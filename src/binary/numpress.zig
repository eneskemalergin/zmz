//! Encodes and decodes the established MS-Numpress Linear, PIC, and SLOF transforms.
//!
//! Encoders take a whole array and write into a caller-owned slice or a `std.Io.Writer`, one
//! block at a time. `Decoder` takes a payload in fragments of any size; the one-shot decoders are
//! one update and finish on it, so every split of a payload gives the same values and errors.
//! Nothing allocates. Linear and SLOF are lossy; PIC is exact only for integer-valued input in
//! its range. SLOF uses `exp` and `log` computed exactly as glibc computes them, so its codes and
//! values match C++ ms-numpress and numpress-rs on Linux.

const std = @import("std");
const builtin = @import("builtin");

const libm = @import("libm_data.zig");

/// Errors returned by checked MS-Numpress operations.
///
/// `InvalidData` describes encoded input. `InvalidValue` and `ValueOutOfRange` describe source
/// numbers. `FailedState` and `AlreadyFinished` come only from `Decoder` calls after an error or
/// after `finish`. Output contents after an error are unspecified, but writes stay within the
/// supplied span.
pub const Error = error{
    AlreadyFinished,
    DecodedSizeMismatch,
    FailedState,
    InvalidData,
    InvalidFixedPoint,
    InvalidValue,
    LengthOverflow,
    OutputTooSmall,
    ToleranceUnattainable,
    ValueOutOfRange,
};

pub const WriteError = Error || std.Io.Writer.Error;

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

// --- Fixed-point selection ---

/// Selects the largest finite linear fixed point for valid nonnegative data.
///
/// This matches the reference selector for nondegenerate input. For an all-zero
/// maximum it returns the largest signed 32-bit integer instead of infinity.
pub fn optimalLinearFixedPoint(input: anytype) Error!f64 {
    const values = slice(input);
    if (values.len == 0) return 0;
    for (values) |value| try validateNonnegative(value);

    if (values.len == 1) return fixedPointForMaximum(valueAt(values, 0));

    var maximum = @max(valueAt(values, 0), valueAt(values, 1));
    var index: usize = 2;
    if (values.len >= 64) {
        maximum = try linearMaximumVector(values, index, maximum, &index);
    }
    return fixedPointForMaximum(try linearMaximumScalar(values, index, maximum));
}

