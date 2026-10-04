//! Constructs owned mzML metadata and encoded arrays within a byte limit.
//!
//! Returned metadata is copied from its inputs and lasts until reset or deinit. A prepared payload
//! is an `arrays.Source` that borrows its values and the encoder until the record is written.
//! Failed operations may consume arena capacity; reset releases it and invalidates earlier
//! views. Do not copy an initialized builder: a copy shares its arena, and both `deinit`s would
//! free it.

const std = @import("std");
const cv = @import("../cv/source.zig");
const arrays = @import("../binary/arrays.zig");
const encoding = @import("../binary/encoding.zig");
const xml = @import("../xml/mzml_adapter.zig");
const model = @import("model.zig");
const owned = @import("owned.zig");
const schema = @import("schema.zig");
const Writer = @import("writer.zig");
const copy = @import("internal/owned_copy.zig");

const Builder = @This();

pub const Error = owned.Error || schema.Error || arrays.OptionsError || model.EncodingError || error{
    InvalidOptions,
    InvalidState,
    GroupRewriteRequired,
};

/// The caller chooses the role, its unit, and the encoding; none is inferred.
pub const ArrayOptions = struct {
    role: cv.Param,
    /// Document-local declaration ID used by the emitted primitive and codec terms.
    cv_ref: []const u8,
    encoding: arrays.EncodeOptions = .{},
    data_processing_ref: ?[]const u8 = null,
    /// Writes `value=""` on the primitive and codec terms generated here, as ProteoWizard does;
    /// by default they have no value attribute.
    empty_values: bool = false,
};

/// Array metadata with its known value count, used to check the enclosing record length.
pub const Array = struct {
    node: model.Node,
    length: usize,
    is_default: bool,
    /// Arrays may only be attached to records in this owner, before its next reset.
    owner: *const Builder,
    generation: usize,
};

/// Array metadata and the payload the writer encodes while writing it. The values and the
/// encoder stay borrowed until the record is written.
pub const PreparedArray = struct { array: Array, payload: Writer.ArrayPayload };

/// Prepared header and reference replacements, owned by the creating builder.
/// Write header before records and keep this owner alive through the last preparation.
/// Use a separate builder for arrays that are reset between records.
pub const Reencoding = struct {
    header: model.Header,
    source_groups: []const cv.Group,
    replacements: []const GroupReplacement,
    owner: *const Builder,
    generation: usize,

    /// Like builder.prepareArrayFrom, moving references to the prepared group definitions.
    /// InvalidState once the creating builder was reset.
    pub fn prepareArray(
        self: Reencoding,
        builder: *Builder,
        comptime T: type,
        values: []const T,
        source: model.Node,
        options: arrays.EncodeOptions,
        encoder: *arrays.Encoder,
    ) Error!PreparedArray {
        if (self.owner.generation != self.generation) return error.InvalidState;
        return builder.prepareArrayFromInner(T, values, source, self.source_groups, options, encoder, self.replacements);
    }
};

arena: std.heap.ArenaAllocator,
limits: owned.Limits,
remaining: usize,
// Counts resets, so arrays and reencodings from before one are refused.
generation: usize = 0,

pub fn init(allocator: std.mem.Allocator, limits: owned.Limits) Builder {
    return .{ .arena = .init(allocator), .limits = limits, .remaining = limits.bytes };
}

pub fn deinit(self: *Builder) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Invalidates all views and releases arena storage, ready for another record or header.
pub fn reset(self: *Builder) void {
    _ = self.arena.reset(.free_all);
    self.remaining = self.limits.bytes;
    self.generation +%= 1;
}

/// Copies a node, including any binary text, within the byte limit and MAX_DEPTH.
pub fn node(self: *Builder, source: model.Node) Error!model.Node {
    var copier = self.makeCopier();
    defer self.remaining = copier.remaining;
    return copier.node(source, schema.MAX_DEPTH);
}

/// Generates a schema list's count from its children and copies their complete content.
pub fn list(self: *Builder, kind: model.Kind, children: []const model.Node) Error!model.Node {
    var count: [32]u8 = undefined;
    return self.node(.{ .kind = kind, .attributes = &.{.{
        .name = "count",
        .value = count[0..std.fmt.printInt(&count, children.len, 10, .lower, .{})],
    }}, .children = children });
}

