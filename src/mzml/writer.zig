//! Writes plain or indexed mzML without retaining records or a run. Forward-only
//! sinks require list counts up front. File-backed output can patch unknown counts
//! when lists close; indexed file output hashes the completed prefix at finish.

const std = @import("std");
const cv = @import("../cv/source.zig");
const model = @import("model.zig");
const schema = @import("schema.zig");
const xml = @import("../xml/mzml_adapter.zig");
const base64 = @import("../binary/base64.zig");
const overlaps = @import("../binary/core.zig").overlaps;
const Sha1 = @import("../binary/sha1.zig").Sha1;
const Diagnostic = @import("diagnostic.zig");
const Ids = @import("internal/id_index.zig").IdIndex(IndexEntry);

const Writer = @This();
const COUNT_PLACEHOLDER = "0" ** std.fmt.comptimePrint("{d}", .{std.math.maxInt(usize)}).len;

pub const Limits = schema.Limits;

/// Writer failures are sticky. No error permits treating partially written output as complete.
pub const Error = xml.WriterError || xml.Error || cv.ValueError || base64.Error || schema.Error || std.Io.File.WritePositionalError || std.Io.File.ReadPositionalError || error{
    InvalidStructure,
    MissingAttribute,
    UnknownAttribute,
    CountMismatch,
    EncodedLengthMismatch,
    PayloadNotRetained,
    InvalidIndex,
    InvalidState,
    LimitExceeded,
    FailedState,
    DuplicateId,
    InvalidOptions,
    UnexpectedEndOfFile,
};

engine: xml.Writer,
allocator: std.mem.Allocator,
limits: Limits,
phase: enum { initial, run, list, document, done } = .initial,
failure: ?Diagnostic = null,
list_kind: ?model.Kind = null,
expected_count: usize = 0,
written_count: usize = 0,
index_state: ?*IndexState = null,
file_sink: ?*std.Io.File.Writer = null,
count_offset: ?u64 = null,
namespace_uri: []const u8 = xml.NAMESPACE,

/// Bounds retained index entries and ID bytes, including historical native/spot IDs.
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
    state.* = .{ .allocator = allocator, .hashed = undefined, .arena = .init(allocator), .limits = index_limits };
    state.hashed = .init(sink, &state.hashed_buffer);
    return .{ .engine = try xml.Writer.init(allocator, &state.hashed.writer, .{}), .allocator = allocator, .limits = limits, .index_state = state };
}

/// Borrows a positional file writer at offset zero on an empty file. Do not write
/// through it independently until finish. Null index_limits selects plain mzML.
/// Indexed output needs a readable file and reads its prefix once for the checksum.
/// List counts may be null. The caller must still flush the final bytes.
pub fn initFile(allocator: std.mem.Allocator, sink: *std.Io.File.Writer, limits: Limits, index_limits: ?IndexLimits) Error!Writer {
    if (sink.logicalPos() != 0 or (sink.mode != .positional and sink.mode != .positional_simple))
        return error.InvalidOptions;
    var writer = if (index_limits) |index|
        try initIndexed(allocator, &sink.interface, limits, index)
    else
        try init(allocator, &sink.interface, limits);
    writer.engine.sink = &sink.interface;
    writer.file_sink = sink;
    return writer;
}

/// Releases XML writer storage without finishing or flushing output.
pub fn deinit(self: *Writer) void {
    self.engine.deinit();
    if (self.index_state) |state| state.deinit();
    self.* = undefined;
}

/// Returns the first failure, unchanged by later FailedState returns. Reports do
/// not make partial output usable. A final caller-owned flush is not reported here.
pub fn diagnostic(self: *const Writer) ?Diagnostic {
    return self.failure;
}

