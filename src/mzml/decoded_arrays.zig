//! Stores decoded arrays for sequential and indexed reads without retaining Base64 text.
//!
//! Each array keeps its source primitive, except Numpress output is always f64. Numeric
//! buffers and shared wire scratch grow as needed and are reused between records.
//! Selected results stay in source order; source_position indexes record.binaryArrays().
//! Results become visible only after the complete record succeeds. Returned slices last
//! until the next decoded read using this owner, reset, or deinit; ordinary reads do not
//! invalidate them. No source metadata is borrowed by this owner.

const std = @import("std");
const model = @import("model.zig");
const cv = @import("../cv/source.zig");
const arrays = @import("../binary/arrays.zig");
const base64 = @import("../binary/base64.zig");
const encoding = @import("../binary/encoding.zig");

const DecodedArrays = @This();

pub const Error = model.EncodingError || cv.ValueError || arrays.Error || std.mem.Allocator.Error;
pub const Values = union(model.Primitive) {
    float32: []const f32,
    float64: []const f64,
    int32: []const i32,
    int64: []const i64,
};
pub const Array = struct { source_position: usize, encoding: model.Encoding, values: Values };

allocator: std.mem.Allocator,
limits: arrays.Limits,
outputs: std.ArrayList(Output) = .empty,
wire: std.ArrayList(u8) = .empty,
transformed: std.ArrayList(u8) = .empty,
count: usize = 0,
ready: bool = false,
default_length: ?usize = null,
decoder: base64.Decoder = undefined,

pub fn init(allocator: std.mem.Allocator, limits: arrays.Limits) DecodedArrays {
    return .{ .allocator = allocator, .limits = limits };
}

pub fn deinit(self: *DecodedArrays) void {
    for (self.outputs.items) |*output| output.words.deinit(self.allocator);
    self.outputs.deinit(self.allocator);
    self.wire.deinit(self.allocator);
    self.transformed.deinit(self.allocator);
    self.* = undefined;
}

/// Invalidates results while retaining allocated capacity.
pub fn reset(self: *DecodedArrays) void {
    self.count = 0;
    self.ready = false;
}

pub fn len(self: *const DecodedArrays) usize {
    return if (self.ready) self.count else 0;
}

pub fn get(self: *const DecodedArrays, position: usize) ?Array {
    if (position >= self.len()) return null;
    const output = &self.outputs.items[position];
    return .{
        .source_position = output.source_position,
        .encoding = output.encoding,
        .values = switch (output.primitive()) {
            .float32 => .{ .float32 = output.values(f32) },
            .float64 => .{ .float64 = output.values(f64) },
            .int32 => .{ .int32 = output.values(i32) },
            .int64 => .{ .int64 = output.values(i64) },
        },
    };
}

pub fn startRecord(self: *DecodedArrays, node: model.Node) Error!void {
    self.default_length = if (node.attribute("defaultArrayLength")) |value| try cv.parseInteger(usize, value) else null;
}

pub fn text(self: *DecodedArrays, bytes: []const u8) Error!void {
    const compressed = self.outputs.items[self.count - 1].encoding.pipeline != .none;
    if (compressed) {
        const total = std.math.add(usize, self.decoder.counts.text_bytes, bytes.len) catch return error.LengthOverflow;
        if (total > self.limits.base64_text.text_bytes) return error.LimitExceeded;
        const incoming = @min(bytes.len, self.limits.base64_text.significant_bytes -| self.decoder.counts.significant_bytes);
        const pending = std.math.add(usize, incoming, self.decoder.quartet_len) catch return error.LengthOverflow;
        const needed = std.math.add(usize, self.decoder.counts.decoded_bytes, pending / 4 * 3) catch return error.LengthOverflow;
        try self.wire.resize(self.allocator, @min(needed, self.limits.base64_text.decoded_bytes));
        self.decoder.output = self.wire.items;
    }
    self.decoder.update(bytes) catch |err| return if (err == error.OutputTooSmall and !compressed)
        error.DecodedSizeMismatch
    else
        err;
}

pub fn complete(self: *DecodedArrays) void {
    self.ready = true;
}

pub fn beginArray(self: *DecodedArrays, node: model.Node, groups: []const cv.Group, source_position: usize) Error!void {
    const array = try model.BinaryArray.init(node, self.default_length, groups);
    if (self.count == self.outputs.items.len) try self.outputs.append(self.allocator, .{});
    const output = &self.outputs.items[self.count];
    self.count += 1;
    output.source_position = source_position;
    output.encoding = array.encoding;
    output.length = array.length;
    const width: usize = switch (output.primitive()) {
        .float32, .int32 => 4,
        .float64, .int64 => 8,
    };
    const bytes = std.math.mul(usize, array.length, width) catch return error.LengthOverflow;
    if (bytes > self.limits.array_bytes) return error.LimitExceeded;
    try output.words.resize(self.allocator, bytes / 8 + @intFromBool(bytes % 8 != 0));
    self.wire.clearRetainingCapacity();
    try self.transformed.resize(self.allocator, switch (array.encoding.pipeline) {
        .linear_zlib, .pic_zlib, .slof_zlib => try arrays.wireBound(f64, array.length, array.encoding.pipeline),
        else => 0,
    });
    const destination = if (array.encoding.pipeline == .none) std.mem.sliceAsBytes(output.words.items)[0..bytes] else self.wire.items;
    self.decoder = base64.Decoder.init(destination, self.limits.base64_text);
}

pub fn finishArray(self: *DecodedArrays) Error!void {
    const counts = try self.decoder.finish();
    const output = &self.outputs.items[self.count - 1];
    const wire = self.decoder.output[0..counts.decoded_bytes];
    const pipeline = if (output.length == 0 and output.encoding.pipeline == .zlib and counts.significant_bytes == 0)
        arrays.Pipeline.none
    else
        output.encoding.pipeline;
    switch (output.primitive()) {
        .float32 => try arrays.decodeWire(f32, output.values(f32), wire, pipeline, self.transformed.items, self.limits),
        .float64 => try arrays.decodeWire(f64, output.values(f64), wire, pipeline, self.transformed.items, self.limits),
        .int32 => try arrays.decodeWire(i32, output.values(i32), wire, pipeline, self.transformed.items, self.limits),
        .int64 => try arrays.decodeWire(i64, output.values(i64), wire, pipeline, self.transformed.items, self.limits),
    }
}

const Output = struct {
    words: std.ArrayList(u64) = .empty,
    source_position: usize = 0,
    encoding: model.Encoding = undefined,
    length: usize = 0,

    fn primitive(self: *const Output) model.Primitive {
        return if (encoding.isNumpress(self.encoding.pipeline)) .float64 else self.encoding.primitive;
    }

    fn values(self: *const Output, comptime T: type) []T {
        return std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(self.words.items))[0..self.length];
    }
};
