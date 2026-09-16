//! Implements forward mzML reading and the private fragment operations used by indexing.

const std = @import("std");
const cv = @import("../../cv/source.zig");
const model = @import("../model.zig");
const schema = @import("../schema.zig");
const xml = @import("../../xml/mzml_adapter.zig");
const owned = @import("../owned.zig");
const DecodedArrays = @import("../decoded_arrays.zig");

const StreamReader = @This();

const ELEMENT_KINDS = std.StaticStringMap(model.Kind).initComptime(blk: {
    const kinds = std.meta.tags(model.Kind);
    var entries: [kinds.len]struct { []const u8, model.Kind } = undefined;
    for (kinds, &entries) |value, *entry| entry.* = .{ value.xmlName(), value };
    break :blk entries;
});

const ParamAttributes = struct {
    ref: ?[]const u8 = null,
    cv_ref: ?[]const u8 = null,
    accession: ?[]const u8 = null,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    value_type: ?[]const u8 = null,
    unit_cv_ref: ?[]const u8 = null,
    unit_accession: ?[]const u8 = null,
    unit_name: ?[]const u8 = null,
};
const PARAM_ATTRIBUTES = std.StaticStringMap(std.meta.FieldEnum(ParamAttributes)).initComptime(.{
    .{ "ref", .ref },               .{ "cvRef", .cv_ref },                 .{ "accession", .accession },
    .{ "name", .name },             .{ "value", .value },                  .{ "type", .value_type },
    .{ "unitCvRef", .unit_cv_ref }, .{ "unitAccession", .unit_accession }, .{ "unitName", .unit_name },
});

/// Independent bounds on parser state, retained objects, lists, and payload text.
/// Retained-byte limits count stored slices, not allocator bookkeeping or temporary list capacity.
pub const Limits = struct {
    depth: usize = 64,
    attributes: usize = 64,
    attribute_bytes: usize = 1024 * 1024,
    header_bytes: usize = 32 * 1024 * 1024,
    record_bytes: usize = 256 * 1024 * 1024,
    nodes: usize = 100_000,
    list_entries: usize = 100_000,
    binary_text_bytes: usize = 256 * 1024 * 1024,
};

/// Retention does not decode arrays. Skip checks XML; checked mode also checks encodedLength.
pub const Payload = enum { retain, skip };

/// Chooses text retention after an array's leading parameters and before its binary text.
/// The callback receives its zero-based array position within the record, source attributes,
/// and unexpanded parameters. All slices borrow only for the call. Keep user_data valid
/// while reading; it can hold header groups. Do not reenter the reader. Later checks can fail.
pub const ArraySelector = struct {
    user_data: ?*anyopaque = null,
    select: *const fn (?*anyopaque, usize, []const model.Attribute, []const cv.Entry) Payload,
};

/// Checked is the default. Minimal preserves valid mzML metadata but skips namespace resolution,
/// nested child cardinalities/order, parameter order and group-reference placement,
/// numeric schema ranges, and length/count
/// comparisons. XML parsing, required attributes, envelope order, and resource limits remain.
/// In minimal mode, a prefixed schemaLocation is treated as XSI without resolving its prefix;
/// other prefixed attributes fail. Unrecognized unprefixed node attributes remain retained.
pub const Checks = enum { checked, minimal };

pub const Options = struct {
    limits: Limits = .{},
    payload: Payload = .retain,
    /// Selects retained arrays without dropping metadata. Ignored when payload is skip.
    /// Does not classify encodings or resolve parameters on the caller's behalf.
    array_selector: ?ArraySelector = null,
    checks: Checks = .checked,
    /// False preserves mismatched source counts.
    /// Ignored in minimal mode, which skips count comparisons and nested cardinalities.
    check_counts: bool = true,
    /// Retains the index trailer within header limits for StreamReader.indexTrailer().
    retain_index: bool = false,
};

/// Structural and resource failures, distinct from errors returned by explicit array decoding.
pub const Error = xml.Error || cv.ValueError || std.mem.Allocator.Error || error{
    InvalidStructure,
    MissingAttribute,
    UnknownAttribute,
    CountMismatch,
    EncodedLengthMismatch,
    FailedState,
    InvalidOptions,
};

/// A failure location in physical bytes. Element identity is present when known.
pub const Diagnostic = struct { code: Error, byte_offset: u64, element: ?model.Kind };

allocator: std.mem.Allocator,
cursor: xml.Cursor,
options: Options,
header_store: Storage,
record_store: Storage,
header: model.Header = undefined,
header_ready: bool = false,
done: bool = false,
failure: ?Diagnostic = null,
active_list: ?model.Kind = null,
run_sequence: schema.Sequence = .{ .rules = schema.children(.run) },
current_kind: ?model.Kind = null,
index_trailer: [3]model.Node = undefined,
scopes: [3]Scope = undefined,
scope_count: usize = 0,
list_scopes: [2]?Scope = .{ null, null },
child_scratch: std.ArrayList(model.Node) = .empty,
param_scratch: std.ArrayList(cv.Entry) = .empty,
decoded_arrays: ?*DecodedArrays = null,
index_visitor: ?IndexVisitor = null,

