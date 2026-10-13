//! Internal shared copier for owned values and the builder.

const std = @import("std");
const cv = @import("../../cv/source.zig");
const model = @import("../model.zig");
const schema = @import("../schema.zig");

pub const Error = std.mem.Allocator.Error || error{LimitExceeded};
// A header copy also reads each group's ID.
pub const HeaderError = Error || error{MissingAttribute};

pub const Copier = struct {
    allocator: std.mem.Allocator,
    remaining: usize,
    // The reader shares one attribute slice (a scope's namespace declarations) across many
    // nodes and parameters; the copy keeps it shared instead of copying it for each.
    shared: struct { source: []const model.Attribute = &.{}, copy: []const model.Attribute = &.{} } = .{},

    pub fn alloc(self: *Copier, comptime T: type, count: usize) Error![]T {
        const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.LimitExceeded;
        if (bytes > self.remaining) return error.LimitExceeded;
        self.remaining -= bytes;
        return self.allocator.alloc(T, count);
    }

    pub fn text(self: *Copier, source: []const u8) Error![]const u8 {
        const result = try self.alloc(u8, source.len);
        @memcpy(result, source);
        return result;
    }

    pub fn entry(self: *Copier, source: cv.Entry) Error!cv.Entry {
        return switch (source) {
            .group_ref => |ref| .{
                .group_ref = .{ .ref = try self.optionalText(ref.ref), .xml = try self.xmlAttributes(ref.xml), .position = ref.position },
            },
            .cv => |param| .{ .cv = .{
                .cv_ref = try self.optionalText(param.cv_ref),
                .accession = try self.accession(param.accession),
                .name = try self.optionalText(param.name),
                .value = try self.optionalText(param.value),
                .unit = try self.unit(param.unit),
                .xml = try self.xmlAttributes(param.xml),
            } },
            .user => |param| .{ .user = .{
                .name = try self.optionalText(param.name),
                .value = try self.optionalText(param.value),
                .value_type = try self.optionalText(param.value_type),
                .unit = try self.unit(param.unit),
                .xml = try self.xmlAttributes(param.xml),
            } },
        };
    }

    pub fn attribute(self: *Copier, source: model.Attribute) Error!model.Attribute {
        return .{
            .name = try self.text(source.name),
            .namespace_uri = try self.optionalText(source.namespace_uri),
            .value = try self.text(source.value),
        };
    }

    pub fn node(self: *Copier, source: model.Node, depth: usize) Error!model.Node {
        if (depth == 0) return error.LimitExceeded;
        var result = source;
        result.attributes = try self.attributes(source.attributes);
        result.params = try self.entries(source.params);
        result.text = try self.optionalText(source.text);
        if (source.content) |content| result.content = try self.contentOf(try self.contentItems(content.items));
        const children = try self.alloc(model.Node, source.children.len);
        for (source.children, children) |child, *copy| copy.* = try self.node(child, depth - 1);
        result.children = children;
        return result;
    }

    pub fn contentItems(self: *Copier, source: []const model.Content.Item) Error![]model.Content.Item {
        const items = try self.alloc(model.Content.Item, source.len);
        for (source, items) |item, *copy| copy.* = switch (item) {
            .xml => |bytes| .{ .xml = try self.text(bytes) },
            else => item,
        };
        return items;
    }

    pub fn contentOf(self: *Copier, items: []const model.Content.Item) Error!*const model.Content {
        const content = &(try self.alloc(model.Content, 1))[0];
        content.* = .{ .items = items };
        return content;
    }

    pub fn list(self: *Copier, source: ?model.RecordList) Error!?model.RecordList {
        var result = source orelse return null;
        result.attributes = try self.attributes(result.attributes);
        return result;
    }

    // Groups are derived from the copied group definitions, as the reader derives them, so their
    // entries are stored once; source.groups is not read.
    pub fn header(self: *Copier, source: model.Header) HeaderError!model.Header {
        var result = source;
        result.namespace_uri = try self.text(source.namespace_uri);
        result.document = try self.node(source.document, schema.MAX_DEPTH);
        result.run = try self.node(source.run, schema.MAX_DEPTH);
        const group_nodes = if (result.document.child(.referenceable_param_group_list)) |groups| groups.children else &.{};
        const groups = try self.alloc(cv.Group, group_nodes.len);
        for (group_nodes, groups) |group, *destination| destination.* = .{
            .id = group.attribute("id") orelse return error.MissingAttribute,
            .entries = group.params,
        };
        result.groups = groups;
        result.spectrum_list = try self.list(source.spectrum_list);
        result.chromatogram_list = try self.list(source.chromatogram_list);
        return result;
    }

    fn optionalText(self: *Copier, source: ?[]const u8) Error!?[]const u8 {
        return if (source) |bytes| try self.text(bytes) else null;
    }

    fn accession(self: *Copier, source: ?cv.Accession) Error!?cv.Accession {
        return if (source) |term| .{ .raw = try self.text(term.raw) } else null;
    }

    fn unit(self: *Copier, source: cv.Unit) Error!cv.Unit {
        return .{
            .cv_ref = try self.optionalText(source.cv_ref),
            .accession = try self.accession(source.accession),
            .name = try self.optionalText(source.name),
        };
    }

    fn entries(self: *Copier, source: []const cv.Entry) Error![]const cv.Entry {
        const result = try self.alloc(cv.Entry, source.len);
        for (source, result) |value, *copy| copy.* = try self.entry(value);
        return result;
    }

    fn attributes(self: *Copier, source: []const model.Attribute) Error![]const model.Attribute {
        if (source.len != 0 and source.ptr == self.shared.source.ptr and source.len == self.shared.source.len) return self.shared.copy;
        const result = try self.alloc(model.Attribute, source.len);
        for (source, result) |attr, *copy| copy.* = try self.attribute(attr);
        self.shared = .{ .source = source, .copy = result };
        return result;
    }

    fn xmlAttributes(self: *Copier, source: ?*const cv.ParameterXml) Error!?*const cv.ParameterXml {
        const value = source orelse return null;
        const result = &(try self.alloc(cv.ParameterXml, 1))[0];
        const content = try self.alloc(cv.ParameterXml.Part, value.content.len);
        for (value.content, content) |part, *copied| copied.* = switch (part) {
            .text => |bytes| .{ .text = try self.text(bytes) },
            .xml => |bytes| .{ .xml = try self.text(bytes) },
        };
        result.* = .{ .attributes = try self.attributes(value.attributes), .content = content };
        return result;
    }
};
