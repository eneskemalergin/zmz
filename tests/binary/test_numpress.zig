//! Verifies the supported MS-Numpress API, wire bytes, loss bounds, and failures.

const std = @import("std");
const builtin = @import("builtin");
const numpress = @import("zmz").mzml.numpress;

fn decodeCount(transform: numpress.Transform, input: []const u8, output: []f64) numpress.DecodeError!usize {
    return switch (transform) {
        .linear => numpress.decodeLinear(input, output),
        .pic => numpress.decodePic(input, output),
        .slof => numpress.decodeSlof(input, output),
    };
}

fn expectLinearErrorBound(expected: []const f64, actual: []const f64, fixed_point: f64) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_value, actual_value| {
        try std.testing.expectApproxEqAbs(expected_value, actual_value, 0.5 / fixed_point);
    }
}

// Values of every nibble width, with fractions.
fn fillMixedWidths(values: []f64, source: std.Random) void {
    for (values) |*value| {
        value.* = @as(f64, @floatFromInt(source.int(u32) >> source.int(u5))) + source.float(f64);
    }
}

// Ascending values with irregular steps, the shape of m/z arrays.
fn fillAscending(values: []f64, source: std.Random) void {
    var current: f64 = 100 + source.float(f64) * 1_000;
    for (values) |*value| {
        current += source.float(f64) * @as(f64, @floatFromInt(@as(u32, 1) << source.int(u4)));
        value.* = current;
    }
}

fn expectSlofErrorBound(expected: []const f64, actual: []const f64, fixed_point: f64) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    const relative_bound = @exp(0.5 / fixed_point) - 1.0;
    for (expected, actual) |expected_value, actual_value| {
        if (expected_value == 0) {
            try std.testing.expectEqual(@as(f64, 0), actual_value);
        } else {
            try std.testing.expect(
                @abs(actual_value - expected_value) / (expected_value + 1.0) <=
                    relative_bound * 1.000001,
            );
        }
    }
}

test "[unit] - [numpress bounds]: reports exact or safe encoded capacities" {
    try std.testing.expectEqual(@as(usize, 8), try numpress.linearEncodedBound(0));
    try std.testing.expectEqual(@as(usize, 12), try numpress.linearEncodedBound(1));
    try std.testing.expectEqual(@as(usize, 16), try numpress.linearEncodedBound(2));
    try std.testing.expectEqual(@as(usize, 21), try numpress.linearEncodedBound(3));
    try std.testing.expectEqual(@as(usize, 25), try numpress.linearEncodedBound(4));

    try std.testing.expectEqual(@as(usize, 0), try numpress.picEncodedBound(0));
    try std.testing.expectEqual(@as(usize, 5), try numpress.picEncodedBound(1));
    try std.testing.expectEqual(@as(usize, 9), try numpress.picEncodedBound(2));
    try std.testing.expectEqual(@as(usize, 14), try numpress.picEncodedBound(3));

    try std.testing.expectEqual(@as(usize, 8), try numpress.slofEncodedSize(0));
    try std.testing.expectEqual(@as(usize, 10), try numpress.slofEncodedSize(1));
    try std.testing.expectEqual(@as(usize, 14), try numpress.slofEncodedSize(3));

    try std.testing.expectError(error.LengthOverflow, numpress.linearEncodedBound(std.math.maxInt(usize)));
    try std.testing.expectError(error.LengthOverflow, numpress.picEncodedBound(std.math.maxInt(usize)));
    try std.testing.expectError(error.LengthOverflow, numpress.slofEncodedSize(std.math.maxInt(usize)));
}

test "[unit] - [numpress wire format]: matches frozen Linear, PIC, and SLOF bytes" {
    const linear_values = [_]f64{ 100, 200, 300.00005, 400.00010 };
    const linear_expected = [_]u8{
        0x40, 0xf8, 0x6a, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x80, 0x96, 0x98, 0x00, 0x00, 0x2d, 0x31, 0x01,
        0x75, 0x80,
    };
    var linear_encoded: [32]u8 = undefined;
    const linear_len = try numpress.encodeLinear(&linear_values, 100_000, &linear_encoded);
    try std.testing.expectEqualSlices(u8, &linear_expected, linear_encoded[0..linear_len]);
    var linear_decoded: [linear_values.len]f64 = undefined;
    try numpress.decodeLinearExact(&linear_expected, &linear_decoded);
    try expectLinearErrorBound(&linear_values, &linear_decoded, 100_000);

    const pic_values = [_]f64{ 0, 1, 15, 16, 256 };
    const pic_expected = [_]u8{ 0x87, 0x17, 0xf6, 0x01, 0x50, 0x01 };
    var pic_encoded: [16]u8 = undefined;
    const pic_len = try numpress.encodePic(&pic_values, &pic_encoded);
    try std.testing.expectEqualSlices(u8, &pic_expected, pic_encoded[0..pic_len]);
    var pic_decoded: [pic_values.len]f64 = undefined;
    try numpress.decodePicExact(&pic_expected, &pic_decoded);
    try std.testing.expectEqualSlices(f64, &pic_values, &pic_decoded);

    const slof_values = [_]f64{ 0, 1, 10 };
    const slof_expected = [_]u8{
        0x40, 0xaf, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xd5, 0x0a, 0x78, 0x25,
    };
    var slof_encoded: [16]u8 = undefined;
    const slof_len = try numpress.encodeSlof(&slof_values, 4_000, &slof_encoded);
    try std.testing.expectEqualSlices(u8, &slof_expected, slof_encoded[0..slof_len]);
    var slof_decoded: [slof_values.len]f64 = undefined;
    try numpress.decodeSlofExact(&slof_expected, &slof_decoded);
    try expectSlofErrorBound(&slof_values, &slof_decoded, 4_000);
}

