//! Encodes and decodes the established MS-Numpress Linear, PIC, and SLOF transforms.
//!
//! Every operation uses caller-owned input and output storage and performs no heap allocation.
//! Linear and SLOF are lossy. PIC is exact only for integer-valued input in its supported range.

const std = @import("std");
const builtin = @import("builtin");
const math_options = @import("numpress_math_options");
const cpu = @import("cpu.zig");

const SlofMathBackend = enum { bundled, glibc_vector };
const SLOF_MATH_BACKEND = std.meta.stringToEnum(
    SlofMathBackend,
    math_options.slof_math_backend,
) orelse @compileError("invalid SLOF math backend");
comptime {
    if (SLOF_MATH_BACKEND == .glibc_vector and
        (builtin.target.os.tag != .linux or builtin.target.cpu.arch != .x86_64 or
            builtin.target.abi != .gnu))
    {
        @compileError("the glibc vector SLOF backend requires Linux x86_64 with the GNU ABI");
    }
}
const F64x2 = @Vector(2, f64);
const F64x4 = @Vector(4, f64);

extern fn _ZGVbN2v_exp(F64x2) callconv(.c) F64x2;
extern fn _ZGVdN4v_exp(F64x4) callconv(.c) F64x4;
extern fn _ZGVdN4v_log(F64x4) callconv(.c) F64x4;

/// Errors returned by checked MS-Numpress operations.
///
/// `InvalidData` describes encoded input. `InvalidValue` and `ValueOutOfRange` describe source
/// numbers. Output contents after an error are unspecified, but writes stay within the supplied span.
pub const Error = error{
    DecodedSizeMismatch,
    InvalidData,
    InvalidFixedPoint,
    InvalidValue,
    LengthOverflow,
    OutputTooSmall,
    ToleranceUnattainable,
    ValueOutOfRange,
};

/// Returns a safe upper bound for a linear encoding of `value_count` doubles.
pub fn linearMaxEncodedLen(value_count: usize) Error!usize {
    const initial_count: usize = @min(value_count, 2);
    const tail_count = value_count - initial_count;
    const tail_bytes = try maxNibbleBytes(tail_count);
    const initial_bytes = initial_count * 4;
    return std.math.add(usize, 8 + initial_bytes, tail_bytes) catch error.LengthOverflow;
}

/// Returns a safe upper bound for a positive-integer encoding.
pub fn picMaxEncodedLen(value_count: usize) Error!usize {
    return maxNibbleBytes(value_count);
}

/// Returns the exact encoded length of a short-logged-float array.
pub fn slofEncodedLen(value_count: usize) Error!usize {
    const body_len = std.math.mul(usize, value_count, 2) catch return error.LengthOverflow;
    return std.math.add(usize, 8, body_len) catch error.LengthOverflow;
}

fn maxNibbleBytes(value_count: usize) Error!usize {
    const pair_bytes = std.math.mul(usize, value_count / 2, 9) catch
        return error.LengthOverflow;
    const odd_bytes: usize = if (value_count % 2 == 0) 0 else 5;
    return std.math.add(usize, pair_bytes, odd_bytes) catch error.LengthOverflow;
}

/// Selects the largest finite linear fixed point for valid nonnegative data.
///
/// This matches the reference selector for nondegenerate input. For an all-zero
/// maximum it returns the largest signed 32-bit integer instead of infinity.
pub fn optimalLinearFixedPoint(values: []const f64) Error!f64 {
    if (values.len == 0) return 0;
    for (values) |value| try validateNonnegative(value);

    if (values.len == 1) return fixedPointForMaximum(values[0]);

    var maximum = @max(values[0], values[1]);
    var index: usize = 2;
    if (values.len >= 64) {
        maximum = try linearMaximumVector(values, index, maximum, &index);
    }
    return fixedPointForMaximum(try linearMaximumScalar(values, index, maximum));
}

fn linearMaximumVector(
    values: []const f64,
    start: usize,
    initial_maximum: f64,
    end: *usize,
) Error!f64 {
    const lanes = std.simd.suggestVectorLength(f64) orelse return initial_maximum;
    const F64Vector = @Vector(lanes, f64);
    const finite_limit: F64Vector = @splat(std.math.floatMax(f64));
    const one: F64Vector = @splat(1.0);
    var maximum = initial_maximum;
    var index = start;
    while (values.len - index >= lanes) : (index += lanes) {
        const current: F64Vector = values[index..][0..lanes].*;
        const previous_1: F64Vector = values[index - 1 ..][0..lanes].*;
        const previous_2: F64Vector = values[index - 2 ..][0..lanes].*;
        const extrapolated = previous_1 + (previous_1 - previous_2);
        if (!@reduce(.And, @abs(extrapolated) <= finite_limit)) {
            return error.ValueOutOfRange;
        }
        const candidates = @ceil(@abs(current - extrapolated) + one);
        maximum = @max(maximum, @reduce(.Max, candidates));
    }
    end.* = index;
    return maximum;
}

fn linearMaximumScalar(
    values: []const f64,
    start: usize,
    initial_maximum: f64,
) Error!f64 {
    var maximum = initial_maximum;
    for (values[start..], start..) |value, index| {
        const extrapolated = values[index - 1] + (values[index - 1] - values[index - 2]);
        if (!std.math.isFinite(extrapolated)) return error.ValueOutOfRange;
        maximum = @max(maximum, @ceil(@abs(value - extrapolated) + 1.0));
    }
    return maximum;
}

/// Selects a Linear fixed point that bounds rounding error by `max_abs_error`.
pub fn linearFixedPointForAbsoluteError(
    values: []const f64,
    max_abs_error: f64,
) Error!f64 {
    if (!std.math.isFinite(max_abs_error) or max_abs_error <= 0) {
        return error.InvalidValue;
    }
    if (values.len == 0) return 0;

    const required = 0.5 / max_abs_error;
    if (!std.math.isFinite(required) or required <= 0) {
        return error.ToleranceUnattainable;
    }
    const maximum = try optimalLinearFixedPoint(values);
    if (required > maximum) return error.ToleranceUnattainable;
    return required;
}

/// Selects the reference-compatible SLOF fixed point for valid nonnegative data.
pub fn optimalSlofFixedPoint(values: []const f64) Error!f64 {
    if (values.len == 0) return 0;

    var maximum: f64 = 1;
    for (values) |value| {
        try validateNonnegative(value);
        const logged = @log(value + 1.0);
        if (!std.math.isFinite(logged)) return error.ValueOutOfRange;
        maximum = @max(maximum, logged);
    }
    const fixed_point = @floor(65_535.0 / maximum);
    if (fixed_point < 1) return error.InvalidFixedPoint;
    return fixed_point;
}

/// Encodes nonnegative doubles with MS-Numpress linear prediction.
pub fn encodeLinear(values: []const f64, fixed_point: f64, output: []u8) Error!usize {
    try validateFixedPoint(fixed_point, values.len == 0);
    if (output.len < 8) return error.OutputTooSmall;
    writeFixedPoint(output[0..8], fixed_point);
    if (values.len == 0) return 8;

    const previous_2 = try scaleLinearInitial(values[0], fixed_point);
    if (output.len < 12) return error.OutputTooSmall;
    std.mem.writeInt(u32, output[8..12], @intCast(previous_2), .little);
    if (values.len == 1) return 12;

    const previous_1 = try scaleLinearInitial(values[1], fixed_point);
    if (output.len < 16) return error.OutputTooSmall;
    std.mem.writeInt(u32, output[12..16], @intCast(previous_1), .little);

    if (values.len >= 4 and previous_2 == previous_1 and
        std.mem.allEqual(f64, values[2..], values[1]))
    {
        const residual_count = values.len - 2;
        const encoded_len = residual_count / 2 + residual_count % 2;
        if (output.len - 16 < encoded_len) return error.OutputTooSmall;
        @memset(output[16..][0..encoded_len], 0x88);
        if (residual_count % 2 != 0) output[16 + encoded_len - 1] = 0x80;
        return 16 + encoded_len;
    }
    if (canUseWideLinear(values, fixed_point, output.len) and
        linearValuesAreValid(values[2..], fixed_point))
    {
        return encodeLinearWide(values[2..], fixed_point, output[16..], previous_2, previous_1);
    }
    if (canUseCommonLinear(values[2..], fixed_point, previous_2, previous_1) and
        linearValuesAreValid(values[2..], fixed_point) and
        hasReservedNibbleCapacity(output[16..], values.len - 2))
    {
        return encodeLinearCommon(values[2..], fixed_point, output[16..], previous_2, previous_1);
    }
    return encodeLinearScalar(values[2..], fixed_point, output[16..], previous_2, previous_1);
}

