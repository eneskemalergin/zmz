//! Internal shared copier for owned values and the builder.

const std = @import("std");
const cv = @import("../../cv/source.zig");
const model = @import("../model.zig");

pub const Error = std.mem.Allocator.Error || error{LimitExceeded};

pub const Copier = struct {
    allocator: std.mem.Allocator,
    remaining: usize,

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

    pub fn entries(self: *Copier, source: []const cv.Entry) Error![]const cv.Entry {
        const result = try self.alloc(cv.Entry, source.len);
        for (source, result) |value, *copy| copy.* = try self.entry(value);
        return result;
    }

    pub fn entry(self: *Copier, source: cv.Entry) Error!cv.Entry {
        return switch (source) {
            .group_ref => |ref| .{ .group_ref = .{ .ref = try self.optionalText(ref.ref), .xml = try self.xmlAttributes(ref.xml) } },
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

    fn attributes(self: *Copier, source: []const model.Attribute) Error![]const model.Attribute {
        const result = try self.alloc(model.Attribute, source.len);
        for (source, result) |attr, *copy| copy.* = try self.attribute(attr);
        return result;
    }

    pub fn attribute(self: *Copier, source: model.Attribute) Error!model.Attribute {
        return .{
            .name = try self.text(source.name),
            .namespace_uri = try self.optionalText(source.namespace_uri),
            .value = try self.text(source.value),
        };
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

    pub fn node(self: *Copier, source: model.Node, depth: usize) Error!model.Node {
        if (depth == 0) return error.LimitExceeded;
        var result = source;
        result.attributes = try self.attributes(source.attributes);
        result.params = try self.entries(source.params);
        result.text = try self.optionalText(source.text);
        if (source.content) |content| {
            const copied = &(try self.alloc(model.Content, 1))[0];
            const items = try self.alloc(model.Content.Item, content.items.len);
            for (content.items, items) |item, *copy| copy.* = switch (item) {
                .xml => |bytes| .{ .xml = try self.text(bytes) },
                else => item,
            };
            copied.* = .{ .items = items };
            result.content = copied;
        }
        const children = try self.alloc(model.Node, source.children.len);
        for (source.children, children) |child, *copy| copy.* = try self.node(child, depth - 1);
        result.children = children;
        return result;
    }

    pub fn list(self: *Copier, source: ?model.RecordList) Error!?model.RecordList {
        var result = source orelse return null;
        result.attributes = try self.attributes(result.attributes);
        return result;
    }
};