fn capture(self: *Writer, err: Error, stage: Diagnostic.Stage, detail: Diagnostic.Detail) void {
    if (self.failure != null) return;
    var report = Diagnostic.init(err, .write_record, stage, detail);
    if (self.engine.failure != null) {
        report.stage = .output;
        if (err == error.WriterLimit and self.engine.frame_count == schema.MAX_DEPTH)
            report = Diagnostic.init(err, .write_record, .output, .{ .limit = .{ .name = .depth, .maximum = schema.MAX_DEPTH } });
    }
    if (self.engine.byteOffset()) |offset| report.location = .{ .output_byte = offset };
    self.failure = report;
}

fn fail(self: *Writer, err: Error, operation: Diagnostic.Operation) void {
    self.capture(err, .metadata, .none);
    self.failure.?.operation = operation;
}

fn limitError(self: *Writer, name: Diagnostic.Limit, maximum: usize, needed: ?usize) Error!noreturn {
    self.capture(error.LimitExceeded, .metadata, .{ .limit = .{ .name = name, .maximum = maximum, .needed = needed } });
    return error.LimitExceeded;
}

fn sizeError(self: *Writer, err: Error, expected: usize, actual: usize, unit: Diagnostic.SizeUnit) Error!noreturn {
    self.capture(err, .metadata, .{ .size = .{ .expected = expected, .actual = actual, .unit = unit } });
    return err;
}

fn number(self: *Writer, node: model.Node, attribute: Diagnostic.Attribute) Error!usize {
    return cv.parseInteger(usize, node.attribute(attribute.xmlName())) catch |err| {
        self.capture(err, .metadata, .{ .attribute = attribute });
        return @as(Error!usize, err);
    };
}

fn ioFailure(self: *Writer, err: Error) Error!noreturn {
    self.capture(err, .output, .none);
    self.failure.?.location = null;
    return err;
}

fn copyId(self: *Writer, state: *IndexState, id: []const u8) Error![]const u8 {
    return state.copyId(id) catch |err| {
        self.capture(err, .index, if (err == error.LimitExceeded) .{ .limit = .{ .name = .id_bytes, .maximum = state.limits.id_bytes } } else .none);
        return @as(Error![]const u8, err);
    };
}

/// Emits source metadata and opens the run. Initialization selects plain or indexed output.
/// Nodes and parameters are borrowed only for the duration of this call.
pub fn writeHeader(self: *Writer, header: model.Header) Error!void {
    if (self.failure != null) return error.FailedState;
    errdefer |err| self.fail(err, .write_header);
    if (self.phase != .initial) return error.InvalidState;
    try schema.checkHeader(header);
    self.namespace_uri = if (std.mem.eql(u8, header.namespace_uri, xml.NAMESPACE)) xml.NAMESPACE else if (std.mem.eql(u8, header.namespace_uri, xml.NAMESPACE_1_0)) xml.NAMESPACE_1_0 else return error.InvalidNamespace;
    try self.engine.startDocument();
    if (self.index_state) |state| {
        state.historical = std.mem.eql(u8, header.namespace_uri, xml.NAMESPACE_1_0);
        try self.engine.startElement("indexedmzML");
        try self.engine.namespace(null, header.namespace_uri);
    }
    try self.startKnown("mzML", header.document.attributes, true);
    if (self.engine.namespaceUri("xsi") == null) try self.engine.namespace("xsi", xml.XSI);
    try self.writeAttributes(header.document.attributes);
    var no_arrays: []const []const u8 = &.{};
    var budget = self.limits.nodes;
    try self.writeContent(header.document, false, &no_arrays, &budget);
    try self.startKnown("run", header.run.attributes, false);
    try self.writeAttributes(header.run.attributes);
    try self.writeContent(header.run, false, &no_arrays, &budget);
    self.phase = .run;
}

/// Opens a spectrum or chromatogram list. A null count requires initFile and is
/// filled in by endList; other writers require an exact count before writing.
/// Spectra precede chromatograms, and each list can occur at most once.
pub fn beginList(self: *Writer, kind: model.Kind, count: ?usize, processing_ref: []const u8) Error!void {
    return self.beginListWithAttributes(kind, count, &.{.{ .name = "defaultDataProcessingRef", .value = processing_ref }});
}