test "[edge] - [numpress arrays]: handles empty, one-value, and two-value inputs" {
    var encoded: [32]u8 = undefined;
    var empty: [0]f64 = .{};

    const empty_linear_len = try numpress.encodeLinear(&.{}, 0, &encoded);
    try std.testing.expectEqual(@as(usize, 8), empty_linear_len);
    try numpress.decodeLinearExact(encoded[0..empty_linear_len], &empty);

    const empty_pic_len = try numpress.encodePic(&.{}, &encoded);
    try std.testing.expectEqual(@as(usize, 0), empty_pic_len);
    try numpress.decodePicExact(encoded[0..empty_pic_len], &empty);

    const empty_slof_len = try numpress.encodeSlof(&.{}, 0, &encoded);
    try std.testing.expectEqual(@as(usize, 8), empty_slof_len);
    try numpress.decodeSlofExact(encoded[0..empty_slof_len], &empty);

    const linear_values = [_]f64{ 100, 200 };
    for (1..linear_values.len + 1) |count| {
        const len = try numpress.encodeLinear(linear_values[0..count], 1_000, &encoded);
        var decoded: [linear_values.len]f64 = undefined;
        try numpress.decodeLinearExact(encoded[0..len], decoded[0..count]);
        try std.testing.expectEqualSlices(f64, linear_values[0..count], decoded[0..count]);
    }

    const pic_len = try numpress.encodePic(&.{42}, &encoded);
    var pic_decoded: [1]f64 = undefined;
    try numpress.decodePicExact(encoded[0..pic_len], &pic_decoded);
    try std.testing.expectEqual(@as(f64, 42), pic_decoded[0]);

    const slof_len = try numpress.encodeSlof(&.{10}, 4_000, &encoded);
    var slof_decoded: [1]f64 = undefined;
    try numpress.decodeSlofExact(encoded[0..slof_len], &slof_decoded);
    try expectSlofErrorBound(&.{10}, &slof_decoded, 4_000);
}

