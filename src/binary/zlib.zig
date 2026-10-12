//! Handles independent zlib array streams with zipir. Buffers must be disjoint
//! (`OverlappingBuffers` otherwise); output after a failure is unspecified but stays within its
//! buffer.
//!
//! Decoding has two zipir builds. The build compiles this same file a second time for
//! x86-64-v3 (`kernel_options.as_object`), where the `fast` functions are exported; the module
//! declares them and calls them on CPUs with those features, and runs its own zipir build
//! elsewhere. Only C types cross between the two compilations, so no Zig struct layout is shared.

const std = @import("std");
const zipir = @import("zipir");
const kernel = @import("kernel_options");
const core = @import("core.zig");
const overlaps = core.overlaps;

pub const DecompressError = error{
    InvalidData,
    TruncatedInput,
    ChecksumMismatch,
    TrailingInput,
    UnsupportedDictionary,
    OutputTooSmall,
    OverlappingBuffers,
};
pub const CompressError = error{ OutputTooSmall, OverlappingBuffers };

/// zipir's compression presets, from fastest to smallest output. Compressed bytes may change
/// between zipir versions; they always decode to the same values.
pub const Preset = enum { fast, even, dense };

/// Reusable streaming decompression storage with one owner. Do not copy a live instance: a copy and
/// the original would free the same state on deinit. Each `start` decodes one zlib stream, with the
/// errors of `decompress`, in caller-sized pieces, so no buffer for the whole decoded stream is
/// needed.
pub const Decompressor = struct {
    /// `InvalidState` is a streaming call before `start` or `startReader`.
    pub const Error = DecompressError || error{InvalidState};

    allocator: std.mem.Allocator,
    // The decoder chosen when allocated, kept for every stream.
    state: union(enum) { portable: *zipir.zlib.Decompressor, fast: []align(FAST_STATE_ALIGN) u8 },
    input: std.Io.Reader = undefined,
    source: enum { none, empty, stream } = .none,

    /// Allocates one zipir decompressor, the x86-64-v3 one when it runs here.
    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Decompressor {
        return initWith(allocator, useFast());
    }

    pub fn deinit(self: *Decompressor) void {
        switch (self.state) {
            .portable => |state| self.allocator.destroy(state),
            .fast => |state| self.allocator.free(state),
        }
        self.* = undefined;
    }

    /// Starts decoding source, which stays borrowed until the stream ends or fails.
    pub fn start(self: *Decompressor, source: []const u8) void {
        self.source = if (source.len == 0) .empty else .stream;
        switch (self.state) {
            .portable => |state| {
                self.input = std.Io.Reader.fixed(source);
                state.init(&self.input, .{});
            },
            .fast => |state| if (FAST_LINKED) fast.start(state.ptr, source.ptr, source.len) else unreachable,
        }
    }

    /// Starts decoding a stream pulled from input, which stays borrowed until the stream ends
    /// or fails. A failed read of input is `InvalidData` here; its owner keeps the cause.
    pub fn startReader(self: *Decompressor, input: *std.Io.Reader) void {
        self.source = .stream;
        switch (self.state) {
            .portable => |state| state.init(input, .{}),
            .fast => |state| if (FAST_LINKED) fast.startReader(state.ptr, input, readCallback) else unreachable,
        }
    }

    /// Returns up to limit next decoded bytes from the decompressor's own buffer, valid until the
    /// next call, or null once the stream ended and was checked.
    pub fn next(self: *Decompressor, limit: usize) Error!?[]const u8 {
        try self.check();
        const portable = switch (self.state) {
            .portable => |state| state,
            .fast => |state| if (!FAST_LINKED) unreachable else {
                var bytes: [*]const u8 = undefined;
                var length: usize = 0;
                const code = fast.next(state.ptr, limit, &bytes, &length);
                if (code == .end) return null;
                try fastResult(code);
                return bytes[0..length];
            },
        };
        const reader = &portable.reader;
        const available = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return null,
            error.ReadFailed => return mapped(portable.err orelse error.ReadFailed),
        };
        const length = @min(available.len, limit);
        reader.toss(length);
        return available[0..length];
    }

    /// Fills window with the next decoded bytes and returns them, short only at the end; null
    /// once the stream has ended and its checksum and trailing bytes were checked. An empty
    /// window returns an empty slice.
    pub fn read(self: *Decompressor, window: []u8) Error!?[]u8 {
        try self.check();
        switch (self.state) {
            .portable => |state| {
                const length = state.reader.readSliceShort(window) catch
                    return mapped(state.err orelse error.ReadFailed);
                return if (length == 0 and window.len != 0) null else window[0..length];
            },
            .fast => |state| if (!FAST_LINKED) unreachable else {
                var length: usize = 0;
                try fastResult(fast.read(state.ptr, window.ptr, window.len, &length));
                return if (length == 0 and window.len != 0) null else window[0..length];
            },
        }
    }

    fn initWith(allocator: std.mem.Allocator, use_fast: bool) std.mem.Allocator.Error!Decompressor {
        if (FAST_LINKED and use_fast) return .{ .allocator = allocator, .state = .{
            .fast = try allocator.alignedAlloc(u8, .fromByteUnits(FAST_STATE_ALIGN), fast.stateSize()),
        } };
        return .{ .allocator = allocator, .state = .{ .portable = try allocator.create(zipir.zlib.Decompressor) } };
    }

    fn check(self: *const Decompressor) Error!void {
        return switch (self.source) {
            .none => error.InvalidState,
            .empty => error.TruncatedInput,
            .stream => {},
        };
    }
};