/// Opens a list using source attributes borrowed until return. Writes the supplied count
/// first, ignoring source count attributes; other attributes keep their order and values.
/// An absent processing reference stays absent. Null count and list order follow beginList.
pub fn beginListWithAttributes(self: *Writer, kind: model.Kind, count: ?usize, attributes: []const model.Attribute) Error!void {
    if (self.failure != null) return error.FailedState;
    errdefer |err| {
        self.fail(err, .open_list);
        self.failure.?.element = kind;
    }
    if (self.phase != .run) return error.InvalidState;
    if (kind != .spectrum_list and kind != .chromatogram_list) return error.InvalidStructure;
    if (self.list_kind == kind or self.list_kind == .chromatogram_list) return error.InvalidStructure;
    if (count == null and self.file_sink == null) return error.InvalidOptions;
    var buffer: [32]u8 = undefined;
    const text = if (count) |value| buffer[0..std.fmt.printInt(&buffer, value, 10, .lower, .{})] else COUNT_PLACEHOLDER;
    try self.startKnown(kind.xmlName(), attributes, false);
    try self.engine.attribute("count", text);
    self.count_offset = if (count == null)
        (self.engine.byteOffset() orelse return error.LimitExceeded) - 1 - COUNT_PLACEHOLDER.len
    else
        null;
    for (attributes) |attribute| {
        if (attribute.namespace_uri == null and std.mem.eql(u8, attribute.name, "count")) continue;
        try self.writeAttributes(&.{attribute});
    }
    self.list_kind = kind;
    self.expected_count = count orelse std.math.maxInt(usize);
    self.written_count = 0;
    self.phase = .list;
}

/// Writes a complete source record with retained encoded arrays, without retaining it afterward.
/// Text is escaped as XML, without checking Base64 or interpreting encodedLength.
/// Numeric array construction uses the separate arrays encoder before this call.
pub fn writeRecord(self: *Writer, node: model.Node) Error!void {
    return self.writeRecordInner(node, false, @as([]const []const u8, &.{}));
}

/// Writes one forward item without retaining it. List openings use source counts;
/// use beginListWithAttributes instead when filtering or choosing unknown counts.
/// Decoded records still need writeRecordWithArrays for their omitted binary text.
pub fn writeItem(self: *Writer, item: model.Item) Error!void {
    if (self.failure != null) return error.FailedState;
    errdefer |err| self.fail(err, .write_item);
    switch (item) {
        .list_start => |start| try self.beginListWithAttributes(start.kind, start.list.declared_count, start.list.attributes),
        .record => |record| try self.writeRecord(record.node),
        .list_end => try self.endList(),
        .run_end => {
            if (self.phase != .run) return error.InvalidState;
            try self.engine.endElement();
            self.phase = .document;
        },
        .xml => |bytes| {
            if (self.phase != .run and self.phase != .list and self.phase != .document) return error.InvalidState;
            var budget = self.limits.nodes;
            try self.writeXml(bytes, &budget);
        },
    }
}

/// Writes prepared primitive, Numpress, or compressed bytes as canonical Base64 in array order.
/// Existing binary text is ignored. Metadata, encodedLength, and array count must match.
/// Bytes are borrowed until return, must not alias the sink buffer, and are not decompressed.
/// Uses bounded temporary storage; list, index, and failure rules match writeRecord.
pub fn writeRecordWithArrays(self: *Writer, node: model.Node, wire_arrays: []const []const u8) Error!void {
    return self.writeRecordInner(node, true, wire_arrays);
}

/// Takes one choice per modeled array in source order: null retains binary text;
/// a wire slice replaces it, including an empty slice. Only supplied bytes receive
/// the prepared-array checks of writeRecordWithArrays; retained codecs are not read.
/// Metadata, choices, and wire borrow until return. Choices must not alias the sink.
pub fn writeRecordWithSelectedArrays(self: *Writer, node: model.Node, wire_arrays: []const ?[]const u8) Error!void {
    return self.writeRecordInner(node, true, wire_arrays);
}

