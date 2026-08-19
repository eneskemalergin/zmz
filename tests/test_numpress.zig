//! Verifies the supported MS-Numpress API, wire bytes, loss bounds, and failures.

const std = @import("std");
const numpress = @import("z_mzml").numpress;

test "[unit] - [numpress bounds]: reports exact or safe encoded capacities" {
    try std.testing.expectEqual(@as(usize, 8), try numpress.linearMaxEncodedLen(0));
    try std.testing.expectEqual(@as(usize, 12), try numpress.linearMaxEncodedLen(1));
    try std.testing.expectEqual(@as(usize, 16), try numpress.linearMaxEncodedLen(2));
    try std.testing.expectEqual(@as(usize, 21), try numpress.linearMaxEncodedLen(3));
    try std.testing.expectEqual(@as(usize, 25), try numpress.linearMaxEncodedLen(4));

    try std.testing.expectEqual(@as(usize, 0), try numpress.picMaxEncodedLen(0));
    try std.testing.expectEqual(@as(usize, 5), try numpress.picMaxEncodedLen(1));
    try std.testing.expectEqual(@as(usize, 9), try numpress.picMaxEncodedLen(2));
    try std.testing.expectEqual(@as(usize, 14), try numpress.picMaxEncodedLen(3));

    try std.testing.expectEqual(@as(usize, 8), try numpress.slofEncodedLen(0));
    try std.testing.expectEqual(@as(usize, 10), try numpress.slofEncodedLen(1));
    try std.testing.expectEqual(@as(usize, 14), try numpress.slofEncodedLen(3));

    try std.testing.expectError(error.LengthOverflow, numpress.linearMaxEncodedLen(std.math.maxInt(usize)));
    try std.testing.expectError(error.LengthOverflow, numpress.picMaxEncodedLen(std.math.maxInt(usize)));
    try std.testing.expectError(error.LengthOverflow, numpress.slofEncodedLen(std.math.maxInt(usize)));
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

test "[failure] - [numpress encoders]: reject invalid values, scales, and capacities" {
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

fn expectLinearErrorBound(expected: []const f64, actual: []const f64, fixed_point: f64) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_value, actual_value| {
        try std.testing.expectApproxEqAbs(expected_value, actual_value, 0.5 / fixed_point);
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

fn expectFinitePrefix(values: []const f64, count: usize) !void {
    try std.testing.expect(count <= values.len);
    for (values[0..count]) |value| try std.testing.expect(std.math.isFinite(value));
}
