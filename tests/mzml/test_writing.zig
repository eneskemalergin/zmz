//! Tests plain, indexed, and prepared writing.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

test "[integration] - [mzML writer]: preserves metadata and records through a plain rewrite" {
    var bytes: [8192]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    try support.rewriteFixture(std.testing.allocator, &sink);
    try std.testing.expect(std.mem.startsWith(u8, sink.buffered(), "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
    try std.testing.expect(std.mem.endsWith(u8, sink.buffered(), "</chromatogramList></run></mzML>"));
    var original = std.Io.Reader.fixed(support.DOCUMENT);
    var rewritten = std.Io.Reader.fixed(sink.buffered());
    var a = try mzml.StreamReader.init(std.testing.allocator, &original, .{});
    defer a.deinit();
    var b = try mzml.StreamReader.init(std.testing.allocator, &rewritten, .{});
    defer b.deinit();
    try support.expectNode((try a.readHeader()).document, (try b.readHeader()).document);
    try support.expectNode((try a.readHeader()).run, (try b.readHeader()).run);
    while (try a.nextRecord()) |record| try support.expectNode(record.node, (try b.nextRecord()).?.node);
    try std.testing.expectEqual(null, try b.nextRecord());
    var second_bytes: [8192]u8 = undefined;
    var second = std.Io.Writer.fixed(&second_bytes);
    try support.rewriteFixture(std.testing.allocator, &second);
    try std.testing.expectEqualStrings(sink.buffered(), second.buffered());
}

test "[failure] - [mzML writer]: rejects counts and keeps output failures sticky" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var bytes: [8192]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header.*);
    try writer.beginList(.spectrum_list, 1, "dp");
    try std.testing.expectError(error.CountMismatch, writer.endList());
    try std.testing.expectError(error.FailedState, writer.finish());
    for ([_]usize{ 0, 8, 128, 1024, 2048 }) |length| {
        var short_sink = std.Io.Writer.fixed(bytes[0..length]);
        try std.testing.expectError(error.WriteFailed, support.rewriteFixture(std.testing.allocator, &short_sink));
    }
    var short_sink = std.Io.Writer.fixed(bytes[0..0]);
    var failing = try mzml.Writer.init(std.testing.allocator, &short_sink, .{});
    defer failing.deinit();
    try std.testing.expectError(error.WriteFailed, failing.writeHeader(header.*));
    try std.testing.expectError(error.FailedState, failing.finish());

    const record = (try reader.nextRecord()).?;
    var array = record.binaryArrays()[0];
    array.children = &.{.{ .kind = .binary, .text = "\x00!!!!!!!!!!!" }};
    var list = record.node.child(.binary_data_array_list).?;
    list.children = &.{ array, record.binaryArrays()[1] };
    var malformed = record.node;
    malformed.children = &.{list};
    var invalid_sink = std.Io.Writer.fixed(&bytes);
    var invalid = try mzml.Writer.init(std.testing.allocator, &invalid_sink, .{});
    defer invalid.deinit();
    try invalid.writeHeader(header.*);
    try invalid.beginList(.spectrum_list, 1, "dp");
    const before = invalid_sink.buffered().len;
    try std.testing.expectError(error.InvalidCharacter, invalid.writeRecord(malformed));
    try std.testing.expect(invalid_sink.buffered().len > before);
    try std.testing.expectError(error.FailedState, invalid.finish());
}

test "[failure] - [mzML writer]: releases partial allocations during rewrite" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.rewriteAllocated, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.indexedRewriteAllocated, .{});
}

