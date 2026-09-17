//! Tests streaming reads, payload handling, and malformed input.

const std = @import("std");
const zmz = @import("zmz");
const mzml = zmz.mzml;
const gates = @import("gates_test_support");
const support = @import("support.zig");

const Selection = struct {
    mode: enum { second, named, group, all, none },
    groups: []const mzml.cv.Group = &.{},
    calls: usize = 0,
    wrong_position: bool = false,
    failure: ?mzml.model.LookupError = null,

    fn select(user_data: ?*anyopaque, position: usize, attributes: []const mzml.model.Attribute, params: []const mzml.cv.Entry) mzml.StreamReader.Payload {
        const self: *Selection = @ptrCast(@alignCast(user_data.?));
        self.wrong_position = self.wrong_position or position != self.calls % 2;
        self.calls += 1;
        const node: mzml.model.Node = .{ .kind = .binary_data_array, .attributes = attributes, .params = params };
        const keep = switch (self.mode) {
            .second => position == 1,
            .named, .group => blk: {
                const accession = if (self.mode == .named) "X:unknown-role" else "MS:1000523";
                const parameter = node.parameter(self.groups, .{ .raw = accession }) catch |err| {
                    self.failure = err;
                    return .retain;
                } orelse break :blk false;
                break :blk self.mode == .group or (std.mem.eql(u8, parameter.name.?, "future array") and parameter.value == null);
            },
            .all => true,
            .none => false,
        };
        return if (keep) .retain else .skip;
    }
};

fn selectSecond(_: ?*anyopaque, position: usize, _: []const mzml.model.Attribute, _: []const mzml.cv.Entry) mzml.StreamReader.Payload {
    return if (position == 1) .retain else .skip;
}

fn expectSelectedNode(expected: mzml.model.Node, actual: mzml.model.Node) !void {
    try std.testing.expectEqual(expected.kind, actual.kind);
    try std.testing.expectEqualDeep(expected.attributes, actual.attributes);
    try std.testing.expectEqualDeep(expected.params, actual.params);
    try std.testing.expectEqual(expected.start_offset, actual.start_offset);
    try std.testing.expectEqual(expected.content_offset, actual.content_offset);
    try std.testing.expectEqual(expected.end_offset, actual.end_offset);
    if (expected.kind != .binary or actual.text != null)
        try std.testing.expectEqualDeep(expected.text, actual.text);
    try std.testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |left, right| try expectSelectedNode(left, right);
}

fn readDecoded(allocator: std.mem.Allocator, source: []const u8, limits: mzml.arrays.Limits) !void {
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(allocator, &input, .{});
    defer reader.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(allocator, limits);
    defer output.deinit();
    while (try reader.nextDecodedRecord(&output)) |_| {}
    try std.testing.expectEqual(@as(usize, 0), output.len());
    try std.testing.expectEqual(null, output.get(0));
}

fn readDecodedRecord(allocator: std.mem.Allocator, source: []const u8, limits: mzml.arrays.Limits) !void {
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(allocator, &input, .{});
    defer reader.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(allocator, limits);
    defer output.deinit();
    errdefer std.debug.assert(output.len() == 0);
    try std.testing.expect((try reader.nextDecodedRecord(&output)) != null);
    try std.testing.expectEqual(@as(usize, 2), output.len());
}

