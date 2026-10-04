//! Verifies binary-array wire boundaries through the public package.

const std = @import("std");
const builtin = @import("builtin");
const mzml = @import("zmz").mzml;
const base64 = mzml.base64;
const zlib = mzml.zlib;
const arrays = mzml.arrays;

// Decodes text in one call: the reference for split updates.
fn decodeWhole(text: []const u8) base64.Decoder.Error!base64.Counts {
    var output: [1536]u8 = undefined;
    var decoder = base64.Decoder.init(&output);
    try decoder.update(text);
    return decoder.finish();
}

test "[property] - [base64]: encoding matches independent bytes around vector blocks" {
    var source: [1025]u8 = undefined;
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    random.random().bytes(&source);
    var expected: [1368]u8 = undefined;
    var output: [1368]u8 = undefined;
    for ([_]usize{ 0, 1, 2, 3, 23, 24, 25, 31, 32, 33, 103, 104, 105, 127, 128, 129, 1023, 1024, 1025 }) |length| {
        const reference = std.base64.standard.Encoder.encode(&expected, source[0..length]);
        try std.testing.expectEqualStrings(reference, try base64.encode(&output, source[0..length]));
    }
}

test "[property] - [base64]: exact unaligned slices match independent encoding and decoding" {
    var source: [321]u8 = undefined;
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    random.random().bytes(&source);
    for (0..258) |length| {
        for (0..32) |offset| {
            var encoded = [_]u8{0xa5} ** 416;
            var decoded = [_]u8{0xa5} ** 321;
            var reference: [344]u8 = undefined;
            const input = source[offset..][0..length];
            const expected = std.base64.standard.Encoder.encode(&reference, input);
            const text = try base64.encode(encoded[offset..][0..expected.len], input);
            try std.testing.expectEqualSlices(u8, expected, text);
            try std.testing.expectEqual(length, (try base64.decode(decoded[offset..][0..length], text)).len);
            try std.testing.expectEqualSlices(u8, input, decoded[offset..][0..length]);
            try std.testing.expect(std.mem.allEqual(u8, encoded[0..offset], 0xa5));
            try std.testing.expect(std.mem.allEqual(u8, encoded[offset + expected.len ..], 0xa5));
            try std.testing.expect(std.mem.allEqual(u8, decoded[0..offset], 0xa5));
            try std.testing.expect(std.mem.allEqual(u8, decoded[offset + length ..], 0xa5));
        }
    }
}

test "[property] - [base64]: every byte in vector blocks follows XML decoding rules" {
    for (0..128) |position| {
        for (0..256) |value| {
            var text = [_]u8{'A'} ** 132;
            text[position] = @intCast(value);
            try compareBase64Updates(&text, 99);
        }
    }
}

test "[property] - [base64]: matches RFC 4648 vectors across every text split" {
    const cases = .{
        .{ "", "" },
        .{ "f", "Zg==" },
        .{ "fo", "Zm8=" },
        .{ "foo", "Zm9v" },
        .{ "foob", "Zm9vYg==" },
        .{ "fooba", "Zm9vYmE=" },
        .{ "foobar", "Zm9vYmFy" },
    };
    inline for (cases) |case| {
        var encoded: [32]u8 = undefined;
        try std.testing.expectEqualStrings(case[1], try base64.encode(&encoded, case[0]));
        var spaced: [64]u8 = undefined;
        var len: usize = 0;
        for (case[1]) |byte| {
            spaced[len] = byte;
            @memcpy(spaced[len + 1 ..][0..4], " \t\r\n");
            len += 5;
        }
        for (0..len + 1) |split| {
            var output: [32]u8 = undefined;
            var decoder = base64.Decoder.init(&output);
            try decoder.update(spaced[0..split]);
            try decoder.update(spaced[split..len]);
            const counts = try decoder.finish();
            try std.testing.expectEqualStrings(case[0], output[0..counts.decoded_bytes]);
            try std.testing.expectEqual(case[1].len, counts.significant_bytes);
            try std.testing.expectEqual(len, counts.text_bytes);
            try std.testing.expectEqualDeep(counts, try decodeWhole(spaced[0..len]));
        }
    }
}

test "[failure] - [base64]: rejects malformed tails and remains failed" {
    const cases = .{
        .{ "Z", error.TruncatedInput },
        .{ "Zg=", error.TruncatedInput },
        .{ "=g==", error.InvalidPadding },
        .{ "Z===", error.InvalidPadding },
        .{ "Zg=A", error.InvalidPadding },
        .{ "Zg==AAAA", error.InvalidPadding },
        .{ "Zh==", error.NonCanonicalTail },
        .{ "Zm9=", error.NonCanonicalTail },
        .{ "Zm-v", error.InvalidCharacter },
        .{ "Zm9v\x0b", error.InvalidCharacter },
    };
    inline for (cases) |case| {
        try std.testing.expectError(case[1], decodeWhole(case[0]));
        for (0..case[0].len + 1) |split| {
            var output: [32]u8 = undefined;
            var decoder = base64.Decoder.init(&output);
            const result = blk: {
                decoder.update(case[0][0..split]) catch |err| break :blk err;
                decoder.update(case[0][split..]) catch |err| break :blk err;
                break :blk decoder.finish();
            };
            try std.testing.expectError(case[1], result);
            try std.testing.expectError(error.FailedState, decoder.update(""));
            try std.testing.expectError(error.FailedState, decoder.finish());
        }
    }
}

test "[failure] - [base64]: enforces output capacity and destination ownership" {
    var output: [4]u8 = undefined;
    _ = try base64.decode(output[0..1], " Zg== ");
    try std.testing.expectError(error.OutputTooSmall, base64.decode(output[0..0], "Zg=="));
    try std.testing.expectError(error.OutputTooSmall, base64.encode(output[0..3], "f"));
    try std.testing.expectError(error.OverlappingBuffers, base64.encode(&output, output[0..1]));
    try std.testing.expectError(error.OverlappingBuffers, base64.decode(&output, &output));
    try std.testing.expectError(error.LengthOverflow, base64.encodedSize(std.math.maxInt(usize)));
}

test "[failure] - [base64]: rejects reuse after finish" {
    var output: [4]u8 = undefined;
    var decoder = base64.Decoder.init(&output);
    _ = try decoder.finish();
    try std.testing.expectError(error.AlreadyFinished, decoder.finish());
    try std.testing.expectError(error.AlreadyFinished, decoder.update(""));
}

test "[property] - [base64]: pieces of pieceFor characters always fit a retargeted window" {
    var source: [300]u8 = undefined;
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    random.random().bytes(&source);
    var encoded: [400]u8 = undefined;
    const text = try base64.encode(&encoded, &source);
    for (3..40) |size| {
        var window: [40]u8 = undefined;
        var decoded: [300]u8 = undefined;
        var length: usize = 0;
        var decoder = base64.Decoder.init(&.{});
        var rest: []const u8 = text;
        while (rest.len != 0) {
            // Shorter pieces leave a partial quartet for the next one.
            const piece = @min(rest.len, 1 + random.random().uintLessThan(usize, base64.Decoder.pieceFor(size)));
            decoder.retarget(window[0..size]);
            try decoder.update(rest[0..piece]);
            const bytes = decoder.take();
            @memcpy(decoded[length..][0..bytes.len], bytes);
            length += bytes.len;
            rest = rest[piece..];
        }
        _ = try decoder.finish();
        try std.testing.expectEqualSlices(u8, &source, decoded[0..length]);
    }
}

