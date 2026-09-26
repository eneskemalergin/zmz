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

/// Ordinary reads retain or skip text; decoded reads decode or skip array bytes.
pub const Payload = enum { retain, skip };

/// Chooses arrays after their leading parameters and before their binary text.
/// The callback receives its zero-based array position within the record, source attributes,
/// and unexpanded parameters. All slices borrow only for the call. Keep user_data valid
/// while reading; it can hold header groups. Do not reenter the reader. Later checks can fail.
pub const ArraySelector = struct {
    user_data: ?*anyopaque = null,
    select: *const fn (?*anyopaque, usize, []const model.Attribute, []const cv.Entry) Payload,
    /// Called once before the array list with the record kind, attributes, and parameters
    /// read so far. Returning skip skips every array without calling select. Neither
    /// callback sees later parameters; selection never removes record or array metadata.
    select_record: ?*const fn (?*anyopaque, model.Kind, []const model.Attribute, []const cv.Entry) Payload = null,
};

pub const Options = struct {
    limits: Limits = .{},
    payload: Payload = .retain,
    /// Selects retained text or decoded arrays without dropping metadata.
    /// Ignored by ordinary reads when payload is skip; decoded reads ignore payload.
    /// Does not classify encodings or resolve parameters on the caller's behalf.
    array_selector: ?ArraySelector = null,
    /// Retains the index trailer within header limits for StreamReader.indexTrailer().
    retain_index: bool = false,
};

pub const Error = xml.Error || cv.ValueError || DecodedArrays.Error || std.mem.Allocator.Error || error{
    InvalidStructure,
    MissingAttribute,
    FailedState,
    InvalidOptions,
    InvalidIndex,
};

pub const Diagnostic = @import("../diagnostic.zig");

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
position: enum { list_start, list, run, run_end, document } = .run_end,
current_kind: ?model.Kind = null,
index_trailer: [3]model.Node = undefined,
scopes: [3]Scope = undefined,
scope_count: usize = 0,
list_scopes: [2]?Scope = .{ null, null },
child_scratch: std.ArrayList(model.Node) = .empty,
param_scratch: std.ArrayList(cv.Entry) = .empty,
decoded_arrays: ?*DecodedArrays = null,
decode_binary: bool = false,
fragment_ancestors: ?xml.Ancestors = null,

pub const Scope = struct { start: u64, end: u64, name: []const u8 };
pub const FragmentTarget = struct { kind: model.Kind, id: []const u8 };

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
        .cursor = try xml.Cursor.init(allocator, input, options.limits.depth, options.limits.attributes, options.limits.attribute_bytes),
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
    if (!self.header_ready) self.readHeaderInner() catch |err| {
        self.fail(err, .read_header);
        return err;
    };
    return &self.header;
}

/// Returns a borrowed spectrum or chromatogram, or null after the mzML content.
/// Every call invalidates the previous record, including its encoded payload. Failures are sticky.
/// Indexed trailers are read only with retain_index; targets and checksums are not checked.
pub fn nextRecord(self: *StreamReader) Error!?model.Record {
    return self.nextRecordFor(.tree);
}

pub fn nextIndexRecord(self: *StreamReader) Error!?model.Record {
    return self.nextRecordFor(.entry);
}

const Retention = enum { tree, entry, none };

fn nextRecordFor(self: *StreamReader, comptime retention: Retention) Error!?model.Record {
    while (try self.nextItemFor(retention, false)) |item| {
        if (item == .record) return item.record;
    }
    return null;
}

pub fn nextItem(self: *StreamReader) Error!?model.Item {
    return self.nextItemFor(.tree, true);
}

fn nextItemFor(self: *StreamReader, comptime retention: Retention, comptime retain_xml: bool) Error!?model.Item {
    if (self.failure != null) return error.FailedState;
    errdefer |err| self.fail(err, if (retain_xml) .read_item else .read_record);
    _ = try self.readHeader();
    self.record_store.reset();
    if (self.done) return null;
    return self.nextItemInner(retention, retain_xml);
}

pub fn nextDecodedItem(self: *StreamReader, output: *DecodedArrays) Error!?model.Item {
    output.reset();
    errdefer output.reset();
    self.decoded_arrays = output;
    defer self.decoded_arrays = null;
    const item = try self.nextItem() orelse return null;
    if (item == .record) output.complete();
    return item;
}

pub fn nextDecodedRecord(self: *StreamReader, output: *DecodedArrays) Error!?model.Record {
    output.reset();
    errdefer output.reset();
    self.decoded_arrays = output;
    defer self.decoded_arrays = null;
    const record = try self.nextRecord() orelse return null;
    output.complete();
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
    return reader.readFragment(allocator, &input, ancestors, physical_start, prefix_length, true, false, null);
}