fn compareDecoded(source: []const u8, chunk: usize) !void {
    var storage: [31]u8 = undefined;
    var a_input = std.Io.Reader.fixed(source);
    var b_input: std.testing.Reader = .init(storage[0..chunk], &.{.{ .buffer = source }});
    b_input.artificial_limit = .limited(chunk);
    var a = try mzml.StreamReader.init(std.testing.allocator, &a_input, .{});
    defer a.deinit();
    var b = try mzml.StreamReader.init(std.testing.allocator, &b_input.interface, .{});
    defer b.deinit();
    const header = try a.readHeader();
    var output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer output.deinit();
    while (try a.nextRecord()) |record| {
        const other = (try b.nextDecodedRecord(&output)).?;
        try expectSelectedNode(record.node, other.node);
        try std.testing.expectEqual(record.binaryArrays().len, output.len());
        var arrays = record.arrays(header.groups);
        var position: usize = 0;
        while (try arrays.next()) |array| : (position += 1) {
            const actual = output.get(position).?;
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
                    try array.decode(T, expected, .{ .transport = transport, .transformed = transformed }, .{});
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
    try support.constructFixture(std.testing.allocator, &sink, true, std.meta.tags(mzml.arrays.Pipeline), false);
    try compareDecoded(sink.buffered(), 7);
    for ([_][]const u8{ "", " \t\r\n" }) |text| {
        const source = try decodedDocument(std.testing.allocator, text, 0, 0, "MS:1000574");
        defer std.testing.allocator.free(source);
        try compareDecoded(source, 1);
    }
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
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecoded, .{ support.DOCUMENT, mzml.arrays.Limits{} });
    var storage: [32768]u8 = undefined;
    var compressed = std.Io.Writer.fixed(&storage);
    try support.constructFixture(std.testing.allocator, &compressed, false, std.meta.tags(mzml.arrays.Pipeline), false);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecoded, .{ compressed.buffered(), mzml.arrays.Limits{} });
    for ([_]mzml.arrays.Limits{
        .{ .array_bytes = 7 },
        .{ .base64_text = .{ .text_bytes = 11 } },
        .{ .base64_text = .{ .significant_bytes = 11 } },
        .{ .base64_text = .{ .decoded_bytes = 7 } },
    }) |limit| try std.testing.expectError(error.LimitExceeded, readDecoded(std.testing.allocator, support.DOCUMENT, limit));
    const text = "!" ++ "A" ** 70000;
    const source = try decodedDocument(std.testing.allocator, text, text.len, 1, "MS:1000576");
    defer std.testing.allocator.free(source);
    try std.testing.expectError(error.InvalidCharacter, readDecoded(std.testing.allocator, source, .{ .base64_text = .{ .text_bytes = 65536 } }));
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
    var compressor = try mzml.zlib.Compressor.init(std.testing.allocator, .fastest);
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
    const limits: mzml.arrays.Limits = .{
        .array_bytes = @sizeOf(@TypeOf(values)),
        .base64_text = .{ .text_bytes = text.len, .significant_bytes = text.len, .decoded_bytes = wire.len },
    };
    // EOF can attempt optional arena consolidation, whose allocation failure is recoverable.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readDecodedRecord, .{ source, limits });
    for (0..4) |limit| {
        var too_small = limits;
        switch (limit) {
            0 => too_small.array_bytes -= 1,
            1 => too_small.base64_text.text_bytes -= 1,
            2 => too_small.base64_text.significant_bytes -= 1,
            3 => too_small.base64_text.decoded_bytes -= 1,
            else => unreachable,
        }
        try std.testing.expectError(error.LimitExceeded, readDecoded(std.testing.allocator, source, too_small));
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
    try std.testing.expect(diagnostic.byte_offset < first_end);
    const position = input.seek;
    try std.testing.expectError(error.FailedState, reader.nextDecodedRecord(&output));
    try std.testing.expectEqual(position, input.seek);
}

test "[integration] - [mzML decoded reading]: keeps numeric lifetimes independent and rejects incompatible options" {
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
    for ([_]mzml.StreamReader.Options{ .{ .checks = .minimal }, .{ .array_selector = .{ .select = selectSecond } } }) |options| {
        var input = std.Io.Reader.fixed(support.DOCUMENT);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, options);
        defer reader.deinit();
        try std.testing.expectError(error.InvalidOptions, reader.nextDecodedRecord(&output));
        try std.testing.expectEqual(null, reader.diagnostic());
        try std.testing.expectEqualStrings("native=a&b", (try reader.nextRecord()).?.id);
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
    try mzml.model.decodeArray(f64, &.{}, node, 5, &.{}, .{ .transport = &scratch, .transformed = &.{} }, .{});
    var typed_arrays = record.arrays(&.{});
    const typed_array = (try typed_arrays.next()).?;
    try typed_array.decode(f64, &.{}, .{ .transport = &scratch, .transformed = &.{} }, .{});
    try std.testing.expectError(error.LimitExceeded, mzml.model.decodeArray(f64, &.{}, node, 0, &.{}, .{ .transport = &scratch, .transformed = &.{} }, .{ .base64_text = .{ .text_bytes = 0 } }));
    var one: [1]f64 = undefined;
    var nonempty = node;
    nonempty.attributes = &.{.{ .name = "encodedLength", .value = "0" }};
    try std.testing.expectError(error.TruncatedInput, mzml.model.decodeArray(f64, &one, nonempty, 1, &.{}, .{ .transport = &scratch, .transformed = &.{} }, .{}));
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
            for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
                var fixed = std.heap.FixedBufferAllocator.init(backing);
                var input = std.Io.Reader.fixed(changed);
                var reader = try mzml.StreamReader.init(fixed.allocator(), &input, .{
                    .checks = checks,
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
            try mzml.model.decodeArray(f64, output[0..length], array, length, header.groups, .{ .transport = &transport, .transformed = &.{} }, .{});
            try std.testing.expectEqualSlices(u8, zeros[0 .. length * 8], std.mem.sliceAsBytes(output[0..length]));
        }
    }
    try std.testing.expectEqual(null, try reader.nextRecord());
    try compareDecoded(source.written(), 7);
}

test "[integration] - [mzML numeric attributes]: reads source text and checks numbers when used" {
    const cases = .{
        .{ "word", error.InvalidValue },
        .{ "1_0", error.InvalidValue },
        .{ "-1", error.Overflow },
    };
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    inline for (cases) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "order='0'", "order='" ++ case[0] ++ "'");
        defer std.testing.allocator.free(source);
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const method = (try reader.readHeader()).document.child(.data_processing_list).?.children[0].children[0];
        try std.testing.expectEqualStrings(case[0], method.attribute("order").?);
        while (try reader.nextRecord()) |_| {}
        try std.testing.expectError(case[1], builder.node(.{
            .kind = .processing_method,
            .attributes = &.{ .{ .name = "order", .value = case[0] }, .{ .name = "softwareRef", .value = "sw" } },
        }));
    }
    inline for (.{ "2147483648", "-2147483649", "1.5" }) |value| {
        const expected = if (std.mem.eql(u8, value, "1.5")) error.InvalidValue else error.Overflow;
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
        try std.testing.expectError(expected, builder.node(.{
            .kind = .source,
            .attributes = &.{.{ .name = "order", .value = value }},
        }));
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
    try std.testing.expectError(error.Overflow, builder.record(.spectrum, "scan=1", 0, 2147483648, &.{}, &.{}, &.{}));

    const record_cases = [_]struct { length: []const u8, index: []const u8, read_error: ?mzml.cv.ValueError, build_error: ?mzml.cv.ValueError }{
        .{ .length = "2147483648", .index = "bad", .read_error = error.InvalidValue, .build_error = error.InvalidValue },
        .{ .length = "-1", .index = "bad", .read_error = error.InvalidValue, .build_error = error.Overflow },
        .{ .length = "-1", .index = "0", .read_error = error.Overflow, .build_error = error.Overflow },
        .{ .length = "2147483648", .index = "0", .read_error = null, .build_error = error.Overflow },
        .{ .length = " +2147483647 ", .index = "0", .read_error = null, .build_error = null },
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
        if (case.build_error) |failure| {
            try std.testing.expectError(failure, builder.node(node));
        } else {
            const copied = try builder.node(node);
            try std.testing.expectEqualStrings(case.length, copied.attribute("defaultArrayLength").?);
        }
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
    }, .{});
    try std.testing.expectEqual(@as(f64, 1), values[0]);
    try mzml.model.decodeArray(f64, &values, spectrum.binaryArrays()[1], 2, header.groups, .{
        .transport = &transport,
        .transformed = &transformed,
    }, .{});
    try std.testing.expectEqual(@as(f64, 1), values[0]);
    try std.testing.expectError(error.DecodedSizeMismatch, mzml.model.decodeArray(
        f64,
        &values,
        spectrum.binaryArrays()[0],
        2,
        header.groups,
        .{ .transport = &transport, .transformed = &transformed },
        .{},
    ));
    var typed_arrays = spectrum.arrays(header.groups);
    const typed_array = (try typed_arrays.next()).?;
    try std.testing.expectEqual(spectrum.binaryArrays()[0], typed_array.node);
    try std.testing.expectEqual(mzml.model.Primitive.float64, typed_array.encoding.primitive);
    try std.testing.expectEqual(mzml.arrays.Pipeline.none, typed_array.encoding.pipeline);
    try std.testing.expectEqual(@as(usize, 1), typed_array.length);
    try typed_array.decode(f64, &values, .{ .transport = &transport, .transformed = &transformed }, .{});
    try std.testing.expectEqual(@as(f64, 1), values[0]);
    var wrong_type: [1]i32 = undefined;
    try std.testing.expectError(error.TypeMismatch, typed_array.decode(i32, &wrong_type, .{
        .transport = &transport,
        .transformed = &transformed,
    }, .{}));
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