fn checkWindowed(text: []const u8, window: []u8, expected: []const u8) !base64.Counts {
    var decoder = base64.Decoder.init(window);
    var compared: usize = 0;
    var rest = text;
    while (rest.len != 0) {
        const piece = @min(rest.len, base64.Decoder.pieceFor(window.len));
        try decoder.update(rest[0..piece]);
        const bytes = decoder.take();
        try std.testing.expectEqualSlices(u8, expected[compared..][0..bytes.len], bytes);
        compared += bytes.len;
        rest = rest[piece..];
    }
    return decoder.finish();
}

test "[property] - [base64]: checks text far larger than its window with exact counts and errors" {
    var source: [10_000]u8 = undefined;
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    random.random().bytes(&source);
    var encoded: [13_336]u8 = undefined;
    const plain = try base64.encode(&encoded, &source);
    // XML text: the Base64 broken into lines of 76 characters.
    var text_buffer: [13_336 + 13_336 / 76 * 2]u8 = undefined;
    var text_length: usize = 0;
    for (plain, 0..) |byte, i| {
        if (i != 0 and i % 76 == 0) {
            @memcpy(text_buffer[text_length..][0..2], "\r\n");
            text_length += 2;
        }
        text_buffer[text_length] = byte;
        text_length += 1;
    }
    const text = text_buffer[0..text_length];
    var window: [48]u8 = undefined;
    try std.testing.expectEqual(base64.Counts{ .text_bytes = text.len, .significant_bytes = plain.len, .decoded_bytes = source.len }, try checkWindowed(text, &window, &source));

    // Errors far past the first window are found where they are, and stay.
    const bad = try std.testing.allocator.dupe(u8, text);
    defer std.testing.allocator.free(bad);
    bad[9_000] = '*';
    try std.testing.expectError(error.InvalidCharacter, checkWindowed(bad, &window, &source));
    @memcpy(bad, text);
    try std.testing.expectError(error.TruncatedInput, checkWindowed(bad[0 .. bad.len - 1], &window, &source));
    // 10,000 bytes end in one byte and "==": a set unused bit in the last character is refused.
    try std.testing.expectEqualStrings("==", text[text.len - 2 ..]);
    bad[bad.len - 3] = switch (text[text.len - 3]) {
        'A' => 'B',
        else => |byte| byte ^ 1,
    };
    try std.testing.expectError(error.NonCanonicalTail, checkWindowed(bad, &window, &source));
    var decoder = base64.Decoder.init(&window);
    try std.testing.expectError(error.InvalidCharacter, decoder.update("AAAA*"));
    try std.testing.expectError(error.FailedState, decoder.update("AAAA"));
}

test "[property] - [base64]: preserves all one-byte and two-byte inputs" {
    var input: [2]u8 = undefined;
    var encoded: [4]u8 = undefined;
    var decoded: [2]u8 = undefined;
    for (0..65536) |number| {
        std.mem.writeInt(u16, &input, @intCast(number), .little);
        const text = try base64.encode(&encoded, &input);
        var decoder = base64.Decoder.init(&decoded);
        for (text) |byte| try decoder.update(&.{byte});
        const counts = try decoder.finish();
        try std.testing.expectEqualSlices(u8, &input, decoded[0..counts.decoded_bytes]);
        if (number < 256) {
            const short = try base64.encode(&encoded, input[0..1]);
            try std.testing.expectEqualSlices(u8, input[0..1], try base64.decode(&decoded, short));
        }
    }
}

test "[property] - [base64]: bulk input matches quartet decoding at errors, capacities, and fragment splits" {
    var source: [384]u8 = undefined;
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    random.random().bytes(&source);
    var encoded: [512]u8 = undefined;
    const text = try base64.encode(&encoded, &source);
    for (0..source.len + 1) |len| {
        var buffer: [512]u8 = undefined;
        const short = try base64.encode(&buffer, source[0..len]);
        for ([_]usize{ 0, 1, 3, 31, 32, 33, 255, 256, 257, short.len }) |split| {
            if (split > short.len) continue;
            var output: [384]u8 = undefined;
            var decoder = base64.Decoder.init(&output);
            try decoder.update(short[0..split]);
            try decoder.update(short[split..]);
            const counts = try decoder.finish();
            try std.testing.expectEqualSlices(u8, source[0..len], output[0..counts.decoded_bytes]);
            try std.testing.expectEqualDeep(counts, try decodeWhole(short));
        }
    }
    for (0..text.len) |position| {
        for ([_]u8{ '=', ' ', '\t', '\r', '\n', '!', 0x80 }) |replacement| {
            var changed = encoded;
            changed[position] = replacement;
            try compareBase64Updates(&changed, source.len);
        }
        if (position <= source.len) try compareBase64Updates(text, position);
    }
    for ([_]usize{ 1, 3, 4, 7, 31, 32, 63, 64, 65, 75, 76, 77, 255, 256, 257 }) |width| {
        for ([_][]const u8{ "\n", "\r\n", " \t" }) |whitespace| {
            var wrapped: [1536]u8 = undefined;
            var used: usize = 0;
            for (text, 0..) |byte, i| {
                if (i != 0 and i % width == 0) {
                    @memcpy(wrapped[used..][0..whitespace.len], whitespace);
                    used += whitespace.len;
                }
                wrapped[used] = byte;
                used += 1;
            }
            try compareBase64Updates(wrapped[0..used], source.len);
            for ([_]usize{ 1, width - 1, width, width + 1, 31, 32, 33, 255, 256, 257, used }) |split| {
                if (split > used) continue;
                var output: [384]u8 = undefined;
                var decoder = base64.Decoder.init(&output);
                try decoder.update(wrapped[0..split]);
                try decoder.update(wrapped[split..used]);
                const counts = try decoder.finish();
                try std.testing.expectEqualSlices(u8, &source, &output);
                try std.testing.expectEqualDeep(counts, try decodeWhole(wrapped[0..used]));
            }
            for ([_]usize{ width - 1, width, width + whitespace.len, used - 1 }) |position| {
                for ([_]u8{ '=', '!', 0x80 }) |replacement| {
                    var changed = wrapped;
                    changed[position] = replacement;
                    try compareBase64Updates(changed[0..used], source.len);
                }
            }
            for ([_]usize{ 0, 1, 3, 31, 32, 33, 191, 192, 193, 383, 384 }) |capacity| {
                try compareBase64Updates(wrapped[0..used], capacity);
            }
        }
    }
}