pub const Scope = struct { start: u64, end: u64, name: []const u8 };

pub const IndexVisitor = struct {
    user_data: *anyopaque,
    index_start: u64 = 0,
    visit: *const fn (*anyopaque, u64, model.Node) void,
};

/// Borrows input for the reader's lifetime. Input and initialized reader must not be copied.
/// This allocates parser state but does not consume input. Release all owned storage with deinit.
/// Streaming input needs buffer capacity for peekGreedy(1); otherwise init returns InvalidOptions.
/// Empty fixed readers are valid inputs and report malformed XML when read.
pub fn init(allocator: std.mem.Allocator, input: *std.Io.Reader, options: Options) Error!StreamReader {
    if (options.limits.depth == 0 or options.limits.depth > 64 or options.limits.nodes == 0 or
        options.limits.list_entries == 0) return error.InvalidOptions;
    if (input.buffer.len == 0 and input.vtable != std.Io.Reader.ending.vtable)
        return error.InvalidOptions;
    return .{
        .allocator = allocator,
        .cursor = try xml.Cursor.init(allocator, input, options.limits.depth, options.limits.attributes, options.limits.attribute_bytes, options.checks == .checked),
        .options = options,
        .header_store = Storage.init(allocator, options.limits.header_bytes),
        .record_store = Storage.init(allocator, options.limits.record_bytes),
    };
}

/// Releases parser, metadata, and record storage. Does not close or deinitialize input.
pub fn deinit(self: *StreamReader) void {
    self.cursor.deinit();
    self.child_scratch.deinit(self.allocator);
    self.param_scratch.deinit(self.allocator);
    self.header_store.arena.deinit();
    self.record_store.arena.deinit();
    self.* = undefined;
}

/// Returns header metadata before the first record. Repeated calls do not advance the source.
/// Metadata slices last until deinit; streaming list observations update as records are consumed.
pub fn readHeader(self: *StreamReader) Error!*const model.Header {
    if (self.failure != null) return error.FailedState;
    if (!self.header_ready) self.readHeaderInner() catch |err| return self.fail(err);
    return &self.header;
}

/// Returns a borrowed spectrum or chromatogram, or null after checking the document end.
/// Every call invalidates the previous record, including its encoded payload. Failures are sticky.
/// Indexed wrappers can be traversed, but index targets and checksums are not verified.
pub fn nextRecord(self: *StreamReader) Error!?model.Record {
    if (self.failure != null) return error.FailedState;
    _ = try self.readHeader();
    self.record_store.reset();
    if (self.done) return null;
    return self.nextRecordInner() catch |err| return self.fail(err);
}

pub fn nextDecodedRecord(self: *StreamReader, output: *DecodedArrays) (Error || DecodedArrays.Error)!?model.Record {
    output.reset();
    errdefer output.reset();
    if (self.options.checks != .checked or self.options.array_selector != null)
        return error.InvalidOptions;
    self.decoded_arrays = output;
    defer self.decoded_arrays = null;
    const record = try self.nextRecord() orelse return null;
    try output.complete();
    return record;
}

/// Returns the first failure without borrowing parser event memory.
pub fn diagnostic(self: *const StreamReader) ?Diagnostic {
    return self.failure;
}

fn captureScope(self: *StreamReader) Error!Scope {
    const event = self.cursor.current orelse return error.UnexpectedEnd;
    return .{ .start = event.span.start, .end = event.span.end, .name = try self.header_store.copy(u8, event.data.start_element.name.raw) };
}

/// Internal indexed-read entry point. The synthetic ancestor prefix is followed by one
/// complete record; returned offsets refer to physical_start in the original source.
pub fn parseFragment(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: Options,
    ancestors: usize,
    physical_start: u64,
    prefix_length: usize,
) Error!owned.Record {
    if (prefix_length > bytes.len) return error.InvalidOptions;
    var input = std.Io.Reader.fixed(bytes);
    var reader = try init(allocator, &input, options);
    defer reader.deinit();
    return reader.readFragment(allocator, &input, ancestors, physical_start, prefix_length, true);
}

