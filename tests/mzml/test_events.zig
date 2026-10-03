//! Tests the public XML event stream: positions, text runs, failures, and reentry.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

const Kind = enum { start, end, text };
const Seen = struct { kind: Kind, start: u64, end: u64, value: []const u8 };

fn collect(allocator: std.mem.Allocator, events: *mzml.Events, seen: *std.ArrayList(Seen), text: *std.ArrayList(u8)) !void {
    while (try events.next()) |event| {
        const kind: Kind, const value: []const u8 = switch (event.data) {
            .start_element => |start| .{ .start, start.name.raw },
            .end_element => |end| .{ .end, end.name.raw },
            .text => |run| .{ .text, run.bytes },
        };
        if (kind == .text) try text.appendSlice(allocator, value);
        try seen.append(allocator, .{ .kind = kind, .start = event.span.start, .end = event.span.end, .value = if (kind == .text) "" else try allocator.dupe(u8, value) });
    }
}

test "[unit] - [mzML events]: report source spans of every element in any root and any split" {
    const source = "<?xml version='1.0'?>\n<!-- c --><root a='&lt;1&gt;'><x/><p:y xmlns:p='urn:p'>t&amp;u</p:y></root>\n";
    var buffer: [64]u8 = undefined;
    for ([_]usize{ 1, 3, 64 }) |size| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = source }});
        input.artificial_limit = .limited(size);
        var events = try mzml.Events.init(std.testing.allocator, &input.interface, .{});
        defer events.deinit();
        var seen: std.ArrayList(Seen) = .empty;
        var text: std.ArrayList(u8) = .empty;
        try collect(arena.allocator(), &events, &seen, &text);
        const root = std.mem.indexOf(u8, source, "<root").?;
        const x = std.mem.indexOf(u8, source, "<x/>").?;
        const y = std.mem.indexOf(u8, source, "<p:y").?;
        const expected = [_]Seen{
            .{ .kind = .start, .start = root, .end = x, .value = "root" },
            .{ .kind = .start, .start = x, .end = x + 4, .value = "x" },
            .{ .kind = .end, .start = x + 4, .end = x + 4, .value = "x" },
            .{ .kind = .start, .start = y, .end = y + 21, .value = "p:y" },
            .{ .kind = .text, .start = y + 21, .end = y + 22, .value = "" },
            .{ .kind = .text, .start = y + 22, .end = y + 28, .value = "" },
            .{ .kind = .end, .start = y + 28, .end = y + 34, .value = "p:y" },
            .{ .kind = .end, .start = y + 34, .end = y + 41, .value = "root" },
        };
        try std.testing.expectEqual(expected.len, seen.items.len);
        for (expected, seen.items) |want, got| {
            try std.testing.expectEqual(want.kind, got.kind);
            try std.testing.expectEqual(want.start, got.start);
            try std.testing.expectEqual(want.end, got.end);
            try std.testing.expectEqualStrings(want.value, got.value);
        }
        try std.testing.expectEqualStrings("t&u", text.items);
        try std.testing.expectEqual(null, try events.next());
    }
}

test "[unit] - [mzML events]: give attributes decoded and namespaces resolved" {
    var input = std.Io.Reader.fixed("<root xmlns='urn:d' xmlns:p='urn:p' a='&lt;1&gt;' p:b='2'><p:c/></root>");
    var events = try mzml.Events.init(std.testing.allocator, &input, .{});
    defer events.deinit();
    const root = (try events.next()).?.data.start_element;
    try std.testing.expectEqualStrings("urn:d", root.name.expanded.namespace_uri.?);
    try std.testing.expectEqual(2, root.attributes.len);
    try std.testing.expectEqualStrings("<1>", root.attribute(null, "a").?.value);
    try std.testing.expectEqualStrings("2", root.attribute("urn:p", "b").?.value);
    var position: usize = 0;
    var bindings: usize = 0;
    while (events.namespaceAt(&position)) |_| bindings += 1;
    try std.testing.expectEqual(2, bindings);
    const child = (try events.next()).?.data.start_element;
    try std.testing.expectEqualStrings("urn:p", child.name.expanded.namespace_uri.?);
    try std.testing.expect(child.empty_element_syntax);
}

test "[unit] - [mzML events]: stream long text in bounded runs" {
    const payload_len = 200 * 1024 + 3;
    const source = try std.testing.allocator.alloc(u8, payload_len + "<b></b>".len);
    defer std.testing.allocator.free(source);
    @memcpy(source[0..3], "<b>");
    @memset(source[3..][0..payload_len], 'A');
    @memcpy(source[3 + payload_len ..], "</b>");
    var input = std.Io.Reader.fixed(source);
    var events = try mzml.Events.init(std.testing.allocator, &input, .{});
    defer events.deinit();
    _ = (try events.next()).?;
    var total: usize = 0;
    var runs: usize = 0;
    while (try events.next()) |event| switch (event.data) {
        .text => |run| {
            try std.testing.expect(run.bytes.len <= 64 * 1024);
            total += run.bytes.len;
            runs += 1;
        },
        else => break,
    };
    try std.testing.expectEqual(payload_len, total);
    try std.testing.expect(runs >= 4);
}