fn compareBase64Updates(text: []const u8, capacity: usize) !void {
    var bulk_output: [384]u8 = undefined;
    var scalar_output: [384]u8 = undefined;
    var bulk = base64.Decoder.init(bulk_output[0..capacity]);
    var scalar = base64.Decoder.init(scalar_output[0..capacity]);
    const bulk_error: ?base64.Decoder.Error = result: {
        bulk.update(text) catch |err| break :result err;
        _ = bulk.finish() catch |err| break :result err;
        break :result null;
    };
    const scalar_error: ?base64.Decoder.Error = result: {
        for (text) |byte| scalar.update(&.{byte}) catch |err| break :result err;
        _ = scalar.finish() catch |err| break :result err;
        break :result null;
    };
    try std.testing.expectEqual(scalar_error, bulk_error);
    try std.testing.expectEqualDeep(scalar.counts, bulk.counts);
    if (bulk_error == null) try std.testing.expectEqualSlices(u8, scalar_output[0..scalar.counts.decoded_bytes], bulk_output[0..bulk.counts.decoded_bytes]);
}

// --- Zlib ---

test "[unit] - [zlib]: decodes independent stored and fixed Huffman streams" {
    // RFC 1950 wrapper around a stored DEFLATE block containing ASCII abc.
    const stored = "\x78\x01\x01\x03\x00\xfc\xffabc\x02\x4d\x01\x27";
    // Python zlib.compress(b"hello") produced this fixed-Huffman stream.
    const fixed = "\x78\x9c\xcb\x48\xcd\xc9\xc9\x07\x00\x06\x2c\x02\x15";
    var output: [16]u8 = undefined;
    try std.testing.expectEqualStrings("abc", try zlib.decompress(&output, stored));
    try std.testing.expectEqualStrings("hello", try zlib.decompress(&output, fixed));
}

test "[failure] - [zlib]: rejects truncation, corruption, trailing input, and aliasing" {
    const stored = "\x78\x01\x01\x03\x00\xfc\xffabc\x02\x4d\x01\x27";
    var output: [16]u8 = undefined;

    for (0..stored.len) |end| {
        try std.testing.expectError(error.TruncatedInput, zlib.decompress(&output, stored[0..end]));
    }
    try std.testing.expectError(error.OutputTooSmall, zlib.decompress(output[0..2], stored));
    try std.testing.expectError(error.TrailingInput, zlib.decompress(&output, stored ++ "x"));
    try std.testing.expectError(error.TrailingInput, zlib.decompress(&output, stored ++ stored));
    var corrupt = stored.*;
    corrupt[corrupt.len - 1] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, zlib.decompress(&output, &corrupt));
    corrupt[0] = 0;
    try std.testing.expectError(error.InvalidData, zlib.decompress(&output, &corrupt));
    try std.testing.expectError(error.UnsupportedDictionary, zlib.decompress(&output, "\x78\x20"));
    try std.testing.expectError(error.OverlappingBuffers, zlib.decompress(&corrupt, &corrupt));
}

test "[edge] - [zlib]: decodes streams declaring 31 or 32 unused distance codes" {
    // One dynamic block holding "a", with literal lengths for 'a' and end of block and one distance
    // code of length 1 then zeros, so only HDIST differs. Built bit by bit. zlib rejects 31 and 32
    // as too many distance symbols; codes 30 and 31 never occur, and none is used.
    const thirty = "\x78\x01\x05\xdd\x21\x01\x00\x00\x00\x00\x90\xad\xfe\x9f\x60\x89\x00\x62\x00\x62";
    const thirty_one = "\x78\x01\x05\xde\x21\x01\x00\x00\x00\x00\x90\xad\xfe\x9f\xe0\x89\x00\x62\x00\x62";
    const thirty_two = "\x78\x01\x05\xdf\x21\x01\x00\x00\x00\x00\x90\xad\xfe\x9f\x60\x8a\x00\x62\x00\x62";
    var output: [4]u8 = undefined;
    inline for (.{ thirty, thirty_one, thirty_two }) |stream| {
        try std.testing.expectEqualStrings("a", try zlib.decompress(&output, stream));
    }
}

test "[edge] - [zlib]: treats empty slices inside the other buffer as disjoint" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectError(error.TruncatedInput, zlib.decompress(buffer[0..16], buffer[4..4]));
    // Python's zlib.compress(b"") and the stored "abc" stream, each with an empty output inside it.
    const empty = "\x78\x9c\x03\x00\x00\x00\x00\x01";
    @memcpy(buffer[0..empty.len], empty);
    try std.testing.expectEqual(@as(usize, 0), (try zlib.decompress(buffer[4..4], buffer[0..empty.len])).len);
    const stored = "\x78\x01\x01\x03\x00\xfc\xffabc\x02\x4d\x01\x27";
    @memcpy(buffer[0..stored.len], stored);
    try std.testing.expectError(error.OutputTooSmall, zlib.decompress(buffer[4..4], buffer[0..stored.len]));
}

test "[property] - [zlib]: decodes exact outputs around loop, staging, and window boundaries" {
    var compressor = try zlib.Compressor.init(std.testing.allocator, .even);
    defer compressor.deinit();
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    // A random window followed by a copy of its start can only be coded with 32,768-byte distances.
    var source: [32768 + 4096]u8 = undefined;
    random.random().bytes(source[0..32768]);
    @memcpy(source[32768..], source[0..4096]);
    var compressed: [source.len + 1024]u8 = undefined;
    var reference: [source.len]u8 = undefined;
    var output: [source.len + 1]u8 = undefined;
    const far = try compressor.compress(&compressed, &source);
    try std.testing.expect(far.len < 32768 + 2048);
    try expectExactDecode(&source, far, &output, &reference);
    // A random 251-byte head repeated: literals, then matches running to each output's end.
    for ([_]usize{ 288, 289, 290, 16383, 16384, 16385 }) |len| {
        const plain = source[0..len];
        random.random().bytes(plain[0..251]);
        for (plain[251..], 251..) |*byte, index| byte.* = plain[index - 251];
        try expectExactDecode(plain, try compressor.compress(&compressed, plain), &output, &reference);
    }
}

fn expectExactDecode(plain: []const u8, wire: []const u8, output: []u8, reference: []u8) !void {
    try std.testing.expectEqualSlices(u8, plain, try decompressReference(reference, wire));
    try std.testing.expectEqualSlices(u8, plain, try zlib.decompress(output[0..plain.len], wire));
    try std.testing.expectEqualSlices(u8, plain, try zlib.decompress(output[0 .. plain.len + 1], wire));
    try std.testing.expectError(error.OutputTooSmall, zlib.decompress(output[0 .. plain.len - 1], wire));
}

test "[property] - [zlib]: reuses compression storage after success and capacity failure" {
    var source: [70_000]u8 = undefined;
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    random.random().bytes(&source);
    var compressed: [72_000]u8 = undefined;
    var decoded: [source.len]u8 = undefined;
    inline for (.{ zlib.Preset.fast, .even, .dense }) |preset| {
        var compressor = try zlib.Compressor.init(std.testing.allocator, preset);
        defer compressor.deinit();
        for ([_]usize{ 0, 1, 31, 32768, source.len }) |len| {
            const wire = try compressor.compress(&compressed, source[0..len]);
            try std.testing.expectEqualSlices(
                u8,
                source[0..len],
                try zlib.decompress(decoded[0..len], wire),
            );
            try std.testing.expectError(
                error.OutputTooSmall,
                compressor.compress(compressed[0..0], source[0..len]),
            );
        }
    }
}