noinline fn encodeLinearScalar(
    values: []const f64,
    fixed_point: f64,
    output: []u8,
    initial_2: i64,
    initial_1: i64,
) Error!usize {
    var previous_2 = initial_2;
    var previous_1 = initial_1;
    var writer = NibbleWriter.init(output);
    for (values) |value| {
        const current = try scaleLinear(value, fixed_point);
        const residual = try linearResidual(current, previous_2, previous_1);
        const residual_bits: u32 = @bitCast(residual);
        if (residual_bits >= 0x0001_0000 and residual_bits <= 0x000f_ffff) {
            try writer.writeFiveNibble(residual_bits, 3);
        } else if (residual_bits >= 0xfff0_0000 and residual_bits <= 0xfffe_ffff) {
            try writer.writeFiveNibble(residual_bits, 11);
        } else {
            try writer.writeInt(residual_bits);
        }
        previous_2 = previous_1;
        previous_1 = current;
    }
    return 16 + writer.finish();
}

noinline fn encodeLinearCommon(
    values: []const f64,
    fixed_point: f64,
    output: []u8,
    initial_2: i64,
    initial_1: i64,
) align(32) Error!usize {
    var previous_2 = initial_2;
    var previous_1 = initial_1;
    var writer = NibbleWriter.init(output);
    for (values) |value| {
        const current = scaleLinearValidated(value, fixed_point);
        const residual_bits: u32 = @bitCast(try linearResidualValidated(current, previous_2, previous_1));
        try writeCommonLinearInt(&writer, residual_bits);
        previous_2 = previous_1;
        previous_1 = current;
    }
    return 16 + writer.finish();
}

inline fn writeCommonLinearInt(writer: *NibbleWriter, value: u32) Error!void {
    if (value == 0) {
        try writer.writeZero(true);
    } else if (value <= 0x0f) {
        try writer.writeOneNibble(value, 7, true);
    } else if (value >= 0xffff_fff0) {
        try writer.writeOneNibble(value, 15, true);
    } else if (value >= 0x100 and value <= 0x0fff) {
        try writer.writeThreeNibble(value, 5, true);
    } else if (value >= 0xffff_f000 and value <= 0xffff_feff) {
        try writer.writeThreeNibble(value, 13, true);
    } else if (value >= 0x1000 and value <= 0xffff) {
        try writer.writeFourNibble(value, 4, true);
    } else if (value >= 0xffff_0000 and value <= 0xffff_efff) {
        try writer.writeFourNibble(value, 12, true);
    } else {
        writeUncommonLinearIntReserved(writer, value);
    }
}

noinline fn writeUncommonLinearIntReserved(writer: *NibbleWriter, value: u32) void {
    const most_significant = value & 0xf000_0000;
    const leading: u4 = if (most_significant == 0)
        @intCast(@clz(value) / 4)
    else if (most_significant == 0xf000_0000)
        @intCast(@min(@clz(~value) / 4, 7))
    else
        0;
    const head: u4 = if (most_significant == 0xf000_0000) leading + 8 else leading;
    switch (8 - leading) {
        2 => writer.writeTwoNibbleReserved(value, head),
        5 => writer.writeFiveNibble(value, head) catch unreachable,
        6 => writer.writeSixNibbleReserved(value, head),
        7 => writer.writeSevenNibbleReserved(value, head),
        8 => writer.writeFullWidthReserved(value),
        else => writer.writeInt(value) catch unreachable,
    }
}

/// Decodes an MS-Numpress linear payload into caller-owned storage.
pub fn decodeLinear(input: []const u8, output: []f64) Error!usize {
    if (input.len < 8) return error.InvalidData;
    if (input.len > 8 and input.len < 12) return error.InvalidData;
    if (input.len > 12 and input.len < 16) return error.InvalidData;

    const fixed_point = readFixedPoint(input[0..8]);
    try validateFixedPoint(fixed_point, input.len == 8);
    if (input.len == 8) return 0;
    if (output.len < 1) return error.OutputTooSmall;
    const outputs_are_finite = fixed_point >= 1;

    const previous_2: i64 = std.mem.readInt(u32, input[8..12], .little);
    output[0] = if (outputs_are_finite)
        @as(f64, @floatFromInt(previous_2)) / fixed_point
    else
        try decodeLinearValue(previous_2, fixed_point);
    if (input.len == 12) return 1;
    if (output.len < 2) return error.OutputTooSmall;

    const previous_1: i64 = std.mem.readInt(u32, input[12..16], .little);
    output[1] = if (outputs_are_finite)
        @as(f64, @floatFromInt(previous_1)) / fixed_point
    else
        try decodeLinearValue(previous_1, fixed_point);
    const tail_input = input[16..];
    const tail_output = output[2..];
    if (previous_1 == previous_2 and
        tail_input.len != 0 and
        std.mem.allEqual(u8, tail_input, 0x88))
    {
        if (tail_input.len > tail_output.len / 2) return error.OutputTooSmall;
        const tail_count = tail_input.len * 2;
        fillDecoded(tail_output[0..tail_count], output[1]);
        return 2 + tail_count;
    }
    const use_word_body = tail_input.len / 4 > tail_output.len;
    const use_short_body = isShortIntegerPayload(tail_input.len, tail_output.len);
    if (tail_output.len <= MAX_UNCHECKED_LINEAR_TAIL and !use_word_body and !use_short_body) {
        const tail_count = if (outputs_are_finite)
            try decodeLinearTailBounded(false, tail_input, tail_output, fixed_point, previous_2, previous_1)
        else
            try decodeLinearTailBounded(true, tail_input, tail_output, fixed_point, previous_2, previous_1);
        return 2 + tail_count;
    }
    const tail_count = if (outputs_are_finite)
        if (use_word_body)
            try decodeLinearTail(false, true, false, tail_input, tail_output, fixed_point, previous_2, previous_1)
        else if (use_short_body)
            try decodeLinearTail(false, false, true, tail_input, tail_output, fixed_point, previous_2, previous_1)
        else
            try decodeLinearTail(false, false, false, tail_input, tail_output, fixed_point, previous_2, previous_1)
    else if (use_word_body)
        try decodeLinearTail(true, true, false, tail_input, tail_output, fixed_point, previous_2, previous_1)
    else if (use_short_body)
        try decodeLinearTail(true, false, true, tail_input, tail_output, fixed_point, previous_2, previous_1)
    else
        try decodeLinearTail(true, false, false, tail_input, tail_output, fixed_point, previous_2, previous_1);
    return 2 + tail_count;
}

noinline fn decodeLinearTail(
    comptime check_finite: bool,
    comptime use_word_body: bool,
    comptime use_short_body: bool,
    input: []const u8,
    output: []f64,
    fixed_point: f64,
    initial_2: i64,
    initial_1: i64,
) Error!usize {
    var previous_2 = initial_2;
    var previous_1 = initial_1;
    var count: usize = 0;
    var reader = NibbleReader.init(input);

    while (!reader.atEnd()) {
        if (reader.onlyZeroPaddingRemains()) break;
        if (count == output.len) return error.OutputTooSmall;
        const residual_bits = try readNumpressInt(&reader, use_word_body, false, use_short_body);
        const residual: i32 = @bitCast(residual_bits);
        const step = std.math.sub(i64, previous_1, previous_2) catch
            return error.InvalidData;
        const extrapolated = std.math.add(i64, previous_1, step) catch
            return error.InvalidData;
        const current = std.math.add(i64, extrapolated, residual) catch
            return error.InvalidData;
        const decoded = @as(f64, @floatFromInt(current)) / fixed_point;
        if (comptime check_finite) {
            if (!std.math.isFinite(decoded)) return error.InvalidData;
        }
        output[count] = decoded;
        count += 1;
        previous_2 = previous_1;
        previous_1 = current;
    }
    return count;
}

const MAX_UNCHECKED_LINEAR_TAIL = 65_536;

