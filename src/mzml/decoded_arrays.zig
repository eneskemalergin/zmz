//! Stores decoded arrays from decoded reads (`nextDecodedRecord`, `nextDecodedItem`, `byIdDecoded`,
//! `atDecoded`), from records whose Base64 text was retained (`decodeRecord`, `decodeArray`), and
//! from text read as events (`decodeArrayText`).
//!
//! Each array keeps its source primitive; Numpress output is f64 unless `numpress_precision` is
//! `.declared`, which keeps a declared 32-bit float. Numeric buffers grow as needed and are reused
//! between records. Every array decodes as its text arrives: Base64 goes straight into typed
//! output, into a fixed window for Numpress, or, with zlib, through a window that the decompressor
//! pulls from. No buffer holds a payload whole. Selected results stay in source order;
//! `source_position` indexes `record.binaryArrays()`, and is 0 for `decodeArray` and
//! `decodeArrayText`. Results become visible only after the complete record succeeds. Returned
//! slices last until the next decoded read using this owner, reset, or deinit; ordinary reads do
//! not invalidate them. No source metadata is borrowed by this owner. Do not copy an owner: a copy
//! shares its buffers, and both `deinit`s would free them.
//!
//! While a read decodes into this owner, as from one of its selection callbacks, the decode
//! calls return `InvalidState` and `reset` does nothing.
//!
//! `beginArray`, `decodeText`, `complete`, and the `busy` and `failure` fields are internal: the
//! reader engine and `IndexedReader` use them while they parse a record. Callers use the reads and
//! the decode functions.

const std = @import("std");
const cv = @import("../cv/source.zig");
const arrays = @import("../binary/arrays.zig");
const base64 = @import("../binary/base64.zig");
const numpress = @import("../binary/numpress.zig");
const zlib = @import("../binary/zlib.zig");
const overlaps = @import("../binary/core.zig").overlaps;
const model = @import("model.zig");
const Diagnostic = @import("diagnostic.zig");

const DecodedArrays = @This();

pub const Error = model.EncodingError || cv.ValueError || arrays.DecodeError || std.mem.Allocator.Error ||
    base64.Decoder.Error || numpress.Decoder.Error || zlib.Decompressor.Error ||
    error{ LimitExceeded, InvalidState, MissingAttribute, PayloadNotRetained };
pub const Values = arrays.Values;
/// One decoded array: its position among the record's arrays, its declared encoding, its role
/// (null when decoded from text without its node), and its values.
pub const Array = struct { source_position: usize, encoding: model.Encoding, role: ?model.ArrayRole, values: Values };

pub const Options = struct {
    /// Bounds each array's decoded typed bytes, allocated from its declared length. The reader's
    /// `binary_text_bytes` bounds the Base64 text.
    array_bytes: usize = 192 * 1024 * 1024,
    /// Bounds the decoded typed bytes of all of a record's arrays together, so the memory one
    /// record takes does not grow with its array count.
    record_array_bytes: usize = 512 * 1024 * 1024,
    /// Numpress decodes to f64. `declared` returns arrays declared 32-bit float as f32, rounded
    /// to the nearest (as pyteomics and pyOpenMS do); integer declarations stay f64.
    numpress_precision: enum { decoded, declared } = .decoded,
};

allocator: std.mem.Allocator,
options: Options,
outputs: std.ArrayList(Output) = .empty,
window: std.ArrayList(u8) = .empty,
decompressor: ?zlib.Decompressor = null,
count: usize = 0,
ready: bool = false,
decoder: base64.Decoder = undefined,
values: numpress.Decoder = undefined,
// The first Numpress error of the current array. It is reported only after the Base64 and
// zlib layers finish, so their errors come first, as when each layer decodes the whole payload.
deferred: ?numpress.Decoder.Error = null,
failure: ?struct { stage: Diagnostic.Stage, detail: Diagnostic.Detail = .none } = null,
// The failure of the last decodeRecord, decodeArray, or decodeArrayText; reset keeps it.
report: ?Diagnostic = null,
// Source position of the array those calls are decoding, for the report.
position: usize = 0,
// A read decodes into this owner; a selection callback must not reset or reuse it meanwhile.
busy: bool = false,

pub fn init(allocator: std.mem.Allocator, options: Options) DecodedArrays {
    return .{ .allocator = allocator, .options = options };
}

pub fn deinit(self: *DecodedArrays) void {
    for (self.outputs.items) |*output| output.words.deinit(self.allocator);
    self.outputs.deinit(self.allocator);
    self.window.deinit(self.allocator);
    if (self.decompressor) |*decompressor| decompressor.deinit();
    self.* = undefined;
}