fn writeRecordInner(self: *Writer, node: model.Node, comptime replace_arrays: bool, wire_arrays: anytype) Error!void {
    if (self.failure != null) return error.FailedState;
    errdefer |err| {
        self.fail(err, .write_record);
        if (self.failure.?.element == null) self.failure.?.element = node.kind;
        if (self.phase == .list and (node.kind == .spectrum or node.kind == .chromatogram))
            self.failure.?.record = Diagnostic.RecordPosition.of(node.kind, self.written_count);
    }
    if (self.phase != .list) return error.InvalidState;
    const expected: model.Kind = if (self.list_kind == .spectrum_list) .spectrum else .chromatogram;
    if (node.kind != expected) return error.InvalidStructure;
    if (self.written_count == self.expected_count) {
        if (self.written_count < std.math.maxInt(usize)) return try self.sizeError(error.CountMismatch, self.expected_count, self.written_count + 1, .records);
        return error.CountMismatch;
    }
    if (replace_arrays) {
        const list = node.child(.binary_data_array_list);
        const arrays = if (list) |value| value.children else &.{};
        if (arrays.len != wire_arrays.len) return try self.sizeError(error.CountMismatch, arrays.len, wire_arrays.len, .arrays);
        if (self.overlapsOutput(std.mem.sliceAsBytes(wire_arrays))) return error.OverlappingBuffers;
        for (arrays, wire_arrays, 0..) |array, supplied, position| {
            const wire = @as(?[]const u8, supplied) orelse continue;
            errdefer |err| {
                self.capture(err, .array, .none);
                self.failure.?.element = .binary_data_array;
                self.failure.?.array_position = position;
            }
            if (array.kind != .binary_data_array or array.children.len != 1 or
                array.children[0].kind != .binary) return error.InvalidStructure;
            if (self.overlapsOutput(wire)) return error.OverlappingBuffers;
            const length = try base64.encodedSize(wire.len);
            if (length > self.limits.text_bytes) return try self.limitError(.text_bytes, self.limits.text_bytes, length);
            const declared = try self.number(array, .encoded_length);
            if (declared != length) return try self.sizeError(error.EncodedLengthMismatch, length, declared, .bytes);
        }
    }
    const index = try self.number(node, .index);
    if (index != self.written_count) return try self.sizeError(error.InvalidIndex, self.written_count, index, .index);
    if (self.index_state) |state| {
        try self.engine.text("");
        const offset = self.engine.byteOffset() orelse return error.LimitExceeded;
        if (offset > std.math.maxInt(i64)) return error.LimitExceeded;
        errdefer |err| self.capture(err, .index, .none);
        const id = node.attribute("id") orelse {
            self.capture(error.MissingAttribute, .index, .{ .attribute = .id });
            return error.MissingAttribute;
        };
        if (state.entries.items.len == state.limits.records) return try self.limitError(.records, state.limits.records, null);
        const copied = try self.copyId(state, id);
        const found = try state.ids[if (node.kind == .spectrum) @as(usize, 0) else 1].getOrPutContextAdapted(
            state.allocator,
            copied,
            Ids.Query{ .entries = state.entries.items },
            .{ .entries = state.entries.items },
        );
        if (found.found_existing) return error.DuplicateId;
        found.key_ptr.* = state.entries.items.len;
        if (state.historical) {
            const native_id = if (node.attribute("nativeID")) |value| try self.copyId(state, value) else null;
            const spot_id = if (node.attribute("spotID")) |value| try self.copyId(state, value) else null;
            try state.historical_ids.append(state.allocator, .{ .native_id = native_id, .spot_id = spot_id });
        }
        try state.entries.ensureUnusedCapacity(state.allocator, 1);
        state.entries.appendAssumeCapacity(.{ .id = copied, .offset = offset });
        if (node.kind == .spectrum) state.spectra += 1;
    }
    var remaining = wire_arrays;
    var budget = self.limits.nodes;
    try self.writeNode(node, replace_arrays, &remaining, &budget);
    if (remaining.len != 0) return try self.sizeError(error.CountMismatch, wire_arrays.len - remaining.len, wire_arrays.len, .arrays);
    self.written_count += 1;
}