/// Internal reusable fragment reader. Returned records use the requested allocator;
/// parser and list scratch remain owned by this reader. No source bytes remain borrowed.
pub fn readFragment(self: *StreamReader, allocator: std.mem.Allocator, input: *std.Io.Reader, ancestors: usize, physical_start: u64, prefix_length: usize, complete: bool) Error!owned.Record {
    if (self.header_ready or ancestors > 4 or physical_start < prefix_length) return error.InvalidOptions;
    try self.cursor.reset(input);
    defer self.cursor.resetEmpty();
    self.record_store.arena.deinit();
    self.record_store = Storage.init(allocator, self.options.limits.record_bytes);
    defer {
        self.record_store.arena.deinit();
        self.record_store = Storage.init(self.allocator, self.options.limits.record_bytes);
    }
    try self.cursor.advance(false);
    for (0..ancestors) |_| {
        if ((self.cursor.current orelse return error.UnexpectedEnd).data != .start_element)
            return error.InvalidStructure;
        try self.cursor.advance(false);
    }
    const kind_value = try self.kind();
    if (kind_value != .spectrum and kind_value != .chromatogram) return error.InvalidStructure;
    var node = try self.parseNode(&self.record_store, 1, complete, self.options.payload);
    if (complete) {
        for (0..ancestors) |_| {
            if ((self.cursor.current orelse return error.UnexpectedEnd).data != .end_element)
                return error.InvalidStructure;
            try self.cursor.advance(false);
        }
        if (self.cursor.current != null) return error.InvalidStructure;
    }
    try shiftOffsets(&node, physical_start - prefix_length);
    const record: model.Record = .{ .node = node, .id = node.attribute("id").?, .index = try cv.parseInteger(usize, node.attribute("index")), .default_array_length = try cv.parseInteger(usize, node.attribute("defaultArrayLength")) };
    const arena = self.record_store.arena;
    self.record_store.arena = .init(allocator);
    return .{ .arena = arena, .value = record };
}

/// Internal owner for parsed indexed-wrapper children. Release its arena once.
pub const ParsedFooter = struct {
    arena: std.heap.ArenaAllocator,
    nodes: [2]model.Node,
};

/// Internal footer parser. Bytes start with the original indexed-wrapper opening,
/// followed by the index offset, checksum, wrapper closing tag, and EOF.
pub fn parseFooter(allocator: std.mem.Allocator, bytes: []const u8, options: Options, physical_start: u64, prefix_length: usize) Error!ParsedFooter {
    if (physical_start < prefix_length) return error.InvalidOptions;
    var input = std.Io.Reader.fixed(bytes);
    var reader = try init(allocator, &input, options);
    defer reader.deinit();
    try reader.cursor.advance(false);
    if (try reader.kind() != .indexed_mzml) return error.InvalidStructure;
    try reader.cursor.advance(false);
    var nodes: [2]model.Node = .{ .{ .kind = .index_list_offset }, .{ .kind = .file_checksum } };
    for (&nodes) |*node| {
        if (try reader.kind() != node.kind) return error.InvalidStructure;
        node.* = try reader.parseNode(&reader.header_store, 1, true, reader.options.payload);
        try shiftOffsets(node, physical_start - prefix_length);
    }
    try reader.consumeEnd(.indexed_mzml, true);
    if (reader.cursor.current != null) return error.InvalidStructure;
    const arena = reader.header_store.arena;
    reader.header_store.arena = .init(allocator);
    return .{ .arena = arena, .nodes = nodes };
}

/// Internal seek operation used to locate a chromatogram-list opening after the
/// final indexed spectrum. The caller supplies original ancestors and source bytes.
pub fn resumeFollowingList(self: *StreamReader, input: *std.Io.Reader, ancestors: usize, physical_start: u64, prefix_length: usize) Error!void {
    if (self.active_list != .spectrum_list or
        ancestors != self.scope_count + 1 or physical_start < prefix_length) return error.InvalidOptions;
    const replacement = try xml.Cursor.init(self.allocator, input, self.options.limits.depth, self.options.limits.attributes, self.options.limits.attribute_bytes, self.options.checks == .checked);
    self.cursor.deinit();
    self.cursor = replacement;
    try self.cursor.advance(false);
    for (0..ancestors) |_| {
        if ((self.cursor.current orelse return error.UnexpectedEnd).data != .start_element) return error.InvalidStructure;
        try self.cursor.advance(false);
    }
    if (try self.kind() != .spectrum) return error.InvalidStructure;
    try self.cursor.skip();
    try self.consumeEnd(.spectrum_list, true);
    self.active_list = null;
    try self.openListInner(false);
    if (self.active_list != .chromatogram_list) return error.InvalidStructure;
    const scope = &self.list_scopes[1].?;
    scope.start = std.math.add(u64, scope.start, physical_start - prefix_length) catch return error.LimitExceeded;
    scope.end = std.math.add(u64, scope.end, physical_start - prefix_length) catch return error.LimitExceeded;
}

/// Internal indexed-open operation for an empty spectrum list preceding chromatograms.
pub fn finishEmptySpectrumList(self: *StreamReader) Error!void {
    if (self.active_list != .spectrum_list or
        self.header.spectrum_list.?.declared_count != 0) return error.InvalidOptions;
    try self.consumeEnd(.spectrum_list, true);
    self.active_list = null;
    try self.openListInner(false);
    if (self.active_list != .chromatogram_list) return error.InvalidStructure;
}