/// Invalidates results while retaining allocated capacity. Does nothing while a read decodes
/// into this owner, as from one of its selection callbacks.
pub fn reset(self: *DecodedArrays) void {
    if (self.busy) return;
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
        .role = output.role,
        .values = switch (output.primitive()) {
            inline else => |kind| .of(kind.Type(), output.values(kind.Type())),
        },
    };
}

/// Decodes every modeled array of a record read with its Base64 text retained (for example
/// from `nextRecord` or an `IndexedReader` lookup), replacing earlier results. Order, types,
/// and limits follow `nextDecodedRecord`; after a failure no results are visible.
pub fn decodeRecord(self: *DecodedArrays, record: model.Record, groups: []const cv.Group) Error!void {
    return self.decodeNodes(record.binaryArrays(), record.default_array_length, groups);
}

/// Decodes one binary array node with retained text, replacing earlier results, and returns
/// its values; `get(0)` returns the same array. `default_length` is the record's
/// `defaultArrayLength`.
pub fn decodeArray(self: *DecodedArrays, node: model.Node, default_length: ?usize, groups: []const cv.Group) Error!Values {
    try self.decodeNodes(&.{node}, default_length, groups);
    return self.get(0).?.values;
}

/// Decodes one array whose Base64 text arrives in pieces from source, given its encoding and
/// value count, for callers that read the document as events: classify the array's terms with
/// `model.encodingTerm` and pass a pointer to a source whose `next()` returns the array's text
/// runs (for example `Events` text events) and then null. Same decoding, error order, and
/// limits as the readers; replaces earlier results, and after a failure none are visible.
/// Returns `Error` plus the source's own errors. After a failure the source may stop before
/// its null; read on to the element's end event.
pub fn decodeArrayText(self: *DecodedArrays, encoding: model.Encoding, length: usize, source: anytype) !Values {
    if (self.busy) return error.InvalidState;
    self.report = null;
    self.reset();
    errdefer self.reset();
    self.busy = true;
    defer self.busy = false;
    errdefer |err| self.keepReport(err);
    self.position = 0;
    try self.beginArrayWith(encoding, length, 0);
    try self.decodeText(source);
    self.complete();
    return self.get(0).?.values;
}

/// Returns the failure of the last `decodeRecord`, `decodeArray`, or `decodeArrayText` call, with
/// its stage, the failing array's position, and size or limit detail; null after a success.
/// Decoding while reading reports through the reader's `diagnostic()` instead.
pub fn diagnostic(self: *const DecodedArrays) ?Diagnostic {
    return self.report;
}

pub fn beginArray(
    self: *DecodedArrays,
    node: model.Node,
    default_length: ?usize,
    groups: []const cv.Group,
    source_position: usize,
) Error!void {
    errdefer |err| if (self.failure == null) {
        self.failure = .{ .stage = .array, .detail = switch (@as(anyerror, err)) {
            error.MissingAttribute, error.EmptyValue, error.InvalidValue, error.Overflow => .{ .attribute = .array_length },
            else => .none,
        } };
    };
    const array = try model.BinaryArray.init(node, default_length, groups);
    try self.beginArrayWith(array.encoding, array.length, source_position);
    self.outputs.items[self.count - 1].role = try model.arrayRole(node, groups);
}

// source.next() returns the next logical text fragment, valid until the following call, and null
// at the end; its errors pass through unchanged and take precedence, as do Base64 errors anywhere
// in the text over zlib errors, and zlib errors over Numpress errors.
pub fn decodeText(self: *DecodedArrays, source: anytype) !void {
    if (self.count == 0) return error.InvalidState;
    const output = &self.outputs.items[self.count - 1];
    if (output.encoding.pipeline.hasZlib()) try self.decompressText(source) else {
        while (try source.next()) |bytes| try self.text(bytes);
        try self.finishArray();
    }
    if (self.options.numpress_precision == .declared and output.encoding.pipeline.isNumpress() and output.encoding.primitive == .float32) {
        // Each f32 lands inside f64 values already read, so narrowing in place is safe.
        const wide = output.values(f64);
        const narrow = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(output.words.items))[0..output.length];
        for (narrow, 0..) |*value, i| value.* = @floatCast(wide[i]);
        output.narrowed = true;
        output.bytes = output.length * @sizeOf(f32);
    }
}

pub fn complete(self: *DecodedArrays) void {
    self.ready = true;
}

// Bytes decoded per step: Numpress input from Base64, or Base64 output for the decompressor. A
// zlib payload that fits whole (most spectra) is decoded in one call, straight into its values.
const WINDOW = 64 * 1024;