test "[edge] - [numpress selectors]: handles degenerate arrays and requested Linear error" {
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    try std.testing.expectEqual(@as(f64, 0), try numpress.optimalLinearFixedPoint(&.{}));
    try std.testing.expectEqual(maximum, try numpress.optimalLinearFixedPoint(&.{0}));
    try std.testing.expectEqual(maximum, try numpress.optimalLinearFixedPoint(&.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(f64, 0), try numpress.optimalSlofFixedPoint(&.{}));
    try std.testing.expectEqual(@as(f64, 65_535), try numpress.optimalSlofFixedPoint(&.{ 0, 0, 0 }));

    const values = [_]f64{ 100.123456, 200.234567, 300.345679, 401.876543, 900.000001 };
    const max_abs_error = 0.0001;
    const fixed_point = try numpress.linearFixedPointForAbsoluteError(&values, max_abs_error);
    try std.testing.expectEqual(@as(f64, 5_000), fixed_point);

    var encoded: [128]u8 = undefined;
    const encoded_len = try numpress.encodeLinear(&values, fixed_point, &encoded);
    var decoded: [values.len]f64 = undefined;
    try numpress.decodeLinearExact(encoded[0..encoded_len], &decoded);
    for (values, decoded) |expected, actual| {
        try std.testing.expect(@abs(expected - actual) <= max_abs_error);
    }
}

test "[property] - [numpress Linear]: decoded values satisfy the fixed-point error bound" {
    const values = [_]f64{ 100.123456, 200.234567, 300.345679, 401.876543, 900.000001 };
    const fixed_point = try numpress.optimalLinearFixedPoint(&values);
    var encoded: [128]u8 = undefined;
    const encoded_len = try numpress.encodeLinear(&values, fixed_point, &encoded);
    var decoded: [values.len]f64 = undefined;
    try numpress.decodeLinearExact(encoded[0..encoded_len], &decoded);
    try expectLinearErrorBound(&values, &decoded, fixed_point);
}

test "[property] - [numpress PIC]: rounds fractional values to the nearest integer" {
    const values = [_]f64{ 0, 0.49, 0.5, 1.49, 1.5, 9_999.9 };
    const expected = [_]f64{ 0, 0, 1, 1, 2, 10_000 };
    var encoded: [64]u8 = undefined;
    const encoded_len = try numpress.encodePic(&values, &encoded);
    var decoded: [values.len]f64 = undefined;
    try numpress.decodePicExact(encoded[0..encoded_len], &decoded);
    try std.testing.expectEqualSlices(f64, &expected, &decoded);
}

test "[property] - [numpress SLOF]: decoded values satisfy the logarithmic error bound" {
    const values = [_]f64{ 0, 0.0001, 0.1, 1, 10, 1_000, 1_000_000 };
    const fixed_point = try numpress.optimalSlofFixedPoint(&values);
    var encoded: [64]u8 = undefined;
    const encoded_len = try numpress.encodeSlof(&values, fixed_point, &encoded);
    var decoded: [values.len]f64 = undefined;
    try numpress.decodeSlofExact(encoded[0..encoded_len], &decoded);
    try expectSlofErrorBound(&values, &decoded, fixed_point);
}

test "[edge] - [numpress PIC]: spans the complete unsigned wire domain" {
    const values = [_]f64{ 0, 1, 2_147_483_647, 2_147_483_648, 4_294_967_294, 4_294_967_295 };
    const expected = [_]u8{ 0x87, 0x10, 0xff, 0xff, 0xff, 0xf7, 0, 0, 0, 0, 0x8f, 0xef, 0xf0 };
    var encoded: [32]u8 = undefined;
    const encoded_len = try numpress.encodePic(&values, &encoded);
    try std.testing.expectEqualSlices(u8, &expected, encoded[0..encoded_len]);

    var decoded: [values.len]f64 = undefined;
    try numpress.decodePicExact(&expected, &decoded);
    try std.testing.expectEqualSlices(f64, &values, &decoded);

    const full_width = [_]u8{ 0x0f, 0xff, 0xff, 0xff, 0xf0 };
    var full_width_decoded: [1]f64 = undefined;
    try numpress.decodePicExact(&full_width, &full_width_decoded);
    try std.testing.expectEqual(@as(f64, @floatFromInt(std.math.maxInt(u32))), full_width_decoded[0]);
    for (1..full_width.len) |length| {
        try std.testing.expectError(
            error.InvalidData,
            numpress.decodePicExact(full_width[0..length], &full_width_decoded),
        );
    }
}

test "[failure] - [numpress exact decode]: rejects fewer and extra values" {
    var linear_encoded: [64]u8 = undefined;
    const linear_len = try numpress.encodeLinear(&.{ 100, 200, 300, 400 }, 10_000, &linear_encoded);
    var linear_values: [4]f64 = undefined;
    try std.testing.expectError(
        error.DecodedSizeMismatch,
        numpress.decodeLinearExact(linear_encoded[0..16], &linear_values),
    );
    try std.testing.expectError(
        error.DecodedSizeMismatch,
        numpress.decodeLinearExact(linear_encoded[0..linear_len], linear_values[0..3]),
    );

    var pic_encoded: [16]u8 = undefined;
    const pic_short_len = try numpress.encodePic(&.{ 1, 2 }, &pic_encoded);
    var pic_values: [3]f64 = undefined;
    try std.testing.expectError(
        error.DecodedSizeMismatch,
        numpress.decodePicExact(pic_encoded[0..pic_short_len], &pic_values),
    );
    const pic_long_len = try numpress.encodePic(&.{ 1, 2, 3, 4 }, &pic_encoded);
    try std.testing.expectError(
        error.DecodedSizeMismatch,
        numpress.decodePicExact(pic_encoded[0..pic_long_len], &pic_values),
    );

    var slof_encoded: [32]u8 = undefined;
    const slof_len = try numpress.encodeSlof(&.{ 0, 1, 10 }, 4_000, &slof_encoded);
    var slof_values: [3]f64 = undefined;
    try std.testing.expectError(
        error.DecodedSizeMismatch,
        numpress.decodeSlofExact(slof_encoded[0 .. slof_len - 2], &slof_values),
    );
    try std.testing.expectError(
        error.DecodedSizeMismatch,
        numpress.decodeSlofExact(slof_encoded[0..slof_len], slof_values[0..2]),
    );
}

test "[failure] - [numpress encoders]: reject invalid values, scales, capacities, and overlapping buffers" {
    var output: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidValue, numpress.encodeLinear(&.{-1}, 1, &output));
    try std.testing.expectError(error.InvalidFixedPoint, numpress.encodeLinear(&.{1}, 0, &output));
    try std.testing.expectError(error.InvalidValue, numpress.encodePic(&.{-0.1}, &output));
    try std.testing.expectError(error.InvalidValue, numpress.encodePic(&.{std.math.nan(f64)}, &output));
    const pic_max: f64 = @floatFromInt(std.math.maxInt(u32));
    _ = try numpress.encodePic(&.{pic_max}, &output);
    try std.testing.expectError(error.ValueOutOfRange, numpress.encodePic(&.{pic_max + 1}, &output));
    try std.testing.expectError(error.InvalidValue, numpress.encodeSlof(&.{-1}, 1, &output));
    try std.testing.expectError(error.ValueOutOfRange, numpress.encodeSlof(&.{100}, 1_000_000, &output));

    try std.testing.expectError(
        error.InvalidValue,
        numpress.linearFixedPointForAbsoluteError(&.{ 100, 200, 300 }, 0),
    );
    try std.testing.expectError(
        error.ToleranceUnattainable,
        numpress.linearFixedPointForAbsoluteError(&.{1_000_000_000}, 0.000000001),
    );

    try std.testing.expectError(error.OutputTooSmall, numpress.encodeLinear(&.{}, 0, output[0..7]));
    try std.testing.expectError(error.OutputTooSmall, numpress.encodePic(&.{0}, output[0..0]));
    try std.testing.expectError(error.OutputTooSmall, numpress.encodeSlof(&.{0}, 1, output[0..9]));

    // An output over the values is refused before any byte is written: below the bound the
    // encoders take the value-by-value path, at it the block path.
    var shared: [4]f64 = .{ 1, 2, 3, 4 };
    const shared_bytes = std.mem.sliceAsBytes(&shared);
    for ([_]usize{ 4, shared_bytes.len }) |len| {
        try std.testing.expectError(error.OverlappingBuffers, numpress.encodePic(&shared, shared_bytes[0..len]));
        try std.testing.expectError(error.OverlappingBuffers, numpress.encodeLinear(&shared, 1, shared_bytes[0..len]));
        try std.testing.expectError(error.OverlappingBuffers, numpress.encodeSlof(&shared, 1, shared_bytes[0..len]));
        try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3, 4 }, &shared);
    }
    // Values inside the writer's buffer are refused the same way.
    var buffer: [64]f64 = undefined;
    @memset(&buffer, 1);
    var writer = std.Io.Writer.fixed(std.mem.sliceAsBytes(&buffer));
    const values = buffer[32..40];
    try std.testing.expectError(error.OverlappingBuffers, numpress.encodePicTo(values, &writer));
    try std.testing.expectError(error.OverlappingBuffers, numpress.encodeLinearTo(values, 1, &writer));
    try std.testing.expectError(error.OverlappingBuffers, numpress.encodeSlofTo(values, 1, &writer));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "[failure] - [numpress decoders]: reject malformed bytes and short destinations" {
    var output: [8]f64 = undefined;
    var linear: [17]u8 = @splat(0);
    try std.testing.expectError(error.InvalidData, numpress.decodeLinear(linear[0..7], &output));
    try std.testing.expectError(error.InvalidData, numpress.decodeLinear(linear[0..9], &output));
    try std.testing.expectError(error.InvalidData, numpress.decodeLinear(linear[0..13], &output));
    std.mem.writeInt(u64, linear[0..8], @bitCast(@as(f64, 1)), .big);
    try std.testing.expectError(error.InvalidData, numpress.decodeLinear(&linear, &output));

    try std.testing.expectError(error.InvalidData, numpress.decodePic(&.{0x00}, &output));
    try std.testing.expectError(error.InvalidData, numpress.decodePic(&.{0x81}, &output));
    try std.testing.expectError(error.OutputTooSmall, numpress.decodePic(&.{0x88}, output[0..1]));

    var slof: [10]u8 = @splat(0);
    try std.testing.expectError(error.InvalidData, numpress.decodeSlof(slof[0..7], &output));
    try std.testing.expectError(error.InvalidData, numpress.decodeSlof(slof[0..9], &output));
    try std.testing.expectError(error.InvalidFixedPoint, numpress.decodeSlof(&slof, &output));
    std.mem.writeInt(u64, slof[0..8], @bitCast(std.math.inf(f64)), .big);
    try std.testing.expectError(error.InvalidFixedPoint, numpress.decodeSlof(&slof, &output));

    var linear_encoded: [32]u8 = undefined;
    const linear_len = try numpress.encodeLinear(&.{ 1, 2, 3 }, 1, &linear_encoded);
    var short_output: [2]f64 = undefined;
    try std.testing.expectError(
        error.OutputTooSmall,
        numpress.decodeLinear(linear_encoded[0..linear_len], &short_output),
    );

    // Payload bytes inside the output are refused, whole or in fragments.
    var decoded: [4]f64 = undefined;
    const payload = std.mem.sliceAsBytes(&decoded)[0..16];
    for ([_]numpress.Transform{ .linear, .pic, .slof }) |transform| {
        try std.testing.expectError(error.OverlappingBuffers, decodeCount(transform, payload, &decoded));
        try std.testing.expectError(error.OverlappingBuffers, numpress.decodeExact(transform, payload, &decoded));
        var decoder = numpress.Decoder.init(transform, &decoded);
        try std.testing.expectError(error.OverlappingBuffers, decoder.update(payload[0..3]));
        try std.testing.expectError(error.FailedState, decoder.finish());
    }
}