/// Closes the active list, checking a supplied count or patching an unknown count.
/// Patching flushes pending file bytes but does not change the output position.
pub fn endList(self: *Writer) Error!void {
    if (self.failure != null) return error.FailedState;
    errdefer |err| {
        self.fail(err, .close_list);
        if (self.failure.?.element == null) self.failure.?.element = self.list_kind;
    }
    if (self.phase != .list) return error.InvalidState;
    if (self.count_offset == null and self.written_count != self.expected_count)
        return try self.sizeError(error.CountMismatch, self.expected_count, self.written_count, .records);
    try self.engine.endElement();
    if (self.count_offset) |offset| {
        const sink = self.file_sink.?;
        sink.interface.flush() catch |err| return try self.ioFailure(err);
        var buffer: [32]u8 = undefined;
        const text = buffer[0..std.fmt.printInt(&buffer, self.written_count, 10, .lower, .{})];
        var count = COUNT_PLACEHOLDER.*;
        @memcpy(count[count.len - text.len ..], text);
        sink.file.writePositionalAll(sink.io, &count, offset) catch |err| return try self.ioFailure(err);
    }
    self.phase = .run;
}

/// Closes the run and document. Indexed file output flushes and reads the checksum
/// prefix, but the caller must flush the final bytes. Can succeed only once.
pub fn finish(self: *Writer) Error!void {
    if (self.failure != null) return error.FailedState;
    errdefer |err| self.fail(err, .finish);
    if (self.phase != .run and self.phase != .document) return error.InvalidState;
    if (self.phase == .run) try self.engine.endElement();
    try self.engine.endElement();
    if (self.index_state) |state| try self.writeIndex(state);
    try self.engine.endDocument();
    if (self.index_state != null and self.file_sink == null) try self.flushHashed(self.index_state.?);
    self.phase = .done;
}

// Wire is read while encoding, so it must not share any buffer that output passes through.
fn overlapsOutput(self: *const Writer, bytes: []const u8) bool {
    if (overlaps(self.engine.sink.buffer, bytes)) return true;
    const state = self.index_state orelse return false;
    return self.file_sink == null and overlaps(state.hashed.out.buffer, bytes);
}

// Buffered bytes that fail to reach the sink have no accepted output position.
fn flushHashed(self: *Writer, state: *IndexState) Error!void {
    state.hashed.writer.flush() catch {
        self.capture(error.WriteFailed, .output, .none);
        self.failure.?.location = null;
        return error.WriteFailed;
    };
}

fn writeIndex(self: *Writer, state: *IndexState) Error!void {
    errdefer |err| self.capture(err, .index, .none);
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
            for (entries, if (kind == .spectrum) @as(usize, 0) else state.spectra..) |entry, i| {
                try self.engine.startElement("offset");
                try self.engine.attribute("idRef", entry.id);
                if (state.historical) {
                    try self.optionalAttribute("nativeID", state.historical_ids.items[i].native_id);
                    try self.optionalAttribute("spotID", state.historical_ids.items[i].spot_id);
                }
                var text: [32]u8 = undefined;
                try self.engine.text(text[0..std.fmt.printInt(&text, entry.offset, 10, .lower, .{})]);
                try self.engine.endElement();
            }
            try self.engine.endElement();
        }
    }
    try self.engine.endElement();
    try self.engine.startElement("indexListOffset");
    var text: [32]u8 = undefined;
    try self.engine.text(text[0..std.fmt.printInt(&text, offset, 10, .lower, .{})]);
    try self.engine.endElement();
    try self.engine.startElement("fileChecksum");
    try self.engine.text("");
    const digest = if (self.file_sink) |sink| digest: {
        sink.interface.flush() catch |err| return try self.ioFailure(err);
        const end = self.engine.byteOffset() orelse return error.LimitExceeded;
        var hasher: Sha1 = .{};
        var buffer: [64 * 1024]u8 = undefined;
        var position: u64 = 0;
        while (position < end) {
            const capacity: usize = @intCast(@min(buffer.len, end - position));
            const length = sink.file.readPositional(sink.io, &.{buffer[0..capacity]}, position) catch |err| return try self.ioFailure(err);
            if (length == 0) return try self.ioFailure(error.UnexpectedEndOfFile);
            hasher.update(buffer[0..length]);
            position += length;
        }
        break :digest hasher.finalResult();
    } else digest: {
        try self.flushHashed(state);
        break :digest state.hashed.hasher.finalResult();
    };
    const checksum = std.fmt.bytesToHex(digest, .lower);
    try self.engine.text(&checksum);
    try self.engine.endElement();
    try self.engine.endElement();
}