/// Reusable compression storage with one owner. Do not copy a live instance: a copy and the
/// original would free the same state on deinit. Calls are independent streams; a failed call does
/// not prevent reuse.
pub const Compressor = struct {
    /// `InvalidState` is a `finish` without its `start`.
    pub const Error = CompressError || error{InvalidState};

    allocator: std.mem.Allocator,
    state: *zipir.zlib.Compressor,
    preset: Preset,
    destination: std.Io.Writer = undefined,
    // Which start began the open stream; finish needs start's output.
    open: enum { none, output, writer } = .none,

    pub fn init(allocator: std.mem.Allocator, preset: Preset) std.mem.Allocator.Error!Compressor {
        return .{ .allocator = allocator, .state = try allocator.create(zipir.zlib.Compressor), .preset = preset };
    }

    pub fn deinit(self: *Compressor) void {
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    /// Writes one zlib stream without allocating.
    pub fn compress(self: *Compressor, output: []u8, source: []const u8) CompressError![]u8 {
        if (overlaps(output, source)) return error.OverlappingBuffers;
        const writer = try self.start(output);
        writer.writeAll(source) catch {
            self.cancel();
            return error.OutputTooSmall;
        };
        return self.finishOutput();
    }

    /// Starts one zlib stream into output and returns the writer for its source; finish
    /// ends it. A write error on the writer means output is full. output stays borrowed
    /// until finish.
    pub fn start(self: *Compressor, output: []u8) error{OutputTooSmall}!*std.Io.Writer {
        self.destination = std.Io.Writer.fixed(output);
        // zipir's only compression error is a full output writer.
        const writer = self.startWriter(&self.destination) catch return error.OutputTooSmall;
        self.open = .output;
        return writer;
    }

    /// Ends the stream begun by start and returns the written prefix of its output.
    pub fn finish(self: *Compressor) error{ OutputTooSmall, InvalidState }![]u8 {
        if (self.open != .output) return error.InvalidState;
        return self.finishOutput();
    }

    /// Starts one zlib stream into destination, which stays borrowed until `finishWriter`, and
    /// returns the writer for its source. Write errors are destination's.
    pub fn startWriter(self: *Compressor, destination: *std.Io.Writer) std.Io.Writer.Error!*std.Io.Writer {
        self.open = .none;
        try self.state.init(destination, .{ .preset = switch (self.preset) {
            .fast => .fast,
            .even => .even,
            .dense => .dense,
        } });
        self.open = .writer;
        return &self.state.writer;
    }

    /// Abandons the open stream after its source failed; the next start begins a new one.
    pub fn cancel(self: *Compressor) void {
        self.open = .none;
    }

    /// Ends the stream begun by `startWriter`. The stream is closed even when a write fails.
    pub fn finishWriter(self: *Compressor) (std.Io.Writer.Error || error{InvalidState})!void {
        if (self.open == .none) return error.InvalidState;
        self.open = .none;
        _ = try self.state.finish();
    }

    fn finishOutput(self: *Compressor) ![]u8 {
        self.open = .none;
        _ = self.state.finish() catch |err| switch (err) {
            error.WriteFailed => return error.OutputTooSmall,
        };
        return self.destination.buffered();
    }
};

/// Decodes exactly one zlib stream into output, checking its Adler-32. Trailing bytes, such as
/// a second stream, are an error, and expanding past output's capacity is `OutputTooSmall`.
pub fn decompress(output: []u8, source: []const u8) DecompressError![]u8 {
    return decompressWith(useFast(), output, source);
}

/// Returns the largest stream `compress` can write for `source_len` bytes. zipir emits a stored
/// block whenever compression would not be smaller, so output never exceeds the source plus block
/// headers, the zlib header, and the Adler-32 trailer.
pub fn compressBound(source_len: usize) usize {
    return source_len +| source_len / 2048 +| 32;
}

// A fast call's outcome; errors map one to one onto DecompressError.
const FastResult = enum(u8) {
    ok,
    end,
    invalid_data,
    truncated_input,
    checksum_mismatch,
    trailing_input,
    unsupported_dictionary,
    output_too_small,
};

// Fills buffer[0..capacity] from the caller's input: end when exhausted, invalid_data on a
// failed read (its owner keeps the cause).
const ReadFn = *const fn (context: *anyopaque, buffer: [*]u8, capacity: usize, filled: *usize) callconv(.c) FastResult;
const FAST_STATE_ALIGN = 64;

const fast = if (kernel.as_object) struct {
    const INPUT_BUFFER = 32 * 1024;

    const State = struct {
        decompressor: zipir.zlib.Decompressor,
        input: std.Io.Reader,
        context: *anyopaque,
        read: ReadFn,
        failed: bool,
        buffer: [INPUT_BUFFER]u8,

        const callback_vtable: std.Io.Reader.VTable = .{ .stream = streamCallback };

        fn streamCallback(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *State = @alignCast(@fieldParentPtr("input", r));
            const destination = limit.slice(try w.writableSliceGreedy(1));
            var filled: usize = 0;
            switch (self.read(self.context, destination.ptr, destination.len, &filled)) {
                .ok => {
                    w.advance(filled);
                    return filled;
                },
                .end => return error.EndOfStream,
                else => {
                    self.failed = true;
                    return error.ReadFailed;
                },
            }
        }

        fn failure(self: *State) FastResult {
            if (self.failed) return .invalid_data;
            return if (self.decompressor.err) |err| result(err) else .invalid_data;
        }
    };

    fn result(err: zipir.zlib.DecompressError) FastResult {
        return switch (err) {
            error.Truncated => .truncated_input,
            error.BadAdler => .checksum_mismatch,
            error.TrailingData => .trailing_input,
            error.DictionaryUnsupported => .unsupported_dictionary,
            error.OutputLimitExceeded => .output_too_small,
            else => .invalid_data,
        };
    }

    fn decode(source: [*]const u8, source_len: usize, output: [*]u8, output_len: usize, written: *usize) callconv(.c) FastResult {
        var decoder: zipir.zlib.SliceDecoder = .{};
        written.* = decoder.decode(source[0..source_len], output[0..output_len]) catch |err| return result(err);
        return .ok;
    }

    fn stateSize() callconv(.c) usize {
        return @sizeOf(State);
    }

    fn start(state: *anyopaque, source: [*]const u8, source_len: usize) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(state));
        self.input = std.Io.Reader.fixed(source[0..source_len]);
        self.failed = false;
        self.decompressor.init(&self.input, .{});
    }

    fn startReader(state: *anyopaque, context: *anyopaque, read_fn: ReadFn) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(state));
        self.input = .{ .vtable = &State.callback_vtable, .buffer = &self.buffer, .seek = 0, .end = 0 };
        self.context = context;
        self.read = read_fn;
        self.failed = false;
        self.decompressor.init(&self.input, .{});
    }

    fn next(state: *anyopaque, limit: usize, bytes: *[*]const u8, len: *usize) callconv(.c) FastResult {
        const self: *State = @ptrCast(@alignCast(state));
        const reader = &self.decompressor.reader;
        const available = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return .end,
            error.ReadFailed => return self.failure(),
        };
        const length = @min(available.len, limit);
        reader.toss(length);
        bytes.* = available.ptr;
        len.* = length;
        return .ok;
    }

    fn read(state: *anyopaque, window: [*]u8, window_len: usize, len: *usize) callconv(.c) FastResult {
        const self: *State = @ptrCast(@alignCast(state));
        len.* = self.decompressor.reader.readSliceShort(window[0..window_len]) catch return self.failure();
        return .ok;
    }
} else struct {
    const decode = @extern(
        *const fn ([*]const u8, usize, [*]u8, usize, *usize) callconv(.c) FastResult,
        .{ .name = "zmz_zlib_fast_decode" },
    );
    const stateSize = @extern(*const fn () callconv(.c) usize, .{ .name = "zmz_zlib_fast_state_size" });
    const start = @extern(*const fn (*anyopaque, [*]const u8, usize) callconv(.c) void, .{ .name = "zmz_zlib_fast_start" });
    const startReader = @extern(*const fn (*anyopaque, *anyopaque, ReadFn) callconv(.c) void, .{ .name = "zmz_zlib_fast_start_reader" });
    const next = @extern(*const fn (*anyopaque, usize, *[*]const u8, *usize) callconv(.c) FastResult, .{ .name = "zmz_zlib_fast_next" });
    const read = @extern(*const fn (*anyopaque, [*]u8, usize, *usize) callconv(.c) FastResult, .{ .name = "zmz_zlib_fast_read" });
};

