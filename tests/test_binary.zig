//! Verifies binary-array wire boundaries through the public package.

const std = @import("std");
const base64 = @import("z_mzml").base64;
const zlib = @import("z_mzml").zlib;
const arrays = @import("z_mzml").arrays;

fn allocateCompressor(allocator: std.mem.Allocator) !void {
    var compressor = try zlib.Compressor.init(allocator, .default);
    defer compressor.deinit();
    var output: [64]u8 = undefined;
    _ = try compressor.compress(&output, "abc");
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

// --- Base64 ---

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
            var decoder = base64.Decoder.init(&output, .{});
            try decoder.update(spaced[0..split]);
            try decoder.update(spaced[split..len]);
            const counts = try decoder.finish();
            try std.testing.expectEqualStrings(case[0], output[0..counts.decoded_bytes]);
            try std.testing.expectEqual(case[1].len, counts.significant_bytes);
            try std.testing.expectEqual(len, counts.text_bytes);
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
        for (0..case[0].len + 1) |split| {
            var output: [32]u8 = undefined;
            var decoder = base64.Decoder.init(&output, .{});
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

test "[edge] - [base64]: enforces independent bounds and destination ownership" {
    var output: [4]u8 = undefined;
    _ = try base64.decode(output[0..1], " Zg== ", .{
        .text_bytes = 6,
        .significant_bytes = 4,
        .decoded_bytes = 1,
    });
    try std.testing.expectError(error.LimitExceeded, base64.decode(&output, " Zg== ", .{ .text_bytes = 5 }));
    try std.testing.expectError(error.LimitExceeded, base64.decode(&output, "Zg==", .{ .significant_bytes = 3 }));
    try std.testing.expectError(error.LimitExceeded, base64.decode(&output, "Zg==", .{ .decoded_bytes = 0 }));
    try std.testing.expectError(error.OutputTooSmall, base64.decode(output[0..0], "Zg==", .{}));
    try std.testing.expectError(error.OutputTooSmall, base64.encode(output[0..3], "f"));
    try std.testing.expectError(error.OverlappingBuffers, base64.encode(&output, output[0..1]));
    try std.testing.expectError(error.OverlappingBuffers, base64.decode(&output, &output, .{}));
    try std.testing.expectError(error.LengthOverflow, base64.encodedSize(std.math.maxInt(usize)));
    var decoder = base64.Decoder.init(&output, .{});
    _ = try decoder.finish();
    try std.testing.expectError(error.AlreadyFinished, decoder.finish());
    try std.testing.expectError(error.AlreadyFinished, decoder.update(""));
}

test "[property] - [base64]: preserves all one-byte and two-byte inputs" {
    var input: [2]u8 = undefined;
    var encoded: [4]u8 = undefined;
    var decoded: [2]u8 = undefined;
    for (0..65536) |number| {
        std.mem.writeInt(u16, &input, @intCast(number), .little);
        const text = try base64.encode(&encoded, &input);
        var decoder = base64.Decoder.init(&decoded, .{});
        for (text) |byte| try decoder.update(&.{byte});
        const counts = try decoder.finish();
        try std.testing.expectEqualSlices(u8, &input, decoded[0..counts.decoded_bytes]);
        if (number < 256) {
            const short = try base64.encode(&encoded, input[0..1]);
            const short_counts = try base64.decode(&decoded, short, .{});
            try std.testing.expectEqualSlices(u8, input[0..1], decoded[0..short_counts.decoded_bytes]);
        }
    }
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

test "[property] - [zlib]: reuses compression storage after success and capacity failure" {
    var source: [70_000]u8 = undefined;
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    random.random().bytes(&source);
    var compressed: [72_000]u8 = undefined;
    var decoded: [source.len]u8 = undefined;
    inline for (.{ zlib.Level.fastest, .default, .best }) |level| {
        var compressor = try zlib.Compressor.init(std.testing.allocator, level);
        defer compressor.deinit();
        for ([_]usize{ 0, 1, 31, 32768, source.len }) |len| {
            const wire = try compressor.compress(&compressed, source[0..len]);
            try std.testing.expectEqualSlices(u8, source[0..len], try zlib.decompress(decoded[0..len], wire));
            try std.testing.expectError(error.OutputTooSmall, compressor.compress(compressed[0..0], source[0..len]));
        }
    }
}

test "[failure] - [zlib]: releases partially allocated compression storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateCompressor, .{});
}

// --- Array composition ---

test "[integration] - [primitive wire]: matches fixed little-endian Base64 vectors" {
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
        try arrays.decode(T, &output, case[2], .none, scratch, .{});
        try std.testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(&expected),
            std.mem.sliceAsBytes(&output),
        );
        const wire = try arrays.encode(T, &encoded, &expected, .{}, scratch, null);
        try std.testing.expectEqualStrings(case[2], wire);
    }
}