comptime {
    const last_index: u128 = MAX_UNCHECKED_LINEAR_TAIL + 1;
    const initial_bound: u128 = std.math.maxInt(u32);
    const residual_bound: u128 = 1 << 31;
    const value_bound = initial_bound + last_index * initial_bound +
        residual_bound * last_index * (last_index - 1) / 2;
    if (value_bound > std.math.maxInt(i64)) @compileError("unchecked Linear recurrence can overflow");
}

noinline fn decodeLinearTailBounded(
    comptime check_finite: bool,
    input: []const u8,
    output: []f64,
    fixed_point: f64,
    initial_2: i64,
    initial_1: i64,
) Error!usize {
    var previous_2 = initial_2;
    var previous_1 = initial_1;
    var count: usize = 0;
    var reader = NibbleReader.init(input);

    while (!reader.atEnd()) {
        if (reader.onlyZeroPaddingRemains()) break;
        if (count == output.len) return error.OutputTooSmall;
        const residual_bits = try readNumpressInt(&reader, false, false, false);
        const residual: i32 = @bitCast(residual_bits);
        const current = previous_1 + (previous_1 - previous_2) + @as(i64, residual);
        const decoded = @as(f64, @floatFromInt(current)) / fixed_point;
        if (comptime check_finite) {
            if (!std.math.isFinite(decoded)) return error.InvalidData;
        }
        output[count] = decoded;
        count += 1;
        previous_2 = previous_1;
        previous_1 = current;
    }
    return count;
}

/// Decodes exactly `output.len` Linear values.
pub fn decodeLinearExact(input: []const u8, output: []f64) Error!void {
    const count = decodeLinear(input, output) catch |err| switch (err) {
        error.OutputTooSmall => return error.DecodedSizeMismatch,
        else => return err,
    };
    if (count != output.len) return error.DecodedSizeMismatch;
}

/// Encodes finite doubles from zero through `maxInt(u32)` by rounding to the
/// nearest integer and applying the Numpress integer code.
pub fn encodePic(values: []const f64, output: []u8) align(64) Error!usize {
    if (values.len >= 4 and std.mem.allEqual(f64, values, 0)) {
        const encoded_len = values.len / 2 + values.len % 2;
        if (output.len < encoded_len) return error.OutputTooSmall;
        @memset(output[0..encoded_len], 0x88);
        if (values.len % 2 != 0) output[encoded_len - 1] = 0x80;
        return encoded_len;
    }
    if (canUseLowPic(values)) return encodePicLow(values, output);
    if (canUseWidePic(values, output.len)) return encodePicWide(values, output);
    if (canUseFiveNibblePic(values) and picValuesAreValid(values)) {
        return encodePicFiveNibble(values, output);
    }

    return encodePicScalar(values, output);
}

noinline fn encodePicScalar(values: []const f64, output: []u8) Error!usize {
    var writer = NibbleWriter.init(output);
    for (values) |value| {
        try writer.writeInt(try roundedPic(value));
    }
    return writer.finish();
}

fn canUseWideLinear(values: []const f64, fixed_point: f64, output_len: usize) bool {
    if (values.len < 4) return false;
    const required = linearMaxEncodedLen(values.len) catch return false;
    if (output_len < required) return false;

    var previous_2 = scaleLinearInitial(values[0], fixed_point) catch return false;
    var previous_1 = scaleLinearInitial(values[1], fixed_point) catch return false;
    for (values[2..4]) |value| {
        const current = scaleLinear(value, fixed_point) catch return false;
        const step = std.math.sub(i64, previous_1, previous_2) catch return false;
        const extrapolated = std.math.add(i64, previous_1, step) catch return false;
        const residual = std.math.sub(i64, current, extrapolated) catch return false;
        if (residual < std.math.minInt(i32) or residual > std.math.maxInt(i32)) return false;
        if (!isFullWidth(@bitCast(@as(i32, @intCast(residual))))) return false;
        previous_2 = previous_1;
        previous_1 = current;
    }
    return true;
}

fn canUseCommonLinear(values: []const f64, fixed_point: f64, initial_2: i64, initial_1: i64) bool {
    if (values.len < 16) return false;
    var previous_2 = initial_2;
    var previous_1 = initial_1;
    var common_count: usize = 0;
    for (values[0..16]) |value| {
        const current = scaleLinear(value, fixed_point) catch return false;
        const residual: u32 = @bitCast(linearResidual(current, previous_2, previous_1) catch return false);
        common_count += @intFromBool(residual <= 0xffff or residual >= 0xffff_0000);
        previous_2 = previous_1;
        previous_1 = current;
    }
    return common_count >= 12;
}

fn linearValuesAreValid(values: []const f64, fixed_point: f64) bool {
    const lanes = std.simd.suggestVectorLength(f64) orelse return linearValuesAreValidScalar(values, fixed_point);
    const F64Vector = @Vector(lanes, f64);
    const zero: F64Vector = @splat(0);
    const finite_limit: F64Vector = @splat(std.math.floatMax(f64));
    const fixed: F64Vector = @splat(fixed_point);
    const half: F64Vector = @splat(0.5);
    const scaled_limit: F64Vector = @splat(0x1p61);
    var index: usize = 0;
    while (values.len - index >= lanes) : (index += lanes) {
        const current: F64Vector = values[index..][0..lanes].*;
        const scaled = current * fixed + half;
        if (!@reduce(.And, (current >= zero) & (@abs(current) <= finite_limit) &
            (@abs(scaled) <= finite_limit) & (scaled < scaled_limit))) return false;
    }
    return linearValuesAreValidScalar(values[index..], fixed_point);
}

fn linearValuesAreValidScalar(values: []const f64, fixed_point: f64) bool {
    for (values) |value| {
        if (!std.math.isFinite(value) or value < 0) return false;
        const scaled_source = value * fixed_point + 0.5;
        if (!std.math.isFinite(scaled_source) or scaled_source >= 0x1p61) return false;
    }
    return true;
}

fn hasReservedNibbleCapacity(output: []const u8, value_count: usize) bool {
    const required = maxNibbleBytes(value_count) catch return false;
    return output.len >= required;
}

fn canUseLowPic(values: []const f64) bool {
    if (values.len < 16) return false;
    var has_common_nonzero = false;
    for (values[0..16]) |value| {
        const rounded = roundedPic(value) catch return false;
        if (rounded > 0x0000_ffff) return false;
        has_common_nonzero = has_common_nonzero or rounded >= 0x100;
    }
    return has_common_nonzero;
}

fn canUseWidePic(values: []const f64, output_len: usize) bool {
    if (values.len < 4) return false;
    const required = picMaxEncodedLen(values.len) catch return false;
    if (output_len < required) return false;

    var wide_count: usize = 0;
    for (values[0..4]) |value| {
        const rounded = roundedPic(value) catch return false;
        wide_count += @intFromBool(isFullWidth(rounded));
    }
    return wide_count >= 3;
}

fn canUseFiveNibblePic(values: []const f64) bool {
    if (values.len < 4) return false;
    return hasFiveBodyNibbles(roundedPic(values[0]) catch return false) and
        hasFiveBodyNibbles(roundedPic(values[1]) catch return false);
}

fn picValuesAreValid(values: []const f64) bool {
    const lanes = std.simd.suggestVectorLength(f64) orelse return picValuesAreValidScalar(values);
    const F64Vector = @Vector(lanes, f64);
    const zero: F64Vector = @splat(0);
    const finite_limit: F64Vector = @splat(std.math.floatMax(f64));
    const regular_maximum: F64Vector = @splat(
        @as(f64, @floatFromInt(std.math.maxInt(u32))) - 0.5,
    );
    var index: usize = 0;
    while (values.len - index >= lanes) : (index += lanes) {
        const current: F64Vector = values[index..][0..lanes].*;
        if (!@reduce(.And, (current >= zero) & (@abs(current) <= finite_limit) &
            (current < regular_maximum))) return false;
    }
    return picValuesAreValidScalar(values[index..]);
}

fn picValuesAreValidScalar(values: []const f64) bool {
    const regular_maximum = @as(f64, @floatFromInt(std.math.maxInt(u32))) - 0.5;
    for (values) |value| {
        if (!std.math.isFinite(value) or value < 0 or value >= regular_maximum) return false;
    }
    return true;
}

