//! Writes plain or indexed mzML without retaining records or a run. Forward-only sinks need
//! list counts up front; file output can patch unknown counts when lists close.
//!
//! Arguments are borrowed only until each call returns. The writer borrows its sink until
//! deinit, and the caller flushes and closes the sink, including after finish. Failures are
//! sticky: the first sets diagnostic() and later calls return FailedState, and partial output
//! is never a complete document. A call made while another runs, as from the sink's drain,
//! returns InvalidState and leaves the running call unharmed.

const std = @import("std");
const cv = @import("../cv/source.zig");
const base64 = @import("../binary/base64.zig");
const arrays = @import("../binary/arrays.zig");
const zlib = @import("../binary/zlib.zig");
const Sha1 = @import("../binary/sha1.zig").Sha1;
const xml = @import("../xml/mzml_adapter.zig");
const model = @import("model.zig");
const schema = @import("schema.zig");
const Diagnostic = @import("diagnostic.zig");
const Ids = @import("internal/id_index.zig").IdIndex(IndexEntry);

const Writer = @This();

/// Per call: `nodes` bounds the elements one header, record, or XML item writes (0 is
/// `InvalidOptions`); `text_bytes` bounds each single text (array text, XML fragment, parameter
/// text), not the whole output.
pub const Limits = struct { nodes: usize = 100_000, text_bytes: usize = 256 * 1024 * 1024 };

/// Indexed output: bounds on retained index entries and ID bytes (including historical
/// native/spot IDs), and the indexedmzML element's attributes.
pub const IndexOptions = struct {
    records: usize = 1_000_000,
    id_bytes: usize = 64 * 1024 * 1024,
    /// Namespaced attributes for indexedmzML, such as the index schema's `xsi:schemaLocation`,
    /// written and checked as on the mzML root; borrowed until writeHeader. None by default.
    wrapper_attributes: []const model.Attribute = &.{},
};

/// One modeled array for writeRecordWithArrays. The writer sets each written array's
/// encodedLength from the text it writes, whatever the node declares.
pub const ArrayPayload = union(enum) {
    /// Finished wire bytes, written as Base64.
    wire: []const u8,
    /// Values encoded while they are written. File output streams every source, writing a
    /// placeholder encodedLength as wide as the longest possible text and patching it after the
    /// text, so it may carry leading zeros. Other output streams sources whose length is known
    /// without encoding (primitives without zlib) or after a counting pass (Numpress without zlib),
    /// and encodes zlib sources into the source's encoder first, so a failing source writes nothing
    /// there. On file output, a source whose length is not known before encoding can stop a record
    /// midway: on a Numpress value error, or when its text turns out longer than
    /// `Limits.text_bytes`. The writer then fails as for an output error.
    source: arrays.Source,
};

pub const Error = xml.WriterError || xml.Error || cv.ValueError || arrays.EncodeError || schema.Error ||
    std.Io.File.WritePositionalError || std.Io.File.ReadPositionalError || error{
    InvalidStructure,
    MissingAttribute,
    UnknownAttribute,
    CountMismatch,
    PayloadNotRetained,
    InvalidIndex,
    InvalidState,
    LimitExceeded,
    FailedState,
    DuplicateId,
    InvalidOptions,
    TruncatedSource,
};

engine: xml.Writer,
allocator: std.mem.Allocator,
limits: Limits,
phase: enum { initial, run, list, document, done } = .initial,
failure: ?Diagnostic = null,
list_kind: ?model.Kind = null,
expected_count: usize = 0,
written_count: usize = 0,
index: ?*Index = null,
file_sink: ?*std.Io.File.Writer = null,
count_offset: ?u64 = null,
namespace_uri: []const u8 = xml.NAMESPACE,
plans: std.ArrayList(Plan) = .empty,
// Base64 length of the last streamed source, for its encodedLength patch.
source_text_length: usize = 0,
// A call is in progress; the sink's drain runs inside it and must not call the writer.
active: bool = false,

/// Call deinit even after a failure. Do not copy the writer: a copy and the original would free the
/// same storage on deinit.
pub fn init(allocator: std.mem.Allocator, sink: *std.Io.Writer, limits: Limits) error{InvalidOptions}!Writer {
    if (limits.nodes == 0) return error.InvalidOptions;
    return .{ .engine = xml.Writer.init(allocator, sink, .{}), .allocator = allocator, .limits = limits };
}

