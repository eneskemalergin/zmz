//! Writes plain or indexed mzML without retaining records or a run.

const std = @import("std");
const cv = @import("../cv/source.zig");
const model = @import("model.zig");
const schema = @import("schema.zig");
const xml = @import("../xml/mzml_adapter.zig");
const base64 = @import("../binary/base64.zig");

const Writer = @This();

/// Explicit bounds for caller-supplied node hierarchies.
pub const Limits = schema.Limits;

/// Writer failures are sticky. No error permits treating partially written output as complete.
pub const Error = xml.WriterError || cv.ValueError || base64.Error || schema.Error || error{
    InvalidStructure,
    MissingAttribute,
    UnknownAttribute,
    CountMismatch,
    EncodedLengthMismatch,
    PayloadNotRetained,
    InvalidIndex,
    InvalidState,
    UnsupportedVersion,
    LimitExceeded,
    FailedState,
    DuplicateId,
    InvalidOptions,
};

engine: xml.Writer,
allocator: std.mem.Allocator,
limits: Limits,
phase: enum { initial, run, list, done } = .initial,
failed: bool = false,
list_kind: ?model.Kind = null,
expected_count: usize = 0,
written_count: usize = 0,
index_state: ?*IndexState = null,

/// Bounds retained index entries and ID bytes for indexed output.
pub const IndexLimits = struct { records: usize = 1_000_000, id_bytes: usize = 64 * 1024 * 1024 };

/// Borrows the sink; finish closes XML but the caller must flush and close its own sink.
/// Release writer-owned XML storage with deinit, including after failure. Do not copy it.
pub fn init(allocator: std.mem.Allocator, sink: *std.Io.Writer, limits: Limits) Error!Writer {
    try schema.checkLimits(limits);
    return .{ .engine = try xml.Writer.init(allocator, sink, .{}), .allocator = allocator, .limits = limits };
}

/// Writes indexedmzML with physical byte offsets and the schema-defined SHA-1 range.
/// Retains IDs and offsets, not records. The caller still owns flushing the sink.
pub fn initIndexed(allocator: std.mem.Allocator, sink: *std.Io.Writer, limits: Limits, index_limits: IndexLimits) Error!Writer {
    try schema.checkLimits(limits);
    const state = try allocator.create(IndexState);
    errdefer allocator.destroy(state);
    state.* = .{ .allocator = allocator, .hashed = .{ .out = sink }, .arena = .init(allocator), .limits = index_limits };
    return .{ .engine = try xml.Writer.init(allocator, &state.hashed.writer, .{}), .allocator = allocator, .limits = limits, .index_state = state };
}

/// Releases XML writer storage without finishing or flushing output.
pub fn deinit(self: *Writer) void {
    self.engine.deinit();
    if (self.index_state) |state| {
        state.entries.deinit(state.allocator);
        for (&state.ids) |*ids| ids.deinit(state.allocator);
        state.arena.deinit();
        state.allocator.destroy(state);
    }
    self.* = undefined;
}

/// Emits source metadata and opens the run. Initialization selects plain or indexed output.
/// Nodes and parameters are borrowed only for the duration of this call.
pub fn writeHeader(self: *Writer, header: model.Header) Error!void {
    if (self.failed) return error.FailedState;
    errdefer self.failed = true;
    if (self.phase != .initial) return error.InvalidState;
    try schema.checkHeader(header);
    try self.engine.startDocument();
    if (self.index_state != null) {
        try self.engine.startElement("indexedmzML");
        try self.engine.namespace(null, xml.NAMESPACE);
    }
    try self.engine.startElement("mzML");
    try self.engine.namespace(null, xml.NAMESPACE);
    try self.engine.namespace("xsi", xml.XSI);
    try self.writeAttributes(header.document.attributes);
    try self.writeParams(header.document.params);
    var no_arrays: []const []const u8 = &.{};
    var budget = self.limits.nodes;
    try self.writeChildren(header.document, false, &no_arrays, self.limits.depth, &budget);
    try self.engine.startElement("run");
    try self.writeAttributes(header.run.attributes);
    try self.writeParams(header.run.params);
    self.phase = .run;
}