fn shiftOffsets(node: *model.Node, delta: u64) Error!void {
    node.start_offset = std.math.add(u64, node.start_offset, delta) catch return error.LimitExceeded;
    node.content_offset = std.math.add(u64, node.content_offset, delta) catch return error.LimitExceeded;
    node.end_offset = std.math.add(u64, node.end_offset, delta) catch return error.LimitExceeded;
    for (@constCast(node.children)) |*child| try shiftOffsets(child, delta);
}

fn fail(self: *StreamReader, err: Error) Error {
    self.failure = .{ .code = err, .byte_offset = self.cursor.offset, .element = self.current_kind };
    return err;
}

fn readHeaderInner(self: *StreamReader) Error!void {
    try self.cursor.advance(false);
    var indexed = false;
    if (try self.kind() == .indexed_mzml) {
        indexed = true;
        self.scopes[self.scope_count] = try self.captureScope();
        self.scope_count += 1;
        try self.cursor.advance(false);
    }
    if (try self.kind() != .mzml) return error.InvalidStructure;
    self.scopes[self.scope_count] = try self.captureScope();
    self.scope_count += 1;
    var document = try self.startNode(&self.header_store, .mzml);
    if (!std.mem.eql(u8, document.attribute("version").?, "1.1.0"))
        return error.UnsupportedVersion;
    try self.cursor.advance(false);
    var sequence: schema.Sequence = .{ .rules = schema.children(.mzml) };
    var metadata: std.ArrayList(model.Node) = .empty;
    defer metadata.deinit(self.allocator);
    try metadata.ensureTotalCapacity(self.allocator, sequence.rules.len - 1);
    while (true) {
        const kind_value = try self.kind();
        try sequence.accept(kind_value);
        if (kind_value == .run) break;
        try metadata.append(self.allocator, try self.parseNode(&self.header_store, 1, true, self.options.payload));
    }
    try sequence.finish();
    document.children = try self.header_store.copy(model.Node, metadata.items);
    var run = try self.startNode(&self.header_store, .run);
    self.scopes[self.scope_count] = try self.captureScope();
    self.scope_count += 1;
    try self.cursor.advance(false);
    run.params = try self.parseParams(&self.header_store, true);
    const group_list = document.child(.referenceable_param_group_list);
    const group_nodes = if (group_list) |list| list.children else &.{};
    const groups = try self.header_store.alloc(cv.Group, group_nodes.len);
    for (group_nodes, groups) |node, *group| {
        group.* = .{ .id = node.attribute("id").?, .entries = node.params };
    }
    self.header = .{ .document = document, .run = run, .groups = groups, .indexed = indexed };
    self.header_ready = true;
    try self.openList();
}

fn openList(self: *StreamReader) Error!void {
    return self.openListInner(true);
}

fn openListInner(self: *StreamReader, advance: bool) Error!void {
    const event = self.cursor.current orelse return error.UnexpectedEnd;
    if (event.data == .end_element) return;
    const kind_value = try self.kind();
    try self.run_sequence.accept(kind_value);
    const node = try self.startNode(&self.header_store, kind_value);
    const list: model.RecordList = .{
        .attributes = node.attributes,
        .declared_count = try cv.parseInteger(usize, node.attribute("count")),
    };
    switch (kind_value) {
        .spectrum_list => self.header.spectrum_list = list,
        .chromatogram_list => self.header.chromatogram_list = list,
        else => return error.InvalidStructure,
    }
    self.active_list = kind_value;
    self.list_scopes[if (kind_value == .spectrum_list) @as(usize, 0) else 1] = try self.captureScope();
    if (advance) try self.cursor.advance(false);
}

