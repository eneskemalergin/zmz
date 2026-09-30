//! Composes primitive or Numpress bytes, optional zlib, and padded Base64.
//!
//! These operations do not interpret CV terms or infer an array's scientific role.

const std = @import("std");
const base64 = @import("base64.zig");
const zlib = @import("zlib.zig");
const numpress = @import("numpress.zig");
const encoding = @import("encoding.zig");
const overlaps = @import("core.zig").overlaps;

pub const Pipeline = encoding.Pipeline;

/// Caller-owned scratch, disjoint from each other and from input and output.
/// Decoding: transport holds the Base64-decoded bytes of any pipeline except none, and
/// transformed holds zlib output for Numpress with zlib; primitive zlib expands straight
/// into the typed output. Encoding: transformed holds Numpress or big-endian primitive
/// bytes and transport the zlib output; little-endian primitives borrow the values' bytes.
pub const Scratch = struct {
    transport: []u8,
    transformed: []u8,
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
) Error!void {
    _ = encoding.Primitive.of(T);
    try checkBuffers(std.mem.sliceAsBytes(output), source, scratch);
    if (pipeline.transform() != .none and T != f64) return error.TypeMismatch;
    const destination = if (pipeline == .none) std.mem.sliceAsBytes(output) else scratch.transport;
    const counts = base64.decode(destination, source) catch |err| {
        if (pipeline != .none or err != error.OutputTooSmall) return err;
        return error.DecodedSizeMismatch;
    };
    try decodeWireInner(T, output, destination[0..counts.decoded_bytes], pipeline, scratch.transformed);
}

/// Decodes bytes after Base64 into exactly output.len values without allocation.
/// T and primitive byte order follow decode. Transformed scratch is needed only for
/// Numpress with zlib. Buffers must be disjoint, except that .none permits source and
/// output to start at the same address.
pub fn decodeWire(
    comptime T: type,
    output: []T,
    source: []const u8,
    pipeline: Pipeline,
    transformed: []u8,
) Error!void {
    _ = encoding.Primitive.of(T);
    const bytes = std.mem.sliceAsBytes(output);
    const in_place = pipeline == .none and bytes.ptr == source.ptr;
    try checkBuffers(bytes, if (in_place) &.{} else source, .{ .transport = &.{}, .transformed = transformed });
    if (in_place) try checkBuffers(transformed, source, .{ .transport = &.{}, .transformed = &.{} });
    if (pipeline.transform() != .none and T != f64) return error.TypeMismatch;
    try decodeWireInner(T, output, source, pipeline, transformed);
}

fn decodeWireInner(comptime T: type, output: []T, source: []const u8, pipeline: Pipeline, transformed: []u8) Error!void {
    const array_bytes = std.math.mul(usize, output.len, @sizeOf(T)) catch return error.LengthOverflow;
    var wire = source;
    if (pipeline.hasZlib()) {
        const maximum = try wireBound(T, output.len, pipeline);
        const inflated = if (pipeline.transform() == .none) std.mem.sliceAsBytes(output) else transformed[0..@min(maximum, transformed.len)];
        // Filling the full bound means the stream holds more than the declared values;
        // shorter transformed scratch is the caller's buffer.
        wire = zlib.decompress(inflated, wire) catch |err|
            return if (err == error.OutputTooSmall and inflated.len == maximum) error.DecodedSizeMismatch else err;
    }
    switch (pipeline.transform()) {
        .none => {
            if (wire.len != array_bytes) return error.DecodedSizeMismatch;
            if (@import("builtin").cpu.arch.endian() == .little) {
                const bytes = std.mem.sliceAsBytes(output);
                if (bytes.ptr != wire.ptr) @memcpy(bytes, wire);
                return;
            }
            const Bits = @Int(.unsigned, @bitSizeOf(T));
            for (output, 0..) |*value, index| {
                const offset = index * @sizeOf(T);
                value.* = @bitCast(std.mem.readInt(Bits, wire[offset..][0..@sizeOf(T)], .little));
            }
        },
        .linear => if (T == f64) try numpress.decodeLinearExact(wire, output) else unreachable,
        .pic => if (T == f64) try numpress.decodePicExact(wire, output) else unreachable,
        .slof => if (T == f64) try numpress.decodeSlofExact(wire, output) else unreachable,
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
    _ = encoding.Primitive.of(T);
    try checkBuffers(output, std.mem.sliceAsBytes(values), scratch);
    return base64.encode(output, try encodeWire(T, values, options, scratch, compressor));
}

/// Prepares primitive or Numpress bytes with optional zlib, without Base64 or allocation.
/// The result borrows values on little-endian primitive paths without zlib; otherwise it
/// borrows scratch until that buffer is reused. All supplied buffers must remain disjoint.
/// A reusable compressor is required only for zlib pipelines.
pub fn encodeWire(
    comptime T: type,
    values: []const T,
    options: EncodeOptions,
    scratch: Scratch,
    compressor: ?*zlib.Compressor,
) Error![]const u8 {
    _ = encoding.Primitive.of(T);
    try checkBuffers(&.{}, std.mem.sliceAsBytes(values), scratch);
    const selected = options.pipeline.transform();
    if (selected != .none and T != f64) return error.TypeMismatch;
    if (options.pipeline.hasZlib() and compressor == null) return error.MissingCompressor;
    if (selected == .linear or selected == .slof) {
        if (options.fixed_point == null) return error.MissingFixedPoint;
    } else if (options.fixed_point != null) return error.UnexpectedFixedPoint;

    if (selected == .none and @import("builtin").cpu.arch.endian() == .little) {
        const wire = std.mem.sliceAsBytes(values);
        return if (options.pipeline.hasZlib()) try compressor.?.compress(scratch.transport, wire) else wire;
    }

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
            unreachable,
        .pic => if (T == f64)
            try numpress.encodePic(values, scratch.transformed)
        else
            unreachable,
        .slof => if (T == f64)
            try numpress.encodeSlof(values, options.fixed_point.?, scratch.transformed)
        else
            unreachable,
    };
    var wire: []const u8 = scratch.transformed[0..length];
    if (options.pipeline.hasZlib()) wire = try compressor.?.compress(scratch.transport, wire);
    return wire;
}