comptime {
    if (kernel.as_object) {
        std.debug.assert(@alignOf(fast.State) <= FAST_STATE_ALIGN);
        @export(&fast.decode, .{ .name = "zmz_zlib_fast_decode" });
        @export(&fast.stateSize, .{ .name = "zmz_zlib_fast_state_size" });
        @export(&fast.start, .{ .name = "zmz_zlib_fast_start" });
        @export(&fast.startReader, .{ .name = "zmz_zlib_fast_start_reader" });
        @export(&fast.next, .{ .name = "zmz_zlib_fast_next" });
        @export(&fast.read, .{ .name = "zmz_zlib_fast_read" });
    }
}

// Whether the x86-64-v3 decoder object is linked into this build. Every call into it sits
// behind this constant, so builds without the object never reference its symbols.
const FAST_LINKED = kernel.zlib_fast == .object;

fn useFast() bool {
    return FAST_LINKED and core.hasX86_64V3();
}

fn fastResult(code: FastResult) DecompressError!void {
    return switch (code) {
        .ok, .end => {},
        .invalid_data => error.InvalidData,
        .truncated_input => error.TruncatedInput,
        .checksum_mismatch => error.ChecksumMismatch,
        .trailing_input => error.TrailingInput,
        .unsupported_dictionary => error.UnsupportedDictionary,
        .output_too_small => error.OutputTooSmall,
    };
}