/// Internal reusable fragment reader. Returned records use the requested allocator;
/// parser and list scratch remain owned by this reader. No source bytes remain borrowed.
pub fn readFragment(self: *StreamReader, allocator: std.mem.Allocator, input: *std.Io.Reader, ancestors: usize, physical_start: u64, prefix_length: usize, complete: bool, reuse_ancestors: bool, expected: ?FragmentTarget) Error!owned.Record {
    self.failure = null;
    if (self.header_ready or ancestors > 4 or physical_start < prefix_length) return error.InvalidOptions;
    errdefer self.fragment_ancestors = null;
    if (reuse_ancestors) {
        try self.cursor.resetToAncestors(input, self.fragment_ancestors.?, prefix_length);
    } else {
        self.fragment_ancestors = null;
        try self.cursor.reset(input);
    }
    defer self.cursor.detachFragment();
    self.record_store.arena.deinit();
    self.record_store = Storage.init(allocator, self.options.limits.record_bytes);
    defer {
        self.record_store.arena.deinit();
        self.record_store = Storage.init(self.allocator, self.options.limits.record_bytes);
    }
    errdefer |err| self.fail(err, .lookup_record);
    try self.cursor.advance(false);
    for (0..if (reuse_ancestors) 0 else ancestors) |i| {
        if ((self.cursor.current orelse return error.UnexpectedEnd).data != .start_element)
            return error.InvalidStructure;
        if (i + 1 == ancestors) self.fragment_ancestors = self.cursor.ancestors();
        try self.cursor.advance(false);
    }
    const kind_value = try self.kind();
    if (expected) |target| {
        errdefer |err| self.capture(err, .index, .none);
        if (kind_value != target.kind) return error.InvalidIndex;
        const start = self.cursor.current.?.data.start_element;
        const id = start.attributeRaw("id") orelse return try self.attributeError(error.MissingAttribute, .id);
        if (!std.mem.eql(u8, id.value, target.id)) return error.InvalidIndex;
    }
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
    const record: model.Record = .{
        .node = node,
        .id = node.attribute("id").?,
        .index = try self.number(node, .index),
        .default_array_length = try self.number(node, .default_array_length),
    };
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
pub fn parseFooter(allocator: std.mem.Allocator, bytes: []const u8, options: Options, physical_start: u64, prefix_length: usize, failure: *?Diagnostic) Error!ParsedFooter {
    failure.* = null;
    if (physical_start < prefix_length) return error.InvalidOptions;
    var input = std.Io.Reader.fixed(bytes);
    var reader = try init(allocator, &input, options);
    defer reader.deinit();
    errdefer |err| {
        reader.fail(err, .open_index);
        failure.* = reader.failure;
        failure.*.?.translate(physical_start, bytes.len - prefix_length, prefix_length);
    }
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
    const replacement = try xml.Cursor.init(self.allocator, input, self.options.limits.depth, self.options.limits.attributes, self.options.limits.attribute_bytes);
    self.cursor.deinit();
    self.cursor = replacement;
    errdefer |err| self.fail(err, .open_index);
    try self.cursor.advance(false);
    for (0..ancestors) |_| {
        if ((self.cursor.current orelse return error.UnexpectedEnd).data != .start_element) return error.InvalidStructure;
        try self.cursor.advance(false);
    }
    if (try self.kind() != .spectrum) return error.InvalidStructure;
    try self.cursor.skip();
    try self.finishSpectrumList();
    if (self.active_list != .chromatogram_list) return error.InvalidStructure;
    const scope = &self.list_scopes[1].?;
    scope.start = std.math.add(u64, scope.start, physical_start - prefix_length) catch return error.LimitExceeded;
    scope.end = std.math.add(u64, scope.end, physical_start - prefix_length) catch return error.LimitExceeded;
}

/// Internal indexed-open operation for an empty spectrum list preceding chromatograms.
pub fn finishEmptySpectrumList(self: *StreamReader) Error!void {
    errdefer |err| self.fail(err, .open_index);
    if (self.active_list != .spectrum_list) return error.InvalidOptions;
    try self.cursor.advance(false);
    try self.finishSpectrumList();
    if (self.active_list != .chromatogram_list) return error.InvalidStructure;
}

fn skipExtraXml(self: *StreamReader, parent: model.Kind) Error!void {
    while (self.cursor.current) |event| {
        if (event.data != .start_element or self.childKind(parent) != null) break;
        self.record_store.reset();
        _ = try self.readXml(&self.record_store, false);
        try self.cursor.advance(false);
    }
}

fn finishSpectrumList(self: *StreamReader) Error!void {
    try self.skipExtraXml(.spectrum_list);
    try self.consumeEnd(.spectrum_list, true);
    self.active_list = null;
    try self.skipExtraXml(.run);
    try self.openList();
}

fn shiftOffsets(node: *model.Node, delta: u64) Error!void {
    node.start_offset = std.math.add(u64, node.start_offset, delta) catch return error.LimitExceeded;
    node.content_offset = std.math.add(u64, node.content_offset, delta) catch return error.LimitExceeded;
    node.end_offset = std.math.add(u64, node.end_offset, delta) catch return error.LimitExceeded;
    for (@constCast(node.children)) |*child| try shiftOffsets(child, delta);
}

fn fail(self: *StreamReader, err: Error, operation: Diagnostic.Operation) void {
    self.capture(err, .metadata, .none);
    self.failure.?.operation = operation;
}

fn capture(self: *StreamReader, err: Error, stage: Diagnostic.Stage, detail: Diagnostic.Detail) void {
    if (self.failure != null) return;
    var report = Diagnostic.init(err, .read_record, stage, detail);
    if (self.cursor.failure != null) {
        report = Diagnostic.init(err, .read_record, .xml, Diagnostic.xmlDetail(&self.cursor));
    } else if (self.decoded_arrays != null and self.decoded_arrays.?.failure != null) {
        const decoded = self.decoded_arrays.?.failure.?;
        report = Diagnostic.init(err, .read_record, decoded.stage, decoded.detail);
    } else if (self.record_store.exceeded or self.header_store.exceeded) {
        const record = self.record_store.exceeded;
        report = Diagnostic.init(err, .read_record, .metadata, .{ .limit = .{
            .name = if (record) .record_bytes else .header_bytes,
            .maximum = if (record) self.record_store.limit else self.header_store.limit,
        } });
    }
    report.location = .{ .input_event = self.cursor.offset };
    report.element = self.current_kind;
    self.failure = report;
}

fn limitError(self: *StreamReader, name: Diagnostic.Limit, maximum: usize, needed: ?usize) Error!noreturn {
    self.capture(error.LimitExceeded, .metadata, .{ .limit = .{ .name = name, .maximum = maximum, .needed = needed } });
    return error.LimitExceeded;
}

fn attributeError(self: *StreamReader, err: Error, attribute: Diagnostic.Attribute) Error!noreturn {
    self.capture(err, .metadata, .{ .attribute = attribute });
    return err;
}

fn number(self: *StreamReader, node: model.Node, attribute: Diagnostic.Attribute) Error!?usize {
    const value = node.attribute(attribute.xmlName()) orelse return null;
    return cv.parseInteger(usize, value) catch |err| return try self.attributeError(err, attribute);
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
    try self.cursor.advance(false);
    const sections = schema.children(.mzml);
    var seen = std.EnumSet(model.Kind).initEmpty();
    var metadata: std.ArrayList(model.Node) = .empty;
    defer metadata.deinit(self.allocator);
    try metadata.ensureTotalCapacity(self.allocator, sections.len - 1);
    var document_params: usize = 0;
    var content: std.ArrayList(model.Content.Item) = .empty;
    defer content.deinit(self.allocator);
    while (true) {
        const before = document_params;
        const current = self.cursor.current orelse return error.UnexpectedEnd;
        if (current.data != .start_element) return error.InvalidStructure;
        if (self.paramKind(current.data.start_element) != null and
            metadata.items.len != 0 and content.items.len == 0)
            try self.startContent(&content, document_params, metadata.items.len);
        try self.parseParams(&self.header_store, true, &document_params);
        if (content.items.len != 0 and document_params != before)
            try content.append(self.allocator, .{ .params = document_params - before });
        const kind_value = self.firstChildKind(.mzml, seen) orelse {
            if (content.items.len == 0) try self.startContent(&content, document_params, metadata.items.len);
            const fragment = try self.readXml(&self.header_store, true);
            try content.append(self.allocator, .{ .xml = fragment });
            try self.cursor.advance(false);
            continue;
        };
        if (kind_value == .run) break;
        seen.insert(kind_value);
        try metadata.append(self.allocator, try self.parseNode(&self.header_store, 1, true, self.options.payload));
        if (content.items.len != 0) try content.append(self.allocator, .{ .children = 1 });
    }
    document.params = try self.header_store.copy(cv.Entry, self.param_scratch.items);
    self.param_scratch.clearRetainingCapacity();
    document.children = try self.header_store.copy(model.Node, metadata.items);
    document.content = try saveContent(&self.header_store, content.items);
    content.clearRetainingCapacity();
    metadata.clearRetainingCapacity();
    var run = try self.startNode(&self.header_store, .run);
    self.scopes[self.scope_count] = try self.captureScope();
    self.scope_count += 1;
    try self.cursor.advance(false);
    var param_count: usize = 0;
    while (true) {
        const before = param_count;
        const current = self.cursor.current orelse return error.UnexpectedEnd;
        if (current.data == .start_element and self.paramKind(current.data.start_element) != null and
            metadata.items.len != 0 and content.items.len == 0)
            try self.startContent(&content, param_count, metadata.items.len);
        try self.parseParams(&self.header_store, true, &param_count);
        if (content.items.len != 0 and param_count != before)
            try content.append(self.allocator, .{ .params = param_count - before });
        const event = self.cursor.current orelse return error.UnexpectedEnd;
        if (event.data == .end_element) break;
        const kind_value = self.childKind(.run);
        if (kind_value != null and kind_value != .source_file_ref_list) break;
        if (kind_value == .source_file_ref_list and metadata.items.len == 0) {
            try metadata.append(self.allocator, try self.parseNode(&self.header_store, 1, true, self.options.payload));
            if (content.items.len != 0) try content.append(self.allocator, .{ .children = 1 });
        } else {
            if (content.items.len == 0) try self.startContent(&content, param_count, metadata.items.len);
            try content.append(self.allocator, .{ .xml = try self.readXml(&self.header_store, true) });
            try self.cursor.advance(false);
        }
    }
    run.params = try self.header_store.copy(cv.Entry, self.param_scratch.items);
    self.param_scratch.clearRetainingCapacity();
    run.children = try self.header_store.copy(model.Node, metadata.items);
    run.content = try saveContent(&self.header_store, content.items);
    const group_list = document.child(.referenceable_param_group_list);
    const group_nodes = if (group_list) |list| list.children else &.{};
    const groups = try self.header_store.alloc(cv.Group, group_nodes.len);
    for (group_nodes, groups) |node, *group| {
        group.* = .{ .id = node.attribute("id") orelse return error.MissingAttribute, .entries = node.params };
    }
    self.header = .{ .document = document, .run = run, .namespace_uri = self.cursor.mzml_namespace, .groups = groups, .indexed = indexed };
    self.header_ready = true;
    try self.openList();
}

fn openList(self: *StreamReader) Error!void {
    const event = self.cursor.current orelse return error.UnexpectedEnd;
    if (event.data == .end_element) return;
    const kind_value = try self.kind();
    switch (kind_value) {
        .spectrum_list => if (self.header.spectrum_list != null or self.header.chromatogram_list != null) return error.InvalidStructure,
        .chromatogram_list => if (self.header.chromatogram_list != null) return error.InvalidStructure,
        else => return error.InvalidStructure,
    }
    const node = try self.startNode(&self.header_store, kind_value);
    const list: model.RecordList = .{
        .attributes = node.attributes,
        .declared_count = try self.number(node, .count),
    };
    switch (kind_value) {
        .spectrum_list => self.header.spectrum_list = list,
        .chromatogram_list => self.header.chromatogram_list = list,
        else => return error.InvalidStructure,
    }
    self.active_list = kind_value;
    self.position = .list_start;
    self.list_scopes[if (kind_value == .spectrum_list) @as(usize, 0) else 1] = try self.captureScope();
}

fn nextItemInner(self: *StreamReader, comptime retention: Retention, comptime retain_xml: bool) Error!?model.Item {
    while (true) switch (self.position) {
        .list_start => {
            self.position = .list;
            const kind_value = self.active_list.?;
            return .{ .list_start = .{
                .kind = kind_value,
                .list = if (kind_value == .spectrum_list) self.header.spectrum_list.? else self.header.chromatogram_list.?,
            } };
        },
        .list => {
            const list_kind = self.active_list.?;
            try self.cursor.advance(false);
            const event = self.cursor.current orelse return error.UnexpectedEnd;
            if (event.data == .end_element) {
                try self.consumeEnd(list_kind, false);
                self.active_list = null;
                self.position = .run;
                return .list_end;
            }
            _ = self.childKind(list_kind) orelse
                return .{ .xml = try self.readXml(&self.record_store, retain_xml) };
            const list = if (list_kind == .spectrum_list) &self.header.spectrum_list.? else &self.header.chromatogram_list.?;
            const ordinal = list.observed_count;
            errdefer |err| {
                self.capture(err, .metadata, .none);
                self.failure.?.record = .{ .kind = if (list_kind == .spectrum_list) .spectrum else .chromatogram, .ordinal = ordinal };
            }
            const node = try self.parseNodeFor(&self.record_store, 1, false, self.options.payload, retention);
            list.observed_count = std.math.add(usize, list.observed_count, 1) catch return error.LimitExceeded;
            return .{ .record = .{
                .node = node,
                .id = node.attribute("id").?,
                .index = try self.number(node, .index),
                .default_array_length = try self.number(node, .default_array_length),
            } };
        },
        .run => {
            try self.cursor.advance(false);
            const event = self.cursor.current orelse return error.UnexpectedEnd;
            if (event.data == .end_element) {
                self.position = .run_end;
                continue;
            }
            if (self.childKind(.run) == null)
                return .{ .xml = try self.readXml(&self.record_store, retain_xml) };
            try self.openList();
        },
        .run_end => {
            try self.consumeEnd(.run, false);
            self.position = .document;
            return .run_end;
        },
        .document => {
            try self.cursor.advance(false);
            const event = self.cursor.current orelse return error.UnexpectedEnd;
            if (event.data == .end_element) {
                try self.consumeEnd(.mzml, false);
                break;
            }
            if (self.childKind(.mzml) != null) return error.InvalidStructure;
            return .{ .xml = try self.readXml(&self.record_store, retain_xml) };
        },
    };
    if (self.header.indexed and !self.options.retain_index) {
        self.done = true;
        return null;
    }
    try self.cursor.advance(false);
    if (self.header.indexed) {
        inline for (.{ model.Kind.index_list, .index_list_offset, .file_checksum }, 0..) |expected, i| {
            if (try self.kind() != expected) return error.InvalidStructure;
            self.index_trailer[i] = try self.parseNode(&self.header_store, 1, true, self.options.payload);
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
    return self.knownKind() orelse error.InvalidStructure;
}

fn knownKind(self: *StreamReader) ?model.Kind {
    const event = self.cursor.current orelse return null;
    if (event.data != .start_element) return null;
    const name = event.data.start_element.name.expanded;
    if (!std.mem.eql(u8, name.namespace_uri orelse "", self.cursor.mzml_namespace)) return null;
    // The cursor resolves namespaces and matches closing tags.
    const value = ELEMENT_KINDS.get(name.local) orelse return null;
    self.current_kind = value;
    return value;
}

fn childKind(self: *StreamReader, parent: model.Kind) ?model.Kind {
    const value = self.knownKind() orelse return null;
    return if (schema.CHILD_KINDS.get(parent).allowed.contains(value)) value else null;
}

fn firstChildKind(self: *StreamReader, parent: model.Kind, seen: std.EnumSet(model.Kind)) ?model.Kind {
    const value = self.childKind(parent) orelse return null;
    if (value != .binary and seen.contains(value) and schema.CHILD_KINDS.get(parent).singular.contains(value)) return null;
    return value;
}

fn startNode(self: *StreamReader, storage: *Storage, kind_value: model.Kind) Error!model.Node {
    return self.startNodeFor(storage, kind_value, true);
}

fn startNodeFor(self: *StreamReader, storage: *Storage, kind_value: model.Kind, comptime retain: bool) Error!model.Node {
    if (storage.nodes == self.options.limits.nodes) return try self.limitError(.nodes, self.options.limits.nodes, null);
    storage.nodes += 1;
    const event = self.cursor.current orelse return error.UnexpectedEnd;
    const attributes = try self.copyAttributes(
        storage,
        event.data.start_element,
        switch (kind_value) {
            .referenceable_param_group, .spectrum, .chromatogram => "id",
            else => "",
        },
        retain,
    );
    return .{
        .kind = kind_value,
        .attributes = attributes,
        .start_offset = event.span.start,
        .content_offset = event.span.end,
    };
}

fn parseNode(self: *StreamReader, storage: *Storage, depth: usize, advance_after: bool, payload: Payload) Error!model.Node {
    return self.parseNodeFor(storage, depth, advance_after, payload, .tree);
}

fn parseNodeFor(self: *StreamReader, storage: *Storage, depth: usize, advance_after: bool, payload: Payload, comptime retention: Retention) Error!model.Node {
    if (depth > self.options.limits.depth) return try self.limitError(.depth, self.options.limits.depth, depth);
    const kind_value = try self.kind();
    const array_position = storage.arrays;
    var node: model.Node = .{ .kind = kind_value };
    errdefer |err| if (kind_value == .binary_data_array and storage == &self.record_store) {
        self.capture(err, .metadata, .none);
        if (node.end_offset == 0 or self.cursor.offset < node.end_offset)
            self.failure.?.array_position = array_position;
    };
    node = try self.startNodeFor(storage, kind_value, retention != .none);
    var child_payload = payload;
    if (storage == &self.record_store and depth == 1) {
        if (self.decoded_arrays) |output| {
            output.startRecord(node) catch |err| return try self.attributeError(err, .default_array_length);
            child_payload = .retain;
        }
    }
    const has_text = kind_value == .binary or kind_value == .offset or kind_value == .index_list_offset or kind_value == .file_checksum;
    try self.cursor.advance(has_text);
    if (has_text) {
        var text: std.ArrayList(u8) = .empty;
        var text_size: usize = 0;
        while (self.cursor.current) |event| {
            if (event.data != .text) break;
            const bytes = event.data.text.bytes;
            text_size = std.math.add(usize, text_size, bytes.len) catch return error.LimitExceeded;
            if (text_size > self.options.limits.binary_text_bytes) return try self.limitError(.binary_text_bytes, self.options.limits.binary_text_bytes, text_size);
            if (kind_value == .binary and self.decode_binary) try self.decoded_arrays.?.text(bytes);
            if (payload == .retain or kind_value != .binary) {
                if (text_size > storage.limit -| storage.used) return try storage.limitError();
                try text.appendSlice(storage.arena.allocator(), bytes);
            }
            try self.cursor.advance(true);
        }
        if (payload == .retain or kind_value != .binary) {
            storage.used += text.items.len;
            node.text = text.items;
        }
        if (kind_value == .binary and self.decode_binary) try self.decoded_arrays.?.finishArray();
    } else {
        const params_start = self.param_scratch.items.len;
        defer self.param_scratch.shrinkRetainingCapacity(params_start);
        var param_count: usize = 0;
        var content: std.ArrayList(model.Content.Item) = .empty;
        defer content.deinit(self.allocator);
        try self.parseParams(storage, retention == .tree, &param_count);
        if (kind_value == .binary_data_array) {
            while (self.cursor.current) |event| {
                if (event.data != .start_element or self.childKind(kind_value) != null) break;
                if (retention == .tree and content.items.len == 0) try self.startContent(&content, param_count, 0);
                const fragment = try self.readXml(storage, retention == .tree);
                if (retention == .tree) try content.append(self.allocator, .{ .xml = fragment });
                try self.cursor.advance(false);
                const before = param_count;
                try self.parseParams(storage, retention == .tree, &param_count);
                if (retention == .tree and param_count != before) try content.append(self.allocator, .{ .params = param_count - before });
            }
        }
        node.params = self.param_scratch.items[params_start..];
        var decode_array = false;
        if (kind_value == .binary_data_array and storage == &self.record_store) {
            const position = storage.arrays;
            storage.arrays += 1;
            if (child_payload == .retain) {
                if (self.options.array_selector) |selector|
                    child_payload = selector.select(selector.user_data, position, node.attributes, node.params);
            }
            if (self.decoded_arrays) |output| {
                decode_array = child_payload == .retain;
                if (decode_array) output.beginArray(node, self.header.groups, position) catch |err| {
                    self.capture(err, .array, .none);
                    self.failure.?.element = .binary_data_array;
                    return @as(Error!model.Node, err);
                };
                child_payload = .skip;
            }
            self.decode_binary = decode_array;
        }
        defer if (decode_array) {
            self.decode_binary = false;
        };
        const children = schema.CHILD_KINDS.get(kind_value);
        var seen = std.EnumSet(model.Kind).initEmpty();
        const children_start = self.child_scratch.items.len;
        defer self.child_scratch.shrinkRetainingCapacity(children_start);
        if (retention == .tree and children.allowed.count() != 0)
            try self.child_scratch.ensureUnusedCapacity(self.allocator, @min(
                4,
                self.options.limits.list_entries,
                (storage.limit -| storage.used) / @sizeOf(model.Node),
            ));
        var child_count: usize = 0;
        while (self.cursor.current) |event| {
            if (event.data == .end_element) break;
            if (event.data == .start_element and self.paramKind(event.data.start_element) != null) {
                if (retention == .tree and child_count != 0 and content.items.len == 0)
                    try self.startContent(&content, param_count, child_count);
                const before = param_count;
                try self.parseParams(storage, retention == .tree, &param_count);
                if (retention == .tree and content.items.len != 0)
                    try content.append(self.allocator, .{ .params = param_count - before });
                if (decode_array) {
                    node.params = self.param_scratch.items[params_start..];
                    // Late declarations must agree with the bytes already decoded.
                    _ = model.arrayEncoding(node, self.header.groups) catch |err| {
                        self.capture(err, .array, .none);
                        return @as(Error!model.Node, err);
                    };
                }
                continue;
            }
            const child_kind = self.firstChildKind(kind_value, seen) orelse {
                if (retention == .tree and content.items.len == 0) try self.startContent(&content, param_count, child_count);
                const fragment = try self.readXml(storage, retention == .tree);
                if (retention == .tree) try content.append(self.allocator, .{ .xml = fragment });
                try self.cursor.advance(false);
                continue;
            };
            if (child_kind == .binary and seen.contains(.binary)) return error.InvalidStructure;
            seen.insert(child_kind);
            if (child_count == self.options.limits.list_entries) return try self.limitError(.list_entries, self.options.limits.list_entries, null);
            if (child_kind == .binary_data_array_list and storage == &self.record_store and child_payload == .retain) {
                if (self.options.array_selector) |selector| {
                    if (selector.select_record) |select|
                        child_payload = select(selector.user_data, kind_value, node.attributes, self.param_scratch.items[params_start..]);
                }
            }
            const child = try self.parseNodeFor(storage, depth + 1, true, child_payload, if (retention == .tree) .tree else .none);
            if (retention == .tree) try self.child_scratch.append(self.allocator, child);
            if (retention == .tree and content.items.len != 0) try content.append(self.allocator, .{ .children = 1 });
            child_count += 1;
        }
        if (decode_array and !seen.contains(.binary)) {
            self.capture(error.PayloadNotRetained, .array, .none);
            return error.PayloadNotRetained;
        }
        self.current_kind = kind_value;
        if (retention == .tree) {
            node.params = try storage.copy(cv.Entry, self.param_scratch.items[params_start..]);
            node.children = try storage.copy(model.Node, self.child_scratch.items[children_start..]);
            node.content = try saveContent(storage, content.items);
        }
    }
    const end = self.cursor.current orelse return error.UnexpectedEnd;
    node.end_offset = end.span.end;
    try self.consumeEnd(kind_value, advance_after);
    return node;
}

fn paramKind(self: *const StreamReader, start: xml.Start) ?u2 {
    if (!std.mem.eql(u8, start.name.expanded.namespace_uri orelse "", self.cursor.mzml_namespace)) return null;
    const local = xml.localName(start.name);
    if (std.mem.eql(u8, local, "referenceableParamGroupRef")) return 0;
    if (std.mem.eql(u8, local, "cvParam")) return 1;
    if (std.mem.eql(u8, local, "userParam")) return 2;
    return null;
}

fn parseParams(self: *StreamReader, storage: *Storage, comptime retain: bool, count: *usize) Error!void {
    const entries = &self.param_scratch;
    while (self.cursor.current) |event| {
        if (event.data != .start_element) break;
        const start = event.data.start_element;
        const selected = self.paramKind(start) orelse break;
        if (count.* == self.options.limits.list_entries) return try self.limitError(.list_entries, self.options.limits.list_entries, null);
        if (retain and count.* == 0) try entries.ensureUnusedCapacity(self.allocator, @min(8, self.options.limits.list_entries));
        var has_extra = retain and self.cursor.hasAdditionalNamespaces();
        const attrs = try copyParamAttributes(storage, start, selected, retain, &has_extra);
        const has_content = !start.empty_element_syntax;
        const extra = if (retain and (has_extra or has_content)) try self.copyParamExtra(storage, start, selected) else null;
        const unit: cv.Unit = .{
            .cv_ref = attrs.unit_cv_ref,
            .name = attrs.unit_name,
            .accession = if (attrs.unit_accession) |value| .{ .raw = value } else null,
        };
        const entry: cv.Entry = switch (selected) {
            0 => .{ .group_ref = .{ .ref = attrs.ref, .xml = extra } },
            1 => .{ .cv = .{
                .cv_ref = attrs.cv_ref,
                .name = attrs.name,
                .accession = if (attrs.accession) |value| .{ .raw = value } else null,
                .value = attrs.value,
                .unit = unit,
                .xml = extra,
            } },
            2 => .{ .user = .{
                .name = attrs.name,
                .value = attrs.value,
                .value_type = attrs.value_type,
                .unit = unit,
                .xml = extra,
            } },
            else => unreachable,
        };
        if (retain) try entries.append(self.allocator, entry);
        count.* += 1;
        try self.cursor.advance(has_content);
        if (has_content) {
            var content: std.ArrayList(cv.ParameterXml.Part) = .empty;
            defer content.deinit(self.allocator);
            while (self.cursor.current) |current| {
                const part: cv.ParameterXml.Part = switch (current.data) {
                    .end_element => break,
                    .start_element => .{ .xml = try self.readXml(storage, retain) },
                    .text => blk: {
                        var bytes: std.ArrayList(u8) = .empty;
                        while (self.cursor.current) |text| {
                            if (text.data != .text) break;
                            if (retain) {
                                if (text.data.text.bytes.len > storage.limit -| storage.used -| bytes.items.len)
                                    return try storage.limitError();
                                try bytes.appendSlice(storage.arena.allocator(), text.data.text.bytes);
                            }
                            try self.cursor.advance(true);
                        }
                        storage.used += bytes.items.len;
                        break :blk .{ .text = bytes.items };
                    },
                    else => return error.InvalidStructure,
                };
                if (retain) {
                    if (content.items.len == self.options.limits.list_entries) return try self.limitError(.list_entries, self.options.limits.list_entries, null);
                    try content.append(self.allocator, part);
                }
                if (part != .text) try self.cursor.advance(true);
            }
            if (retain) extra.?.content = try storage.copy(cv.ParameterXml.Part, content.items);
            if (retain and !has_extra and content.items.len == 0) switch (entries.items[entries.items.len - 1]) {
                inline else => |*param| param.xml = null,
            };
        }
        const end = self.cursor.current orelse return error.UnexpectedEnd;
        if (end.data != .end_element) return error.InvalidStructure;
        try self.cursor.advance(false);
    }
}

fn copyParamAttributes(storage: *Storage, start: xml.Start, selected: u2, comptime retain: bool, has_extra: *bool) Error!ParamAttributes {
    var result: ParamAttributes = .{};
    for (start.attributes) |attribute| {
        const name = attribute.name.expanded;
        const field = parameterAttribute(name, selected) orelse {
            has_extra.* = true;
            continue;
        };
        switch (field) {
            inline else => |tag| @field(result, @tagName(tag)) = attribute.value,
        }
    }
    if (!retain) return result;
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

fn copyAttributes(
    self: *StreamReader,
    storage: *Storage,
    start: xml.Start,
    required: []const u8,
    comptime retain: bool,
) Error![]const model.Attribute {
    var names = std.mem.tokenizeScalar(u8, required, ' ');
    while (names.next()) |name| {
        const attribute = start.attribute(null, name);
        if (attribute == null) return try self.attributeError(error.MissingAttribute, .id);
    }
    if (retain and self.cursor.hasAdditionalNamespaces()) return self.copyForeignAttributes(storage, start, null);
    var byte_count: usize = 0;
    var attribute_count: usize = 0;
    for (start.attributes) |attribute| {
        const name = attribute.name.expanded;
        if (name.namespace_uri) |uri| {
            if (!std.mem.eql(u8, uri, xml.XSI) or !std.mem.eql(u8, name.local, "schemaLocation"))
                return if (retain) self.copyForeignAttributes(storage, start, null) else &.{};
        }
        if (retain) {
            attribute_count += 1;
            byte_count = std.math.add(usize, byte_count, name.local.len) catch return error.LimitExceeded;
            byte_count = std.math.add(usize, byte_count, attribute.value.len) catch return error.LimitExceeded;
        }
    }
    if (!retain) return &.{};
    const result = try storage.alloc(model.Attribute, attribute_count);
    const bytes = try storage.alloc(u8, byte_count);
    var offset: usize = 0;
    var position: usize = 0;
    for (start.attributes) |attribute| {
        const name = attribute.name.expanded;
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

fn parameterAttribute(name: xml.ExpandedName, selected: u2) ?std.meta.FieldEnum(ParamAttributes) {
    if (name.namespace_uri != null) return null;
    const field = PARAM_ATTRIBUTES.get(name.local) orelse return null;
    if (selected == 0) return if (field == .ref) field else null;
    return switch (field) {
        .ref => null,
        .cv_ref, .accession => if (selected == 1) field else null,
        .value_type => if (selected == 2) field else null,
        else => field,
    };
}

fn copyParamExtra(self: *StreamReader, storage: *Storage, start: xml.Start, selected: u2) Error!*cv.ParameterXml {
    const result = &(try storage.alloc(cv.ParameterXml, 1))[0];
    result.* = .{ .attributes = try self.copyForeignAttributes(storage, start, selected) };
    return result;
}

fn startContent(self: *StreamReader, content: *std.ArrayList(model.Content.Item), params: usize, children: usize) Error!void {
    try content.append(self.allocator, .{ .params = params });
    try content.append(self.allocator, .{ .children = children });
}

fn saveContent(storage: *Storage, items: []const model.Content.Item) Error!?*const model.Content {
    if (items.len == 0) return null;
    const result = &(try storage.alloc(model.Content, 1))[0];
    result.* = .{ .items = try storage.copy(model.Content.Item, items) };
    return result;
}

fn readXml(self: *StreamReader, storage: *Storage, comptime retain: bool) Error![]const u8 {
    var output: FragmentBuffer = .{ .allocator = self.allocator, .limit = storage.limit -| storage.used };
    defer output.bytes.deinit(self.allocator);
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    var writer = try xml.Writer.init(self.allocator, if (retain) &output.writer else &discarding.writer, .{ .fragment = true });
    defer writer.deinit();
    var remaining = self.options.limits.nodes - storage.nodes;
    self.cursor.writeElement(&writer, &remaining) catch |err| return switch (err) {
        error.WriteFailed => if ((output.failure orelse error.InvalidXml) == error.LimitExceeded) try storage.limitError() else output.failure orelse error.InvalidXml,
        error.InvalidName, error.InvalidCharacter, error.InvalidNamespace, error.DuplicateAttribute => error.InvalidXml,
        error.WriterLimit => try self.limitError(.depth, 64, null),
        error.LimitExceeded => if (self.cursor.limit_failure == .nodes) try self.limitError(.nodes, self.options.limits.nodes, null) else error.LimitExceeded,
        else => |other| other,
    };
    storage.nodes = self.options.limits.nodes - remaining;
    return if (retain) try storage.copy(u8, output.bytes.items) else &.{};
}

const FragmentBuffer = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    bytes: std.ArrayList(u8) = .empty,
    failure: ?Error = null,
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FragmentBuffer = @alignCast(@fieldParentPtr("writer", writer));
        std.debug.assert(writer.end == 0 and data.len == 1 and splat == 1);
        const bytes = data[0];
        if (bytes.len > self.limit - self.bytes.items.len) {
            self.failure = error.LimitExceeded;
            return error.WriteFailed;
        }
        const needed = self.bytes.items.len + bytes.len;
        if (needed > self.bytes.capacity) {
            const capacity = @min(self.limit, @max(needed, self.bytes.capacity +| self.bytes.capacity / 2 +| 256));
            self.bytes.ensureTotalCapacityPrecise(self.allocator, capacity) catch {
                self.failure = error.OutOfMemory;
                return error.WriteFailed;
            };
        }
        self.bytes.appendSliceAssumeCapacity(bytes);
        return bytes.len;
    }
};

fn copyForeignAttributes(self: *StreamReader, storage: *Storage, start: xml.Start, parameter: ?u2) Error![]const model.Attribute {
    var count: usize = 0;
    var position: usize = 0;
    var has_default = false;
    while (self.cursor.namespaceAt(&position)) |binding| {
        count += 1;
        has_default = has_default or binding.prefix.len == 0;
    }
    if (!has_default) count += 1;
    for (start.attributes) |attribute| {
        if (parameter) |selected| if (parameterAttribute(attribute.name.expanded, selected) != null) continue;
        count += 1;
    }
    const result = try storage.alloc(model.Attribute, count);
    position = 0;
    var i: usize = 0;
    while (self.cursor.namespaceAt(&position)) |binding| {
        const name = try storage.alloc(u8, if (binding.prefix.len == 0) 5 else 6 + binding.prefix.len);
        @memcpy(name[0..5], "xmlns");
        if (binding.prefix.len != 0) {
            name[5] = ':';
            @memcpy(name[6..], binding.prefix);
        }
        result[i] = .{ .name = name, .namespace_uri = xml.XMLNS_NAMESPACE, .value = try storage.copy(u8, binding.uri) };
        i += 1;
    }
    if (!has_default) {
        result[i] = .{ .name = "xmlns", .namespace_uri = xml.XMLNS_NAMESPACE, .value = "" };
        i += 1;
    }
    for (start.attributes) |attribute| {
        if (parameter) |selected| if (parameterAttribute(attribute.name.expanded, selected) != null) continue;
        result[i] = .{
            .name = try storage.copy(u8, attribute.name.raw),
            .namespace_uri = if (attribute.name.expanded.namespace_uri) |uri| try storage.copy(u8, uri) else null,
            .value = try storage.copy(u8, attribute.value),
        };
        i += 1;
    }
    return result;
}

const Storage = struct {
    arena: std.heap.ArenaAllocator,
    limit: usize,
    used: usize = 0,
    nodes: usize = 0,
    arrays: usize = 0,
    exceeded: bool = false,

    fn init(allocator: std.mem.Allocator, limit: usize) Storage {
        return .{ .arena = .init(allocator), .limit = limit };
    }

    fn reset(self: *Storage) void {
        _ = self.arena.reset(.retain_capacity);
        self.used = 0;
        self.nodes = 0;
        self.arrays = 0;
        self.exceeded = false;
    }

    fn charge(self: *Storage, comptime T: type, count: usize) Error!void {
        const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return error.LimitExceeded;
        if (bytes > self.limit -| self.used) return try self.limitError();
        self.used += bytes;
    }

    fn limitError(self: *Storage) Error!noreturn {
        self.exceeded = true;
        return error.LimitExceeded;
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

test "[integration] - [mzML fragment parsing]: preserves text boundaries and physical offsets" {
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

test "[edge] - [mzML fragment parsing]: retains offsets beyond 32-bit positions" {
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