noinline fn encodeLinearWide(
    values: []const f64,
    fixed_point: f64,
    output: []u8,
    initial_2: i64,
    initial_1: i64,
) Error!usize {
    var writer = NibbleWriter.init(output);
    var previous_2 = initial_2;
    var previous_1 = initial_1;
    var index: usize = 0;
    while (values.len - index >= 2) : (index += 2) {
        const current_0 = scaleLinearValidated(values[index], fixed_point);
        const residual_0 = try linearResidualValidated(current_0, previous_2, previous_1);
        const current_1 = scaleLinearValidated(values[index + 1], fixed_point);
        const residual_1 = try linearResidualValidated(current_1, previous_1, current_0);
        if (!writer.writeFullWidthPairReserved(@bitCast(residual_0), @bitCast(residual_1), false)) {
            try writer.writeInt(@bitCast(residual_0));
            try writer.writeInt(@bitCast(residual_1));
        }
        previous_2 = current_0;
        previous_1 = current_1;
    }
    if (index < values.len) {
        const current = scaleLinearValidated(values[index], fixed_point);
        const residual = try linearResidualValidated(current, previous_2, previous_1);
        try writer.writeInt(@bitCast(residual));
    }
    return 16 + writer.finish();
}

noinline fn encodePicWide(values: []const f64, output: []u8) align(64) Error!usize {
    var writer = NibbleWriter.init(output);
    var index: usize = 0;
    while (values.len - index >= 2) : (index += 2) {
        const rounded_0 = try roundedPic(values[index]);
        const rounded_1 = try roundedPic(values[index + 1]);
        if (!writer.writeFullWidthPairReserved(rounded_0, rounded_1, true)) {
            if (isFullWidth(rounded_0)) {
                try writer.writeFullWidth(rounded_0);
            } else if (hasSevenBodyNibbles(rounded_0)) {
                try writer.writeSevenNibble(rounded_0);
            } else {
                try writer.writeInt(rounded_0);
            }
            if (isFullWidth(rounded_1)) {
                try writer.writeFullWidth(rounded_1);
            } else if (hasSevenBodyNibbles(rounded_1)) {
                try writer.writeSevenNibble(rounded_1);
            } else {
                try writer.writeInt(rounded_1);
            }
        }
    }
    if (index < values.len) try writer.writeInt(try roundedPic(values[index]));
    return writer.finish();
}

noinline fn encodePicFiveNibble(values: []const f64, output: []u8) Error!usize {
    var writer = NibbleWriter.init(output);
    var index: usize = 0;
    while (values.len - index >= 2) : (index += 2) {
        const rounded_0 = roundedPicValidated(values[index]);
        const rounded_1 = roundedPicValidated(values[index + 1]);
        if (!try writer.writeFiveNibblePair(rounded_0, rounded_1)) {
            try writePicFiveFallback(&writer, rounded_0, rounded_1);
        }
    }
    if (index < values.len) try writer.writeInt(roundedPicValidated(values[index]));
    return writer.finish();
}

inline fn writePicFiveFallback(writer: *NibbleWriter, first: u32, second: u32) Error!void {
    if (hasFiveBodyNibbles(first)) {
        try writer.writeFiveNibble(first, 3);
    } else if (first >= 0x1000 and first <= 0xffff) {
        try writer.writeFourNibble(first, 4, false);
    } else {
        try writer.writeInt(first);
    }
    if (hasFiveBodyNibbles(second)) {
        try writer.writeFiveNibble(second, 3);
    } else if (second >= 0x1000 and second <= 0xffff) {
        try writer.writeFourNibble(second, 4, false);
    } else {
        try writer.writeInt(second);
    }
}

noinline fn encodePicLow(values: []const f64, output: []u8) align(64) Error!usize {
    var writer = NibbleWriter.init(output);
    var index: usize = 0;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        if (value == 0 and index + 1 < values.len and values[index + 1] == 0) {
            try writer.writeZeroPair();
            index += 1;
            continue;
        }
        const rounded = try roundedPic(value);
        if (rounded == 0) {
            try writer.writeZero(false);
        } else if (rounded >= 0x100 and rounded <= 0x0fff) {
            try writer.writeThreeNibble(rounded, 5, false);
        } else if (rounded >= 0x1000 and rounded <= 0xffff) {
            try writer.writeFourNibble(rounded, 4, false);
        } else {
            try writer.writeInt(rounded);
        }
    }
    return writer.finish();
}

fn linearResidual(current: i64, previous_2: i64, previous_1: i64) Error!i32 {
    const step = std.math.sub(i64, previous_1, previous_2) catch
        return error.ValueOutOfRange;
    const extrapolated = std.math.add(i64, previous_1, step) catch
        return error.ValueOutOfRange;
    const residual = std.math.sub(i64, current, extrapolated) catch
        return error.ValueOutOfRange;
    if (residual < std.math.minInt(i32) or residual > std.math.maxInt(i32)) {
        return error.ValueOutOfRange;
    }
    return @intCast(residual);
}

fn linearResidualValidated(current: i64, previous_2: i64, previous_1: i64) Error!i32 {
    const residual = current - (previous_1 + (previous_1 - previous_2));
    if (residual < std.math.minInt(i32) or residual > std.math.maxInt(i32)) {
        return error.ValueOutOfRange;
    }
    return @intCast(residual);
}

fn roundedPic(value: f64) Error!u32 {
    try validateNonnegative(value);
    const regular_maximum = @as(f64, @floatFromInt(std.math.maxInt(u32))) - 0.5;
    if (value < regular_maximum) return @intFromFloat(value + 0.5);
    const maximum: f64 = @floatFromInt(std.math.maxInt(u32));
    if (value > maximum) return error.ValueOutOfRange;
    return std.math.maxInt(u32);
}

inline fn roundedPicValidated(value: f64) u32 {
    return @intFromFloat(value + 0.5);
}

fn isFullWidth(value: u32) bool {
    const most_significant = value & 0xf000_0000;
    return most_significant != 0 and most_significant != 0xf000_0000;
}

fn hasFiveBodyNibbles(value: u32) bool {
    return value >= 0x0001_0000 and value <= 0x000f_ffff;
}

fn hasSevenBodyNibbles(value: u32) bool {
    return value >= 0x0100_0000 and value <= 0x0fff_ffff;
}

/// Decodes an MS-Numpress positive-integer payload into doubles.
pub fn decodePic(input: []const u8, output: []f64) Error!usize {
    if (input.len / 4 > output.len) return decodePicWithReader(true, false, false, input, output);
    if (output.len <= 4_096 and isMediumIntegerPayload(input.len, output.len)) {
        return decodePicWithReader(false, true, false, input, output);
    }
    if (isShortIntegerPayload(input.len, output.len)) {
        return decodePicWithReader(false, false, true, input, output);
    }
    return decodePicWithReader(false, false, false, input, output);
}

fn decodePicWithReader(
    comptime use_word_body: bool,
    comptime use_five_body: bool,
    comptime use_short_body: bool,
    input: []const u8,
    output: []f64,
) Error!usize {
    if (input.len != 0 and std.mem.allEqual(u8, input, 0x88)) {
        if (input.len > output.len / 2) return error.OutputTooSmall;
        const count = input.len * 2;
        fillDecoded(output[0..count], 0);
        return count;
    }
    var reader = NibbleReader.init(input);
    var count: usize = 0;
    while (!reader.atEnd()) {
        if (reader.onlyZeroPaddingRemains()) break;
        if (count == output.len) return error.OutputTooSmall;
        output[count] = @floatFromInt(try readNumpressInt(
            &reader,
            use_word_body,
            use_five_body,
            use_short_body,
        ));
        count += 1;
    }
    return count;
}

/// Decodes exactly `output.len` PIC values.
pub fn decodePicExact(input: []const u8, output: []f64) Error!void {
    const count = decodePic(input, output) catch |err| switch (err) {
        error.OutputTooSmall => return error.DecodedSizeMismatch,
        else => return err,
    };
    if (count != output.len) return error.DecodedSizeMismatch;
}

