//! Tests streaming reads, payload handling, and malformed input.

const std = @import("std");
const zmz = @import("zmz");
const mzml = zmz.mzml;
const gates = @import("gates_test_support");
const support = @import("support.zig");

test "[failure] - [mzML diagnostics]: retains selected source positions and physical event offsets" {
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "<binary>AAAAAAAA8D8=</binary>", "<binary>&#33;AAAAAAA8D8=</binary>");
    defer std.testing.allocator.free(source);
    const payload = std.mem.indexOf(u8, source, "&#33;").?;
    const utf16 = try std.testing.allocator.alloc(u8, source.len * 2 + 2);
    defer std.testing.allocator.free(utf16);
    for ([_]?std.builtin.Endian{ null, .little, .big }) |endian| {
        const bytes = if (endian) |order| encoded: {
            std.mem.writeInt(u16, utf16[0..2], 0xfeff, order);
            for (source, 0..) |byte, i| std.mem.writeInt(u16, utf16[2 + i * 2 ..][0..2], byte, order);
            break :encoded utf16;
        } else source;
        for ([_]usize{ 1, 7, 31 }) |chunk| {
            const report = blk: {
                var buffer: [31]u8 = undefined;
                var input: std.testing.Reader = .init(buffer[0..chunk], &.{.{ .buffer = bytes }});
                input.artificial_limit = .limited(chunk);
                var reader = try mzml.StreamReader.init(std.testing.allocator, &input.interface, .{ .array_selector = .{ .select = selectSecond } });
                defer reader.deinit();
                var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
                defer output.deinit();
                try std.testing.expectError(error.InvalidCharacter, reader.nextDecodedRecord(&output));
                try std.testing.expectEqual(@as(usize, 0), output.len());
                const saved = reader.diagnostic().?;
                try std.testing.expectError(error.FailedState, reader.readHeader());
                try std.testing.expectError(error.FailedState, reader.nextDecodedItem(&output));
                try std.testing.expectEqualDeep(saved, reader.diagnostic().?);
                break :blk saved;
            };
            try std.testing.expectEqual(.invalid_base64, report.id);
            try std.testing.expectEqual(error.InvalidCharacter, report.code);
            try std.testing.expectEqual(.base64, report.stage);
            try std.testing.expectEqual(.read_record, report.operation);
            try std.testing.expectEqual(.binary, report.element.?);
            try std.testing.expectEqual(@as(usize, 1), report.array_position.?);
            try std.testing.expectEqual(@as(usize, 0), report.record.?.ordinal);
            try std.testing.expectEqual(.spectrum, report.record.?.kind);
            try std.testing.expectEqual(@as(u64, if (endian == null) payload else payload * 2 + 2), report.location.?.input_event);
            var short = std.Io.Writer.fixed(&.{});
            try std.testing.expectError(error.WriteFailed, report.format(&short));
            var buffer: [512]u8 = undefined;
            var sink = std.Io.Writer.fixed(&buffer);
            try report.format(&sink);
            try std.testing.expect(std.mem.startsWith(u8, sink.buffered(), "[ZMZ0006] read_record:"));
            try std.testing.expect(std.mem.endsWith(u8, sink.buffered(), "; array_position=1"));
        }
    }
}

test "[failure] - [mzML diagnostics]: names selected array attributes limits and encoding origins" {
    inline for (.{
        .{ "arrayLength='bad'", error.InvalidValue, mzml.Diagnostic.Id.invalid_value },
        .{ "arrayLength='1'", error.LimitExceeded, mzml.Diagnostic.Id.limit_exceeded },
    }) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "arrayLength='1'", case[0]);
        defer std.testing.allocator.free(source);
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .array_selector = .{ .select = selectSecond } });
        defer reader.deinit();
        var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{ .array_bytes = 1 });
        defer output.deinit();
        try std.testing.expectError(case[1], reader.nextDecodedRecord(&output));
        const report = reader.diagnostic().?;
        try std.testing.expectEqual(case[2], report.id);
        try std.testing.expectEqual(.binary_data_array, report.element.?);
        try std.testing.expectEqual(@as(usize, 1), report.array_position.?);
        if (case[1] == error.InvalidValue) {
            try std.testing.expectEqual(.array_length, report.detail.attribute);
        } else {
            try std.testing.expectEqual(.array_bytes, report.detail.limit.name);
            try std.testing.expectEqual(@as(u64, 1), report.detail.limit.maximum);
            try std.testing.expectEqual(@as(u64, 8), report.detail.limit.needed.?);
        }
    }
    var xml_input = std.Io.Reader.fixed("<?xml version='1.0' encoding='UTF-32'?>" ++ support.DOCUMENT);
    var xml_reader = try mzml.StreamReader.init(std.testing.allocator, &xml_input, .{});
    defer xml_reader.deinit();
    try std.testing.expectError(error.UnsupportedEncoding, xml_reader.readHeader());
    try std.testing.expectEqual(.xml_encoding_unavailable, xml_reader.diagnostic().?.id);
    try std.testing.expectEqual(.xml, xml_reader.diagnostic().?.stage);
    try std.testing.expectEqual(.read_header, xml_reader.diagnostic().?.operation);
    const source = try decodedDocument(std.testing.allocator, "AAAA", 4, 1, "MS:1003089");
    defer std.testing.allocator.free(source);
    var array_input = std.Io.Reader.fixed(source);
    var array_reader = try mzml.StreamReader.init(std.testing.allocator, &array_input, .{});
    defer array_reader.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    try std.testing.expectEqual(.list_start, std.meta.activeTag((try array_reader.nextDecodedItem(&output)).?));
    try std.testing.expectError(error.UnsupportedEncoding, array_reader.nextDecodedItem(&output));
    const report = array_reader.diagnostic().?;
    try std.testing.expectEqual(.array_encoding_unavailable, report.id);
    try std.testing.expectEqual(.array, report.stage);
    try std.testing.expectEqual(.read_item, report.operation);
}

test "[failure] - [mzML diagnostics]: identifies configured storage and XML limits" {
    const Case = struct { limits: mzml.StreamReader.Limits, name: mzml.Diagnostic.Limit, maximum: u64 };
    for ([_]Case{
        .{ .limits = .{ .header_bytes = 0 }, .name = .header_bytes, .maximum = 0 },
        .{ .limits = .{ .record_bytes = 0 }, .name = .record_bytes, .maximum = 0 },
        .{ .limits = .{ .attributes = 1 }, .name = .attributes, .maximum = 1 },
        .{ .limits = .{ .attribute_bytes = 1 }, .name = .attribute_bytes, .maximum = 1 },
        .{ .limits = .{ .nodes = 1 }, .name = .nodes, .maximum = 1 },
        .{ .limits = .{ .list_entries = 1 }, .name = .list_entries, .maximum = 1 },
        .{ .limits = .{ .binary_text_bytes = 1 }, .name = .binary_text_bytes, .maximum = 1 },
    }) |case| {
        var input = std.Io.Reader.fixed(support.DOCUMENT);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .limits = case.limits });
        defer reader.deinit();
        try std.testing.expectError(error.LimitExceeded, reader.nextRecord());
        const report = reader.diagnostic().?;
        try std.testing.expectEqual(.limit_exceeded, report.id);
        try std.testing.expectEqual(case.name, report.detail.limit.name);
        try std.testing.expectEqual(case.maximum, report.detail.limit.maximum);
    }
    var input = std.Io.Reader.fixed("<mzML xmlns='http://psi.hupo.org/ms/mzml'><run><spectrumList><spectrum/></spectrumList></run></mzML>");
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    try std.testing.expectError(error.MissingAttribute, reader.nextRecord());
    try std.testing.expectEqual(.id, reader.diagnostic().?.detail.attribute);
    var failing = std.Io.Reader.failing;
    var buffer: [8]u8 = undefined;
    failing.buffer = &buffer;
    var failed = try mzml.StreamReader.init(std.testing.allocator, &failing, .{});
    defer failed.deinit();
    try std.testing.expectError(error.ReadFailed, failed.readHeader());
    try std.testing.expectEqual(.io_failed, failed.diagnostic().?.id);
}

test "[failure] - [mzML diagnostics]: does not assign the next opening error to a completed array" {
    const source = support.HEADER ++ "<spectrumList><spectrum id='s'><binaryDataArrayList><binaryDataArray><binary/></binaryDataArray><binaryDataArray broken=";
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    try std.testing.expectError(error.InvalidXml, reader.nextRecord());
    try std.testing.expectEqual(null, reader.diagnostic().?.array_position);
    try std.testing.expectEqual(.xml, reader.diagnostic().?.stage);
}

test "[unit] - [mzML diagnostics]: distinguishes unknown offsets and maps only source fragment bytes" {
    const locations = [_]?mzml.Diagnostic.Location{ null, .{ .input_event = 0 }, .{ .input_byte = 17 }, .{ .output_byte = 17 } };
    const suffixes = [_][]const u8{ "", "; input_event=0", "; input_byte=17", "; output_byte=17" };
    for (locations, suffixes) |location, suffix| {
        var report = mzml.Diagnostic.init(error.OutOfMemory, .write_record, .metadata, .none);
        report.location = location;
        var bytes: [256]u8 = undefined;
        var sink = std.Io.Writer.fixed(&bytes);
        try report.format(&sink);
        const prefix = "[ZMZ0001] write_record: allocation failed (OutOfMemory); stage=metadata";
        try std.testing.expectEqualStrings(prefix, sink.buffered()[0..prefix.len]);
        try std.testing.expectEqualStrings(suffix, sink.buffered()[prefix.len..]);
    }
    for ([_]u64{ 9, 10, 29, 30 }) |offset| {
        var report = mzml.Diagnostic.init(error.InvalidXml, .lookup_record, .xml, .none);
        report.location = .{ .input_event = offset };
        report.translate(100, 20, 10);
        if (offset == 9 or offset == 30) {
            try std.testing.expectEqual(null, report.location);
        } else try std.testing.expectEqual(100 + offset - 10, report.location.?.input_event);
    }
}

test "[failure] - [mzML diagnostics]: reports a known decoded size without guessing the compressed codec" {
    for ([_][]const u8{ "MS:1000576", "MS:1000574" }) |codec| {
        const source = try decodedDocument(std.testing.allocator, "AA==", 4, 1, codec);
        defer std.testing.allocator.free(source);
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
        defer output.deinit();
        const uncompressed = std.mem.eql(u8, codec, "MS:1000576");
        try std.testing.expectError(if (uncompressed) error.DecodedSizeMismatch else error.TruncatedInput, reader.nextDecodedRecord(&output));
        const report = reader.diagnostic().?;
        try std.testing.expectEqual(.array, report.stage);
        if (uncompressed) {
            try std.testing.expectEqual(.decoded_size_mismatch, report.id);
            try std.testing.expectEqual(@as(u64, 8), report.detail.size.expected);
            try std.testing.expectEqual(@as(u64, 1), report.detail.size.actual);
            try std.testing.expectEqual(.bytes, report.detail.size.unit);
        } else try std.testing.expectEqual(.array_decode_failed, report.id);
    }
}

test "[failure] - [mzML diagnostics]: reports a zlib array longer than declared as a size mismatch" {
    // Python's zlib.compress of two doubles, declared as one.
    const source = try decodedDocument(std.testing.allocator, "eJxjYACBD/YMEOAAAAvnAXA=", 24, 1, "MS:1000574");
    defer std.testing.allocator.free(source);
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    try std.testing.expectError(error.DecodedSizeMismatch, reader.nextDecodedRecord(&output));
    const report = reader.diagnostic().?;
    try std.testing.expectEqual(.array, report.stage);
    try std.testing.expectEqual(.decoded_size_mismatch, report.id);
}

fn expectSameValues(expected: mzml.StreamReader.DecodedArrays.Values, actual: mzml.StreamReader.DecodedArrays.Values) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        inline else => |values, tag| try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(values), std.mem.sliceAsBytes(@field(actual, @tagName(tag)))),
    }
}

test "[integration] - [decoded arrays]: decodes retained records exactly like streamed decoding" {
    const source = @embedFile("data/writer_indexed.mzML");
    var retained_input = std.Io.Reader.fixed(source);
    var retained = try mzml.StreamReader.init(std.testing.allocator, &retained_input, .{});
    defer retained.deinit();
    var streamed_input = std.Io.Reader.fixed(source);
    var streamed = try mzml.StreamReader.init(std.testing.allocator, &streamed_input, .{});
    defer streamed.deinit();
    const header = try retained.readHeader();
    _ = try streamed.readHeader();
    var from_text = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer from_text.deinit();
    var from_stream = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer from_stream.deinit();
    var records: usize = 0;
    while (try retained.nextRecord()) |record| {
        _ = (try streamed.nextDecodedRecord(&from_stream)).?;
        try from_text.decodeRecord(record, header.groups);
        try std.testing.expectEqual(from_stream.len(), from_text.len());
        for (0..from_text.len()) |i| {
            const expected = from_stream.get(i).?;
            const actual = from_text.get(i).?;
            try std.testing.expectEqual(expected.source_position, actual.source_position);
            try std.testing.expectEqual(expected.encoding, actual.encoding);
            try expectSameValues(expected.values, actual.values);
        }
        const single = try from_text.decodeArray(record.binaryArrays()[1], record.default_array_length, header.groups);
        try std.testing.expectEqual(@as(usize, 1), from_text.len());
        try expectSameValues(from_stream.get(1).?.values, single);
        records += 1;
    }
    try std.testing.expectEqual(@as(usize, 16), records);
}

test "[failure] - [decoded arrays]: rejects missing or invalid retained text and clears results" {
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    const good = try decodedDocument(std.testing.allocator, "AAAAAAAA8D8=", 12, 1, "MS:1000576");
    defer std.testing.allocator.free(good);
    var input = std.Io.Reader.fixed(good);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const record = (try reader.nextRecord()).?;
    try output.decodeRecord(record, header.groups);
    try std.testing.expectEqual(@as(usize, 2), output.len());
    var broken = record.binaryArrays()[0];
    var binary = broken.children[0];
    binary.text = "!AAAAAAA8D8=";
    broken.children = &.{binary};
    try std.testing.expectError(error.InvalidCharacter, output.decodeArray(broken, 1, header.groups));
    try std.testing.expectEqual(@as(usize, 0), output.len());

    var skipped_input = std.Io.Reader.fixed(good);
    var skipped = try mzml.StreamReader.init(std.testing.allocator, &skipped_input, .{ .payload = .skip });
    defer skipped.deinit();
    const skipped_header = try skipped.readHeader();
    const skipped_record = (try skipped.nextRecord()).?;
    try std.testing.expectError(error.PayloadNotRetained, output.decodeRecord(skipped_record, skipped_header.groups));
    try std.testing.expectEqual(@as(usize, 0), output.len());
}

test "[integration] - [mzML items]: streams selected arrays and XML across short reads" {
    const source = support.HEADER ++ "<spectrumList count='1'><future/>" ++ support.SPECTRUM ++
        "<tail/></spectrumList><between/><chromatogramList count='0'><empty/></chromatogramList>" ++
        "<runTail/></run><documentTail/></mzML>";
    for ([_]usize{ 1, 7, 31 }) |chunk| {
        var buffer: [31]u8 = undefined;
        var input: std.testing.Reader = .init(buffer[0..chunk], &.{.{ .buffer = source }});
        input.artificial_limit = .limited(chunk);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input.interface, .{
            .array_selector = .{ .select = selectSecond },
        });
        defer reader.deinit();
        var fixed = std.Io.Reader.fixed(source);
        var expected = try mzml.StreamReader.init(std.testing.allocator, &fixed, .{ .payload = .skip });
        defer expected.deinit();
        var decoded = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
        defer decoded.deinit();
        var records: usize = 0;
        var fragments: usize = 0;
        while (try expected.nextItem()) |item| {
            const actual = (try reader.nextDecodedItem(&decoded)).?;
            try support.expectItem(item, actual);
            if (actual == .record) {
                records += 1;
                try std.testing.expectEqual(@as(usize, 1), decoded.len());
                try std.testing.expectEqual(@as(usize, 1), decoded.get(0).?.source_position);
                try std.testing.expectEqualSlices(f64, &.{1}, decoded.get(0).?.values.float64);
            } else {
                try std.testing.expectEqual(@as(usize, 0), decoded.len());
                if (actual == .xml) fragments += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), records);
        try std.testing.expectEqual(@as(usize, 6), fragments);
        try std.testing.expectEqual(null, try reader.nextDecodedItem(&decoded));
        try std.testing.expectEqual(@as(usize, 0), decoded.len());
    }
}

test "[edge] - [mzML reader]: reuses cursor storage for discarded XML" {
    const fragment = "<e:note xmlns:e='urn:note' e:label='A&amp;B'>before<e:part/>after<![CDATA[<&>]]></e:note>";
    const source = "<mzML xmlns='http://psi.hupo.org/ms/mzml'><run><spectrumList>" ++
        fragment ++ "<spectrum id='s'/>" ++ fragment ++ "</spectrumList></run></mzML>";
    var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(allocations.allocator(), &input, .{});
    defer reader.deinit();
    try std.testing.expectEqualStrings("s", (try reader.nextRecord()).?.id);
    allocations.fail_index = allocations.alloc_index;
    allocations.resize_fail_index = allocations.resize_index;
    try std.testing.expectEqual(null, try reader.nextRecord());
    try std.testing.expectEqual(null, reader.diagnostic());
    try std.testing.expect(!allocations.has_induced_failure);
}