test "[integration] - [mzML minimal checks]: preserves complete metadata across fragmented encodings" {
    const prefixed = support.HEADER ++ "<spectrumList xmlns:p='http://psi.hupo.org/ms/mzml' count='1' defaultDataProcessingRef='dp'>" ++
        "<p:spectrum xmlns:q='http://www.w3.org/2001/XMLSchema-instance' q:schemaLocation='unchanged' id='scan=1' index='0' defaultArrayLength='0'>" ++
        "<p:userParam name='note' value='e&#x301;&#x9;&amp;'/></p:spectrum></spectrumList></run></mzML>";
    const sources = [_][]const u8{ support.DOCUMENT, prefixed, @embedFile("data/scientific_metadata.mzML"), @embedFile("data/writer_indexed.mzML"), gates.EMPTY_RUN };
    for (sources) |source| {
        for (std.enums.values(mzml.StreamReader.Payload)) |payload| try support.expectMinimalRead(source, payload);
    }
    var utf16: [prefixed.len * 2 + 2]u8 = undefined;
    for (std.enums.values(std.builtin.Endian)) |endian| {
        std.mem.writeInt(u16, utf16[0..2], 0xfeff, endian);
        for (prefixed, 0..) |byte, i| std.mem.writeInt(u16, utf16[2 + i * 2 ..][0..2], byte, endian);
        try support.expectMinimalRead(&utf16, .retain);
    }
}