test "[failure] - [mzML events]: name the broken rule, keep the first failure, and refuse reuse" {
    const cases = .{
        .{ "<root><a></b></root>", mzml.Events.Rule.mismatched_end_tag },
        .{ "<root>&bogus;</root>", mzml.Events.Rule.unknown_entity },
        .{ "<root a='1' a='2'/>", mzml.Events.Rule.duplicate_attribute },
        .{ "<root><a>", mzml.Events.Rule.unexpected_end },
        .{ "text<root/>", mzml.Events.Rule.unexpected_text },
        .{ "<root/>text", mzml.Events.Rule.unexpected_text },
        .{ "<root/> <!-- c --> <?pi?> &amp;", mzml.Events.Rule.unexpected_text },
        .{ "<root/><root/>", mzml.Events.Rule.content_after_root },
    };
    inline for (cases) |case| {
        var input = std.Io.Reader.fixed(case[0]);
        var events = try mzml.Events.init(std.testing.allocator, &input, .{});
        defer events.deinit();
        const failure = while (true) {
            _ = (events.next() catch |err| break err) orelse return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(error.InvalidXml, failure);
        const report = events.diagnostic().?;
        try std.testing.expectEqual(mzml.Diagnostic.Operation.read_event, report.operation);
        try std.testing.expectEqual(mzml.Diagnostic.Detail{ .xml = case[1] }, report.detail);
        try std.testing.expect(report.location != null);
        try std.testing.expectError(error.FailedState, events.next());
    }
}

test "[failure] - [mzML events]: report limits with their maximum" {
    var input = std.Io.Reader.fixed("<root a='1' b='2' c='3'/>");
    var events = try mzml.Events.init(std.testing.allocator, &input, .{ .attributes = 2 });
    defer events.deinit();
    try std.testing.expectError(error.LimitExceeded, events.next());
    const limit = events.diagnostic().?.detail.limit;
    try std.testing.expectEqual(mzml.Diagnostic.Limit.attributes, limit.name);
    try std.testing.expectEqual(2, limit.maximum);
}

test "[failure] - [mzML events]: readers report the same broken rule" {
    var input = std.Io.Reader.fixed("<mzML xmlns='http://psi.hupo.org/ms/mzml'><run id='r'></mzML>");
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    try std.testing.expectError(error.InvalidXml, reader.readHeader());
    try std.testing.expectEqual(mzml.Diagnostic.Detail{ .xml = .mismatched_end_tag }, reader.diagnostic().?.detail);
}

test "[unit] - [mzML events]: give each attribute's source offset in any split" {
    const source = "<root a='1'  p:b=\"2\" xmlns:p='urn:p'\n c = '3'/>";
    var buffer: [64]u8 = undefined;
    for ([_]usize{ 1, 5, 64 }) |size| {
        var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = source }});
        input.artificial_limit = .limited(size);
        var events = try mzml.Events.init(std.testing.allocator, &input.interface, .{});
        defer events.deinit();
        const root = (try events.next()).?.data.start_element;
        try std.testing.expectEqual(3, root.attributes.len);
        for (root.attributes, [_][]const u8{ "a=", "p:b=", "c =" }) |attribute, text| {
            try std.testing.expectEqual(std.mem.indexOf(u8, source, text).?, attribute.offset);
        }
    }
}