fn decodeNodes(self: *DecodedArrays, nodes: []const model.Node, default_length: ?usize, groups: []const cv.Group) Error!void {
    if (self.busy) return error.InvalidState;
    self.report = null;
    self.reset();
    errdefer self.reset();
    self.busy = true;
    defer self.busy = false;
    errdefer |err| self.keepReport(err);
    for (nodes, 0..) |node, position| try self.decodeRetained(node, default_length, groups, position);
    self.complete();
}

// Runs before the failed call's reset clears failure and the array count.
fn keepReport(self: *DecodedArrays, err: anyerror) void {
    const stage: Diagnostic.Stage = if (self.failure) |failure| failure.stage else .array;
    const detail: Diagnostic.Detail = if (self.failure) |failure| failure.detail else .none;
    var report = Diagnostic.initAny(err, .decode_array, stage, detail);
    report.element = .binary_data_array;
    report.array_position = self.position;
    self.report = report;
}

fn decodeRetained(
    self: *DecodedArrays,
    node: model.Node,
    default_length: ?usize,
    groups: []const cv.Group,
    source_position: usize,
) Error!void {
    self.position = source_position;
    const retained = if (node.child(.binary)) |binary| binary.text else null;
    // Text kept in this owner's storage would be freed or overwritten as arrays are sized.
    if (retained) |bytes| {
        if (overlaps(self.window.allocatedSlice(), bytes)) return error.OverlappingBuffers;
        for (self.outputs.items) |output| {
            if (overlaps(std.mem.sliceAsBytes(output.words.allocatedSlice()), bytes)) return error.OverlappingBuffers;
        }
    }
    try self.beginArray(node, default_length, groups, source_position);
    var source = RetainedText{ .text = retained orelse return error.PayloadNotRetained };
    try self.decodeText(&source);
}

const RetainedText = struct {
    text: ?[]const u8,

    pub fn next(self: *RetainedText) error{}!?[]const u8 {
        defer self.text = null;
        return self.text;
    }
};