/// Constructs a `cv` declaration from explicit source identity and version fields. `id`,
/// `full_name`, and `uri` are required (`InvalidOptions` otherwise).
pub fn cvDeclaration(self: *Builder, declaration: cv.Declaration) Error!model.Node {
    if (declaration.id == null or declaration.full_name == null or declaration.uri == null)
        return error.InvalidOptions;
    const attrs = [_]model.Attribute{
        .{ .name = "id", .value = declaration.id.? },
        .{ .name = "fullName", .value = declaration.full_name.? },
        .{ .name = "URI", .value = declaration.uri.? },
        .{ .name = "version", .value = declaration.version orelse "" },
    };
    return self.node(.{ .kind = .cv, .attributes = attrs[0..if (declaration.version == null) @as(usize, 3) else 4] });
}

/// Builds a spectrum or chromatogram with new id, index, and defaultArrayLength attributes, for
/// `writeRecordWithArrays` with the arrays' payloads. Arrays from another builder, or prepared
/// before this builder's last reset, are `InvalidState`; default arrays must match
/// `default_length`. To keep a source record's attributes, edit a view of its node instead.
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
    if ((kind != .spectrum and kind != .chromatogram) or id.len == 0) return error.InvalidOptions;
    for (children) |child| if (child.kind == .binary_data_array_list) return error.InvalidOptions;
    for (binary_arrays) |array| {
        if (array.owner != self or array.generation != self.generation) return error.InvalidState;
        if (array.is_default and array.length != default_length) return error.InvalidOptions;
    }
    const child_count = std.math.add(usize, children.len, @intFromBool(binary_arrays.len != 0)) catch return error.LimitExceeded;
    var copier = self.makeCopier();
    defer self.remaining = copier.remaining;
    const record_children = try copier.alloc(model.Node, child_count);
    for (children, record_children[0..children.len]) |child, *destination|
        destination.* = try copier.node(child, schema.MAX_DEPTH - 1);
    if (binary_arrays.len != 0) {
        const array_nodes = try copier.alloc(model.Node, binary_arrays.len);
        for (binary_arrays, array_nodes) |array, *destination| destination.* = array.node;
        var count_text: [32]u8 = undefined;
        var list_node = try copier.node(.{
            .kind = .binary_data_array_list,
            .attributes = &.{.{
                .name = "count",
                .value = count_text[0..std.fmt.printInt(&count_text, binary_arrays.len, 10, .lower, .{})],
            }},
        }, schema.MAX_DEPTH);
        list_node.children = array_nodes;
        record_children[children.len] = list_node;
    }
    var index_text: [32]u8 = undefined;
    var length_text: [32]u8 = undefined;
    var result = try copier.node(.{ .kind = kind, .attributes = &.{
        .{ .name = "id", .value = id },
        .{ .name = "index", .value = index_text[0..std.fmt.printInt(&index_text, index, 10, .lower, .{})] },
        .{ .name = "defaultArrayLength", .value = length_text[0..std.fmt.printInt(&length_text, default_length, 10, .lower, .{})] },
    }, .params = params }, schema.MAX_DEPTH);
    result.children = record_children;
    return .{ .node = result, .id = result.attribute("id").?, .index = index, .default_array_length = default_length };
}

/// Copies header metadata and derives group entries from the copied definitions.
pub fn header(self: *Builder, source: model.Header) Error!model.Header {
    try schema.checkHeader(source);
    var copier = self.makeCopier();
    defer self.remaining = copier.remaining;
    // Only the metadata: list descriptors and the index flag are reader state.
    return copier.header(.{ .document = source.document, .run = source.run, .namespace_uri = source.namespace_uri });
}

/// Builds a cvParam whose value is the number in XML Schema spelling, with the caller's
/// accession, name, and unit as given.
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

