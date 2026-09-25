//! Constructs owned mzML metadata and encoded arrays with explicit allocation limits.
//!
//! Returned metadata lasts until reset or deinit. Metadata and ordinary Base64 inputs are
//! copied; prepared wire borrows values or caller scratch until writing completes. Constructed
//! arrays are reused by records in the same builder. Failed operations
//! may consume arena capacity; reset releases that storage and invalidates previous views.

const std = @import("std");
const cv = @import("../cv/source.zig");
const model = @import("model.zig");
const owned = @import("owned.zig");
const copy = @import("internal/owned_copy.zig");
const arrays = @import("../binary/arrays.zig");
const base64 = @import("../binary/base64.zig");
const encoding = @import("../binary/encoding.zig");
const zlib = @import("../binary/zlib.zig");
const schema = @import("schema.zig");

const Builder = @This();

/// Construction checks, codec errors, and bounded allocation failures.
pub const Error = owned.Error || schema.Error || arrays.Error || model.EncodingError || model.LookupError || error{
    InvalidDeclaration,
    InvalidRecord,
    InvalidArrayLength,
};

/// A caller-selected array role and its source unit. No role or lossy codec is inferred.
pub const ArrayOptions = struct {
    role: cv.Param,
    /// Document-local declaration ID used by the emitted primitive and codec terms.
    cv_ref: []const u8,
    encoding: arrays.EncodeOptions = .{},
    data_processing_ref: ?[]const u8 = null,
};

/// An encoded array with its known value count, used to check the enclosing record length.
pub const Array = struct {
    node: model.Node,
    length: usize,
    is_default: bool,
    /// Arrays may only be attached to records in this owner, before its next reset.
    owner: *const Builder,
};

/// Metadata belongs to the builder; wire borrows values or scratch until writing completes.
pub const PreparedArray = struct { array: Array, wire: []const u8 };

arena: std.heap.ArenaAllocator,
limits: owned.Limits,
remaining: usize,

/// Creates an empty owner without allocating. Do not copy an initialized builder.
pub fn init(allocator: std.mem.Allocator, limits: owned.Limits) Builder {
    return .{ .arena = .init(allocator), .limits = limits, .remaining = limits.bytes };
}

/// Releases all constructed objects.
pub fn deinit(self: *Builder) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Invalidates all views and releases arena storage, ready for another record or header.
pub fn reset(self: *Builder) void {
    _ = self.arena.reset(.free_all);
    self.remaining = self.limits.bytes;
}

/// Copies source fields within the byte and depth limits, without interpreting payloads.
pub fn node(self: *Builder, source: model.Node) Error!model.Node {
    if (self.limits.depth == 0 or self.limits.depth > 64) return error.LimitExceeded;
    var copier = self.makeCopier();
    defer self.remaining = copier.remaining;
    return copier.node(source, self.limits.depth);
}

/// Generates a schema list's count from its children and copies their complete content.
pub fn list(self: *Builder, kind: model.Kind, children: []const model.Node) Error!model.Node {
    var count: [32]u8 = undefined;
    return self.node(.{ .kind = kind, .attributes = &.{.{
        .name = "count",
        .value = std.fmt.bufPrint(&count, "{d}", .{children.len}) catch return error.LimitExceeded,
    }}, .children = children });
}

/// Constructs a vocabulary declaration from explicit source identity and version fields.
pub fn vocabulary(self: *Builder, declaration: cv.Declaration) Error!model.Node {
    if (declaration.id == null or declaration.full_name == null or declaration.uri == null)
        return error.InvalidDeclaration;
    const attrs = [_]model.Attribute{
        .{ .name = "id", .value = declaration.id.? },
        .{ .name = "fullName", .value = declaration.full_name.? },
        .{ .name = "URI", .value = declaration.uri.? },
        .{ .name = "version", .value = declaration.version orelse "" },
    };
    return self.node(.{ .kind = .cv, .attributes = attrs[0..if (declaration.version == null) @as(usize, 3) else 4] });
}

/// Formats a floating parameter using XML Schema spellings, preserving explicit units.
/// The caller supplies the accession and label; this does not resolve or type-check the term.
pub fn number(self: *Builder, parameter: cv.Param, value: f64) Error!cv.Param {
    var buffer: [64]u8 = undefined;
    var param = parameter;
    param.value = if (std.math.isNan(value)) "NaN" else if (std.math.isInf(value))
        (if (value < 0) "-INF" else "INF")
    else
        std.fmt.bufPrint(&buffer, "{e}", .{value}) catch return error.LimitExceeded;
    const result = try self.node(.{ .kind = .file_content, .params = &.{.{ .cv = param }} });
    return result.params[0].cv;
}