test "[integration] - [mzML references]: preserves unresolved and external links through rewriting and indexed access" {
    inline for (.{
        "spectrumRef='scan=2'",
        "spectrumRef='scan=absent'",
        "externalSpectrumID='scan=outside' sourceFileRef='unavailable'",
    }) |reference| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.REFERENCED_DOCUMENT, "spectrumRef='scan=2'", reference);
        defer std.testing.allocator.free(source);
        try support.readAll(std.testing.allocator, source, .{ .payload = .skip });
        for ([_]bool{ false, true }) |indexed| {
            var bytes: [16384]u8 = undefined;
            var sink = std.Io.Writer.fixed(&bytes);
            try support.rewriteDocument(std.testing.allocator, source, &sink, indexed);
            var original_input = std.Io.Reader.fixed(source);
            var original = try mzml.StreamReader.init(std.testing.allocator, &original_input, .{});
            defer original.deinit();
            var rewritten_input = std.Io.Reader.fixed(sink.buffered());
            var rewritten = try mzml.StreamReader.init(std.testing.allocator, &rewritten_input, .{});
            defer rewritten.deinit();
            var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{
                .policy = if (indexed) .open_embedded else .rebuild,
            });
            defer index.deinit();
            const header = try original.readHeader();
            const rewritten_header = try rewritten.readHeader();
            try support.expectNode(header.document, rewritten_header.document);
            var count: usize = 0;
            while (try original.nextRecord()) |record| {
                const next = (try rewritten.nextRecord()).?;
                try support.expectNode(record.node, next.node);
                var found = (try index.at(std.testing.allocator, record.node.kind, record.index)).?;
                defer found.deinit();
                try support.expectNode(record.node, found.value.node);
                for (next.binaryArrays()) |array| {
                    var values: [1]f64 = undefined;
                    try mzml.model.decodeArray(f64, &values, array, next.default_array_length, rewritten_header.groups, .{ .transport = &.{}, .transformed = &.{} }, .{});
                    try std.testing.expectEqual(@as(f64, 1), values[0]);
                }
                count += 1;
            }
            try std.testing.expectEqual(@as(usize, 3), count);
            try std.testing.expectEqual(null, try rewritten.nextRecord());
            try std.testing.expectEqual(null, try index.byId(std.testing.allocator, "scan=absent"));
        }
    }
}