test "[property] - [mzML items]: discarding XML preserves parser errors and diagnostic locations" {
    const prefix = "<mzML xmlns='http://psi.hupo.org/ms/mzml'><run><spectrumList>";
    const Case = struct {
        fragment: []const u8,
        limits: mzml.StreamReader.Limits = .{},
        failure: anyerror = error.InvalidXml,
    };
    for ([_]Case{
        .{ .fragment = "<future><part>" },
        .{ .fragment = "<future></other>" },
        .{ .fragment = "<future>&missing;</future>" },
        .{ .fragment = "<future><![CDATA[unfinished" },
        .{ .fragment = "<future><!--unfinished" },
        .{ .fragment = "<future><part label='unfinished" },
        .{ .fragment = "<future><e:part/></future>" },
        .{ .fragment = "<future xmlns:a='urn:a' xmlns:b='urn:a'><part a:x='1' b:x='2'/></future>" },
        .{ .fragment = "<future>\x01</future>" },
        .{ .fragment = "<future><a/><b/><c/></future>", .limits = .{ .nodes = 3 }, .failure = error.LimitExceeded },
        .{ .fragment = "<future>" ** mzml.MAX_DEPTH, .failure = error.LimitExceeded },
        .{ .fragment = "<future a='1' b='2'/>", .limits = .{ .attributes = 1 }, .failure = error.LimitExceeded },
        .{ .fragment = "<future a='" ++ "x" ** 129 ++ "'/>", .limits = .{ .attribute_bytes = 128 }, .failure = error.LimitExceeded },
    }) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, case.fragment });
        defer std.testing.allocator.free(source);
        const utf16 = try std.testing.allocator.alloc(u8, source.len * 2 + 2);
        defer std.testing.allocator.free(utf16);
        for ([_]?std.builtin.Endian{ null, .little, .big }) |endian| {
            const bytes = if (endian) |order| encoded: {
                std.mem.writeInt(u16, utf16[0..2], 0xfeff, order);
                for (source, 0..) |byte, i| std.mem.writeInt(u16, utf16[2 + i * 2 ..][0..2], byte, order);
                break :encoded utf16;
            } else source;
            var expected: ?mzml.Diagnostic = null;
            for ([_]usize{ 1, 7, 31 }) |chunk| {
                for ([_]bool{ true, false }) |retain| {
                    var buffer: [31]u8 = undefined;
                    var input: std.testing.Reader = .init(buffer[0..chunk], &.{.{ .buffer = bytes }});
                    input.artificial_limit = .limited(chunk);
                    var reader = try mzml.StreamReader.init(std.testing.allocator, &input.interface, .{ .limits = case.limits });
                    defer reader.deinit();
                    try std.testing.expectEqual(.list_start, std.meta.activeTag((try reader.nextItem()).?));
                    if (retain) {
                        try std.testing.expectError(case.failure, reader.nextItem());
                    } else try std.testing.expectError(case.failure, reader.nextRecord());
                    const saved = reader.diagnostic().?;
                    try std.testing.expectError(error.FailedState, reader.nextRecord());
                    try std.testing.expectEqualDeep(saved, reader.diagnostic().?);
                    var report = saved;
                    report.operation = .read_item;
                    if (expected) |value| {
                        try std.testing.expectEqualDeep(value, report);
                    } else expected = report;
                }
            }
        }
    }
}

test "[failure] - [mzML items]: bounds each XML item and stops at truncated input" {
    const prefix = "<mzML xmlns='http://psi.hupo.org/ms/mzml'><run><spectrumList count='0'>";
    const suffix = "</spectrumList></run></mzML>";
    const Check = struct {
        fn read(allocator: std.mem.Allocator, source: []const u8, options: mzml.StreamReader.Options) !void {
            var input = std.Io.Reader.fixed(source);
            var reader = try mzml.StreamReader.init(allocator, &input, options);
            defer reader.deinit();
            while (try reader.nextItem()) |_| {}
        }
        fn copyFirst(allocator: std.mem.Allocator) !void {
            var input = std.Io.Reader.fixed(prefix ++ "<future><part/></future>" ++ suffix);
            var reader = try mzml.StreamReader.init(allocator, &input, .{});
            defer reader.deinit();
            _ = try reader.nextItem();
            var copy = try mzml.owned.Item.init(allocator, (try reader.nextItem()).?, .{});
            defer copy.deinit();
            var output: [4096]u8 = undefined;
            var sink: std.Io.Writer = .fixed(&output);
            var writer = try mzml.Writer.init(allocator, &sink, .{});
            defer writer.deinit();
            try writer.writeHeader((try reader.readHeader()).*);
            try writer.beginListWithAttributes(.spectrum_list, 0, &.{});
            try writer.writeItem(copy.value);
            try writer.endList();
            try writer.finish();
        }
    };
    try Check.read(std.testing.allocator, prefix ++ "<future/>" ** 100 ++ suffix, .{ .limits = .{ .record_bytes = 128, .nodes = 3 } });
    try std.testing.expectError(error.LimitExceeded, Check.read(std.testing.allocator, prefix ++ "<future>" ++ "x" ** 129 ++ "</future>" ++ suffix, .{ .limits = .{ .record_bytes = 128 } }));
    try std.testing.expectError(error.LimitExceeded, Check.read(std.testing.allocator, prefix ++ "<future><a/><b/><c/></future>" ++ suffix, .{ .limits = .{ .nodes = 3 } }));
    inline for (.{ "<future><nested>", "<future></other>", "<future>&missing;</future>" }) |fragment| {
        var input = std.Io.Reader.fixed(prefix ++ fragment);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        _ = try reader.nextItem();
        try std.testing.expectError(error.InvalidXml, reader.nextItem());
        try std.testing.expectError(error.FailedState, reader.nextItem());
    }
    for ([_][]const u8{
        prefix ++ "</spectrumList>",
        prefix ++ "</spectrumList></run><future>",
        prefix ++ "</spectrumList></run><future/>",
    }) |source| {
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        while (reader.nextItem()) |item| {
            try std.testing.expect(item != null);
        } else |err| try std.testing.expectEqual(error.InvalidXml, err);
        try std.testing.expectError(error.FailedState, reader.nextItem());
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.copyFirst, .{});
}

test "[integration] - [mzML extensions]: selected decoding keeps unfamiliar metadata" {
    for ([_]usize{ 1, 7, 31 }) |chunk| {
        try compareDecoded(support.EXTENSIONS, chunk);
        try compareDecodedWithSelection(support.EXTENSIONS, chunk, true);
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecodedRecord, .{ support.EXTENSIONS, mzml.StreamReader.DecodedArrays.Limits{} });
}

test "[integration] - [mzML children]: keeps misplaced known names out of metadata and decoding" {
    var input = std.Io.Reader.fixed(support.KNOWN_CHILDREN);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    try std.testing.expectEqual(@as(usize, 1), header.document.children.len);
    try std.testing.expectEqual(@as(usize, 1), header.groups.len);
    try std.testing.expectEqualStrings("encoding", header.groups[0].id);
    try std.testing.expectEqual(@as(usize, 0), header.run.params.len);
    try std.testing.expectEqual(@as(usize, 0), header.run.children.len);
    var decoded = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer decoded.deinit();
    const record = (try reader.nextDecodedRecord(&decoded)).?;
    try std.testing.expectEqualStrings("s0", record.id);
    try std.testing.expectEqual(@as(?i32, 1), try record.msLevel(header.groups));
    try std.testing.expectEqual(@as(usize, 2), record.node.children.len);
    try std.testing.expectEqual(@as(usize, 1), record.scans().len);
    try std.testing.expectEqual(@as(usize, 2), record.binaryArrays().len);
    try std.testing.expectEqual(@as(usize, 2), decoded.len());
    for (0..2) |position| {
        try std.testing.expectEqual(position, decoded.get(position).?.source_position);
        try std.testing.expectEqual(@as(usize, 2), record.binaryArrays()[position].params.len);
        try std.testing.expectEqualSlices(f64, &.{@floatFromInt(position + 1)}, decoded.get(position).?.values.float64);
    }
    const next = (try reader.nextDecodedRecord(&decoded)).?;
    try std.testing.expectEqualStrings("c0", next.id);
    try std.testing.expectEqual(@as(usize, 0), next.node.children.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.len());
    try std.testing.expectEqual(null, try reader.nextDecodedRecord(&decoded));
    try std.testing.expectEqual(@as(usize, 1), header.spectrum_list.?.observed_count);
    try std.testing.expectEqual(@as(usize, 1), header.chromatogram_list.?.observed_count);
    for ([_]usize{ 1, 7, 31 }) |chunk| {
        try compareDecoded(support.KNOWN_CHILDREN, chunk);
        try compareDecodedWithSelection(support.KNOWN_CHILDREN, chunk, true);
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecodedRecord, .{ support.KNOWN_CHILDREN, mzml.StreamReader.DecodedArrays.Limits{} });
}

test "[integration] - [mzML containers]: retains later occurrences without merging their contents" {
    var input = std.Io.Reader.fixed(support.REPEATED_CONTAINERS);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    try std.testing.expectEqual(@as(usize, 2), header.document.children.len);
    try std.testing.expectEqual(@as(usize, 1), header.groups.len);
    try std.testing.expectEqualStrings("encoding", header.groups[0].id);
    try std.testing.expectEqual(@as(usize, 1), header.run.children.len);
    try std.testing.expectEqual(mzml.model.Content.Item{ .children = 1 }, header.document.content.?.items[1]);
    try std.testing.expect(std.mem.indexOf(u8, header.document.content.?.items[2].xml, "zmz-reencoded-0") != null);
    try std.testing.expect(std.mem.indexOf(u8, header.run.content.?.items[2].xml, "second-source") != null);
    var decoded = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer decoded.deinit();
    const record = (try reader.nextDecodedRecord(&decoded)).?;
    try std.testing.expectEqual(@as(usize, 1), record.scans().len);
    try std.testing.expectEqual(@as(f64, 1), (try record.scans()[0].scanStartTime(header.groups)).?.value);
    try std.testing.expectEqual(@as(usize, 1), record.precursors().len);
    try std.testing.expectEqualStrings("first", record.precursors()[0].attribute("spectrumRef").?);
    const ions = try record.precursors()[0].selectedIons();
    try std.testing.expectEqual(@as(usize, 1), ions.len);
    try std.testing.expectEqualStrings("first ion", ions[0].params[0].user.name.?);
    try std.testing.expectEqual(@as(usize, 1), record.products().len);
    try std.testing.expectEqual(@as(usize, 2), record.binaryArrays().len);
    try std.testing.expectEqual(@as(usize, 2), decoded.len());
    for (0..2) |i| try std.testing.expectEqualSlices(f64, &.{@floatFromInt(i + 1)}, decoded.get(i).?.values.float64);
    try std.testing.expectEqual(record.binaryArrays()[0], (try record.arrayByRole(header.groups, mzml.model.Terms.MZ_ARRAY)).?);
    try std.testing.expect(std.mem.indexOf(u8, record.node.content.?.items[record.node.content.?.items.len - 1].xml, "AAAAAAAACEA=") != null);
    const chrom = (try reader.nextDecodedRecord(&decoded)).?;
    try std.testing.expectEqual(@as(usize, 1), chrom.precursors().len);
    try std.testing.expectEqual(@as(usize, 1), chrom.products().len);
    try std.testing.expectEqual(@as(usize, 0), chrom.binaryArrays().len);
    try std.testing.expectEqual(@as(usize, 0), decoded.len());
    try std.testing.expectEqual(null, try reader.nextDecodedRecord(&decoded));
    for ([_]usize{ 1, 7, 31 }) |chunk| {
        try compareDecoded(support.REPEATED_CONTAINERS, chunk);
        try compareDecodedWithSelection(support.REPEATED_CONTAINERS, chunk, true);
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecodedRecord, .{ support.REPEATED_CONTAINERS, mzml.StreamReader.DecodedArrays.Limits{} });
}

test "[failure] - [mzML containers]: bounds extra XML and leaves extra group definitions unexpanded" {
    const prefix = "<mzML xmlns='http://psi.hupo.org/ms/mzml'><run><spectrumList><spectrum id='s'><scanList/>";
    const suffix = "</spectrum></spectrumList></run></mzML>";
    const nodes = prefix ++ "<scanList><scan/><scan/></scanList>" ++ suffix;
    try support.readAll(std.testing.allocator, nodes, .{ .limits = .{ .nodes = 5 } });
    try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, nodes, .{ .limits = .{ .nodes = 4 } }));
    try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, prefix ++ "<scanList>" ++ "x" ** 2048 ++ "</scanList>" ++ suffix, .{ .limits = .{ .record_bytes = 2048 } }));
    inline for (.{ "<scanList></other>", "<scanList><scan>", "<scanList>&missing;</scanList>" }) |body| {
        var input = std.Io.Reader.fixed(prefix ++ body ++ suffix);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        try std.testing.expectError(error.InvalidXml, reader.nextRecord());
        try std.testing.expectError(error.FailedState, reader.nextRecord());
    }
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.REPEATED_CONTAINERS, "ref=\"encoding\"", "ref=\"zmz-reencoded-0\"");
    defer std.testing.allocator.free(source);
    try support.readAll(std.testing.allocator, source, .{});
    try std.testing.expectError(error.MissingGroup, readDecoded(std.testing.allocator, source, .{}));
}

test "[failure] - [mzML extensions]: bounds retained XML and stops on malformed subtrees" {
    for ([_]mzml.StreamReader.Options{
        .{ .limits = .{ .header_bytes = 128 } },
        .{ .limits = .{ .record_bytes = 128 } },
        .{ .limits = .{ .nodes = 3 } },
        .{ .limits = .{ .attributes = 2 } },
    }) |options| try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.EXTENSIONS, options));
    const prefix = support.HEADER ++ "<spectrumList count='1'><spectrum id='x' index='0' defaultArrayLength='0'>";
    const minimal = "<mzML xmlns='http://psi.hupo.org/ms/mzml'><run><spectrumList count='1'><spectrum id='x' index='0' defaultArrayLength='0'>";
    const suffix = "</spectrum></spectrumList></run></mzML>";
    inline for (.{ "future", "software" }) |name| {
        const opening = "<" ++ name ++ ">";
        const closing = "</" ++ name ++ ">";
        const nodes = minimal ++ opening ++ "<a/><b/>" ++ closing ++ suffix;
        try support.readAll(std.testing.allocator, nodes, .{ .limits = .{ .nodes = 4 } });
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, nodes, .{ .limits = .{ .nodes = 3 } }));
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, minimal ++ opening ++ "x" ** 4096 ++ closing ++ suffix, .{ .limits = .{ .record_bytes = 2048 } }));
        inline for (.{ opening ++ "<nested>", opening ++ "</other>", opening ++ "&missing;" ++ closing }) |fragment| {
            var input = std.Io.Reader.fixed(prefix ++ fragment);
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
            defer reader.deinit();
            try std.testing.expectError(error.InvalidXml, reader.nextRecord());
            try std.testing.expectError(error.FailedState, reader.nextRecord());
        }
    }
}

test "[integration] - [mzML 1.0 reading]: streams exact values and selections across refills" {
    for ([_]usize{ 1, 7, 31 }) |chunk| {
        try compareDecoded(support.HISTORICAL, chunk);
        try compareDecodedWithSelection(support.HISTORICAL, chunk, true);
    }
    var input = std.Io.Reader.fixed(support.HISTORICAL);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    const first = (try reader.nextDecodedRecord(&output)).?;
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, output.get(0).?.values.float64);
    try std.testing.expectEqualSlices(f64, &.{ 3, 4 }, output.get(1).?.values.float64);
    const start = std.mem.indexOf(u8, support.HISTORICAL, "<spectrum id=\"S19\"").?;
    try std.testing.expectEqual(@as(u64, start), first.node.start_offset);
    _ = (try reader.nextDecodedRecord(&output)).?;
    try std.testing.expectEqual(@as(usize, 0), output.len());
    _ = (try reader.nextDecodedRecord(&output)).?;
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, output.get(0).?.values.float64);
    try std.testing.expectEqual(null, try reader.nextDecodedRecord(&output));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.readAll, .{ support.HISTORICAL, mzml.StreamReader.Options{} });
}

test "[failure] - [mzML 1.0 reading]: stops at truncated historical metadata or payload" {
    for ([_][]const u8{ "<softwareParam", "<sourceFileRef ref=", "<spectrumDescription>", "<acquisition number=", "<binary>" }) |marker| {
        const end = std.mem.indexOf(u8, support.HISTORICAL, marker).? + marker.len;
        var input = std.Io.Reader.fixed(support.HISTORICAL[0..end]);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
        defer output.deinit();
        while (reader.nextDecodedRecord(&output)) |record| {
            try std.testing.expect(record != null);
        } else |err| {
            try std.testing.expectEqual(error.InvalidXml, err);
            try std.testing.expectEqual(@as(usize, 0), output.len());
            try std.testing.expectError(error.FailedState, reader.nextRecord());
            continue;
        }
        return error.TestUnexpectedResult;
    }
}

const Selection = struct {
    mode: enum { second, named, group, all, none },
    calls: usize = 0,
    wrong_position: bool = false,

    fn select(user_data: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
        const self: *Selection = @ptrCast(@alignCast(user_data.?));
        self.wrong_position = self.wrong_position or view.position != self.calls % 2;
        self.calls += 1;
        const keep = switch (self.mode) {
            .second => view.position == 1,
            .named, .group => blk: {
                const accession = if (self.mode == .named) "X:unknown-role" else "MS:1000523";
                const parameter = try view.node.parameter(view.groups, .{ .raw = accession }) orelse break :blk false;
                break :blk self.mode == .group or (std.mem.eql(u8, parameter.name.?, "future array") and parameter.value == null);
            },
            .all => true,
            .none => false,
        };
        return if (keep) .retain else .skip;
    }
};

fn selectSecond(_: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
    return if (view.position == 1) .retain else .skip;
}

fn expectSelectedNode(expected: mzml.model.Node, actual: mzml.model.Node) !void {
    try std.testing.expectEqual(expected.kind, actual.kind);
    try std.testing.expectEqualDeep(expected.attributes, actual.attributes);
    try std.testing.expectEqualDeep(expected.params, actual.params);
    try std.testing.expectEqualDeep(expected.content, actual.content);
    try std.testing.expectEqual(expected.start_offset, actual.start_offset);
    try std.testing.expectEqual(expected.content_offset, actual.content_offset);
    try std.testing.expectEqual(expected.end_offset, actual.end_offset);
    if (expected.kind != .binary or actual.text != null)
        try std.testing.expectEqualDeep(expected.text, actual.text);
    try std.testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |left, right| try expectSelectedNode(left, right);
}