fn writeNode(self: *Writer, node: model.Node, comptime replace_arrays: bool, remaining: anytype, budget: *usize) Error!void {
    errdefer |err| {
        self.capture(err, .metadata, .none);
        if (self.failure.?.element == null) self.failure.?.element = node.kind;
    }
    if (budget.* == 0) return try self.limitError(.nodes, self.limits.nodes, null);
    budget.* -= 1;
    const wire: ?[]const u8 = if (replace_arrays and node.kind == .binary) blk: {
        if (remaining.len == 0) return error.CountMismatch;
        break :blk remaining.*[0];
    } else null;
    if (node.kind == .binary) {
        if (node.params.len != 0) return error.InvalidStructure;
        if (wire == null and node.text == null) return error.PayloadNotRetained;
    } else if (node.text != null) return error.InvalidStructure;
    try self.startKnown(node.kind.xmlName(), node.attributes, false);
    try self.writeAttributes(node.attributes);
    if (wire) |bytes| {
        try self.engine.binary(bytes);
    } else if (node.text) |text| {
        if (text.len > self.limits.text_bytes) return try self.limitError(.text_bytes, self.limits.text_bytes, text.len);
        try self.engine.text(text);
    }
    try self.writeContent(node, replace_arrays, remaining, budget);
    try self.engine.endElement();
    if (replace_arrays and node.kind == .binary_data_array) {
        if (remaining.len == 0) return error.CountMismatch;
        remaining.* = remaining.*[1..];
    }
}

fn writeContent(self: *Writer, node: model.Node, comptime replace_arrays: bool, remaining: anytype, budget: *usize) Error!void {
    errdefer |err| {
        self.capture(err, .metadata, .none);
        if (self.failure.?.element == null) self.failure.?.element = node.kind;
    }
    var seen = std.EnumSet(model.Kind).initEmpty();
    if (node.content == null) {
        try self.writeParams(node.params, budget);
        for (node.children, 0..) |child, position|
            try self.writeChild(node, child, position, &seen, replace_arrays, remaining, budget);
        return;
    }
    var params: usize = 0;
    var children: usize = 0;
    for (node.content.?.items) |item| switch (item) {
        .params => |count| {
            if (count > node.params.len - params) return error.InvalidStructure;
            try self.writeParams(node.params[params..][0..count], budget);
            params += count;
        },
        .children => |count| {
            if (count > node.children.len - children) return error.InvalidStructure;
            for (node.children[children..][0..count], children..) |child, position|
                try self.writeChild(node, child, position, &seen, replace_arrays, remaining, budget);
            children += count;
        },
        .xml => |bytes| try self.writeXml(bytes, budget),
    };
    if (params != node.params.len or children != node.children.len) return error.InvalidStructure;
}