test "[integration] - [mzML minimal checks]: distinguishes omitted checks from retained failures" {
    const omitted = .{
        .{ "http://psi.hupo.org/ms/mzml", "urn:unchecked", error.WrongNamespace },
        .{ "<activation/>", "", error.InvalidStructure },
        .{ "<userParam name='note' value=''/>", "<userParam name='note' value=''/><cvParam cvRef='MS' accession='X:future' name='later'/>", error.InvalidStructure },
        .{ "<referenceableParamGroup id='encoding'>", "<referenceableParamGroup id='encoding'><referenceableParamGroupRef ref='other'/>", error.InvalidStructure },
        .{ "index='0'", "index='0' extra='source'", error.UnknownAttribute },
    };
    inline for (omitted) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, case[0], case[1]);
        defer std.testing.allocator.free(source);
        try std.testing.expectError(case[2], support.readAll(std.testing.allocator, source, .{}));
        for (std.enums.values(mzml.StreamReader.Payload)) |payload| {
            try support.readAll(std.testing.allocator, source, .{ .checks = .minimal, .payload = payload });
        }
    }
    const retained = .{
        .{ "<mzML ", "<!DOCTYPE mzML><mzML ", error.DtdForbidden },
        .{ "<mzML ", "<?xml version='1.1'?><mzML ", error.UnsupportedVersion },
        .{ "value=''", "value='&#x1;'", error.InvalidXml },
        .{ "value=''", "value='\xff'", error.InvalidEncoding },
        .{ "<activation/>", "<!--a--b--><activation/>", error.InvalidXml },
        .{ "<activation/>", "<future/>", error.InvalidStructure },
        .{ "<activation/>", "<activation xmlns:q='urn:foreign' q:value='x'/>", error.UnknownAttribute },
        .{ "<activation/>", "<activation></precursor>", error.InvalidXml },
        .{ "name='note'", "", error.MissingAttribute },
        .{ "index='0'", "index='bad'", error.InvalidValue },
        .{ "defaultArrayLength='1'", "defaultArrayLength='-1'", error.Overflow },
        .{ "index='0'", "index='0' index='1'", error.InvalidXml },
    };
    inline for (retained) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, case[0], case[1]);
        defer std.testing.allocator.free(source);
        for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
            try std.testing.expectError(case[2], support.readAll(std.testing.allocator, source, .{ .checks = checks }));
        }
    }
    const extra = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "index='0'", "index='0' extra='source'");
    defer std.testing.allocator.free(extra);
    var extra_input = std.Io.Reader.fixed(extra);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &extra_input, .{ .checks = .minimal });
    defer reader.deinit();
    try std.testing.expectEqualStrings("source", (try reader.nextRecord()).?.node.attribute("extra").?);

    const invalid_payload = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "<binary>AAAA", "<binary>!AAA");
    defer std.testing.allocator.free(invalid_payload);
    var invalid_input = std.Io.Reader.fixed(invalid_payload);
    var invalid = try mzml.StreamReader.init(std.testing.allocator, &invalid_input, .{ .checks = .minimal });
    defer invalid.deinit();
    const record = (try invalid.nextRecord()).?;
    var values: [1]f64 = undefined;
    var transport: [32]u8 = undefined;
    try std.testing.expectError(error.InvalidCharacter, mzml.model.decodeArray(f64, &values, record.binaryArrays()[0], record.default_array_length, (try invalid.readHeader()).groups, .{ .transport = &transport, .transformed = &.{} }, .{}));
}

