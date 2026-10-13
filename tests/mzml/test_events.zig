//! Tests the public XML event stream: positions, text runs, failures, and reentry.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

const Kind = enum { start, end, text };
const Seen = struct { kind: Kind, start: u64, end: u64, value: []const u8 };

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
        const allocator = arena.allocator();
        while (try events.next()) |event| {
            const kind: Kind, const value: []const u8 = switch (event.data) {
                .start_element => |start| .{ .start, start.name.raw },
                .end_element => |end| .{ .end, end.name.raw },
                .text => |run| .{ .text, run.bytes },
            };
            if (kind == .text) try text.appendSlice(allocator, value);
            const kept = if (kind == .text) "" else try allocator.dupe(u8, value);
            try seen.append(allocator, .{ .kind = kind, .start = event.span.start, .end = event.span.end, .value = kept });
        }
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

test "[regression] - [mzML events]: an undeclared default namespace is null in both spellings" {
    var input = std.Io.Reader.fixed("<r xmlns='urn:r'><a xmlns=''/><b/></r>");
    var events = try mzml.Events.init(std.testing.allocator, &input, .{});
    defer events.deinit();
    _ = try events.next();
    const a = (try events.next()).?.data.start_element;
    try std.testing.expectEqual(@as(?[]const u8, null), a.name.expanded.namespace_uri);
    _ = try events.next();
    const b = (try events.next()).?.data.start_element;
    try std.testing.expectEqualStrings("urn:r", b.name.expanded.namespace_uri.?);
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

test "[unit] - [mzML events]: list in-scope bindings without shadowed ones, restoring them after the shadowing element" {
    var input = std.Io.Reader.fixed("<r xmlns='urn:d' xmlns:p='urn:p' xmlns:xml='http://www.w3.org/XML/1998/namespace'>" ++
        "<c xmlns:p='urn:q' xmlns=''><e/></c><f/></r>");
    var events = try mzml.Events.init(std.testing.allocator, &input, .{});
    defer events.deinit();
    // Expected per start tag, outermost first; the xml prefix is never listed.
    const expected = [_][]const u8{ "=urn:d;p=urn:p;", "p=urn:q;=;", "p=urn:q;=;", "=urn:d;p=urn:p;" };
    var starts: usize = 0;
    while (try events.next()) |event| {
        if (event.data != .start_element) continue;
        var listed: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&listed);
        var position: usize = 0;
        while (events.namespaceAt(&position)) |binding| try writer.print("{s}={s};", .{ binding.prefix, binding.uri });
        try std.testing.expectEqualStrings(expected[starts], writer.buffered());
        starts += 1;
    }
    try std.testing.expectEqual(expected.len, starts);
}

test "[unit] - [mzML events]: decode UTF-8 at the bounds of every well-formed range" {
    // U+0080, U+07FF, U+0800, U+D7FF, U+E000, U+FFFD, U+10000, U+10FFFF.
    const text = "\xc2\x80\xdf\xbf\xe0\xa0\x80\xed\x9f\xbf\xee\x80\x80\xef\xbf\xbd\xf0\x90\x80\x80\xf4\x8f\xbf\xbf";
    for ([_]usize{ 0, 1 }) |buffer_size| {
        var fixed = std.Io.Reader.fixed("<m>" ++ text ++ "</m>");
        var small: [1]u8 = undefined;
        var limited = fixed.limited(.unlimited, &small);
        var events = try mzml.Events.init(std.testing.allocator, if (buffer_size == 0) &fixed else &limited.interface, .{});
        defer events.deinit();
        try std.testing.expectEqualStrings("m", (try events.next()).?.data.start_element.name.raw);
        try std.testing.expectEqualStrings(text, (try events.next()).?.data.text.bytes);
        try std.testing.expectEqualStrings("m", (try events.next()).?.data.end_element.name.raw);
        for (0..3) |_| try std.testing.expectEqual(null, try events.next());
    }
}