fn nextRecordInner(self: *StreamReader) Error!?model.Record {
    while (self.active_list) |list_kind| {
        const event = self.cursor.current orelse return error.UnexpectedEnd;
        const list = if (list_kind == .spectrum_list) &self.header.spectrum_list.? else &self.header.chromatogram_list.?;
        if (event.data == .end_element) {
            self.current_kind = list_kind;
            if (self.options.checks == .checked and list_kind == .chromatogram_list and list.observed_count == 0)
                return error.InvalidStructure;
            if (self.options.checks == .checked and self.options.check_counts and list.observed_count != list.declared_count)
                return error.CountMismatch;
            self.active_list = null;
            try self.cursor.advance(false);
            try self.openList();
            continue;
        }
        const expected: model.Kind = if (list_kind == .spectrum_list) .spectrum else .chromatogram;
        if (try self.kind() != expected) return error.InvalidStructure;
        const node = try self.parseNode(&self.record_store, 1, true, self.options.payload);
        list.observed_count = std.math.add(usize, list.observed_count, 1) catch
            return error.LimitExceeded;
        return .{
            .node = node,
            .id = node.attribute("id").?,
            .index = try cv.parseInteger(usize, node.attribute("index")),
            .default_array_length = try cv.parseInteger(usize, node.attribute("defaultArrayLength")),
        };
    }
    try self.run_sequence.finish();
    try self.consumeEnd(.run, true);
    try self.consumeEnd(.mzml, true);
    if (self.header.indexed) {
        if (self.index_visitor) |*visitor|
            visitor.index_start = (self.cursor.current orelse return error.UnexpectedEnd).span.start;
        inline for (.{ model.Kind.index_list, .index_list_offset, .file_checksum }, 0..) |expected, i| {
            if (try self.kind() != expected) return error.InvalidStructure;
            if (self.options.retain_index) {
                self.index_trailer[i] = try self.parseNode(&self.header_store, 1, true, self.options.payload);
            } else try self.cursor.skip();
        }
        try self.consumeEnd(.indexed_mzml, true);
    }
    if (self.cursor.current != null) return error.InvalidStructure;
    self.done = true;
    return null;
}

fn consumeEnd(self: *StreamReader, kind_value: model.Kind, advance: bool) Error!void {
    const event = self.cursor.current orelse return error.UnexpectedEnd;
    if (event.data != .end_element or
        !std.mem.eql(u8, xml.localName(event.data.end_element.name), kind_value.xmlName()))
        return error.InvalidStructure;
    if (kind_value == .run) self.header.run.end_offset = event.span.end;
    if (kind_value == .mzml) self.header.document.end_offset = event.span.end;
    if (advance) try self.cursor.advance(false);
}

fn kind(self: *StreamReader) Error!model.Kind {
    const event = self.cursor.current orelse return error.UnexpectedEnd;
    if (event.data != .start_element) return error.InvalidStructure;
    // Cursor.advance checks start namespaces in checked mode; the XML cursor matches closing tags.
    const name = xml.localName(event.data.start_element.name);
    const value = ELEMENT_KINDS.get(name) orelse return error.InvalidStructure;
    self.current_kind = value;
    return value;
}

fn startNode(self: *StreamReader, storage: *Storage, kind_value: model.Kind) Error!model.Node {
    if (storage.nodes == self.options.limits.nodes) return error.LimitExceeded;
    storage.nodes += 1;
    const event = self.cursor.current orelse return error.UnexpectedEnd;
    const attributes = try self.copyAttributes(
        storage,
        event.data.start_element,
        schema.requiredAttributes(kind_value),
        schema.optionalAttributes(kind_value),
    );
    const node: model.Node = .{
        .kind = kind_value,
        .attributes = attributes,
        .start_offset = event.span.start,
        .content_offset = event.span.end,
    };
    if (self.options.checks == .checked) {
        try schema.checkNumericAttributes(node);
        if (node.attribute("count")) |value| {
            const count = try cv.parseInteger(usize, value);
            if (kind_value != .spectrum_list and kind_value != .chromatogram_list and
                count > self.options.limits.list_entries) return error.LimitExceeded;
        }
    }
    return node;
}