fn expectFinitePrefix(values: []const f64, count: usize) !void {
    try std.testing.expect(count <= values.len);
    for (values[0..count]) |value| try std.testing.expect(std.math.isFinite(value));
}

test "[property] - [numpress decoders]: bounded arbitrary bytes stay within output spans" {
    var random = std.Random.DefaultPrng.init(0x4e55_4d50_4259_5445);
    const source = random.random();
    var bytes: [64]u8 = undefined;
    var guarded_output: [34]f64 = @splat(-1);

    for (0..4_096) |_| {
        const input_len = source.uintLessThan(usize, bytes.len + 1);
        const output_len = source.uintLessThan(usize, guarded_output.len - 1);
        source.bytes(bytes[0..input_len]);
        const output = guarded_output[1 .. 1 + output_len];

        if (numpress.decodeLinear(bytes[0..input_len], output)) |count| {
            try expectFinitePrefix(output, count);
        } else |_| {}
        if (numpress.decodePic(bytes[0..input_len], output)) |count| {
            try expectFinitePrefix(output, count);
        } else |_| {}
        if (numpress.decodeSlof(bytes[0..input_len], output)) |count| {
            try expectFinitePrefix(output, count);
        } else |_| {}

        try std.testing.expectEqual(@as(f64, -1), guarded_output[0]);
        try std.testing.expectEqual(@as(f64, -1), guarded_output[guarded_output.len - 1]);
    }
}