/// Writes one modeled child after checking it is allowed, and not repeated if singular.
fn writeChild(self: *Writer, parent: model.Node, child: model.Node, position: usize, seen: *std.EnumSet(model.Kind), comptime replace_arrays: bool, remaining: anytype, budget: *usize) Error!void {
    errdefer |err| if (parent.kind == .binary_data_array_list) {
        self.capture(err, .metadata, .none);
        self.failure.?.array_position = position;
    };
    const rules = schema.CHILD_KINDS.get(parent.kind);
    if (!rules.allowed.contains(child.kind) or (parent.kind == .mzml and child.kind == .run)) return error.InvalidStructure;
    if (rules.singular.contains(child.kind) and seen.contains(child.kind)) return error.InvalidStructure;
    seen.insert(child.kind);
    try self.writeNode(child, replace_arrays, remaining, budget);
}

// Keep fragment parser storage off ordinary recursive write frames.
noinline fn writeXml(self: *Writer, bytes: []const u8, budget: *usize) Error!void {
    if (bytes.len > self.limits.text_bytes) return try self.limitError(.text_bytes, self.limits.text_bytes, bytes.len);
    var input = std.Io.Reader.fixed(bytes);
    var cursor = try xml.Cursor.init(self.allocator, &input, schema.MAX_DEPTH, @max(1, bytes.len / 4), self.limits.text_bytes);
    defer cursor.deinit();
    errdefer |err| {
        var detail = Diagnostic.xmlDetail(&cursor);
        if (detail == .limit and detail.limit.name == .nodes) detail.limit.maximum = self.limits.nodes;
        self.capture(err, .xml, detail);
        if (self.engine.failure == null) self.failure.?.location = null;
    }
    try cursor.advanceFragment(true);
    if (cursor.current == null or cursor.current.?.data != .start_element) return error.InvalidStructure;
    try cursor.writeElement(&self.engine, budget);
    try cursor.advanceFragment(false);
    if (cursor.current != null) return error.InvalidStructure;
}

fn writeAttributes(self: *Writer, attrs: []const model.Attribute) Error!void {
    for (attrs) |attr| {
        if (namespacePrefix(attr) != null) continue;
        if (attr.namespace_uri) |uri| {
            if (std.mem.indexOfScalar(u8, attr.name, ':')) |colon| {
                const actual = self.engine.namespaceUri(attr.name[0..colon]) orelse return error.InvalidNamespace;
                if (!std.mem.eql(u8, actual, uri)) return error.InvalidNamespace;
                try self.engine.attribute(attr.name, attr.value);
            } else if (std.mem.eql(u8, uri, xml.XSI) and std.mem.eql(u8, attr.name, "schemaLocation")) {
                if (!std.mem.eql(u8, self.engine.namespaceUri("xsi") orelse "", xml.XSI)) try self.engine.namespace("xsi", xml.XSI);
                try self.engine.attribute("xsi:schemaLocation", attr.value);
            } else return error.UnknownAttribute;
        } else {
            if (std.mem.indexOfScalar(u8, attr.name, ':') != null) return error.InvalidNamespace;
            try self.engine.attribute(attr.name, attr.value);
        }
    }
}

fn namespacePrefix(attr: model.Attribute) ?[]const u8 {
    if (!std.mem.eql(u8, attr.namespace_uri orelse "", xml.XMLNS_NAMESPACE)) return null;
    if (std.mem.eql(u8, attr.name, "xmlns")) return "";
    if (std.mem.startsWith(u8, attr.name, "xmlns:")) return attr.name[6..];
    return null;
}