fn readDecoded(allocator: std.mem.Allocator, source: []const u8, limits: mzml.StreamReader.DecodedArrays.Limits) !void {
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(allocator, &input, .{});
    defer reader.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(allocator, limits);
    defer output.deinit();
    while (try reader.nextDecodedRecord(&output)) |_| {}
    try std.testing.expectEqual(@as(usize, 0), output.len());
    try std.testing.expectEqual(null, output.get(0));
}

fn readDecodedRecord(allocator: std.mem.Allocator, source: []const u8, limits: mzml.StreamReader.DecodedArrays.Limits) !void {
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(allocator, &input, .{});
    defer reader.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(allocator, limits);
    defer output.deinit();
    errdefer std.debug.assert(output.len() == 0);
    const record = reader.nextDecodedRecord(&output) catch |err| {
        const report = reader.diagnostic().?;
        try std.testing.expectEqual(err, report.code);
        if (err == error.OutOfMemory) try std.testing.expectEqual(.out_of_memory, report.id);
        var bytes: [512]u8 = undefined;
        var sink = std.Io.Writer.fixed(&bytes);
        try report.format(&sink);
        return err;
    };
    try std.testing.expect(record != null);
    try std.testing.expectEqual(@as(usize, 2), output.len());
}

fn compareDecoded(source: []const u8, chunk: usize) !void {
    try compareDecodedWithSelection(source, chunk, false);
}

fn compareDecodedWithSelection(source: []const u8, chunk: usize, selected: bool) !void {
    var storage: [31]u8 = undefined;
    var a_input = std.Io.Reader.fixed(source);
    var b_input: std.testing.Reader = .init(storage[0..chunk], &.{.{ .buffer = source }});
    b_input.artificial_limit = .limited(chunk);
    var a = try mzml.StreamReader.init(std.testing.allocator, &a_input, .{});
    defer a.deinit();
    var b = try mzml.StreamReader.init(std.testing.allocator, &b_input.interface, .{
        .array_selector = if (selected) .{ .select = selectSecond } else null,
    });
    defer b.deinit();
    const header = try a.readHeader();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    while (try a.nextRecord()) |record| {
        const other = (try b.nextDecodedRecord(&output)).?;
        try expectSelectedNode(record.node, other.node);
        try std.testing.expectEqual(if (selected) @intFromBool(record.binaryArrays().len > 1) else record.binaryArrays().len, output.len());
        var arrays = record.arrays(header.groups);
        var position: usize = 0;
        while (try arrays.next()) |array| : (position += 1) {
            if (selected and position != 1) continue;
            const actual = output.get(if (selected) 0 else position).?;
            try std.testing.expectEqual(position, actual.source_position);
            try std.testing.expectEqualDeep(array.encoding, actual.encoding);
            switch (actual.values) {
                inline else => |values| {
                    const T = @typeInfo(@TypeOf(values)).pointer.child;
                    try std.testing.expectEqual(array.length, values.len);
                    const expected = try std.testing.allocator.alloc(T, values.len);
                    defer std.testing.allocator.free(expected);
                    const transport = try std.testing.allocator.alloc(u8, array.node.child(.binary).?.text.?.len);
                    defer std.testing.allocator.free(transport);
                    const transformed = try std.testing.allocator.alloc(u8, try mzml.arrays.wireBound(T, values.len, array.encoding.pipeline));
                    defer std.testing.allocator.free(transformed);
                    try array.decode(T, expected, .{ .transport = transport, .transformed = transformed });
                    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(values));
                },
            }
        }
        for (other.binaryArrays()) |array| try std.testing.expectEqual(null, array.child(.binary).?.text);
    }
    try std.testing.expectEqual(null, try b.nextDecodedRecord(&output));
    try std.testing.expectEqual(@as(usize, 0), output.len());
}

fn decodedDocument(allocator: std.mem.Allocator, text: []const u8, encoded: usize, length: usize, codec: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, support.HEADER ++
        "<spectrumList count='1' defaultDataProcessingRef='dp'><spectrum id='x' index='0' defaultArrayLength='{d}'>" ++
        "<binaryDataArrayList count='2'><binaryDataArray encodedLength='{d}'>" ++
        "<cvParam cvRef='MS' accession='MS:1000523' name='64-bit float'/>" ++
        "<cvParam cvRef='MS' accession='{s}' name='codec'/><binary>{s}</binary>" ++
        "</binaryDataArray><binaryDataArray encodedLength='0' arrayLength='0'><referenceableParamGroupRef ref='encoding'/><binary/></binaryDataArray>" ++
        "</binaryDataArrayList></spectrum></spectrumList></run></mzML>", .{ length, encoded, codec, text });
}

fn readSelectedDecoded(allocator: std.mem.Allocator, source: []const u8) !void {
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(allocator, &input, .{ .array_selector = .{ .select = selectSecond } });
    defer reader.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(allocator, .{});
    defer output.deinit();
    errdefer std.debug.assert(output.len() == 0);
    while (try reader.nextDecodedRecord(&output)) |_| {
        try std.testing.expectEqual(@as(usize, 1), output.len());
        try std.testing.expectEqual(@as(usize, 1), output.get(0).?.source_position);
    }
}

test "[integration] - [mzML parameters]: preserves source order and absent fields" {
    const params = "<userParam value=''/><cvParam accession='X:first'/>" ++
        "<referenceableParamGroupRef ref='encoding'/><cvParam/><userParam name='' unitName=''/>" ++
        "<referenceableParamGroupRef/>";
    const expected = [_]mzml.cv.Entry{
        .{ .user = .{ .value = "" } },
        .{ .cv = .{ .accession = .{ .raw = "X:first" } } },
        .{ .group_ref = .{ .ref = "encoding" } },
        .{ .cv = .{} },
        .{ .user = .{ .name = "", .unit = .{ .name = "" } } },
        .{ .group_ref = .{ .ref = null } },
    };
    const source = support.HEADER ++ params ++ "<spectrumList count='1' defaultDataProcessingRef='dp'>" ++
        "<spectrum id='x' index='0' defaultArrayLength='1'>" ++ params ++ support.ARRAYS ++
        "</spectrum></spectrumList></run></mzML>";
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    try std.testing.expectEqualDeep(&expected, header.run.params);
    const record = (try reader.nextRecord()).?;
    try std.testing.expectEqualDeep(&expected, record.node.params);
    try std.testing.expectEqual(null, try reader.nextRecord());
    try compareDecoded(source, 1);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild });
    defer index.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    var fetched = (try index.atDecoded(std.testing.allocator, .spectrum, 0, &output)).?;
    defer fetched.deinit();
    try std.testing.expectEqualDeep(&expected, index.header().run.params);
    try std.testing.expectEqualDeep(&expected, fetched.value.node.params);
    try std.testing.expectEqual(@as(usize, 2), output.len());
    for (0..output.len()) |i| try std.testing.expectEqualSlices(f64, &.{1}, output.get(i).?.values.float64);
}

test "[integration] - [mzML parameters]: preserves parent parameters between child elements" {
    const source = support.HEADER ++ "<spectrumList count='1'><spectrum id='s' index='0' defaultArrayLength='1'>" ++
        "<userParam name='first'/><scanList><scan><userParam name='scan-first'/><scanWindowList/>" ++
        "<userParam name='scan-last'/></scan></scanList><cvParam accession='MS:1000511' value='2'/>" ++
        "<precursorList><precursor><selectedIonList><selectedIon><userParam name='ion'/></selectedIon></selectedIonList></precursor></precursorList>" ++
        "<referenceableParamGroupRef ref='encoding'/>" ++ support.ARRAYS ++ "<userParam name='last'/>" ++
        "</spectrum></spectrumList></run></mzML>";
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const record = (try reader.nextRecord()).?;
    try std.testing.expectEqualDeep(&[_]mzml.cv.Entry{
        .{ .user = .{ .name = "first" } },
        .{ .cv = .{ .accession = .{ .raw = "MS:1000511" }, .value = "2" } },
        .{ .group_ref = .{ .ref = "encoding" } },
        .{ .user = .{ .name = "last" } },
    }, record.node.params);
    try std.testing.expectEqual(@as(?i32, 2), try record.msLevel((try reader.readHeader()).groups));
    try std.testing.expectEqualDeep(&[_]mzml.cv.Entry{
        .{ .user = .{ .name = "scan-first" } }, .{ .user = .{ .name = "scan-last" } },
    }, record.scans()[0].params);
    try std.testing.expectEqualStrings("ion", (try record.precursors()[0].selectedIons())[0].params[0].user.name.?);
    try std.testing.expectEqual(@as(usize, 3), record.node.children.len);
    try compareDecoded(source, 1);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild });
    defer index.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    var fetched = (try index.atDecoded(std.testing.allocator, .spectrum, 0, &output)).?;
    defer fetched.deinit();
    try expectSelectedNode(record.node, fetched.value.node);
    try std.testing.expectEqual(@as(usize, 2), output.len());
    for (0..output.len()) |i| try std.testing.expectEqualSlices(f64, &.{1}, output.get(i).?.values.float64);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecodedRecord, .{ source, mzml.StreamReader.DecodedArrays.Limits{} });
    try support.readAll(std.testing.allocator, source, .{ .limits = .{ .list_entries = 4 } });
    try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, source, .{ .limits = .{ .list_entries = 3 } }));
    try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild, .reader = .{ .limits = .{ .list_entries = 3 } } }));
}

test "[integration] - [mzML parameters]: retains late array declarations without streaming guessed values" {
    const source = support.HEADER ++ "<spectrumList count='1'><spectrum id='s' index='0' defaultArrayLength='1'>" ++
        "<binaryDataArrayList><binaryDataArray><referenceableParamGroupRef ref='encoding'/>" ++
        "<binary>AAAAAAAA8D8=</binary><cvParam accession='X:role' value='late'/></binaryDataArray>" ++
        "</binaryDataArrayList></spectrum></spectrumList></run></mzML>";
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const record = (try reader.nextRecord()).?;
    const array = record.binaryArrays()[0];
    try std.testing.expectEqualStrings("late", (try array.parameter((try reader.readHeader()).groups, .{ .raw = "X:role" })).?.value.?);
    var values: [1]f64 = undefined;
    var scratch: [8]u8 = undefined;
    try mzml.model.decodeArray(f64, &values, array, 1, (try reader.readHeader()).groups, .{ .transport = &scratch, .transformed = &.{} });
    try std.testing.expectEqual(@as(f64, 1), values[0]);
    try compareDecoded(source, 1);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild });
    defer index.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    var decoded = (try index.atDecoded(std.testing.allocator, .spectrum, 0, &output)).?;
    defer decoded.deinit();
    try expectSelectedNode(record.node, decoded.value.node);
    try std.testing.expectEqual(@as(usize, 1), output.len());
    try std.testing.expectEqualSlices(f64, &.{1}, output.get(0).?.values.float64);
    var fetched = (try index.at(std.testing.allocator, .spectrum, 0)).?;
    defer fetched.deinit();
    try std.testing.expectEqualDeep(record, fetched.value);
    inline for (.{
        .{ "MS:1000521", error.ConflictingPrimitive },
        .{ "MS:1000574", error.ConflictingCompression },
    }) |case| {
        const conflicting = try std.mem.replaceOwned(u8, std.testing.allocator, source, "X:role", case[0]);
        defer std.testing.allocator.free(conflicting);
        try support.readAll(std.testing.allocator, conflicting, .{});
        try std.testing.expectError(case[1], readDecoded(std.testing.allocator, conflicting, .{}));
    }
}

test "[integration] - [mzML arrays]: retains repeated encoding terms across numeric reads" {
    const declarations = "<cvParam accession='MS:1000523' name='source primitive label' extra='keep'/>" ++
        "<cvParam accession='MS:1000576' name='source codec label'><note xmlns='urn:producer'>keep</note></cvParam>";
    const reference = "<referenceableParamGroupRef ref='encoding'/>";
    inline for (.{
        .{ reference, declarations ++ declarations },
        .{ reference, reference ++ declarations },
        .{ reference, declarations ++ reference },
        .{ reference, reference ++ reference },
        .{ "</referenceableParamGroup>", declarations ++ "</referenceableParamGroup>" },
        .{ "</binary>", "</binary>" ++ declarations },
    }) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, case[0], case[1]);
        defer std.testing.allocator.free(source);
        try compareDecoded(source, 1);
        try compareDecodedWithSelection(source, 7, true);
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const header = try reader.readHeader();
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild });
        defer index.deinit();
        var decoded = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
        defer decoded.deinit();
        while (try reader.nextRecord()) |record| {
            for (record.binaryArrays()) |array| {
                var value: [1]f64 = undefined;
                try mzml.model.decodeArray(f64, &value, array, 1, header.groups, .{ .transport = &.{}, .transformed = &.{} });
                try std.testing.expectEqualSlices(f64, &.{1}, &value);
            }
            var fetched = (try index.byIdDecoded(std.testing.allocator, record.id, &decoded)).?;
            defer fetched.deinit();
            try expectSelectedNode(record.node, fetched.value.node);
            try std.testing.expectEqual(@as(usize, 2), decoded.len());
            for (0..decoded.len()) |i| try std.testing.expectEqualSlices(f64, &.{1}, decoded.get(i).?.values.float64);
        }
    }
}

test "[integration] - [mzML parameters]: defers group and encoding errors until requested" {
    const cases = .{
        .{ "<referenceableParamGroup id='encoding'>", "<referenceableParamGroup id='encoding'><referenceableParamGroupRef ref='other'/>", error.NestedGroup },
        .{ "<referenceableParamGroupRef ref='encoding'/>", "<referenceableParamGroupRef/>", error.MissingGroup },
        .{ "accession='MS:1000523'", "", error.MissingPrimitive },
    };
    inline for (cases) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, case[0], case[1]);
        defer std.testing.allocator.free(source);
        try support.readAll(std.testing.allocator, source, .{});
        try std.testing.expectError(case[2], readDecoded(std.testing.allocator, source, .{}));
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild });
        defer index.deinit();
        var ordinary = (try index.at(std.testing.allocator, .spectrum, 0)).?;
        defer ordinary.deinit();
        var arrays = ordinary.value.arrays(index.header().groups);
        try std.testing.expectError(case[2], arrays.next());
        var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
        defer output.deinit();
        try std.testing.expectError(case[2], index.atDecoded(std.testing.allocator, .spectrum, 0, &output));
        try std.testing.expectEqual(@as(usize, 0), output.len());
    }
}

test "[integration] - [mzML decoded reading]: preserves metadata and values across fragments and codecs" {
    for ([_]usize{ 1, 7, 31 }) |chunk| try compareDecoded(support.DOCUMENT, chunk);
    var utf16: [support.DOCUMENT.len * 2 + 2]u8 = undefined;
    inline for (.{ std.builtin.Endian.little, .big }) |endian| {
        std.mem.writeInt(u16, utf16[0..2], 0xfeff, endian);
        for (support.DOCUMENT, 0..) |byte, index| std.mem.writeInt(u16, utf16[2 + index * 2 ..][0..2], byte, endian);
        try compareDecoded(&utf16, 7);
    }
    var buffer: [32768]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    try support.constructFixture(std.testing.allocator, &sink, true, std.meta.tags(mzml.arrays.Pipeline));
    try compareDecoded(sink.buffered(), 7);
    for ([_][]const u8{ "", " \t\r\n" }) |text| {
        const source = try decodedDocument(std.testing.allocator, text, 0, 0, "MS:1000574");
        defer std.testing.allocator.free(source);
        try compareDecoded(source, 1);
        try compareDecodedWithSelection(source, 1, true);
    }
}

test "[integration] - [mzML decoded selection]: preserves source positions, metadata, and codec values" {
    for ([_]usize{ 1, 7, 31 }) |chunk| try compareDecodedWithSelection(support.DOCUMENT, chunk, true);
    const source = @embedFile("data/writer_plain.mzML");
    try compareDecodedWithSelection(source, 7, true);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readSelectedDecoded, .{source});
}

test "[integration] - [mzML decoded selection]: selects MS1 from record parameters available before the array list" {
    const RecordSelection = struct {
        records: usize = 0,
        arrays: usize = 0,
        saw_late: bool = false,

        fn record(data: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.records += 1;
            if (view.node.kind != .spectrum) return .skip;
            self.saw_late = self.saw_late or try view.node.parameter(view.groups, .{ .raw = "X:late" }) != null;
            return if (try view.node.integer(i32, view.groups, mzml.model.Terms.MS_LEVEL) == 1) .retain else .skip;
        }

        fn array(data: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.arrays += 1;
            return if (view.position == 1) .retain else .skip;
        }
    };
    const header = try std.mem.replaceOwned(u8, std.testing.allocator, support.HEADER, "</referenceableParamGroup>", "<cvParam accession='MS:1000511' value='1'/></referenceableParamGroup>");
    defer std.testing.allocator.free(header);
    const source = try std.mem.concat(std.testing.allocator, u8, &.{
        header,
        "<spectrumList count='4' defaultDataProcessingRef='dp'>" ++
            "<spectrum id='ms1' index='0' defaultArrayLength='1'><scanList count='0'/>" ++
            "<referenceableParamGroupRef ref='encoding'/>" ++ support.ARRAYS ++ "<cvParam accession='X:late'/></spectrum>" ++
            "<spectrum id='ms2' index='1' defaultArrayLength='1'><cvParam accession='MS:1000511' value='2'/>" ++
            "<binaryDataArrayList count='1'><binaryDataArray encodedLength='1'><binary>!</binary></binaryDataArray></binaryDataArrayList></spectrum>" ++
            "<spectrum id='empty-list' index='2' defaultArrayLength='0'><cvParam accession='MS:1000511' value='1'/><binaryDataArrayList count='0'/></spectrum>" ++
            "<spectrum id='no-list' index='3' defaultArrayLength='0'/></spectrumList>" ++
            "<chromatogramList count='1' defaultDataProcessingRef='dp'><chromatogram id='tic' index='0' defaultArrayLength='1'>" ++
            support.ARRAYS ++ "</chromatogram></chromatogramList></run></mzML>",
    });
    defer std.testing.allocator.free(source);
    for ([_]bool{ false, true }) |numeric| {
        var selection: RecordSelection = .{};
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{
            .payload = if (numeric) .skip else .retain,
            .array_selector = .{ .user_data = &selection, .select = RecordSelection.array, .select_record = RecordSelection.record },
        });
        defer reader.deinit();
        const groups = (try reader.readHeader()).groups;
        var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
        defer output.deinit();
        var count: usize = 0;
        while (if (numeric) try reader.nextDecodedRecord(&output) else try reader.nextRecord()) |record| {
            defer count += 1;
            if (count == 0) {
                try std.testing.expect((try record.node.parameter(groups, .{ .raw = "X:late" })) != null);
                if (numeric) {
                    try std.testing.expectEqual(@as(usize, 1), output.len());
                    try std.testing.expectEqual(@as(usize, 1), output.get(0).?.source_position);
                    try std.testing.expectEqualSlices(f64, &.{1}, output.get(0).?.values.float64);
                }
            } else try std.testing.expectEqual(@as(usize, 0), output.len());
            for (record.binaryArrays(), 0..) |array, position|
                try std.testing.expectEqual(!numeric and count == 0 and position == 1, array.child(.binary).?.text != null);
        }
        try std.testing.expectEqual(@as(usize, 5), count);
        try std.testing.expectEqual(@as(usize, 4), selection.records);
        try std.testing.expectEqual(@as(usize, 2), selection.arrays);
        try std.testing.expect(!selection.saw_late);
    }
}