test "[property] - [zlib]: incompressible input fits the compression bound" {
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    const source = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(source);
    random.random().bytes(source);
    const output = try std.testing.allocator.alloc(u8, zlib.compressBound(source.len));
    defer std.testing.allocator.free(output);
    inline for (.{ zlib.Preset.fast, .even, .dense }) |preset| {
        var compressor = try zlib.Compressor.init(std.testing.allocator, preset);
        defer compressor.deinit();
        for ([_]usize{ 0, 1, 31, 32767, 32768, 32769, 65535, 65536, 65537, 131073, source.len }) |len| {
            _ = try compressor.compress(output[0..zlib.compressBound(len)], source[0..len]);
        }
    }
}

test "[failure] - [zlib]: streaming calls out of order fail with InvalidState" {
    var decompressor = try zlib.Decompressor.init(std.testing.allocator);
    defer decompressor.deinit();
    var window: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidState, decompressor.next(16));
    try std.testing.expectError(error.InvalidState, decompressor.read(&window));

    var compressor = try zlib.Compressor.init(std.testing.allocator, .fast);
    defer compressor.deinit();
    try std.testing.expectError(error.InvalidState, compressor.finish());
    try std.testing.expectError(error.InvalidState, compressor.finishWriter());
    var output: [64]u8 = undefined;
    _ = try compressor.start(&output);
    _ = try compressor.finish();
    try std.testing.expectError(error.InvalidState, compressor.finish());
    // finish returns start's output, which a startWriter stream does not have.
    var sink = std.Io.Writer.fixed(&output);
    _ = try compressor.startWriter(&sink);
    try std.testing.expectError(error.InvalidState, compressor.finish());
    try compressor.finishWriter();
    try std.testing.expectError(error.InvalidState, compressor.finishWriter());
}

test "[failure] - [zlib]: a one-call compression that runs out of output is closed" {
    var compressor = try zlib.Compressor.init(std.testing.allocator, .fast);
    defer compressor.deinit();
    // Incompressible input fills the output while it is written, before the stream ends.
    const source = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(source);
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    random.random().bytes(source);
    var output: [64]u8 = undefined;
    try std.testing.expectError(error.OutputTooSmall, compressor.compress(&output, source));
    try std.testing.expectError(error.InvalidState, compressor.finish());
    const stream = try compressor.compress(&output, "abc");
    var plain: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", try zlib.decompress(&plain, stream));
}

test "[integration] - [array encoder]: a stream whose source failed is closed" {
    var encoder = arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    const bad = [_]f64{ 1, -1 };
    const options: arrays.EncodeOptions = .{ .pipeline = .linear_zlib, .fixed_point = 1 };
    try std.testing.expectError(error.InvalidValue, encoder.encode(f64, &bad, options));
    const compressor = try encoder.compressor();
    try std.testing.expectError(error.InvalidState, compressor.finish());
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.InvalidValue, arrays.Source.of(f64, &bad, options, &encoder).writeTo(&discard.writer));
    try std.testing.expectError(error.InvalidState, compressor.finishWriter());
    // A failed start leaves no earlier stream open either.
    var output: [64]u8 = undefined;
    _ = try compressor.start(&output);
    try std.testing.expectError(error.OutputTooSmall, compressor.start(output[0..1]));
    try std.testing.expectError(error.InvalidState, compressor.finish());
}

fn allocateCompressor(allocator: std.mem.Allocator) !void {
    var compressor = try zlib.Compressor.init(allocator, .even);
    defer compressor.deinit();
    var output: [64]u8 = undefined;
    _ = try compressor.compress(&output, "abc");
}

test "[failure] - [zlib]: releases partially allocated compression storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateCompressor, .{});
}

test "[property] - [zlib]: matches valid streaming output and bounds corrupt or truncated streams" {
    var compressor = try zlib.Compressor.init(std.testing.allocator, .even);
    defer compressor.deinit();
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    var source: [2048]u8 = undefined;
    var compressed: [4096]u8 = undefined;
    var reference: [4096]u8 = undefined;
    var actual: [4096]u8 = undefined;
    for (0..4) |shape| {
        random.random().bytes(&source);
        for (&source, 0..) |*byte, index| byte.* = switch (shape) {
            0 => byte.*,
            1 => @intCast(index % 3),
            2 => if (index % 100 < 99) 'a' else byte.*,
            else => byte.* & 15,
        };
        const wire = try compressor.compress(&compressed, &source);
        try std.testing.expectEqualSlices(u8, &source, try decompressReference(&reference, wire));
        try std.testing.expectEqualSlices(u8, &source, try zlib.decompress(&actual, wire));
        for (0..wire.len) |position| {
            const original = wire[position];
            for ([_]u8{ 0, 1, 0x80, 0xff }) |mask| {
                wire[position] = original ^ mask;
                const observed = zlib.decompress(&actual, wire);
                // HACK: Zig 0.16's std inflate can panic on malformed short-bit tails, so it is the
                // reference only for successful streams; compare errors too once std is fixed.
                if (observed) |bytes| {
                    try std.testing.expectEqualSlices(u8, try decompressReference(&reference, wire), bytes);
                } else |failure| switch (failure) {
                    error.InvalidData,
                    error.TruncatedInput,
                    error.ChecksumMismatch,
                    error.TrailingInput,
                    error.UnsupportedDictionary,
                    error.OutputTooSmall,
                    => {},
                    else => return failure,
                }
            }
            wire[position] = original;
            try std.testing.expectError(error.TruncatedInput, zlib.decompress(&actual, wire[0..position]));
        }
    }
}

test "[property] - [zlib]: streamed inflation matches whole-stream results and errors" {
    var compressor = try zlib.Compressor.init(std.testing.allocator, .even);
    defer compressor.deinit();
    var decompressor = try zlib.Decompressor.init(std.testing.allocator);
    defer decompressor.deinit();
    var random = std.Random.DefaultPrng.init(0x7a6c_6962_5354_524d);
    var source: [3000]u8 = undefined;
    var compressed: [4096]u8 = undefined;
    var whole: [source.len + 64]u8 = undefined;
    // One byte more than whole, so a stream that outgrows whole shows as OutputTooSmall.
    var streamed: [whole.len + 1]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = if (index % 50 < 45) @intCast(index % 7) else random.random().int(u8);
    const valid = try compressor.compress(&compressed, &source);
    for (0..valid.len + 1) |position| {
        for ([_]u8{ 0, 1, 0x80, 0xff }) |mask| {
            const wire = compressed[0..if (mask == 0) position else valid.len];
            if (mask != 0 and position < valid.len) wire[position] ^= mask;
            defer if (mask != 0 and position < valid.len) {
                wire[position] ^= mask;
            };
            const expected = zlib.decompress(&whole, wire);
            for ([_]usize{ 1, 100, 4096 }) |window| {
                decompressor.start(wire);
                var total: usize = 0;
                const actual = while (true) {
                    if (total > whole.len) break error.OutputTooSmall;
                    const piece = (decompressor.read(streamed[total..][0..@min(window, streamed.len - total)]) catch |err| break err) orelse break total;
                    total += piece.len;
                };
                if (expected) |bytes| {
                    try std.testing.expectEqual(bytes.len, try actual);
                    try std.testing.expectEqualSlices(u8, bytes, streamed[0..total]);
                } else |err| try std.testing.expectError(err, actual);
            }
        }
    }
}