test "[failure] - [mzML reader]: rejects unsafe XML wrong namespaces and malformed structure" {
    const cases = .{
        .{ "<!DOCTYPE mzML>" ++ support.DOCUMENT, error.DtdForbidden },
        .{ "<mzML xmlns='wrong' version='1.1.0'/>", error.WrongNamespace },
        .{ "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.0.0'/>", error.UnsupportedVersion },
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
    try std.testing.expectEqual(@as(u64, 0), reader.diagnostic().?.byte_offset);
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

test "[integration] - [mzML array selection]: preserves metadata and decodes selected text across fragmented encodings" {
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
        for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
            for (std.enums.values(@FieldType(Selection, "mode"))) |mode| {
                var selection: Selection = .{ .mode = mode };
                var buffer: [7]u8 = undefined;
                var input: std.testing.Reader = .init(&buffer, &.{.{ .buffer = source }});
                input.artificial_limit = .limited(1);
                var reader = try mzml.StreamReader.init(std.testing.allocator, &input.interface, .{
                    .checks = checks,
                    .array_selector = .{ .user_data = &selection, .select = Selection.select },
                });
                defer reader.deinit();
                const header = try reader.readHeader();
                selection.groups = header.groups;
                try std.testing.expectEqual(@as(usize, 0), selection.calls);

                var reference_input = std.Io.Reader.fixed(source);
                var reference = try mzml.StreamReader.init(std.testing.allocator, &reference_input, .{ .checks = checks });
                defer reference.deinit();
                while (try reader.nextRecord()) |record| {
                    const expected = (try reference.nextRecord()).?;
                    try expectSelectedNode(expected.node, record.node);
                    for (record.binaryArrays(), 0..) |array, position| {
                        const keep = switch (mode) {
                            .second => position == 1,
                            .named => position == 0,
                            .all, .group => true,
                            .none => false,
                        };
                        const text = array.child(.binary).?.text;
                        try std.testing.expectEqual(keep, text != null);
                        var values: [1]f64 = undefined;
                        var transport: [8]u8 = undefined;
                        const descriptor = try mzml.model.BinaryArray.init(array, record.default_array_length, header.groups);
                        const decoded = descriptor.decode(f64, &values, .{ .transport = &transport, .transformed = &.{} }, .{});
                        if (keep) {
                            try decoded;
                            try std.testing.expectEqual(@as(f64, 1), values[0]);
                        } else try std.testing.expectError(error.PayloadNotRetained, decoded);
                    }
                }
                try std.testing.expectEqual(null, try reference.nextRecord());
                try std.testing.expectEqualDeep((try reference.readHeader()).*, header.*);
                try std.testing.expectEqual(@as(usize, 4), selection.calls);
                try std.testing.expect(!selection.wrong_position);
                try std.testing.expectEqual(null, selection.failure);
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
        for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
            var expected: ?mzml.StreamReader.Diagnostic = null;
            for ([_]bool{ false, true }) |selected| {
                var input = std.Io.Reader.fixed(source);
                var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{
                    .checks = checks,
                    .array_selector = if (selected) .{ .select = selectSecond } else null,
                });
                defer reader.deinit();
                try std.testing.expectError(case[2], reader.nextRecord());
                if (expected) |diagnostic| {
                    try std.testing.expectEqualDeep(diagnostic, reader.diagnostic().?);
                } else expected = reader.diagnostic().?;
                try std.testing.expectError(error.FailedState, reader.nextRecord());
                try std.testing.expectEqualDeep(expected, reader.diagnostic());
            }
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
    for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
        var input = std.Io.Reader.fixed(source.written());
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{
            .limits = limits,
            .checks = checks,
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
        try mzml.model.decodeArray(f64, &.{}, arrays[1], 0, header.groups, .{ .transport = &.{}, .transformed = &.{} }, .{});
        try std.testing.expectEqual(null, try reader.nextRecord());
    }
}

test "[failure] - [mzML array selection]: releases allocations and bounds skipped text" {
    for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
        const options: mzml.StreamReader.Options = .{ .checks = checks, .array_selector = .{ .select = selectSecond } };
        try std.testing.checkAllAllocationFailures(std.testing.allocator, support.readAll, .{ support.DOCUMENT, options });
        var limited = options;
        limited.limits.binary_text_bytes = 11;
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, limited));
        limited.limits.binary_text_bytes = 12;
        try support.readAll(std.testing.allocator, support.DOCUMENT, limited);
        limited.limits.record_bytes = 1;
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, limited));
    }
}