/// Encodes actual values and emits their primitive, codec, and encodedLength.
/// Default arrays omit arrayLength; auxiliary arrays carry arrayLength.
/// Output and scratch are caller-owned disjoint buffers; encoded bytes are copied into this owner.
/// Role labels and units are supplied explicitly, not looked up in an ontology.
pub fn binaryArray(
    self: *Builder,
    comptime T: type,
    values: []const T,
    options: ArrayOptions,
    output: []u8,
    scratch: arrays.Scratch,
    compressor: ?*zlib.Compressor,
) Error!Array {
    return (try self.buildArray(T, values, options, output, scratch, compressor, false)).array;
}

/// Encodes wire once and constructs metadata without retaining Base64.
pub fn prepareArray(self: *Builder, comptime T: type, values: []const T, options: ArrayOptions, scratch: arrays.Scratch, compressor: ?*zlib.Compressor) Error!PreparedArray {
    return self.buildArray(T, values, options, &.{}, scratch, compressor, true);
}

/// Reencodes values using copied source metadata, without copying the old payload.
/// Group references on this array become local parameters; header groups stay unchanged.
/// Replaces primitive/codec terms and lengths, preserving other fields and parameter order.
/// If a default array omits arrayLength, the caller must update the enclosing record's
/// defaultArrayLength when changing its length. Wire borrows values or caller scratch.
pub fn prepareArrayFrom(
    self: *Builder,
    comptime T: type,
    values: []const T,
    source: model.Node,
    groups: []const cv.Group,
    options: arrays.EncodeOptions,
    scratch: arrays.Scratch,
    compressor: ?*zlib.Compressor,
) Error!PreparedArray {
    if (self.limits.depth < 2 or self.limits.depth > 64) return error.LimitExceeded;
    const previous = try model.arrayEncoding(source, groups);
    if (source.children.len != 1 or source.children[0].kind != .binary) return error.InvalidStructure;
    const old_primitive = encoding.primitiveTerm(previous.primitive);
    const old_codec = encoding.codecTerm(previous.pipeline);
    const primitive = encoding.primitiveTerm(primitiveFor(T));
    const codec = encoding.codecTerm(options.pipeline);
    var iterator: cv.EffectiveIterator = .{ .entries = source.params, .groups = groups };
    var count: usize = 0;
    while (try iterator.next()) |_| {
        if (count == self.remaining / @sizeOf(cv.Entry)) return error.LimitExceeded;
        count += 1;
    }
    const wire = try arrays.encodeWire(T, values, options, scratch, compressor);
    var copier = self.makeCopier();
    defer self.remaining = copier.remaining;
    const params = try copier.alloc(cv.Entry, count);
    var is_default = false;
    iterator = .{ .entries = source.params, .groups = groups };
    for (params) |*entry| {
        entry.* = (try iterator.next()).?;
        if (entry.* != .cv) continue;
        const accession = entry.cv.accession orelse continue;
        is_default = is_default or accession.eql(model.Terms.MZ_ARRAY) or
            accession.eql(model.Terms.INTENSITY_ARRAY) or accession.eql(model.Terms.TIME_ARRAY);
        const term = if (std.mem.eql(u8, accession.raw, old_primitive.accession)) primitive else if (std.mem.eql(u8, accession.raw, old_codec.accession)) codec else continue;
        if (std.mem.eql(u8, accession.raw, term.accession)) continue;
        entry.cv.accession = .{ .raw = term.accession };
        entry.cv.name = term.name;
    }
    var encoded_length: [32]u8 = undefined;
    var array_length: [32]u8 = undefined;
    const encoded_text = std.fmt.bufPrint(&encoded_length, "{d}", .{try base64.encodedSize(wire.len)}) catch return error.LimitExceeded;
    const length_text = std.fmt.bufPrint(&array_length, "{d}", .{values.len}) catch return error.LimitExceeded;
    const attributes = try copier.alloc(model.Attribute, std.math.add(usize, source.attributes.len, 2) catch return error.LimitExceeded);
    @memcpy(attributes[0..source.attributes.len], source.attributes);
    var has_encoded_length = false;
    var has_array_length = false;
    for (attributes[0..source.attributes.len]) |*attribute| {
        if (attribute.namespace_uri != null) continue;
        if (std.mem.eql(u8, attribute.name, "encodedLength")) {
            attribute.value = encoded_text;
            has_encoded_length = true;
        } else if (std.mem.eql(u8, attribute.name, "arrayLength")) {
            attribute.value = length_text;
            has_array_length = true;
        }
    }
    var attribute_count = source.attributes.len;
    if (!has_encoded_length) {
        attributes[attribute_count] = .{ .name = "encodedLength", .value = encoded_text };
        attribute_count += 1;
    }
    if (!has_array_length and !is_default) {
        attributes[attribute_count] = .{ .name = "arrayLength", .value = length_text };
        attribute_count += 1;
    }
    var binary = source.children[0];
    binary.text = null;
    var result = source;
    result.attributes = attributes[0..attribute_count];
    result.params = params;
    result.children = &.{binary};
    return .{ .array = .{
        .node = try copier.node(result, self.limits.depth),
        .length = values.len,
        .is_default = is_default,
        .owner = self,
    }, .wire = wire };
}