test "[edge] - [mzML events]: decode BOM-less UTF-16, surrogates, hex references, CDATA brackets, ? in instructions, a final CR" {
    const Case = struct { source: []const u8, utf16: ?std.builtin.Endian = null, text: []const u8 };
    const cases = [_]Case{
        .{ .source = "<r>\u{e9}\u{1F600}</r>", .utf16 = .little, .text = "\u{e9}\u{1F600}" },
        .{ .source = "<r>\u{e9}\u{1F600}</r>", .utf16 = .big, .text = "\u{e9}\u{1F600}" },
        .{ .source = "<r>&#x1f600;&#xe9;</r>", .text = "\u{1F600}\u{e9}" },
        .{ .source = "<r><![CDATA[a]]]><![CDATA[]]x]]></r>", .text = "a]]]x" },
        .{ .source = "<?p a?b?><r>t</r>\r", .text = "t" },
    };
    var bytes: [64]u8 = undefined;
    for (cases) |case| {
        const source = if (case.utf16) |order| encoded: {
            const units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, case.source);
            defer std.testing.allocator.free(units);
            for (units, 0..) |unit, i| std.mem.writeInt(u16, bytes[2 * i ..][0..2], unit, order);
            break :encoded bytes[0 .. 2 * units.len];
        } else case.source;
        var input = std.Io.Reader.fixed(source);
        var events = try mzml.Events.init(std.testing.allocator, &input, .{});
        defer events.deinit();
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(std.testing.allocator);
        var elements: usize = 0;
        while (try events.next()) |event| switch (event.data) {
            .text => |run| try text.appendSlice(std.testing.allocator, run.bytes),
            else => elements += 1,
        };
        try std.testing.expectEqualStrings(case.text, text.items);
        try std.testing.expectEqual(@as(usize, 2), elements);
    }
}