test "[failure] - [mzML selection]: fails the read with a diagnostic when a callback fails" {
    const Level = struct {
        fn record(_: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
            return if (try view.node.integer(i32, view.groups, mzml.model.Terms.MS_LEVEL) == 1) .retain else .skip;
        }
    };
    const level = "<cvParam cvRef='MS' accession='MS:1000511' name='ms level' value='1'/>";
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "defaultArrayLength='1'><scanList", "defaultArrayLength='1'>" ++ level ++ level ++ "<scanList");
    defer std.testing.allocator.free(source);
    for ([_]bool{ false, true }) |numeric| {
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{
            .array_selector = .{ .select = selectSecond, .select_record = Level.record },
        });
        defer reader.deinit();
        var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
        defer output.deinit();
        try std.testing.expectError(error.RepeatedParameter, if (numeric) reader.nextDecodedRecord(&output) else reader.nextRecord());
        try std.testing.expectEqual(.invalid_value, reader.diagnostic().?.id);
        try std.testing.expectError(error.FailedState, reader.nextRecord());
    }
}

test "[failure] - [mzML decoded selection]: interprets only selected bytes and clears partial results" {
    inline for (.{
        .{ "MS:1003089", "AAAA", error.UnsupportedEncoding },
        .{ "MS:1000576", "!AAA", error.InvalidCharacter },
    }) |case| {
        const source = try decodedDocument(std.testing.allocator, case[1], 4, 1, case[0]);
        defer std.testing.allocator.free(source);
        try readSelectedDecoded(std.testing.allocator, source);
        try std.testing.expectError(case[2], readDecoded(std.testing.allocator, source, .{}));
    }
    for ([_][]const u8{
        "<binary>!</binary><cvParam accession='MS:1000521'/>",
        "<referenceableParamGroupRef ref='missing'/>",
    }) |replacement| {
        const skipped = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "<binary>AAAA<![CDATA[AAAA]]>8D8&#61;</binary>", replacement);
        defer std.testing.allocator.free(skipped);
        try readSelectedDecoded(std.testing.allocator, skipped);
    }
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "<binary>AAAAAAAA8D8=</binary>", "<binary>!AAAAAAA8D8=</binary>");
    defer std.testing.allocator.free(source);
    var input = std.Io.Reader.fixed(source);
    var selection: Selection = .{ .mode = .all };
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{
        .array_selector = .{ .user_data = &selection, .select = Selection.select },
    });
    defer reader.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    try std.testing.expectError(error.InvalidCharacter, reader.nextDecodedRecord(&output));
    try std.testing.expectEqual(@as(usize, 0), output.len());
    try std.testing.expectEqual(null, output.get(0));
    try std.testing.expectEqual(error.InvalidCharacter, reader.diagnostic().?.code);
    try std.testing.expectError(error.FailedState, reader.nextDecodedRecord(&output));
}

test "[failure] - [mzML reader]: returns completed results before a broken next opening" {
    const opening = support.HEADER ++ "<spectrumList count='2' defaultDataProcessingRef='dp'>";
    for ([_][]const u8{ "", "<spectrum id='empty' index='0' defaultArrayLength='0'/>", support.SPECTRUM }) |record_text| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}<spectrum id='unfinished", .{ opening, record_text });
        defer std.testing.allocator.free(source);
        for ([_]?std.builtin.Endian{ null, .little, .big }) |encoding| {
            const width: usize = if (encoding != null) 2 else 1;
            const bom: usize = if (encoding != null) 2 else 0;
            const bytes = try std.testing.allocator.alloc(u8, bom + source.len * width);
            defer std.testing.allocator.free(bytes);
            if (encoding) |endian| {
                std.mem.writeInt(u16, bytes[0..2], 0xfeff, endian);
                for (source, 0..) |byte, i| std.mem.writeInt(u16, bytes[2 + i * 2 ..][0..2], byte, endian);
            } else @memcpy(bytes, source);
            for ([_]usize{ 1, 31 }) |chunk| {
                var buffer: [31]u8 = undefined;
                var input: std.testing.Reader = .init(buffer[0..chunk], &.{.{ .buffer = bytes }});
                input.artificial_limit = .limited(chunk);
                var reader = try mzml.StreamReader.init(std.testing.allocator, &input.interface, .{});
                defer reader.deinit();
                const header = try reader.readHeader();
                try std.testing.expectEqual(@as(usize, 0), header.spectrum_list.?.observed_count);
                if (record_text.len != 0) {
                    const record = (try reader.nextRecord()).?;
                    try std.testing.expectEqual(bom + opening.len * width, record.node.start_offset);
                    try std.testing.expectEqual(bom + (opening.len + record_text.len) * width, record.node.end_offset);
                    try std.testing.expectEqual(@as(usize, 1), header.spectrum_list.?.observed_count);
                }
                const position = input.interface.seek;
                try std.testing.expectEqual(header, try reader.readHeader());
                try std.testing.expectEqual(position, input.interface.seek);
                try std.testing.expectError(error.InvalidXml, reader.nextRecord());
                const diagnostic = reader.diagnostic().?;
                try std.testing.expectEqual(error.InvalidXml, diagnostic.code);
                try std.testing.expectError(error.FailedState, reader.nextRecord());
                try std.testing.expectEqualDeep(diagnostic, reader.diagnostic().?);
            }
        }
    }
}

test "[failure] - [mzML decoded reading]: stops at the first error and clears failed output" {
    const cases = .{
        .{ "!AAAAAAA8D8=", 12, 1, "MS:1000576", error.InvalidCharacter },
        .{ "!AAAAAAA8D8=", 11, 1, "MS:1000576", error.InvalidCharacter },
        .{ "!AAAAAAA8D8=</broken>", 12, 1, "MS:1000576", error.InvalidCharacter },
        .{ "AAAAAAAA8D8=", 12, 0, "MS:1000576", error.DecodedSizeMismatch },
        .{ "AAAAAAAA8D8=!AAA", 16, 0, "MS:1000576", error.DecodedSizeMismatch },
        .{ "AAAAAAAA8D8", 11, 1, "MS:1000576", error.TruncatedInput },
        .{ "AB==", 4, 0, "MS:1000576", error.NonCanonicalTail },
        .{ "AA=A", 4, 0, "MS:1000576", error.InvalidPadding },
        .{ "AAAAAAAA8D8=", 12, 1, "X:unknown", error.MissingCompression },
    };
    inline for (cases) |case| {
        const source = try decodedDocument(std.testing.allocator, case[0], case[1], case[2], case[3]);
        defer std.testing.allocator.free(source);
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
        defer output.deinit();
        try std.testing.expectError(case[4], reader.nextDecodedRecord(&output));
        try std.testing.expectEqual(@as(usize, 0), output.len());
        try std.testing.expect(reader.diagnostic() != null);
        const diagnostic = reader.diagnostic().?;
        try std.testing.expectEqual(case[4], diagnostic.code);
        try std.testing.expectError(error.FailedState, reader.nextDecodedRecord(&output));
        try std.testing.expectError(error.FailedState, reader.nextRecord());
        try std.testing.expectEqualDeep(diagnostic, reader.diagnostic().?);
    }
    const initial = try decodedDocument(std.testing.allocator, "AAAAAAAA8D8=", 12, 1, "MS:1000574");
    defer std.testing.allocator.free(initial);
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, initial, "encodedLength='0' arrayLength='0'><referenceableParamGroupRef ref='encoding'/><binary/>", "encodedLength='1' arrayLength='0'><referenceableParamGroupRef ref='encoding'/><binary>!</binary>");
    defer std.testing.allocator.free(source);
    try std.testing.expectError(error.InvalidData, readDecoded(std.testing.allocator, source, .{}));
}

test "[failure] - [mzML decoded reading]: bounds storage and releases failed allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecoded, .{ support.DOCUMENT, mzml.StreamReader.DecodedArrays.Limits{} });
    var storage: [32768]u8 = undefined;
    var compressed = std.Io.Writer.fixed(&storage);
    try support.constructFixture(std.testing.allocator, &compressed, false, std.meta.tags(mzml.arrays.Pipeline));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecoded, .{ compressed.buffered(), mzml.StreamReader.DecodedArrays.Limits{} });
    try std.testing.expectError(error.LimitExceeded, readDecoded(std.testing.allocator, support.DOCUMENT, .{ .array_bytes = 7 }));
    const text = "!" ++ "A" ** 70000;
    const source = try decodedDocument(std.testing.allocator, text, text.len, 1, "MS:1000576");
    defer std.testing.allocator.free(source);
    try std.testing.expectError(error.InvalidCharacter, readDecoded(std.testing.allocator, source, .{}));
}

test "[integration] - [mzML decoded reading]: preserves encoded length hints without using them" {
    const cases = .{
        .{ "AAAAAAAA8D8=", "MS:1000576" },
        .{ "eJxjYACBD/YAAicBMA==", "MS:1000574" },
    };
    inline for (cases) |case| {
        const original = try decodedDocument(std.testing.allocator, case[0], 0, 1, case[1]);
        defer std.testing.allocator.free(original);
        for ([_]?[]const u8{ null, "", "0", "1", "12", "20", "1048576", "bad", "-1" }) |hint| {
            const attribute = if (hint) |value|
                try std.fmt.allocPrint(std.testing.allocator, "encodedLength='{s}'", .{value})
            else
                try std.testing.allocator.dupe(u8, "");
            defer std.testing.allocator.free(attribute);
            const source = try std.mem.replaceOwned(u8, std.testing.allocator, original, "encodedLength='0'", attribute);
            defer std.testing.allocator.free(source);
            var input = std.Io.Reader.fixed(source);
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
            defer reader.deinit();
            var backing: [4096]u8 = undefined;
            var allocator = std.heap.FixedBufferAllocator.init(&backing);
            var output = mzml.StreamReader.DecodedArrays.init(allocator.allocator(), .{ .array_bytes = 8 });
            defer output.deinit();

            const record = (try reader.nextDecodedRecord(&output)).?;
            try std.testing.expectEqualDeep(hint, record.binaryArrays()[0].attribute("encodedLength"));
            try std.testing.expectEqualSlices(f64, &.{1}, output.get(0).?.values.float64);
        }
    }
}

test "[integration] - [mzML decoded reading]: grows wire storage across fragments within byte limits" {
    var values: [256]f64 = undefined;
    var random: std.Random.DefaultPrng = .init(0);
    random.random().bytes(std.mem.sliceAsBytes(&values));
    var compressor = try mzml.zlib.Compressor.init(std.testing.allocator, .fast);
    defer compressor.deinit();
    var transport: [4096]u8 = undefined;
    var transformed: [2048]u8 = undefined;
    const wire = try mzml.arrays.encodeWire(f64, &values, .{ .pipeline = .zlib }, .{
        .transport = &transport,
        .transformed = &transformed,
    }, &compressor);
    var text_buffer: [8192]u8 = undefined;
    const text = try mzml.base64.encode(&text_buffer, wire);
    var fragments: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fragments.deinit();
    var position: usize = 0;
    while (position < text.len) {
        const end = @min(position + 13, text.len);
        try fragments.writer.print("<![CDATA[{s}]]>", .{text[position..end]});
        position = end;
    }
    const source = try decodedDocument(std.testing.allocator, fragments.written(), text.len, values.len, "MS:1000574");
    defer std.testing.allocator.free(source);
    try compareDecoded(source, 7);
    const limits: mzml.StreamReader.DecodedArrays.Limits = .{ .array_bytes = @sizeOf(@TypeOf(values)) };
    // EOF can attempt optional arena consolidation, whose allocation failure is recoverable.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecodedRecord, .{ source, limits });
    for ([_]mzml.Diagnostic.Limit{ .array_bytes, .binary_text_bytes }) |name| {
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{
            .limits = .{ .binary_text_bytes = if (name == .binary_text_bytes) text.len - 1 else text.len },
        });
        defer reader.deinit();
        var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{
            .array_bytes = if (name == .array_bytes) limits.array_bytes - 1 else limits.array_bytes,
        });
        defer output.deinit();
        try std.testing.expectError(error.LimitExceeded, reader.nextDecodedRecord(&output));
        try std.testing.expectEqual(name, reader.diagnostic().?.detail.limit.name);
    }
}

test "[failure] - [mzML decoded reading]: does not read beyond a known payload error" {
    const source = try decodedDocument(std.testing.allocator, "!AAAAAAA8D8=", 12, 1, "MS:1000576");
    defer std.testing.allocator.free(source);
    const first_end = std.mem.indexOf(u8, source, "</binary>").? + "</binary>".len;
    var input = std.Io.Reader.failing;
    input.buffer = source;
    input.end = first_end;
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    try std.testing.expectError(error.InvalidCharacter, reader.nextDecodedRecord(&output));
    try std.testing.expect(input.seek < first_end);
    try std.testing.expectEqual(@as(usize, 0), output.len());
    const diagnostic = reader.diagnostic().?;
    try std.testing.expectEqual(error.InvalidCharacter, diagnostic.code);
    try std.testing.expectEqual(.binary, diagnostic.element.?);
    try std.testing.expect(diagnostic.location.?.input_event < first_end);
    const position = input.seek;
    try std.testing.expectError(error.FailedState, reader.nextDecodedRecord(&output));
    try std.testing.expectEqual(position, input.seek);
}

test "[integration] - [mzML decoded reading]: keeps numeric lifetimes independent of ordinary and selected reads" {
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    {
        var input = std.Io.Reader.fixed(support.DOCUMENT);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .payload = .skip });
        defer reader.deinit();
        const record = (try reader.nextDecodedRecord(&output)).?;
        try std.testing.expectEqual(@as(usize, 2), output.len());
        try std.testing.expectEqual(null, record.binaryArrays()[0].child(.binary).?.text);
        const values = output.get(0).?.values.float64;
        try std.testing.expectEqualStrings("tic", (try reader.nextRecord()).?.id);
        try std.testing.expectEqualSlices(f64, &.{1}, values);
    }
    try std.testing.expectEqualSlices(f64, &.{1}, output.get(0).?.values.float64);
    output.reset();
    try std.testing.expectEqual(null, output.get(0));
    {
        var input = std.Io.Reader.fixed(support.DOCUMENT);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .array_selector = .{ .select = selectSecond } });
        defer reader.deinit();
        try std.testing.expectEqualStrings("native=a&b", (try reader.nextDecodedRecord(&output)).?.id);
        try std.testing.expectEqual(@as(usize, 1), output.len());
        try std.testing.expectEqual(@as(usize, 1), output.get(0).?.source_position);
        try std.testing.expectEqualSlices(f64, &.{1}, output.get(0).?.values.float64);
        try std.testing.expectEqual(null, reader.diagnostic());
        try std.testing.expectEqualStrings("tic", (try reader.nextRecord()).?.id);
    }
    for ([_]usize{ 0, support.HEADER.len, support.DOCUMENT.len / 2, support.DOCUMENT.len }) |length| {
        var bytes: [support.DOCUMENT.len]u8 = undefined;
        @memcpy(&bytes, support.DOCUMENT);
        var input = std.Io.Reader.failing;
        input.buffer = &bytes;
        input.end = length;
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        while (reader.nextDecodedRecord(&output)) |_| {} else |err| {
            try std.testing.expectEqual(error.ReadFailed, err);
            try std.testing.expectEqual(@as(usize, 0), output.len());
            try std.testing.expectError(error.FailedState, reader.nextDecodedRecord(&output));
            continue;
        }
        return error.TestUnexpectedResult;
    }
}

test "[unit] - [package API]: exposes mzML through one namespace" {
    try std.testing.expect(@hasDecl(zmz, "mzml"));
    try std.testing.expect(!@hasDecl(zmz, "StreamReader"));
    try std.testing.expect(!@hasDecl(zmz, "Writer"));
    try std.testing.expect(!@hasDecl(mzml, "Validator"));
    try std.testing.expect(!@hasDecl(mzml.Writer, "enableValidation"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "Scope"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "parseFragment"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "readFragment"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "parseFooter"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "resumeFollowingList"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "finishEmptySpectrumList"));
    try std.testing.expect(@hasDecl(mzml.StreamReader, "indexTrailer"));
    try std.testing.expect(!@hasDecl(mzml.owned, "Copier"));
    try std.testing.expect(@hasDecl(mzml.arrays, "Pipeline"));
    try std.testing.expect(@hasDecl(mzml.cv, "Resolver"));
}