test "[regression] - [numpress SLOF]: block and value encoders agree at the 65535 boundary" {
    const fixed_point = 2.636635300905972e4;
    const value = 1.1007773364781926e1;
    var one: [8 + 2]u8 = undefined;
    var many: [8 + 32]u8 = undefined;
    try std.testing.expectError(error.ValueOutOfRange, numpress.encodeSlof(&[_]f64{value}, fixed_point, &one));
    try std.testing.expectError(error.ValueOutOfRange, numpress.encodeSlof(&([_]f64{value} ** 16), fixed_point, &many));
}

test "[property] - [numpress SLOF]: a block of 16 encodes like each value alone around the range limit" {
    var random = std.Random.DefaultPrng.init(0x534c_4f46_4c49_4d49);
    const source = random.random();
    var one: [8 + 2]u8 = undefined;
    var many: [8 + 32]u8 = undefined;
    for (0..200) |_| {
        const fixed_point = 100.0 + source.float(f64) * 60_000.0;
        // The value whose scaled logarithm is the limit, then a few ULPs either side of it.
        var value = std.math.expm1(65_535.0 / fixed_point);
        for (0..4) |_| value = std.math.nextAfter(f64, value, 0);
        for (0..9) |_| {
            const alone = numpress.encodeSlof(&[_]f64{value}, fixed_point, &one);
            const block = numpress.encodeSlof(&([_]f64{value} ** 16), fixed_point, &many);
            if (alone) |_| {
                _ = try block;
                for (0..16) |lane| try std.testing.expectEqualSlices(u8, one[8..10], many[8 + 2 * lane ..][0..2]);
            } else |err| try std.testing.expectError(err, block);
            value = std.math.nextAfter(f64, value, std.math.inf(f64));
        }
    }
}

test "[property] - [numpress encoders]: block encoding matches the value-by-value encoding" {
    var random = std.Random.DefaultPrng.init(0x4e55_4d50_424c_4f43);
    const source = random.random();
    var values: [700]f64 = undefined;
    var block: [16 + 9 * values.len / 2 + 16]u8 = undefined;
    var checked: [block.len]u8 = undefined;
    for ([_]usize{ 3, 17, 129, 300, 700 }) |count| {
        fillMixedWidths(values[0..count], source);
        const array = values[0..count];
        const slof_fixed_point = try numpress.optimalSlofFixedPoint(array);
        // An output of exactly the encoded length is below the worst-case bound, so the
        // encoders take their value-by-value path for it; an output of exactly the bound
        // takes the block path to its last byte.
        const pic_len = try numpress.encodePic(array, &block);
        try std.testing.expectEqual(pic_len, try numpress.encodePic(array, checked[0..pic_len]));
        try std.testing.expectEqualSlices(u8, block[0..pic_len], checked[0..pic_len]);
        const pic_bound = try numpress.picEncodedBound(count);
        try std.testing.expectEqual(pic_len, try numpress.encodePic(array, checked[0..pic_bound]));
        try std.testing.expectEqualSlices(u8, block[0..pic_len], checked[0..pic_len]);
        const slof_len = try numpress.encodeSlof(array, slof_fixed_point, &block);
        try std.testing.expectEqual(slof_len, try numpress.encodeSlof(array, slof_fixed_point, checked[0..slof_len]));
        try std.testing.expectEqualSlices(u8, block[0..slof_len], checked[0..slof_len]);

        fillAscending(array, source);
        const linear_fixed_point = try numpress.optimalLinearFixedPoint(array);
        const linear_len = try numpress.encodeLinear(array, linear_fixed_point, &block);
        try std.testing.expectEqual(linear_len, try numpress.encodeLinear(array, linear_fixed_point, checked[0..linear_len]));
        try std.testing.expectEqualSlices(u8, block[0..linear_len], checked[0..linear_len]);
        const linear_bound = try numpress.linearEncodedBound(count);
        try std.testing.expectEqual(linear_len, try numpress.encodeLinear(array, linear_fixed_point, checked[0..linear_bound]));
        try std.testing.expectEqualSlices(u8, block[0..linear_len], checked[0..linear_len]);
    }
}

test "[regression] - [numpress Linear]: values falling below 2^62 at a block boundary encode" {
    // Second differences of 2^30 fit a residual, but the values peak between 2^62 and 2^63.
    // The block before the fall takes the checked path; the next one starts below 2^62 with
    // carried values above it.
    const allocator = std.testing.allocator;
    const n: i64 = 80_000;
    var scaled: std.ArrayList(i64) = .empty;
    defer scaled.deinit(allocator);
    var value: i64 = 0;
    var step: i64 = 0;
    var fall: ?usize = null;
    var high = false;
    var i: i64 = 0;
    while (fall == null or scaled.items.len < fall.? + 300) : (i += 1) {
        try scaled.append(allocator, value);
        const below = @as(f64, @floatFromInt(value)) + 0.5 < 0x1p62;
        if (high and below and fall == null) fall = scaled.items.len - 1;
        high = high or !below;
        step += if (i < n) 1 << 30 else -(1 << 30);
        value += step;
    }
    // Leading zeros move the fall to the first value of a 128-value block, which starts at 2.
    const zeros = (128 - (fall.? - 2) % 128) % 128;
    const values = try allocator.alloc(f64, zeros + scaled.items.len);
    defer allocator.free(values);
    @memset(values[0..zeros], 0);
    for (scaled.items, values[zeros..]) |source, *destination| destination.* = @floatFromInt(source);
    const encoded = try allocator.alloc(u8, try numpress.linearEncodedBound(values.len));
    defer allocator.free(encoded);
    const length = try numpress.encodeLinear(values, 1, encoded);
    const decoded = try allocator.alloc(f64, values.len);
    defer allocator.free(decoded);
    try numpress.decodeLinearExact(encoded[0..length], decoded);
    try std.testing.expectEqualSlices(f64, values, decoded);
}