test "[failure] - [mzML events]: accept standalone only as yes or no, after version and encoding" {
    for ([_][]const u8{
        "<?xml version='1.0' standalone='yes'?><r/>",
        "<?xml version='1.0' encoding='UTF-8' standalone='no'?><r/>",
    }) |source| {
        var input = std.Io.Reader.fixed(source);
        var events = try mzml.Events.init(std.testing.allocator, &input, .{});
        defer events.deinit();
        try std.testing.expectEqualStrings("r", (try events.next()).?.data.start_element.name.raw);
    }
    for ([_][]const u8{
        "<?xml version='1.0' standalone='maybe'?><r/>",
        "<?xml version='1.0' standalone='yes' encoding='UTF-8'?><r/>",
        "<?xml standalone='yes' version='1.0'?><r/>",
        "<?xml version='1.0'?x?><r/>",
    }) |source| {
        var input = std.Io.Reader.fixed(source);
        var events = try mzml.Events.init(std.testing.allocator, &input, .{});
        defer events.deinit();
        try std.testing.expectError(error.InvalidXml, events.next());
        try std.testing.expectEqual(.xml, events.diagnostic().?.stage);
    }
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

test "[failure] - [mzML events]: name the broken rule and where, keep the first failure, and refuse reuse" {
    // Each case's offset is the first byte of what broke the rule, or the end of input.
    const Rule = mzml.Diagnostic.XmlRule;
    const cases = .{
        .{ "<mzML><spectrum>", Rule.unexpected_end, 16 },
        .{ "<mzML></spectrum>", Rule.mismatched_end_tag, 6 },
        .{ "text<root/>", Rule.unexpected_text, 0 },
        .{ "<root/>text", Rule.unexpected_text, 7 },
        .{ "<root/> <!-- c --> <?pi?> &amp;", Rule.unexpected_text, 26 },
        .{ "<mzML/><mzML/>", Rule.content_after_root, 7 },
        .{ "<mzML a=1/>", Rule.malformed_tag, 8 },
        .{ "<mzML a='<'/>", Rule.less_than_in_attribute, 9 },
        .{ "<mzML><!-x--></mzML>", Rule.malformed_markup, 9 },
        .{ "<mzML>]]></mzML>", Rule.malformed_markup, 6 },
        .{ "<?xml version='1.0' size='1'?><mzML/>", Rule.malformed_declaration, 20 },
        .{ "<1mzML/>", Rule.invalid_name, 1 },
        .{ "<spec\x01trum/>", Rule.invalid_name, 5 },
        .{ "<mzML a='1' a='2'/>", Rule.duplicate_attribute, 12 },
        .{ "<mzML xmlns:p='u' xmlns:q='u' p:a='1' q:a='2'/>", Rule.duplicate_attribute, 38 },
        .{ "<p:mzML/>", Rule.unbound_prefix, 1 },
        .{ "<mzML q:a='1'/>", Rule.unbound_prefix, 6 },
        .{ "<mzML xmlns:p=''/>", Rule.invalid_namespace_declaration, 6 },
        .{ "<mzML>&nbsp;</mzML>", Rule.unknown_entity, 6 },
        .{ "<mzML a='&#0;'/>", Rule.invalid_character_reference, 9 },
        .{ "<mzML>\x01</mzML>", Rule.invalid_character, 6 },
    };
    // A one-byte buffer takes the character-by-character paths instead of the buffered scans.
    for ([_]usize{ 0, 1 }) |buffer_size| {
        inline for (cases) |case| {
            var fixed = std.Io.Reader.fixed(case[0]);
            var small: [1]u8 = undefined;
            var limited = fixed.limited(.unlimited, &small);
            var events = try mzml.Events.init(std.testing.allocator, if (buffer_size == 0) &fixed else &limited.interface, .{});
            defer events.deinit();
            const failure = while (true) {
                _ = (events.next() catch |err| break err) orelse return error.TestUnexpectedResult;
            };
            try std.testing.expectEqual(error.InvalidXml, failure);
            const report = events.diagnostic().?;
            try std.testing.expectEqual(mzml.Diagnostic.Operation.read_event, report.operation);
            try std.testing.expectEqual(mzml.Diagnostic.Detail{ .xml = case[1] }, report.detail);
            try std.testing.expectEqual(@as(u64, case[2]), report.location.?.input_event);
            try std.testing.expectError(error.FailedState, events.next());
        }
    }
}

test "[failure] - [mzML events]: report a broken encoding at the byte that cannot continue it" {
    // A broken encoding is reported at the first byte that cannot continue a well-formed
    // sequence (the end of input when cut off); in UTF-16, offsets count two bytes per unit.
    const encoded = .{
        .{ "<mzML>ab\xc3(</mzML>", error.InvalidEncoding, 9 },
        .{ "<mzML a='\xe2\x82'/>", error.InvalidEncoding, 11 },
        .{ "<mzML>\x80</mzML>", error.InvalidEncoding, 6 },
        .{ "<mzML>\xc0\x80</mzML>", error.InvalidEncoding, 6 },
        .{ "<mzML>\xe0\x9f\xbf</mzML>", error.InvalidEncoding, 7 },
        .{ "<mzML>\xed\xa0\x80</mzML>", error.InvalidEncoding, 7 },
        .{ "<mzML>\xf4\x90\x80\x80</mzML>", error.InvalidEncoding, 7 },
        .{ "<mzML>\xf0\x9f\x98", error.InvalidEncoding, 9 },
        .{ "<?xml version='1.1'?><mzML/>", error.UnsupportedVersion, 15 },
        .{ "<?xml version='1.0' encoding='UTF-16'?><mzML/>", error.InvalidEncoding, 30 },
    };
    inline for (encoded) |case| {
        var input = std.Io.Reader.fixed(case[0]);
        var events = try mzml.Events.init(std.testing.allocator, &input, .{});
        defer events.deinit();
        const failure = while (true) {
            _ = (events.next() catch |err| break err) orelse return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(case[1], failure);
        try std.testing.expectEqual(@as(u64, case[2]), events.diagnostic().?.location.?.input_event);
    }
    const utf16 = .{
        .{ "<?xml version='1.0' encoding='ISO-8859-1'?><mzML/>", error.InvalidEncoding, 2 + 30 * 2 },
        .{ "<mzML>]]></mzML>", error.InvalidXml, 2 + 6 * 2 },
        // '#' stands for a high surrogate unit and '%' for a low one.
        .{ "<mzML>#a</mzML>", error.InvalidEncoding, 2 + 7 * 2 },
        .{ "<mzML>%</mzML>", error.InvalidEncoding, 2 + 6 * 2 },
    };
    inline for (utf16) |case| {
        var bytes: [2 + case[0].len * 2]u8 = undefined;
        std.mem.writeInt(u16, bytes[0..2], 0xfeff, .little);
        for (case[0], 0..) |byte, i| {
            const unit: u16 = switch (byte) {
                '#' => 0xD800,
                '%' => 0xDC00,
                else => byte,
            };
            std.mem.writeInt(u16, bytes[2 + i * 2 ..][0..2], unit, .little);
        }
        var input = std.Io.Reader.fixed(&bytes);
        var events = try mzml.Events.init(std.testing.allocator, &input, .{});
        defer events.deinit();
        const failure = while (true) {
            _ = (events.next() catch |err| break err) orelse return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(case[1], failure);
        try std.testing.expectEqual(@as(u64, case[2]), events.diagnostic().?.location.?.input_event);
    }
}

// Writes every event, then the failure if any, with names, spans, attribute offsets, and the
// broken rule and its offset.
fn trace(allocator: std.mem.Allocator, input: *std.Io.Reader, out: *std.Io.Writer) !void {
    return traceWith(allocator, input, out, .{}, false);
}

// As trace; with drop_blank, leaves out text events that hold only XML whitespace.
fn traceWith(allocator: std.mem.Allocator, input: *std.Io.Reader, out: *std.Io.Writer, options: mzml.Events.Options, drop_blank: bool) !void {
    var events = try mzml.Events.init(allocator, input, options);
    defer events.deinit();
    while (true) {
        const event = (events.next() catch |err| {
            const report = events.diagnostic().?;
            try out.print("{s} {any} {any}\n", .{ @errorName(err), report.detail, report.location });
            return;
        }) orelse return;
        if (drop_blank and event.data == .text and std.mem.trim(u8, event.data.text.bytes, " \t\r\n").len == 0) continue;
        try out.print("{d}-{d} ", .{ event.span.start, event.span.end });
        switch (event.data) {
            .start_element => |start| {
                try out.print("<{s} {}", .{ start.name.raw, start.empty_element_syntax });
                for (start.attributes) |attribute| try out.print(" {s}@{d}", .{ attribute.name.raw, attribute.offset });
            },
            .end_element => |end| try out.print("</{s}", .{end.name.raw}),
            .text => |run| try out.print("'{s}'", .{run.bytes}),
        }
        try out.writeByte('\n');
    }
}

test "[property] - [mzML events]: every input split gives the same tags, spans, and failures" {
    const document = "<r xmlns:p='urn:p'><a/><a></a><b x='1' y='2'></b ><p:c p:z='3'></p:c>" ++
        "<d>t</d><!-- c --><?pi x?><e><![CDATA[<]]></e><f\n/><g><?pi y?></g></r>";
    // Text with tabs, line ends, an entity, brackets, and runs past one 64-byte block.
    const text = "<r>\n\t <a>one\ttwo\nthree\r\nfour&amp;five]]six</a>\r\n" ++ " " ** 40 ++ "<b>" ++ "x" ** 70 ++ "</b>\n</r>";
    const cases = [_][]const u8{
        document,
        "<r><a></ab></r>",
        "<r><ab></a></r>",
        "<r><a></a",
        "<r><a></",
        "<r></r></r>",
        "<r><a/ ></r>",
        "<r><p:a></p:a></r>",
        text,
    };
    for (cases) |source| {
        var whole: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer whole.deinit();
        var fixed = std.Io.Reader.fixed(source);
        try trace(std.testing.allocator, &fixed, &whole.writer);
        const valid = source.ptr == document.ptr or source.ptr == text.ptr;
        try std.testing.expectEqual(!valid, std.mem.indexOf(u8, whole.written(), "InvalidXml") != null);
        var buffer: [256]u8 = undefined;
        for (1..source.len + 1) |size| {
            var split: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer split.deinit();
            var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = source }});
            input.artificial_limit = .limited(size);
            try trace(std.testing.allocator, &input.interface, &split.writer);
            try std.testing.expectEqualStrings(whole.written(), split.written());
        }
    }
}