test "[regression] - [mzML array decoding]: reads empty producer arrays with zlib declarations" {
    const array = "<binaryDataArray encodedLength='0' arrayLength='0'><cvParam cvRef='MS' accession='MS:1000523' name='64-bit float'/>" ++
        "<cvParam cvRef='MS' accession='MS:1000574' name='zlib compression'/><binary> \t\r\n</binary></binaryDataArray>";
    const source = support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'><spectrum id='scan=1' index='0' defaultArrayLength='0'>" ++
        "<binaryDataArrayList count='2'>" ++ array ++ array ++ "</binaryDataArrayList></spectrum></spectrumList></run></mzML>";
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const record = (try reader.nextRecord()).?;
    var scratch: [32]u8 = undefined;
    const node = record.binaryArrays()[0];
    try mzml.model.decodeArray(f64, &.{}, node, 5, &.{}, .{ .transport = &scratch, .transformed = &.{} });
    var typed_arrays = record.arrays(&.{});
    const typed_array = (try typed_arrays.next()).?;
    try typed_array.decode(f64, &.{}, .{ .transport = &scratch, .transformed = &.{} });
    var one: [1]f64 = undefined;
    var nonempty = node;
    nonempty.attributes = &.{.{ .name = "encodedLength", .value = "0" }};
    try std.testing.expectError(error.TruncatedInput, mzml.model.decodeArray(f64, &one, nonempty, 1, &.{}, .{ .transport = &scratch, .transformed = &.{} }));
    try std.testing.expectError(error.TruncatedInput, mzml.zlib.decompress(&scratch, ""));
    try std.testing.expectEqual(null, try reader.nextRecord());
}

test "[regression] - [mzML reader]: oversized count hints do not exhaust bounded storage" {
    const source = support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'>" ++
        "<spectrum id='x' index='0' defaultArrayLength='0'><scanList count='1'><scan/></scanList></spectrum>" ++
        "</spectrumList></run></mzML>";
    const backing = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(backing);
    for ([_][]const u8{ "cvList", "scanList" }) |name| {
        const before = try std.fmt.allocPrint(std.testing.allocator, "<{s} count='1'>", .{name});
        defer std.testing.allocator.free(before);
        for ([_][]const u8{ "0", "100000", "bad", "18446744073709551616" }) |count| {
            const after = try std.fmt.allocPrint(std.testing.allocator, "<{s} count='{s}'>", .{ name, count });
            defer std.testing.allocator.free(after);
            const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, before, after);
            defer std.testing.allocator.free(changed);
            var fixed = std.heap.FixedBufferAllocator.init(backing);
            var input = std.Io.Reader.fixed(changed);
            var reader = try mzml.StreamReader.init(fixed.allocator(), &input, .{
                .limits = .{ .header_bytes = 8192, .record_bytes = 1024, .list_entries = 8 },
            });
            defer reader.deinit();
            const record = (try reader.nextRecord()).?;
            const node = if (std.mem.eql(u8, name, "cvList"))
                (try reader.readHeader()).document.child(.cv_list).?
            else
                record.node.child(.scan_list).?;
            try std.testing.expectEqual(@as(usize, 1), node.children.len);
            try std.testing.expectEqualStrings(count, node.attribute("count").?);
            try std.testing.expectEqual(null, try reader.nextRecord());
        }
    }
}

test "[property] - [mzML binary text]: retains or skips text without interpreting encoded length" {
    var buffer: [8192]u8 = undefined;
    var text: [257]u8 = undefined;
    const alphabet = "A =+/!\t\n";
    for ([_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 257 }) |length| {
        for (text[0..length], 0..) |*byte, i| byte.* = alphabet[i % alphabet.len];
        var source = std.Io.Writer.fixed(&buffer);
        try source.writeAll(support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'><spectrum id='scan=1' index='0' defaultArrayLength='0'><binaryDataArrayList count='2'>");
        for (0..2) |_| {
            try source.print("<binaryDataArray encodedLength='unused'><binary><![CDATA[{s}]]></binary></binaryDataArray>", .{text[0..length]});
        }
        try source.writeAll("</binaryDataArrayList></spectrum></spectrumList></run></mzML>");
        for ([_]mzml.StreamReader.Payload{ .retain, .skip }) |payload| {
            var input = std.Io.Reader.fixed(source.buffered());
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .payload = payload });
            defer reader.deinit();
            const record = (try reader.nextRecord()).?;
            try std.testing.expectEqual(@as(usize, 2), record.binaryArrays().len);
            for (record.binaryArrays()) |array| {
                try std.testing.expectEqualStrings("unused", array.attribute("encodedLength").?);
                try std.testing.expectEqualDeep(if (payload == .retain) @as(?[]const u8, text[0..length]) else null, array.child(.binary).?.text);
            }
            try std.testing.expectEqual(null, try reader.nextRecord());
        }
    }
}

test "[integration] - [mzML reader]: reuses storage across growing and shrinking fragmented records" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    const lengths = [_]usize{ 1, 512, 0, 16, 1 };
    try source.writer.writeAll(support.HEADER ++ "<spectrumList count='5' defaultDataProcessingRef='dp'>");
    var zeros: [4096]u8 = @splat(0);
    var encoded: [5464]u8 = undefined;
    for (lengths, 0..) |length, index| {
        const text = try mzml.base64.encode(&encoded, zeros[0 .. length * 8]);
        try source.writer.print("<spectrum index='{d}' id='scan={d}' defaultArrayLength='{d}'><binaryDataArrayList count='2'>", .{ index, index, length });
        for (0..2) |_| {
            try source.writer.print("<binaryDataArray encodedLength='{d}'><referenceableParamGroupRef ref='encoding'/><binary>", .{text.len});
            const split = @min(37, text.len);
            try source.writer.writeAll(text[0..split]);
            try source.writer.writeAll("<![CDATA[");
            try source.writer.writeAll(text[split..]);
            try source.writer.writeAll("]]></binary></binaryDataArray>");
        }
        try source.writer.writeAll("</binaryDataArrayList></spectrum>");
    }
    try source.writer.writeAll("</spectrumList></run></mzML>");
    var input = std.Io.Reader.fixed(source.written());
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var transport: [4096]u8 = undefined;
    var output: [512]f64 = undefined;
    for (lengths, 0..) |length, index| {
        const record = (try reader.nextRecord()).?;
        try std.testing.expectEqual(index, record.index);
        try std.testing.expectEqual(length, record.default_array_length);
        try std.testing.expectEqual(@as(usize, 2), record.binaryArrays().len);
        for (record.binaryArrays()) |array| {
            const text = try mzml.base64.encode(&encoded, zeros[0 .. length * 8]);
            try std.testing.expectEqualStrings(text, array.child(.binary).?.text.?);
            try mzml.model.decodeArray(f64, output[0..length], array, length, header.groups, .{ .transport = &transport, .transformed = &.{} });
            try std.testing.expectEqualSlices(u8, zeros[0 .. length * 8], std.mem.sliceAsBytes(output[0..length]));
        }
    }
    try std.testing.expectEqual(null, try reader.nextRecord());
    try compareDecoded(source.written(), 7);
}

test "[integration] - [mzML children]: reads present metadata without schema order or minimum counts" {
    const header = "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.1.0'>" ++
        "<userParam name='document-first'/>" ++
        "<instrumentConfigurationList><instrumentConfiguration><softwareRef ref='sw'/>" ++
        "<componentList><analyzer order='3'/><userParam name='components'/><source order='1'/><analyzer order='2'/></componentList>" ++
        "<userParam name='instrument'/></instrumentConfiguration></instrumentConfigurationList>" ++
        "<referenceableParamGroupList><referenceableParamGroup id='encoding'>" ++
        "<cvParam accession='MS:1000523'/><cvParam accession='MS:1000576'/>" ++
        "</referenceableParamGroup></referenceableParamGroupList><userParam name='document-last'/><run>";
    const source = header ++ "<spectrumList count='1'><spectrum id='s' index='0' defaultArrayLength='1'>" ++
        support.ARRAYS ++ "<productList/><precursorList><precursor><selectedIonList/></precursor></precursorList>" ++
        "<scanList><scan><scanWindowList/></scan><scan/></scanList></spectrum></spectrumList>" ++
        "<chromatogramList count='1'><chromatogram id='c' index='0' defaultArrayLength='0'/>" ++
        "</chromatogramList></run></mzML>";
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const document = (try reader.readHeader()).document;
    try std.testing.expectEqualDeep(&[_]mzml.cv.Entry{
        .{ .user = .{ .name = "document-first" } }, .{ .user = .{ .name = "document-last" } },
    }, document.params);
    const instrument = document.child(.instrument_configuration_list).?.children[0];
    try std.testing.expectEqualStrings("instrument", instrument.params[0].user.name.?);
    try std.testing.expectEqual(.software_ref, instrument.children[0].kind);
    try std.testing.expectEqualStrings("components", instrument.child(.component_list).?.params[0].user.name.?);
    const components = instrument.child(.component_list).?.children;
    try std.testing.expectEqual(@as(usize, 3), components.len);
    for ([_]mzml.model.Kind{ .analyzer, .source, .analyzer }, components) |kind, node|
        try std.testing.expectEqual(kind, node.kind);
    const record = (try reader.nextRecord()).?;
    try std.testing.expectEqual(@as(usize, 4), record.node.children.len);
    try std.testing.expectEqual(.binary_data_array_list, record.node.children[0].kind);
    try std.testing.expectEqual(@as(usize, 2), record.binaryArrays().len);
    try std.testing.expectEqual(@as(usize, 2), record.scans().len);
    try std.testing.expectEqual(@as(usize, 0), record.products().len);
    try std.testing.expectEqual(@as(usize, 0), (try record.precursors()[0].selectedIons()).len);
    const chrom = (try reader.nextRecord()).?;
    try std.testing.expectEqual(@as(usize, 0), chrom.binaryArrays().len);
    try std.testing.expectEqual(null, try reader.nextRecord());
    try compareDecoded(source, 1);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild });
    defer index.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    var fetched = (try index.atDecoded(std.testing.allocator, .spectrum, 0, &output)).?;
    defer fetched.deinit();
    try std.testing.expectEqual(@as(usize, 2), fetched.value.scans().len);
    try std.testing.expectEqual(@as(usize, 2), output.len());
    for (0..output.len()) |i| try std.testing.expectEqualSlices(f64, &.{1}, output.get(i).?.values.float64);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecodedRecord, .{ source, mzml.StreamReader.DecodedArrays.Limits{} });
}

test "[integration] - [mzML children]: distinguishes missing payloads from repeated payloads" {
    const prefix = support.HEADER ++ "<spectrumList count='1'><spectrum id='s' index='0' defaultArrayLength='1'>";
    const suffix = "</spectrum></spectrumList></run></mzML>";
    inline for (.{ "", "<binary>AAAAAAAA8D8=</binary>" }) |binary| {
        const source = prefix ++ "<binaryDataArrayList><binaryDataArray><referenceableParamGroupRef ref='encoding'/>" ++
            binary ++ "</binaryDataArray></binaryDataArrayList>" ++ suffix;
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const record = (try reader.nextRecord()).?;
        try std.testing.expectEqual(@as(usize, 1), record.binaryArrays().len);
        var values: [1]f64 = undefined;
        var transport: [8]u8 = undefined;
        const result = mzml.model.decodeArray(f64, &values, record.binaryArrays()[0], 1, (try reader.readHeader()).groups, .{ .transport = &transport, .transformed = &.{} });
        if (binary.len == 0) {
            try std.testing.expectError(error.PayloadNotRetained, result);
            try std.testing.expectError(error.PayloadNotRetained, readDecoded(std.testing.allocator, source, .{}));
        } else {
            try result;
            try std.testing.expectEqual(@as(f64, 1), values[0]);
            try compareDecoded(source, 1);
        }
    }
    inline for (.{
        "<scanList/><scanList/>",
        "<precursorList/><precursorList/>",
        "<binaryDataArrayList/><binaryDataArrayList/>",
        "<precursorList><precursor><selectedIonList/><selectedIonList/></precursor></precursorList>",
    }) |body| {
        const source = prefix ++ body ++ suffix;
        try compareDecoded(source, 1);
    }
    const ambiguous = prefix ++ "<binaryDataArrayList><binaryDataArray><referenceableParamGroupRef ref='encoding'/>" ++
        "<binary>AAAAAAAA8D8=</binary><binary/></binaryDataArray></binaryDataArrayList>" ++ suffix;
    try std.testing.expectError(error.InvalidStructure, support.readAll(std.testing.allocator, ambiguous, .{}));
    try std.testing.expectError(error.InvalidStructure, readDecoded(std.testing.allocator, ambiguous, .{}));
    try std.testing.expectError(error.InvalidStructure, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = ambiguous }, .{ .policy = .rebuild }));
}

test "[integration] - [mzML header]: preserves present sections without requiring schema order" {
    const group = "<referenceableParamGroupList><referenceableParamGroup id='encoding'>" ++
        "<cvParam accession='MS:1000523'/><cvParam accession='MS:1000576'/>" ++
        "</referenceableParamGroup></referenceableParamGroupList>";
    const software = "<softwareList><software id='sw'/></softwareList>";
    inline for (.{
        .{ group, &[_]mzml.model.Kind{.referenceable_param_group_list} },
        .{ software ++ group, &[_]mzml.model.Kind{ .software_list, .referenceable_param_group_list } },
    }) |case| {
        const source = "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.1.0'>" ++ case[0] ++
            "<run><spectrumList count='1'>" ++ support.SPECTRUM ++ "</spectrumList></run></mzML>";
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const header = try reader.readHeader();
        try std.testing.expectEqual(null, header.document.child(.cv_list));
        try std.testing.expectEqual(case[1].len, header.document.children.len);
        for (case[1], header.document.children) |expected, node| try std.testing.expectEqual(expected, node.kind);
        try std.testing.expectEqualStrings("encoding", header.groups[0].id);
        try std.testing.expectEqual(@as(usize, 2), header.groups[0].entries.len);
        const record = (try reader.nextRecord()).?;
        try std.testing.expectEqualStrings("native=a&b", record.id);
        try std.testing.expectEqual(@as(usize, 2), record.binaryArrays().len);
        try std.testing.expectEqual(null, try reader.nextRecord());
        try compareDecoded(source, 1);
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild });
        defer index.deinit();
        var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
        defer output.deinit();
        var fetched = (try index.atDecoded(std.testing.allocator, .spectrum, 0, &output)).?;
        defer fetched.deinit();
        try std.testing.expectEqualStrings("native=a&b", fetched.value.id);
        try std.testing.expectEqual(@as(usize, 2), output.len());
        for (0..output.len()) |i| try std.testing.expectEqualSlices(f64, &.{1}, output.get(i).?.values.float64);
        try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecodedRecord, .{ source, mzml.StreamReader.DecodedArrays.Limits{} });
    }
    const opening = "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.1.0'>";
    try support.readAll(std.testing.allocator, opening ++ group ++ group ++ "<run/></mzML>", .{});
    try std.testing.expectError(error.InvalidStructure, support.readAll(std.testing.allocator, opening ++ software ++ "</mzML>", .{}));
}

test "[integration] - [mzML lists]: reads absent and empty lists without requiring records" {
    const Case = struct { xml: []const u8, spectra: ?usize = null, chromatograms: ?usize = null };
    inline for ([_]Case{
        .{ .xml = "" },
        .{ .xml = "<spectrumList count='0'/>", .spectra = 0 },
        .{ .xml = "<chromatogramList count='0'/>", .chromatograms = 0 },
        .{ .xml = "<spectrumList count='8'/><chromatogramList count='3'/>", .spectra = 8, .chromatograms = 3 },
    }) |case| {
        const source = support.HEADER ++ case.xml ++ "</run></mzML>";
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const header = try reader.readHeader();
        try std.testing.expectEqual(null, try reader.nextRecord());
        try std.testing.expectEqual(case.spectra != null, header.spectrum_list != null);
        try std.testing.expectEqual(case.chromatograms != null, header.chromatogram_list != null);
        if (header.spectrum_list) |list| {
            try std.testing.expectEqual(case.spectra.?, list.declared_count);
            try std.testing.expectEqual(@as(usize, 0), list.observed_count);
        }
        if (header.chromatogram_list) |list| {
            try std.testing.expectEqual(case.chromatograms.?, list.declared_count);
            try std.testing.expectEqual(@as(usize, 0), list.observed_count);
        }
        try readDecoded(std.testing.allocator, source, .{});
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild });
        defer index.deinit();
        try std.testing.expectEqual(@as(usize, 0), index.entries.items.len);
        try std.testing.expectEqual(null, try index.at(std.testing.allocator, .chromatogram, 0));
    }
    const prefix = "<indexedmzML xmlns='http://psi.hupo.org/ms/mzml'><mzML version='1.1.0'>" ++
        "<run><chromatogramList count='0'/></run></mzML>";
    var buffer: [512]u8 = undefined;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    for ([_][]const u8{
        "<indexList/>",
        "<indexList count='0'></indexList>",
        "<indexList><index name='chromatogram'/></indexList>",
    }) |trailer| {
        const indexed = try std.fmt.bufPrint(&buffer, prefix ++ "{s}" ++
            "<indexListOffset>{d}</indexListOffset><fileChecksum/></indexedmzML>", .{ trailer, prefix.len });
        try support.readAll(std.testing.allocator, indexed, .{ .retain_index = true });
        const file = try directory.dir.createFile(std.testing.io, "empty.mzML", .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, indexed);
        for ([_]mzml.IndexedReader.Source{ .{ .bytes = indexed }, .{ .file = .{ .handle = file, .io = std.testing.io } } }) |source| {
            for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
                var index = try mzml.IndexedReader.build(std.testing.allocator, source, .{ .policy = policy, .max_records = 0 });
                defer index.deinit();
                try std.testing.expectEqual(@as(usize, 0), index.entries.items.len);
                try std.testing.expectEqualDeep([_]usize{ 0, 0 }, index.counts);
                try std.testing.expectEqual(@as(usize, 0), index.header().chromatogram_list.?.declared_count);
                try std.testing.expectEqual(null, try index.byId(std.testing.allocator, "missing"));
                try std.testing.expectEqual(null, try index.at(std.testing.allocator, .spectrum, 0));
                try std.testing.expectEqual(null, try index.at(std.testing.allocator, .chromatogram, 0));
                var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
                defer output.deinit();
                try std.testing.expectEqual(null, try index.byIdDecoded(std.testing.allocator, "missing", &output));
                try std.testing.expectEqual(null, try index.atDecoded(std.testing.allocator, .chromatogram, 0, &output));
                try std.testing.expectEqual(@as(usize, 0), output.len());
            }
        }
    }
}

