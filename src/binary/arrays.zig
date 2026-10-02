//! Composes primitive or Numpress bytes, optional zlib, and padded Base64.
//!
//! Only Encoder allocates. Caller buffers must be disjoint unless a function says otherwise,
//! and their contents after a failure are unspecified.

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
/// into the typed output. Encoding: transformed holds Numpress or big-endian primitive bytes
/// without zlib; with zlib they stream into the compressor and transport holds its output.
/// Little-endian primitives without zlib borrow the values' bytes.
pub const Scratch = struct {
    transport: []u8,
    transformed: []u8,
};

/// Linear and SLOF need fixed_point; every other pipeline rejects one.
pub const EncodeOptions = struct {
    pipeline: Pipeline = .none,
    fixed_point: ?f64 = null,
};

/// Typed array values, borrowed.
pub const Values = union(encoding.Primitive) {
    float32: []const f32,
    float64: []const f64,
    int32: []const i32,
    int64: []const i64,

    pub fn of(comptime T: type, values: []const T) Values {
        return @unionInit(Values, @tagName(encoding.Primitive.of(T)), values);
    }
};

/// Borrowed values and how to encode them, for encoding while they are written instead of
/// into a buffer first. The values must stay unchanged until they are written. encoder
/// supplies the zlib compressor, and a buffer where a length must be known before writing.
pub const Source = struct {
    values: Values,
    options: EncodeOptions,
    encoder: ?*Encoder = null,

    pub fn of(comptime T: type, values: []const T, options: EncodeOptions, encoder: ?*Encoder) Source {
        return .{ .values = .of(T, values), .options = options, .encoder = encoder };
    }

    /// Checks the options against the values, with the errors encode would return: the type,
    /// the compressor, and the fixed point's presence and value.
    pub fn check(self: Source) Error!void {
        switch (self.values) {
            inline else => |values| try checkOptions(@typeInfo(@TypeOf(values)).pointer.child, values.len, self.options, self.encoder != null),
        }
    }

    /// The exact wire length when it is known without encoding: primitives without zlib.
    pub fn wireLength(self: Source) ?usize {
        if (self.options.pipeline != .none) return null;
        return switch (self.values) {
            inline else => |values| values.len * @sizeOf(@typeInfo(@TypeOf(values)).pointer.child),
        };
    }

    /// Writes the wire bytes to writer, through the encoder's compressor for zlib pipelines.
    /// Numpress value errors surface here; after one, writer holds an unspecified prefix.
    pub fn writeTo(self: Source, writer: *std.Io.Writer) WriteError!void {
        try self.check();
        switch (self.values) {
            inline else => |values| {
                if (overlaps(writer.buffer, std.mem.sliceAsBytes(values))) return error.OverlappingBuffers;
                const T = @typeInfo(@TypeOf(values)).pointer.child;
                if (!self.options.pipeline.hasZlib()) return writeWire(T, values, self.options, writer);
                const compressor = try (self.encoder orelse return error.MissingCompressor).compressor();
                const compressed = try compressor.startWriter(writer);
                errdefer compressor.cancel();
                try writeWire(T, values, self.options, compressed);
                try compressor.finishWriter();
            },
        }
    }
};

pub const Error = base64.Error || zlib.Error || numpress.Error || error{
    TypeMismatch,
    MissingFixedPoint,
    UnexpectedFixedPoint,
    MissingCompressor,
};