fn expectSameBytes(narrow: numpress.EncodeError!usize, wide: numpress.EncodeError!usize, narrow_bytes: []const u8, wide_bytes: []const u8) !void {
    const length = try wide;
    try std.testing.expectEqual(length, try narrow);
    try std.testing.expectEqualSlices(u8, wide_bytes[0..length], narrow_bytes[0..length]);
}

test "[property] - [numpress encoders]: f32 input encodes as its f64 copy" {
    var random = std.Random.DefaultPrng.init(0x4e55_4d50_4633_3200);
    const source = random.random();
    var narrow: [700]f32 = undefined;
    var wide: [narrow.len]f64 = undefined;
    var from_narrow: [16 + 9 * narrow.len / 2 + 16]u8 = undefined;
    var from_wide: [from_narrow.len]u8 = undefined;
    for ([_]usize{ 0, 1, 3, 17, 129, 700 }) |count| {
        var current: f32 = 100;
        for (narrow[0..count], wide[0..count]) |*n, *w| {
            current += source.float(f32) * 3;
            n.* = if (source.uintLessThan(u8, 8) == 0) 0 else current;
            w.* = n.*;
        }
        const n = narrow[0..count];
        const w = wide[0..count];
        try std.testing.expectEqual(try numpress.optimalLinearFixedPoint(w), try numpress.optimalLinearFixedPoint(n));
        try std.testing.expectEqual(try numpress.optimalSlofFixedPoint(w), try numpress.optimalSlofFixedPoint(n));
        const linear_fixed_point = try numpress.optimalLinearFixedPoint(w);
        const slof_fixed_point = try numpress.optimalSlofFixedPoint(w);
        try expectSameBytes(
            numpress.encodeLinear(n, linear_fixed_point, &from_narrow),
            numpress.encodeLinear(w, linear_fixed_point, &from_wide),
            &from_narrow,
            &from_wide,
        );
        try expectSameBytes(numpress.encodePic(n, &from_narrow), numpress.encodePic(w, &from_wide), &from_narrow, &from_wide);
        try expectSameBytes(
            numpress.encodeSlof(n, slof_fixed_point, &from_narrow),
            numpress.encodeSlof(w, slof_fixed_point, &from_wide),
            &from_narrow,
            &from_wide,
        );
        var narrow_writer = std.Io.Writer.fixed(&from_narrow);
        var wide_writer = std.Io.Writer.fixed(&from_wide);
        _ = try numpress.encodeSlofTo(n, slof_fixed_point, &narrow_writer);
        _ = try numpress.encodeSlofTo(w, slof_fixed_point, &wide_writer);
        try std.testing.expectEqualSlices(u8, wide_writer.buffered(), narrow_writer.buffered());
    }
    var invalid = [_]f32{ 1, std.math.nan(f32), 3 };
    try std.testing.expectError(error.InvalidValue, numpress.encodePic(&invalid, &from_narrow));
    invalid[1] = -1;
    try std.testing.expectError(error.InvalidValue, numpress.encodeLinear(&invalid, 1, &from_narrow));
}

test "[property] - [numpress SLOF]: vector blocks and tails give the frozen codes" {
    const pattern = [_]f64{ 0, 1, 10 };
    const codes = [_]u16{ 0x0000, 0x0ad5, 0x2578 };
    var values: [40]f64 = undefined;
    var expected: [8 + 2 * values.len]u8 = undefined;
    std.mem.writeInt(u64, expected[0..8], @bitCast(@as(f64, 4_000)), .big);
    for (&values, 0..) |*value, index| {
        value.* = pattern[index % 3];
        std.mem.writeInt(u16, expected[8 + 2 * index ..][0..2], codes[index % 3], .little);
    }
    for (0..values.len + 1) |count| {
        const wire_length = 8 + count * 2;
        var encoded: [expected.len + 2]u8 = @splat(0xa5);
        var decoded: [values.len + 2]f64 = @splat(-1);
        const length = try numpress.encodeSlof(values[0..count], 4_000, encoded[1 .. 1 + wire_length]);
        try std.testing.expectEqual(wire_length, length);
        try std.testing.expectEqualSlices(u8, expected[0..length], encoded[1 .. 1 + length]);
        try std.testing.expectEqual(@as(u8, 0xa5), encoded[0]);
        try std.testing.expect(std.mem.allEqual(u8, encoded[1 + length ..], 0xa5));

        try numpress.decodeSlofExact(encoded[1 .. 1 + length], decoded[1 .. 1 + count]);
        try std.testing.expectEqual(@as(f64, -1), decoded[0]);
        try std.testing.expect(std.mem.allEqual(f64, decoded[1 + count ..], -1));
        try expectSlofErrorBound(values[0..count], decoded[1 .. 1 + count], 4_000);
    }
}

