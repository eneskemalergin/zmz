//! Tests independent ownership of parsed metadata and records.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

test "[integration] - [mzML extensions]: owns XML after reader closure and cleans failed copies" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var builder = mzml.Builder.init(allocator, .{});
            defer builder.deinit();
            var header: mzml.owned.Header = undefined;
            var record: mzml.owned.Record = undefined;
            const built = blk: {
                var input = std.Io.Reader.fixed(support.EXTENSIONS);
                var reader = try mzml.StreamReader.init(allocator, &input, .{});
                defer reader.deinit();
                header = try mzml.owned.Header.init(allocator, (try reader.readHeader()).*, .{});
                errdefer header.deinit();
                record = try mzml.owned.Record.init(allocator, (try reader.nextRecord()).?, .{});
                errdefer record.deinit();
                const copy = try builder.node(record.value.node);
                break :blk copy;
            };
            defer header.deinit();
            defer record.deinit();
            try support.expectNode(record.value.node, built);
            try std.testing.expectEqualStrings("keep", record.value.node.params[0].user.xml.?.attributes[4].value);
            var bytes: [32768]u8 = undefined;
            var sink = std.Io.Writer.fixed(&bytes);
            var writer = try mzml.Writer.initIndexed(allocator, &sink, .{}, .{});
            defer writer.deinit();
            try writer.writeHeader(header.value);
            try writer.beginListWithAttributes(.spectrum_list, 1, header.value.spectrum_list.?.attributes);
            try writer.writeRecord(built);
            try writer.endList();
            try writer.finish();
            var index = try mzml.IndexedReader.build(allocator, .{ .bytes = sink.buffered() }, .{});
            defer index.deinit();
            var output = mzml.DecodedArrays.init(allocator, .{});
            defer output.deinit();
            var found = (try index.byIdDecoded(allocator, "scan=1", &output)).?;
            defer found.deinit();
            try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, output.get(0).?.values.float64);
            try std.testing.expectEqualSlices(f64, &.{ 3, 4 }, output.get(1).?.values.float64);
            try std.testing.expect(found.value.node.content != null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

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

fn copyRetained(allocator: std.mem.Allocator) !void {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var header: mzml.owned.Header = undefined;
    var record: mzml.owned.Record = undefined;
    {
        var reader = try mzml.StreamReader.init(allocator, &input, .{});
        defer reader.deinit();
        const source_header = try reader.readHeader();
        const source_record = (try reader.nextRecord()).?;
        header = try mzml.owned.Header.init(allocator, source_header.*, .{});
        errdefer header.deinit();
        record = try mzml.owned.Record.init(allocator, source_record, .{});
        errdefer record.deinit();
        try support.expectNode(source_header.document, header.value.document);
        try support.expectNode(source_header.run, header.value.run);
        try std.testing.expectEqualDeep(source_header.groups, header.value.groups);
        try std.testing.expectEqualDeep(source_header.spectrum_list, header.value.spectrum_list);
        try support.expectNode(source_record.node, record.value.node);
        try std.testing.expectEqual(source_record.node.start_offset, record.value.node.start_offset);
        try std.testing.expectEqual(source_record.node.end_offset, record.value.node.end_offset);
        while (try reader.nextRecord()) |_| {}
    }
    defer header.deinit();
    defer record.deinit();
    try std.testing.expectEqualStrings("native=a&b", record.value.id);
    try std.testing.expectEqualStrings("A&B", header.value.document.child(.file_description).?.child(.file_content).?.params[0].cv.name.?);
    var output: [1]f64 = undefined;
    var transport: [16]u8 = undefined;
    var transformed: [16]u8 = undefined;
    for (record.value.binaryArrays()) |array| {
        _ = try mzml.model.decodeArray(f64, &output, array, record.value.default_array_length, header.value.groups, .{
            .transport = &transport,
            .transformed = &transformed,
        });
        try std.testing.expectEqual(@as(f64, 1), output[0]);
    }
}

test "[integration] - [mzML ownership]: retains grouped records after reader closure and cleans failed copies" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyRetained, .{});
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
            .{ .group_ref = .{ .ref = &text } },
        }, .children = &.{.{ .kind = .binary, .text = null }} },
    };
    var copy = try mzml.owned.Record.init(std.testing.allocator, source, .{});
    defer copy.deinit();
    text[0] = 'y';
    try std.testing.expectEqualStrings("x", copy.value.id);
    try std.testing.expectEqualStrings("x", copy.value.node.attributes[0].namespace_uri.?);
    try std.testing.expectEqualStrings("x", copy.value.node.params[0].user.unit.accession.?.raw);
    try std.testing.expectEqualStrings("", copy.value.node.params[0].user.value.?);
    try std.testing.expectEqualStrings("x", copy.value.node.params[1].cv.value.?);
    try std.testing.expectEqualStrings("x", copy.value.node.params[2].group_ref.ref.?);
    try std.testing.expectEqual(null, copy.value.node.children[0].text);
    // The record node is the first level.
    var chain: [mzml.MAX_DEPTH]mzml.model.Node = undefined;
    var deep = source;
    deep.node.children = &.{support.nest(chain[1..])};
    var deepest = try mzml.owned.Record.init(std.testing.allocator, deep, .{});
    deepest.deinit();
    deep.node.children = &.{support.nest(&chain)};
    try std.testing.expectError(error.LimitExceeded, mzml.owned.Record.init(std.testing.allocator, deep, .{}));
    try std.testing.expectError(error.LimitExceeded, mzml.owned.Record.init(std.testing.allocator, source, .{ .bytes = 0 }));
    const minimal: mzml.model.Record = .{ .id = "x", .index = 0, .default_array_length = 0, .node = .{ .kind = .spectrum } };
    var exact = try mzml.owned.Record.init(std.testing.allocator, minimal, .{ .bytes = 1 });
    defer exact.deinit();
    try std.testing.expectEqualStrings("x", exact.value.id);
}