test "[integration] - [SLOF pipeline]: decodes a frozen zlib envelope" {
    var transport: [128]u8 = undefined;
    var transformed: [128]u8 = undefined;
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var output: [3]f64 = undefined;

    // Frozen Numpress vector with fixed point 4000, wrapped by Python zlib and Base64.
    try arrays.decode(f64, &output, "eJxzWO/AAAFXuSpUARP4Aqw=", .slof_zlib, scratch, .{});
    try expectSlofBound(&.{ 0, 1, 10 }, &output, 4000);
}

test "[property] - [array pipelines]: preserves single-bit patterns zeros and all-one bits" {
    var transport: [2048]u8 = undefined;
    var transformed: [2048]u8 = undefined;
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var encoded: [4096]u8 = undefined;
    var compressor = try zlib.Compressor.init(std.testing.allocator, .default);
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
            try arrays.decode(T, &output, wire, pipeline, scratch, .{});
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&values), std.mem.sliceAsBytes(&output));
        }
    }
}

test "[integration] - [array pipelines]: composes all Numpress modes with optional zlib" {
    var transport: [256]u8 = undefined;
    var transformed: [256]u8 = undefined;
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var encoded: [512]u8 = undefined;
    var output: [4]f64 = undefined;
    const values = [_]f64{ 0, 1.25, 10.5, 100.125 };
    var compressor = try zlib.Compressor.init(std.testing.allocator, .default);
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
        try arrays.decode(f64, &output, wire, pipeline, scratch, .{});
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

test "[integration] - [array options]: rejects invalid configuration and aliasing" {
    var transport: [128]u8 = undefined;
    var transformed: [128]u8 = undefined;
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var encoded: [128]u8 = undefined;
    const values = [_]f64{1};

    try std.testing.expectError(error.MissingFixedPoint, arrays.encode(f64, &encoded, &values, .{ .pipeline = .linear }, scratch, null));
    try std.testing.expectError(error.UnexpectedFixedPoint, arrays.encode(f64, &encoded, &values, .{ .fixed_point = 1 }, scratch, null));
    try std.testing.expectError(error.MissingCompressor, arrays.encode(f64, &encoded, &values, .{ .pipeline = .zlib }, scratch, null));
    try std.testing.expectError(error.OverlappingBuffers, arrays.encode(f64, &transport, &values, .{}, scratch, null));
    var floats: [4]f32 = undefined;
    try std.testing.expectError(error.TypeMismatch, arrays.decode(f32, &floats, "", .pic, scratch, .{}));
}

test "[integration] - [array limits]: rejects short scratch and mismatched counts" {
    var transport: [128]u8 = undefined;
    var transformed: [128]u8 = undefined;
    var output: [3]f64 = undefined;
    const source = "eJxzWO/AAAFXuSpUARP4Aqw=";
    try std.testing.expectError(error.OutputTooSmall, arrays.decode(f64, &output, source, .slof_zlib, .{
        .transport = transport[0..1],
        .transformed = &transformed,
    }, .{}));
    try std.testing.expectError(error.OutputTooSmall, arrays.decode(f64, &output, source, .slof_zlib, .{
        .transport = &transport,
        .transformed = transformed[0..1],
    }, .{}));
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    const plain = "AAAAAAAA8D8AAAAAAAAAgAAAAAAAAPB/";
    try std.testing.expectError(
        error.DecodedSizeMismatch,
        arrays.decode(f64, output[0..2], plain, .none, scratch, .{}),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        arrays.decode(f64, &output, plain, .none, scratch, .{ .array_bytes = 23 }),
    );
}

test "[integration] - [empty arrays]: round trips every established pipeline" {
    var transport: [128]u8 = undefined;
    var transformed: [128]u8 = undefined;
    var output: [0]f64 = .{};
    const scratch: arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
    var encoded: [256]u8 = undefined;
    var compressor = try zlib.Compressor.init(std.testing.allocator, .default);
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
        try arrays.decode(f64, output[0..0], wire, pipeline, scratch, .{});
    }
}