test "[property] - [zlib]: split writer input and split reader input match one-call results and errors" {
    var compressor = try zlib.Compressor.init(std.testing.allocator, .even);
    defer compressor.deinit();
    var decompressor = try zlib.Decompressor.init(std.testing.allocator);
    defer decompressor.deinit();
    var prng = std.Random.DefaultPrng.init(0x7370_6c69_7473_7472);
    const random = prng.random();
    var source: [3000]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = if (index % 50 < 45) @intCast(index % 7) else random.int(u8);
    var compressed: [4096]u8 = undefined;
    const valid = try compressor.compress(&compressed, &source);
    for (0..8) |_| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        const writer = try compressor.startWriter(&output.writer);
        var rest: []const u8 = &source;
        while (rest.len != 0) {
            const piece = @min(rest.len, 1 + random.uintLessThan(usize, 600));
            try writer.writeAll(rest[0..piece]);
            rest = rest[piece..];
        }
        try compressor.finishWriter();
        try std.testing.expectEqualSlices(u8, valid, output.written());
    }
    var whole: [source.len + 64]u8 = undefined;
    var streamed: [whole.len]u8 = undefined;
    // The valid stream, cut short at each tested length, and with a bit flipped in the header,
    // the body, and the checksum.
    for ([_]usize{ valid.len, 0, 1, valid.len / 2, valid.len - 1 }) |length| {
        for ([_]?usize{ null, 0, valid.len / 2, valid.len - 2 }) |flipped| {
            if (flipped != null and length != valid.len) continue;
            const wire = compressed[0..length];
            if (flipped) |position| wire[position] ^= 0x80;
            defer if (flipped) |position| {
                wire[position] ^= 0x80;
            };
            const expected = zlib.decompress(&whole, wire);
            for ([_]usize{ 1, 7 }) |limit| {
                var buffer: [64]u8 = undefined;
                var input: std.testing.Reader = .init(&buffer, &.{.{ .buffer = wire }});
                input.artificial_limit = .limited(limit);
                decompressor.startReader(&input.interface);
                var total: usize = 0;
                const actual: zlib.Decompressor.Error!usize = while (true) {
                    const piece = (decompressor.next(1 + random.uintLessThan(usize, 300)) catch |err| break err) orelse break total;
                    if (piece.len > streamed.len - total) break error.OutputTooSmall;
                    @memcpy(streamed[total..][0..piece.len], piece);
                    total += piece.len;
                };
                if (expected) |bytes| {
                    try std.testing.expectEqual(bytes.len, try actual);
                    try std.testing.expectEqualSlices(u8, bytes, streamed[0..total]);
                } else |err| try std.testing.expectError(err, actual);
            }
        }
    }
}

fn decompressReference(output: []u8, source: []const u8) zlib.DecompressError![]u8 {
    if (source.len < 2) return error.TruncatedInput;
    const header = std.mem.readInt(u16, source[0..2], .big);
    if (source[0] & 15 != 8 or source[0] >> 4 > 7 or header % 31 != 0) return error.InvalidData;
    if (source[1] & 32 != 0) return error.UnsupportedDictionary;
    var input = std.Io.Reader.fixed(source);
    var destination = std.Io.Writer.fixed(output);
    var decoder: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    _ = decoder.reader.streamRemaining(&destination) catch |failure| switch (failure) {
        error.WriteFailed => return error.OutputTooSmall,
        error.ReadFailed => {
            if (decoder.err) |cause| if (cause == error.EndOfStream) return error.TruncatedInput;
            return error.InvalidData;
        },
    };
    if (input.seek != source.len) return error.TrailingInput;
    const result = destination.buffered();
    if (std.hash.Adler32.hash(result) != decoder.container_metadata.zlib.adler) return error.ChecksumMismatch;
    return result;
}

// --- Array composition ---

test "[integration] - [arrays]: matches fixed little-endian Base64 vectors" {
    // Fixed byte vectors are independent of the array encoder and decoder.
    const cases = .{
        .{ f32, [_]f32{1}, "AACAPw==" },
        .{ f64, [_]f64{ 1, -0.0, std.math.inf(f64) }, "AAAAAAAA8D8AAAAAAAAAgAAAAAAAAPB/" },
        .{ i32, [_]i32{0x01020304}, "BAMCAQ==" },
        .{ i64, [_]i64{0x0102030405060708}, "CAcGBQQDAgE=" },
    };
    var transport: [128]u8 = undefined;
    var transformed: [128]u8 = undefined;
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var encoded: [128]u8 = undefined;

    inline for (cases) |case| {
        const T = case[0];
        const expected = case[1];
        var output: [expected.len]T = undefined;
        try arrays.decode(T, &output, case[2], .none, .{ .transport = &.{}, .transformed = &.{} });
        try std.testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(&expected),
            std.mem.sliceAsBytes(&output),
        );
        const wire = try arrays.encode(T, &encoded, &expected, .{}, scratch, null);
        try std.testing.expectEqualStrings(case[2], wire);
        const prepared = try arrays.encodeWire(T, &expected, .{}, .{ .transport = &.{}, .transformed = &transformed }, null);
        try std.testing.expectEqualStrings(case[2], try base64.encode(&encoded, prepared));
        @memset(std.mem.sliceAsBytes(&output), 0xa5);
        try arrays.decodeWire(T, &output, prepared, .none, &.{});
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), std.mem.sliceAsBytes(&output));
        @memcpy(std.mem.sliceAsBytes(&output), prepared);
        try arrays.decodeWire(T, &output, std.mem.sliceAsBytes(&output), .none, &.{});
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), std.mem.sliceAsBytes(&output));
        if (builtin.cpu.arch.endian() == .little) {
            const borrowed = try arrays.encodeWire(T, &expected, .{}, .{ .transport = &.{}, .transformed = &.{} }, null);
            try std.testing.expectEqual(@intFromPtr(expected[0..].ptr), @intFromPtr(borrowed.ptr));
        }
        // A zlib envelope can decode into typed output without transformed scratch.
        var compressor = try zlib.Compressor.init(std.testing.allocator, .even);
        defer compressor.deinit();
        const compressed = try arrays.encode(T, &encoded, &expected, .{ .pipeline = .zlib }, scratch, &compressor);
        try arrays.decode(T, &output, compressed, .zlib, .{ .transport = &transport, .transformed = &.{} });
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), std.mem.sliceAsBytes(&output));
    }
}

