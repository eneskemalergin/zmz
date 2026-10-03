//! Stores decoded arrays from decoded reads (nextDecodedRecord, byIdDecoded, atDecoded)
//! and from records whose Base64 text was retained (decodeRecord, decodeArray).
//!
//! Each array keeps its source primitive, except Numpress output is always f64. Numeric
//! buffers grow as needed and are reused between records. Every array decodes as its text
//! arrives: Base64 goes straight into typed output, into a fixed window for Numpress, or, with
//! zlib, through a window that the decompressor pulls from. No buffer holds a payload whole.
//! Selected results stay in source order; source_position indexes record.binaryArrays().
//! Results become visible only after the complete record succeeds. Returned slices last
//! until the next decoded read using this owner, reset, or deinit; ordinary reads do not
//! invalidate them. No source metadata is borrowed by this owner.
//!
//! startRecord, beginArray, decodeText, and complete are the reader engine's entry points
//! while it parses a record; callers use the reads and decode functions.

const std = @import("std");
const model = @import("model.zig");
const cv = @import("../cv/source.zig");
const arrays = @import("../binary/arrays.zig");
const base64 = @import("../binary/base64.zig");
const numpress = @import("../binary/numpress.zig");
const zlib = @import("../binary/zlib.zig");
const Diagnostic = @import("diagnostic.zig");

const DecodedArrays = @This();

pub const Error = model.EncodingError || cv.ValueError || arrays.Error || std.mem.Allocator.Error || error{LimitExceeded};
pub const Values = union(model.Primitive) {
    float32: []const f32,
    float64: []const f64,
    int32: []const i32,
    int64: []const i64,
};
pub const Array = struct { source_position: usize, encoding: model.Encoding, values: Values };

/// Bounds each array's decoded typed bytes, allocated from its declared length. The reader's
/// binary_text_bytes bounds the Base64 text.
pub const Limits = struct { array_bytes: usize = 192 * 1024 * 1024 };

// Bytes decoded per step: Numpress input from Base64, or Base64 output for the decompressor. A
// zlib payload that fits whole (most spectra) is decoded in one call, straight into its values.
const WINDOW = 64 * 1024;

allocator: std.mem.Allocator,
limits: Limits,
outputs: std.ArrayList(Output) = .empty,
window: std.ArrayList(u8) = .empty,
decompressor: ?zlib.Decompressor = null,
count: usize = 0,
ready: bool = false,
default_length: ?usize = null,
decoder: base64.Decoder = undefined,
values: numpress.Decoder = undefined,
// The first Numpress error of the current array. It is reported only after the Base64 and
// zlib layers finish, so their errors come first, as when each layer decodes the whole payload.
deferred: ?numpress.Error = null,
failure: ?struct { stage: Diagnostic.Stage, detail: Diagnostic.Detail = .none } = null,

pub fn init(allocator: std.mem.Allocator, limits: Limits) DecodedArrays {
    return .{ .allocator = allocator, .limits = limits };
}

pub fn deinit(self: *DecodedArrays) void {
    for (self.outputs.items) |*output| output.words.deinit(self.allocator);
    self.outputs.deinit(self.allocator);
    self.window.deinit(self.allocator);
    if (self.decompressor) |*decompressor| decompressor.deinit();
    self.* = undefined;
}