fn linearMaximumVector(
    values: anytype,
    start: usize,
    initial_maximum: f64,
    end: *usize,
) Error!f64 {
    const finite_limit: F64s = @splat(std.math.floatMax(f64));
    const one: F64s = @splat(1.0);
    var maximum = initial_maximum;
    var index = start;
    while (values.len - index >= LANES) : (index += LANES) {
        const current = load(LANES, values, index);
        const previous_1 = load(LANES, values, index - 1);
        const previous_2 = load(LANES, values, index - 2);
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
    values: anytype,
    start: usize,
    initial_maximum: f64,
) Error!f64 {
    var maximum = initial_maximum;
    for (start..values.len) |index| {
        const extrapolated = valueAt(values, index - 1) + (valueAt(values, index - 1) - valueAt(values, index - 2));
        if (!std.math.isFinite(extrapolated)) return error.ValueOutOfRange;
        maximum = @max(maximum, @ceil(@abs(valueAt(values, index) - extrapolated) + 1.0));
    }
    return maximum;
}

/// Selects a Linear fixed point that bounds rounding error by `max_abs_error`.
pub fn linearFixedPointForAbsoluteError(
    input: anytype,
    max_abs_error: f64,
) Error!f64 {
    const values = slice(input);
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
pub fn optimalSlofFixedPoint(input: anytype) Error!f64 {
    const values = slice(input);
    if (values.len == 0) return 0;

    var maximum: f64 = 1;
    for (0..values.len) |index| {
        const value = valueAt(values, index);
        try validateNonnegative(value);
        maximum = @max(maximum, logLibm(value + 1.0));
    }
    const fixed_point = @floor(65_535.0 / maximum);
    if (fixed_point < 1) return error.InvalidFixedPoint;
    return fixed_point;
}

fn fixedPointForMaximum(maximum: f64) Error!f64 {
    if (!std.math.isFinite(maximum) or maximum < 0) return error.InvalidValue;
    if (maximum == 0) return @floatFromInt(std.math.maxInt(i32));
    const fixed_point = @floor(@as(f64, @floatFromInt(std.math.maxInt(i32))) / maximum);
    if (!std.math.isFinite(fixed_point) or fixed_point < 1) return error.InvalidFixedPoint;
    return fixed_point;
}

// --- Encoding ---

// Values per encode block; decode was flat from 64 to 1,024, and 128 keeps the stack blocks
// under 2 KiB.
const BLOCK = 128;
// One block's worst case: 128 values of 9 nibbles, the 8-byte store margin, and a spare byte.
const BLOCK_BYTES = 9 * BLOCK / 2 + 16;

const LANES = std.simd.suggestVectorLength(f64) orelse 1;

// Encoders and selectors take f32 or f64 values. f32 widens to f64 exactly, and every step
// computes in f64 after widening, so f32 input encodes as its f64 copy would, without the copy.
fn Input(comptime Values: type) type {
    const T = std.meta.Elem(Values);
    if (T != f64 and T != f32) @compileError("Numpress encodes f32 or f64 values, not " ++ @typeName(T));
    return T;
}

inline fn valueAt(values: anytype, index: usize) f64 {
    _ = Input(@TypeOf(values));
    return values[index];
}

// The input as a slice: f32 slices and arrays stay f32; everything else (f64 slices, arrays,
// and literals such as &.{ 1, 2 }) coerces to []const f64.
fn Slice(comptime Values: type) type {
    const info = @typeInfo(Values);
    if (info == .pointer) {
        const child = info.pointer.child;
        if (info.pointer.size == .slice and child == f32) return []const f32;
        if (info.pointer.size == .one and @typeInfo(child) == .array and @typeInfo(child).array.child == f32) return []const f32;
    }
    return []const f64;
}

inline fn slice(values: anytype) Slice(@TypeOf(values)) {
    return values;
}

inline fn load(comptime N: usize, values: anytype, index: usize) @Vector(N, f64) {
    const T = Input(@TypeOf(values));
    const v: @Vector(N, T) = values[index..][0..N].*;
    return if (T == f64) v else @floatCast(v);
}
const F64s = @Vector(LANES, f64);
const I64s = @Vector(LANES, i64);
const U32s = @Vector(LANES, u32);
const U64s = @Vector(LANES, u64);

/// Encodes finite doubles from zero through `maxInt(u32)` by rounding to the nearest integer
/// and applying the Numpress integer code.
pub noinline fn encodePic(input: anytype, output: []u8) Error!usize {
    const values = slice(input);
    // The sink writes only filled bytes, so the worst-case bound is enough room; a smaller
    // output takes the checked encoder, which reports OutputTooSmall only when it is needed.
    const bound = picMaxEncodedLen(values.len) catch return encodePicChecked(values, output);
    if (output.len < bound) return encodePicChecked(values, output);
    var codes: [BLOCK]u32 = undefined;
    var leading: [BLOCK]u32 = undefined;
    var sink = RawSink{ .out = output };
    var i: usize = 0;
    while (i < values.len) {
        const n: usize = @min(BLOCK, values.len - i);
        switch (roundPicBlock(values[i..][0..n], codes[0..n], leading[0..n])) {
            .invalid => return encodePicChecked(values, output),
            .wide => sink.putAll(codes[0..n]),
            .simple => sink.putAllLeading(codes[0..n], leading[0..n]),
        }
        i += n;
    }
    return sink.finish();
}

/// Encodes nonnegative doubles with MS-Numpress linear prediction.
pub noinline fn encodeLinear(input: anytype, fixed_point: f64, output: []u8) Error!usize {
    const values = slice(input);
    const bound = linearMaxEncodedLen(values.len) catch
        return encodeLinearChecked(values, fixed_point, output);
    if (values.len < 3 or !(fixed_point > 0 and fixed_point <= std.math.floatMax(f64)) or
        output.len < bound)
    {
        return encodeLinearChecked(values, fixed_point, output);
    }
    var scaled: [BLOCK + 2]i64 = undefined;
    if (!scaleLinearBlock(values[0..2], fixed_point, scaled[0..2]) or
        scaled[0] > std.math.maxInt(u32) or scaled[1] > std.math.maxInt(u32))
    {
        return encodeLinearChecked(values, fixed_point, output);
    }
    writeFixedPoint(output[0..8], fixed_point);
    std.mem.writeInt(u32, output[8..12], @intCast(scaled[0]), .little);
    std.mem.writeInt(u32, output[12..16], @intCast(scaled[1]), .little);
    var sink = RawSink{ .out = output[16..] };
    var residuals: [BLOCK]u32 = undefined;
    var i: usize = 2;
    while (i < values.len) {
        const n: usize = @min(BLOCK, values.len - i);
        // scaled[0..2] carries the previous two values into the block.
        if (!scaleLinearBlock(values[i..][0..n], fixed_point, scaled[2..][0..n]) or
            !linearResiduals(scaled[0 .. n + 2], residuals[0..n]))
        {
            return encodeLinearChecked(values, fixed_point, output);
        }
        sink.putAll(residuals[0..n]);
        scaled[0] = scaled[n];
        scaled[1] = scaled[n + 1];
        i += n;
    }
    return 16 + sink.finish();
}

/// Encodes nonnegative doubles with the MS-Numpress short logged float transform.
pub noinline fn encodeSlof(input: anytype, fixed_point: f64, output: []u8) Error!usize {
    const values = slice(input);
    const encoded_len = slofEncodedLen(values.len) catch
        return encodeSlofChecked(values, fixed_point, output);
    if (!(fixed_point > 0 and fixed_point <= std.math.floatMax(f64)) or output.len < encoded_len)
        return encodeSlofChecked(values, fixed_point, output);
    writeFixedPoint(output[0..8], fixed_point);
    const guard = slofGuard(fixed_point);
    var i: usize = 0;
    while (values.len - i >= SLOF_LANES) : (i += SLOF_LANES) {
        const codes = slofBlock(values[i..][0..SLOF_LANES], fixed_point, guard) orelse
            return encodeSlofChecked(values, fixed_point, output);
        storeCodes(output[8 + 2 * i ..][0 .. 2 * SLOF_LANES], codes);
    }
    for (values[i..], i..) |value, index| {
        const code = slofCode(value, fixed_point) catch
            return encodeSlofChecked(values, fixed_point, output);
        std.mem.writeInt(u16, output[8 + 2 * index ..][0..2], code, .little);
    }
    return encoded_len;
}

/// Writes the PIC encoding of `values` to `writer` and returns the bytes written. Errors match
/// `encodePic`; after one, the writer holds an unspecified prefix.
pub fn encodePicTo(input: anytype, writer: *std.Io.Writer) WriteError!usize {
    const values = slice(input);
    var block: [BLOCK_BYTES]u8 = undefined;
    var sink = RawSink{ .out = &block };
    var codes: [BLOCK]u32 = undefined;
    var leading: [BLOCK]u32 = undefined;
    var written: usize = 0;
    var i: usize = 0;
    while (i < values.len) {
        const n: usize = @min(BLOCK, values.len - i);
        switch (roundPicBlock(values[i..][0..n], codes[0..n], leading[0..n])) {
            .simple => sink.putAllLeading(codes[0..n], leading[0..n]),
            .wide => sink.putAll(codes[0..n]),
            .invalid => {
                for (values[i..][0..n], codes[0..n]) |value, *code| code.* = try roundedPic(value);
                sink.putAll(codes[0..n]);
            },
        }
        written += try sink.drain(writer);
        i += n;
    }
    const tail = sink.finish();
    try writer.writeAll(block[0..tail]);
    return written + tail;
}

/// Writes the Linear encoding of `values` to `writer` and returns the bytes written. Errors
/// match `encodeLinear`; after one, the writer holds an unspecified prefix.
pub fn encodeLinearTo(input: anytype, fixed_point: f64, writer: *std.Io.Writer) WriteError!usize {
    const values = slice(input);
    try validateFixedPoint(fixed_point, values.len == 0);
    var header: [16]u8 = undefined;
    writeFixedPoint(header[0..8], fixed_point);
    if (values.len == 0) {
        try writer.writeAll(header[0..8]);
        return 8;
    }
    var scaled: [BLOCK + 2]i64 = undefined;
    scaled[0] = try scaleLinearInitial(values[0], fixed_point);
    std.mem.writeInt(u32, header[8..12], @intCast(scaled[0]), .little);
    if (values.len == 1) {
        try writer.writeAll(header[0..12]);
        return 12;
    }
    scaled[1] = try scaleLinearInitial(values[1], fixed_point);
    std.mem.writeInt(u32, header[12..16], @intCast(scaled[1]), .little);
    try writer.writeAll(&header);
    var block: [BLOCK_BYTES]u8 = undefined;
    var sink = RawSink{ .out = &block };
    var residuals: [BLOCK]u32 = undefined;
    var written: usize = 16;
    var i: usize = 2;
    while (i < values.len) {
        const n: usize = @min(BLOCK, values.len - i);
        if (!scaleLinearBlock(values[i..][0..n], fixed_point, scaled[2..][0..n]) or
            !linearResiduals(scaled[0 .. n + 2], residuals[0..n]))
        {
            for (0..n) |j| {
                scaled[j + 2] = try scaleLinear(values[i + j], fixed_point);
                residuals[j] = @bitCast(try linearResidual(scaled[j + 2], scaled[j], scaled[j + 1]));
            }
        }
        sink.putAll(residuals[0..n]);
        written += try sink.drain(writer);
        scaled[0] = scaled[n];
        scaled[1] = scaled[n + 1];
        i += n;
    }
    const tail = sink.finish();
    try writer.writeAll(block[0..tail]);
    return written + tail;
}

/// Writes the SLOF encoding of `values` to `writer` and returns the bytes written. Errors
/// match `encodeSlof`; after one, the writer holds an unspecified prefix.
pub fn encodeSlofTo(input: anytype, fixed_point: f64, writer: *std.Io.Writer) WriteError!usize {
    const values = slice(input);
    try validateFixedPoint(fixed_point, values.len == 0);
    var header: [8]u8 = undefined;
    writeFixedPoint(&header, fixed_point);
    try writer.writeAll(&header);
    const guard = slofGuard(fixed_point);
    var out: [2 * SLOF_LANES]u8 = undefined;
    var i: usize = 0;
    while (values.len - i >= SLOF_LANES) : (i += SLOF_LANES) {
        const block = values[i..][0..SLOF_LANES];
        var codes: SlofCodes = undefined;
        if (slofBlock(block, fixed_point, guard)) |fast| {
            codes = fast;
        } else {
            inline for (0..SLOF_LANES) |lane| codes[lane] = try slofCode(block[lane], fixed_point);
        }
        storeCodes(&out, codes);
        try writer.writeAll(&out);
    }
    for (values[i..]) |value| {
        var code: [2]u8 = undefined;
        std.mem.writeInt(u16, &code, try slofCode(value, fixed_point), .little);
        try writer.writeAll(&code);
    }
    return 8 + 2 * values.len;
}

// The checked encoders: one value at a time, every check in the reference order. The block
// encoders fall back to them for invalid input or an output below the worst-case bound, so
// errors and short-output behavior come from one place.
noinline fn encodePicChecked(values: anytype, output: []u8) Error!usize {
    var writer = NibbleWriter.init(output);
    for (values) |value| try writer.writeInt(try roundedPic(value));
    return writer.finish();
}

noinline fn encodeLinearChecked(values: anytype, fixed_point: f64, output: []u8) Error!usize {
    try validateFixedPoint(fixed_point, values.len == 0);
    if (output.len < 8) return error.OutputTooSmall;
    writeFixedPoint(output[0..8], fixed_point);
    if (values.len == 0) return 8;

    var previous_2 = try scaleLinearInitial(values[0], fixed_point);
    if (output.len < 12) return error.OutputTooSmall;
    std.mem.writeInt(u32, output[8..12], @intCast(previous_2), .little);
    if (values.len == 1) return 12;

    var previous_1 = try scaleLinearInitial(values[1], fixed_point);
    if (output.len < 16) return error.OutputTooSmall;
    std.mem.writeInt(u32, output[12..16], @intCast(previous_1), .little);

    var writer = NibbleWriter.init(output[16..]);
    for (values[2..]) |value| {
        const current = try scaleLinear(value, fixed_point);
        try writer.writeInt(@bitCast(try linearResidual(current, previous_2, previous_1)));
        previous_2 = previous_1;
        previous_1 = current;
    }
    return 16 + writer.finish();
}

noinline fn encodeSlofChecked(values: anytype, fixed_point: f64, output: []u8) Error!usize {
    try validateFixedPoint(fixed_point, values.len == 0);
    const encoded_len = try slofEncodedLen(values.len);
    if (output.len < encoded_len) return error.OutputTooSmall;
    writeFixedPoint(output[0..8], fixed_point);
    for (values, 0..) |value, index| {
        std.mem.writeInt(u16, output[8 + 2 * index ..][0..2], try slofCode(value, fixed_point), .little);
    }
    return encoded_len;
}

// Rounds a PIC block into u32 codes and gives each code's leading zero nibbles, read from the
// exponent of v + 0.5: for v >= 0 it lies in [0.5, 2^32), and truncating to the code keeps the
// binary exponent E, so the code has (1054 - E) >> 2 leading zero nibbles (8 for zero, where E
// is 1022). `.wide` means a code reaches 0xf0000000, whose leading nibbles are F, so the block
// needs the general word builder; `.invalid` means a value needs the checked path.
const Rounded = enum { simple, wide, invalid };

fn roundPicBlock(values: anytype, codes: []u32, leading: []u32) Rounded {
    const regular_maximum = @as(f64, @floatFromInt(std.math.maxInt(u32))) - 0.5;
    const filled_minimum = 0xf000_0000 - 0.5;
    const limit: F64s = @splat(regular_maximum);
    const filled: F64s = @splat(filled_minimum);
    const zero: F64s = @splat(0);
    var any_filled = false;
    var i: usize = 0;
    while (values.len - i >= LANES) : (i += LANES) {
        const v = load(LANES, values, i);
        if (!@reduce(.And, (v >= zero) & (v < limit))) return .invalid;
        any_filled = any_filled or @reduce(.Or, v >= filled);
        const shifted = v + @as(F64s, @splat(0.5));
        codes[i..][0..LANES].* = @as(U32s, @intFromFloat(shifted));
        const exponent = @as(U64s, @bitCast(shifted)) >> @splat(52);
        leading[i..][0..LANES].* = @as(U32s, @truncate((@as(U64s, @splat(1054)) - exponent) >> @splat(2)));
    }
    while (i < values.len) : (i += 1) {
        const v = valueAt(values, i);
        if (!(v >= 0 and v < regular_maximum)) return .invalid;
        any_filled = any_filled or v >= filled_minimum;
        const shifted = v + 0.5;
        codes[i] = @intFromFloat(shifted);
        leading[i] = @truncate((1054 - (@as(u64, @bitCast(shifted)) >> 52)) >> 2);
    }
    return if (any_filled) .wide else .simple;
}

// Scales a Linear block to i64 with the checked encoder's rounding; false when a value needs
// the checked path (negative, non-finite, or not below 2^62 after scaling, where the second
// difference stops being exact in i64).
fn scaleLinearBlock(values: anytype, fixed_point: f64, out: []i64) bool {
    const fp: F64s = @splat(fixed_point);
    const half: F64s = @splat(0.5);
    const limit: F64s = @splat(0x1p62);
    const zero: F64s = @splat(0);
    var i: usize = 0;
    while (values.len - i >= LANES) : (i += LANES) {
        const v = load(LANES, values, i);
        const scaled = v * fp + half;
        if (!@reduce(.And, (v >= zero) & (scaled < limit))) return false;
        out[i..][0..LANES].* = @as(I64s, @intFromFloat(scaled));
    }
    while (i < values.len) : (i += 1) {
        const value = valueAt(values, i);
        const scaled = value * fixed_point + 0.5;
        if (!(value >= 0 and scaled < 0x1p62)) return false;
        out[i] = @intFromFloat(scaled);
    }
    return true;
}

// Second differences of a scaled block (two carried values first) as i32 bits; false when one
// does not fit in i32.
fn linearResiduals(scaled: []const i64, out: []u32) bool {
    const n = out.len;
    const bias: U64s = @splat(1 << 31);
    var wide: U64s = @splat(0);
    var j: usize = 0;
    while (n - j >= LANES) : (j += LANES) {
        const a: I64s = scaled[j..][0..LANES].*;
        const b: I64s = scaled[j + 1 ..][0..LANES].*;
        const c: I64s = scaled[j + 2 ..][0..LANES].*;
        const r: U64s = @bitCast(c - (b + b - a));
        // In range exactly when r + 2^31 fits in 32 bits.
        wide |= (r +% bias) >> @splat(32);
        out[j..][0..LANES].* = @as(U32s, @truncate(r));
    }
    var tail_wide: u64 = 0;
    while (j < n) : (j += 1) {
        const r: u64 = @bitCast(scaled[j + 2] - (scaled[j + 1] + scaled[j + 1] - scaled[j]));
        tail_wide |= (r +% (1 << 31)) >> 32;
        out[j] = @truncate(r);
    }
    return @reduce(.Or, wide) | tail_wide == 0;
}

// log and exp are long dependency chains with a division; 16 lanes (8 SSE2 or 4 AVX2 vectors)
// let them overlap, and beat 4, 8, and 32 lanes on baseline and x86-64-v3.
const SLOF_LANES = if (LANES == 1) 1 else 16;
const SlofF64s = @Vector(SLOF_LANES, f64);
const SlofCodes = @Vector(SLOF_LANES, u16);

// The codes of a SLOF block, or null when a value needs the checked path. Codes whose scaled
// logarithm lies within `guard` of a rounding boundary are recomputed with the glibc-exact
// scalar log, so every code matches C++.
inline fn slofBlock(values: anytype, fixed_point: f64, guard: f64) ?SlofCodes {
    const v = load(SLOF_LANES, values, 0);
    const valid = (v >= @as(SlofF64s, @splat(0))) & (v <= @as(SlofF64s, @splat(std.math.floatMax(f64))));
    if (!@reduce(.And, valid)) return null;
    const scaled = logAtLeastOne(SLOF_LANES, v + @as(SlofF64s, @splat(1.0))) * @as(SlofF64s, @splat(fixed_point));
    if (!@reduce(.And, scaled <= @as(SlofF64s, @splat(65_535.0)))) return null;
    const shifted = scaled + @as(SlofF64s, @splat(0.5));
    const truncated: @Vector(SLOF_LANES, i32) = @intFromFloat(shifted);
    const fraction = shifted - @as(SlofF64s, @floatFromInt(truncated));
    const stable = (fraction > @as(SlofF64s, @splat(guard))) &
        (fraction < @as(SlofF64s, @splat(1.0 - guard)));
    var codes: SlofCodes = @intCast(truncated);
    if (!@reduce(.And, stable)) {
        inline for (0..SLOF_LANES) |lane| {
            if (!stable[lane]) codes[lane] = @intFromFloat(logLibm(valueAt(values, lane) + 1.0) * fixed_point + 0.5);
        }
    }
    return codes;
}

// The vector log is within 1 ULP of glibc's for results up to log(maxFloat) < 710; 16 ULP of
// that, scaled, plus two ULP of the largest code bounds the difference in the scaled value.
fn slofGuard(fixed_point: f64) f64 {
    const eps = std.math.floatEps(f64);
    return 16.0 * 710.0 * eps * fixed_point + 2.0 * eps * 65_535.0;
}

inline fn loadCodes(bytes: *const [2 * SLOF_LANES]u8) SlofCodes {
    if (comptime builtin.cpu.arch.endian() == .little) return @bitCast(bytes.*);
    var codes: SlofCodes = undefined;
    inline for (0..SLOF_LANES) |lane| codes[lane] = std.mem.readInt(u16, bytes[2 * lane ..][0..2], .little);
    return codes;
}

inline fn storeCodes(bytes: *[2 * SLOF_LANES]u8, codes: SlofCodes) void {
    if (comptime builtin.cpu.arch.endian() == .little) {
        bytes.* = @bitCast(codes);
        return;
    }
    inline for (0..SLOF_LANES) |lane| std.mem.writeInt(u16, bytes[2 * lane ..][0..2], codes[lane], .little);
}

// --- Decoding ---

pub const Transform = enum { linear, pic, slof };

// Bytes staged between updates: the unconsumed tail of a fragment (under one value, at most 5
// bytes) plus the first JOIN_BYTES of the next fragment, so a value split across fragments is
// decoded from one buffer. Everything else is decoded in place.
const JOIN_BYTES = 16;
const STAGE_BYTES = 32;
// Linear runs the unchecked block kernel only while |value| and |step| stay this small, so the
// up to 1,024 values of one kernel call cannot overflow i64: |step| < 2^40 + 1024 * 2^31 and
// |value| < 2^60 + 1024 * 2^41 < 2^62.
const LINEAR_FAST_VALUE: i64 = 1 << 60;
const LINEAR_FAST_STEP: i64 = 1 << 40;
const LINEAR_FAST_VALUES = 1024;

/// Decodes one payload given in fragments: `init` or `initExact` with the output, `update`
/// with each fragment, `finish` once. Fragments are borrowed only during `update`; at most one
/// value's worth of bytes, or the header, is kept between updates. Errors that depend on the
/// payload's total length (Linear header sizes, SLOF parity) are reported by `finish`, so any
/// split of a payload gives the same values and error. After an error every call returns
/// `FailedState`; after `finish`, `AlreadyFinished`.
pub const Decoder = struct {
    transform: Transform,
    output: []f64,
    exact: bool,
    count: usize = 0,
    total: usize = 0,
    stage: [STAGE_BYTES]u8 = undefined,
    stage_len: usize = 0,
    // Nibble index, 0 or 1, of the first unconsumed nibble of stage[0].
    parity: usize = 0,
    header: [16]u8 = undefined,
    header_len: usize = 0,
    fixed_point: f64 = 0,
    started: bool = false,
    previous_2: i64 = 0,
    previous_1: i64 = 0,
    codes: usize = 0,
    odd: ?u8 = null,
    nonfinite: bool = false,
    failed: bool = false,
    finished: bool = false,

    /// Decodes at most output.len values, like the decode functions.
    pub fn init(transform: Transform, output: []f64) Decoder {
        return .{ .transform = transform, .output = output, .exact = false };
    }

    /// Decodes exactly output.len values, like the decode*Exact functions: a payload holding
    /// a different count fails with DecodedSizeMismatch.
    pub fn initExact(transform: Transform, output: []f64) Decoder {
        return .{ .transform = transform, .output = output, .exact = true };
    }

    /// Consumes one payload fragment. Empty fragments are valid before finish.
    pub noinline fn update(self: *Decoder, bytes: []const u8) Error!void {
        if (self.failed) return error.FailedState;
        if (self.finished) return error.AlreadyFinished;
        errdefer self.failed = true;
        self.total = std.math.add(usize, self.total, bytes.len) catch return error.LengthOverflow;
        self.consume(bytes) catch |err| return self.mapped(err);
    }

    /// Applies the end-of-payload rules and returns the decoded count.
    pub fn finish(self: *Decoder) Error!usize {
        if (self.failed) return error.FailedState;
        if (self.finished) return error.AlreadyFinished;
        errdefer self.failed = true;
        const count = self.finishInner() catch |err| return self.mapped(err);
        if (self.exact and count != self.output.len) return error.DecodedSizeMismatch;
        self.finished = true;
        return count;
    }

    fn mapped(self: *const Decoder, err: Error) Error {
        return if (self.exact and err == error.OutputTooSmall) error.DecodedSizeMismatch else err;
    }

    fn consume(self: *Decoder, bytes: []const u8) Error!void {
        var input = bytes;
        switch (self.transform) {
            .pic => return self.nibbles(input),
            .linear => {
                if (!self.started) {
                    if (self.header_len == 0 and input.len >= 16) {
                        self.header = input[0..16].*;
                        self.header_len = 16;
                        input = input[16..];
                    } else {
                        const take = @min(16 - self.header_len, input.len);
                        for (0..take) |k| self.header[self.header_len + k] = input[k];
                        self.header_len += take;
                        input = input[take..];
                        if (self.header_len < 16) return;
                    }
                    try self.startLinear();
                }
                return self.nibbles(input);
            },
            .slof => {
                if (self.header_len < 8) {
                    if (self.header_len == 0 and input.len >= 8) {
                        self.header[0..8].* = input[0..8].*;
                        self.header_len = 8;
                        input = input[8..];
                    } else {
                        const take = @min(8 - self.header_len, input.len);
                        for (0..take) |k| self.header[self.header_len + k] = input[k];
                        self.header_len += take;
                        input = input[take..];
                        if (self.header_len < 8) return;
                    }
                    self.fixed_point = readFixedPoint(self.header[0..8]);
                }
                self.slofCodes(input);
            },
        }
    }

    // The 16-byte header is complete, so the payload is at least 16 bytes long and the length
    // checks cannot fail: validate the fixed point and emit two values.
    fn startLinear(self: *Decoder) Error!void {
        const fixed_point = readFixedPoint(self.header[0..8]);
        try validateFixedPoint(fixed_point, false);
        self.fixed_point = fixed_point;
        if (self.output.len < 1) return error.OutputTooSmall;
        const first: i64 = std.mem.readInt(u32, self.header[8..12], .little);
        self.output[0] = try decodeLinearValue(first, fixed_point);
        if (self.output.len < 2) return error.OutputTooSmall;
        const second: i64 = std.mem.readInt(u32, self.header[12..16], .little);
        self.output[1] = try decodeLinearValue(second, fixed_point);
        self.count = 2;
        self.previous_2 = first;
        self.previous_1 = second;
        self.started = true;
    }

    fn nibbles(self: *Decoder, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        var start: usize = 0;
        if (self.stage_len != 0) {
            // Join the staged tail with the head of this fragment and decode the values that
            // start in the tail; they end within JOIN_BYTES, since a value has at most 5 bytes.
            const tail_nibbles = 2 * self.stage_len;
            const take = @min(JOIN_BYTES, bytes.len);
            for (0..take) |k| self.stage[self.stage_len + k] = bytes[k];
            const pos = try self.stageRun(self.stage_len + take, self.parity, tail_nibbles);
            if (pos < tail_nibbles) {
                // A short fragment did not complete the value: keep everything staged.
                self.stage_len += take;
                return;
            }
            start = pos - tail_nibbles;
            self.stage_len = 0;
            self.parity = 0;
        }
        const pos = try self.run(bytes, start);
        const first = pos >> 1;
        // The kernel stops at most 8 bytes before the end; stage them and finish whole values
        // there, each with one 8-byte window load from the zero-padded stage.
        for (bytes[first..], 0..) |b, k| self.stage[k] = b;
        const len = bytes.len - first;
        const done = try self.stageRun(len, pos & 1, 2 * len);
        const kept = done >> 1;
        for (0..len - kept) |k| self.stage[k] = self.stage[kept + k];
        self.stage_len = len - kept;
        self.parity = done & 1;
    }

    // Whole values in stage[0..len] from nibble `start` that begin before `limit` and cannot
    // be the final padding nibble; returns the nibble position after them.
    fn stageRun(self: *Decoder, len: usize, start: usize, limit: usize) Error!usize {
        @memset(self.stage[len..][0..8], 0);
        const total = 2 * len;
        var pos = start;
        while (pos < limit and total - pos >= 2) {
            if (self.count == self.output.len) return error.OutputTooSmall;
            const v = stageValue(&self.stage, pos);
            if (total - pos < v.nibbles) break;
            try self.emit(v.bits);
            pos += v.nibbles;
        }
        return pos;
    }

    // The scalar whole-value loop for a fragment the kernel cannot take: Linear outside its
    // unchecked range, or a full output (where two nibbles left mean OutputTooSmall).
    fn scalarRun(self: *Decoder, buf: []const u8, start: usize) Error!usize {
        const total = 2 * buf.len;
        var pos = start;
        while (total - pos >= 2) {
            if (self.count == self.output.len) return error.OutputTooSmall;
            const head = nibbleAt(buf, pos);
            const body: usize = BODY_NIBBLES[head];
            if (total - pos < 1 + body) break;
            try self.emit(readBits(buf, pos, head));
            pos += 1 + body;
        }
        return pos;
    }

    // Decodes the values of buf from nibble `start` with the block kernel, and returns the
    // nibble position after them: within 8 bytes of the end, or further back only where the
    // kernel cannot run, in which case the scalar loop takes the rest.
    fn run(self: *Decoder, buf: []const u8, start: usize) Error!usize {
        var pos = start;
        while (self.count < self.output.len) {
            const room = self.output.len - self.count;
            if (self.transform == .pic) {
                var sink = PicSink{ .out = self.output[self.count..] };
                const r = unpackChase(PicSink, &sink, buf, pos);
                if (r.count == 0) break;
                self.count += r.count;
                pos = r.pos;
            } else {
                if (!self.linearFast()) break;
                const n: usize = @min(room, LINEAR_FAST_VALUES);
                var sink = LinearSink{
                    .out = self.output[self.count..][0..n],
                    .step = self.previous_1 - self.previous_2,
                    .value = self.previous_1,
                };
                const r = unpackChase(LinearSink, &sink, buf, pos);
                if (r.count == 0) break;
                convertLinear(self.output[self.count..][0..r.count], self.fixed_point);
                self.previous_1 = sink.value;
                self.previous_2 = sink.value - sink.step;
                self.count += r.count;
                pos = r.pos;
            }
        }
        if (buf.len - (pos >> 1) <= 9) return pos;
        return self.scalarRun(buf, pos);
    }

    // Below a fixed point of 1 a decoded value can overflow to infinity, which the checked
    // path rejects.
    fn linearFast(self: *const Decoder) bool {
        return self.fixed_point >= 1 and @abs(self.previous_1) <= LINEAR_FAST_VALUE and
            @abs(self.previous_2) <= LINEAR_FAST_VALUE and
            @abs(self.previous_1 - self.previous_2) <= LINEAR_FAST_STEP;
    }

    fn emit(self: *Decoder, bits: u32) Error!void {
        switch (self.transform) {
            .pic => self.output[self.count] = @floatFromInt(bits),
            .linear => {
                const residual: i32 = @bitCast(bits);
                const step = std.math.sub(i64, self.previous_1, self.previous_2) catch return error.InvalidData;
                const extrapolated = std.math.add(i64, self.previous_1, step) catch return error.InvalidData;
                const next = std.math.add(i64, extrapolated, residual) catch return error.InvalidData;
                self.output[self.count] = try decodeLinearValue(next, self.fixed_point);
                self.previous_2 = self.previous_1;
                self.previous_1 = next;
            },
            .slof => unreachable,
        }
        self.count += 1;
    }

    fn finishInner(self: *Decoder) Error!usize {
        switch (self.transform) {
            .pic => return self.finalNibbles(),
            .linear => {
                if (self.started) return self.finalNibbles();
                const t = self.total;
                if (t < 8 or (t > 8 and t < 12) or (t > 12 and t < 16)) return error.InvalidData;
                const fixed_point = readFixedPoint(self.header[0..8]);
                try validateFixedPoint(fixed_point, t == 8);
                if (t == 8) return 0;
                if (self.output.len < 1) return error.OutputTooSmall;
                self.output[0] = try decodeLinearValue(std.mem.readInt(u32, self.header[8..12], .little), fixed_point);
                return 1;
            },
            .slof => {
                if (self.total < 8 or (self.total - 8) % 2 != 0) return error.InvalidData;
                const value_count = (self.total - 8) / 2;
                if (self.exact and value_count != self.output.len) return error.DecodedSizeMismatch;
                if (self.output.len < value_count) return error.OutputTooSmall;
                try validateFixedPoint(self.fixed_point, value_count == 0);
                if (self.nonfinite) return error.InvalidData;
                return value_count;
            },
        }
    }

    // The end rules on the staged tail: a final zero low nibble is padding, a value past the
    // output is OutputTooSmall, and a cut value is InvalidData.
    fn finalNibbles(self: *Decoder) Error!usize {
        const total = 2 * self.stage_len;
        @memset(self.stage[self.stage_len..][0..8], 0);
        var pos = self.parity;
        while (pos < total) {
            if (pos + 1 == total and pos & 1 == 1 and self.stage[pos >> 1] & 0x0f == 0) break;
            if (self.count == self.output.len) return error.OutputTooSmall;
            const v = stageValue(&self.stage, pos);
            if (pos + v.nibbles > total) return error.InvalidData;
            try self.emit(v.bits);
            pos += v.nibbles;
        }
        return self.count;
    }

    // SLOF codes are decoded while the output has room and counted after it; validity
    // resolves in finish.
    fn slofCodes(self: *Decoder, bytes: []const u8) void {
        var input = bytes;
        if (input.len == 0) return;
        if (self.odd) |low| {
            self.slofScalar(@as(u16, low) | @as(u16, input[0]) << 8);
            input = input[1..];
            self.odd = null;
        }
        const pairs = input.len / 2;
        const room = self.output.len -| self.codes;
        const decode_pairs = @min(pairs, room);
        const out = self.output[@min(self.codes, self.output.len)..][0..decode_pairs];
        const fp: SlofF64s = @splat(self.fixed_point);
        const finite: SlofF64s = @splat(std.math.floatMax(f64));
        var i: usize = 0;
        var all_finite = true;
        while (decode_pairs - i >= SLOF_LANES) : (i += SLOF_LANES) {
            const codes = loadCodes(input[2 * i ..][0 .. 2 * SLOF_LANES]);
            const decoded = expLibm(SLOF_LANES, @as(SlofF64s, @floatFromInt(codes)) / fp) - @as(SlofF64s, @splat(1.0));
            all_finite = all_finite and @reduce(.And, decoded <= finite);
            out[i..][0..SLOF_LANES].* = decoded;
        }
        while (i < decode_pairs) : (i += 1) {
            const decoded = slofValue(std.mem.readInt(u16, input[2 * i ..][0..2], .little), self.fixed_point);
            all_finite = all_finite and decoded <= std.math.floatMax(f64);
            out[i] = decoded;
        }
        if (!all_finite) self.nonfinite = true;
        self.codes += pairs;
        if (input.len % 2 == 1) self.odd = input[input.len - 1];
    }

    fn slofScalar(self: *Decoder, code: u16) void {
        if (self.codes < self.output.len) {
            const decoded = slofValue(code, self.fixed_point);
            if (!(decoded <= std.math.floatMax(f64))) self.nonfinite = true;
            self.output[self.codes] = decoded;
        }
        self.codes += 1;
    }
};

/// Decodes an MS-Numpress linear payload into caller-owned storage.
pub fn decodeLinear(input: []const u8, output: []f64) Error!usize {
    return decodeWhole(.linear, false, input, output);
}

/// Decodes exactly `output.len` Linear values.
pub fn decodeLinearExact(input: []const u8, output: []f64) Error!void {
    _ = try decodeWhole(.linear, true, input, output);
}

/// Decodes an MS-Numpress positive-integer payload into doubles.
pub fn decodePic(input: []const u8, output: []f64) Error!usize {
    return decodeWhole(.pic, false, input, output);
}

/// Decodes exactly `output.len` PIC values.
pub fn decodePicExact(input: []const u8, output: []f64) Error!void {
    _ = try decodeWhole(.pic, true, input, output);
}

/// Decodes an MS-Numpress short-logged-float payload into caller-owned storage.
pub fn decodeSlof(input: []const u8, output: []f64) Error!usize {
    return decodeWhole(.slof, false, input, output);
}

/// Decodes exactly `output.len` SLOF values.
pub fn decodeSlofExact(input: []const u8, output: []f64) Error!void {
    _ = try decodeWhole(.slof, true, input, output);
}

// One update and finish on a fresh decoder, without the sticky-state checks.
inline fn decodeWhole(transform: Transform, exact: bool, input: []const u8, output: []f64) Error!usize {
    var decoder = if (exact) Decoder.initExact(transform, output) else Decoder.init(transform, output);
    decoder.total = input.len;
    decoder.consume(input) catch |err| return decoder.mapped(err);
    const count = decoder.finishInner() catch |err| return decoder.mapped(err);
    if (exact and count != output.len) return error.DecodedSizeMismatch;
    return count;
}

fn convertLinear(values: []f64, fixed_point: f64) void {
    const fp: F64s = @splat(fixed_point);
    var j: usize = 0;
    while (values.len - j >= LANES) : (j += LANES) {
        const y: I64s = @bitCast(values[j..][0..LANES].*);
        values[j..][0..LANES].* = @as(F64s, @floatFromInt(y)) / fp;
    }
    while (j < values.len) : (j += 1) {
        values[j] = @as(f64, @floatFromInt(@as(i64, @bitCast(values[j])))) / fixed_point;
    }
}

// --- Nibble codec ---

// The stream puts each byte's first nibble in its high half. Swapping the halves of every byte
// turns a little-endian word into stream order with the first nibble in bits 0-3, so values
// never need their nibbles reversed one by one.
inline fn swapNibbles(x: u64) u64 {
    return ((x & 0x0f0f_0f0f_0f0f_0f0f) << 4) | ((x >> 4) & 0x0f0f_0f0f_0f0f_0f0f);
}

// One value as a stream-order word: head nibble in bits 0-3, then the body from its least
// significant nibble up. Returns the word and its length in nibbles (1 to 9).
inline fn nibbleWord(v: u32) struct { word: u64, nibbles: u64 } {
    const filled: u32 = @intFromBool((v >> 28) == 0xf);
    // ORing the flag in caps a filled value at 7 leading nibbles (0xffffffff keeps one body
    // nibble) while zero still counts 8, without a min or a branch.
    const leading: u64 = @clz((v ^ (0 -% filled)) | filled) >> 2;
    // Bits above the body are zero for unfilled values; filled ones need the mask.
    const body = @as(u64, v) & (@as(u64, 0xffff_ffff) >> @intCast(4 * leading));
    return .{ .word = (leading + 8 * @as(u64, filled)) | body << 4, .nibbles = 9 - leading };
}

// Packs stream-order words with each byte's first nibble in its low half, the order the words
// are built in, so no value pays for the swap; `swapFinished` turns finished bytes into wire
// order a block at a time. `put` stores 8 bytes after every word and needs 8 bytes of room past
// the current position; `fitting` counts the values that have it.
const RawSink = struct {
    out: []u8,
    pos: usize = 0,
    acc: u64 = 0,
    bits: u64 = 0,
    // Bytes below this are in wire order.
    swapped: usize = 0,

    inline fn put(self: *RawSink, word: u64, nibbles: u64) void {
        self.acc |= word << @intCast(self.bits);
        self.bits += 4 * nibbles;
        std.mem.writeInt(u64, self.out[self.pos..][0..8], self.acc, .little);
        const whole = self.bits >> 3;
        self.pos += whole;
        self.acc >>= @intCast(8 * whole);
        self.bits &= 7;
    }

    fn putChecked(self: *RawSink, word: u64, nibbles: u64) void {
        self.acc |= word << @intCast(self.bits);
        self.bits += 4 * nibbles;
        const whole = self.bits >> 3;
        for (0..whole) |i| self.out[self.pos + i] = @truncate(self.acc >> @intCast(8 * i));
        self.pos += whole;
        self.acc >>= @intCast(8 * whole);
        self.bits &= 7;
    }

    // How many of `count` more values can take `put`: the position grows by at most 4.5 bytes
    // a value, and every store needs 8 bytes. Only the last few values of an output sized to
    // the bound fall outside.
    inline fn fitting(self: *const RawSink, count: usize) usize {
        const room = self.out.len - self.pos;
        if (room < 9) return 0;
        return @min(count, (room - 9) * 2 / 9);
    }

    inline fn putAll(self: *RawSink, codes: []const u32) void {
        const fit = self.fitting(codes.len);
        for (codes[0..fit]) |c| {
            const w = nibbleWord(c);
            self.put(w.word, w.nibbles);
        }
        for (codes[fit..]) |c| {
            const w = nibbleWord(c);
            self.putChecked(w.word, w.nibbles);
        }
        self.swapFinished();
    }

    // Like putAll for codes below 0xf0000000 with known leading zero nibbles: the word is the
    // head (the leading count) and the code above it, with nothing to mask.
    inline fn putAllLeading(self: *RawSink, codes: []const u32, leading: []const u32) void {
        const fit = self.fitting(codes.len);
        for (codes[0..fit], leading[0..fit]) |c, l| self.put(l | @as(u64, c) << 4, 9 - @as(u64, l));
        for (codes[fit..], leading[fit..]) |c, l| self.putChecked(l | @as(u64, c) << 4, 9 - @as(u64, l));
        self.swapFinished();
    }

    fn swapFinished(self: *RawSink) void {
        const V = 16;
        var i = self.swapped;
        while (self.pos - i >= V) : (i += V) {
            const c: @Vector(V, u8) = self.out[i..][0..V].*;
            self.out[i..][0..V].* = (c << @splat(4)) | (c >> @splat(4));
        }
        while (i < self.pos) : (i += 1) self.out[i] = (self.out[i] << 4) | (self.out[i] >> 4);
        self.swapped = self.pos;
    }

    // Writes the finished bytes to `writer` and restarts at the buffer's start; the pending
    // half byte stays in the accumulator.
    fn drain(self: *RawSink, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
        const n = self.pos;
        try writer.writeAll(self.out[0..n]);
        self.pos = 0;
        self.swapped = 0;
        return n;
    }

    fn finish(self: *RawSink) usize {
        self.swapFinished();
        if (self.bits != 0) {
            self.out[self.pos] = @as(u8, @truncate(self.acc & 0xf)) << 4;
            self.pos += 1;
        }
        return self.pos;
    }
};

// Body length and fill bits for each head nibble.
const BODY_NIBBLES = [16]u6{ 8, 7, 6, 5, 4, 3, 2, 1, 0, 7, 6, 5, 4, 3, 2, 1 };
const FILL = [16]u32{
    0, 0,           0,           0,           0,           0,           0,           0,
    0, 0xf000_0000, 0xff00_0000, 0xfff0_0000, 0xffff_0000, 0xffff_f000, 0xffff_ff00, 0xffff_fff0,
};
const BODY_MASK: [16]u32 = blk: {
    var masks: [16]u32 = undefined;
    for (&masks, BODY_NIBBLES) |*m, nibbles| m.* = @truncate((@as(u64, 1) << (4 * nibbles)) - 1);
    break :blk masks;
};

// Input bytes one chase call precomputes; the caller loops until a call decodes nothing.
const CHASE_BYTES = 256;

// Value length (head plus body) for each head nibble, over vector lanes: 9 - h for heads 0-8,
// 17 - h for 9-15.
inline fn lengthsOf(comptime N: usize, heads: @Vector(N, u8)) @Vector(N, u8) {
    const wide = heads > @as(@Vector(N, u8), @splat(8));
    return @select(u8, wide, @as(@Vector(N, u8), @splat(17)), @as(@Vector(N, u8), @splat(9))) - heads;
}

// Where chased values go. PIC writes each value as f64. Linear runs the second-difference
// recurrence in i64 and leaves each value's integer bits in the output slot; the caller
// converts and divides them in a vector pass.
const PicSink = struct {
    out: []f64,

    inline fn put(self: *PicSink, n: usize, bits: u32) void {
        self.out[n] = @floatFromInt(bits);
    }
};

const LinearSink = struct {
    out: []f64,
    step: i64,
    value: i64,

    inline fn put(self: *LinearSink, n: usize, bits: u32) void {
        self.step += @as(i32, @bitCast(bits));
        self.value += self.step;
        self.out[n] = @bitCast(self.value);
    }
};

// Decodes complete values from nibble `start` into `sink` (at most sink.out.len), with every
// load inside the input. A vector pre-pass writes each nibble's value length, as if a value
// started there, and the stream with each byte's halves swapped. Each value's start depends on
// the previous value's head, so the chain is kept to one byte load and one add per value,
// carried in a pointer; each value's bits come from an independent 8-byte load, its head's body
// mask, and its head's fill.
noinline fn unpackChase(
    comptime Sink: type,
    sink: *Sink,
    input: []const u8,
    start: usize,
) struct { count: usize, pos: usize } {
    // Every 8-byte load at byte p >> 1 must fit: values may start below 2 * (len - 8) + 2.
    if (input.len < 8 or start >= 2 * (input.len - 8) + 2) return .{ .count = 0, .pos = start };
    const V = 16;
    const first_byte = start >> 1;
    const bytes: usize = @min(input.len - first_byte, CHASE_BYTES + 8);
    var lengths: [2 * (CHASE_BYTES + 8 + V)]u8 align(16) = undefined;
    var swapped: [CHASE_BYTES + 8 + V]u8 align(16) = undefined;
    var i: usize = 0;
    while (i < bytes) : (i += V) {
        var chunk: @Vector(V, u8) = undefined;
        if (bytes - i >= V) {
            chunk = input[first_byte + i ..][0..V].*;
        } else {
            var tail = [_]u8{0} ** V;
            @memcpy(tail[0 .. bytes - i], input[first_byte + i ..][0 .. bytes - i]);
            chunk = tail;
        }
        const high = chunk >> @splat(4);
        const low = chunk & @as(@Vector(V, u8), @splat(0x0f));
        swapped[i..][0..V].* = (low << @splat(4)) | high;
        lengths[2 * i ..][0 .. 2 * V].* = std.simd.interlace(.{ lengthsOf(V, high), lengthsOf(V, low) });
    }
    // Positions are relative to byte `first_byte`. A value may start where its 8-byte load
    // stays inside the covered bytes, which also keeps it inside the input; it then ends inside
    // that load (16 nibbles, at most 9 used).
    const stop = 2 * (bytes - 8) + 2;
    const origin: [*]const u8 = &lengths;
    var at: [*]const u8 = origin + (start & 1);
    var local = sink.*;
    const room = local.out.len;
    var n: usize = 0;
    // Four values per bound check while four certainly fit: each starts at most 9 nibbles on.
    while (room - n >= 4 and (at - origin) + 27 < stop) {
        inline for (0..4) |k| {
            local.put(n + k, chaseBits(&swapped, at - origin));
            at += at[0];
        }
        n += 4;
    }
    while (n < room and at - origin < stop) {
        local.put(n, chaseBits(&swapped, at - origin));
        at += at[0];
        n += 1;
    }
    sink.* = local;
    return .{ .count = n, .pos = (start & ~@as(usize, 1)) + (at - origin) };
}

inline fn chaseBits(swapped: []const u8, p: usize) u32 {
    const window = std.mem.readInt(u64, swapped[p >> 1 ..][0..8], .little) >> @intCast(4 * (p & 1));
    const head = window & 0xf;
    return (@as(u32, @truncate(window >> 4)) & BODY_MASK[head]) | FILL[head];
}

// The value at nibble `pos` of a stage with at least 8 readable bytes from pos >> 1 (bytes past
// the staged ones are zero and masked off): its bits and its length in nibbles.
inline fn stageValue(stage: *const [STAGE_BYTES]u8, pos: usize) struct { bits: u32, nibbles: usize } {
    const window = swapNibbles(std.mem.readInt(u64, stage[pos >> 1 ..][0..8], .little)) >> @intCast(4 * (pos & 1));
    const head = window & 0xf;
    return .{
        .bits = (@as(u32, @truncate(window >> 4)) & BODY_MASK[head]) | FILL[head],
        .nibbles = 1 + @as(usize, BODY_NIBBLES[head]),
    };
}

inline fn nibbleAt(buf: []const u8, pos: usize) u4 {
    return @truncate(buf[pos >> 1] >> @intCast(4 * (1 - (pos & 1))));
}

// The value bits of the complete value whose head nibble is at `pos`.
fn readBits(buf: []const u8, pos: usize, head: u4) u32 {
    var bits = FILL[head];
    for (0..BODY_NIBBLES[head]) |i| bits |= @as(u32, nibbleAt(buf, pos + 1 + i)) << @intCast(4 * i);
    return bits;
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

// --- Value checks ---

fn validateNonnegative(value: f64) Error!void {
    if (!std.math.isFinite(value)) return error.InvalidValue;
    if (value < 0) return error.InvalidValue;
}

fn validateFixedPoint(fixed_point: f64, allow_zero: bool) Error!void {
    if (!std.math.isFinite(fixed_point) or fixed_point < 0) return error.InvalidFixedPoint;
    if (!allow_zero and fixed_point == 0) return error.InvalidFixedPoint;
}

fn roundedPic(value: f64) Error!u32 {
    try validateNonnegative(value);
    const regular_maximum = @as(f64, @floatFromInt(std.math.maxInt(u32))) - 0.5;
    if (value < regular_maximum) return @intFromFloat(value + 0.5);
    const maximum: f64 = @floatFromInt(std.math.maxInt(u32));
    if (value > maximum) return error.ValueOutOfRange;
    return std.math.maxInt(u32);
}

fn scaleLinear(value: f64, fixed_point: f64) Error!i64 {
    try validateNonnegative(value);
    const scaled_source = value * fixed_point + 0.5;
    if (!std.math.isFinite(scaled_source) or scaled_source >= 0x1p63) {
        return error.ValueOutOfRange;
    }
    return @intFromFloat(scaled_source);
}

fn scaleLinearInitial(value: f64, fixed_point: f64) Error!i64 {
    const scaled = try scaleLinear(value, fixed_point);
    if (scaled > std.math.maxInt(u32)) return error.ValueOutOfRange;
    return scaled;
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

fn slofCode(value: f64, fixed_point: f64) Error!u16 {
    try validateNonnegative(value);
    const scaled = logLibm(value + 1.0) * fixed_point;
    if (!std.math.isFinite(scaled) or scaled > 65_535.0) return error.ValueOutOfRange;
    return @intFromFloat(scaled + 0.5);
}

fn slofValue(code: u16, fixed_point: f64) f64 {
    return expLibm(1, @splat(@as(f64, @floatFromInt(code)) / fixed_point))[0] - 1.0;
}

fn decodeLinearValue(value: i64, fixed_point: f64) Error!f64 {
    const decoded = @as(f64, @floatFromInt(value)) / fixed_point;
    if (!std.math.isFinite(decoded)) return error.InvalidData;
    return decoded;
}

fn writeFixedPoint(output: *[8]u8, fixed_point: f64) void {
    std.mem.writeInt(u64, output, @bitCast(fixed_point), .big);
}

fn readFixedPoint(input: *const [8]u8) f64 {
    return @bitCast(std.mem.readInt(u64, input, .big));
}

// --- SLOF math ---
//
// C++ ms-numpress and numpress-rs call the platform's exp and log; on Linux that is glibc,
// which runs ARM optimized-routines builds of both: an FMA build on CPUs with FMA and a plain
// build otherwise. These ports reproduce both bit for bit. `madd` is a fused multiply-add
// exactly where GCC fused glibc's FMA build and a separate multiply and add otherwise; the FMA
// form is used when the target has FMA, so each build matches glibc on the CPUs it runs on.

const FUSED = switch (builtin.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .fma),
    .aarch64 => true,
    else => false,
};

inline fn madd(a: anytype, b: @TypeOf(a), c: @TypeOf(a)) @TypeOf(a) {
    return if (FUSED) @mulAdd(@TypeOf(a), a, b, c) else a * b + c;
}

// exp(x) for x >= 0 (a SLOF code over its fixed point), as glibc computes it: 1 + x below
// 2^-54, the table path below 512, the scaled path from 512, and +inf from 1024.
fn expLibm(comptime N: usize, x: @Vector(N, f64)) @Vector(N, f64) {
    const F = @Vector(N, f64);
    const U = @Vector(N, u64);
    const shift: F = @splat(libm.exp_shift);
    const big = x >= @as(F, @splat(512.0));
    // x = k ln2/128 + r, |r| <= ln2/256; exp(x) = 2^(k/128) exp(r).
    const z = @as(F, @splat(libm.exp_invln2n)) * x;
    const shifted = z + shift;
    const ki: U = @bitCast(shifted);
    const kd = shifted - shift;
    const r = madd(kd, @as(F, @splat(libm.exp_negln2lon)), madd(kd, @as(F, @splat(libm.exp_negln2hin)), x));
    // 2^(k/128) ~= scale * (1 + tail), from the table entry for k mod 128.
    var tail_bits: U = undefined;
    var scale_bits: U = undefined;
    inline for (0..N) |lane| {
        const index: usize = @intCast(2 * (ki[lane] % 128));
        tail_bits[lane] = libm.exp_tab[index];
        scale_bits[lane] = libm.exp_tab[index + 1];
    }
    const tail: F = @bitCast(tail_bits);
    var sbits = scale_bits +% (ki << @splat(52 - 7));
    // From 512 the scale's exponent may overflow; glibc lowers it by 1009 and multiplies back.
    sbits = @select(u64, big, sbits -% @as(U, @splat(1009 << 52)), sbits);
    const r2 = r * r;
    const c = libm.exp_poly;
    const tmp = madd(
        r2 * r2,
        madd(r, @as(F, @splat(c[3])), @as(F, @splat(c[2]))),
        madd(r2, madd(r, @as(F, @splat(c[1])), @as(F, @splat(c[0]))), tail + r),
    );
    const scale: F = @bitCast(sbits);
    var y = madd(scale, tmp, scale);
    y = @select(f64, big, y * @as(F, @splat(0x1p1009)), y);
    y = @select(f64, x < @as(F, @splat(0x1p-54)), @as(F, @splat(1.0)) + x, y);
    return @select(f64, x >= @as(F, @splat(1024.0)), @as(F, @splat(std.math.inf(f64))), y);
}

// log(x) for finite x >= 1 (a SLOF value plus one), as glibc computes it.
fn logLibm(x: f64) f64 {
    const ix: u64 = @bitCast(x);
    const low: u64 = @bitCast(@as(f64, 1.0 - 0x1p-4));
    const high: u64 = @bitCast(@as(f64, 1.0 + 0x1.09p-4));
    if (ix -% low < high - low) {
        if (x == 1.0) return 0;
        const b = libm.log_poly1;
        const r = x - 1.0;
        const r2 = r * r;
        const r3 = r * r2;
        const p3 = madd(r3, b[10], madd(r2, b[9], madd(r, b[8], b[7])));
        const p2 = madd(r3, p3, madd(r2, b[6], madd(r, b[5], b[4])));
        const p1 = madd(r3, p2, madd(r2, b[3], madd(r, b[2], b[1])));
        // r = rhi + rlo with rhi short enough that rhi * rhi is exact.
        const w0 = r * 0x1p27;
        const rhi = r + w0 - w0;
        const rlo = r - rhi;
        const w = rhi * rhi * b[0];
        const hi = r + w;
        var lo = r - hi + w;
        lo = madd(b[0] * rlo, rhi + r, lo);
        return madd(r3, p1, lo) + hi;
    }
    // x = 2^k z with z in [OFF, 2 OFF); log(x) = log1p(z/c - 1) + log(c) + k ln2.
    const off: u64 = 0x3fe6000000000000;
    const tmp = ix -% off;
    const i: usize = @intCast((tmp >> (52 - 7)) % 128);
    const k: i64 = @as(i64, @bitCast(tmp)) >> 52;
    const z: f64 = @bitCast(ix -% (tmp & (@as(u64, 0xfff) << 52)));
    const invc = libm.log_tab[i].a;
    const logc = libm.log_tab[i].b;
    const r = if (FUSED) @mulAdd(f64, z, invc, -1.0) else (z - libm.log_tab2[i].a - libm.log_tab2[i].b) * invc;
    const kd: f64 = @floatFromInt(k);
    const w = madd(kd, libm.log_ln2hi, logc);
    const hi = w + r;
    const lo = madd(kd, libm.log_ln2lo, w - hi + r);
    const a = libm.log_poly;
    const r2 = r * r;
    const poly = madd(r2, madd(r, a[4], a[3]), madd(r, a[2], a[1]));
    return madd(r * r2, poly, madd(r2, a[0], lo)) + hi;
}

// log(x) for finite x >= 1 over vectors, under 1 ULP (fdlibm's __ieee754_log); the block
// encoder recomputes codes near a rounding boundary with logLibm.
fn logAtLeastOne(comptime N: usize, x: @Vector(N, f64)) @Vector(N, f64) {
    const F = @Vector(N, f64);
    const U = @Vector(N, u64);
    const ln2_hi: F = @splat(6.93147180369123816490e-01);
    const ln2_lo: F = @splat(1.90821492927058770002e-10);
    const bits: U = @bitCast(x);
    var high = (bits >> @splat(32)) + @as(U, @splat(0x3ff00000 - 0x3fe6a09e));
    const k: @Vector(N, i32) = @as(@Vector(N, i32), @intCast(high >> @splat(20))) - @as(@Vector(N, i32), @splat(0x3ff));
    high = (high & @as(U, @splat(0x000fffff))) + @as(U, @splat(0x3fe6a09e));
    const m: F = @bitCast((high << @splat(32)) | (bits & @as(U, @splat(0xffffffff))));
    const f = m - @as(F, @splat(1.0));
    const hfsq = @as(F, @splat(0.5)) * f * f;
    const s = f / (@as(F, @splat(2.0)) + f);
    const z = s * s;
    const w = z * z;
    const t1 = w * (@as(F, @splat(3.999999999940941908e-01)) + w * (@as(F, @splat(2.222219843214978396e-01)) +
        w * @as(F, @splat(1.531383769920937332e-01))));
    const t2 = z * (@as(F, @splat(6.666666666666735130e-01)) + w * (@as(F, @splat(2.857142874366239149e-01)) +
        w * (@as(F, @splat(1.818357216161805012e-01)) + w * @as(F, @splat(1.479819860511658591e-01)))));
    const r = t2 + t1;
    const dk: F = @floatFromInt(k);
    return s * (hfsq + r) + dk * ln2_lo - hfsq + f + dk * ln2_hi;
}