// The fast decoder pulls from a caller's reader through this callback.
fn readCallback(context: *anyopaque, buffer: [*]u8, capacity: usize, filled: *usize) callconv(.c) FastResult {
    const input: *std.Io.Reader = @ptrCast(@alignCast(context));
    filled.* = input.readSliceShort(buffer[0..capacity]) catch return .invalid_data;
    return if (filled.* == 0) .end else .ok;
}

fn decompressWith(use_fast: bool, output: []u8, source: []const u8) DecompressError![]u8 {
    if (overlaps(output, source)) return error.OverlappingBuffers;
    // zipir asserts distinct addresses even for empty slices, which are disjoint here.
    if (source.len == 0) return error.TruncatedInput;
    const destination = if (output.len == 0) @constCast(source[0..0]) else output;
    if (FAST_LINKED and use_fast) {
        var written: usize = 0;
        try fastResult(fast.decode(source.ptr, source.len, destination.ptr, destination.len, &written));
        return output[0..written];
    }
    // zipir's decoding workspace lives on the stack; nothing is allocated.
    var decoder: zipir.zlib.SliceDecoder = .{};
    const length = decoder.decode(source, destination) catch |err| return mapped(err);
    return output[0..length];
}

fn mapped(err: zipir.zlib.DecompressError) DecompressError {
    return switch (err) {
        error.Truncated => error.TruncatedInput,
        error.BadAdler => error.ChecksumMismatch,
        error.TrailingData => error.TrailingInput,
        error.DictionaryUnsupported => error.UnsupportedDictionary,
        error.OutputLimitExceeded => error.OutputTooSmall,
        error.BadHeader,
        error.UnsupportedMethod,
        error.WindowTooLarge,
        error.BadHuffman,
        error.BadSymbol,
        error.BadDistance,
        error.BadStored,
        error.BadBlock,
        // Reader errors are in zipir's set: a failed read of a startReader input is InvalidData
        // here, and a slice source cannot fail one.
        error.ReadFailed,
        error.InputBufferTooSmall,
        error.PeekTooLarge,
        => error.InvalidData,
    };
}