fn text(self: *DecodedArrays, bytes: []const u8) Error!void {
    errdefer if (self.failure == null) {
        self.failure = .{ .stage = .base64 };
    };
    const pipeline = self.outputs.items[self.count - 1].encoding.pipeline;
    if (pipeline.isNumpress()) return self.numpressText(bytes);
    self.decoder.update(bytes) catch |err| {
        if (err != error.OutputTooSmall) return err;
        // An overlong array is an array error, as a short one is in finishArray.
        self.failure = .{ .stage = .array };
        return error.DecodedSizeMismatch;
    };
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

fn beginArrayWith(self: *DecodedArrays, encoding: model.Encoding, length: usize, source_position: usize) Error!void {
    errdefer if (self.failure == null) {
        self.failure = .{ .stage = .array };
    };
    if (self.count == self.outputs.items.len) try self.outputs.append(self.allocator, .{});
    const output = &self.outputs.items[self.count];
    self.count += 1;
    output.source_position = source_position;
    output.encoding = encoding;
    output.role = null;
    output.narrowed = false;
    // Set once the words are sized, so a failure here exposes no values.
    output.length = 0;
    output.bytes = 0;
    const bytes = std.math.mul(usize, length, output.primitive().size()) catch return error.LengthOverflow;
    if (bytes > self.options.array_bytes) {
        self.failure = .{
            .stage = .array,
            .detail = .{ .limit = .{ .name = .array_bytes, .maximum = self.options.array_bytes, .needed = bytes } },
        };
        return error.LimitExceeded;
    }
    var record_bytes = bytes;
    for (self.outputs.items[0 .. self.count - 1]) |previous| record_bytes +|= previous.bytes;
    if (record_bytes > self.options.record_array_bytes) {
        self.failure = .{
            .stage = .array,
            .detail = .{ .limit = .{ .name = .record_array_bytes, .maximum = self.options.record_array_bytes, .needed = record_bytes } },
        };
        return error.LimitExceeded;
    }
    try output.words.resize(self.allocator, bytes / 8 + @intFromBool(bytes % 8 != 0));
    output.length = length;
    output.bytes = bytes;
    const pipeline = encoding.pipeline;
    if (pipeline != .none) try self.window.resize(self.allocator, WINDOW);
    if (pipeline.transform()) |transform| {
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
            self.failure.?.detail = .{ .size = .{ .expected = output.bytes, .actual = counts.decoded_bytes, .unit = .bytes } };
    }
    if (output.encoding.pipeline.isNumpress()) return self.finishNumpress();
    if (counts.decoded_bytes != output.bytes) return error.DecodedSizeMismatch;
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
        if (input.failure) |err| return input.fail(self, err);
        if (input.ended) return self.decompressWhole(output, input.reader.buffered(), input.decoder.counts);
    }
    if (self.decompressor == null) self.decompressor = try zlib.Decompressor.init(self.allocator);
    const decompressor = &self.decompressor.?;
    decompressor.startReader(&input.reader);
    var short: ?usize = null;
    const inflated = self.decompressInto(decompressor, output, &short);
    if (input.failure) |err| return input.fail(self, err);
    input.drain() catch |err| return input.fail(self, err);
    inflated catch |err| {
        self.failure = .{ .stage = .array, .detail = output.shortDetail(short) };
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
    const pipeline = output.encoding.payloadPipeline(output.length, counts.significant_bytes == 0);
    switch (output.primitive()) {
        inline else => |kind| arrays.decodeWire(kind.Type(), output.values(kind.Type()), wire, pipeline, &.{}) catch |err| {
            // Only on this error path: inflate again for the length of a stream that ended short.
            const bytes = std.mem.sliceAsBytes(output.words.items)[0..output.bytes];
            const short = if (err == error.DecodedSizeMismatch and pipeline == .zlib)
                if (zlib.decompress(bytes, wire)) |inflated| inflated.len else |_| null
            else
                null;
            self.failure = .{ .stage = .array, .detail = output.shortDetail(short) };
            return err;
        },
    }
}

// short receives the decoded length of a primitive stream that ended before the values did.
fn decompressInto(self: *DecodedArrays, decompressor: *zlib.Decompressor, output: *Output, short: *?usize) Error!void {
    if (output.encoding.pipeline.isNumpress()) {
        // More than the Numpress bound means the stream holds more than the declared values;
        // never read more than one byte past it, so a zlib error beyond stays unseen.
        const bound = try arrays.wireBound(f64, output.length, output.encoding.pipeline);
        var total: usize = 0;
        while (true) {
            const piece = try decompressor.next(bound - total + 1) orelse return;
            total += piece.len;
            if (total > bound) return error.DecodedSizeMismatch;
            self.feed(piece);
        }
    }
    const bytes = std.mem.sliceAsBytes(output.words.items)[0..output.bytes];
    const length = if (try decompressor.read(bytes)) |piece| piece.len else 0;
    if (length != bytes.len) {
        short.* = length;
        return error.DecodedSizeMismatch;
    }
    var extra: [1]u8 = undefined;
    if (try decompressor.read(&extra) != null) return error.DecodedSizeMismatch;
}

// A reader over binary text that Base64-decodes into a window as the decompressor pulls.
// Source and Base64 errors are kept in failure, since a reader can only report ReadFailed.
fn Base64Input(comptime Source: type) type {
    const SourceError = @typeInfo(@typeInfo(@TypeOf(std.meta.Child(Source).next)).@"fn".return_type.?).error_union.error_set;
    return struct {
        const Self = @This();
        const Failure = SourceError || base64.Decoder.Error;

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
                self.decoder.retarget(r.buffer[r.end..]);
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
    role: ?model.ArrayRole = null,
    // Numpress values narrowed to the declared f32.
    narrowed: bool = false,
    length: usize = 0,
    // length times the primitive's size, set once its words are allocated.
    bytes: usize = 0,

    // The size detail of an array whose stream decoded to short bytes, when that is known.
    fn shortDetail(self: *const Output, short: ?usize) Diagnostic.Detail {
        const actual = short orelse return .none;
        return .{ .size = .{ .expected = self.bytes, .actual = actual, .unit = .bytes } };
    }

    fn primitive(self: *const Output) model.Primitive {
        return if (self.narrowed) .float32 else self.encoding.decodedPrimitive();
    }

    fn values(self: *const Output, comptime T: type) []T {
        return std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(self.words.items))[0..self.length];
    }
};

// --- Tests ---

test "[failure] - [mzML decoded arrays]: refuses text before its array and leaves a limit-stopped array empty" {
    const int32 = cv.Entry{ .cv = .{ .accession = .{ .raw = "MS:1000519" }, .name = "32-bit integer" } };
    const plain = cv.Entry{ .cv = .{ .accession = .{ .raw = "MS:1000576" }, .name = "no compression" } };
    const node: model.Node = .{
        .kind = .binary_data_array,
        .params = &.{ int32, plain },
        .children = &.{.{ .kind = .binary, .text = "QUFBQUFBQUE=" }},
    };
    const Empty = struct {
        fn next(_: *@This()) error{}!?[]const u8 {
            return null;
        }
    };
    var output = DecodedArrays.init(std.testing.allocator, .{ .array_bytes = 64 });
    defer output.deinit();
    var empty: Empty = .{};
    try std.testing.expectError(error.InvalidState, output.decodeText(&empty));
    try std.testing.expectError(error.LimitExceeded, output.beginArray(node, 1000, &.{}, 0));
    output.complete();
    try std.testing.expectEqual(@as(usize, 0), output.get(0).?.values.int32.len);
}