/// Encoder failures: composition errors or failed allocation of its storage.
pub const EncodeError = Error || std.mem.Allocator.Error;

/// Encodes arrays with storage it owns: scratch, the zlib compressor (allocated on first
/// use), and one output buffer per array encoded since the last reset. Callers size and
/// retry nothing. Do not copy an initialized encoder.
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    preset: zlib.Preset,
    compressor: ?zlib.Compressor = null,
    transformed: std.ArrayList(u8) = .empty,
    outputs: std.ArrayList(std.ArrayList(u8)) = .empty,
    used: usize = 0,

    pub fn init(allocator: std.mem.Allocator, preset: zlib.Preset) Encoder {
        return .{ .allocator = allocator, .preset = preset };
    }

    pub fn deinit(self: *Encoder) void {
        if (self.compressor) |*compressor| compressor.deinit();
        for (self.outputs.items) |*output| output.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
        self.transformed.deinit(self.allocator);
        self.* = undefined;
    }

    /// Invalidates every wire returned since the last reset; capacity is kept for reuse.
    pub fn reset(self: *Encoder) void {
        self.used = 0;
    }

    /// Encodes values into wire bytes (primitive or Numpress, then optional zlib), valid
    /// until reset or deinit. Little-endian primitives without zlib borrow values instead.
    pub fn encode(self: *Encoder, comptime T: type, values: []const T, options: EncodeOptions) EncodeError![]const u8 {
        const bound = try wireBound(T, values.len, options.pipeline);
        const transformed = options.pipeline.transform() != .none or
            @import("builtin").cpu.arch.endian() == .big;
        if (!options.pipeline.hasZlib()) {
            if (!transformed) return encodeWire(T, values, options, .{ .transport = &.{}, .transformed = &.{} }, null);
            const output = try self.nextOutput(bound);
            return encodeWire(T, values, options, .{ .transport = &.{}, .transformed = output }, null);
        }
        if (self.compressor == null) self.compressor = try zlib.Compressor.init(self.allocator, self.preset);
        if (transformed) try self.transformed.resize(self.allocator, bound);
        const output = try self.nextOutput(zlib.compressBound(bound));
        return encodeWire(T, values, options, .{
            .transport = output,
            .transformed = if (transformed) self.transformed.items else &.{},
        }, &self.compressor.?);
    }

    fn nextOutput(self: *Encoder, size: usize) std.mem.Allocator.Error![]u8 {
        if (self.used == self.outputs.items.len) try self.outputs.append(self.allocator, .empty);
        const output = &self.outputs.items[self.used];
        try output.resize(self.allocator, size);
        self.used += 1;
        return output.items;
    }
};

/// Returns the primitive or Numpress wire capacity before optional zlib compression.
/// This is not a bound for the zlib stream or its Base64 representation.
pub fn wireBound(comptime T: type, count: usize, pipeline: Pipeline) Error!usize {
    _ = encoding.Primitive.of(T);
    if (pipeline.transform() != .none and T != f64) return error.TypeMismatch;
    return switch (pipeline.transform()) {
        .none => std.math.mul(usize, count, @sizeOf(T)) catch error.LengthOverflow,
        .linear => numpress.linearMaxEncodedLen(count),
        .pic => numpress.picMaxEncodedLen(count),
        .slof => numpress.slofEncodedLen(count),
    };
}

fn checkBuffers(output: []u8, source: []const u8, scratch: Scratch) Error!void {
    const buffers = [_][]const u8{ output, source, scratch.transport, scratch.transformed };
    for (buffers, 0..) |a, i| {
        for (buffers[i + 1 ..]) |b| {
            if (overlaps(a, b)) return error.OverlappingBuffers;
        }
    }
}