test "[failure] - [arrays]: rejects overlap, type, size, and limit errors" {
    var output: [4]u64 = undefined;
    const bytes = std.mem.sliceAsBytes(&output);
    const source = [_]u8{ 4, 3, 2, 1 };
    var values: [1]i32 = undefined;
    try arrays.decodeWire(i32, &values, &source, .none, &.{});
    try std.testing.expectEqual(@as(i32, 0x01020304), values[0]);
    try std.testing.expectError(error.OverlappingBuffers, arrays.decodeWire(i64, std.mem.bytesAsSlice(i64, bytes)[0..1], bytes[1..9], .none, &.{}));
    try std.testing.expectError(error.OverlappingBuffers, arrays.decodeWire(i64, std.mem.bytesAsSlice(i64, bytes)[0..1], bytes[0..8], .zlib, &.{}));
    try std.testing.expectError(error.OverlappingBuffers, arrays.decodeWire(i64, std.mem.bytesAsSlice(i64, bytes)[0..1], bytes[0..16], .none, bytes[8..16]));
    try std.testing.expectError(error.DecodedSizeMismatch, arrays.decodeWire(i32, &values, source[0..3], .none, &.{}));
    try std.testing.expectError(error.TypeMismatch, arrays.decodeWire(i32, &values, &source, .pic, &.{}));
}

fn expectSlofBound(expected: []const f64, actual: []const f64, fixed_point: f64) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    const relative_bound = @exp(0.5 / fixed_point) - 1.0;
    for (expected, actual) |value, decoded| {
        if (value == 0) {
            try std.testing.expectEqual(@as(f64, 0), decoded);
        } else {
            try std.testing.expect(
                @abs(decoded - value) / (value + 1) <= relative_bound * 1.000001,
            );
        }
    }
}

test "[integration] - [arrays]: decodes a frozen zlib envelope" {
    var transport: [128]u8 = undefined;
    var transformed: [128]u8 = undefined;
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var output: [3]f64 = undefined;

    // Frozen Numpress vector with fixed point 4000, wrapped by Python zlib and Base64.
    try arrays.decode(f64, &output, "eJxzWO/AAAFXuSpUARP4Aqw=", .slof_zlib, scratch);
    try expectSlofBound(&.{ 0, 1, 10 }, &output, 4000);
}

test "[property] - [arrays]: preserves single-bit patterns, zeros, and all-one bits" {
    var transport: [2048]u8 = undefined;
    var transformed: [2048]u8 = undefined;
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var encoded: [4096]u8 = undefined;
    var compressor = try zlib.Compressor.init(std.testing.allocator, .even);
    defer compressor.deinit();
    inline for (.{ f32, f64, i32, i64 }) |T| {
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        var values: [@bitSizeOf(T) + 2]T = undefined;
        var output: [values.len]T = undefined;
        for (values[0..@bitSizeOf(T)], 0..) |*value, bit| {
            value.* = @bitCast(@as(Bits, 1) << @intCast(bit));
        }
        values[@bitSizeOf(T)] = @bitCast(@as(Bits, 0));
        values[@bitSizeOf(T) + 1] = @bitCast(@as(Bits, std.math.maxInt(Bits)));
        inline for (.{ arrays.Pipeline.none, .zlib }) |pipeline| {
            const wire = try arrays.encode(T, &encoded, &values, .{ .pipeline = pipeline }, scratch, &compressor);
            try arrays.decode(T, &output, wire, pipeline, scratch);
            try std.testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(&values),
                std.mem.sliceAsBytes(&output),
            );
        }
    }
}

test "[integration] - [arrays]: composes all Numpress modes with optional zlib" {
    var transport: [256]u8 = undefined;
    var transformed: [256]u8 = undefined;
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var encoded: [512]u8 = undefined;
    var output: [4]f64 = undefined;
    const values = [_]f64{ 0, 1.25, 10.5, 100.125 };
    var compressor = try zlib.Compressor.init(std.testing.allocator, .even);
    defer compressor.deinit();
    inline for (.{
        arrays.Pipeline.linear, .pic, .slof, .linear_zlib, .pic_zlib, .slof_zlib,
    }) |pipeline| {
        const fixed_point: ?f64 = switch (pipeline) {
            .pic, .pic_zlib => null,
            else => 4000,
        };
        const wire = try arrays.encode(f64, &encoded, &values, .{
            .pipeline = pipeline,
            .fixed_point = fixed_point,
        }, scratch, &compressor);
        const prepared = try arrays.encodeWire(f64, &values, .{
            .pipeline = pipeline,
            .fixed_point = fixed_point,
        }, scratch, &compressor);
        var encoded_wire: [512]u8 = undefined;
        try std.testing.expectEqualStrings(wire, try base64.encode(&encoded_wire, prepared));
        try arrays.decode(f64, &output, wire, pipeline, scratch);
        switch (pipeline) {
            .pic, .pic_zlib => try std.testing.expectEqualSlices(f64, &.{ 0, 1, 11, 100 }, &output),
            .linear, .linear_zlib => {
                for (values, output) |expected, actual|
                    try std.testing.expectApproxEqAbs(expected, actual, 0.5 / fixed_point.?);
            },
            .slof, .slof_zlib => try expectSlofBound(&values, &output, fixed_point.?),
            else => unreachable,
        }
    }
}

test "[failure] - [arrays]: rejects invalid configuration and aliasing" {
    var transport: [128]u8 = undefined;
    var transformed: [128]u8 = undefined;
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var encoded: [128]u8 = undefined;
    const values = [_]f64{1};

    try std.testing.expectError(
        error.MissingFixedPoint,
        arrays.encode(f64, &encoded, &values, .{ .pipeline = .linear }, scratch, null),
    );
    try std.testing.expectError(
        error.UnexpectedFixedPoint,
        arrays.encode(f64, &encoded, &values, .{ .fixed_point = 1 }, scratch, null),
    );
    try std.testing.expectError(
        error.MissingCompressor,
        arrays.encode(f64, &encoded, &values, .{ .pipeline = .zlib }, scratch, null),
    );
    try std.testing.expectError(
        error.OverlappingBuffers,
        arrays.encode(f64, &transport, &values, .{}, scratch, null),
    );
    var floats: [4]f32 = undefined;
    try std.testing.expectError(
        error.TypeMismatch,
        arrays.decode(f32, &floats, "", .pic, scratch),
    );
}

test "[failure] - [arrays]: rejects short scratch and mismatched counts" {
    var transport: [128]u8 = undefined;
    var transformed: [128]u8 = undefined;
    var output: [3]f64 = undefined;
    const source = "eJxzWO/AAAFXuSpUARP4Aqw=";
    try std.testing.expectError(error.OutputTooSmall, arrays.decode(f64, &output, source, .slof_zlib, .{
        .transport = transport[0..1],
        .transformed = &transformed,
    }));
    try std.testing.expectError(error.OutputTooSmall, arrays.decode(f64, &output, source, .slof_zlib, .{
        .transport = &transport,
        .transformed = transformed[0..1],
    }));
}

