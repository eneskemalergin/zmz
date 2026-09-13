//! Writes plain or indexed mzML without retaining records or a run.

const std = @import("std");
const cv = @import("../cv/source.zig");
const model = @import("model.zig");
const schema = @import("schema.zig");
const xml = @import("../xml/mzml_adapter.zig");
const Validator = @import("validator.zig");
const base64 = @import("../binary/base64.zig");

const Writer = @This();

/// Explicit bounds for caller-supplied node hierarchies.
pub const Limits = schema.Limits;

/// Writer failures are sticky. No error permits treating partially written output as complete.
pub const Error = xml.WriterError || cv.ValueError || schema.Error || Validator.Error || error{
    InvalidStructure,
    MissingAttribute,
    UnknownAttribute,
    CountMismatch,
    EncodedLengthMismatch,
    PayloadNotRetained,
    InvalidIndex,
    UnsupportedVersion,
    LimitExceeded,
    FailedState,
    DuplicateId,
    InvalidOptions,
};

engine: xml.Writer,
allocator: std.mem.Allocator,
limits: Limits,
validation_limits: ?Validator.Limits = null,
validator: ?Validator = null,
phase: enum { initial, run, list, done } = .initial,
failed: bool = false,
sequence: schema.Sequence = .{ .rules = schema.children(.run) },
list_kind: model.Kind = .spectrum_list,
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
    state.* = .{ .allocator = allocator, .hashed = .initHasher(sink, .init(.{}), &.{}), .arena = .init(allocator), .limits = index_limits };
    return .{ .engine = try xml.Writer.init(allocator, &state.hashed.writer, .{}), .allocator = allocator, .limits = limits, .index_state = state };
}

/// Enables document conformance before writeHeader, for either plain or indexed output.
/// Retains bounded IDs and forward references. Unresolved targets make finish fail.
/// Does not resolve CV terms or validate compressed payloads. Default writing preserves source metadata.
pub fn enableValidation(self: *Writer, limits: Validator.Limits) Error!void {
    if (self.failed) return error.FailedState;
    errdefer self.failed = true;
    if (self.phase != .initial) return error.InvalidState;
    try schema.checkLimits(limits.structure);
    self.validation_limits = limits;
}

/// Releases XML writer storage without finishing or flushing output.
pub fn deinit(self: *Writer) void {
    if (self.validator) |*validator| validator.deinit();
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
    try schema.checkHeader(header, self.limits);
    if (self.validation_limits) |limits| self.validator = try Validator.init(self.allocator, header, limits);
    try self.engine.startDocument();
    if (self.index_state != null) {
        try self.engine.startElement("indexedmzML");
        try self.engine.namespace(null, xml.NAMESPACE);
    }
    try self.engine.startElement("mzML");
    try self.engine.namespace(null, xml.NAMESPACE);
    try self.engine.namespace("xsi", xml.XSI);
    try self.writeAttributes(header.document.attributes);
    var no_arrays: []const []const u8 = &.{};
    for (header.document.children) |node| try self.writeNode(node, false, &no_arrays);
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
    if (kind == .chromatogram_list and count == 0) return error.InvalidStructure;
    try self.sequence.accept(kind);
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{count}) catch return error.LimitExceeded;
    if (self.validator) |*validator| try validator.beginList(.{ .kind = kind, .attributes = &.{
        .{ .name = "count", .value = text },
        .{ .name = "defaultDataProcessingRef", .value = processing_ref },
    } });
    try self.engine.startElement(kind.xmlName());
    try self.engine.attribute("count", text);
    try self.engine.attribute("defaultDataProcessingRef", processing_ref);
    self.list_kind = kind;
    self.expected_count = count;
    self.written_count = 0;
    self.phase = .list;
}

/// Writes a complete source record with retained encoded arrays, without retaining it afterward.
/// This checks structure and encoded character counts, not CV semantics or compressed payloads.
/// Numeric array construction uses the separate arrays encoder before this call.
pub fn writeRecord(self: *Writer, node: model.Node) Error!void {
    return self.writeRecordInner(node, false, &.{});
}

/// Writes prepared primitive, Numpress, or compressed bytes as canonical Base64 in array order.
/// Existing binary text is ignored. Metadata, encodedLength, and array count must match.
/// Bytes are borrowed until return, must not alias the sink buffer, and are not decompressed.
/// Uses bounded temporary storage; list, index, validation, and failure rules match writeRecord.
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
        try schema.checkMetadataNode(node, self.limits);
        const list = node.child(.binary_data_array_list);
        const arrays = if (list) |value| value.children else &.{};
        if (arrays.len != wire_arrays.len) return error.CountMismatch;
        const sink = if (self.index_state) |state| state.hashed.out else self.engine.sink;
        if (overlaps(sink.buffer, std.mem.sliceAsBytes(wire_arrays))) return error.OverlappingBuffers;
        for (arrays, wire_arrays) |array, wire| {
            if (overlaps(sink.buffer, wire)) return error.OverlappingBuffers;
            const length = try base64.encodedSize(wire.len);
            if (length > self.limits.text_bytes) return error.LimitExceeded;
            if (try cv.parseInteger(usize, array.attribute("encodedLength")) != length)
                return error.EncodedLengthMismatch;
        }
    } else try schema.checkNode(node, self.limits);
    if (try cv.parseInteger(usize, node.attribute("index")) != self.written_count)
        return error.InvalidIndex;
    if (self.validator) |*validator| try validator.record(node);
    if (self.index_state) |state| {
        try self.engine.text("");
        const offset = self.engine.byteOffset() orelse return error.LimitExceeded;
        if (offset > std.math.maxInt(i64)) return error.LimitExceeded;
        const id = node.attribute("id").?;
        if (state.entries.items.len == state.limits.records or id.len > state.limits.id_bytes -| state.id_bytes)
            return error.LimitExceeded;
        const copied = try state.arena.allocator().dupe(u8, id);
        const found = try state.ids[if (node.kind == .spectrum) @as(usize, 0) else 1].getOrPut(state.allocator, copied);
        if (found.found_existing) return error.DuplicateId;
        state.id_bytes += id.len;
        try state.entries.ensureUnusedCapacity(state.allocator, 1);
        state.entries.appendAssumeCapacity(.{ .kind = node.kind, .id = copied, .offset = offset });
    }
    var remaining = wire_arrays;
    try self.writeNode(node, replace_arrays, &remaining);
    std.debug.assert(remaining.len == 0);
    self.written_count += 1;
}