/// Invalidates results while retaining allocated capacity.
pub fn reset(self: *DecodedArrays) void {
    self.count = 0;
    self.ready = false;
    self.failure = null;
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

/// Decodes every modeled array of a record read with its Base64 text retained (for example
/// from nextRecord or an IndexedReader lookup), replacing earlier results. Order, types,
/// and limits follow nextDecodedRecord; after a failure no results are visible.
pub fn decodeRecord(self: *DecodedArrays, record: model.Record, groups: []const cv.Group) Error!void {
    self.reset();
    errdefer self.reset();
    try self.startRecord(record.node);
    for (record.binaryArrays(), 0..) |node, position| try self.decodeRetained(node, groups, position);
    self.complete();
}

/// Decodes one binary array node with retained text, replacing earlier results, and returns
/// its values; get(0) returns the same array. default_length is the record's defaultArrayLength.
pub fn decodeArray(self: *DecodedArrays, node: model.Node, default_length: ?usize, groups: []const cv.Group) Error!Values {
    self.reset();
    errdefer self.reset();
    self.default_length = default_length;
    try self.decodeRetained(node, groups, 0);
    self.complete();
    return self.get(0).?.values;
}

fn decodeRetained(self: *DecodedArrays, node: model.Node, groups: []const cv.Group, source_position: usize) Error!void {
    try self.beginArray(node, groups, source_position);
    const binary = node.child(.binary) orelse return error.PayloadNotRetained;
    var source = RetainedText{ .text = binary.text orelse return error.PayloadNotRetained };
    try self.decodeText(&source);
}

const RetainedText = struct {
    text: ?[]const u8,

    pub fn next(self: *RetainedText) error{}!?[]const u8 {
        defer self.text = null;
        return self.text;
    }
};

// --- Reader engine entry points ---

pub fn startRecord(self: *DecodedArrays, node: model.Node) Error!void {
    self.default_length = if (node.attribute("defaultArrayLength")) |value| try cv.parseInteger(usize, value) else null;
}

/// Decodes the current array's binary text, pulled from source until its next() returns null.
/// source.next() returns the next logical text fragment, valid until the following call; its
/// errors pass through unchanged and take precedence, as do Base64 errors anywhere in the text
/// over zlib errors, and zlib errors over Numpress errors.
pub fn decodeText(self: *DecodedArrays, source: anytype) !void {
    const pipeline = self.outputs.items[self.count - 1].encoding.pipeline;
    if (pipeline.hasZlib()) return self.decompressText(source);
    while (try source.next()) |bytes| try self.text(bytes);
    return self.finishArray();
}

fn text(self: *DecodedArrays, bytes: []const u8) Error!void {
    errdefer if (self.failure == null) {
        self.failure = .{ .stage = .base64 };
    };
    const pipeline = self.outputs.items[self.count - 1].encoding.pipeline;
    if (pipeline.isNumpress()) return self.numpressText(bytes);
    self.decoder.update(bytes) catch |err|
        return if (err == error.OutputTooSmall) error.DecodedSizeMismatch else err;
}

// Decodes Base64 in pieces whose bytes always fit the window and hands them to Numpress.
fn numpressText(self: *DecodedArrays, bytes: []const u8) Error!void {
    const piece = base64.Decoder.pieceFor(WINDOW);
    var rest = bytes;
    while (rest.len != 0) {
        const part = rest[0..@min(rest.len, piece)];
        try self.decoder.update(part);
        self.feed(self.decoder.take());
        rest = rest[part.len..];
    }
}

fn feed(self: *DecodedArrays, bytes: []const u8) void {
    if (self.deferred != null) return;
    self.values.update(bytes) catch |err| {
        self.deferred = err;
    };
}

pub fn complete(self: *DecodedArrays) void {
    self.ready = true;
}

pub fn beginArray(self: *DecodedArrays, node: model.Node, groups: []const cv.Group, source_position: usize) Error!void {
    errdefer |err| if (self.failure == null) {
        self.failure = .{ .stage = .array, .detail = switch (@as(anyerror, err)) {
            error.MissingValue, error.EmptyValue, error.InvalidValue, error.Overflow => .{ .attribute = .array_length },
            else => .none,
        } };
    };
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
    if (bytes > self.limits.array_bytes) {
        self.failure = .{ .stage = .array, .detail = .{ .limit = .{ .name = .array_bytes, .maximum = self.limits.array_bytes, .needed = bytes } } };
        return error.LimitExceeded;
    }
    try output.words.resize(self.allocator, bytes / 8 + @intFromBool(bytes % 8 != 0));
    const pipeline = array.encoding.pipeline;
    if (pipeline != .none) try self.window.resize(self.allocator, WINDOW);
    if (pipeline.isNumpress()) {
        const transform: numpress.Transform = switch (pipeline.transform()) {
            .linear => .linear,
            .pic => .pic,
            .slof => .slof,
            .none => unreachable,
        };
        self.values = numpress.Decoder.initExact(transform, output.values(f64));
        self.deferred = null;
    }
    self.decoder = base64.Decoder.init(if (pipeline == .none) std.mem.sliceAsBytes(output.words.items)[0..bytes] else self.window.items);
}

fn finishArray(self: *DecodedArrays) Error!void {
    const counts = self.decoder.finish() catch |err| {
        self.failure = .{ .stage = .base64 };
        return err;
    };
    const output = &self.outputs.items[self.count - 1];
    errdefer |err| {
        self.failure = .{ .stage = .array };
        if (err == error.DecodedSizeMismatch and output.encoding.pipeline == .none)
            self.failure.?.detail = .{ .size = .{ .expected = output.byteLength(), .actual = counts.decoded_bytes, .unit = .bytes } };
    }
    if (output.encoding.pipeline.isNumpress()) return self.finishNumpress();
    if (counts.decoded_bytes != output.byteLength()) return error.DecodedSizeMismatch;
    output.toNative();
}

fn finishNumpress(self: *DecodedArrays) Error!void {
    if (self.deferred) |err| return err;
    _ = try self.values.finish();
}

// Inflates a zlib array while its text arrives. The decompressor pulls Base64-decoded bytes from
// the text through a window, and its output goes straight into typed values or to Numpress.
// The error order of decoding each layer whole is kept: after a zlib error the rest of the
// text is still Base64-checked, and its errors and the source's come first.
fn decompressText(self: *DecodedArrays, source: anytype) !void {
    const output = &self.outputs.items[self.count - 1];
    var input = Base64Input(@TypeOf(source)).init(source, self.window.items);
    if (!output.encoding.pipeline.isNumpress()) {
        input.fill();
        if (input.ended and input.failure == null) return self.decompressWhole(output, input.reader.buffered(), input.decoder.counts);
    }
    if (self.decompressor == null) self.decompressor = try zlib.Decompressor.init(self.allocator);
    const decompressor = &self.decompressor.?;
    decompressor.startReader(&input.reader);
    const inflated = self.decompressInto(decompressor, output);
    if (input.failure) |err| return input.fail(self, err);
    input.drain() catch |err| return input.fail(self, err);
    const counts = input.decoder.counts;
    inflated catch |err| {
        // An empty zlib array with no text is valid, as for decoding the payload whole.
        if (output.encoding.payloadPipeline(output.length, counts.significant_bytes == 0) == .none) return;
        self.failure = .{ .stage = .array };
        return err;
    };
    if (output.encoding.pipeline.isNumpress()) {
        errdefer self.failure = .{ .stage = .array };
        return self.finishNumpress();
    }
}

// A primitive zlib payload that fit the window whole: the slice decoder writes straight into
// the values, with the same checks and errors as decoding a retained payload.
fn decompressWhole(self: *DecodedArrays, output: *Output, wire: []const u8, counts: base64.Counts) Error!void {
    errdefer self.failure = .{ .stage = .array };
    const pipeline = output.encoding.payloadPipeline(output.length, counts.significant_bytes == 0);
    switch (output.primitive()) {
        inline else => |kind| {
            const T = switch (kind) {
                .float32 => f32,
                .float64 => f64,
                .int32 => i32,
                .int64 => i64,
            };
            try arrays.decodeWire(T, output.values(T), wire, pipeline, &.{});
        },
    }
}

fn decompressInto(self: *DecodedArrays, decompressor: *zlib.Decompressor, output: *Output) Error!void {
    if (output.encoding.pipeline.isNumpress()) {
        // More than the Numpress bound means the stream holds more than the declared values;
        // never read more than one byte past it, so a zlib error beyond stays unseen.
        const bound = try arrays.wireBound(f64, output.length, output.encoding.pipeline);
        var total: usize = 0;
        while (true) {
            const piece = try decompressor.next(bound - total + 1);
            if (piece.len == 0) return;
            total += piece.len;
            if (total > bound) return error.DecodedSizeMismatch;
            self.feed(piece);
        }
    }
    const bytes = std.mem.sliceAsBytes(output.words.items)[0..output.byteLength()];
    if ((try decompressor.read(bytes)).len != bytes.len) return error.DecodedSizeMismatch;
    var extra: [1]u8 = undefined;
    if ((try decompressor.read(&extra)).len != 0) return error.DecodedSizeMismatch;
    output.toNative();
}

// A reader over binary text that Base64-decodes into a window as the decompressor pulls.
// Source and Base64 errors are kept in failure, since a reader can only report ReadFailed.
fn Base64Input(comptime Source: type) type {
    const SourceError = @typeInfo(@typeInfo(@TypeOf(std.meta.Child(Source).next)).@"fn".return_type.?).error_union.error_set;
    return struct {
        const Self = @This();
        const Failure = SourceError || base64.Error;

        reader: std.Io.Reader,
        source: Source,
        decoder: base64.Decoder,
        pending: []const u8 = &.{},
        ended: bool = false,
        failure: ?Failure = null,
        base64_failed: bool = false,

        const vtable: std.Io.Reader.VTable = .{ .stream = stream };

        fn init(source: Source, window: []u8) Self {
            return .{
                .reader = .{ .vtable = &vtable, .buffer = window, .seek = 0, .end = 0 },
                .source = source,
                .decoder = base64.Decoder.init(&.{}),
            };
        }

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            _ = w;
            _ = limit;
            try @as(*Self, @alignCast(@fieldParentPtr("reader", r))).produce();
            return 0;
        }

        // Moves unread bytes to the window's start and decodes at least one more byte.
        fn produce(self: *Self) error{ EndOfStream, ReadFailed }!void {
            const r = &self.reader;
            if (self.failure != null) return error.ReadFailed;
            if (r.seek != 0) {
                std.mem.copyForwards(u8, r.buffer[0 .. r.end - r.seek], r.buffer[r.seek..r.end]);
                r.end -= r.seek;
                r.seek = 0;
            }
            const before = r.end;
            while (r.end == before) {
                if (self.ended) return error.EndOfStream;
                if (self.pending.len == 0) {
                    const next = self.source.next() catch |err| return self.stop(err, false);
                    self.pending = next orelse {
                        _ = self.decoder.finish() catch |err| return self.stop(err, true);
                        self.ended = true;
                        continue;
                    };
                    continue;
                }
                const room = r.buffer.len - r.end;
                if (room < 6) return;
                const part = self.pending[0..@min(self.pending.len, base64.Decoder.pieceFor(room))];
                self.decoder.output = r.buffer[r.end..];
                self.decoder.taken = self.decoder.counts.decoded_bytes;
                self.decoder.update(part) catch |err| return self.stop(err, true);
                r.end += self.decoder.take().len;
                self.pending = self.pending[part.len..];
            }
        }

        fn stop(self: *Self, err: Failure, from_base64: bool) error{ReadFailed} {
            self.failure = err;
            self.base64_failed = from_base64;
            return error.ReadFailed;
        }

        // Decodes until the window is full, the text ends, or an error is kept.
        fn fill(self: *Self) void {
            const r = &self.reader;
            while (!self.ended and self.failure == null and r.buffer.len - r.end >= 6) self.produce() catch return;
        }

        // Reads and checks the rest of the text, discarding its bytes.
        fn drain(self: *Self) Failure!void {
            while (true) {
                self.reader.seek = self.reader.end;
                self.produce() catch |err| switch (err) {
                    error.EndOfStream => return,
                    error.ReadFailed => return self.failure.?,
                };
            }
        }

        fn fail(self: *const Self, owner: *DecodedArrays, err: Failure) Failure {
            if (self.base64_failed and owner.failure == null) owner.failure = .{ .stage = .base64 };
            return err;
        }
    };
}
const Output = struct {
    words: std.ArrayList(u64) = .empty,
    source_position: usize = 0,
    encoding: model.Encoding = undefined,
    length: usize = 0,

    fn primitive(self: *const Output) model.Primitive {
        return self.encoding.decodedPrimitive();
    }

    // Values arrive as little-endian bytes; big-endian targets swap them in place.
    fn toNative(self: *const Output) void {
        if (comptime @import("builtin").cpu.arch.endian() == .little) return;
        switch (self.primitive()) {
            inline else => |kind| {
                const T = switch (kind) {
                    .float32 => f32,
                    .float64 => f64,
                    .int32 => i32,
                    .int64 => i64,
                };
                const Bits = @Int(.unsigned, @bitSizeOf(T));
                for (std.mem.bytesAsSlice(Bits, std.mem.sliceAsBytes(self.values(T)))) |*bits| bits.* = @byteSwap(bits.*);
            },
        }
    }

    fn byteLength(self: *const Output) usize {
        return switch (self.primitive()) {
            .float32, .int32 => self.length * 4,
            .float64, .int64 => self.length * 8,
        };
    }

    fn values(self: *const Output, comptime T: type) []T {
        return std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(self.words.items))[0..self.length];
    }
};
