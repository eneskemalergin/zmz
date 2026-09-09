//! Composes primitive or Numpress bytes, optional zlib, and padded Base64.
//!
//! These operations do not interpret CV terms or infer an array's scientific role.

const std = @import("std");
const base64 = @import("base64.zig");
const zlib = @import("zlib.zig");
const numpress = @import("numpress.zig");

/// Established array pipelines, named in encoding order before the Base64 envelope.
pub const Pipeline = enum { none, zlib, linear, pic, slof, linear_zlib, pic_zlib, slof_zlib };

/// Caller-owned disjoint scratch buffers. Neither buffer aliases input or output.
/// Transport holds Base64-decoded bytes; transformed holds uncompressed wire bytes.
/// Encoding uses transformed for primitive or Numpress bytes and transport only for zlib.
pub const Scratch = struct {
    transport: []u8,
    transformed: []u8,
};

/// Input-text and final typed-output limits, independently of scratch capacity.
pub const Limits = struct {
    base64_text: base64.Limits = .{},
    array_bytes: usize = 192 * 1024 * 1024,
};

/// Lossy transforms require explicit caller selection; Linear and SLOF require a fixed point.
/// An unused fixed point is rejected instead of silently ignored.
pub const EncodeOptions = struct {
    pipeline: Pipeline = .none,
    fixed_point: ?f64 = null,
};

/// Composition errors retain the underlying lexical and codec distinctions.
pub const Error = base64.Error || zlib.Error || numpress.Error || error{
    TypeMismatch,
    MissingFixedPoint,
    UnexpectedFixedPoint,
    MissingCompressor,
};

/// Decodes exactly output.len values. T is f32, f64, i32, or i64; Numpress requires f64.
/// Primitive bytes are little endian and float bits are preserved without conversion.
/// No allocation occurs. Output and scratch contents after failure are unspecified.
pub fn decode(
    comptime T: type,
    output: []T,
    source: []const u8,
    pipeline: Pipeline,
    scratch: Scratch,
    limits: Limits,
) Error!void {
    checkType(T);
    try checkBuffers(std.mem.sliceAsBytes(output), source, scratch);
    const array_bytes = std.math.mul(usize, output.len, @sizeOf(T)) catch
        return error.LengthOverflow;
    if (array_bytes > limits.array_bytes) return error.LimitExceeded;
    if (transform(pipeline) != .none and T != f64) return error.TypeMismatch;
    const counts = try base64.decode(scratch.transport, source, limits.base64_text);
    var wire: []const u8 = scratch.transport[0..counts.decoded_bytes];
    if (hasZlib(pipeline)) {
        const maximum = try wireBound(T, output.len, pipeline);
        wire = try zlib.decompress(scratch.transformed[0..@min(maximum, scratch.transformed.len)], wire);
    }
    switch (transform(pipeline)) {
        .none => {
            if (wire.len != array_bytes) return error.DecodedSizeMismatch;
            const Bits = @Int(.unsigned, @bitSizeOf(T));
            for (output, 0..) |*value, index| {
                const offset = index * @sizeOf(T);
                value.* = @bitCast(std.mem.readInt(Bits, wire[offset..][0..@sizeOf(T)], .little));
            }
        },
        .linear => if (T == f64) try numpress.decodeLinearExact(wire, output) else return error.TypeMismatch,
        .pic => if (T == f64) try numpress.decodePicExact(wire, output) else return error.TypeMismatch,
        .slof => if (T == f64) try numpress.decodeSlofExact(wire, output) else return error.TypeMismatch,
    }
}

/// Encodes values into caller-owned Base64 storage and returns its written prefix.
/// A reusable compressor is required only for zlib pipelines. No allocation occurs here.
pub fn encode(
    comptime T: type,
    output: []u8,
    values: []const T,
    options: EncodeOptions,
    scratch: Scratch,
    compressor: ?*zlib.Compressor,
) Error![]u8 {
    checkType(T);
    try checkBuffers(output, std.mem.sliceAsBytes(values), scratch);
    const selected = transform(options.pipeline);
    if (selected != .none and T != f64) return error.TypeMismatch;
    if (hasZlib(options.pipeline) and compressor == null) return error.MissingCompressor;
    if (selected == .linear or selected == .slof) {
        if (options.fixed_point == null) return error.MissingFixedPoint;
    } else if (options.fixed_point != null) return error.UnexpectedFixedPoint;

    const length = switch (selected) {
        .none => blk: {
            const required = try wireBound(T, values.len, options.pipeline);
            if (scratch.transformed.len < required) return error.OutputTooSmall;
            const Bits = @Int(.unsigned, @bitSizeOf(T));
            for (values, 0..) |value, index| {
                const offset = index * @sizeOf(T);
                std.mem.writeInt(Bits, scratch.transformed[offset..][0..@sizeOf(T)], @bitCast(value), .little);
            }
            break :blk required;
        },
        .linear => if (T == f64)
            try numpress.encodeLinear(values, options.fixed_point.?, scratch.transformed)
        else
            return error.TypeMismatch,
        .pic => if (T == f64)
            try numpress.encodePic(values, scratch.transformed)
        else
            return error.TypeMismatch,
        .slof => if (T == f64)
            try numpress.encodeSlof(values, options.fixed_point.?, scratch.transformed)
        else
            return error.TypeMismatch,
    };
    var wire: []const u8 = scratch.transformed[0..length];
    if (hasZlib(options.pipeline)) wire = try compressor.?.compress(scratch.transport, wire);
    return base64.encode(output, wire);
}

/// Returns the primitive or Numpress wire capacity before optional zlib compression.
/// This is not a bound for the zlib stream or its Base64 representation.
pub fn wireBound(comptime T: type, count: usize, pipeline: Pipeline) Error!usize {
    checkType(T);
    if (transform(pipeline) != .none and T != f64) return error.TypeMismatch;
    return switch (transform(pipeline)) {
        .none => std.math.mul(usize, count, @sizeOf(T)) catch error.LengthOverflow,
        .linear => numpress.linearMaxEncodedLen(count),
        .pic => numpress.picMaxEncodedLen(count),
        .slof => numpress.slofEncodedLen(count),
    };
}

const Transform = enum { none, linear, pic, slof };

fn transform(pipeline: Pipeline) Transform {
    return switch (pipeline) {
        .none, .zlib => .none,
        .linear, .linear_zlib => .linear,
        .pic, .pic_zlib => .pic,
        .slof, .slof_zlib => .slof,
    };
}

fn hasZlib(pipeline: Pipeline) bool {
    return switch (pipeline) {
        .zlib, .linear_zlib, .pic_zlib, .slof_zlib => true,
        else => false,
    };
}

fn checkType(comptime T: type) void {
    if (T != f32 and T != f64 and T != i32 and T != i64)
        @compileError("array values must be f32, f64, i32, or i64");
}

fn checkBuffers(output: []u8, source: []const u8, scratch: Scratch) Error!void {
    const buffers = [_][]const u8{ output, source, scratch.transport, scratch.transformed };
    for (buffers, 0..) |a, i| {
        if (a.len == 0) continue;
        for (buffers[i + 1 ..]) |b| {
            if (b.len == 0) continue;
            const start_a = @intFromPtr(a.ptr);
            const start_b = @intFromPtr(b.ptr);
            const overlap = if (start_a <= start_b)
                start_b - start_a < a.len
            else
                start_a - start_b < b.len;
            if (overlap) return error.OverlappingBuffers;
        }
    }
}