/// Encodes nonnegative doubles with the MS-Numpress short logged float transform.
pub fn encodeSlof(values: []const f64, fixed_point: f64, output: []u8) Error!usize {
    try validateFixedPoint(fixed_point, values.len == 0);
    const encoded_len = try slofEncodedLen(values.len);
    if (output.len < encoded_len) return error.OutputTooSmall;
    writeFixedPoint(output[0..8], fixed_point);

    if (comptime SLOF_MATH_BACKEND == .glibc_vector) {
        if (cpu.hasAvx2()) {
            try encodeSlofAvx2(values, fixed_point, output, encoded_len);
            return encoded_len;
        }
    }
    for (values, 0..) |value, index| {
        try validateNonnegative(value);
        try writeSlofCode(output, index, @log(value + 1.0) * fixed_point);
    }
    return encoded_len;
}

noinline fn encodeSlofAvx2(
    values: []const f64,
    fixed_point: f64,
    output: []u8,
    encoded_len: usize,
) Error!void {
    if (slofAllZero(values)) {
        @memset(output[8..encoded_len], 0);
        return;
    }
    var index: usize = 0;
    while (values.len - index >= 4) : (index += 4) {
        const current: F64x4 = values[index..][0..4].*;
        const valid = (@abs(current) <= @as(F64x4, @splat(std.math.floatMax(f64)))) &
            (current >= @as(F64x4, @splat(0)));
        if (!@reduce(.And, valid)) {
            inline for (0..4) |lane| {
                const value = current[lane];
                try validateNonnegative(value);
                try writeSlofCode(output, index + lane, @log(value + 1.0) * fixed_point);
            }
            continue;
        }
        const logged = _ZGVdN4v_log(current + @as(F64x4, @splat(1.0)));
        const scaled = logged * @as(F64x4, @splat(fixed_point));
        if (@reduce(.And, slofCandidatesAreStable(scaled, fixed_point))) {
            const encoded: @Vector(4, u16) = @intFromFloat(scaled + @as(F64x4, @splat(0.5)));
            inline for (0..4) |lane| {
                std.mem.writeInt(u16, output[8 + (index + lane) * 2 ..][0..2], encoded[lane], .little);
            }
            continue;
        }
        inline for (0..4) |lane| {
            try writeGuardedSlofCode(current[lane], logged[lane], fixed_point, output, index + lane);
        }
    }
    while (index < values.len) : (index += 1) {
        const value = values[index];
        try validateNonnegative(value);
        try writeSlofCode(output, index, @log(value + 1.0) * fixed_point);
    }
}

fn slofAllZero(values: []const f64) bool {
    if (values.len < 16) return false;
    var index: usize = 0;
    while (values.len - index >= 4) : (index += 4) {
        const current: F64x4 = values[index..][0..4].*;
        if (!@reduce(.And, current == @as(F64x4, @splat(0)))) return false;
    }
    for (values[index..]) |value| {
        if (value != 0) return false;
    }
    return true;
}

inline fn writeGuardedSlofCode(
    value: f64,
    logged: f64,
    fixed_point: f64,
    output: []u8,
    index: usize,
) Error!void {
    try validateNonnegative(value);
    if (value == 0) return writeSlofCode(output, index, 0);

    const scaled = logged * fixed_point;
    if (slofCandidateIsStable(logged, scaled, fixed_point)) {
        return writeSlofCode(output, index, scaled);
    }
    return writeSlofCode(output, index, @log(value + 1.0) * fixed_point);
}

inline fn slofCandidateIsStable(logged: f64, scaled: f64, fixed_point: f64) bool {
    if (!std.math.isFinite(logged) or !std.math.isFinite(scaled) or
        scaled < 0 or scaled > 65_535.0)
    {
        return false;
    }

    const half_distance = @abs(scaled - (@floor(scaled) + 0.5));
    const epsilon = std.math.floatEps(f64);
    const true_min = std.math.floatTrueMin(f64);
    const log_ulp = @max(@abs(logged) * epsilon, true_min);
    const scaled_ulp = @max(@abs(scaled) * epsilon, true_min);
    const error_bound = 16.0 * log_ulp * fixed_point + 2.0 * scaled_ulp;
    return std.math.isFinite(error_bound) and half_distance > error_bound;
}

inline fn slofCandidatesAreStable(scaled: F64x4, fixed_point: f64) @Vector(4, bool) {
    const finite_limit: F64x4 = @splat(std.math.floatMax(f64));
    const half_distance = @abs(scaled - (@floor(scaled) + @as(F64x4, @splat(0.5))));
    const epsilon = std.math.floatEps(f64);
    // Sixteen ULP over log(maxFloat) covers the documented four-ULP libmvec
    // error, the sub-ULP bundled reference error, and conversion slack.
    const error_bound: F64x4 = @splat(
        16.0 * 710.0 * epsilon * fixed_point + 2.0 * epsilon * 65_535.0,
    );
    return (@abs(scaled) <= finite_limit) & (scaled >= @as(F64x4, @splat(0))) &
        (scaled <= @as(F64x4, @splat(65_535.0))) & (half_distance > error_bound);
}

/// Decodes an MS-Numpress short-logged-float payload into caller-owned storage.
pub fn decodeSlof(input: []const u8, output: []f64) Error!usize {
    if (input.len < 8 or (input.len - 8) % 2 != 0) return error.InvalidData;
    const value_count = (input.len - 8) / 2;
    if (output.len < value_count) return error.OutputTooSmall;
    const fixed_point = readFixedPoint(input[0..8]);
    try validateFixedPoint(fixed_point, value_count == 0);
    const body = input[8..];
    if (comptime SLOF_MATH_BACKEND == .glibc_vector) {
        if (decodeSlofIfZeroBody(body, output[0..value_count])) return value_count;
    } else if (body.len != 0 and body[0] == 0 and std.mem.allEqual(u8, body, 0)) {
        fillDecoded(output[0..value_count], 0);
        return value_count;
    }

    var index: usize = 0;
    if (comptime SLOF_MATH_BACKEND == .glibc_vector) {
        if (cpu.hasAvx2()) {
            while (value_count - index >= 4) : (index += 4) {
                const encoded: @Vector(4, u16) = .{
                    std.mem.readInt(u16, input[8 + index * 2 ..][0..2], .little),
                    std.mem.readInt(u16, input[10 + index * 2 ..][0..2], .little),
                    std.mem.readInt(u16, input[12 + index * 2 ..][0..2], .little),
                    std.mem.readInt(u16, input[14 + index * 2 ..][0..2], .little),
                };
                const scaled: F64x4 = @as(F64x4, @floatFromInt(encoded)) /
                    @as(F64x4, @splat(fixed_point));
                const decoded = _ZGVdN4v_exp(scaled) - @as(F64x4, @splat(1.0));
                if (!@reduce(.And, @abs(decoded) <= @as(F64x4, @splat(std.math.floatMax(f64))))) {
                    return error.InvalidData;
                }
                inline for (0..4) |lane| output[index + lane] = decoded[lane];
            }
        }
        while (value_count - index >= 2) : (index += 2) {
            const encoded_0 = std.mem.readInt(u16, input[8 + index * 2 ..][0..2], .little);
            const encoded_1 = std.mem.readInt(u16, input[10 + index * 2 ..][0..2], .little);
            const scaled: F64x2 = .{
                @as(f64, @floatFromInt(encoded_0)) / fixed_point,
                @as(f64, @floatFromInt(encoded_1)) / fixed_point,
            };
            const decoded = _ZGVbN2v_exp(scaled) - @as(F64x2, @splat(1.0));
            if (!std.math.isFinite(decoded[0]) or !std.math.isFinite(decoded[1])) {
                return error.InvalidData;
            }
            output[index] = decoded[0];
            output[index + 1] = decoded[1];
        }
    }
    while (index < value_count) : (index += 1) {
        const encoded = std.mem.readInt(u16, input[8 + index * 2 ..][0..2], .little);
        const decoded = slofExp(@as(f64, @floatFromInt(encoded)) / fixed_point) - 1.0;
        if (!std.math.isFinite(decoded)) return error.InvalidData;
        output[index] = decoded;
    }
    return value_count;
}