/// Opens a spectrum or chromatogram list with an exact forward-only count and processing ref.
/// Spectra precede chromatograms, and each list can occur at most once.
pub fn beginList(self: *Writer, kind: model.Kind, count: usize, processing_ref: []const u8) Error!void {
    if (self.failed) return error.FailedState;
    errdefer self.failed = true;
    if (self.phase != .run) return error.InvalidState;
    if (kind != .spectrum_list and kind != .chromatogram_list) return error.InvalidStructure;
    if (self.list_kind == kind or self.list_kind == .chromatogram_list) return error.InvalidStructure;
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{count}) catch return error.LimitExceeded;
    try self.engine.startElement(kind.xmlName());
    try self.engine.attribute("count", text);
    try self.engine.attribute("defaultDataProcessingRef", processing_ref);
    self.list_kind = kind;
    self.expected_count = count;
    self.written_count = 0;
    self.phase = .list;
}

/// Writes a complete source record with retained encoded arrays, without retaining it afterward.
/// Text is escaped as XML, without checking Base64 or interpreting encodedLength.
/// Numeric array construction uses the separate arrays encoder before this call.
pub fn writeRecord(self: *Writer, node: model.Node) Error!void {
    return self.writeRecordInner(node, false, &.{});
}

/// Writes prepared primitive, Numpress, or compressed bytes as canonical Base64 in array order.
/// Existing binary text is ignored. Metadata, encodedLength, and array count must match.
/// Bytes are borrowed until return, must not alias the sink buffer, and are not decompressed.
/// Uses bounded temporary storage; list, index, and failure rules match writeRecord.
pub fn writeRecordWithArrays(self: *Writer, node: model.Node, wire_arrays: []const []const u8) Error!void {
    return self.writeRecordInner(node, true, wire_arrays);
}

fn writeRecordInner(self: *Writer, node: model.Node, comptime replace_arrays: bool, wire_arrays: []const []const u8) Error!void {
    if (self.failed) return error.FailedState;
    errdefer self.failed = true;
    if (self.phase != .list) return error.InvalidState;
    const expected: model.Kind = if (self.list_kind == .spectrum_list) .spectrum else .chromatogram;
    if (node.kind != expected) return error.InvalidStructure;
    if (self.written_count == self.expected_count) return error.CountMismatch;
    if (replace_arrays) {
        const list = node.child(.binary_data_array_list);
        const arrays = if (list) |value| value.children else &.{};
        if (arrays.len != wire_arrays.len) return error.CountMismatch;
        const sink = if (self.index_state) |state| state.hashed.out else self.engine.sink;
        if (overlaps(sink.buffer, std.mem.sliceAsBytes(wire_arrays))) return error.OverlappingBuffers;
        for (arrays, wire_arrays) |array, wire| {
            if (array.kind != .binary_data_array or array.children.len != 1 or
                array.children[0].kind != .binary) return error.InvalidStructure;
            if (overlaps(sink.buffer, wire)) return error.OverlappingBuffers;
            const length = try base64.encodedSize(wire.len);
            if (length > self.limits.text_bytes) return error.LimitExceeded;
            if (try cv.parseInteger(usize, array.attribute("encodedLength")) != length)
                return error.EncodedLengthMismatch;
        }
    }
    if (try cv.parseInteger(usize, node.attribute("index")) != self.written_count)
        return error.InvalidIndex;
    if (self.index_state) |state| {
        try self.engine.text("");
        const offset = self.engine.byteOffset() orelse return error.LimitExceeded;
        if (offset > std.math.maxInt(i64)) return error.LimitExceeded;
        const id = node.attribute("id") orelse return error.MissingAttribute;
        if (state.entries.items.len == state.limits.records or id.len > state.limits.id_bytes -| state.id_bytes)
            return error.LimitExceeded;
        const copied = try state.arena.allocator().dupe(u8, id);
        const found = try state.ids[if (node.kind == .spectrum) @as(usize, 0) else 1].getOrPutContextAdapted(
            state.allocator,
            copied,
            IdQuery{ .entries = state.entries.items },
            .{ .entries = state.entries.items },
        );
        if (found.found_existing) return error.DuplicateId;
        found.key_ptr.* = state.entries.items.len;
        state.id_bytes += id.len;
        try state.entries.ensureUnusedCapacity(state.allocator, 1);
        state.entries.appendAssumeCapacity(.{ .id = copied, .offset = offset });
        if (node.kind == .spectrum) state.spectra += 1;
    }
    var remaining = wire_arrays;
    var budget = self.limits.nodes;
    try self.writeNode(node, replace_arrays, &remaining, self.limits.depth, &budget);
    if (remaining.len != 0) return error.CountMismatch;
    self.written_count += 1;
}