fn parseNode(self: *StreamReader, storage: *Storage, depth: usize, advance_after: bool, payload: Payload) Error!model.Node {
    if (depth > self.options.limits.depth) return error.LimitExceeded;
    const kind_value = try self.kind();
    var node = try self.startNode(storage, kind_value);
    if (storage == &self.record_store and depth == 1) {
        if (self.decoded_arrays) |output| output.startRecord(node);
    }
    const has_text = kind_value == .binary or kind_value == .offset or kind_value == .index_list_offset or kind_value == .file_checksum;
    try self.cursor.advance(has_text);
    if (has_text) {
        var text: std.ArrayList(u8) = .empty;
        var text_size: usize = 0;
        var significant: usize = 0;
        while (self.cursor.current) |event| {
            if (event.data != .text) break;
            const bytes = event.data.text.bytes;
            text_size = std.math.add(usize, text_size, bytes.len) catch return error.LimitExceeded;
            if (text_size > self.options.limits.binary_text_bytes) return error.LimitExceeded;
            if (self.options.checks == .checked) significant += significantLength(bytes);
            if (kind_value == .binary and storage == &self.record_store) {
                if (self.decoded_arrays) |output| output.text(bytes);
            }
            if (payload == .retain or kind_value != .binary) {
                if (text_size > storage.limit -| storage.used) return error.LimitExceeded;
                try text.appendSlice(storage.arena.allocator(), bytes);
            }
            try self.cursor.advance(true);
        }
        if (payload == .retain or kind_value != .binary) {
            storage.used += text.items.len;
            node.text = text.items;
        }
        // The parent uses this count before returning the source span to the caller.
        storage.last_binary_length = significant;
        if (kind_value == .binary and storage == &self.record_store) {
            if (self.decoded_arrays) |output| output.finishArray();
        }
    } else if (kind_value == .index and self.index_visitor != null) {
        try self.parseIndexOffsets(storage, depth, node);
    } else {
        if (schema.hasParams(kind_value))
            node.params = try self.parseParams(storage, kind_value != .referenceable_param_group);
        var child_payload = payload;
        if (kind_value == .binary_data_array and storage == &self.record_store) {
            if (self.decoded_arrays) |output| {
                output.beginArray(node, self.header.groups);
                child_payload = .skip;
            }
        }
        if (kind_value == .binary_data_array and storage == &self.record_store and self.options.payload == .retain) {
            if (self.options.array_selector) |selector| {
                const position = storage.arrays;
                storage.arrays += 1;
                child_payload = selector.select(selector.user_data, position, node.attributes, node.params);
            }
        }
        var sequence: schema.Sequence = .{ .rules = schema.children(kind_value) };
        const children_start = self.child_scratch.items.len;
        defer self.child_scratch.shrinkRetainingCapacity(children_start);
        const capacity = if (self.options.checks == .checked)
            (if (node.attribute("count")) |value| try cv.parseInteger(usize, value) else 4)
        else
            4;
        if (sequence.rules.len != 0)
            try self.child_scratch.ensureUnusedCapacity(self.allocator, @min(
                capacity,
                self.options.limits.list_entries,
                (storage.limit -| storage.used) / @sizeOf(model.Node),
            ));
        while (self.cursor.current) |event| {
            if (event.data == .end_element) break;
            const child_kind = try self.kind();
            if (self.options.checks == .checked) try sequence.accept(child_kind);
            if (self.child_scratch.items.len - children_start == self.options.limits.list_entries) return error.LimitExceeded;
            const child = try self.parseNode(storage, depth + 1, true, child_payload);
            try self.child_scratch.append(self.allocator, child);
        }
        if (self.options.checks == .checked) try sequence.finish();
        self.current_kind = kind_value;
        if (self.options.checks == .checked and self.options.check_counts) {
            if (try node.declaredCount()) |count| {
                if (count != self.child_scratch.items.len - children_start) return error.CountMismatch;
            }
        }
        node.children = try storage.copy(model.Node, self.child_scratch.items[children_start..]);
        if (self.options.checks == .checked and kind_value == .binary_data_array and
            try cv.parseInteger(usize, node.attribute("encodedLength")) != storage.last_binary_length)
            return error.EncodedLengthMismatch;
    }
    const end = self.cursor.current orelse return error.UnexpectedEnd;
    node.end_offset = end.span.end;
    try self.consumeEnd(kind_value, advance_after);
    return node;
}

fn parseIndexOffsets(self: *StreamReader, storage: *Storage, depth: usize, node: model.Node) Error!void {
    const visitor = self.index_visitor.?;
    visitor.visit(visitor.user_data, visitor.index_start, node);
    var offsets = Storage.init(self.allocator, storage.limit);
    defer offsets.arena.deinit();
    offsets.used = storage.used;
    offsets.nodes = storage.nodes;
    var sequence: schema.Sequence = .{ .rules = schema.children(.index) };
    var count: usize = 0;
    while (self.cursor.current) |event| {
        if (event.data == .end_element) break;
        try sequence.accept(try self.kind());
        if (count == self.options.limits.list_entries) return error.LimitExceeded;
        const offset = try self.parseNode(&offsets, depth + 1, true, .skip);
        visitor.visit(visitor.user_data, visitor.index_start, offset);
        count += 1;
        _ = offsets.arena.reset(.retain_capacity);
    }
    try sequence.finish();
    self.current_kind = .index;
    storage.used = offsets.used;
    storage.nodes = offsets.nodes;
    // Verification keeps the retained-tree byte limit and its original failure point.
    try storage.charge(model.Node, count);
}