/// Decodes exactly output.len values. T is f32, f64, i32, or i64, and Numpress needs f64.
/// Primitive bytes are little endian, and float bits are kept exactly.
pub fn decode(
    comptime T: type,
    output: []T,
    source: []const u8,
    pipeline: Pipeline,
    scratch: Scratch,
) Error!void {
    _ = encoding.Primitive.of(T);
    try checkBuffers(std.mem.sliceAsBytes(output), source, scratch);
    if (pipeline.isNumpress() and T != f64) return error.TypeMismatch;
    const destination = if (pipeline == .none) std.mem.sliceAsBytes(output) else scratch.transport;
    const counts = base64.decode(destination, source) catch |err| {
        if (err != error.OutputTooSmall) return err;
        // Filling output, or Numpress scratch as large as its bound, means the text holds more
        // than the declared values; shorter scratch is the caller's buffer.
        if (pipeline == .none) return error.DecodedSizeMismatch;
        if (pipeline.isNumpress() and !pipeline.hasZlib() and scratch.transport.len >= try wireBound(T, output.len, pipeline))
            return error.DecodedSizeMismatch;
        return err;
    };
    try decodeWireInner(T, output, destination[0..counts.decoded_bytes], pipeline, scratch.transformed);
}

/// Like decode, starting from the bytes after Base64. transformed is used only by Numpress
/// with zlib. With pipeline none, source may start at output's address to convert in place.
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
    if (pipeline.isNumpress() and T != f64) return error.TypeMismatch;
    try decodeWireInner(T, output, source, pipeline, transformed);
}

fn decodeWireInner(comptime T: type, output: []T, source: []const u8, pipeline: Pipeline, transformed: []u8) Error!void {
    const array_bytes = std.math.mul(usize, output.len, @sizeOf(T)) catch return error.LengthOverflow;
    var wire = source;
    if (pipeline.hasZlib()) {
        const maximum = try wireBound(T, output.len, pipeline);
        const inflated = if (pipeline.isNumpress()) transformed[0..@min(maximum, transformed.len)] else std.mem.sliceAsBytes(output);
        // Filling the full bound means the stream holds more than the declared values;
        // shorter transformed scratch is the caller's buffer.
        wire = zlib.decompress(inflated, wire) catch |err|
            return if (err == error.OutputTooSmall and inflated.len == maximum) error.DecodedSizeMismatch else err;
    }
    if (pipeline.transform()) |transform| {
        if (T == f64) return numpress.decodeExact(transform, wire, output) else unreachable;
    }
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
}

/// Encodes values as Base64 into output and returns the written prefix. compressor is needed
/// only for zlib pipelines. Numpress takes f32 or f64 values and always decodes to f64.
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

/// Like encode, stopping before Base64. The result borrows values for little-endian
/// primitives without zlib, and scratch otherwise.
pub fn encodeWire(
    comptime T: type,
    values: []const T,
    options: EncodeOptions,
    scratch: Scratch,
    compressor: ?*zlib.Compressor,
) Error![]const u8 {
    _ = encoding.Primitive.of(T);
    try checkBuffers(&.{}, std.mem.sliceAsBytes(values), scratch);
    try checkOptions(T, values.len, options, compressor != null);
    if (options.pipeline.hasZlib()) {
        const writer = try compressor.?.start(scratch.transport);
        errdefer compressor.?.cancel();
        writeWire(T, values, options, writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutputTooSmall,
            else => |e| return e,
        };
        return compressor.?.finish();
    }

    // Numpress slice encoding reports the exact error for short scratch, which a fixed
    // writer cannot.
    if (options.pipeline.transform()) |transform| {
        if (T != f64 and T != f32) unreachable;
        return scratch.transformed[0..try numpress.encode(transform, values, options.fixed_point orelse 0, scratch.transformed)];
    }
    if (@import("builtin").cpu.arch.endian() == .little) return std.mem.sliceAsBytes(values);
    const required = try wireBound(T, values.len, options.pipeline);
    if (scratch.transformed.len < required) return error.OutputTooSmall;
    var writer = std.Io.Writer.fixed(scratch.transformed[0..required]);
    writePrimitives(T, values, &writer) catch unreachable;
    return writer.buffered();
}

// Writes primitive or Numpress bytes into a zlib compressor's writer.
fn writeWire(comptime T: type, values: []const T, options: EncodeOptions, writer: *std.Io.Writer) numpress.WriteError!void {
    if (options.pipeline.transform()) |transform| {
        if (T != f64 and T != f32) unreachable else _ = try numpress.encodeTo(transform, values, options.fixed_point orelse 0, writer);
    } else try writePrimitives(T, values, writer);
}