/// Closes the active list only after exactly its declared number of records were written.
pub fn endList(self: *Writer) Error!void {
    if (self.failed) return error.FailedState;
    errdefer self.failed = true;
    if (self.phase != .list) return error.InvalidState;
    if (self.written_count != self.expected_count) return error.CountMismatch;
    try self.engine.endElement();
    self.phase = .run;
}

/// Closes the run and document. Does not flush the caller's sink. Can succeed only once.
pub fn finish(self: *Writer) Error!void {
    if (self.failed) return error.FailedState;
    errdefer self.failed = true;
    if (self.phase != .run) return error.InvalidState;
    try self.engine.endElement();
    try self.engine.endElement();
    if (self.index_state) |state| try self.writeIndex(state);
    try self.engine.endDocument();
    self.phase = .done;
}

fn writeIndex(self: *Writer, state: *IndexState) Error!void {
    const offset = self.engine.byteOffset() orelse return error.LimitExceeded;
    if (offset > std.math.maxInt(i64)) return error.LimitExceeded;
    const spectrum = state.spectra != 0 or state.entries.items.len == 0;
    const chromatogram = state.spectra != state.entries.items.len;
    try self.engine.startElement("indexList");
    try self.engine.attribute("count", if (spectrum and chromatogram) "2" else "1");
    inline for (.{ model.Kind.spectrum, model.Kind.chromatogram }) |kind| {
        if (if (kind == .spectrum) spectrum else chromatogram) {
            try self.engine.startElement("index");
            try self.engine.attribute("name", kind.xmlName());
            const entries = if (kind == .spectrum) state.entries.items[0..state.spectra] else state.entries.items[state.spectra..];
            for (entries) |entry| {
                try self.engine.startElement("offset");
                try self.engine.attribute("idRef", entry.id);
                var text: [32]u8 = undefined;
                try self.engine.text(std.fmt.bufPrint(&text, "{d}", .{entry.offset}) catch return error.LimitExceeded);
                try self.engine.endElement();
            }
            try self.engine.endElement();
        }
    }
    try self.engine.endElement();
    try self.engine.startElement("indexListOffset");
    var text: [32]u8 = undefined;
    try self.engine.text(std.fmt.bufPrint(&text, "{d}", .{offset}) catch return error.LimitExceeded);
    try self.engine.endElement();
    try self.engine.startElement("fileChecksum");
    try self.engine.text("");
    const checksum = std.fmt.bytesToHex(state.hashed.hasher.finalResult(), .lower);
    try self.engine.text(&checksum);
    try self.engine.endElement();
    try self.engine.endElement();
}

fn writeNode(self: *Writer, node: model.Node, comptime replace_arrays: bool, remaining: *[]const []const u8, depth: usize, budget: *usize) Error!void {
    if (depth == 0 or budget.* == 0) return error.LimitExceeded;
    budget.* -= 1;
    if (node.kind == .binary) {
        if (node.params.len != 0) return error.InvalidStructure;
        if (!replace_arrays and node.text == null) return error.PayloadNotRetained;
    } else if (node.text != null) return error.InvalidStructure;
    try self.engine.startElement(node.kind.xmlName());
    try self.writeAttributes(node.attributes);
    try self.writeParams(node.params);
    if (replace_arrays and node.kind == .binary) {
        if (remaining.len == 0) return error.CountMismatch;
        try self.engine.binary(remaining.*[0]);
        remaining.* = remaining.*[1..];
    } else if (node.text) |text| {
        if (text.len > self.limits.text_bytes) return error.LimitExceeded;
        try self.engine.text(text);
    }
    try self.writeChildren(node, replace_arrays, remaining, depth - 1, budget);
    try self.engine.endElement();
}

