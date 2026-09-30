//! Handles independent zlib array streams, decoding with zipir and encoding with Zig's standard library.

const std = @import("std");
const zipir = @import("zipir");

/// Checked stream failures. Partial output is unspecified and never exceeds its buffer.
pub const Error = error{
    InvalidData,
    TruncatedInput,
    ChecksumMismatch,
    TrailingInput,
    UnsupportedDictionary,
    OutputTooSmall,
    OverlappingBuffers,
};

/// Compression effort, not a promise of byte identity with other implementations.
pub const Level = enum { fastest, default, best };

/// Decodes exactly one complete zlib stream into disjoint caller storage.
/// The destination capacity bounds expansion. Checks Adler-32 and rejects concatenation.
pub fn decompress(output: []u8, source: []const u8) Error![]u8 {
    if (overlaps(output, source)) return error.OverlappingBuffers;
    // zipir asserts distinct addresses even for empty slices, which are disjoint here.
    if (source.len == 0) return error.TruncatedInput;
    const destination = if (output.len == 0) @constCast(source[0..0]) else output;
    // The workspace is zipir's decoding tables (7,704 bytes); nothing is allocated.
    var decoder: zipir.zlib.SliceDecoder = .{};
    const length = decoder.decode(source, destination) catch |err| return switch (err) {
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
        => error.InvalidData,
        // Reader errors in zipir's set; a slice source cannot fail a read.
        error.ReadFailed, error.InputBufferTooSmall, error.PeekTooLarge => error.InvalidData,
    };
    return output[0..length];
}

/// Reusable compression storage with one owner. Do not copy a live instance.
/// Calls are independent streams; a failed call does not prevent reuse.
pub const Compressor = struct {
    allocator: std.mem.Allocator,
    state: *std.compress.flate.Compress,
    scratch: []u8,
    level: Level,

    /// Allocates reusable state. Release it with deinit.
    pub fn init(allocator: std.mem.Allocator, level: Level) std.mem.Allocator.Error!Compressor {
        const state = try allocator.create(std.compress.flate.Compress);
        errdefer allocator.destroy(state);
        const scratch = try allocator.alloc(u8, std.compress.flate.max_window_len);
        return .{ .allocator = allocator, .state = state, .scratch = scratch, .level = level };
    }

    /// Releases all compression storage and invalidates this instance.
    pub fn deinit(self: *Compressor) void {
        self.allocator.free(self.scratch);
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    /// Writes one zlib stream without allocating. Source and output must not overlap.
    pub fn compress(self: *Compressor, output: []u8, source: []const u8) Error![]u8 {
        if (overlaps(output, source)) return error.OverlappingBuffers;
        // Flate requires a writer buffer larger than eight bytes even for empty input.
        var small_output: [64]u8 = undefined;
        var destination = std.Io.Writer.fixed(if (output.len <= 8) &small_output else output);
        self.state.* = std.compress.flate.Compress.init(
            &destination,
            self.scratch,
            .zlib,
            switch (self.level) {
                .fastest => .fastest,
                .default => .default,
                .best => .best,
            },
        ) catch return error.OutputTooSmall;
        self.state.writer.writeAll(source) catch return error.OutputTooSmall;
        self.state.finish() catch return error.OutputTooSmall;
        const result = destination.buffered();
        if (result.len > output.len) return error.OutputTooSmall;
        if (output.len <= 8) @memcpy(output[0..result.len], result);
        return output[0..result.len];
    }
};

fn overlaps(output: []u8, source: []const u8) bool {
    if (output.len == 0 or source.len == 0) return false;
    const a = @intFromPtr(output.ptr);
    const b = @intFromPtr(source.ptr);
    return if (a <= b) b - a < output.len else a - b < source.len;
}