fn decodeSlofIfZeroBody(body: []const u8, output: []f64) bool {
    if (body.len == 0 or body[0] != 0) return false;

    // A late nonzero can leave a zero prefix; decodeSlof restarts at index zero.
    const ByteVector = @Vector(16, u8);
    const zero_bytes: ByteVector = @splat(0);
    var byte_index: usize = 0;
    var output_index: usize = 0;
    while (body.len - byte_index >= 16) : (byte_index += 16) {
        const current: ByteVector = body[byte_index..][0..16].*;
        if (!@reduce(.And, current == zero_bytes)) return false;
        inline for (0..8) |lane| output[output_index + lane] = 0;
        output_index += 8;
    }
    if (!std.mem.allEqual(u8, body[byte_index..], 0)) return false;
    @memset(output[output_index..], 0);
    return true;
}

/// Decodes exactly `output.len` SLOF values.
pub fn decodeSlofExact(input: []const u8, output: []f64) Error!void {
    if (input.len < 8 or (input.len - 8) % 2 != 0) return error.InvalidData;
    if ((input.len - 8) / 2 != output.len) return error.DecodedSizeMismatch;
    _ = try decodeSlof(input, output);
}

fn fixedPointForMaximum(maximum: f64) Error!f64 {
    if (!std.math.isFinite(maximum) or maximum < 0) return error.InvalidValue;
    if (maximum == 0) return @floatFromInt(std.math.maxInt(i32));
    const fixed_point = @floor(@as(f64, @floatFromInt(std.math.maxInt(i32))) / maximum);
    if (!std.math.isFinite(fixed_point) or fixed_point < 1) return error.InvalidFixedPoint;
    return fixed_point;
}

fn writeSlofCode(output: []u8, index: usize, scaled: f64) Error!void {
    if (!std.math.isFinite(scaled) or scaled > 65_535.0) {
        return error.ValueOutOfRange;
    }
    const encoded: u16 = @intFromFloat(scaled + 0.5);
    std.mem.writeInt(u16, output[8 + index * 2 ..][0..2], encoded, .little);
}

inline fn slofExp(value: f64) f64 {
    return switch (comptime SLOF_MATH_BACKEND) {
        .bundled => @exp(value),
        .glibc_vector => _ZGVbN2v_exp(.{ value, value })[0],
    };
}

fn validateNonnegative(value: f64) Error!void {
    if (!std.math.isFinite(value)) return error.InvalidValue;
    if (value < 0) return error.InvalidValue;
}

fn validateFixedPoint(fixed_point: f64, allow_zero: bool) Error!void {
    if (!std.math.isFinite(fixed_point) or fixed_point < 0) return error.InvalidFixedPoint;
    if (!allow_zero and fixed_point == 0) return error.InvalidFixedPoint;
}

fn scaleLinear(value: f64, fixed_point: f64) Error!i64 {
    try validateNonnegative(value);
    const scaled_source = value * fixed_point + 0.5;
    if (!std.math.isFinite(scaled_source) or scaled_source >= 0x1p63) {
        return error.ValueOutOfRange;
    }
    return @intFromFloat(scaled_source);
}

inline fn scaleLinearValidated(value: f64, fixed_point: f64) i64 {
    return @intFromFloat(value * fixed_point + 0.5);
}

fn scaleLinearInitial(value: f64, fixed_point: f64) Error!i64 {
    const scaled = try scaleLinear(value, fixed_point);
    if (scaled > std.math.maxInt(u32)) return error.ValueOutOfRange;
    return scaled;
}

fn decodeLinearValue(value: i64, fixed_point: f64) Error!f64 {
    const decoded = @as(f64, @floatFromInt(value)) / fixed_point;
    if (!std.math.isFinite(decoded)) return error.InvalidData;
    return decoded;
}

noinline fn fillDecoded(output: []f64, value: f64) void {
    @memset(output, value);
}

fn writeFixedPoint(output: *[8]u8, fixed_point: f64) void {
    std.mem.writeInt(u64, output, @bitCast(fixed_point), .big);
}

fn readFixedPoint(input: *const [8]u8) f64 {
    return @bitCast(std.mem.readInt(u64, input, .big));
}