fn writeChildren(self: *Writer, node: model.Node, comptime replace_arrays: bool, remaining: *[]const []const u8, depth: usize, budget: *usize) Error!void {
    const rules = schema.CHILD_KINDS.get(node.kind);
    var seen = std.EnumSet(model.Kind).initEmpty();
    for (node.children) |child| {
        if (!rules.allowed.contains(child.kind) or (node.kind == .mzml and child.kind == .run))
            return error.InvalidStructure;
        if (rules.singular.contains(child.kind) and seen.contains(child.kind)) return error.InvalidStructure;
        seen.insert(child.kind);
        try self.writeNode(child, replace_arrays, remaining, depth, budget);
    }
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const start_a = @intFromPtr(a.ptr);
    const start_b = @intFromPtr(b.ptr);
    return if (start_a <= start_b) start_b - start_a < a.len else start_a - start_b < b.len;
}

fn writeAttributes(self: *Writer, attrs: []const model.Attribute) Error!void {
    for (attrs) |attr| {
        if (attr.namespace_uri) |uri| {
            if (!std.mem.eql(u8, uri, xml.XSI) or !std.mem.eql(u8, attr.name, "schemaLocation"))
                return error.UnknownAttribute;
        }
        try self.engine.attribute(if (attr.namespace_uri != null) "xsi:schemaLocation" else attr.name, attr.value);
    }
}

fn writeParams(self: *Writer, params: []const cv.Entry) Error!void {
    for (params) |entry| {
        switch (entry) {
            .group_ref => |ref| {
                try self.engine.startElement("referenceableParamGroupRef");
                try self.optionalAttribute("ref", ref);
            },
            .cv => |param| {
                try self.engine.startElement("cvParam");
                try self.optionalAttribute("cvRef", param.cv_ref);
                try self.optionalAttribute("accession", if (param.accession) |accession| accession.raw else null);
                try self.optionalAttribute("name", param.name);
                try self.optionalAttribute("value", param.value);
                try self.writeUnit(param.unit);
            },
            .user => |param| {
                try self.engine.startElement("userParam");
                try self.optionalAttribute("name", param.name);
                try self.optionalAttribute("value", param.value);
                try self.optionalAttribute("type", param.value_type);
                try self.writeUnit(param.unit);
            },
        }
        try self.engine.endElement();
    }
}

fn writeUnit(self: *Writer, unit: cv.Unit) Error!void {
    try self.optionalAttribute("unitCvRef", unit.cv_ref);
    try self.optionalAttribute("unitAccession", if (unit.accession) |a| a.raw else null);
    try self.optionalAttribute("unitName", unit.name);
}

fn optionalAttribute(self: *Writer, name: []const u8, value: ?[]const u8) Error!void {
    if (value) |text| try self.engine.attribute(name, text);
}

const IndexEntry = struct { id: []const u8, offset: u64 };

const IndexState = struct {
    allocator: std.mem.Allocator,
    hashed: ChecksumWriter,
    arena: std.heap.ArenaAllocator,
    limits: IndexLimits,
    entries: std.ArrayList(IndexEntry) = .empty,
    ids: [2]std.HashMapUnmanaged(usize, void, IdContext, std.hash_map.default_max_load_percentage) = .{ .empty, .empty },
    spectra: usize = 0,
    id_bytes: usize = 0,
};

const IdContext = struct {
    entries: []const IndexEntry,

    pub fn hash(self: IdContext, position: usize) u64 {
        return std.hash_map.hashString(self.entries[position].id);
    }

    pub fn eql(_: IdContext, left: usize, right: usize) bool {
        return left == right;
    }
};

const IdQuery = struct {
    entries: []const IndexEntry,

    pub fn hash(_: IdQuery, id: []const u8) u64 {
        return std.hash_map.hashString(id);
    }

    pub fn eql(self: IdQuery, id: []const u8, position: usize) bool {
        return std.mem.eql(u8, id, self.entries[position].id);
    }
};

const ChecksumWriter = struct {
    out: *std.Io.Writer,
    hasher: std.crypto.hash.Sha1 = .init(.{}),
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        // The XML writer submits one slice per write, without buffering or splats.
        std.debug.assert(writer.end == 0 and data.len == 1 and splat == 1);
        const self: *ChecksumWriter = @alignCast(@fieldParentPtr("writer", writer));
        const written = try self.out.write(data[0]);
        if (written != 0) self.hasher.update(data[0][0..written]);
        return written;
    }
};