test "[integration] - [mzML prepared writing]: preserves primitive bytes across chunk and padding boundaries" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var compressor = try mzml.zlib.Compressor.init(std.testing.allocator, .fastest);
    defer compressor.deinit();
    inline for (.{ f32, f64, i32, i64 }) |T| {
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        var values: [769]T = undefined;
        for (&values, 0..) |*value, i| value.* = @bitCast(@as(Bits, @truncate(@as(u64, i) *% 0x9e3779b97f4a7c15)));
        for ([_]usize{ 0, 1, 2, 383, 384, 385, 768, 769 }) |count| {
            for ([_]mzml.arrays.Pipeline{ .none, .zlib }) |pipeline| {
                builder.reset();
                var text: [16384]u8 = undefined;
                var transport: [16384]u8 = undefined;
                var transformed: [8192]u8 = undefined;
                const scratch: mzml.arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
                var arrays: [2]mzml.Builder.Array = undefined;
                for (&arrays, 0..) |*array, i| array.* = try builder.binaryArray(T, values[0..count], .{
                    .cv_ref = "MS",
                    .encoding = .{ .pipeline = pipeline },
                    .role = .{
                        .cv_ref = "MS",
                        .accession = if (i == 0) mzml.model.Terms.MZ_ARRAY else mzml.model.Terms.INTENSITY_ARRAY,
                        .name = if (i == 0) "m/z array" else "intensity array",
                    },
                }, &text, scratch, &compressor);
                const record = try builder.record(.spectrum, "scan=1", 0, count, &.{}, &.{}, &arrays);
                var nodes = [_]mzml.model.Node{ arrays[0].node, arrays[1].node };
                for (&nodes) |*node| node.children = &.{.{ .kind = .binary }};
                var list = record.node.child(.binary_data_array_list).?;
                list.children = &nodes;
                var metadata = record.node;
                metadata.children = &.{list};
                const wire = try mzml.arrays.encodeWire(T, values[0..count], .{ .pipeline = pipeline }, scratch, &compressor);
                for ([_]bool{ false, true }) |indexed| {
                    var expected_bytes: [32768]u8 = undefined;
                    var expected = std.Io.Writer.fixed(&expected_bytes);
                    try support.writeSingleRecord(std.testing.allocator, &expected, header.*, record.node, indexed, null);
                    var actual_bytes: [32768]u8 = undefined;
                    var actual = std.Io.Writer.fixed(&actual_bytes);
                    try support.writeSingleRecord(std.testing.allocator, &actual, header.*, metadata, indexed, &.{ wire, wire });
                    try std.testing.expectEqualStrings(expected.buffered(), actual.buffered());
                    var source = std.Io.Reader.fixed(expected.buffered());
                    var decoded_reader = try mzml.StreamReader.init(std.testing.allocator, &source, .{});
                    defer decoded_reader.deinit();
                    var decoded_arrays = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
                    defer decoded_arrays.deinit();
                    const decoded_record = (try decoded_reader.nextDecodedRecord(&decoded_arrays)).?;
                    try std.testing.expectEqual(@as(usize, 2), decoded_arrays.len());
                    for (0..decoded_arrays.len()) |position| {
                        switch (decoded_arrays.get(position).?.values) {
                            inline else => |decoded| try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(values[0..count]), std.mem.sliceAsBytes(decoded)),
                        }
                    }
                    const decoded = decoded_arrays.get(0).?.values;
                    const typed: []const T = if (T == f32) decoded.float32 else if (T == f64) decoded.float64 else if (T == i32) decoded.int32 else decoded.int64;
                    const reencoded = try mzml.arrays.encodeWire(T, typed, .{ .pipeline = pipeline }, scratch, &compressor);
                    var rewritten_bytes: [32768]u8 = undefined;
                    var rewritten = std.Io.Writer.fixed(&rewritten_bytes);
                    try support.writeSingleRecord(std.testing.allocator, &rewritten, header.*, decoded_record.node, indexed, &.{ reencoded, reencoded });
                    try std.testing.expectEqualSlices(u8, expected.buffered(), rewritten.buffered());
                    if (indexed) {
                        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = rewritten.buffered() }, .{});
                        defer index.deinit();
                        try std.testing.expectEqual(@as(usize, 1), index.entries.items.len);
                        var fetched = (try index.atDecoded(std.testing.allocator, .spectrum, 0, &decoded_arrays)).?;
                        defer fetched.deinit();
                        try std.testing.expectEqual(@as(usize, 2), decoded_arrays.len());
                        for (0..decoded_arrays.len()) |position| {
                            switch (decoded_arrays.get(position).?.values) {
                                inline else => |items| try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(values[0..count]), std.mem.sliceAsBytes(items)),
                            }
                        }
                        const fetched_values = decoded_arrays.get(0).?.values;
                        const fetched_typed: []const T = if (T == f32) fetched_values.float32 else if (T == f64) fetched_values.float64 else if (T == i32) fetched_values.int32 else fetched_values.int64;
                        const fetched_wire = try mzml.arrays.encodeWire(T, fetched_typed, .{ .pipeline = pipeline }, scratch, &compressor);
                        var fetched_bytes: [32768]u8 = undefined;
                        var fetched_sink = std.Io.Writer.fixed(&fetched_bytes);
                        try support.writeSingleRecord(std.testing.allocator, &fetched_sink, header.*, fetched.value.node, true, &.{ fetched_wire, fetched_wire });
                        try std.testing.expectEqualSlices(u8, expected.buffered(), fetched_sink.buffered());
                    }
                    try std.testing.expectEqual(null, try decoded_reader.nextDecodedRecord(&decoded_arrays));
                }
            }
        }
    }
}