// --- Tests ---

test "[property] - [zlib dispatch]: both decoders give the same bytes and errors on every route" {
    if (comptime kernel.zlib_fast != .object) return error.SkipZigTest;
    if (!core.hasX86_64V3()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7a6c6962);
    const random = prng.random();
    var compressor = try Compressor.init(allocator, .fast);
    defer compressor.deinit();
    var decoders = [2]Decompressor{ try Decompressor.initWith(allocator, false), try Decompressor.initWith(allocator, true) };
    defer for (&decoders) |*decoder| decoder.deinit();
    const plain = try allocator.alloc(u8, 300_000);
    defer allocator.free(plain);
    const stream = try allocator.alloc(u8, compressBound(plain.len) + 1);
    defer allocator.free(stream);
    var outputs: [2][]u8 = undefined;
    for (&outputs) |*output| output.* = try allocator.alloc(u8, plain.len + 16);
    defer for (outputs) |output| allocator.free(output);

    for ([_]usize{ 0, 1, 100, 70_000, 300_000 }) |length| {
        // Runs of repeats and noise, so both literal and match paths decode.
        for (plain[0..length], 0..) |*byte, i| byte.* = if (i % 97 < 40) @truncate(i / 97) else random.int(u8);
        const compressed = try compressor.compress(stream, plain[0..length]);
        const damaged = [_][]const u8{ compressed, compressed[0 .. compressed.len / 2], compressed[0..compressed.len -| 1] };
        for (damaged ++ [_][]const u8{stream[0 .. compressed.len + 1]}, 0..) |source, case| {
            if (case == 3) stream[compressed.len] = 0;
            var results: [2]Decompressor.Error![]u8 = undefined;
            for (&results, outputs, [_]bool{ false, true }) |*result, output, use_fast| result.* = decompressWith(use_fast, output, source);
            try expectSame(results);
            // Streaming from a slice, from 1- and 7-byte reads, by next and by read.
            for ([_]usize{ 0, 1, 7 }) |chunk| {
                var streamed: [2]Decompressor.Error!usize = undefined;
                for (&decoders, &streamed, outputs) |*decoder, *result, output| {
                    var input: std.testing.Reader = .init(output[plain.len..][0..16], &.{.{ .buffer = source }});
                    if (chunk == 0) decoder.start(source) else {
                        input.artificial_limit = .limited(chunk);
                        decoder.startReader(&input.interface);
                    }
                    result.* = drain(decoder, output[0..plain.len], chunk == 7);
                }
                try expectSame(.{
                    if (streamed[0]) |n| outputs[0][0..n] else |err| err,
                    if (streamed[1]) |n| outputs[1][0..n] else |err| err,
                });
            }
        }
    }
    // A corrupted byte inside the stream fails the same way in both.
    const compressed = try compressor.compress(stream, plain[0..70_000]);
    for (0..64) |_| {
        const position = 2 + random.uintLessThan(usize, compressed.len - 6);
        const flip = @as(u8, 1) << random.int(u3);
        compressed[position] ^= flip;
        var results: [2]Decompressor.Error![]u8 = undefined;
        for (&results, outputs, [_]bool{ false, true }) |*result, output, use_fast| result.* = decompressWith(use_fast, output, compressed);
        try expectSame(results);
        compressed[position] ^= flip;
    }
}

fn drain(decoder: *Decompressor, output: []u8, by_read: bool) Decompressor.Error!usize {
    var length: usize = 0;
    while (true) {
        if (by_read) {
            const piece = try decoder.read(output[length..@min(output.len, length + 4096)]) orelse return length;
            if (piece.len == 0) return length;
            length += piece.len;
        } else {
            const piece = try decoder.next(5000) orelse return length;
            @memcpy(output[length..][0..piece.len], piece);
            length += piece.len;
        }
    }
}

fn expectSame(results: [2]Decompressor.Error![]u8) !void {
    const portable = results[0] catch |err| return std.testing.expectError(err, results[1]);
    try std.testing.expectEqualSlices(u8, portable, try results[1]);
}