/// Builds array metadata with its primitive and codec terms, and a payload that the writer
/// encodes while writing (with encoder's compressor or buffer when needed). Options are
/// checked here; Numpress value errors surface when the record is written. Default arrays
/// (m/z, intensity, time) omit arrayLength; others carry it. The metadata has no
/// encodedLength: the writer writes it first, from the text it writes.
pub fn prepareArray(
    self: *Builder,
    comptime T: type,
    values: []const T,
    options: ArrayOptions,
    encoder: *arrays.Encoder,
) Error!PreparedArray {
    try checkArrayOptions(options);
    const source = arrays.Source.of(T, values, options.encoding, encoder);
    try source.check();
    return .{
        .array = try self.arrayMetadata(T, values.len, options),
        .payload = .{ .source = source },
    };
}

/// Prepares values under a copy of the source array's metadata, like prepareArray, replacing its
/// primitive, codec, and arrayLength and keeping other fields in order; the writer replaces
/// encodedLength. Bare group references become local parameters; changing an annotated group's
/// encoding needs a Reencoding header and otherwise returns GroupRewriteRequired. If a default
/// array omits arrayLength, update the record's defaultArrayLength when the length changes.
pub fn prepareArrayFrom(
    self: *Builder,
    comptime T: type,
    values: []const T,
    source: model.Node,
    groups: []const cv.Group,
    options: arrays.EncodeOptions,
    encoder: *arrays.Encoder,
) Error!PreparedArray {
    return self.prepareArrayFromInner(T, values, source, groups, options, encoder, null);
}

/// Copies a header and adds a group definition for each requested output encoding, keeping
/// the originals for unchanged arrays; equivalent replacements share one definition.
pub fn reencoding(self: *Builder, source: model.Header, targets: []const model.Encoding) Error!Reencoding {
    var header_copy = try self.header(source);
    const source_groups = header_copy.groups;
    var count: usize = 0;
    for (source_groups) |group| for (targets, 0..) |_, i| {
        if (groupReplacement(group.entries, targets, i) != null)
            count = std.math.add(usize, count, 1) catch return error.LimitExceeded;
    };
    if (count == 0) return .{
        .header = header_copy,
        .source_groups = source_groups,
        .replacements = &.{},
        .owner = self,
        .generation = self.generation,
    };
    var copier = self.makeCopier();
    defer self.remaining = copier.remaining;
    const replacements = try copier.alloc(GroupReplacement, count);
    const total = std.math.add(usize, source_groups.len, count) catch return error.LimitExceeded;
    const groups = try copier.alloc(cv.Group, total);
    @memcpy(groups[0..source_groups.len], source_groups);
    // Every group ID in use, including those of extra group lists, so each new ID is checked once.
    var used_ids: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
    defer used_ids.deinit();
    var used: std.StringHashMapUnmanaged(void) = .empty;
    for (source_groups) |group| try used.put(used_ids.allocator(), cv.idKey(group.id), {});
    addExtraGroupIds(used_ids.allocator(), header_copy, &used) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LimitExceeded => return error.LimitExceeded,
        else => return error.InvalidStructure,
    };
    for (@constCast(header_copy.document.children)) |*list_node| {
        if (list_node.kind != .referenceable_param_group_list) continue;
        const original_nodes = list_node.children;
        const nodes = try copier.alloc(model.Node, total);
        @memcpy(nodes[0..original_nodes.len], original_nodes);
        var next: usize = source_groups.len;
        var serial: usize = 0;
        for (original_nodes, source_groups) |group_node, group| for (targets, 0..) |target, i| {
            const key = groupReplacement(group.entries, targets, i) orelse continue;
            var id_buffer: [64]u8 = undefined;
            const id = while (true) {
                const candidate = std.fmt.bufPrint(&id_buffer, "zmz-reencoded-{d}", .{serial}) catch return error.LimitExceeded;
                serial = std.math.add(usize, serial, 1) catch return error.LimitExceeded;
                if (used.contains(candidate)) continue;
                const chosen = try copier.text(candidate);
                try used.put(used_ids.allocator(), chosen, {});
                break chosen;
            };
            var node_copy = group_node;
            const attributes = try copier.alloc(model.Attribute, group_node.attributes.len);
            @memcpy(attributes, group_node.attributes);
            for (attributes) |*attribute| {
                if (attribute.namespace_uri == null and std.mem.eql(u8, attribute.name, "id")) attribute.value = id;
            }
            const params = try copier.alloc(cv.Entry, group_node.params.len);
            for (group_node.params, params) |entry, *destination| destination.* = reencodedParam(entry, target);
            node_copy.attributes = attributes;
            node_copy.params = params;
            nodes[next] = node_copy;
            groups[next] = .{ .id = id, .entries = params };
            replacements[next - source_groups.len] = .{ .source_id = group.id, .encoding = key, .id = id };
            next += 1;
        };
        var count_buffer: [32]u8 = undefined;
        const count_text = try copier.text(count_buffer[0..std.fmt.printInt(&count_buffer, total, 10, .lower, .{})]);
        const attributes = try copier.alloc(model.Attribute, list_node.attributes.len + 1);
        @memcpy(attributes[0..list_node.attributes.len], list_node.attributes);
        var found = false;
        for (attributes[0..list_node.attributes.len]) |*attribute| {
            if (attribute.namespace_uri == null and std.mem.eql(u8, attribute.name, "count")) {
                attribute.value = count_text;
                found = true;
            }
        }
        attributes[list_node.attributes.len] = .{ .name = "count", .value = count_text };
        list_node.attributes = attributes[0 .. list_node.attributes.len + @intFromBool(!found)];
        list_node.children = nodes;
        if (list_node.content) |content| {
            const items = try copier.alloc(model.Content.Item, content.items.len + 1);
            @memcpy(items[0..content.items.len], content.items);
            items[content.items.len] = .{ .children = count };
            list_node.content = try copier.contentOf(items);
        }
        break;
    }
    header_copy.groups = groups;
    return .{
        .header = header_copy,
        .source_groups = source_groups,
        .replacements = replacements,
        .owner = self,
        .generation = self.generation,
    };
}