test "[integration] - [mzML prepared writing]: rejects mismatches and keeps sink failures sticky" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const record = (try reader.nextRecord()).?;
    const bytes = [_]u8{0} ** 8;
    for ([_]bool{ false, true }) |indexed| {
        for (0..9) |failure| {
            var output: [8192]u8 = undefined;
            var sink = std.Io.Writer.fixed(&output);
            var writer = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &sink, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &sink, .{});
            defer writer.deinit();
            try writer.writeHeader(header.*);
            try writer.beginList(.spectrum_list, 1, "dp");
            const before = sink.buffered().len;
            switch (failure) {
                0 => try std.testing.expectError(error.CountMismatch, writer.writeRecordWithArrays(record.node, &.{})),
                1 => try std.testing.expectError(error.EncodedLengthMismatch, writer.writeRecordWithArrays(record.node, &.{ &bytes, bytes[0..1] })),
                2 => try std.testing.expectError(error.OverlappingBuffers, writer.writeRecordWithArrays(record.node, &.{ output[0..8], &bytes })),
                3 => {
                    writer.limits.text_bytes = 11;
                    try std.testing.expectError(error.LimitExceeded, writer.writeRecordWithArrays(record.node, &.{ &bytes, &bytes }));
                },
                4 => {
                    sink.buffer = sink.buffer[0 .. sink.end + 1];
                    try std.testing.expectError(error.WriteFailed, writer.writeRecordWithArrays(record.node, &.{ &bytes, &bytes }));
                },
                5, 6, 7 => {
                    var array = record.binaryArrays()[0];
                    array.children = if (failure == 5) &.{} else if (failure == 6)
                        &.{ .{ .kind = .binary }, .{ .kind = .binary } }
                    else
                        &.{.{ .kind = .scan }};
                    var list = record.node.child(.binary_data_array_list).?;
                    list.children = &.{ array, record.binaryArrays()[1] };
                    var changed = record.node;
                    changed.children = &.{list};
                    try std.testing.expectError(error.InvalidStructure, writer.writeRecordWithArrays(changed, &.{ &bytes, &bytes }));
                },
                8 => {
                    var changed = record.node;
                    const list = changed.child(.binary_data_array_list).?;
                    changed.children = &.{ list, list };
                    try std.testing.expectError(error.InvalidStructure, writer.writeRecordWithArrays(changed, &.{ &bytes, &bytes }));
                    try std.testing.expect(sink.buffered().len > before);
                },
                else => unreachable,
            }
            if (failure != 4 and failure != 8) try std.testing.expectEqual(before, sink.buffered().len);
            try std.testing.expectError(error.FailedState, writer.finish());
            try std.testing.expectError(error.FailedState, writer.writeRecordWithArrays(record.node, &.{ &bytes, &bytes }));
        }
    }
}

test "[integration] - [mzML binary construction]: preserves text without decoding it" {
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "0" },
        .{ " \t\r\n", "0" },
        .{ " A\tA\r=\n= ", "4" },
        .{ " A\tA\r=\n= ", "11" },
        .{ "AA==", "0" },
        .{ "A!==", "0" },
        .{ "AB==", "0" },
        .{ "AAA", "0" },
        .{ "AA==AAAA", "0" },
        .{ "A!==", "bad" },
    };
    for (cases) |case| {
        builder.reset();
        const source: mzml.model.Node = .{
            .kind = .binary_data_array,
            .attributes = &.{.{ .name = "encodedLength", .value = case[1] }},
            .children = &.{.{ .kind = .binary, .text = case[0] }},
        };
        try support.expectNode(source, try builder.node(source));
    }
}