test "[failure] - [arrays]: returns DecodedSizeMismatch when a stream outgrows its declared values" {
    // Python's zlib.compress of the little-endian doubles 1 and 2.
    const two = "eJxjYACBD/YMEOAAAAvnAXA=";
    var transport: [64]u8 = undefined;
    var transformed: [64]u8 = undefined;
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var output: [3]f64 = undefined;
    try arrays.decode(f64, output[0..2], two, .zlib, scratch);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, output[0..2]);
    try std.testing.expectError(error.DecodedSizeMismatch, arrays.decode(f64, output[0..1], two, .zlib, scratch));
    try std.testing.expectError(error.DecodedSizeMismatch, arrays.decode(f64, &output, two, .zlib, scratch));
    try std.testing.expectError(error.DecodedSizeMismatch, arrays.decodeWire(f64, output[0..1], try base64.decode(&transport, two), .zlib, &.{}));
    // Three SLOF values exceed the wire bound of one.
    try std.testing.expectError(error.DecodedSizeMismatch, arrays.decode(f64, output[0..1], "eJxzWO/AAAFXuSpUARP4Aqw=", .slof_zlib, scratch));
}

test "[failure] - [array sources]: writeTo checks options before writing a byte" {
    var output: [64]u8 = undefined;
    const cases = .{
        .{ arrays.Source.of(i32, &.{ 1, 2 }, .{ .pipeline = .pic }, null), error.TypeMismatch },
        .{ arrays.Source.of(f64, &.{ 1, 2 }, .{ .pipeline = .linear, .fixed_point = 0 }, null), error.InvalidFixedPoint },
        .{ arrays.Source.of(f64, &.{ 1, 2 }, .{ .pipeline = .slof, .fixed_point = std.math.nan(f64) }, null), error.InvalidFixedPoint },
        .{ arrays.Source.of(f64, &.{1}, .{ .pipeline = .zlib }, null), error.MissingCompressor },
    };
    inline for (cases) |case| {
        var writer = std.Io.Writer.fixed(&output);
        try std.testing.expectError(case[1], case[0].check());
        try std.testing.expectError(case[1], case[0].writeTo(&writer));
        try std.testing.expectEqual(@as(usize, 0), writer.end);
    }
}

test "[failure] - [array sources]: values inside the destination's buffer are refused" {
    var buffer: [64]f64 = undefined;
    @memset(&buffer, 1);
    var writer = std.Io.Writer.fixed(std.mem.sliceAsBytes(&buffer));
    const values = buffer[32..40];
    try std.testing.expectError(error.OverlappingBuffers, arrays.Source.of(f64, values, .{}, null).writeTo(&writer));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "[failure] - [arrays]: too many Numpress values are the file's fault at any scratch size" {
    var encoded: [128]u8 = undefined;
    var wire: [64]u8 = undefined;
    const many = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const text = try base64.encode(&encoded, wire[0..try mzml.numpress.encodePic(&many, &wire)]);
    var output: [1]f64 = undefined;
    const bound = try arrays.wireBound(f64, output.len, .pic);
    var transport: [64]u8 = undefined;
    for ([_]usize{ bound, bound + 1, transport.len }) |size| {
        try std.testing.expectError(error.DecodedSizeMismatch, arrays.decode(f64, &output, text, .pic, .{ .transport = transport[0..size], .transformed = &.{} }));
    }
    // Scratch below the bound is the caller's.
    try std.testing.expectError(error.OutputTooSmall, arrays.decode(f64, &output, text, .pic, .{ .transport = transport[0 .. bound - 1], .transformed = &.{} }));
}

test "[integration] - [array encoder]: keeps every wire until reset for all pipelines" {
    var encoder = arrays.Encoder.init(std.testing.allocator, .even);
    defer encoder.deinit();
    const values = [_]f64{ 0, 1.25, 10.5, 100.125 };
    var wires: [std.meta.tags(arrays.Pipeline).len][]const u8 = undefined;
    inline for (std.meta.tags(arrays.Pipeline), 0..) |pipeline, i| {
        const fixed_point: ?f64 = switch (pipeline) {
            .linear, .linear_zlib => 1000,
            .slof, .slof_zlib => 10000,
            else => null,
        };
        wires[i] = try encoder.encode(f64, &values, .{ .pipeline = pipeline, .fixed_point = fixed_point });
    }
    var transformed: [512]u8 = undefined;
    inline for (std.meta.tags(arrays.Pipeline), 0..) |pipeline, i| {
        var output: [values.len]f64 = undefined;
        try arrays.decodeWire(f64, &output, wires[i], pipeline, &transformed);
        if (pipeline == .none or pipeline == .zlib) try std.testing.expectEqualSlices(f64, &values, &output);
        if (pipeline == .pic or pipeline == .pic_zlib) try std.testing.expectEqualSlices(f64, &.{ 0, 1, 11, 100 }, &output);
        // Linear rounds each value to 1/1000.
        if (pipeline == .linear or pipeline == .linear_zlib)
            for (values, output) |value, decoded| try std.testing.expectApproxEqAbs(value, decoded, 0.5 / 1000.0);
        if (pipeline == .slof or pipeline == .slof_zlib) try expectSlofBound(&values, &output, 10000);
    }
    if (builtin.cpu.arch.endian() == .little)
        try std.testing.expectEqual(@intFromPtr(&values), @intFromPtr(wires[0].ptr));
    encoder.reset();
    inline for (.{ f32, i32, i64 }) |T| {
        const typed = [_]T{ 1, 2, 3 };
        var output: [3]T = undefined;
        try arrays.decodeWire(T, &output, try encoder.encode(T, &typed, .{ .pipeline = .zlib }), .zlib, &.{});
        try std.testing.expectEqualSlices(T, &typed, &output);
    }
}

test "[property] - [array encoder]: streamed zlib matches encoding whole then compressing" {
    var encoder = arrays.Encoder.init(std.testing.allocator, .even);
    defer encoder.deinit();
    var compressor = try zlib.Compressor.init(std.testing.allocator, .even);
    defer compressor.deinit();
    var values: [5_000]f64 = undefined;
    var current: f64 = 100;
    var random = std.Random.DefaultPrng.init(0x656e_636f_6465_7273);
    for (&values) |*value| {
        current += random.random().float(f64) * 3;
        value.* = current;
    }
    const transformed = try std.testing.allocator.alloc(u8, 8 * values.len + 32);
    defer std.testing.allocator.free(transformed);
    const transport = try std.testing.allocator.alloc(u8, zlib.compressBound(transformed.len));
    defer std.testing.allocator.free(transport);
    const pairs = [_][2]arrays.Pipeline{
        .{ .zlib, .none }, .{ .linear_zlib, .linear }, .{ .pic_zlib, .pic }, .{ .slof_zlib, .slof },
    };
    for ([_]?f64{ null, -1 }) |invalid| {
        if (invalid) |bad| values[values.len / 2] = bad;
        for (pairs) |pair| {
            for ([_]?f64{ null, 1000 }) |fixed_point| {
                encoder.reset();
                const actual = encoder.encode(f64, &values, .{ .pipeline = pair[0], .fixed_point = fixed_point });
                const plain = arrays.encodeWire(f64, &values, .{ .pipeline = pair[1], .fixed_point = fixed_point }, .{ .transport = &.{}, .transformed = transformed }, null);
                if (plain) |bytes| {
                    try std.testing.expectEqualSlices(u8, try compressor.compress(transport, bytes), try actual);
                } else |err| try std.testing.expectError(err, actual);
            }
        }
    }
}

test "[property] - [array encoder]: f32 Numpress input matches its f64 copy and decodes to f64" {
    var encoder = arrays.Encoder.init(std.testing.allocator, .even);
    defer encoder.deinit();
    var narrow: [3_000]f32 = undefined;
    var wide: [narrow.len]f64 = undefined;
    var current: f32 = 100;
    var random = std.Random.DefaultPrng.init(0x6633_3220_6172_7279);
    for (&narrow, &wide) |*n, *w| {
        current += random.random().float(f32) * 2;
        n.* = current;
        w.* = current;
    }
    var transformed: [16 + 9 * narrow.len / 2 + 16]u8 = undefined;
    for ([_]arrays.Pipeline{ .linear, .pic, .slof, .linear_zlib, .pic_zlib, .slof_zlib }) |pipeline| {
        const fixed_point: ?f64 = if (pipeline.transform()) |transform| switch (transform) {
            .linear => try mzml.numpress.optimalLinearFixedPoint(&narrow),
            .slof => try mzml.numpress.optimalSlofFixedPoint(&narrow),
            .pic => null,
        } else null;
        encoder.reset();
        const options: arrays.EncodeOptions = .{ .pipeline = pipeline, .fixed_point = fixed_point };
        const from_narrow = try encoder.encode(f32, &narrow, options);
        const from_wide = try encoder.encode(f64, &wide, options);
        try std.testing.expectEqualSlices(u8, from_wide, from_narrow);
        var decoded: [narrow.len]f64 = undefined;
        try arrays.decodeWire(f64, &decoded, from_narrow, pipeline, &transformed);
        // PIC rounds to integers; the chosen Linear and SLOF fixed points keep far finer steps.
        for (wide, decoded) |value, output| {
            if (pipeline.transform().? == .pic)
                try std.testing.expectApproxEqAbs(value, output, 0.5)
            else
                try std.testing.expectApproxEqRel(value, output, 1e-4);
        }
        var narrow_output: [narrow.len]f32 = undefined;
        try std.testing.expectError(error.TypeMismatch, arrays.decodeWire(f32, &narrow_output, from_narrow, pipeline, &transformed));
    }
}

test "[property] - [array encoder]: round trips incompressible random arrays through zlib" {
    var encoder = arrays.Encoder.init(std.testing.allocator, .dense);
    defer encoder.deinit();
    const values = try std.testing.allocator.alloc(u64, 12_500);
    defer std.testing.allocator.free(values);
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    random.random().bytes(std.mem.sliceAsBytes(values));
    const numbers: []const i64 = @ptrCast(values);
    const wire = try encoder.encode(i64, numbers, .{ .pipeline = .zlib });
    const output = try std.testing.allocator.alloc(i64, numbers.len);
    defer std.testing.allocator.free(output);
    try arrays.decodeWire(i64, output, wire, .zlib, &.{});
    try std.testing.expectEqualSlices(i64, numbers, output);
}

fn encodeAllocated(allocator: std.mem.Allocator) !void {
    var encoder = arrays.Encoder.init(allocator, .fast);
    defer encoder.deinit();
    _ = try encoder.encode(f64, &.{ 1, 2, 3 }, .{ .pipeline = .slof_zlib, .fixed_point = 10000 });
    _ = try encoder.encode(f64, &.{ 1, 2, 3 }, .{ .pipeline = .linear, .fixed_point = 1000 });
}

test "[failure] - [array encoder]: refuses bad options before allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var encoder = arrays.Encoder.init(failing.allocator(), .fast);
    defer encoder.deinit();
    try std.testing.expectError(error.MissingFixedPoint, encoder.encode(f64, &.{1}, .{ .pipeline = .linear_zlib }));
    try std.testing.expectError(error.MissingFixedPoint, encoder.encode(f64, &.{1}, .{ .pipeline = .linear }));
    try std.testing.expectError(error.TypeMismatch, encoder.encode(i32, &.{1}, .{ .pipeline = .pic_zlib }));
    try std.testing.expectEqual(0, failing.allocations);
}