// Writes primitive values as little-endian bytes.
fn writePrimitives(comptime T: type, values: []const T, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (@import("builtin").cpu.arch.endian() == .little) return writer.writeAll(std.mem.sliceAsBytes(values));
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    for (values) |value| try writer.writeInt(Bits, @bitCast(value), .little);
}

fn checkOptions(comptime T: type, count: usize, options: EncodeOptions, has_compressor: bool) Error!void {
    const selected = options.pipeline.transform();
    if (selected != null and T != f64 and T != f32) return error.TypeMismatch;
    if (options.pipeline.hasZlib() and !has_compressor) return error.MissingCompressor;
    if (selected == .linear or selected == .slof) {
        try numpress.validateFixedPoint(options.fixed_point orelse return error.MissingFixedPoint, count == 0);
    } else if (options.fixed_point != null) return error.UnexpectedFixedPoint;
}

pub const EncodeError = Error || std.mem.Allocator.Error;
pub const WriteError = EncodeError || std.Io.Writer.Error;

/// Encodes arrays with storage it owns: the zlib compressor (allocated on first use) and one
/// output buffer per array encoded since the last reset. With zlib, primitive or Numpress
/// bytes go straight into the compressor, so no buffer holds them whole. Do not copy an
/// initialized encoder.
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    preset: zlib.Preset,
    compressor_state: ?zlib.Compressor = null,
    outputs: std.ArrayList(std.ArrayList(u8)) = .empty,
    used: usize = 0,

    pub fn init(allocator: std.mem.Allocator, preset: zlib.Preset) Encoder {
        return .{ .allocator = allocator, .preset = preset };
    }

    pub fn deinit(self: *Encoder) void {
        if (self.compressor_state) |*state| state.deinit();
        for (self.outputs.items) |*output| output.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
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
        const transformed = options.pipeline.isNumpress() or
            @import("builtin").cpu.arch.endian() == .big;
        if (!options.pipeline.hasZlib()) {
            if (!transformed) return encodeWire(T, values, options, .{ .transport = &.{}, .transformed = &.{} }, null);
            const output = try self.nextOutput(bound);
            return encodeWire(T, values, options, .{ .transport = &.{}, .transformed = output }, null);
        }
        const state = try self.compressor();
        const output = try self.nextOutput(zlib.compressBound(bound));
        return encodeWire(T, values, options, .{ .transport = output, .transformed = &.{} }, state);
    }

    /// Encodes a source like encode.
    pub fn encodeSource(self: *Encoder, source: Source) EncodeError![]const u8 {
        return switch (source.values) {
            inline else => |values| self.encode(@typeInfo(@TypeOf(values)).pointer.child, values, source.options),
        };
    }

    /// The encoder's compressor, allocated on first use.
    pub fn compressor(self: *Encoder) std.mem.Allocator.Error!*zlib.Compressor {
        if (self.compressor_state == null) self.compressor_state = try zlib.Compressor.init(self.allocator, self.preset);
        return &self.compressor_state.?;
    }

    /// Whether the next encode reuses storage holding bytes, which a reset left there: the
    /// encode would overwrite or free them.
    pub fn reuses(self: *const Encoder, bytes: []const u8) bool {
        if (self.used == self.outputs.items.len) return false;
        return overlaps(self.outputs.items[self.used].allocatedSlice(), bytes);
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
    const transform = pipeline.transform() orelse
        return std.math.mul(usize, count, @sizeOf(T)) catch error.LengthOverflow;
    if (T != f64 and T != f32) return error.TypeMismatch;
    return numpress.maxEncodedLen(transform, count);
}

fn checkBuffers(output: []u8, source: []const u8, scratch: Scratch) Error!void {
    const buffers = [_][]const u8{ output, source, scratch.transport, scratch.transformed };
    for (buffers, 0..) |a, i| {
        for (buffers[i + 1 ..]) |b| {
            if (overlaps(a, b)) return error.OverlappingBuffers;
        }
    }
}