test "[integration] - [mzML attributes]: preserves extras without requiring unused fields" {
    const source = "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.1.0' extra='document'>" ++
        "<cvList><cv/></cvList><fileDescription><fileContent/><sourceFileList><sourceFile/></sourceFileList></fileDescription>" ++
        "<referenceableParamGroupList><referenceableParamGroup id='encoding'>" ++
        "<cvParam accession='MS:1000523'/><cvParam accession='MS:1000576'/></referenceableParamGroup></referenceableParamGroupList>" ++
        "<sampleList><sample/></sampleList><softwareList><software/></softwareList>" ++
        "<scanSettingsList><scanSettings><sourceFileRefList><sourceFileRef/></sourceFileRefList><targetList><target/></targetList></scanSettings></scanSettingsList>" ++
        "<instrumentConfigurationList><instrumentConfiguration><componentList><source/><analyzer/><detector/></componentList><softwareRef/></instrumentConfiguration></instrumentConfigurationList>" ++
        "<dataProcessingList><dataProcessing><processingMethod/></dataProcessing></dataProcessingList>" ++
        "<run extra='run'><spectrumList count='1'><spectrum id='x' index='0' defaultArrayLength='1' extra='record'>" ++
        "<scanList extra='scans'><scan/></scanList>" ++ support.ARRAYS ++ "</spectrum></spectrumList></run></mzML>";
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    try std.testing.expectEqualStrings("document", header.document.attribute("extra").?);
    try std.testing.expectEqualStrings("run", header.run.attribute("extra").?);
    try std.testing.expectEqual(null, header.run.attribute("id"));
    const cv_list = header.document.child(.cv_list).?;
    try std.testing.expectEqual(null, try cv_list.declaredCount());
    try std.testing.expectEqual(@as(usize, 0), cv_list.children[0].attributes.len);
    const record = (try reader.nextRecord()).?;
    try std.testing.expectEqualStrings("record", record.node.attribute("extra").?);
    try std.testing.expectEqualStrings("scans", record.node.child(.scan_list).?.attribute("extra").?);
    try std.testing.expectEqual(null, try record.node.child(.scan_list).?.declaredCount());
    try std.testing.expectEqual(@as(usize, 2), record.binaryArrays().len);
    try std.testing.expectEqual(null, try reader.nextRecord());
    try compareDecoded(source, 1);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild });
    defer index.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    var fetched = (try index.atDecoded(std.testing.allocator, .spectrum, 0, &output)).?;
    defer fetched.deinit();
    try std.testing.expectEqualStrings("record", fetched.value.node.attribute("extra").?);
    try std.testing.expectEqualStrings("scans", fetched.value.node.child(.scan_list).?.attribute("extra").?);
    try std.testing.expectEqual(@as(usize, 2), output.len());
    for (0..output.len()) |i| try std.testing.expectEqualSlices(f64, &.{1}, output.get(i).?.values.float64);
}

test "[integration] - [mzML numeric attributes]: retains absent source numbers without inventing values" {
    inline for (.{ "index='0'", "defaultArrayLength='1'", "count='1'" }) |removed| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, removed, "");
        defer std.testing.allocator.free(source);
        for ([_]mzml.StreamReader.Payload{ .retain, .skip }) |payload| {
            var input = std.Io.Reader.fixed(source);
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .payload = payload });
            defer reader.deinit();
            const header = try reader.readHeader();
            var records: usize = 0;
            while (try reader.nextItem()) |item| switch (item) {
                .list_start => |start| {
                    try std.testing.expectEqual(if (std.mem.startsWith(u8, removed, "count")) @as(?usize, null) else 1, start.list.declared_count);
                    try std.testing.expectEqual(@as(usize, 0), start.list.observed_count);
                },
                .record => |record| {
                    try std.testing.expectEqual(if (std.mem.startsWith(u8, removed, "index")) @as(?usize, null) else 0, record.index);
                    try std.testing.expectEqual(if (std.mem.startsWith(u8, removed, "default")) @as(?usize, null) else 1, record.default_array_length);
                    var retained = try mzml.owned.Record.init(std.testing.allocator, record, .{});
                    defer retained.deinit();
                    try std.testing.expectEqualDeep(record, retained.value);
                    records += 1;
                },
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 2), records);
            try std.testing.expectEqual(@as(usize, 1), header.spectrum_list.?.observed_count);
            try std.testing.expectEqual(@as(usize, 1), header.chromatogram_list.?.observed_count);
            var retained = try mzml.owned.Header.init(std.testing.allocator, header.*, .{});
            defer retained.deinit();
            try std.testing.expectEqualDeep(header.*, retained.value);
        }
    }
}

test "[integration] - [mzML numeric attributes]: requires a length only for requested arrays" {
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "defaultArrayLength='1'", "");
    defer std.testing.allocator.free(source);
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    while (try reader.nextRecord()) |record| {
        var descriptors = record.arrays(header.groups);
        try std.testing.expectError(error.MissingValue, descriptors.next());
        try std.testing.expectError(error.MissingValue, descriptors.next());
        var value: [1]f64 = undefined;
        const nodes = record.binaryArrays();
        try std.testing.expectError(error.MissingValue, mzml.model.decodeArray(f64, &value, nodes[0], record.default_array_length, header.groups, .{ .transport = &.{}, .transformed = &.{} }));
        try mzml.model.decodeArray(f64, &value, nodes[1], record.default_array_length, header.groups, .{ .transport = &.{}, .transformed = &.{} });
        try std.testing.expectEqualSlices(f64, &.{1}, &value);
    }
    try std.testing.expectError(error.MissingValue, readDecoded(std.testing.allocator, source, .{}));
    try readSelectedDecoded(std.testing.allocator, source);
    var selection: Selection = .{ .mode = .none };
    var skipped_input = std.Io.Reader.fixed(source);
    var skipped = try mzml.StreamReader.init(std.testing.allocator, &skipped_input, .{
        .array_selector = .{ .user_data = &selection, .select = Selection.select },
    });
    defer skipped.deinit();
    var decoded = mzml.StreamReader.DecodedArrays.init(std.testing.failing_allocator, .{});
    defer decoded.deinit();
    var records: usize = 0;
    while (try skipped.nextDecodedRecord(&decoded)) |_| {
        try std.testing.expectEqual(@as(usize, 0), decoded.len());
        records += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), records);
    const explicit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "<binaryDataArray encodedLength='12'>", "<binaryDataArray encodedLength='12' arrayLength='1'>");
    defer std.testing.allocator.free(explicit);
    try compareDecoded(explicit, 1);
    inline for (.{ "", " index='0' defaultArrayLength='0'" }) |attributes| {
        const empty = support.HEADER ++ "<spectrumList><spectrum id='empty'" ++ attributes ++ "/></spectrumList></run></mzML>";
        var empty_input = std.Io.Reader.fixed(empty);
        var empty_reader = try mzml.StreamReader.init(std.testing.allocator, &empty_input, .{});
        defer empty_reader.deinit();
        const record = (try empty_reader.nextDecodedRecord(&decoded)).?;
        try std.testing.expectEqual(if (attributes.len == 0) @as(?usize, null) else 0, record.index);
        try std.testing.expectEqual(if (attributes.len == 0) @as(?usize, null) else 0, record.default_array_length);
        try std.testing.expectEqual(@as(usize, 0), decoded.len());
        try std.testing.expectEqual(null, try empty_reader.nextDecodedRecord(&decoded));
    }
}

test "[failure] - [mzML attributes]: requires identifiers and requested groups" {
    for ([_][]const u8{ "id='encoding'", "id='native=a&amp;b'" }) |attribute| {
        const removed = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, attribute, "");
        defer std.testing.allocator.free(removed);
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, removed, "<binary>AAAA", "<binary>&missing;AAA");
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.MissingAttribute, support.readAll(std.testing.allocator, source, .{}));
        try std.testing.expectError(error.MissingAttribute, readDecoded(std.testing.allocator, source, .{}));
        try std.testing.expectError(error.MissingAttribute, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild }));
    }
    const incomplete = support.HEADER ++ "<spectrumList><broken";
    try std.testing.expectError(error.InvalidXml, support.readAll(std.testing.allocator, incomplete, .{}));
    const unexpected_start = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "<referenceableParamGroup id='encoding'>", "<sourceFile>");
    defer std.testing.allocator.free(unexpected_start);
    const unexpected_group = try std.mem.replaceOwned(u8, std.testing.allocator, unexpected_start, "</referenceableParamGroup>", "</sourceFile>");
    defer std.testing.allocator.free(unexpected_group);
    try support.readAll(std.testing.allocator, unexpected_group, .{});
    try std.testing.expectError(error.MissingGroup, readDecoded(std.testing.allocator, unexpected_group, .{}));
}

test "[integration] - [mzML numeric attributes]: reads source text and checks numbers when used" {
    const cases = .{ "word", "1_0", "-1" };
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    inline for (cases) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "order='0'", "order='" ++ case ++ "'");
        defer std.testing.allocator.free(source);
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const method = (try reader.readHeader()).document.child(.data_processing_list).?.children[0].children[0];
        try std.testing.expectEqualStrings(case, method.attribute("order").?);
        while (try reader.nextRecord()) |_| {}
        try support.expectNode(method, try builder.node(method));
    }
    inline for (.{ "2147483648", "-2147483649", "1.5" }) |value| {
        const components = "<instrumentConfiguration id='ic'><componentList count='3'>" ++
            "<source order='" ++ value ++ "'/><analyzer order='1'/><detector order='2'/>" ++
            "</componentList></instrumentConfiguration>";
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "<instrumentConfiguration id='ic'/>", components);
        defer std.testing.allocator.free(source);
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const component = (try reader.readHeader()).document.child(.instrument_configuration_list).?.children[0].child(.component_list).?.children[0];
        try std.testing.expectEqualStrings(value, component.attribute("order").?);
        while (try reader.nextRecord()) |_| {}
        try support.expectNode(component, try builder.node(component));
    }
    inline for (.{ "-2147483648", "-1", "-0", "+2147483647" }) |value| {
        _ = try builder.node(.{ .kind = .source, .attributes = &.{.{ .name = "order", .value = value }} });
    }
    inline for (.{
        .{ "defaultArrayLength='1'", "defaultArrayLength='2147483648'" },
        .{ "<scanWindowList count='1'>", "<scanWindowList count='2147483648'>" },
    }) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, case[0], case[1]);
        defer std.testing.allocator.free(source);
        try support.readAll(std.testing.allocator, source, .{
            .limits = .{ .list_entries = std.math.maxInt(usize), .header_bytes = 8192, .record_bytes = 8192 },
        });
    }
    const large = try builder.record(.spectrum, "scan=1", 0, 2147483648, &.{}, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 2147483648), large.default_array_length);

    const record_cases = [_]struct { length: []const u8, index: []const u8, read_error: ?mzml.cv.ValueError }{
        .{ .length = "2147483648", .index = "bad", .read_error = error.InvalidValue },
        .{ .length = "-1", .index = "bad", .read_error = error.InvalidValue },
        .{ .length = "-1", .index = "0", .read_error = error.Overflow },
        .{ .length = "2147483648", .index = "0", .read_error = null },
        .{ .length = " +2147483647 ", .index = "0", .read_error = null },
    };
    for (record_cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, support.HEADER ++
            "<spectrumList count='1' defaultDataProcessingRef='dp'><spectrum id='scan=1' index='{s}' defaultArrayLength='{s}'/></spectrumList></run></mzML>", .{ case.index, case.length });
        defer std.testing.allocator.free(source);
        const node: mzml.model.Node = .{ .kind = .spectrum, .attributes = &.{
            .{ .name = "id", .value = "scan=1" },
            .{ .name = "index", .value = case.index },
            .{ .name = "defaultArrayLength", .value = case.length },
        } };
        if (case.read_error) |failure| {
            try std.testing.expectError(failure, support.readAll(std.testing.allocator, source, .{}));
        } else {
            var input = std.Io.Reader.fixed(source);
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
            defer reader.deinit();
            const record = (try reader.nextRecord()).?;
            try std.testing.expectEqual(try mzml.cv.parseInteger(usize, case.length), record.default_array_length);
            try std.testing.expectEqualStrings(case.length, record.node.attribute("defaultArrayLength").?);
        }
        try support.expectNode(node, try builder.node(node));
    }
    const bad_length = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "arrayLength='1'", "arrayLength='bad'");
    defer std.testing.allocator.free(bad_length);
    var input = std.Io.Reader.fixed(bad_length);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const record = (try reader.nextRecord()).?;
    try std.testing.expectEqualStrings("bad", record.binaryArrays()[1].attribute("arrayLength").?);
    var descriptors = record.arrays(header.groups);
    _ = try descriptors.next();
    try std.testing.expectError(error.InvalidValue, descriptors.next());
    try std.testing.expectError(error.InvalidValue, readDecoded(std.testing.allocator, bad_length, .{}));
}

test "[integration] - [mzML chunks]: retains values across short reads and UTF-16 code units" {
    var buffer: [31]u8 = undefined;
    inline for (.{ 1, 7, 31 }) |size| {
        var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = support.DOCUMENT }});
        input.artificial_limit = .limited(size);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input.interface, .{});
        defer reader.deinit();
        const record = (try reader.nextRecord()).?;
        try std.testing.expectEqualStrings("native=a&b", record.id);
        try std.testing.expectEqualStrings("AAAAAAAA8D8=", record.binaryArrays()[0].child(.binary).?.text.?);
        while (try reader.nextRecord()) |_| {}
    }
    var utf16: [support.DOCUMENT.len * 2 + 2]u8 = undefined;
    inline for (.{ std.builtin.Endian.little, .big }) |endian| {
        std.mem.writeInt(u16, utf16[0..2], 0xfeff, endian);
        for (support.DOCUMENT, 0..) |byte, index| std.mem.writeInt(u16, utf16[2 + index * 2 ..][0..2], byte, endian);
        var input: std.testing.Reader = .init(buffer[0..7], &.{.{ .buffer = &utf16 }});
        input.artificial_limit = .limited(7);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input.interface, .{});
        defer reader.deinit();
        const record = (try reader.nextRecord()).?;
        const expected_offset = 2 + 2 * std.mem.indexOf(u8, support.DOCUMENT, "<spectrum id").?;
        try std.testing.expectEqual(@as(u64, expected_offset), record.node.start_offset);
        try std.testing.expectEqualStrings("native=a&b", record.id);
        while (try reader.nextRecord()) |_| {}
    }
}

test "[integration] - [mzML reader]: decodes Latin-1 metadata without changing physical offsets or numeric arrays" {
    const source = "<?xml version='1.0' encoding='iSo-8859-1'?>" ++ support.HEADER ++
        "<spectrumList count='1' defaultDataProcessingRef='dp'>" ++
        "<spectrum id='scan=\xe9' index='0' defaultArrayLength='1'>" ++
        "<userParam name='\xb5' value='\xff&#x20AC;'/><scanList count='1'><scan spectrumRef='scan=\xe9'/></scanList>" ++
        support.ARRAYS ++ "</spectrum></spectrumList></run></mzML>";
    var buffer: [4096]u8 = undefined;
    for ([_]usize{ 1, 7, buffer.len }) |size| {
        for ([_]bool{ false, true }) |numeric| {
            var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = source }});
            input.artificial_limit = .limited(size);
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input.interface, .{});
            defer reader.deinit();
            var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
            defer output.deinit();
            const record = (if (numeric) try reader.nextDecodedRecord(&output) else try reader.nextRecord()).?;
            try std.testing.expectEqualStrings("scan=\xc3\xa9", record.id);
            try std.testing.expectEqualStrings("\xc2\xb5", record.node.params[0].user.name.?);
            try std.testing.expectEqualStrings("\xc3\xbf\xe2\x82\xac", record.node.params[0].user.value.?);
            try std.testing.expectEqualStrings(record.id, record.node.child(.scan_list).?.children[0].attribute("spectrumRef").?);
            try std.testing.expectEqual(@as(u64, std.mem.indexOf(u8, source, "<spectrum id").?), record.node.start_offset);
            if (numeric) {
                try std.testing.expectEqual(@as(usize, 2), output.len());
                try std.testing.expectEqualSlices(f64, &.{1}, output.get(0).?.values.float64);
            } else {
                try std.testing.expectEqualStrings("AAAAAAAA8D8=", record.binaryArrays()[0].child(.binary).?.text.?);
            }
            try std.testing.expectEqual(null, try reader.nextRecord());
        }
    }
}