const NibbleWriter = struct {
    output: []u8,
    byte_index: usize = 0,
    low_half: bool = false,

    fn init(output: []u8) NibbleWriter {
        return .{ .output = output };
    }

    fn writeInt(writer: *NibbleWriter, value: u32) Error!void {
        const most_significant = value & 0xf000_0000;
        if (most_significant == 0) {
            const leading: u4 = @intCast(@clz(value) / 4);
            try writer.writeNibble(leading);
            try writer.writeBody(value, leading);
        } else if (most_significant == 0xf000_0000) {
            const leading: u4 = @intCast(@min(@clz(~value) / 4, 7));
            try writer.writeNibble(leading + 8);
            try writer.writeBody(value, leading);
        } else {
            try writer.writeNibble(0);
            try writer.writeBody(value, 0);
        }
    }

    fn writeFullWidthPairReserved(
        writer: *NibbleWriter,
        first: u32,
        second: u32,
        comptime allow_half_aligned: bool,
    ) bool {
        if (!isFullWidth(first) or !isFullWidth(second)) return false;
        if (allow_half_aligned and writer.low_half) {
            const bytes = writer.output[writer.byte_index..][0..10];
            bytes[1] = valueNibble(first, 0) << 4 | valueNibble(first, 1);
            bytes[2] = valueNibble(first, 2) << 4 | valueNibble(first, 3);
            bytes[3] = valueNibble(first, 4) << 4 | valueNibble(first, 5);
            bytes[4] = valueNibble(first, 6) << 4 | valueNibble(first, 7);
            bytes[5] = valueNibble(second, 0);
            bytes[6] = valueNibble(second, 1) << 4 | valueNibble(second, 2);
            bytes[7] = valueNibble(second, 3) << 4 | valueNibble(second, 4);
            bytes[8] = valueNibble(second, 5) << 4 | valueNibble(second, 6);
            bytes[9] = valueNibble(second, 7) << 4;
            writer.byte_index += 9;
            return true;
        }
        if (writer.low_half) return false;
        const bytes = writer.output[writer.byte_index..][0..9];
        bytes[0] = valueNibble(first, 0);
        bytes[1] = valueNibble(first, 1) << 4 | valueNibble(first, 2);
        bytes[2] = valueNibble(first, 3) << 4 | valueNibble(first, 4);
        bytes[3] = valueNibble(first, 5) << 4 | valueNibble(first, 6);
        bytes[4] = valueNibble(first, 7) << 4;
        bytes[5] = valueNibble(second, 0) << 4 | valueNibble(second, 1);
        bytes[6] = valueNibble(second, 2) << 4 | valueNibble(second, 3);
        bytes[7] = valueNibble(second, 4) << 4 | valueNibble(second, 5);
        bytes[8] = valueNibble(second, 6) << 4 | valueNibble(second, 7);
        writer.byte_index += 9;
        return true;
    }

    fn writeFullWidth(writer: *NibbleWriter, value: u32) Error!void {
        if (writer.low_half) {
            if (writer.output.len - writer.byte_index < 5) return error.OutputTooSmall;
            const bytes = writer.output[writer.byte_index..][0..5];
            bytes[1] = valueNibble(value, 0) << 4 | valueNibble(value, 1);
            bytes[2] = valueNibble(value, 2) << 4 | valueNibble(value, 3);
            bytes[3] = valueNibble(value, 4) << 4 | valueNibble(value, 5);
            bytes[4] = valueNibble(value, 6) << 4 | valueNibble(value, 7);
            writer.byte_index += 5;
            writer.low_half = false;
            return;
        }
        if (writer.output.len - writer.byte_index < 5) return error.OutputTooSmall;
        const bytes = writer.output[writer.byte_index..][0..5];
        bytes[0] = valueNibble(value, 0);
        bytes[1] = valueNibble(value, 1) << 4 | valueNibble(value, 2);
        bytes[2] = valueNibble(value, 3) << 4 | valueNibble(value, 4);
        bytes[3] = valueNibble(value, 5) << 4 | valueNibble(value, 6);
        bytes[4] = valueNibble(value, 7) << 4;
        writer.byte_index += 4;
        writer.low_half = true;
    }

    fn writeFullWidthReserved(writer: *NibbleWriter, value: u32) void {
        if (writer.low_half) {
            const bytes = writer.output[writer.byte_index..][0..5];
            bytes[1] = valueNibble(value, 0) << 4 | valueNibble(value, 1);
            bytes[2] = valueNibble(value, 2) << 4 | valueNibble(value, 3);
            bytes[3] = valueNibble(value, 4) << 4 | valueNibble(value, 5);
            bytes[4] = valueNibble(value, 6) << 4 | valueNibble(value, 7);
            writer.byte_index += 5;
            writer.low_half = false;
            return;
        }
        const bytes = writer.output[writer.byte_index..][0..5];
        bytes[0] = valueNibble(value, 0);
        bytes[1] = valueNibble(value, 1) << 4 | valueNibble(value, 2);
        bytes[2] = valueNibble(value, 3) << 4 | valueNibble(value, 4);
        bytes[3] = valueNibble(value, 5) << 4 | valueNibble(value, 6);
        bytes[4] = valueNibble(value, 7) << 4;
        writer.byte_index += 4;
        writer.low_half = true;
    }

    fn writeTwoNibbleReserved(writer: *NibbleWriter, value: u32, head: u4) void {
        const bytes = writer.output[writer.byte_index..][0..2];
        if (writer.low_half) {
            bytes[0] |= head;
            bytes[1] = valueNibble(value, 0) << 4 | valueNibble(value, 1);
            writer.byte_index += 2;
            writer.low_half = false;
        } else {
            bytes[0] = @as(u8, head) << 4 | valueNibble(value, 0);
            bytes[1] = valueNibble(value, 1) << 4;
            writer.byte_index += 1;
            writer.low_half = true;
        }
    }

    fn writeSixNibbleReserved(writer: *NibbleWriter, value: u32, head: u4) void {
        const bytes = writer.output[writer.byte_index..][0..4];
        if (writer.low_half) {
            bytes[0] |= head;
            bytes[1] = valueNibble(value, 0) << 4 | valueNibble(value, 1);
            bytes[2] = valueNibble(value, 2) << 4 | valueNibble(value, 3);
            bytes[3] = valueNibble(value, 4) << 4 | valueNibble(value, 5);
            writer.byte_index += 4;
            writer.low_half = false;
        } else {
            bytes[0] = @as(u8, head) << 4 | valueNibble(value, 0);
            bytes[1] = valueNibble(value, 1) << 4 | valueNibble(value, 2);
            bytes[2] = valueNibble(value, 3) << 4 | valueNibble(value, 4);
            bytes[3] = valueNibble(value, 5) << 4;
            writer.byte_index += 3;
            writer.low_half = true;
        }
    }

    fn writeSevenNibbleReserved(writer: *NibbleWriter, value: u32, head: u4) void {
        const bytes = writer.output[writer.byte_index..];
        if (writer.low_half) {
            bytes[0] |= head;
            bytes[1] = valueNibble(value, 0) << 4 | valueNibble(value, 1);
            bytes[2] = valueNibble(value, 2) << 4 | valueNibble(value, 3);
            bytes[3] = valueNibble(value, 4) << 4 | valueNibble(value, 5);
            bytes[4] = valueNibble(value, 6) << 4;
        } else {
            bytes[0] = @as(u8, head) << 4 | valueNibble(value, 0);
            bytes[1] = valueNibble(value, 1) << 4 | valueNibble(value, 2);
            bytes[2] = valueNibble(value, 3) << 4 | valueNibble(value, 4);
            bytes[3] = valueNibble(value, 5) << 4 | valueNibble(value, 6);
        }
        writer.byte_index += 4;
    }

    fn writeSevenNibble(writer: *NibbleWriter, value: u32) Error!void {
        if (writer.output.len - writer.byte_index <
            4 + @as(usize, @intFromBool(writer.low_half)))
        {
            return error.OutputTooSmall;
        }
        const bytes = writer.output[writer.byte_index..];
        if (writer.low_half) {
            bytes[0] |= 1;
            bytes[1] = valueNibble(value, 0) << 4 | valueNibble(value, 1);
            bytes[2] = valueNibble(value, 2) << 4 | valueNibble(value, 3);
            bytes[3] = valueNibble(value, 4) << 4 | valueNibble(value, 5);
            bytes[4] = valueNibble(value, 6) << 4;
        } else {
            bytes[0] = 1 << 4 | valueNibble(value, 0);
            bytes[1] = valueNibble(value, 1) << 4 | valueNibble(value, 2);
            bytes[2] = valueNibble(value, 3) << 4 | valueNibble(value, 4);
            bytes[3] = valueNibble(value, 5) << 4 | valueNibble(value, 6);
        }
        writer.byte_index += 4;
    }

    fn writeFiveNibblePair(writer: *NibbleWriter, first: u32, second: u32) Error!bool {
        if (!hasFiveBodyNibbles(first) or !hasFiveBodyNibbles(second)) return false;
        if (writer.low_half) {
            if (writer.output.len - writer.byte_index < 7) return error.OutputTooSmall;
            const bytes = writer.output[writer.byte_index..][0..7];
            bytes[0] |= 3;
            bytes[1] = valueNibble(first, 0) << 4 | valueNibble(first, 1);
            bytes[2] = valueNibble(first, 2) << 4 | valueNibble(first, 3);
            bytes[3] = valueNibble(first, 4) << 4 | 3;
            bytes[4] = valueNibble(second, 0) << 4 | valueNibble(second, 1);
            bytes[5] = valueNibble(second, 2) << 4 | valueNibble(second, 3);
            bytes[6] = valueNibble(second, 4) << 4;
            writer.byte_index += 6;
            return true;
        }
        if (writer.output.len - writer.byte_index < 6) return error.OutputTooSmall;
        const bytes = writer.output[writer.byte_index..][0..6];
        bytes[0] = 3 << 4 | valueNibble(first, 0);
        bytes[1] = valueNibble(first, 1) << 4 | valueNibble(first, 2);
        bytes[2] = valueNibble(first, 3) << 4 | valueNibble(first, 4);
        bytes[3] = 3 << 4 | valueNibble(second, 0);
        bytes[4] = valueNibble(second, 1) << 4 | valueNibble(second, 2);
        bytes[5] = valueNibble(second, 3) << 4 | valueNibble(second, 4);
        writer.byte_index += 6;
        return true;
    }

    fn writeFiveNibble(writer: *NibbleWriter, value: u32, head: u4) Error!void {
        const required: usize = if (writer.low_half) 4 else 3;
        if (writer.output.len - writer.byte_index < required) return error.OutputTooSmall;
        const bytes = writer.output[writer.byte_index..];
        if (writer.low_half) {
            bytes[0] |= head;
            bytes[1] = valueNibble(value, 0) << 4 | valueNibble(value, 1);
            bytes[2] = valueNibble(value, 2) << 4 | valueNibble(value, 3);
            bytes[3] = valueNibble(value, 4) << 4;
        } else {
            bytes[0] = @as(u8, head) << 4 | valueNibble(value, 0);
            bytes[1] = valueNibble(value, 1) << 4 | valueNibble(value, 2);
            bytes[2] = valueNibble(value, 3) << 4 | valueNibble(value, 4);
        }
        writer.byte_index += 3;
    }

    fn writeZero(writer: *NibbleWriter, comptime reserved: bool) Error!void {
        if (!reserved and writer.byte_index == writer.output.len) return error.OutputTooSmall;
        if (writer.low_half) {
            writer.output[writer.byte_index] |= 8;
            writer.byte_index += 1;
            writer.low_half = false;
        } else {
            writer.output[writer.byte_index] = 0x80;
            writer.low_half = true;
        }
    }

    fn writeZeroPair(writer: *NibbleWriter) Error!void {
        const required: usize = if (writer.low_half) 2 else 1;
        if (writer.output.len - writer.byte_index < required) return error.OutputTooSmall;
        if (writer.low_half) {
            writer.output[writer.byte_index] |= 8;
            writer.output[writer.byte_index + 1] = 0x80;
        } else {
            writer.output[writer.byte_index] = 0x88;
        }
        writer.byte_index += 1;
    }

    fn writeOneNibble(writer: *NibbleWriter, value: u32, head: u4, comptime reserved: bool) Error!void {
        const required: usize = if (writer.low_half) 2 else 1;
        if (!reserved and writer.output.len - writer.byte_index < required) return error.OutputTooSmall;
        if (writer.low_half) {
            writer.output[writer.byte_index] |= head;
            writer.output[writer.byte_index + 1] = valueNibble(value, 0) << 4;
        } else {
            writer.output[writer.byte_index] = @as(u8, head) << 4 | valueNibble(value, 0);
        }
        writer.byte_index += 1;
    }

    fn writeThreeNibble(writer: *NibbleWriter, value: u32, head: u4, comptime reserved: bool) Error!void {
        const required: usize = if (writer.low_half) 3 else 2;
        if (!reserved and writer.output.len - writer.byte_index < required) return error.OutputTooSmall;
        const bytes = writer.output[writer.byte_index..];
        if (writer.low_half) {
            bytes[0] |= head;
            bytes[1] = valueNibble(value, 0) << 4 | valueNibble(value, 1);
            bytes[2] = valueNibble(value, 2) << 4;
        } else {
            bytes[0] = @as(u8, head) << 4 | valueNibble(value, 0);
            bytes[1] = valueNibble(value, 1) << 4 | valueNibble(value, 2);
        }
        writer.byte_index += 2;
    }

    fn writeFourNibble(writer: *NibbleWriter, value: u32, head: u4, comptime reserved: bool) Error!void {
        if (!reserved and writer.output.len - writer.byte_index < 3) return error.OutputTooSmall;
        const bytes = writer.output[writer.byte_index..][0..3];
        if (writer.low_half) {
            bytes[0] |= head;
            bytes[1] = valueNibble(value, 0) << 4 | valueNibble(value, 1);
            bytes[2] = valueNibble(value, 2) << 4 | valueNibble(value, 3);
            writer.byte_index += 3;
            writer.low_half = false;
        } else {
            bytes[0] = @as(u8, head) << 4 | valueNibble(value, 0);
            bytes[1] = valueNibble(value, 1) << 4 | valueNibble(value, 2);
            bytes[2] = valueNibble(value, 3) << 4;
            writer.byte_index += 2;
            writer.low_half = true;
        }
    }

    fn writeBody(writer: *NibbleWriter, value: u32, leading: u4) Error!void {
        for (leading..8) |index| {
            const shift: u5 = @intCast((index - leading) * 4);
            try writer.writeNibble(@truncate(value >> shift));
        }
    }

    fn writeNibble(writer: *NibbleWriter, nibble: u4) Error!void {
        if (writer.byte_index == writer.output.len) return error.OutputTooSmall;
        if (!writer.low_half) {
            writer.output[writer.byte_index] = @as(u8, nibble) << 4;
            writer.low_half = true;
        } else {
            writer.output[writer.byte_index] |= nibble;
            writer.byte_index += 1;
            writer.low_half = false;
        }
    }

    fn finish(writer: *NibbleWriter) usize {
        return writer.byte_index + @intFromBool(writer.low_half);
    }
};