test "[integration] - [mzML writer]: preserves partial metadata and uninterpreted binary text" {
    const source = "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.1.0'>" ++
        "<userParam name='document parameter'/><run><userParam unitCvRef='UO'/><cvParam/><referenceableParamGroupRef/>" ++
        "<spectrumList count='1' defaultDataProcessingRef='dp'>" ++
        "<spectrum id='scan=1' index='0' defaultArrayLength='0' extra='kept'>" ++
        "<binaryDataArrayList count='7'><binaryDataArray encodedLength='unknown'>" ++
        "<binary>A!&amp;&lt;]]&gt;&#xD;</binary></binaryDataArray></binaryDataArrayList>" ++
        "<scanList count='0'/><cvParam unitName='partial'/>" ++
        "</spectrum></spectrumList><chromatogramList count='0' defaultDataProcessingRef='dp'/>" ++
        "</run></mzML>";
    for ([_]bool{ false, true }) |indexed| {
        var output: [8192]u8 = undefined;
        var sink = std.Io.Writer.fixed(&output);
        try support.rewriteDocument(std.testing.allocator, source, &sink, indexed);
        var original_input = std.Io.Reader.fixed(source);
        var original = try mzml.StreamReader.init(std.testing.allocator, &original_input, .{});
        defer original.deinit();
        var rewritten_input = std.Io.Reader.fixed(sink.buffered());
        var rewritten = try mzml.StreamReader.init(std.testing.allocator, &rewritten_input, .{});
        defer rewritten.deinit();
        try support.expectNode((try original.readHeader()).document, (try rewritten.readHeader()).document);
        try support.expectNode((try original.readHeader()).run, (try rewritten.readHeader()).run);
        try support.expectNode((try original.nextRecord()).?.node, (try rewritten.nextRecord()).?.node);
        try std.testing.expectEqual(null, try original.nextRecord());
        try std.testing.expectEqual(null, try rewritten.nextRecord());
    }
}

test "[failure] - [mzML writer]: checks node bounds and missing payloads during emission" {
    const node: mzml.model.Node = .{ .kind = .spectrum, .attributes = &.{
        .{ .name = "id", .value = "one" },
        .{ .name = "index", .value = "0" },
        .{ .name = "defaultArrayLength", .value = "0" },
    }, .children = &.{.{ .kind = .binary_data_array_list, .children = &.{.{
        .kind = .binary_data_array,
        .children = &.{.{ .kind = .binary, .text = "AA==" }},
    }} }} };
    const header: mzml.model.Header = .{
        .document = .{ .kind = .mzml, .attributes = &.{.{ .name = "version", .value = "1.1.0" }} },
        .run = .{ .kind = .run },
    };
    const cases = [_]struct { mzml.Writer.Limits, ?mzml.Writer.Error }{
        .{ .{ .depth = 4, .nodes = 4, .text_bytes = 4 }, null },
        .{ .{ .depth = 3 }, error.LimitExceeded },
        .{ .{ .nodes = 3 }, error.LimitExceeded },
        .{ .{ .text_bytes = 3 }, error.LimitExceeded },
    };
    for (cases) |case| {
        var bytes: [2048]u8 = undefined;
        var sink = std.Io.Writer.fixed(&bytes);
        var writer = try mzml.Writer.init(std.testing.allocator, &sink, case[0]);
        defer writer.deinit();
        try writer.writeHeader(header);
        try writer.beginList(.spectrum_list, 1, "dp");
        if (case[1]) |failure| {
            try std.testing.expectError(failure, writer.writeRecord(node));
            try std.testing.expectError(error.FailedState, writer.finish());
        } else {
            try writer.writeRecord(node);
            try writer.endList();
            try writer.finish();
            var input = std.Io.Reader.fixed(sink.buffered());
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
            defer reader.deinit();
            try support.expectNode(node, (try reader.nextRecord()).?.node);
        }
    }
    var bytes: [2048]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header);
    try writer.beginList(.spectrum_list, 1, "dp");
    var array = node.children[0].children[0];
    array.children = &.{.{ .kind = .binary }};
    var list = node.children[0];
    list.children = &.{array};
    var missing = node;
    missing.children = &.{list};
    try std.testing.expectError(error.PayloadNotRetained, writer.writeRecord(missing));
    try std.testing.expectError(error.FailedState, writer.finish());
}

test "[integration] - [mzML writer]: leaves the final sink flush to its caller" {
    const FailingFlush = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
    };
    var bytes: [8192]u8 = undefined;
    var sink: std.Io.Writer = .{ .vtable = &.{ .drain = FailingFlush.drain }, .buffer = &bytes };
    try support.rewriteFixture(std.testing.allocator, &sink);
    try std.testing.expect(std.mem.endsWith(u8, sink.buffered(), "</mzML>"));
    try std.testing.expectError(error.WriteFailed, sink.flush());
}