test "[integration] - [mzML reader]: retains hierarchy parameters and decodes grouped arrays" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();

    const header = try reader.readHeader();
    try std.testing.expectEqualStrings("example", header.document.attribute("id").?);
    const param = header.document.child(.file_description).?.child(.file_content).?.params[0].cv;
    try std.testing.expectEqualStrings("A&B", param.name.?);
    try std.testing.expectEqualStrings("", param.value.?);
    try std.testing.expectEqualStrings("", header.document.child(.cv_list).?.children[0].attribute("version").?);
    const spectrum = (try reader.nextRecord()).?;
    try std.testing.expectEqualStrings("native=a&b", spectrum.id);
    try std.testing.expectEqual(@as(usize, 2), spectrum.binaryArrays().len);
    try std.testing.expectEqual(@as(u64, std.mem.indexOf(u8, support.DOCUMENT, "<spectrum id").?), spectrum.node.start_offset);
    try std.testing.expectEqual(@as(usize, 1), spectrum.node.child(.scan_list).?.children.len);
    const precursor = spectrum.node.child(.precursor_list).?.children[0];
    try std.testing.expectEqualStrings("earlier", precursor.attribute("spectrumRef").?);
    try std.testing.expectEqualStrings("", precursor.child(.selected_ion_list).?.children[0].params[0].user.value.?);
    try std.testing.expect(spectrum.node.child(.product_list).?.children[0].child(.isolation_window) != null);
    var values: [1]f64 = undefined;
    var transport: [32]u8 = undefined;
    var transformed: [32]u8 = undefined;
    try mzml.model.decodeArray(f64, &values, spectrum.binaryArrays()[0], 1, header.groups, .{
        .transport = &transport,
        .transformed = &transformed,
    });
    try std.testing.expectEqual(@as(f64, 1), values[0]);
    try mzml.model.decodeArray(f64, &values, spectrum.binaryArrays()[1], 2, header.groups, .{
        .transport = &transport,
        .transformed = &transformed,
    });
    try std.testing.expectEqual(@as(f64, 1), values[0]);
    try std.testing.expectError(error.DecodedSizeMismatch, mzml.model.decodeArray(
        f64,
        &values,
        spectrum.binaryArrays()[0],
        2,
        header.groups,
        .{ .transport = &transport, .transformed = &transformed },
    ));
    var typed_arrays = spectrum.arrays(header.groups);
    const typed_array = (try typed_arrays.next()).?;
    try std.testing.expectEqual(spectrum.binaryArrays()[0], typed_array.node);
    try std.testing.expectEqual(mzml.model.Primitive.float64, typed_array.encoding.primitive);
    try std.testing.expectEqual(mzml.arrays.Pipeline.none, typed_array.encoding.pipeline);
    try std.testing.expectEqual(@as(usize, 1), typed_array.length);
    try typed_array.decode(f64, &values, .{ .transport = &transport, .transformed = &transformed });
    try std.testing.expectEqual(@as(f64, 1), values[0]);
    var wrong_type: [1]i32 = undefined;
    try std.testing.expectError(error.TypeMismatch, typed_array.decode(i32, &wrong_type, .{
        .transport = &transport,
        .transformed = &transformed,
    }));
    const second_typed_array = (try typed_arrays.next()).?;
    try std.testing.expectEqual(@as(usize, 1), second_typed_array.length);
    try std.testing.expectEqual(null, try typed_arrays.next());
    var invalid_arrays = mzml.model.BinaryArrayIterator{
        .nodes = &.{.{ .kind = .binary_data_array }},
        .groups = &.{},
        .default_length = 0,
    };
    try std.testing.expectError(error.MissingPrimitive, invalid_arrays.next());
    try std.testing.expectError(error.MissingPrimitive, invalid_arrays.next());
    const chromatogram = (try reader.nextRecord()).?;
    try std.testing.expectEqual(.chromatogram, chromatogram.node.kind);
    try std.testing.expectEqualStrings("tic", chromatogram.id);
    try std.testing.expectEqualStrings("A&B", param.name.?);
    try std.testing.expectEqual(null, try reader.nextRecord());
    try std.testing.expectEqual(null, try reader.nextRecord());
    try std.testing.expectEqual(@as(usize, 1), header.spectrum_list.?.observed_count);
    try std.testing.expectEqual(@as(usize, 1), header.chromatogram_list.?.observed_count);
    try std.testing.expectEqual(@as(u64, support.DOCUMENT.len), header.document.end_offset);
}

test "[integration] - [mzML reader]: preserves complete metadata across fragmented encodings" {
    const prefixed = support.HEADER ++ "<spectrumList xmlns:p='http://psi.hupo.org/ms/mzml' count='1' defaultDataProcessingRef='dp'>" ++
        "<p:spectrum xmlns:q='http://www.w3.org/2001/XMLSchema-instance' q:schemaLocation='unchanged' id='scan=1' index='0' defaultArrayLength='0'>" ++
        "<p:userParam name='note' value='e&#x301;&#x9;&amp;'/></p:spectrum></spectrumList></run></mzML>";
    const sources = [_][]const u8{ support.DOCUMENT, support.EXTENSIONS, prefixed, @embedFile("data/scientific_metadata.mzML"), @embedFile("data/writer_indexed.mzML"), gates.EMPTY_RUN };
    for (sources) |source| {
        for (std.enums.values(mzml.StreamReader.Payload)) |payload| try support.expectFragmentedRead(source, payload);
    }
    var utf16: [prefixed.len * 2 + 2]u8 = undefined;
    for (std.enums.values(std.builtin.Endian)) |endian| {
        std.mem.writeInt(u16, utf16[0..2], 0xfeff, endian);
        for (prefixed, 0..) |byte, i| std.mem.writeInt(u16, utf16[2 + i * 2 ..][0..2], byte, endian);
        try support.expectFragmentedRead(&utf16, .retain);
    }
}

test "[integration] - [mzML reader]: rejects unreadable metadata without decoding payloads" {
    const retained = .{
        .{ "<mzML ", "<!DOCTYPE mzML><mzML ", error.DtdForbidden },
        .{ "<mzML ", "<?xml version='1.1'?><mzML ", error.UnsupportedVersion },
        .{ "value=''", "value='&#x1;'", error.InvalidXml },
        .{ "value=''", "value='\xff'", error.InvalidEncoding },
        .{ "<activation/>", "<!--a--b--><activation/>", error.InvalidXml },
        .{ "<activation/>", "<activation></precursor>", error.InvalidXml },
        .{ "index='0'", "index='bad'", error.InvalidValue },
        .{ "index='0'", "index=''", error.EmptyValue },
        .{ "defaultArrayLength='1'", "defaultArrayLength=''", error.EmptyValue },
        .{ "count='1'", "count=''", error.EmptyValue },
        .{ "count='1'", "count='bad'", error.InvalidValue },
        .{ "defaultArrayLength='1'", "defaultArrayLength='-1'", error.Overflow },
        .{ "index='0'", "index='0' index='1'", error.InvalidXml },
    };
    inline for (retained) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, case[0], case[1]);
        defer std.testing.allocator.free(source);
        try std.testing.expectError(case[2], support.readAll(std.testing.allocator, source, .{}));
    }
    const invalid_payload = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "<binary>AAAA", "<binary>!AAA");
    defer std.testing.allocator.free(invalid_payload);
    var invalid_input = std.Io.Reader.fixed(invalid_payload);
    var invalid = try mzml.StreamReader.init(std.testing.allocator, &invalid_input, .{});
    defer invalid.deinit();
    const record = (try invalid.nextRecord()).?;
    var values: [1]f64 = undefined;
    var transport: [32]u8 = undefined;
    try std.testing.expectError(error.InvalidCharacter, mzml.model.decodeArray(f64, &values, record.binaryArrays()[0], record.default_array_length, (try invalid.readHeader()).groups, .{ .transport = &transport, .transformed = &.{} }));
}

test "[failure] - [mzML reader]: rejects unsafe XML wrong namespaces and malformed structure" {
    const cases = .{
        .{ "<!DOCTYPE mzML>" ++ support.DOCUMENT, error.DtdForbidden },
        .{ "<mzML xmlns='wrong' version='1.1.0'/>", error.WrongNamespace },
        .{ "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.0.0'/>", error.InvalidStructure },
        .{ "<?xml version='1.1'?>" ++ support.DOCUMENT, error.UnsupportedVersion },
        .{ "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.1.0'/>", error.InvalidStructure },
    };
    inline for (cases) |case| {
        try std.testing.expectError(case[1], support.readAll(std.testing.allocator, case[0], .{}));
    }
    var input = std.Io.Reader.fixed("<mzML xmlns='wrong'/>");
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    try std.testing.expectError(error.WrongNamespace, reader.readHeader());
    try std.testing.expectEqual(@as(u64, 0), reader.diagnostic().?.location.?.input_event);
    try std.testing.expectError(error.FailedState, reader.nextRecord());
}

test "[edge] - [mzML reader]: skips payload storage without dropping array descriptors" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .payload = .skip });
    defer reader.deinit();
    const spectrum = (try reader.nextRecord()).?;
    const descriptors = spectrum.binaryArrays();
    try std.testing.expectEqual(@as(usize, 2), descriptors.len);
    try std.testing.expectEqual(null, descriptors[0].child(.binary).?.text);
    while (try reader.nextRecord()) |_| {}
}

test "[integration] - [mzML array selection]: preserves metadata and selected values across fragmented encodings" {
    const document = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "arrayLength='1'><referenceableParamGroupRef ref='encoding'/>", "arrayLength='1'><referenceableParamGroupRef ref='encoding'/><cvParam cvRef='MS' accession='X:unknown-role' name='future array' value='other'/>");
    defer std.testing.allocator.free(document);
    const utf16 = try std.testing.allocator.alloc(u8, document.len * 2 + 2);
    defer std.testing.allocator.free(utf16);
    for (0..3) |encoding| {
        const source = if (encoding == 0) document else blk: {
            const endian: std.builtin.Endian = if (encoding == 1) .little else .big;
            std.mem.writeInt(u16, utf16[0..2], 0xfeff, endian);
            for (document, 0..) |byte, index|
                std.mem.writeInt(u16, utf16[2 + index * 2 ..][0..2], byte, endian);
            break :blk utf16;
        };
        for (std.enums.values(@FieldType(Selection, "mode"))) |mode| {
            for ([_]bool{ false, true }) |numeric| {
                var selection: Selection = .{ .mode = mode };
                var buffer: [7]u8 = undefined;
                var input: std.testing.Reader = .init(&buffer, &.{.{ .buffer = source }});
                input.artificial_limit = .limited(1);
                var reader = try mzml.StreamReader.init(std.testing.allocator, &input.interface, .{
                    .array_selector = .{ .user_data = &selection, .select = Selection.select },
                });
                defer reader.deinit();
                const header = try reader.readHeader();
                try std.testing.expectEqual(@as(usize, 0), selection.calls);

                var reference_input = std.Io.Reader.fixed(source);
                var reference = try mzml.StreamReader.init(std.testing.allocator, &reference_input, .{});
                defer reference.deinit();
                var output = mzml.StreamReader.DecodedArrays.init(if (mode == .none) std.testing.failing_allocator else std.testing.allocator, .{});
                defer output.deinit();
                while (if (numeric) try reader.nextDecodedRecord(&output) else try reader.nextRecord()) |record| {
                    const expected = (try reference.nextRecord()).?;
                    try expectSelectedNode(expected.node, record.node);
                    var selected_count: usize = 0;
                    for (record.binaryArrays(), 0..) |array, position| {
                        const keep = switch (mode) {
                            .second => position == 1,
                            .named => position == 0,
                            .all, .group => true,
                            .none => false,
                        };
                        const text = array.child(.binary).?.text;
                        try std.testing.expectEqual(keep and !numeric, text != null);
                        if (numeric) {
                            if (keep) {
                                const decoded = output.get(selected_count).?;
                                selected_count += 1;
                                try std.testing.expectEqual(position, decoded.source_position);
                                try std.testing.expectEqualSlices(f64, &.{1}, decoded.values.float64);
                            }
                            continue;
                        }
                        var values: [1]f64 = undefined;
                        var transport: [8]u8 = undefined;
                        const descriptor = try mzml.model.BinaryArray.init(array, record.default_array_length, header.groups);
                        const decoded = descriptor.decode(f64, &values, .{ .transport = &transport, .transformed = &.{} });
                        if (keep) {
                            try decoded;
                            try std.testing.expectEqual(@as(f64, 1), values[0]);
                        } else try std.testing.expectError(error.PayloadNotRetained, decoded);
                    }
                    try std.testing.expectEqual(selected_count, output.len());
                }
                try std.testing.expectEqual(@as(usize, 0), output.len());
                try std.testing.expectEqual(null, try reference.nextRecord());
                try std.testing.expectEqualDeep((try reference.readHeader()).*, header.*);
                try std.testing.expectEqual(@as(usize, 4), selection.calls);
                try std.testing.expect(!selection.wrong_position);
            }
        }
    }
}

test "[failure] - [mzML array selection]: preserves skipped XML errors and diagnostics" {
    const cases = .{
        .{ "<binary>AAAA", "<binary>\x01AAA", error.InvalidXml },
        .{ "<binary>AAAA", "<binary>\xffAAA", error.InvalidEncoding },
        .{ "<binary>AAAA", "<binary>&missing;AAA", error.InvalidXml },
        .{ "</binary>", "</broken>", error.InvalidXml },
    };
    inline for (cases) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, case[0], case[1]);
        defer std.testing.allocator.free(source);
        var expected: ?mzml.StreamReader.Diagnostic = null;
        for (0..3) |mode| {
            var input = std.Io.Reader.fixed(source);
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{
                .array_selector = if (mode != 0) .{ .select = selectSecond } else null,
            });
            defer reader.deinit();
            var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
            defer output.deinit();
            try std.testing.expectError(case[2], if (mode == 2) reader.nextDecodedRecord(&output) else reader.nextRecord());
            try std.testing.expectEqual(@as(usize, 0), output.len());
            if (expected) |diagnostic| {
                try std.testing.expectEqualDeep(diagnostic, reader.diagnostic().?);
            } else expected = reader.diagnostic().?;
            try std.testing.expectError(error.FailedState, reader.nextRecord());
            try std.testing.expectEqualDeep(expected, reader.diagnostic());
        }
    }
}

test "[edge] - [mzML array selection]: keeps deferred errors and ignores selectors when all text is skipped" {
    const repeated = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "<referenceableParamGroupRef ref='encoding'/>", "<referenceableParamGroupRef ref='encoding'/><cvParam cvRef='MS' accession='MS:1000514' name='m/z array'/>");
    defer std.testing.allocator.free(repeated);
    var input = std.Io.Reader.fixed(repeated);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .array_selector = .{ .select = selectSecond } });
    defer reader.deinit();
    const header = try reader.readHeader();
    const record = (try reader.nextRecord()).?;
    try std.testing.expectError(error.RepeatedArray, record.arrayByRole(header.groups, mzml.model.Terms.MZ_ARRAY));
    while (try reader.nextRecord()) |_| {}

    inline for (.{ "missing", "encoding" }) |group| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "<referenceableParamGroupRef ref='encoding'/>", "<referenceableParamGroupRef ref='" ++ group ++ "'/><cvParam cvRef='MS' accession='X:future-codec' name='future codec'/>");
        defer std.testing.allocator.free(source);
        try support.readAll(std.testing.allocator, source, .{ .array_selector = .{ .select = selectSecond } });
    }
    inline for (.{ "MS:1000523", "MS:1000576" }) |accession| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, accession, "X:future-encoding");
        defer std.testing.allocator.free(source);
        try support.readAll(std.testing.allocator, source, .{ .array_selector = .{ .select = selectSecond } });
    }
    var selection: Selection = .{ .mode = .all };
    try support.readAll(std.testing.allocator, support.DOCUMENT, .{
        .payload = .skip,
        .array_selector = .{ .user_data = &selection, .select = Selection.select },
    });
    try std.testing.expectEqual(@as(usize, 0), selection.calls);
    try support.readAll(std.testing.allocator, support.REFERENCED_DOCUMENT, .{
        .array_selector = .{ .select = selectSecond },
    });
}

test "[edge] - [mzML array selection]: excludes skipped text from record storage and retains empty selections" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll(support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'>" ++
        "<spectrum id='scan=1' index='0' defaultArrayLength='0'><binaryDataArrayList count='3'>" ++
        "<binaryDataArray encodedLength='65537'><binary>");
    try source.writer.splatByteAll('A', 65537);
    try source.writer.writeAll("</binary></binaryDataArray>" ++
        "<binaryDataArray encodedLength='0'><referenceableParamGroupRef ref='encoding'/><binary/></binaryDataArray>" ++
        "<binaryDataArray encodedLength='0'><binary/></binaryDataArray>" ++
        "</binaryDataArrayList></spectrum></spectrumList></run></mzML>");
    const limits: mzml.StreamReader.Limits = .{ .record_bytes = 8192, .binary_text_bytes = 65537 };
    try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, source.written(), .{ .limits = limits }));
    var input = std.Io.Reader.fixed(source.written());
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{
        .limits = limits,
        .array_selector = .{ .select = selectSecond },
    });
    defer reader.deinit();
    const header = try reader.readHeader();
    const record = (try reader.nextRecord()).?;
    const arrays = record.binaryArrays();
    try std.testing.expectEqual(@as(usize, 3), arrays.len);
    try std.testing.expectEqual(null, arrays[0].child(.binary).?.text);
    try std.testing.expectEqualStrings("", arrays[1].child(.binary).?.text.?);
    try std.testing.expectEqual(null, arrays[2].child(.binary).?.text);
    try mzml.model.decodeArray(f64, &.{}, arrays[1], 0, header.groups, .{ .transport = &.{}, .transformed = &.{} });
    try std.testing.expectEqual(null, try reader.nextRecord());
}

test "[failure] - [mzML array selection]: releases allocations and bounds skipped text" {
    const options: mzml.StreamReader.Options = .{ .array_selector = .{ .select = selectSecond } };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.readAll, .{ support.DOCUMENT, options });
    var limited = options;
    limited.limits.binary_text_bytes = 11;
    try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, limited));
    limited.limits.binary_text_bytes = 12;
    try support.readAll(std.testing.allocator, support.DOCUMENT, limited);
    limited.limits.record_bytes = 1;
    try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, limited));
}

test "[failure] - [mzML reader]: releases partial allocations and enforces retention limits" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.readAll, .{ support.DOCUMENT, mzml.StreamReader.Options{} });
    try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{
        .limits = .{ .header_bytes = 1 },
    }));
    try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{
        .limits = .{ .record_bytes = 1 },
    }));
    const limits = [_]mzml.StreamReader.Limits{
        .{ .attributes = 1 },
        .{ .attribute_bytes = 1 },
        .{ .nodes = 1 },
        .{ .list_entries = 1 },
        .{ .binary_text_bytes = 11 },
    };
    for (limits) |limit| {
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{ .limits = limit }));
    }
    try support.readAll(std.testing.allocator, support.DOCUMENT, .{ .limits = .{ .binary_text_bytes = 12 } });
    try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{
        .limits = .{ .binary_text_bytes = 11 },
        .payload = .skip,
    }));
}