fn parseParams(self: *StreamReader, storage: *Storage, allow_refs: bool) Error![]const cv.Entry {
    self.param_scratch.clearRetainingCapacity();
    const entries = &self.param_scratch;
    try entries.ensureTotalCapacity(self.allocator, @min(8, self.options.limits.list_entries));
    var rank: u2 = 0;
    while (self.cursor.current) |event| {
        if (event.data != .start_element) break;
        const start = event.data.start_element;
        const local = xml.localName(start.name);
        const selected: u2 = if (std.mem.eql(u8, local, "referenceableParamGroupRef"))
            0
        else if (std.mem.eql(u8, local, "cvParam"))
            1
        else if (std.mem.eql(u8, local, "userParam"))
            2
        else
            break;
        if (self.options.checks == .checked and (selected < rank or (selected == 0 and !allow_refs))) return error.InvalidStructure;
        rank = selected;
        if (entries.items.len == self.options.limits.list_entries) return error.LimitExceeded;
        const attrs = switch (self.options.checks) {
            inline else => |checks| try copyParamAttributes(storage, start, selected, checks),
        };
        const unit: cv.Unit = .{
            .cv_ref = attrs.unit_cv_ref,
            .name = attrs.unit_name,
            .accession = if (attrs.unit_accession) |value| .{ .raw = value } else null,
        };
        const entry: cv.Entry = switch (selected) {
            0 => .{ .group_ref = attrs.ref },
            1 => .{ .cv = .{
                .cv_ref = attrs.cv_ref,
                .name = attrs.name,
                .accession = .{ .raw = attrs.accession.? },
                .value = attrs.value,
                .unit = unit,
            } },
            2 => .{ .user = .{
                .name = attrs.name,
                .value = attrs.value,
                .value_type = attrs.value_type,
                .unit = unit,
            } },
            else => unreachable,
        };
        try entries.append(self.allocator, entry);
        try self.cursor.advance(false);
        const end = self.cursor.current orelse return error.UnexpectedEnd;
        if (end.data != .end_element) return error.InvalidStructure;
        try self.cursor.advance(false);
    }
    return storage.copy(cv.Entry, entries.items);
}

fn copyParamAttributes(storage: *Storage, start: xml.Start, selected: u2, comptime checks: Checks) Error!ParamAttributes {
    var result: ParamAttributes = .{};
    var unknown = false;
    for (start.attributes) |attribute| {
        const name = if (checks == .checked) attribute.name.expanded.? else (try xml.attributeName(attribute.name)) orelse continue;
        if (name.namespace_uri) |uri| {
            if (!std.mem.eql(u8, uri, xml.XSI) or !std.mem.eql(u8, name.local, "schemaLocation")) unknown = true;
            continue;
        }
        const field = PARAM_ATTRIBUTES.get(name.local) orelse {
            unknown = true;
            continue;
        };
        switch (field) {
            inline else => |tag| @field(result, @tagName(tag)) = attribute.value,
        }
    }
    // Required-attribute failures retain precedence over unknown attributes.
    if ((selected == 0 and result.ref == null) or
        (selected == 1 and (result.cv_ref == null or result.accession == null or result.name == null)) or
        (selected == 2 and result.name == null)) return error.MissingAttribute;
    if (unknown or (selected != 0 and result.ref != null) or
        (selected != 1 and (result.cv_ref != null or result.accession != null)) or
        (selected != 2 and result.value_type != null)) return error.UnknownAttribute;
    if (selected == 0 and (result.name != null or result.value != null or result.unit_cv_ref != null or
        result.unit_accession != null or result.unit_name != null)) return error.UnknownAttribute;
    var length: usize = 0;
    inline for (std.meta.fields(ParamAttributes)) |field| {
        if (@field(result, field.name)) |value| length = std.math.add(usize, length, value.len) catch return error.LimitExceeded;
    }
    const bytes = try storage.alloc(u8, length);
    var position: usize = 0;
    inline for (std.meta.fields(ParamAttributes)) |field| {
        if (@field(result, field.name)) |value| {
            const copied = bytes[position..][0..value.len];
            @memcpy(copied, value);
            @field(result, field.name) = copied;
            position += value.len;
        }
    }
    return result;
}