fn prepareArrayFromInner(
    self: *Builder,
    comptime T: type,
    values: []const T,
    source: model.Node,
    groups: []const cv.Group,
    options: arrays.EncodeOptions,
    encoder: *arrays.Encoder,
    replacements: ?[]const GroupReplacement,
) Error!PreparedArray {
    _ = try model.arrayEncoding(source, groups);
    if (source.children.len != 1 or source.children[0].kind != .binary) return error.InvalidStructure;
    const target: model.Encoding = .{ .primitive = encoding.Primitive.of(T), .pipeline = options.pipeline };
    const counted = try reencodedParams(null, source.params, groups, target, replacements, self.remaining / @sizeOf(cv.Entry));
    const prepared = arrays.Source.of(T, values, options, encoder);
    try prepared.check();
    var copier = self.makeCopier();
    defer self.remaining = copier.remaining;
    const params = try copier.alloc(cv.Entry, counted.count);
    _ = try reencodedParams(params, source.params, groups, target, replacements, params.len);
    for (params) |*entry| entry.* = try copier.entry(entry.*);
    const is_default = counted.is_default;
    var array_length: [32]u8 = undefined;
    const length_text = array_length[0..std.fmt.printInt(&array_length, values.len, 10, .lower, .{})];
    const add_array_length = !is_default and source.attribute("arrayLength") == null;
    const added: usize = @intFromBool(add_array_length);
    const attributes = try copier.alloc(
        model.Attribute,
        std.math.add(usize, source.attributes.len, added) catch return error.LimitExceeded,
    );
    for (source.attributes, attributes[0..source.attributes.len]) |attribute, *destination| {
        var changed = attribute;
        if (attribute.namespace_uri == null and std.mem.eql(u8, attribute.name, "arrayLength")) changed.value = length_text;
        destination.* = try copier.attribute(changed);
    }
    if (add_array_length) {
        attributes[source.attributes.len] = try copier.attribute(.{ .name = "arrayLength", .value = length_text });
    }
    var binary = source.children[0];
    binary.text = null;
    const children = try copier.alloc(model.Node, 1);
    children[0] = try copier.node(binary, schema.MAX_DEPTH - 1);
    var result = source;
    result.attributes = attributes;
    result.params = params;
    result.children = children;
    result.text = if (source.text) |text| try copier.text(text) else null;
    if (source.content) |content| {
        const items = try copier.contentItems(content.items);
        var position: usize = 0;
        for (items) |*item| {
            if (item.* != .params) continue;
            const count = item.params;
            if (count > source.params.len - position) return error.InvalidStructure;
            const run = try reencodedParams(null, source.params[position..][0..count], groups, target, replacements, params.len);
            item.* = .{ .params = run.count };
            position += count;
        }
        if (position != source.params.len) return error.InvalidStructure;
        result.content = try copier.contentOf(items);
    }
    return .{ .array = .{
        .node = result,
        .length = values.len,
        .is_default = is_default,
        .owner = self,
        .generation = self.generation,
    }, .payload = .{ .source = prepared } };
}