test "[integration] - [mzML reader]: keeps declared and observed counts separate" {
    for ([_][]const u8{ "count='0'", "count='2'" }, [_]usize{ 0, 2 }) |replacement, declared| {
        const document = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "count='1'", replacement);
        defer std.testing.allocator.free(document);
        var input = std.Io.Reader.fixed(document);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const header = try reader.readHeader();
        try std.testing.expectEqual(declared, header.spectrum_list.?.declared_count);
        try std.testing.expectEqual(@as(usize, 0), header.spectrum_list.?.observed_count);
        try std.testing.expectEqualStrings("native=a&b", (try reader.nextRecord()).?.id);
        try std.testing.expectEqualStrings("tic", (try reader.nextRecord()).?.id);
        try std.testing.expectEqual(null, try reader.nextRecord());
        try std.testing.expectEqual(@as(usize, 1), header.spectrum_list.?.observed_count);
        try std.testing.expectEqual(declared, header.chromatogram_list.?.declared_count);
        try std.testing.expectEqual(@as(usize, 1), header.chromatogram_list.?.observed_count);
        try std.testing.expectEqual(null, reader.diagnostic());
    }
}

test "[integration] - [mzML writer]: matches frozen XML and preserves attribute characters" {
    const expected = std.mem.trimEnd(u8, gates.EMPTY_RUN, "\n");
    var input = std.Io.Reader.fixed(expected);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const params = header.document.child(.file_description).?.child(.file_content).?.params;
    try std.testing.expectEqualStrings("\xc2\xb5 < & \"", params[0].cv.name.?);
    try std.testing.expectEqualStrings("\t\n\r", params[0].cv.value.?);
    try std.testing.expectEqual(null, params[1].user.value);
    try std.testing.expectEqualStrings("", params[1].user.unit.name.?);
    const declaration_node = header.document.child(.cv_list).?.children[0];
    const declarations = [_]mzml.cv.Declaration{try declaration_node.cvDeclaration()};
    const resolver = mzml.cv.Resolver.init(&declarations);
    const resolved = try resolver.resolve(params[0].cv);
    try std.testing.expectEqualDeep(params[0].cv, resolved.source);
    try std.testing.expectEqual(null, resolved.term.match);
    try std.testing.expectEqual(null, try reader.nextRecord());

    var bytes: [2048]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header.*);
    try writer.finish();
    try std.testing.expectEqualStrings(expected, sink.buffered());
    try std.testing.expectError(error.InvalidState, writer.finish());
}

test "[integration] - [mzML reader]: reads indexed trailers only when requested" {
    const allocator = std.testing.allocator;
    const document = "<indexedmzML xmlns='http://psi.hupo.org/ms/mzml'>" ++ support.DOCUMENT;
    const trailer = "<indexList count='1'><index name='spectrum'><offset idRef='native=a&amp;b'>0</offset></index></indexList>" ++
        "<indexListOffset>0</indexListOffset><fileChecksum>unchecked</fileChecksum></indexedmzML>";
    for ([_][]const u8{ document, document ++ "<broken", document ++ trailer }) |text| {
        var utf16: [(document.len + trailer.len) * 2 + 2]u8 = undefined;
        for ([_]?std.builtin.Endian{ null, .little, .big }) |encoding| {
            const source = if (encoding) |endian| blk: {
                std.mem.writeInt(u16, utf16[0..2], 0xfeff, endian);
                for (text, 0..) |byte, i| std.mem.writeInt(u16, utf16[2 + 2 * i ..][0..2], byte, endian);
                break :blk utf16[0 .. text.len * 2 + 2];
            } else text;
            for ([_]bool{ false, true }) |decode| {
                var buffer: [7]u8 = undefined;
                var input: std.testing.Reader = .init(&buffer, &.{.{ .buffer = source }});
                input.artificial_limit = .limited(1);
                var reader = try mzml.StreamReader.init(allocator, &input.interface, .{});
                defer reader.deinit();
                const header = try reader.readHeader();
                var output = mzml.StreamReader.DecodedArrays.init(allocator, .{});
                defer output.deinit();
                var count: usize = 0;
                while (if (decode) try reader.nextDecodedRecord(&output) else try reader.nextRecord()) |record| {
                    try std.testing.expectEqualStrings(if (count == 0) "native=a&b" else "tic", record.id);
                    if (decode) {
                        try std.testing.expectEqual(@as(usize, 2), output.len());
                        for (0..output.len()) |i| try std.testing.expectEqualSlices(f64, &.{1}, output.get(i).?.values.float64);
                    }
                    count += 1;
                }
                try std.testing.expectEqual(@as(usize, 2), count);
                try std.testing.expectEqual(@as(usize, 0), output.len());
                try std.testing.expectEqual(@as(u64, if (encoding != null) document.len * 2 + 2 else document.len), header.document.end_offset);
                try std.testing.expectEqual(null, reader.indexTrailer());
                try std.testing.expectEqual(null, reader.diagnostic());
                try std.testing.expectEqual(null, try reader.nextRecord());
            }
        }
    }
    for ([_]bool{ false, true }) |retain_index| {
        var bytes: [document.len]u8 = document.*;
        var input = std.Io.Reader.failing;
        input.buffer = &bytes;
        input.end = bytes.len;
        var reader = try mzml.StreamReader.init(allocator, &input, .{ .retain_index = retain_index });
        defer reader.deinit();
        _ = (try reader.nextRecord()).?;
        _ = (try reader.nextRecord()).?;
        if (retain_index) {
            try std.testing.expectError(error.ReadFailed, reader.nextRecord());
            try std.testing.expectError(error.FailedState, reader.nextRecord());
        } else try std.testing.expectEqual(null, try reader.nextRecord());
        try std.testing.expectEqual(null, reader.indexTrailer());
    }
    for ([_][]const u8{ document[0 .. document.len - 1], document ++ "<broken" }) |source| {
        try std.testing.expectError(error.InvalidXml, support.readAll(allocator, source, .{ .retain_index = true }));
    }
    try std.testing.expectError(error.InvalidXml, support.readAll(allocator, document[0 .. document.len - 1], .{}));
    var input = std.Io.Reader.fixed(document ++ trailer);
    var retained = try mzml.StreamReader.init(allocator, &input, .{ .retain_index = true });
    defer retained.deinit();
    while (try retained.nextRecord()) |_| {}
    const nodes = retained.indexTrailer().?;
    try std.testing.expectEqual(@as(usize, 3), nodes.len);
    try std.testing.expectEqualStrings("native=a&b", nodes[0].children[0].children[0].attribute("idRef").?);
    try std.testing.expectEqualStrings("0", nodes[1].text.?);
    try std.testing.expectEqualStrings("unchecked", nodes[2].text.?);
}

test "[integration] - [mzML reader]: distinguishes read failures from truncated XML" {
    var unbuffered = std.Io.Reader.failing;
    try std.testing.expectError(error.InvalidOptions, mzml.StreamReader.init(std.testing.allocator, &unbuffered, .{}));
    const Case = struct { source: []const u8, cut: usize };
    const cases = [_]Case{
        .{ .source = support.DOCUMENT, .cut = support.HEADER.len },
        .{ .source = support.STREAM_EXTENSIONS, .cut = std.mem.indexOf(u8, support.STREAM_EXTENSIONS, "before").? + "before".len },
    };
    for ([_]mzml.StreamReader.Options{
        .{},
        .{ .array_selector = .{ .select = selectSecond } },
    }) |options| for (cases) |case| {
        const source = std.mem.trimEnd(u8, case.source, "\r\n");
        var bytes: [@max(support.DOCUMENT.len, support.STREAM_EXTENSIONS.len)]u8 = undefined;
        for ([_]usize{ 0, case.cut, source.len / 2, source.len }) |length| {
            @memcpy(bytes[0..source.len], source);
            var input = std.Io.Reader.failing;
            input.buffer = bytes[0..source.len];
            input.end = length;
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, options);
            defer reader.deinit();
            while (reader.nextRecord()) |_| {} else |err| {
                try std.testing.expectEqual(error.ReadFailed, err);
                try std.testing.expectError(error.FailedState, reader.nextRecord());
                continue;
            }
            return error.TestUnexpectedResult;
        }
        for ([_]usize{ 0, 1, case.cut, source.len / 2, source.len - 1 }) |length| {
            try std.testing.expectError(error.InvalidXml, support.readAll(std.testing.allocator, source[0..length], options));
        }
    };
}

test "[integration] - [mzML arrays]: classifies explicit encodings without guessing" {
    const primitives = .{
        .{ "MS:1000521", mzml.model.Primitive.float32 },
        .{ "MS:1000523", mzml.model.Primitive.float64 },
        .{ "MS:1000519", mzml.model.Primitive.int32 },
        .{ "MS:1000522", mzml.model.Primitive.int64 },
    };
    const pipelines = .{
        .{ "MS:1000576", mzml.arrays.Pipeline.none },
        .{ "MS:1000574", mzml.arrays.Pipeline.zlib },
        .{ "MS:1002312", mzml.arrays.Pipeline.linear },
        .{ "MS:1002313", mzml.arrays.Pipeline.pic },
        .{ "MS:1002314", mzml.arrays.Pipeline.slof },
        .{ "MS:1002746", mzml.arrays.Pipeline.linear_zlib },
        .{ "MS:1002747", mzml.arrays.Pipeline.pic_zlib },
        .{ "MS:1002748", mzml.arrays.Pipeline.slof_zlib },
    };
    inline for (primitives) |primitive| {
        inline for (pipelines) |pipeline| {
            const entries = [_]mzml.cv.Entry{
                .{ .cv = .{ .accession = .{ .raw = primitive[0] } } },
                .{ .cv = .{ .accession = .{ .raw = pipeline[0] } } },
                .{ .cv = .{ .accession = .{ .raw = "X:future-role" } } },
            };
            const array: mzml.model.Node = .{ .kind = .binary_data_array, .params = &entries };
            try std.testing.expectEqualDeep(mzml.model.Encoding{
                .primitive = primitive[1],
                .pipeline = pipeline[1],
            }, try mzml.model.arrayEncoding(array, &.{}));
            const groups = [_]mzml.cv.Group{
                .{ .id = "encoding", .entries = &.{ entries[0], entries[1], entries[0], entries[1] } },
                .{ .id = "other", .entries = entries[0..2] },
            };
            const reference: mzml.cv.Entry = .{ .group_ref = .{ .ref = "encoding" } };
            for ([_][]const mzml.cv.Entry{
                &.{ entries[0], entries[0], entries[1], entries[1], entries[2] },
                &.{ reference, entries[0], entries[1] },
                &.{ entries[0], entries[1], reference },
                &.{ reference, reference, .{ .group_ref = .{ .ref = "other" } } },
            }) |params| {
                try std.testing.expectEqualDeep(mzml.model.Encoding{
                    .primitive = primitive[1],
                    .pipeline = pipeline[1],
                }, try mzml.model.arrayEncoding(.{ .kind = .binary_data_array, .params = params }, &groups));
            }
        }
    }
    const primitive: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = "MS:1000523" } } };
    const compression: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = "MS:1000576" } } };
    const other_primitive: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = "MS:1000522" } } };
    const other_compression: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = "MS:1000574" } } };
    const group: mzml.cv.Entry = .{ .group_ref = .{ .ref = "encoding" } };
    const conflict_groups = [_]mzml.cv.Group{.{ .id = "encoding", .entries = &.{ primitive, compression } }};
    const cases = .{
        .{ &[_]mzml.cv.Entry{}, error.MissingPrimitive },
        .{ &[_]mzml.cv.Entry{primitive}, error.MissingCompression },
        .{ &[_]mzml.cv.Entry{ primitive, primitive, other_primitive, compression }, error.ConflictingPrimitive },
        .{ &[_]mzml.cv.Entry{ primitive, compression, compression, other_compression }, error.ConflictingCompression },
        .{ &[_]mzml.cv.Entry{ group, other_primitive }, error.ConflictingPrimitive },
        .{ &[_]mzml.cv.Entry{ other_primitive, group }, error.ConflictingPrimitive },
        .{ &[_]mzml.cv.Entry{ group, other_compression }, error.ConflictingCompression },
        .{ &[_]mzml.cv.Entry{ other_compression, group }, error.ConflictingCompression },
        .{ &[_]mzml.cv.Entry{.{ .group_ref = .{ .ref = "absent" } }}, error.MissingGroup },
        .{ &[_]mzml.cv.Entry{.{ .cv = .{ .accession = .{ .raw = "MS:1003780" } } }}, error.UnsupportedEncoding },
    };
    inline for (cases) |case| {
        try std.testing.expectError(case[1], mzml.model.arrayEncoding(.{
            .kind = .binary_data_array,
            .params = case[0],
        }, &conflict_groups));
    }
    inline for (.{ "MS:1003088", "MS:1003089", "MS:1003090" }) |accession| {
        const unsupported: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = accession } } };
        const groups = [_]mzml.cv.Group{.{ .id = "codec", .entries = &.{unsupported} }};
        inline for (.{
            &[_]mzml.cv.Entry{ primitive, unsupported, compression },
            &[_]mzml.cv.Entry{ primitive, compression, unsupported },
            &[_]mzml.cv.Entry{ .{ .group_ref = .{ .ref = "codec" } }, primitive, compression },
        }) |entries| {
            var output: [0]f64 = .{};
            var transport: [1]u8 = undefined;
            var transformed: [1]u8 = undefined;
            try std.testing.expectError(error.UnsupportedEncoding, mzml.model.decodeArray(f64, &output, .{
                .kind = .binary_data_array,
                .params = entries,
                .children = &.{.{ .kind = .binary, .text = "" }},
            }, 0, &groups, .{ .transport = &transport, .transformed = &transformed }));
        }
    }
}

test "[property] - [decoded arrays]: streamed Numpress matches whole-payload decoding" {
    const allocator = std.testing.allocator;
    var random = std.Random.DefaultPrng.init(0x4e55_4d50_4152_5259);
    const source = random.random();
    const pipelines = [_]struct { mzml.arrays.Pipeline, []const u8 }{
        .{ .linear, "MS:1002312" },      .{ .pic, "MS:1002313" },      .{ .slof, "MS:1002314" },
        .{ .linear_zlib, "MS:1002746" }, .{ .pic_zlib, "MS:1002747" }, .{ .slof_zlib, "MS:1002748" },
    };
    var encoder = mzml.arrays.Encoder.init(allocator, .fast);
    defer encoder.deinit();
    var decoded = mzml.StreamReader.DecodedArrays.init(allocator, .{});
    defer decoded.deinit();
    const values = try allocator.alloc(f64, 9_000);
    defer allocator.free(values);
    var current: f64 = 100;
    for (values) |*value| {
        current += source.float(f64) * 4;
        value.* = current;
    }
    for (pipelines) |entry| {
        const pipeline, const accession = entry;
        for ([_]usize{ 0, 1, 3, 600, 9_000 }) |count| {
            const fixed_point: ?f64 = switch (pipeline.transform()) {
                .linear => try mzml.numpress.optimalLinearFixedPoint(values[0..count]),
                .slof => try mzml.numpress.optimalSlofFixedPoint(values[0..count]),
                else => null,
            };
            encoder.reset();
            const wire = try encoder.encode(f64, values[0..count], .{ .pipeline = pipeline, .fixed_point = fixed_point });
            const damaged = try allocator.dupe(u8, wire);
            defer allocator.free(damaged);
            for (0..12) |variant| {
                // Variants 1-5 flip a byte, 6-8 cut the payload, 9-11 misstate the length.
                @memcpy(damaged, wire);
                var payload: []const u8 = damaged;
                if (variant >= 1 and variant <= 5 and damaged.len != 0) {
                    damaged[source.uintLessThan(usize, damaged.len)] ^= @as(u8, 1) << source.int(u3);
                } else if (variant >= 6 and variant <= 8) {
                    payload = damaged[0..source.uintLessThan(usize, damaged.len + 1)];
                }
                const length = switch (variant) {
                    9 => count + 1,
                    10 => count -| 1,
                    11 => count * 2 + 1,
                    else => count,
                };
                const text = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(payload.len));
                defer allocator.free(text);
                _ = std.base64.standard.Encoder.encode(text, payload);
                try expectStreamedMatchesWhole(allocator, &decoded, text, accession, length, source);
            }
        }
    }
}

fn expectStreamedMatchesWhole(
    allocator: std.mem.Allocator,
    decoded: *mzml.StreamReader.DecodedArrays,
    text: []const u8,
    accession: []const u8,
    length: usize,
    source: std.Random,
) !void {
    const node: mzml.model.Node = .{
        .kind = .binary_data_array,
        .params = &.{
            .{ .cv = .{ .accession = .{ .raw = "MS:1000523" }, .name = "64-bit float" } },
            .{ .cv = .{ .accession = .{ .raw = accession }, .name = "compression" } },
        },
        .children = &.{.{ .kind = .binary, .text = text }},
    };
    const array = try mzml.model.BinaryArray.init(node, length, &.{});
    const expected_values = try allocator.alloc(f64, length);
    defer allocator.free(expected_values);
    const transport = try allocator.alloc(u8, text.len / 4 * 3 + 3);
    defer allocator.free(transport);
    const transformed = try allocator.alloc(u8, try mzml.arrays.wireBound(f64, length, array.encoding.pipeline));
    defer allocator.free(transformed);
    const expected = array.decode(f64, expected_values, .{ .transport = transport, .transformed = transformed });

    // The reader hands text over in fragments of any size.
    decoded.reset();
    decoded.default_length = length;
    const actual = streamed: {
        decoded.beginArray(node, &.{}, 0) catch |err| break :streamed err;
        var rest = text;
        while (rest.len != 0) {
            const piece = @min(rest.len, 1 + source.uintLessThan(usize, 40_000));
            decoded.text(rest[0..piece]) catch |err| break :streamed err;
            rest = rest[piece..];
        }
        decoded.finishArray() catch |err| break :streamed err;
        decoded.complete();
    };
    if (expected) |_| {
        try actual;
        try std.testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(expected_values),
            std.mem.sliceAsBytes(decoded.get(0).?.values.float64),
        );
    } else |err| {
        try std.testing.expectError(err, actual);
    }
}