test "[failure] - [numpress SLOF]: reports invalid values in vector blocks and tails" {
    var values: [40]f64 = @splat(1);
    var encoded: [8 + values.len * 2]u8 = undefined;
    var decoded: [values.len]f64 = undefined;
    for ([_]f64{ -1, std.math.inf(f64), std.math.nan(f64), 1e100 }) |invalid| {
        for (0..values.len) |index| {
            values[index] = invalid;
            try std.testing.expectError(
                if (invalid == 1e100) error.ValueOutOfRange else error.InvalidValue,
                numpress.encodeSlof(&values, 4_000, &encoded),
            );
            values[index] = 1;
        }
    }
    _ = try numpress.encodeSlof(&values, 1, &encoded);
    for (0..values.len) |index| {
        const code = encoded[8 + index * 2 ..][0..2];
        std.mem.writeInt(u16, code, 65_535, .little);
        try std.testing.expectError(error.InvalidData, numpress.decodeSlofExact(&encoded, &decoded));
        std.mem.writeInt(u16, code, 1, .little);
    }
}

test "[unit] - [numpress SLOF]: decodes to glibc's exp bit for bit" {
    // glibc runs an FMA build of exp on CPUs with FMA and a plain build otherwise; the last
    // code is one where the two differ, and each zmz build must match the one it targets.
    const fused = switch (builtin.cpu.arch) {
        .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .fma),
        .aarch64 => true,
        else => false,
    };
    const cases = [_]struct { fixed_point: f64, code: u16, bits: u64 }{
        .{ .fixed_point = 4_000, .code = 1, .bits = 0x3f3062d40d8bc000 },
        .{ .fixed_point = 4_000, .code = 31_752, .bits = 0x40a5e180b745f201 },
        .{ .fixed_point = 4_000, .code = 34_671, .bits = 0x40b6b3681e31c5ff },
        .{ .fixed_point = 100, .code = 51_200, .bits = 0x6e19476504ba852e },
        .{ .fixed_point = 100, .code = 60_000, .bits = 0x76088a122d234b39 },
        .{ .fixed_point = 100, .code = 65_535, .bits = if (fused) 0x7b062a2ceaa34527 else 0x7b062a2ceaa34526 },
    };
    for (cases) |case| {
        var payload: [10]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], @bitCast(case.fixed_point), .big);
        std.mem.writeInt(u16, payload[8..10], case.code, .little);
        var decoded: [1]f64 = undefined;
        try numpress.decodeSlofExact(&payload, &decoded);
        try std.testing.expectEqual(case.bits, @as(u64, @bitCast(decoded[0])));
    }
}

fn decodeWhole(transform: numpress.Transform, exact: bool, input: []const u8, output: []f64) numpress.DecodeError!usize {
    if (!exact) return decodeCount(transform, input, output);
    try numpress.decodeExact(transform, input, output);
    return output.len;
}

fn decodeFed(
    transform: numpress.Transform,
    exact: bool,
    input: []const u8,
    output: []f64,
    max_piece: usize,
    source: std.Random,
) numpress.Decoder.Error!usize {
    var decoder = if (exact) numpress.Decoder.initExact(transform, output) else numpress.Decoder.init(transform, output);
    var at: usize = 0;
    while (at < input.len) {
        const piece = @min(1 + source.uintLessThan(usize, max_piece), input.len - at);
        try decoder.update(input[at..][0..piece]);
        try decoder.update(input[at..][0..0]);
        at += piece;
    }
    return decoder.finish();
}

fn expectSameDecode(
    expected: numpress.Decoder.Error!usize,
    expected_values: []const f64,
    actual: numpress.Decoder.Error!usize,
    actual_values: []const f64,
) !void {
    const count = expected catch |err| return std.testing.expectError(err, actual);
    try std.testing.expectEqual(count, try actual);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(expected_values[0..count]),
        std.mem.sliceAsBytes(actual_values[0..count]),
    );
}