test "[failure] - [array encoder]: releases storage after allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, encodeAllocated, .{});
}

test "[integration] - [arrays]: reports the first decode error without rescanning" {
    const scratch: arrays.Scratch = .{ .transport = &.{}, .transformed = &.{} };
    var output: [2]i32 = undefined;
    try arrays.decode(i32, output[0..1], " B\tAMC\rAQ==\n", .none, scratch);
    try std.testing.expectEqual(@as(i32, 0x01020304), output[0]);
    try arrays.decode(i32, output[0..0], " \n", .none, scratch);
    try std.testing.expectError(error.DecodedSizeMismatch, arrays.decode(i32, &output, "BAMCAQ==", .none, scratch));
    try std.testing.expectError(error.DecodedSizeMismatch, arrays.decode(i32, output[0..0], "BAMCAQ==", .none, scratch));
    try std.testing.expectError(error.DecodedSizeMismatch, arrays.decode(i32, output[0..1], "BAMCAQAAAAAA", .none, scratch));
    try std.testing.expectError(error.DecodedSizeMismatch, arrays.decode(i32, output[0..1], "BAMCAQAAAAAA!", .none, scratch));
    try std.testing.expectError(error.DecodedSizeMismatch, arrays.decode(i32, output[0..1], "BAMCAQAAAAAAA", .none, scratch));
    try std.testing.expectError(error.DecodedSizeMismatch, arrays.decode(i32, output[0..1], "BAMCAQAAAAAABR==", .none, scratch));
    try std.testing.expectError(error.InvalidCharacter, arrays.decode(i32, output[0..1], "!AMCAQAAAAAA", .none, scratch));
    try std.testing.expectError(error.TruncatedInput, arrays.decode(i32, output[0..1], "BAM", .none, scratch));
    try std.testing.expectError(error.NonCanonicalTail, arrays.decode(i32, output[0..1], "BR==", .none, scratch));
    try std.testing.expectError(error.OverlappingBuffers, arrays.decode(i32, &output, std.mem.sliceAsBytes(&output), .none, scratch));
    try std.testing.expectError(error.OverlappingBuffers, arrays.decode(i32, &output, "BAMCAQ==", .none, .{ .transport = std.mem.sliceAsBytes(&output), .transformed = &.{} }));
}

test "[integration] - [arrays]: round trips every established pipeline" {
    var transport: [128]u8 = undefined;
    var transformed: [128]u8 = undefined;
    var output: [0]f64 = .{};
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var encoded: [256]u8 = undefined;
    var compressor = try zlib.Compressor.init(std.testing.allocator, .even);
    defer compressor.deinit();
    inline for (std.meta.tags(arrays.Pipeline)) |pipeline| {
        const fixed_point: ?f64 = switch (pipeline) {
            .linear, .linear_zlib, .slof, .slof_zlib => 0,
            else => null,
        };
        const wire = try arrays.encode(f64, &encoded, &.{}, .{
            .pipeline = pipeline,
            .fixed_point = fixed_point,
        }, scratch, &compressor);
        try arrays.decode(f64, output[0..0], wire, pipeline, scratch);
    }
}