test "[failure] - [mzML reader]: releases partial allocations and enforces retention limits" {
    for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, support.readAll, .{ support.DOCUMENT, mzml.StreamReader.Options{ .checks = checks } });
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{
            .limits = .{ .header_bytes = 1 },
            .checks = checks,
        }));
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{
            .limits = .{ .record_bytes = 1 },
            .checks = checks,
        }));
        const limits = [_]mzml.StreamReader.Limits{
            .{ .depth = 2 },
            .{ .attributes = 1 },
            .{ .attribute_bytes = 1 },
            .{ .nodes = 1 },
            .{ .list_entries = 1 },
            .{ .binary_text_bytes = 11 },
        };
        for (limits) |limit| {
            try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{ .limits = limit, .checks = checks }));
        }
        try support.readAll(std.testing.allocator, support.DOCUMENT, .{ .limits = .{ .binary_text_bytes = 12 }, .checks = checks });
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{
            .limits = .{ .binary_text_bytes = 11 },
            .payload = .skip,
            .checks = checks,
        }));
    }
}

test "[integration] - [mzML reader]: keeps declared and observed counts separate" {
    for ([_][]const u8{ "count='0'", "count='2'" }, [_]usize{ 0, 2 }) |replacement, declared| {
        const document = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "count='1'", replacement);
        defer std.testing.allocator.free(document);
        for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
            var input = std.Io.Reader.fixed(document);
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .checks = checks });
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
    const declarations = [_]mzml.cv.Declaration{.{
        .id = declaration_node.attribute("id"),
        .full_name = declaration_node.attribute("fullName"),
        .uri = declaration_node.attribute("URI"),
        .version = declaration_node.attribute("version"),
    }};
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
            for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
                var buffer: [7]u8 = undefined;
                var input: std.testing.Reader = .init(&buffer, &.{.{ .buffer = source }});
                input.artificial_limit = .limited(1);
                var reader = try mzml.StreamReader.init(allocator, &input.interface, .{ .checks = checks });
                defer reader.deinit();
                const header = try reader.readHeader();
                var output = mzml.StreamReader.DecodedArrays.init(allocator, .{});
                defer output.deinit();
                var count: usize = 0;
                while (if (checks == .checked) try reader.nextDecodedRecord(&output) else try reader.nextRecord()) |record| {
                    try std.testing.expectEqualStrings(if (count == 0) "native=a&b" else "tic", record.id);
                    if (checks == .checked) {
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
    for ([_]mzml.StreamReader.Options{
        .{},
        .{ .checks = .minimal },
        .{ .array_selector = .{ .select = selectSecond } },
        .{ .checks = .minimal, .array_selector = .{ .select = selectSecond } },
    }) |options| {
        var bytes: [support.DOCUMENT.len]u8 = undefined;
        for ([_]usize{ 0, support.HEADER.len, support.DOCUMENT.len / 2, support.DOCUMENT.len }) |length| {
            @memcpy(&bytes, support.DOCUMENT);
            var input = std.Io.Reader.failing;
            input.buffer = &bytes;
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
        for ([_]usize{ 0, 1, support.HEADER.len, support.DOCUMENT.len / 2, support.DOCUMENT.len - 1 }) |length| {
            try std.testing.expectError(error.InvalidXml, support.readAll(std.testing.allocator, support.DOCUMENT[0..length], options));
        }
    }
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
        }
    }
    const primitive: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = "MS:1000523" } } };
    const compression: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = "MS:1000576" } } };
    const cases = .{
        .{ &[_]mzml.cv.Entry{}, error.MissingPrimitive },
        .{ &[_]mzml.cv.Entry{primitive}, error.MissingCompression },
        .{ &[_]mzml.cv.Entry{ primitive, primitive, compression }, error.ConflictingPrimitive },
        .{ &[_]mzml.cv.Entry{ primitive, compression, compression }, error.ConflictingCompression },
        .{ &[_]mzml.cv.Entry{.{ .group_ref = "absent" }}, error.MissingGroup },
        .{ &[_]mzml.cv.Entry{.{ .cv = .{ .accession = .{ .raw = "MS:1003780" } } }}, error.UnsupportedEncoding },
    };
    inline for (cases) |case| {
        try std.testing.expectError(case[1], mzml.model.arrayEncoding(.{
            .kind = .binary_data_array,
            .params = case[0],
        }, &.{}));
    }
    inline for (.{ "MS:1003088", "MS:1003089", "MS:1003090" }) |accession| {
        const unsupported: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = accession } } };
        const groups = [_]mzml.cv.Group{.{ .id = "codec", .entries = &.{unsupported} }};
        inline for (.{
            &[_]mzml.cv.Entry{ primitive, unsupported, compression },
            &[_]mzml.cv.Entry{ primitive, compression, unsupported },
            &[_]mzml.cv.Entry{ .{ .group_ref = "codec" }, primitive, compression },
        }) |entries| {
            var output: [0]f64 = .{};
            var transport: [1]u8 = undefined;
            var transformed: [1]u8 = undefined;
            try std.testing.expectError(error.UnsupportedEncoding, mzml.model.decodeArray(f64, &output, .{
                .kind = .binary_data_array,
                .params = entries,
                .children = &.{.{ .kind = .binary, .text = "" }},
            }, 0, &groups, .{ .transport = &transport, .transformed = &transformed }, .{}));
        }
    }
}