fn buildArray(self: *Builder, comptime T: type, values: []const T, options: ArrayOptions, output: []u8, scratch: arrays.Scratch, compressor: ?*zlib.Compressor, comptime prepared: bool) Error!PreparedArray {
    if (self.limits.depth < 2 or self.limits.depth > 64) return error.LimitExceeded;
    if (options.cv_ref.len == 0 or options.role.cv_ref == null or options.role.accession == null or
        options.role.name == null) return error.InvalidDeclaration;
    const role = options.role.accession.?;
    const is_default = role.eql(model.Terms.MZ_ARRAY) or role.eql(model.Terms.INTENSITY_ARRAY) or role.eql(model.Terms.TIME_ARRAY);
    const primitive = encoding.primitiveTerm(primitiveFor(T));
    const codec = encoding.codecTerm(options.encoding.pipeline);
    const wire = if (prepared) try arrays.encodeWire(T, values, options.encoding, scratch, compressor) else &.{};
    const encoded: ?[]const u8 = if (prepared) null else try arrays.encode(T, output, values, options.encoding, scratch, compressor);
    const encoded_length = if (prepared) try base64.encodedSize(wire.len) else encoded.?.len;
    var length: [32]u8 = undefined;
    var count: [32]u8 = undefined;
    var attrs = [_]model.Attribute{
        .{ .name = "encodedLength", .value = std.fmt.bufPrint(&length, "{d}", .{encoded_length}) catch return error.LimitExceeded },
        .{ .name = "arrayLength", .value = std.fmt.bufPrint(&count, "{d}", .{values.len}) catch return error.LimitExceeded },
        .{ .name = "dataProcessingRef", .value = options.data_processing_ref orelse "" },
    };
    var attribute_count: usize = if (is_default) 1 else 2;
    if (options.data_processing_ref != null) {
        attrs[attribute_count] = attrs[2];
        attribute_count += 1;
    }
    const params = [_]cv.Entry{
        .{ .cv = options.role },
        .{ .cv = .{ .cv_ref = options.cv_ref, .accession = .{ .raw = primitive.accession }, .name = primitive.name } },
        .{ .cv = .{ .cv_ref = options.cv_ref, .accession = .{ .raw = codec.accession }, .name = codec.name } },
    };
    const result: model.Node = .{
        .kind = .binary_data_array,
        .attributes = attrs[0..attribute_count],
        .params = &params,
        .children = &.{.{ .kind = .binary, .text = encoded }},
    };
    _ = try model.arrayEncoding(result, &.{});
    const copied = try self.node(result);
    return .{ .array = .{ .node = copied, .length = values.len, .is_default = is_default, .owner = self }, .wire = wire };
}

/// Creates a spectrum or chromatogram with generated numeric attributes and copied children.
/// Arrays must belong to this builder; their storage is reused, not copied.
/// Other input slices are copied. Default arrays must match default_length.
/// This constructs new record attributes; use source node views to preserve existing ones.
pub fn record(
    self: *Builder,
    kind: model.Kind,
    id: []const u8,
    index: usize,
    default_length: usize,
    params: []const cv.Entry,
    children: []const model.Node,
    binary_arrays: []const Array,
) Error!model.Record {
    return self.recordInner(kind, id, index, default_length, params, children, binary_arrays, false);
}