/// Writes indexedmzML, keeping each record's ID and offset (within index_options) until deinit.
pub fn initIndexed(
    allocator: std.mem.Allocator,
    sink: *std.Io.Writer,
    limits: Limits,
    index_options: IndexOptions,
) (std.mem.Allocator.Error || error{InvalidOptions})!Writer {
    if (limits.nodes == 0) return error.InvalidOptions;
    // Entry positions and ID offsets are 32 bits.
    if (index_options.records > std.math.maxInt(u32) or index_options.id_bytes > std.math.maxInt(u32))
        return error.InvalidOptions;
    for (index_options.wrapper_attributes) |attr| if (attr.namespace_uri == null) return error.InvalidOptions;
    const state = try allocator.create(Index);
    errdefer allocator.destroy(state);
    const chunk = try allocator.alloc(u8, CHUNK_BYTES);
    errdefer allocator.free(chunk);
    state.* = .{ .allocator = allocator, .hashed = .init(sink, chunk), .arena = .init(allocator), .options = index_options };
    var engine = xml.Writer.init(allocator, &state.hashed.writer, .{});
    engine.guard = sink;
    return .{ .engine = engine, .allocator = allocator, .limits = limits, .index = state };
}

/// Writes to a positional file writer at offset zero on an empty file; nothing else may write
/// through it until finish. List counts may be null. Null index_options selects plain mzML;
/// indexed output needs a readable file, whose prefix finish rereads for the checksum.
pub fn initFile(
    allocator: std.mem.Allocator,
    sink: *std.Io.File.Writer,
    limits: Limits,
    index_options: ?IndexOptions,
) (std.mem.Allocator.Error || error{InvalidOptions})!Writer {
    if (sink.logicalPos() != 0 or (sink.mode != .positional and sink.mode != .positional_simple))
        return error.InvalidOptions;
    var writer = if (index_options) |index|
        try initIndexed(allocator, &sink.interface, limits, index)
    else
        try init(allocator, &sink.interface, limits);
    writer.engine.sink = &sink.interface;
    writer.file_sink = sink;
    return writer;
}

/// Neither finishes nor flushes output.
pub fn deinit(self: *Writer) void {
    self.engine.deinit();
    self.plans.deinit(self.allocator);
    if (self.index) |state| state.deinit();
    self.* = undefined;
}

/// Returns the first failure; later FailedState returns leave it unchanged. The caller's own
/// final flush is not covered.
pub fn diagnostic(self: *const Writer) ?Diagnostic {
    return self.failure;
}

/// Returns the output position: bytes written from the document start, including indexed output
/// still in the hashing buffer, so callers can keep their own record offsets. Null after an output
/// failure.
pub fn outputPosition(self: *const Writer) ?u64 {
    return self.engine.byteOffset();
}

/// Writes the header metadata and opens the run.
pub fn writeHeader(self: *Writer, header: model.Header) Error!void {
    try self.enter();
    defer self.active = false;
    if (self.failure != null) return error.FailedState;
    errdefer |err| self.fail(err, .write_header);
    if (self.phase != .initial) return error.InvalidState;
    try schema.checkHeader(header);
    self.namespace_uri = if (std.mem.eql(u8, header.namespace_uri, xml.NAMESPACE))
        xml.NAMESPACE
    else if (std.mem.eql(u8, header.namespace_uri, xml.NAMESPACE_1_0))
        xml.NAMESPACE_1_0
    else
        return error.InvalidNamespace;
    try self.checkNode(header.document);
    try self.checkNode(header.run);
    try self.engine.startDocument();
    if (self.index) |state| {
        state.historical = std.mem.eql(u8, header.namespace_uri, xml.NAMESPACE_1_0);
        try self.checkParts(.{state.options.wrapper_attributes});
        try self.startKnown("indexedmzML", state.options.wrapper_attributes, true);
        try self.writeAttributes(state.options.wrapper_attributes);
    }
    try self.startKnown("mzML", header.document.attributes, true);
    if (self.engine.namespaceUri("xsi") == null) try self.engine.namespace("xsi", xml.XSI);
    try self.writeAttributes(header.document.attributes);
    var no_plans: []const Plan = &.{};
    var budget = self.limits.nodes;
    try self.writeContent(header.document, false, &no_plans, &budget);
    try self.startKnown("run", header.run.attributes, false);
    try self.writeAttributes(header.run.attributes);
    try self.writeContent(header.run, false, &no_plans, &budget);
    self.phase = .run;
}

/// Opens a spectrum or chromatogram list. A null count requires `initFile` (`InvalidOptions`
/// otherwise) and is filled in by `endList`; other writers require an exact count before writing
/// (a wrong count is `CountMismatch`). Spectra precede chromatograms, and each list can occur at
/// most once.
pub fn beginList(self: *Writer, kind: model.Kind, count: ?usize, processing_ref: []const u8) ListError!void {
    try self.enter();
    defer self.active = false;
    return self.openList(kind, count, &.{.{ .name = "defaultDataProcessingRef", .value = processing_ref }});
}

/// Opens a list with source attributes, writing the supplied count first in place of any
/// source count; other attributes keep their order and values, and an absent processing
/// reference stays absent. Count and list order follow beginList.
pub fn beginListWithAttributes(self: *Writer, kind: model.Kind, count: ?usize, attributes: []const model.Attribute) ListError!void {
    try self.enter();
    defer self.active = false;
    return self.openList(kind, count, attributes);
}