inline fn valueNibble(value: u32, comptime index: u5) u8 {
    return @as(u8, @truncate(value >> (index * 4))) & 0x0f;
}

const NibbleReader = struct {
    input: []const u8,
    byte_index: usize = 0,
    cached_byte: u8 = 0,
    has_low_nibble: bool = false,

    fn init(input: []const u8) NibbleReader {
        return .{ .input = input };
    }

    fn atEnd(reader: *const NibbleReader) bool {
        return reader.byte_index == reader.input.len and !reader.has_low_nibble;
    }

    fn onlyZeroPaddingRemains(reader: *const NibbleReader) bool {
        return reader.has_low_nibble and reader.byte_index == reader.input.len and
            (reader.cached_byte & 0x0f) == 0;
    }

    fn readNibble(reader: *NibbleReader) Error!u4 {
        if (reader.has_low_nibble) {
            reader.has_low_nibble = false;
            return @truncate(reader.cached_byte);
        }
        if (reader.byte_index == reader.input.len) return error.InvalidData;
        reader.cached_byte = reader.input[reader.byte_index];
        reader.byte_index += 1;
        reader.has_low_nibble = true;
        return @truncate(reader.cached_byte >> 4);
    }

    fn readBodyWord(reader: *NibbleReader, count: u4, sign_seed: u32) u32 {
        const starts_low = reader.has_low_nibble;
        const word = std.mem.readInt(u32, reader.input[reader.byte_index..][0..4], .little);
        const swapped = ((word & 0xf0f0_f0f0) >> 4) | ((word & 0x0f0f_0f0f) << 4);
        const packed_bits = if (starts_low)
            @as(u64, reader.cached_byte & 0x0f) | @as(u64, swapped) << 4
        else
            @as(u64, swapped);
        const bit_count: u6 = @as(u6, count) * 4;
        const mask = (@as(u64, 1) << bit_count) - 1;

        const cached_nibbles: u4 = @intFromBool(starts_low);
        const input_nibbles = count - cached_nibbles;
        reader.byte_index += (input_nibbles + 1) / 2;
        reader.has_low_nibble = starts_low != (count % 2 != 0);
        if (reader.has_low_nibble) reader.cached_byte = reader.input[reader.byte_index - 1];
        return sign_seed | @as(u32, @truncate(packed_bits & mask));
    }
};

const IntegerHead = struct {
    body_nibbles: u4,
    sign_seed: u32,
};

const INTEGER_HEADS = [16]IntegerHead{
    .{ .body_nibbles = 8, .sign_seed = 0 },
    .{ .body_nibbles = 7, .sign_seed = 0 },
    .{ .body_nibbles = 6, .sign_seed = 0 },
    .{ .body_nibbles = 5, .sign_seed = 0 },
    .{ .body_nibbles = 4, .sign_seed = 0 },
    .{ .body_nibbles = 3, .sign_seed = 0 },
    .{ .body_nibbles = 2, .sign_seed = 0 },
    .{ .body_nibbles = 1, .sign_seed = 0 },
    .{ .body_nibbles = 0, .sign_seed = 0 },
    .{ .body_nibbles = 7, .sign_seed = 0xf000_0000 },
    .{ .body_nibbles = 6, .sign_seed = 0xff00_0000 },
    .{ .body_nibbles = 5, .sign_seed = 0xfff0_0000 },
    .{ .body_nibbles = 4, .sign_seed = 0xffff_0000 },
    .{ .body_nibbles = 3, .sign_seed = 0xffff_f000 },
    .{ .body_nibbles = 2, .sign_seed = 0xffff_ff00 },
    .{ .body_nibbles = 1, .sign_seed = 0xffff_fff0 },
};

fn readNumpressInt(
    reader: *NibbleReader,
    comptime use_word_body: bool,
    comptime use_five_body: bool,
    comptime use_short_body: bool,
) Error!u32 {
    const head = try reader.readNibble();
    const descriptor = INTEGER_HEADS[head];
    if (comptime use_word_body) {
        if (descriptor.body_nibbles >= 7 and reader.input.len - reader.byte_index >= 4) {
            return reader.readBodyWord(descriptor.body_nibbles, descriptor.sign_seed);
        }
    }
    if (comptime use_five_body) {
        if (descriptor.body_nibbles == 5 and !reader.has_low_nibble) {
            return readNumpressBodyFive(reader, descriptor.sign_seed);
        }
    }
    if (comptime use_short_body) {
        return readNumpressBodyShort(reader, descriptor.body_nibbles, descriptor.sign_seed);
    }
    return readNumpressBody(reader, descriptor.body_nibbles, descriptor.sign_seed);
}

fn readNumpressBody(reader: anytype, count: u4, sign_seed: u32) Error!u32 {
    var value = sign_seed;
    for (0..count) |index| {
        const nibble = try reader.readNibble();
        const shift: u5 = @intCast(index * 4);
        value |= @as(u32, nibble) << shift;
    }
    return value;
}

fn readNumpressBodyShort(reader: anytype, count: u4, sign_seed: u32) Error!u32 {
    if (count == 0) return sign_seed;
    if (count == 1) return sign_seed | @as(u32, try reader.readNibble());
    return readNumpressBody(reader, count, sign_seed);
}

fn readNumpressBodyFive(reader: anytype, sign_seed: u32) Error!u32 {
    var value = sign_seed;
    inline for (0..5) |index| {
        value |= @as(u32, try reader.readNibble()) << @as(u5, @intCast(index * 4));
    }
    return value;
}

fn isShortIntegerPayload(input_len: usize, output_len: usize) bool {
    if (input_len <= output_len) return true;
    return input_len - output_len <= output_len / 8;
}

fn isMediumIntegerPayload(input_len: usize, output_len: usize) bool {
    return input_len / 3 <= output_len and input_len / 2 > output_len;
}