fn startKnown(self: *Writer, name: []const u8, attrs: []const model.Attribute, root: bool) Error!void {
    var source_default: ?[]const u8 = null;
    var has_namespaces = false;
    for (attrs) |attr| if (namespacePrefix(attr)) |prefix| {
        has_namespaces = true;
        if (prefix.len == 0) source_default = attr.value;
    };
    if (source_default) |uri| {
        if (!std.mem.eql(u8, uri, self.namespace_uri)) {
            var prefix: ?[]const u8 = null;
            for (attrs) |attr| if (namespacePrefix(attr)) |candidate| {
                if (candidate.len != 0 and std.mem.eql(u8, attr.value, self.namespace_uri)) prefix = candidate;
            };
            const selected = prefix orelse return error.InvalidNamespace;
            const qualified = try self.allocator.alloc(u8, selected.len + 1 + name.len);
            defer self.allocator.free(qualified);
            @memcpy(qualified[0..selected.len], selected);
            qualified[selected.len] = ':';
            @memcpy(qualified[selected.len + 1 ..], name);
            try self.engine.startElement(qualified);
        } else try self.engine.startElement(name);
    } else {
        const declare = root or !std.mem.eql(u8, self.engine.namespaceUri("") orelse "", self.namespace_uri);
        try self.engine.startElement(name);
        if (declare) try self.engine.namespace(null, self.namespace_uri);
        if (!has_namespaces) return;
    }
    for (attrs) |attr| if (namespacePrefix(attr)) |prefix| {
        if (!std.mem.eql(u8, self.engine.namespaceUri(prefix) orelse "", attr.value))
            try self.engine.namespace(if (prefix.len == 0) null else prefix, attr.value);
    };
}

fn writeParams(self: *Writer, params: []const cv.Entry, budget: *usize) Error!void {
    for (params) |entry| {
        const extra = switch (entry) {
            .group_ref => |ref| ref.xml,
            .cv => |param| param.xml,
            .user => |param| param.xml,
        };
        const attrs = if (extra) |value| value.attributes else &.{};
        switch (entry) {
            .group_ref => |ref| {
                try self.startKnown("referenceableParamGroupRef", attrs, false);
                try self.optionalAttribute("ref", ref.ref);
            },
            .cv => |param| {
                try self.startKnown("cvParam", attrs, false);
                try self.optionalAttribute("cvRef", param.cv_ref);
                try self.optionalAttribute("accession", if (param.accession) |accession| accession.raw else null);
                try self.optionalAttribute("name", param.name);
                try self.optionalAttribute("value", param.value);
                try self.writeUnit(param.unit);
            },
            .user => |param| {
                try self.startKnown("userParam", attrs, false);
                try self.optionalAttribute("name", param.name);
                try self.optionalAttribute("value", param.value);
                try self.optionalAttribute("type", param.value_type);
                try self.writeUnit(param.unit);
            },
        }
        try self.writeAttributes(attrs);
        if (extra) |value| for (value.content) |part| switch (part) {
            .xml => |bytes| try self.writeXml(bytes, budget),
            .text => |bytes| {
                if (bytes.len > self.limits.text_bytes) return try self.limitError(.text_bytes, self.limits.text_bytes, bytes.len);
                try self.engine.text(bytes);
            },
        };
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
    /// Hashes and forwards streamed output in whole chunks; file output rereads the file instead.
    hashed: std.Io.Writer.Hashed(Sha1),
    hashed_buffer: [64 * 1024]u8 = undefined,
    arena: std.heap.ArenaAllocator,
    limits: IndexLimits,
    entries: std.ArrayList(IndexEntry) = .empty,
    historical: bool = false,
    historical_ids: std.ArrayList(struct { native_id: ?[]const u8, spot_id: ?[]const u8 }) = .empty,
    ids: [2]Ids.Map = .{ .empty, .empty },
    spectra: usize = 0,
    id_bytes: usize = 0,

    /// Releases the retained IDs and offsets and the state itself.
    fn deinit(self: *IndexState) void {
        self.entries.deinit(self.allocator);
        self.historical_ids.deinit(self.allocator);
        for (&self.ids) |*ids| ids.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn copyId(self: *IndexState, text: []const u8) Error![]const u8 {
        if (text.len > self.limits.id_bytes -| self.id_bytes) return error.LimitExceeded;
        const result = try self.arena.allocator().dupe(u8, text);
        self.id_bytes += text.len;
        return result;
    }
};