/// Writes a record with its retained binary text, escaped as XML; the Base64 and encodedLength
/// are not checked.
pub fn writeRecord(self: *Writer, node: model.Node) Error!void {
    try self.enter();
    defer self.active = false;
    return self.writeRecordInner(node, false, @as([]const ArrayPayload, &.{}));
}

/// Writes one forward item. List openings keep their source counts; use
/// beginListWithAttributes when filtering changes a count or leaves it unknown. Records from
/// decoded reads have no binary text; write them with writeRecordWithArrays.
pub fn writeItem(self: *Writer, item: model.Item) Error!void {
    try self.enter();
    defer self.active = false;
    if (self.failure != null) return error.FailedState;
    errdefer |err| self.fail(err, .write_item);
    switch (item) {
        .list_start => |start| try self.openList(start.kind, start.list.declared_count, start.list.attributes),
        .record => |record| try self.writeRecordInner(record.node, false, @as([]const ArrayPayload, &.{})),
        .list_end => try self.closeList(),
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

/// Writes a record with one payload per modeled array, written as Base64 in place of any
/// binary text. The array count must match; wire and source values must not share memory with
/// the output buffers (`OverlappingBuffers` otherwise).
pub fn writeRecordWithArrays(self: *Writer, node: model.Node, payloads: []const ArrayPayload) Error!void {
    try self.enter();
    defer self.active = false;
    return self.writeRecordInner(node, true, payloads);
}

/// Like writeRecordWithArrays with one choice per modeled array: null keeps that array's
/// binary text, and a payload, even an empty one, replaces it. Only supplied payloads are
/// checked.
pub fn writeRecordWithSelectedArrays(self: *Writer, node: model.Node, payloads: []const ?ArrayPayload) Error!void {
    try self.enter();
    defer self.active = false;
    return self.writeRecordInner(node, true, payloads);
}

/// Closes the active list, checking a supplied count or patching an unknown count: in the sink's
/// buffer while the count is still there, otherwise flushed and written at its file position.
/// Patching does not change the output position.
pub fn endList(self: *Writer) Error!void {
    try self.enter();
    defer self.active = false;
    return self.closeList();
}

/// Closes the run and document. Indexed stream output flushes the writer's chunk buffer
/// into the sink; indexed file output flushes and reads the checksum prefix. The caller
/// must still flush its own sink. Can succeed only once.
pub fn finish(self: *Writer) Error!void {
    try self.enter();
    defer self.active = false;
    if (self.failure != null) return error.FailedState;
    errdefer |err| self.fail(err, .finish);
    if (self.phase != .run and self.phase != .document) return error.InvalidState;
    if (self.phase == .run) try self.engine.endElement();
    try self.engine.endElement();
    if (self.index) |state| try self.writeIndex(state);
    try self.engine.endDocument();
    if (self.index != null and self.file_sink == null) try self.flushHashed(self.index.?);
    self.phase = .done;
}

// Zeros as wide as the longest usize: a count or encodedLength written before it is known,
// then patched with patchDigits.
const PLACEHOLDER = "0" ** std.fmt.comptimePrint("{d}", .{std.math.maxInt(usize)}).len;

// How one modeled array is written: its retained text, Base64 of wire bytes, or a source
// encoded while written, with its known text length or, for a patched placeholder, null and
// the placeholder's width.
const Plan = union(enum) {
    keep,
    wire: []const u8,
    source: struct { payload: arrays.Source, text_length: ?usize, width: usize = 0 },
};

fn enter(self: *Writer) error{InvalidState}!void {
    if (self.active) return error.InvalidState;
    self.active = true;
}

fn capture(self: *Writer, err: Error, stage: Diagnostic.Stage, detail: Diagnostic.Detail) void {
    if (self.failure != null) return;
    var report = Diagnostic.init(err, .write_record, stage, detail);
    if (self.engine.failure != null) {
        report.stage = .output;
        if (err == error.LimitExceeded and self.engine.frame_count == schema.MAX_DEPTH)
            report = Diagnostic.init(err, .write_record, .output, .{ .limit = .{ .name = .depth, .maximum = schema.MAX_DEPTH } });
    }
    if (self.engine.byteOffset()) |offset| report.location = .{ .output_byte = offset };
    self.failure = report;
}

fn fail(self: *Writer, err: Error, operation: Diagnostic.Operation) void {
    self.capture(err, .metadata, .none);
    self.failure.?.operation = operation;
}

fn limitError(self: *Writer, stage: Diagnostic.Stage, name: Diagnostic.Limit, maximum: usize, needed: ?usize) Error!noreturn {
    self.capture(error.LimitExceeded, stage, .{ .limit = .{ .name = name, .maximum = maximum, .needed = needed } });
    return error.LimitExceeded;
}

fn sizeError(self: *Writer, err: Error, expected: usize, actual: usize, unit: Diagnostic.SizeUnit) Error!noreturn {
    self.capture(err, .metadata, .{ .size = .{ .expected = expected, .actual = actual, .unit = unit } });
    return err;
}

fn integerAttribute(self: *Writer, node: model.Node, attribute: Diagnostic.Attribute) Error!usize {
    const value = node.attribute(attribute.xmlName()) orelse {
        self.capture(error.MissingAttribute, .metadata, .{ .attribute = attribute });
        return error.MissingAttribute;
    };
    return cv.parseInteger(usize, value) catch |err| {
        self.capture(err, .metadata, .{ .attribute = attribute });
        return @as(Error!usize, err);
    };
}

fn ioFailure(self: *Writer, err: Error) Error!noreturn {
    self.capture(err, .output, .none);
    self.failure.?.location = null;
    return err;
}

const ListError = xml.WriterError || error{ FailedState, InvalidOptions, InvalidStructure, UnknownAttribute };

fn openList(self: *Writer, kind: model.Kind, count: ?usize, attributes: []const model.Attribute) ListError!void {
    if (self.failure != null) return error.FailedState;
    errdefer |err| {
        self.fail(err, .open_list);
        self.failure.?.element = kind;
    }
    try self.checkParts(.{attributes});
    if (self.phase != .run) return error.InvalidState;
    if (kind != .spectrum_list and kind != .chromatogram_list) return error.InvalidOptions;
    if (self.list_kind == kind or self.list_kind == .chromatogram_list) return error.InvalidStructure;
    if (count == null and self.file_sink == null) return error.InvalidOptions;
    var buffer: [32]u8 = undefined;
    const text = if (count) |value| buffer[0..std.fmt.printInt(&buffer, value, 10, .lower, .{})] else PLACEHOLDER;
    try self.startKnown(kind.xmlName(), attributes, false);
    try self.engine.attribute("count", text);
    self.count_offset = if (count == null)
        (self.engine.byteOffset() orelse return error.LimitExceeded) - 1 - PLACEHOLDER.len
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

fn closeList(self: *Writer) Error!void {
    if (self.failure != null) return error.FailedState;
    errdefer |err| {
        self.fail(err, .close_list);
        if (self.failure.?.element == null) self.failure.?.element = self.list_kind;
    }
    if (self.phase != .list) return error.InvalidState;
    if (self.count_offset == null and self.written_count != self.expected_count)
        return try self.sizeError(error.CountMismatch, self.expected_count, self.written_count, .records);
    try self.engine.endElement();
    if (self.count_offset) |offset| try self.patchDigits(offset, self.written_count, PLACEHOLDER.len);
    self.phase = .run;
}

fn writeRecordInner(self: *Writer, node: model.Node, comptime replace_arrays: bool, payloads: anytype) Error!void {
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
        if (self.written_count < std.math.maxInt(usize))
            return try self.sizeError(error.CountMismatch, self.expected_count, self.written_count + 1, .records);
        return error.CountMismatch;
    }
    self.plans.clearRetainingCapacity();
    if (replace_arrays) {
        const list = node.child(.binary_data_array_list);
        const array_nodes = if (list) |value| value.children else &.{};
        if (array_nodes.len != payloads.len) return try self.sizeError(error.CountMismatch, array_nodes.len, payloads.len, .arrays);
        if (self.engine.overlapsOutput(std.mem.sliceAsBytes(payloads))) return error.OverlappingBuffers;
        try self.plans.ensureTotalCapacity(self.allocator, payloads.len);
        for (array_nodes, payloads, 0..) |array, supplied, position| {
            const payload = @as(?ArrayPayload, supplied) orelse {
                self.plans.appendAssumeCapacity(.keep);
                continue;
            };
            errdefer |err| {
                self.capture(err, .array, .none);
                self.failure.?.element = .binary_data_array;
                self.failure.?.array_position = position;
            }
            if (array.kind != .binary_data_array or array.children.len != 1 or
                array.children[0].kind != .binary) return error.InvalidStructure;
            self.plans.appendAssumeCapacity(switch (payload) {
                .wire => |wire| plan: {
                    if (self.engine.overlapsOutput(wire)) return error.OverlappingBuffers;
                    _ = try self.textLength(wire.len);
                    break :plan .{ .wire = wire };
                },
                .source => |source| try self.planSource(source, payloads),
            });
        }
    }
    const index = try self.integerAttribute(node, .index);
    if (index != self.written_count) return try self.sizeError(error.InvalidIndex, self.written_count, index, .index);
    if (self.index) |state| {
        try self.engine.text("");
        const offset = self.engine.byteOffset() orelse return error.LimitExceeded;
        if (offset > std.math.maxInt(i64)) return error.LimitExceeded;
        errdefer |err| self.capture(err, .index, .none);
        const id = node.attribute("id") orelse {
            self.capture(error.MissingAttribute, .index, .{ .attribute = .id });
            return error.MissingAttribute;
        };
        if (state.entries.items.len == state.options.records) return try self.limitError(.index, .records, state.options.records, null);
        const id_start = try self.listId(state, id);
        // Historical IDs are copied and reserved first, so they stay parallel to the entries.
        var native_id: ?[]const u8 = null;
        var spot_id: ?[]const u8 = null;
        if (state.historical) {
            if (node.attribute("nativeID")) |value| native_id = try self.copyId(state, value);
            if (node.attribute("spotID")) |value| spot_id = try self.copyId(state, value);
            try state.historical_ids.ensureUnusedCapacity(state.allocator, 1);
        }
        const ids = &state.ids[if (node.kind == .spectrum) @as(usize, 0) else 1];
        try Ids.insert(
            ids,
            state.allocator,
            &state.entries,
            state.id_list.items,
            .{ .id_start = id_start, .id_len = @intCast(id.len), .offset = offset },
        );
        if (state.historical) state.historical_ids.appendAssumeCapacity(.{ .native_id = native_id, .spot_id = spot_id });
        if (node.kind == .spectrum) state.spectra += 1;
    }
    var remaining: []const Plan = self.plans.items;
    var budget = self.limits.nodes;
    try self.writeNode(node, replace_arrays, &remaining, &budget);
    if (remaining.len != 0) return try self.sizeError(error.CountMismatch, payloads.len - remaining.len, payloads.len, .arrays);
    self.written_count += 1;
}

fn textLength(self: *Writer, wire_length: usize) Error!usize {
    const length = try base64.encodedSize(wire_length);
    if (length > self.limits.text_bytes) return try self.limitError(.array, .text_bytes, self.limits.text_bytes, length);
    return length;
}

// Decides how a source is written before any of its record is, so that on output that cannot
// be patched every length is known and every encoding error found first.
fn planSource(self: *Writer, source: arrays.Source, payloads: anytype) Error!Plan {
    try source.check();
    switch (source.values) {
        inline else => |values| if (self.engine.overlapsOutput(std.mem.sliceAsBytes(values))) return error.OverlappingBuffers,
    }
    if (source.wireSize()) |length| return .{ .source = .{ .payload = source, .text_length = try self.textLength(length) } };
    if (self.file_sink != null) {
        // The placeholder is as wide as the longest text the source could produce.
        var longest = switch (source.values) {
            inline else => |values| try arrays.wireBound(@typeInfo(@TypeOf(values)).pointer.child, values.len, source.options.pipeline),
        };
        if (source.options.pipeline.hasZlib()) longest = zlib.compressBound(longest);
        var digits: [32]u8 = undefined;
        const width = std.fmt.printInt(&digits, try base64.encodedSize(longest), 10, .lower, .{});
        return .{ .source = .{ .payload = source, .text_length = null, .width = width } };
    }
    if (!source.options.pipeline.hasZlib()) {
        var counter = std.Io.Writer.Discarding.init(&.{});
        source.writeTo(&counter.writer) catch |err| switch (err) {
            error.WriteFailed => unreachable,
            else => |e| return e,
        };
        return .{
            .source = .{
                .payload = source,
                .text_length = try self.textLength(std.math.cast(usize, counter.fullCount()) orelse return error.LimitExceeded),
            },
        };
    }
    // A wire of this record left in the slot this encode reuses (the encoder was reset after
    // making it) would be freed or overwritten before it is written.
    for (payloads) |supplied| {
        const other = @as(?ArrayPayload, supplied) orelse continue;
        if (other == .wire and source.encoder.?.reuses(other.wire)) return error.InvalidState;
    }
    const wire = try source.encoder.?.encodeSource(source);
    _ = try self.textLength(wire.len);
    return .{ .wire = wire };
}

// Streams a source as Base64 into the open binary element and records its text length.
fn writeSource(self: *Writer, source: arrays.Source) Error!void {
    try self.engine.binaryPart(&.{});
    const start = self.engine.byteOffset() orelse return error.LimitExceeded;
    if (source.options.pipeline == .none) {
        switch (source.values) {
            inline else => |values| try self.engine.binary(std.mem.sliceAsBytes(values)),
        }
    } else {
        var buffer: [3 * 4096]u8 = undefined;
        var out: Base64Out = .{ .engine = &self.engine, .writer = .{ .vtable = &Base64Out.vtable, .buffer = &buffer } };
        source.writeTo(&out.writer) catch |err| switch (err) {
            error.WriteFailed => return out.failure orelse error.WriteFailed,
            else => |e| return e,
        };
        out.writer.flush() catch return out.failure orelse error.WriteFailed;
        try self.engine.binaryEnd();
    }
    const end = self.engine.byteOffset() orelse return error.LimitExceeded;
    self.source_text_length = std.math.cast(usize, end - start) orelse return error.LimitExceeded;
    if (self.source_text_length > self.limits.text_bytes)
        return try self.limitError(.array, .text_bytes, self.limits.text_bytes, self.source_text_length);
}

// A writer that Base64-encodes everything written to it into the engine's open binary text.
const Base64Out = struct {
    writer: std.Io.Writer,
    engine: *xml.Writer,
    failure: ?xml.WriterError = null,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Base64Out = @alignCast(@fieldParentPtr("writer", w));
        self.part(w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.part(bytes) catch return error.WriteFailed;
            written += bytes.len;
        }
        for (0..splat) |_| self.part(data[data.len - 1]) catch return error.WriteFailed;
        return written + data[data.len - 1].len * splat;
    }

    fn part(self: *Base64Out, bytes: []const u8) xml.WriterError!void {
        self.engine.binaryPart(bytes) catch |err| {
            self.failure = err;
            return err;
        };
    }
};

// Writes value over its placeholder of width digits, zero-padded: in the sink's buffer when
// the placeholder is still there, otherwise at its file position.
fn patchDigits(self: *Writer, offset: u64, value: usize, width: usize) Error!void {
    var buffer: [32]u8 = undefined;
    const text = buffer[0..std.fmt.printInt(&buffer, value, 10, .lower, .{})];
    // Only an undercounted bound could overflow the placeholder.
    if (text.len > width) return error.InvalidState;
    var padded = PLACEHOLDER.*;
    const digits = padded[0..width];
    @memcpy(digits[width - text.len ..], text);
    const file = self.file_sink.?;
    const sink = &file.interface;
    const end = self.engine.byteOffset() orelse return error.LimitExceeded;
    // Bytes written to the file writer by anyone else would move every recorded offset.
    if (file.logicalPos() != end) return error.InvalidState;
    const buffered_start = end - sink.end;
    if (offset >= buffered_start) {
        @memcpy(sink.buffer[@intCast(offset - buffered_start)..][0..digits.len], digits);
        return;
    }
    sink.flush() catch |err| return try self.ioFailure(err);
    file.file.writePositionalAll(file.io, digits, offset) catch |err| return try self.ioFailure(err);
}

// Writes a written array's attributes with the encodedLength of its text: the known value, or
// a placeholder of width digits whose offset is returned. A missing encodedLength is written
// first.
fn writeArrayAttributes(self: *Writer, attrs: []const model.Attribute, text_length: ?usize, width: usize) Error!?u64 {
    var has_length = false;
    for (attrs) |attr| {
        if (attr.namespace_uri == null and std.mem.eql(u8, attr.name, "encodedLength")) has_length = true;
    }
    var placeholder: ?u64 = null;
    if (!has_length) placeholder = try self.writeEncodedLength(text_length, width);
    for (attrs) |attr| {
        if (attr.namespace_uri == null and std.mem.eql(u8, attr.name, "encodedLength")) {
            placeholder = try self.writeEncodedLength(text_length, width);
        } else try self.writeAttributes(&.{attr});
    }
    return placeholder;
}

fn writeEncodedLength(self: *Writer, text_length: ?usize, width: usize) Error!?u64 {
    var buffer: [32]u8 = undefined;
    const value = if (text_length) |length| buffer[0..std.fmt.printInt(&buffer, length, 10, .lower, .{})] else PLACEHOLDER[0..width];
    try self.engine.attribute("encodedLength", value);
    if (text_length != null) return null;
    return (self.engine.byteOffset() orelse return error.LimitExceeded) - 1 - width;
}

fn writeNode(self: *Writer, node: model.Node, comptime replace_arrays: bool, remaining: *[]const Plan, budget: *usize) Error!void {
    errdefer |err| {
        self.capture(err, .metadata, .none);
        if (self.failure.?.element == null) self.failure.?.element = node.kind;
    }
    if (budget.* == 0) return try self.limitError(.metadata, .nodes, self.limits.nodes, null);
    budget.* -= 1;
    try self.checkNode(node);
    const plan: Plan = if (replace_arrays and (node.kind == .binary or node.kind == .binary_data_array)) blk: {
        if (remaining.len == 0) return error.CountMismatch;
        break :blk remaining.*[0];
    } else .keep;
    if (node.kind == .binary) {
        if (node.params.len != 0) return error.InvalidStructure;
        if (plan == .keep and node.text == null) return error.PayloadNotRetained;
    } else if (node.text != null) return error.InvalidStructure;
    try self.startKnown(node.kind.xmlName(), node.attributes, false);
    var placeholder: ?u64 = null;
    if (node.kind == .binary_data_array and plan == .source) {
        placeholder = try self.writeArrayAttributes(node.attributes, plan.source.text_length, plan.source.width);
    } else if (node.kind == .binary_data_array and plan == .wire) {
        _ = try self.writeArrayAttributes(node.attributes, try base64.encodedSize(plan.wire.len), 0);
    } else try self.writeAttributes(node.attributes);
    if (node.kind == .binary) switch (plan) {
        .wire => |bytes| try self.engine.binary(bytes),
        .source => |source| {
            errdefer |err| {
                // As on stream output, where the counting pass finds the error while planning.
                self.capture(err, .array, .none);
                self.failure.?.element = .binary_data_array;
                self.failure.?.array_position = self.plans.items.len - remaining.len;
            }
            try self.writeSource(source.payload);
        },
        .keep => {
            const text = node.text.?;
            if (text.len > self.limits.text_bytes) return try self.limitError(.array, .text_bytes, self.limits.text_bytes, text.len);
            try self.engine.text(text);
        },
    };
    try self.writeContent(node, replace_arrays, remaining, budget);
    try self.engine.endElement();
    if (replace_arrays and node.kind == .binary_data_array) {
        if (remaining.len == 0) return error.CountMismatch;
        remaining.* = remaining.*[1..];
        if (placeholder) |offset| try self.patchDigits(offset, self.source_text_length, plan.source.width);
        // A counted length is already in the output, so the text must have matched it.
        if (plan == .source) if (plan.source.text_length) |length| if (length != self.source_text_length) return error.InvalidState;
    }
}

fn writeContent(self: *Writer, node: model.Node, comptime replace_arrays: bool, remaining: *[]const Plan, budget: *usize) Error!void {
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

fn writeChild(
    self: *Writer,
    parent: model.Node,
    child: model.Node,
    position: usize,
    seen: *std.EnumSet(model.Kind),
    comptime replace_arrays: bool,
    remaining: *[]const Plan,
    budget: *usize,
) Error!void {
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
    if (bytes.len > self.limits.text_bytes) return try self.limitError(.metadata, .text_bytes, self.limits.text_bytes, bytes.len);
    var input = std.Io.Reader.fixed(bytes);
    var cursor = try xml.Cursor.init(self.allocator, &input, @max(1, bytes.len / 4), self.limits.text_bytes);
    defer cursor.deinit();
    errdefer |err| {
        const detail: Diagnostic.Detail = if (cursor.limit_failure == .nodes)
            .{ .limit = .{ .name = .nodes, .maximum = self.limits.nodes } }
        else
            Diagnostic.xmlDetail(&cursor);
        self.capture(err, .xml, detail);
        if (self.engine.failure == null) self.failure.?.location = null;
    }
    try cursor.advanceFragment(true);
    if (cursor.current == null or cursor.current.?.data != .start_element) return error.InvalidStructure;
    try cursor.writeElement(&self.engine, budget);
    try cursor.advanceFragment(false);
    if (cursor.current != null) return error.InvalidStructure;
}

fn writeAttributes(self: *Writer, attrs: []const model.Attribute) !void {
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

fn startKnown(self: *Writer, name: []const u8, attrs: []const model.Attribute, root: bool) !void {
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
            var fallback = std.heap.stackFallback(128, self.allocator);
            const allocator = fallback.get();
            const qualified = try allocator.alloc(u8, selected.len + 1 + name.len);
            defer allocator.free(qualified);
            @memcpy(qualified[0..selected.len], selected);
            qualified[selected.len] = ':';
            @memcpy(qualified[selected.len + 1 ..], name);
            try self.engine.startElement(qualified);
        } else try self.engine.startElementTrusted(name);
    } else {
        const declare = root or !std.mem.eql(u8, self.engine.namespaceUri("") orelse "", self.namespace_uri);
        try self.engine.startElementTrusted(name);
        if (declare) try self.engine.namespace(null, self.namespace_uri);
        if (!has_namespaces) return;
    }
    for (attrs) |attr| if (namespacePrefix(attr)) |prefix| {
        if (!std.mem.eql(u8, self.engine.namespaceUri(prefix) orelse "", attr.value))
            try self.engine.namespace(if (prefix.len == 0) null else prefix, attr.value);
    };
}

// A node's arrays are read while its earlier parts are written, so like the strings (checked
// by the XML writer) they must not live in the output buffers.
fn checkNode(self: *Writer, node: model.Node) Error!void {
    try self.checkParts(.{ node.attributes, node.params, node.children });
    if (node.content) |content| try self.checkParts(.{ std.mem.asBytes(content), content.items });
}

fn checkParts(self: *Writer, parts: anytype) !void {
    inline for (parts) |part| {
        if (self.engine.overlapsOutput(std.mem.sliceAsBytes(part))) return error.OverlappingBuffers;
    }
}

fn writeParams(self: *Writer, params: []const cv.Entry, budget: *usize) Error!void {
    for (params) |entry| {
        const extra = switch (entry) {
            .group_ref => |ref| ref.xml,
            .cv => |param| param.xml,
            .user => |param| param.xml,
        };
        if (extra) |value| try self.checkParts(.{ std.mem.asBytes(value), value.attributes, value.content });
        const attrs = if (extra) |value| value.attributes else &.{};
        const record = attrs.len != 0;
        switch (entry) {
            .group_ref => |ref| {
                try self.startKnown("referenceableParamGroupRef", attrs, false);
                try self.optionalAttribute("ref", ref.ref, record);
            },
            .cv => |param| {
                try self.startKnown("cvParam", attrs, false);
                try self.optionalAttribute("cvRef", param.cv_ref, record);
                try self.optionalAttribute("accession", if (param.accession) |accession| accession.raw else null, record);
                try self.optionalAttribute("name", param.name, record);
                try self.optionalAttribute("value", param.value, record);
                try self.writeUnit(param.unit, record);
            },
            .user => |param| {
                try self.startKnown("userParam", attrs, false);
                try self.optionalAttribute("name", param.name, record);
                try self.optionalAttribute("value", param.value, record);
                try self.optionalAttribute("type", param.value_type, record);
                try self.writeUnit(param.unit, record);
            },
        }
        try self.writeAttributes(attrs);
        if (extra) |value| for (value.content) |part| switch (part) {
            .xml => |bytes| try self.writeXml(bytes, budget),
            .text => |bytes| {
                if (bytes.len > self.limits.text_bytes)
                    return try self.limitError(.metadata, .text_bytes, self.limits.text_bytes, bytes.len);
                try self.engine.text(bytes);
            },
        };
        try self.engine.endElement();
    }
}

fn writeUnit(self: *Writer, unit: cv.Unit, record: bool) Error!void {
    try self.optionalAttribute("unitCvRef", unit.cv_ref, record);
    try self.optionalAttribute("unitAccession", if (unit.accession) |a| a.raw else null, record);
    try self.optionalAttribute("unitName", unit.name, record);
}

// The fixed fields of parameters and units, written before any of the parameter's own XML
// attributes; record when such attributes follow, so a repeated name is a duplicate.
fn optionalAttribute(self: *Writer, name: []const u8, value: ?[]const u8, record: bool) Error!void {
    if (value) |text| try self.engine.attributeTrusted(name, text, record);
}

// Copies a record's ID into the index's ID list and returns where it starts.
fn listId(self: *Writer, state: *Index, id: []const u8) Error!u32 {
    try self.chargeId(state, id.len);
    const start = state.id_list.items.len;
    state.id_list.appendSlice(state.allocator, id) catch |err| {
        self.capture(err, .index, .none);
        return err;
    };
    state.id_bytes += id.len;
    return @intCast(start);
}

fn copyId(self: *Writer, state: *Index, id: []const u8) Error![]const u8 {
    try self.chargeId(state, id.len);
    const result = state.arena.allocator().dupe(u8, id) catch |err| {
        self.capture(err, .index, .none);
        return err;
    };
    state.id_bytes += id.len;
    return result;
}

fn chargeId(self: *Writer, state: *Index, length: usize) Error!void {
    if (length > state.options.id_bytes -| state.id_bytes)
        return try self.limitError(.index, .id_bytes, state.options.id_bytes, state.id_bytes +| length);
}

// Buffered bytes that fail to reach the sink have no accepted output position.
fn flushHashed(self: *Writer, state: *Index) Error!void {
    state.hashed.writer.flush() catch {
        self.capture(error.WriteFailed, .output, .none);
        self.failure.?.location = null;
        return error.WriteFailed;
    };
}

fn writeIndex(self: *Writer, state: *Index) Error!void {
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
                try self.engine.attribute("idRef", Ids.idOf(entry, state.id_list.items));
                if (state.historical) {
                    try self.optionalAttribute("nativeID", state.historical_ids.items[i].native_id, false);
                    try self.optionalAttribute("spotID", state.historical_ids.items[i].spot_id, false);
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
        // File output bypasses the hashed writer, so its idle buffer holds each read.
        const buffer = state.hashed.writer.buffer;
        var position: u64 = 0;
        while (position < end) {
            const capacity: usize = @intCast(@min(buffer.len, end - position));
            const length = sink.file.readPositional(sink.io, &.{buffer[0..capacity]}, position) catch |err| return try self.ioFailure(err);
            if (length == 0) return try self.ioFailure(error.TruncatedSource);
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

const IndexEntry = struct { id_start: u32, id_len: u32, offset: u64 };

// Indexed stream output is hashed and forwarded, and file output reread, in chunks of this
// size. Rewrite time was flat from 8 to 256 KiB; 16 KiB kept peak RSS at the unhashed level.
const CHUNK_BYTES = 16 * 1024;

const Index = struct {
    allocator: std.mem.Allocator,
    // Hashes and forwards streamed output in whole chunks; file output rereads the file instead.
    hashed: std.Io.Writer.Hashed(Sha1),
    arena: std.heap.ArenaAllocator,
    options: IndexOptions,
    entries: std.ArrayList(IndexEntry) = .empty,
    id_list: std.ArrayList(u8) = .empty,
    historical: bool = false,
    historical_ids: std.ArrayList(struct { native_id: ?[]const u8, spot_id: ?[]const u8 }) = .empty,
    ids: [2]Ids.Map = .{ .empty, .empty },
    spectra: usize = 0,
    id_bytes: usize = 0,

    fn deinit(self: *Index) void {
        self.entries.deinit(self.allocator);
        self.id_list.deinit(self.allocator);
        self.historical_ids.deinit(self.allocator);
        for (&self.ids) |*ids| ids.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.free(self.hashed.writer.buffer);
        self.allocator.destroy(self);
    }
};