test "[unit] - [mzML events]: name modeled elements in both mzML namespaces only" {
    var input = std.Io.Reader.fixed("<mzML xmlns='http://psi.hupo.org/schema_revision/mzML_1.0.0'><run/><x:run xmlns:x='urn:other'/><unmodeled/></mzML>");
    var events = try mzml.Events.init(std.testing.allocator, &input, .{});
    defer events.deinit();
    const expected = [_]?mzml.model.Kind{ .mzml, .run, null, null };
    var position: usize = 0;
    while (try events.next()) |event| switch (event.data) {
        .start_element => |start| {
            try std.testing.expectEqual(expected[position], mzml.Events.kindOf(start.name));
            position += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(expected.len, position);
}

test "[unit] - [mzML events]: classify encoding terms with the readers' table" {
    try std.testing.expectEqual(mzml.model.EncodingTerm{ .primitive = .float64 }, mzml.model.encodingTerm("MS:1000523").?);
    try std.testing.expectEqual(mzml.model.EncodingTerm{ .compression = .slof_zlib }, mzml.model.encodingTerm("MS:1002748").?);
    try std.testing.expectEqual(mzml.model.EncodingTerm{ .unsupported = .compression }, mzml.model.encodingTerm("MS:1003780").?);
    try std.testing.expectEqual(mzml.model.EncodingTerm{ .unsupported = .primitive }, mzml.model.encodingTerm("MS:1001479").?);
    try std.testing.expectEqual(null, mzml.model.encodingTerm("MS:1000514"));
    // Every current binary data type and compression type term is classified, so none is
    // silently ignored, and nothing else is.
    const ms = for (mzml.cv.Resolver.BUNDLED) |vocabulary| {
        if (std.mem.eql(u8, vocabulary.identity.key, "psi-ms")) break vocabulary;
    } else return error.TestUnexpectedResult;
    var classified: usize = 0;
    for (ms.terms) |term| {
        if (term.obsolete) continue;
        const data_type = try ms.isA(term.id, "MS:1000518", 1000) and !std.mem.eql(u8, term.id, "MS:1000518");
        const compression = try ms.isA(term.id, "MS:1000572", 1000) and !std.mem.eql(u8, term.id, "MS:1000572");
        const Declaration = enum { primitive, compression };
        const expected: ?Declaration = if (data_type) .primitive else if (compression) .compression else null;
        const kind: ?Declaration = if (mzml.model.encodingTerm(term.id)) |found| switch (found) {
            .primitive => .primitive,
            .compression => .compression,
            .unsupported => |declaration| switch (declaration) {
                .primitive => .primitive,
                .compression => .compression,
            },
        } else null;
        std.testing.expectEqual(expected, kind) catch |err| {
            std.debug.print("{s} {s}\n", .{ term.id, term.name });
            return err;
        };
        classified += @intFromBool(kind != null);
    }
    try std.testing.expect(classified >= 20);
}

fn wide(value: anytype) f64 {
    return if (@typeInfo(@TypeOf(value)) == .float) @floatCast(value) else @floatFromInt(value);
}

// What an event app does: the array's text runs, ending at its next element event.
const TextRuns = struct {
    events: *mzml.Events,

    pub fn next(self: *TextRuns) !?[]const u8 {
        const event = try self.events.next() orelse return null;
        return switch (event.data) {
            .text => |run| run.bytes,
            else => null,
        };
    }
};

test "[integration] - [mzML events]: decode arrays from text runs as the readers do" {
    const allocator = std.testing.allocator;
    var document: std.Io.Writer.Allocating = .init(allocator);
    defer document.deinit();
    try support.constructFixture(allocator, &document.writer, false, &.{ .none, .zlib, .linear, .pic, .slof, .linear_zlib, .pic_zlib, .slof_zlib });
    const bytes = document.written();

    var expected: std.ArrayList(f64) = .empty;
    defer expected.deinit(allocator);
    {
        var input = std.Io.Reader.fixed(bytes);
        var reader = try mzml.StreamReader.init(allocator, &input, .{});
        defer reader.deinit();
        var decoded = mzml.StreamReader.DecodedArrays.init(allocator, .{});
        defer decoded.deinit();
        while (try reader.nextDecodedRecord(&decoded)) |_| for (0..decoded.len()) |i| switch (decoded.get(i).?.values) {
            inline else => |values| for (values) |value| try expected.append(allocator, wide(value)),
        };
    }

    var buffer: [64]u8 = undefined;
    for ([_]usize{ 1, 7, 64 }) |size| {
        var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = bytes }});
        input.artificial_limit = .limited(size);
        var events = try mzml.Events.init(allocator, &input.interface, .{});
        defer events.deinit();
        var decoded = mzml.StreamReader.DecodedArrays.init(allocator, .{});
        defer decoded.deinit();
        var record_length: usize = 0;
        var primitive: ?mzml.model.Primitive = null;
        var pipeline: ?mzml.arrays.Pipeline = null;
        var position: usize = 0;
        while (try events.next()) |event| switch (event.data) {
            .start_element => |start| switch (mzml.Events.kindOf(start.name) orelse {
                // Parameters are entries of a node, not node kinds.
                if (!std.mem.eql(u8, start.name.expanded.local, "cvParam")) continue;
                if (mzml.model.encodingTerm(start.attribute(null, "accession").?.value)) |term| switch (term) {
                    .primitive => |value| primitive = value,
                    .compression => |value| pipeline = value,
                    .unsupported => return error.TestUnexpectedResult,
                };
                continue;
            }) {
                .spectrum, .chromatogram => record_length = try std.fmt.parseInt(usize, start.attribute(null, "defaultArrayLength").?.value, 10),
                .binary_data_array => {
                    primitive = null;
                    pipeline = null;
                },
                .binary => {
                    var runs: TextRuns = .{ .events = &events };
                    const values = try decoded.decodeArrayText(.{ .primitive = primitive.?, .pipeline = pipeline.? }, record_length, &runs);
                    switch (values) {
                        inline else => |numbers| for (numbers) |value| {
                            try std.testing.expectEqual(expected.items[position], wide(value));
                            position += 1;
                        },
                    }
                },
                else => {},
            },
            else => {},
        };
        try std.testing.expectEqual(expected.items.len, position);
    }
}