fn checkArrayOptions(options: ArrayOptions) Error!void {
    if (options.cv_ref.len == 0 or options.role.cv_ref == null or options.role.accession == null or
        options.role.name == null) return error.InvalidOptions;
}

fn arrayMetadata(self: *Builder, comptime T: type, value_count: usize, options: ArrayOptions) Error!Array {
    const is_default = isDefaultRole(options.role.accession.?);
    const primitive = encoding.primitiveTerm(encoding.Primitive.of(T));
    const codec = encoding.codecTerm(options.encoding.pipeline);
    var count: [32]u8 = undefined;
    var attrs = [_]model.Attribute{
        .{ .name = "arrayLength", .value = count[0..std.fmt.printInt(&count, value_count, 10, .lower, .{})] },
        .{ .name = "dataProcessingRef", .value = options.data_processing_ref orelse "" },
    };
    var attribute_count: usize = if (is_default) 0 else 1;
    if (options.data_processing_ref != null) {
        attrs[attribute_count] = attrs[1];
        attribute_count += 1;
    }
    const value: ?[]const u8 = if (options.empty_values) "" else null;
    const params = [_]cv.Entry{
        .{ .cv = options.role },
        .{ .cv = .{ .cv_ref = options.cv_ref, .accession = .{ .raw = primitive.accession }, .name = primitive.name, .value = value } },
        .{ .cv = .{ .cv_ref = options.cv_ref, .accession = .{ .raw = codec.accession }, .name = codec.name, .value = value } },
    };
    const result: model.Node = .{
        .kind = .binary_data_array,
        .attributes = attrs[0..attribute_count],
        .params = &params,
        .children = &.{.{ .kind = .binary }},
    };
    _ = try model.arrayEncoding(result, &.{});
    return .{
        .node = try self.node(result),
        .length = value_count,
        .is_default = is_default,
        .owner = self,
        .generation = self.generation,
    };
}

const GroupEncoding = struct { primitive: ?model.Primitive = null, pipeline: ?arrays.Pipeline = null };
const GroupReplacement = struct { source_id: []const u8, encoding: GroupEncoding, id: []const u8 };

// Extra group lists are not expanded, but their IDs must not be reused.
fn addExtraGroupIds(
    allocator: std.mem.Allocator,
    header_value: model.Header,
    used: *std.StringHashMapUnmanaged(void),
) (xml.InitError || xml.AdvanceError)!void {
    const content = header_value.document.content orelse return;
    for (content.items) |item| {
        if (item != .xml) continue;
        var input = std.Io.Reader.fixed(item.xml);
        var cursor = try xml.Cursor.init(allocator, &input, @max(1, item.xml.len / 4), item.xml.len);
        defer cursor.deinit();
        try cursor.advanceFragment(false);
        const root = cursor.current orelse return error.InvalidXml;
        if (root.data != .start_element or
            !root.data.start_element.name.eql(header_value.namespace_uri, "referenceableParamGroupList")) continue;
        while (true) {
            try cursor.advanceFragment(true);
            const event = cursor.current orelse break;
            if (event.data != .start_element or cursor.depth != 2) continue;
            const start = event.data.start_element;
            if (!start.name.eql(header_value.namespace_uri, "referenceableParamGroup")) continue;
            if (start.attribute(null, "id")) |attribute| try used.put(allocator, try allocator.dupe(u8, cv.idKey(attribute.value)), {});
        }
    }
}