/// Constructs metadata for writeRecordWithArrays; wire remains caller-owned.
pub fn preparedRecord(self: *Builder, kind: model.Kind, id: []const u8, index: usize, default_length: usize, params: []const cv.Entry, children: []const model.Node, binary_arrays: []const Array) Error!model.Record {
    return self.recordInner(kind, id, index, default_length, params, children, binary_arrays, true);
}

fn recordInner(self: *Builder, kind: model.Kind, id: []const u8, index: usize, default_length: usize, params: []const cv.Entry, children: []const model.Node, binary_arrays: []const Array, comptime prepared: bool) Error!model.Record {
    if (self.limits.depth == 0 or self.limits.depth > 64 or
        (binary_arrays.len != 0 and self.limits.depth < 4)) return error.LimitExceeded;
    if ((kind != .spectrum and kind != .chromatogram) or id.len == 0) return error.InvalidRecord;
    for (children) |child| if (child.kind == .binary_data_array_list) return error.InvalidRecord;
    for (binary_arrays) |array| {
        if (array.owner != self) return error.InvalidRecord;
        if (array.is_default and array.length != default_length) return error.InvalidArrayLength;
        if (!prepared) {
            const binary = array.node.child(.binary) orelse return error.PayloadNotRetained;
            if (binary.text == null) return error.PayloadNotRetained;
        }
    }
    const child_count = std.math.add(usize, children.len, @intFromBool(binary_arrays.len != 0)) catch return error.LimitExceeded;
    var copier = self.makeCopier();
    defer self.remaining = copier.remaining;
    const record_children = try copier.alloc(model.Node, child_count);
    for (children, record_children[0..children.len]) |child, *destination|
        destination.* = try copier.node(child, self.limits.depth -| 1);
    if (binary_arrays.len != 0) {
        const array_nodes = try copier.alloc(model.Node, binary_arrays.len);
        for (binary_arrays, array_nodes) |array, *destination| destination.* = array.node;
        var count_text: [32]u8 = undefined;
        var list_node = try copier.node(.{
            .kind = .binary_data_array_list,
            .attributes = &.{.{
                .name = "count",
                .value = std.fmt.bufPrint(&count_text, "{d}", .{binary_arrays.len}) catch return error.LimitExceeded,
            }},
        }, self.limits.depth);
        list_node.children = array_nodes;
        record_children[children.len] = list_node;
    }
    var index_text: [32]u8 = undefined;
    var length_text: [32]u8 = undefined;
    var result = try copier.node(.{ .kind = kind, .attributes = &.{
        .{ .name = "id", .value = id },
        .{ .name = "index", .value = std.fmt.bufPrint(&index_text, "{d}", .{index}) catch return error.LimitExceeded },
        .{ .name = "defaultArrayLength", .value = std.fmt.bufPrint(&length_text, "{d}", .{default_length}) catch return error.LimitExceeded },
    }, .params = params }, self.limits.depth);
    result.children = record_children;
    return .{ .node = result, .id = result.attribute("id").?, .index = index, .default_array_length = default_length };
}

/// Copies header metadata and derives group entries from the copied definitions.
pub fn header(self: *Builder, source: model.Header) Error!model.Header {
    if (self.limits.depth == 0 or self.limits.depth > 64) return error.LimitExceeded;
    try schema.checkHeader(source);
    var copier = self.makeCopier();
    defer self.remaining = copier.remaining;
    const document = try copier.node(source.document, self.limits.depth);
    const run = try copier.node(source.run, self.limits.depth);
    const group_nodes = if (document.child(.referenceable_param_group_list)) |groups| groups.children else &.{};
    const groups = try copier.alloc(cv.Group, group_nodes.len);
    for (group_nodes, groups) |group, *destination| destination.* = .{
        .id = group.attribute("id") orelse return error.MissingAttribute,
        .entries = group.params,
    };
    return .{ .document = document, .run = run, .namespace_uri = try copier.text(source.namespace_uri), .groups = groups };
}

fn makeCopier(self: *Builder) copy.Copier {
    return .{ .allocator = self.arena.allocator(), .remaining = self.remaining };
}

fn primitiveFor(comptime T: type) encoding.Primitive {
    return switch (T) {
        f32 => .float32,
        f64 => .float64,
        i32 => .int32,
        i64 => .int64,
        else => @compileError("array construction requires f32, f64, i32, or i64"),
    };
}
