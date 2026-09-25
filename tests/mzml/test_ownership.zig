//! Tests independent ownership of parsed metadata and records.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

test "[integration] - [mzML 1.0 copies]: keeps header and record metadata after reader reuse" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var builder = mzml.Builder.init(allocator, .{});
            defer builder.deinit();
            var header: mzml.owned.Header = undefined;
            var record: mzml.owned.Record = undefined;
            const built = blk: {
                var input = std.Io.Reader.fixed(support.HISTORICAL);
                var reader = try mzml.StreamReader.init(allocator, &input, .{});
                defer reader.deinit();
                const source = try reader.readHeader();
                header = try mzml.owned.Header.init(allocator, source.*, .{});
                errdefer header.deinit();
                const copied = try builder.header(source.*);
                record = try mzml.owned.Record.init(allocator, (try reader.nextRecord()).?, .{});
                errdefer record.deinit();
                while (try reader.nextRecord()) |_| {}
                break :blk copied;
            };
            defer header.deinit();
            defer record.deinit();
            try std.testing.expectEqualStrings("http://psi.hupo.org/schema_revision/mzML_1.0.0", header.value.namespace_uri);
            try std.testing.expectEqualStrings(header.value.namespace_uri, built.namespace_uri);
            try support.expectNode(header.value.document, built.document);
            try support.expectNode(header.value.run, built.run);
            try std.testing.expectEqual(mzml.model.Polarity.positive, (try record.value.polarity(header.value.groups)).?);
            try std.testing.expectEqualStrings("19", record.value.node.attribute("nativeID").?);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "[integration] - [mzML ownership]: retains grouped records after reader closure and cleans failed copies" {
    try support.copyRetained(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.copyRetained, .{});
}

test "[integration] - [mzML ownership]: copies optional text and bounds storage and nesting" {
    var text = [_]u8{'x'};
    const source: mzml.model.Record = .{
        .id = &text,
        .index = 3,
        .default_array_length = 0,
        .node = .{ .kind = .spectrum, .attributes = &.{.{ .name = &text, .namespace_uri = &text, .value = &text }}, .params = &.{
            .{ .user = .{ .name = &text, .value = "", .value_type = &text, .unit = .{ .cv_ref = &text, .name = &text, .accession = .{ .raw = &text } } } },
            .{ .cv = .{ .cv_ref = &text, .accession = .{ .raw = &text }, .name = &text, .value = &text, .unit = .{ .name = "" } } },
            .{ .group_ref = &text },
        }, .children = &.{.{ .kind = .binary, .text = null }} },
    };
    var copy = try mzml.owned.Record.init(std.testing.allocator, source, .{ .depth = 2 });
    defer copy.deinit();
    text[0] = 'y';
    try std.testing.expectEqualStrings("x", copy.value.id);
    try std.testing.expectEqualStrings("x", copy.value.node.attributes[0].namespace_uri.?);
    try std.testing.expectEqualStrings("x", copy.value.node.params[0].user.unit.accession.?.raw);
    try std.testing.expectEqualStrings("", copy.value.node.params[0].user.value.?);
    try std.testing.expectEqualStrings("x", copy.value.node.params[1].cv.value.?);
    try std.testing.expectEqualStrings("x", copy.value.node.params[2].group_ref.?);
    try std.testing.expectEqual(null, copy.value.node.children[0].text);
    try std.testing.expectError(error.LimitExceeded, mzml.owned.Record.init(std.testing.allocator, source, .{ .depth = 1 }));
    try std.testing.expectError(error.LimitExceeded, mzml.owned.Record.init(std.testing.allocator, source, .{ .bytes = 0 }));
    const minimal: mzml.model.Record = .{ .id = "x", .index = 0, .default_array_length = 0, .node = .{ .kind = .spectrum } };
    var exact = try mzml.owned.Record.init(std.testing.allocator, minimal, .{ .bytes = 1, .depth = 1 });
    defer exact.deinit();
    try std.testing.expectEqualStrings("x", exact.value.id);
}