test "[property] - [numpress Decoder]: every fragment split gives the one-shot result" {
    var random = std.Random.DefaultPrng.init(0x4e55_4d50_5354_524d);
    const source = random.random();
    var values: [600]f64 = undefined;
    var encoded: [16 + 9 * values.len / 2 + 16]u8 = undefined;
    var whole: [values.len + 1]f64 = undefined;
    var fed: [values.len + 1]f64 = undefined;
    for ([_]usize{ 0, 1, 2, 3, 17, 300, 600 }) |count| {
        const array = values[0..count];
        for ([_]numpress.Transform{ .linear, .pic, .slof }) |transform| {
            if (transform == .linear) fillAscending(array, source) else fillMixedWidths(array, source);
            const len = switch (transform) {
                .linear => try numpress.encodeLinear(array, try numpress.optimalLinearFixedPoint(array), &encoded),
                .pic => try numpress.encodePic(array, &encoded),
                .slof => try numpress.encodeSlof(array, try numpress.optimalSlofFixedPoint(array), &encoded),
            };
            const cuts = [_]usize{ len, len -| 1, len / 2, @min(len, 9), @min(len, 15) };
            for (cuts) |cut| {
                for ([_]usize{ count -| 1, count, count + 1 }) |capacity| {
                    for ([_]bool{ false, true }) |exact| {
                        const expected = decodeWhole(transform, exact, encoded[0..cut], whole[0..capacity]);
                        for ([_]usize{ 1, 9, 600 }) |max_piece| {
                            const actual = decodeFed(transform, exact, encoded[0..cut], fed[0..capacity], max_piece, source);
                            try expectSameDecode(expected, whole[0..capacity], actual, fed[0..capacity]);
                        }
                    }
                }
            }
        }
    }
    var bytes: [64]u8 = undefined;
    for (0..2_000) |_| {
        const input_len = source.uintLessThan(usize, bytes.len + 1);
        source.bytes(bytes[0..input_len]);
        if (input_len >= 8 and source.boolean()) {
            std.mem.writeInt(u64, bytes[0..8], @bitCast(@as(f64, 1_000)), .big);
        }
        const transform = source.enumValue(numpress.Transform);
        const capacity = source.uintLessThan(usize, 140);
        const exact = source.boolean();
        const expected = decodeWhole(transform, exact, bytes[0..input_len], whole[0..capacity]);
        const actual = decodeFed(transform, exact, bytes[0..input_len], fed[0..capacity], 1 + source.uintLessThan(usize, 9), source);
        try expectSameDecode(expected, whole[0..capacity], actual, fed[0..capacity]);
    }
}

test "[failure] - [numpress Decoder]: calls after an error or finish report the state" {
    var output: [4]f64 = undefined;
    var finished = numpress.Decoder.init(.pic, &output);
    try finished.update(&.{ 0x88, 0x88 });
    try std.testing.expectEqual(@as(usize, 4), try finished.finish());
    try std.testing.expectError(error.AlreadyFinished, finished.update(&.{0x88}));
    try std.testing.expectError(error.AlreadyFinished, finished.finish());

    var failed = numpress.Decoder.init(.pic, output[0..1]);
    try std.testing.expectError(error.OutputTooSmall, failed.update(&.{ 0x88, 0x88 }));
    try std.testing.expectError(error.FailedState, failed.update(&.{0x88}));
    try std.testing.expectError(error.FailedState, failed.finish());

    var exact = numpress.Decoder.initExact(.slof, output[0..1]);
    try exact.update(&.{ 0x40, 0xaf, 0x40, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectError(error.InvalidData, exact.finish());
    try std.testing.expectError(error.FailedState, exact.finish());
}

// A writer with a small buffer that forwards every drain, so encoders see partial drains.
const Forward = struct {
    target: *std.Io.Writer,
    interface: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Forward = @alignCast(@fieldParentPtr("interface", writer));
        try self.target.writeAll(writer.buffered());
        writer.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.target.writeAll(bytes);
            written += bytes.len;
        }
        for (0..splat) |_| try self.target.writeAll(data[data.len - 1]);
        return written + data[data.len - 1].len * splat;
    }
};

test "[property] - [numpress writer encoders]: match the slice encoders' bytes and errors" {
    var random = std.Random.DefaultPrng.init(0x4e55_4d50_5752_4954);
    const source = random.random();
    var values: [300]f64 = undefined;
    var expected: [16 + 9 * values.len / 2 + 16]u8 = undefined;
    var fixed_bytes: [expected.len]u8 = undefined;
    const invalid = [_]f64{ -1, std.math.nan(f64), std.math.inf(f64), 4_294_967_296, 1e300 };
    for ([_]usize{ 0, 1, 2, 3, 16, 17, 129, 300 }) |count| {
        fillMixedWidths(values[0..count], source);
        for (0..invalid.len + 1) |variant| {
            const array = values[0..count];
            const position = if (count == 0) 0 else source.uintLessThan(usize, count);
            const saved = if (count == 0) 0 else array[position];
            if (variant < invalid.len and count != 0) array[position] = invalid[variant];
            defer if (count != 0) {
                array[position] = saved;
            };
            for ([_]f64{ 1_000, 0, -1, 0.5 }) |fixed_point| {
                for ([_]numpress.Transform{ .linear, .pic, .slof }) |transform| {
                    const slice_result = numpress.encode(transform, array, fixed_point, &expected);
                    var fixed = std.Io.Writer.fixed(&fixed_bytes);
                    const fixed_result = numpress.encodeTo(transform, array, fixed_point, &fixed);
                    var collected: std.Io.Writer.Allocating = .init(std.testing.allocator);
                    defer collected.deinit();
                    var small: [64]u8 = undefined;
                    var forward = Forward{ .target = &collected.writer, .interface = .{ .vtable = &Forward.vtable, .buffer = &small } };
                    const forward_result = numpress.encodeTo(transform, array, fixed_point, &forward.interface);
                    if (slice_result) |len| {
                        try std.testing.expectEqual(len, try fixed_result);
                        try std.testing.expectEqualSlices(u8, expected[0..len], fixed.buffered());
                        try std.testing.expectEqual(len, try forward_result);
                        try forward.interface.flush();
                        try std.testing.expectEqualSlices(u8, expected[0..len], collected.written());
                    } else |err| {
                        try std.testing.expectError(err, fixed_result);
                        try std.testing.expectError(err, forward_result);
                    }
                }
            }
        }
    }
}