/// Closes the active list only after exactly its declared number of records were written.
pub fn endList(self: *Writer) Error!void {
    if (self.failed) return error.FailedState;
    errdefer self.failed = true;
    if (self.phase != .list) return error.InvalidState;
    if (self.written_count != self.expected_count) return error.CountMismatch;
    if (self.validator) |*validator| try validator.endList();
    try self.engine.endElement();
    self.phase = .run;
}

/// Closes the run and document. Does not flush the caller's sink. Can succeed only once.
pub fn finish(self: *Writer) Error!void {
    if (self.failed) return error.FailedState;
    errdefer self.failed = true;
    if (self.phase != .run) return error.InvalidState;
    try self.sequence.finish();
    if (self.validator) |*validator| try validator.finish();
    try self.engine.endElement();
    try self.engine.endElement();
    if (self.index_state) |state| try self.writeIndex(state);
    try self.engine.endDocument();
    self.phase = .done;
}

fn writeIndex(self: *Writer, state: *IndexState) Error!void {
    const offset = self.engine.byteOffset() orelse return error.LimitExceeded;
    if (offset > std.math.maxInt(i64)) return error.LimitExceeded;
    var spectrum = state.entries.items.len == 0;
    var chromatogram = false;
    for (state.entries.items) |entry| {
        if (entry.kind == .spectrum) spectrum = true else chromatogram = true;
    }
    try self.engine.startElement("indexList");
    try self.engine.attribute("count", if (spectrum and chromatogram) "2" else "1");
    inline for (.{ model.Kind.spectrum, model.Kind.chromatogram }) |kind| {
        if (if (kind == .spectrum) spectrum else chromatogram) {
            try self.engine.startElement("index");
            try self.engine.attribute("name", kind.xmlName());
            for (state.entries.items) |entry| {
                if (entry.kind != kind) continue;
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

fn writeNode(self: *Writer, node: model.Node, comptime replace_arrays: bool, remaining: *[]const []const u8) Error!void {
    try self.engine.startElement(node.kind.xmlName());
    try self.writeAttributes(node.attributes);
    try self.writeParams(node.params);
    if (replace_arrays and node.kind == .binary) {
        try self.writeBinary(remaining.*[0]);
        remaining.* = remaining.*[1..];
    } else if (node.text) |text| try self.engine.text(text);
    for (node.children) |child| try self.writeNode(child, replace_arrays, remaining);
    try self.engine.endElement();
}

fn writeBinary(self: *Writer, wire: []const u8) Error!void {
    var encoded: [4096]u8 = undefined;
    if (wire.len == 0) return self.engine.text("");
    var offset: usize = 0;
    while (offset < wire.len) {
        const length = @min(wire.len - offset, encoded.len / 4 * 3);
        const text = try base64.encode(&encoded, wire[offset..][0..length]);
        try self.engine.text(text);
        offset += length;
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
        try self.engine.attribute(if (attr.namespace_uri != null) "xsi:schemaLocation" else attr.name, attr.value);
    }
}

fn writeParams(self: *Writer, params: []const cv.Entry) Error!void {
    for (params) |entry| {
        switch (entry) {
            .group_ref => |ref| {
                try self.engine.startElement("referenceableParamGroupRef");
                try self.engine.attribute("ref", ref.?);
            },
            .cv => |param| {
                try self.engine.startElement("cvParam");
                try self.engine.attribute("cvRef", param.cv_ref.?);
                try self.engine.attribute("accession", param.accession.?.raw);
                try self.engine.attribute("name", param.name.?);
                try self.optionalAttribute("value", param.value);
                try self.writeUnit(param.unit);
            },
            .user => |param| {
                try self.engine.startElement("userParam");
                try self.engine.attribute("name", param.name.?);
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

const IndexState = struct {
    allocator: std.mem.Allocator,
    hashed: std.Io.Writer.Hashed(std.crypto.hash.Sha1),
    arena: std.heap.ArenaAllocator,
    limits: IndexLimits,
    entries: std.ArrayList(struct { kind: model.Kind, id: []const u8, offset: u64 }) = .empty,
    ids: [2]std.StringHashMapUnmanaged(void) = .{ .empty, .empty },
    id_bytes: usize = 0,
};