fn significantLength(bytes: []const u8) usize {
    const width = @min(64, std.simd.suggestVectorLength(u8) orelse 16);
    const Vector = @Vector(width, u8);
    var position: usize = 0;
    var count: usize = 0;
    while (bytes.len - position >= width) : (position += width) {
        const run: Vector = bytes[position..][0..width].*;
        const whitespace = (run == @as(Vector, @splat(' '))) | (run == @as(Vector, @splat('\t'))) |
            (run == @as(Vector, @splat('\r'))) | (run == @as(Vector, @splat('\n')));
        count += width - @popCount(@as(@Int(.unsigned, width), @bitCast(whitespace)));
    }
    for (bytes[position..]) |byte| {
        count += @intFromBool(byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n');
    }
    return count;
}

fn copyAttributes(
    self: *StreamReader,
    storage: *Storage,
    start: xml.Start,
    required: []const u8,
    optional: []const u8,
) Error![]const model.Attribute {
    return switch (self.options.checks) {
        inline else => |checks| copyAttributesFor(storage, start, required, optional, checks),
    };
}

fn copyAttributesFor(
    storage: *Storage,
    start: xml.Start,
    required: []const u8,
    optional: []const u8,
    comptime checks: Checks,
) Error![]const model.Attribute {
    var names = std.mem.tokenizeScalar(u8, required, ' ');
    while (names.next()) |name| {
        const attribute = if (checks == .checked) start.attribute(null, name) else start.attributeRaw(name);
        if (attribute == null) return error.MissingAttribute;
    }
    var byte_count: usize = 0;
    var attribute_count: usize = 0;
    for (start.attributes) |attribute| {
        const name = if (checks == .checked) attribute.name.expanded.? else (try xml.attributeName(attribute.name)) orelse continue;
        if (name.namespace_uri) |uri| {
            if (!std.mem.eql(u8, uri, xml.XSI) or !std.mem.eql(u8, name.local, "schemaLocation"))
                return error.UnknownAttribute;
        } else if (checks == .checked and !schema.contains(required, name.local) and !schema.contains(optional, name.local))
            return error.UnknownAttribute;
        attribute_count += 1;
        byte_count = std.math.add(usize, byte_count, name.local.len) catch return error.LimitExceeded;
        byte_count = std.math.add(usize, byte_count, attribute.value.len) catch return error.LimitExceeded;
    }
    const result = try storage.alloc(model.Attribute, attribute_count);
    const bytes = try storage.alloc(u8, byte_count);
    var offset: usize = 0;
    var position: usize = 0;
    for (start.attributes) |attribute| {
        const name = if (checks == .checked) attribute.name.expanded.? else (try xml.attributeName(attribute.name)) orelse continue;
        const copied_name = bytes[offset..][0..name.local.len];
        @memcpy(copied_name, name.local);
        offset += name.local.len;
        const value = bytes[offset..][0..attribute.value.len];
        @memcpy(value, attribute.value);
        offset += attribute.value.len;
        result[position] = .{
            .name = copied_name,
            .namespace_uri = if (name.namespace_uri != null) xml.XSI else null,
            .value = value,
        };
        position += 1;
    }
    return result;
}

const Storage = struct {
    arena: std.heap.ArenaAllocator,
    limit: usize,
    used: usize = 0,
    nodes: usize = 0,
    arrays: usize = 0,
    last_binary_length: usize = 0,

    fn init(allocator: std.mem.Allocator, limit: usize) Storage {
        return .{ .arena = .init(allocator), .limit = limit };
    }

    fn reset(self: *Storage) void {
        _ = self.arena.reset(.retain_capacity);
        self.used = 0;
        self.nodes = 0;
        self.arrays = 0;
    }

    fn charge(self: *Storage, comptime T: type, count: usize) Error!void {
        const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return error.LimitExceeded;
        if (bytes > self.limit -| self.used) return error.LimitExceeded;
        self.used += bytes;
    }

    fn alloc(self: *Storage, comptime T: type, count: usize) Error![]T {
        try self.charge(T, count);
        return self.arena.allocator().alloc(T, count);
    }

    fn copy(self: *Storage, comptime T: type, values: []const T) Error![]T {
        const result = try self.alloc(T, values.len);
        @memcpy(result, values);
        return result;
    }
};

// --- Tests ---

test "fragment parsing preserves text boundaries and physical offsets" {
    const prefix = "<mzML xmlns='http://psi.hupo.org/ms/mzml'>";
    const cases = [_]struct { text: []const u8, failure: ?Error }{
        .{ .text = "e\u{301}", .failure = null },
        .{ .text = "value\x01", .failure = error.InvalidXml },
        .{ .text = "value\xff", .failure = error.InvalidEncoding },
    };
    const wrappers = .{
        .{ "<userParam name='note' value='", "'/>", true },
        .{ "<!--", "-->", false },
        .{ "<?note ", "?>", false },
    };
    inline for (wrappers) |wrapper| {
        for (cases) |case| {
            const source = try std.fmt.allocPrint(std.testing.allocator, "{s}<spectrum id='scan=1' index='0' defaultArrayLength='0'>{s}{s}{s}</spectrum></mzML>", .{ prefix, wrapper[0], case.text, wrapper[1] });
            defer std.testing.allocator.free(source);
            const result = parseFragment(std.testing.allocator, source, .{}, 1, 4096, prefix.len);
            if (case.failure) |failure| {
                try std.testing.expectError(failure, result);
            } else {
                var record = try result;
                defer record.deinit();
                if (wrapper[2]) {
                    try std.testing.expectEqualStrings(case.text, record.value.node.params[0].user.value.?);
                } else try std.testing.expectEqual(@as(usize, 0), record.value.node.params.len);
                try std.testing.expectEqual(@as(u64, 4096), record.value.node.start_offset);
            }
        }
    }
}

test "fragment parsing retains offsets beyond 32-bit positions" {
    const prefix = "<mzML xmlns='http://psi.hupo.org/ms/mzml'>";
    var record = try parseFragment(
        std.testing.allocator,
        prefix ++ "<spectrum id='scan=1' index='0' defaultArrayLength='0'/></mzML>",
        .{},
        1,
        0x1_0000_0000,
        prefix.len,
    );
    defer record.deinit();
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), record.value.node.start_offset);
}