test "[failure] - [mzML events]: release every allocation when one fails during a read" {
    const Read = struct {
        fn run(allocator: std.mem.Allocator, document: []const u8) !void {
            var input = std.Io.Reader.fixed(document);
            var events = try mzml.Events.init(allocator, &input, .{});
            defer events.deinit();
            while (try events.next()) |_| {}
        }
    };
    const long_text = "<r xmlns='urn:r' xmlns:p='urn:p'><p:a p:x='&amp;'>" ++ "t" ** 70_000 ++ "</p:a><b/></r>";
    for ([_][]const u8{ support.DOCUMENT, long_text }) |document|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Read.run, .{document});
}

test "[property] - [mzML events]: skipping whitespace text drops exactly the blank text events at every split" {
    const cases = [_][]const u8{
        "<r>\n  <a x='1'/>\r\n\t<b>  t u  </b>\n  <c><![CDATA[ ]]></c> <d> </d>\n</r>\n",
        "<r>   <a/>  t  <b/>   </r>",
        "<r>\n  <a></b>\n</r>",
        "<r> x </r> y",
        // Indentation across 16-byte steps, and a long blank run before text.
        "<r>\n" ++ " " ** 15 ++ "<a/>\r\n" ++ " " ** 16 ++ "<b/>\n" ++ "\t" ** 33 ++ "<c/>" ++ " " ** 47 ++ "x</r>",
    };
    for (cases) |source| {
        var buffer: [256]u8 = undefined;
        for (1..source.len + 1) |size| {
            var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer expected.deinit();
            var all: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = source }});
            all.artificial_limit = .limited(size);
            try traceWith(std.testing.allocator, &all.interface, &expected.writer, .{}, true);
            var actual: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer actual.deinit();
            var skipping: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = source }});
            skipping.artificial_limit = .limited(size);
            try traceWith(std.testing.allocator, &skipping.interface, &actual.writer, .{ .skip_whitespace_text = true }, false);
            try std.testing.expectEqualStrings(expected.written(), actual.written());
        }
    }
}

test "[failure] - [mzML events]: report limits with their maximum" {
    const cases = .{
        .{ "<root a='1' b='2' c='3'/>", mzml.Diagnostic.Limit.attributes, 2 },
        .{ "<?xml version='1.0'" ++ " " ** 4096 ++ "?><root/>", mzml.Diagnostic.Limit.xml_declaration_bytes, 4096 },
    };
    inline for (cases) |case| {
        var input = std.Io.Reader.fixed(case[0]);
        var events = try mzml.Events.init(std.testing.allocator, &input, .{ .attributes = 2 });
        defer events.deinit();
        try std.testing.expectError(error.LimitExceeded, events.next());
        const limit = events.diagnostic().?.detail.limit;
        try std.testing.expectEqual(case[1], limit.name);
        try std.testing.expectEqual(case[2], limit.maximum);
    }
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

test "[property] - [mzML encoding terms]: classify encoding terms with the readers' table" {
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
        var decoded = mzml.DecodedArrays.init(allocator, .{});
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
        var decoded = mzml.DecodedArrays.init(allocator, .{});
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