fn changedGroupEncoding(entries: []const cv.Entry, target: model.Encoding) ?GroupEncoding {
    var result: GroupEncoding = .{};
    var changed = false;
    for (entries) |entry| {
        if (entry != .cv) continue;
        const accession = entry.cv.accession orelse continue;
        if (encoding.primitiveFromAccession(accession.raw)) |primitive| {
            result.primitive = target.primitive;
            changed = changed or primitive != target.primitive;
        }
        if (encoding.codecFromAccession(accession.raw)) |pipeline| {
            result.pipeline = target.pipeline;
            changed = changed or pipeline != target.pipeline;
        }
    }
    return if (changed) result else null;
}

fn groupReplacement(entries: []const cv.Entry, targets: []const model.Encoding, position: usize) ?GroupEncoding {
    const key = changedGroupEncoding(entries, targets[position]) orelse return null;
    for (targets[0..position]) |previous| {
        if (std.meta.eql(@as(?GroupEncoding, key), changedGroupEncoding(entries, previous))) return null;
    }
    return key;
}

fn reencodedParam(source: cv.Entry, target: model.Encoding) cv.Entry {
    var entry = source;
    if (entry != .cv) return entry;
    const accession = entry.cv.accession orelse return entry;
    const term = if (encoding.primitiveFromAccession(accession.raw) != null)
        encoding.primitiveTerm(target.primitive)
    else if (encoding.codecFromAccession(accession.raw) != null)
        encoding.codecTerm(target.pipeline)
    else
        return entry;
    if (!std.mem.eql(u8, accession.raw, term.accession)) {
        entry.cv.accession = .{ .raw = term.accession };
        entry.cv.name = term.name;
    }
    return entry;
}

fn isDefaultParam(entry: cv.Entry) bool {
    if (entry != .cv) return false;
    return isDefaultRole(entry.cv.accession orelse return false);
}

// Default m/z, intensity, and time arrays take the record's defaultArrayLength.
fn isDefaultRole(accession: cv.Accession) bool {
    return accession.eql(model.Terms.MZ_ARRAY) or accession.eql(model.Terms.INTENSITY_ARRAY) or accession.eql(model.Terms.TIME_ARRAY);
}

const ParamCount = struct { count: usize = 0, is_default: bool = false };

fn reencodedParams(
    output: ?[]cv.Entry,
    params: []const cv.Entry,
    groups: []const cv.Group,
    target: model.Encoding,
    replacements: ?[]const GroupReplacement,
    limit: usize,
) Error!ParamCount {
    var result: ParamCount = .{};
    for (params, 0..) |entry, position| {
        if (entry == .group_ref and (entry.group_ref.xml != null or replacements != null)) {
            const id = entry.group_ref.ref orelse return error.MissingGroup;
            const entries = entries: {
                for (groups) |group| if (cv.sameId(id, group.id)) break :entries group.entries;
                return error.MissingGroup;
            };
            var retained = entry;
            if (changedGroupEncoding(entries, target)) |key| {
                retained.group_ref.ref = replacement: {
                    for (replacements orelse return error.GroupRewriteRequired) |replacement| {
                        if (cv.sameId(id, replacement.source_id) and std.meta.eql(key, replacement.encoding))
                            break :replacement replacement.id;
                    }
                    return error.GroupRewriteRequired;
                };
            }
            for (entries) |member| result.is_default = result.is_default or isDefaultParam(member);
            if (result.count == limit) return error.LimitExceeded;
            if (output) |destination| destination[result.count] = retained;
            result.count += 1;
        } else {
            var iterator: cv.EffectiveIterator = .{ .entries = params[position..][0..1], .groups = groups };
            while (try iterator.next()) |member| {
                if (result.count == limit) return error.LimitExceeded;
                if (output) |destination| destination[result.count] = reencodedParam(member, target);
                result.count += 1;
                result.is_default = result.is_default or isDefaultParam(member);
            }
        }
    }
    return result;
}

fn makeCopier(self: *Builder) copy.Copier {
    return .{ .allocator = self.arena.allocator(), .remaining = self.remaining };
}
