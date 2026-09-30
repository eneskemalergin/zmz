//! Handles independent zlib array streams with zipir. Buffers must be disjoint.

const std = @import("std");
const zipir = @import("zipir");
const overlaps = @import("core.zig").overlaps;

/// Output after a failure is unspecified but stays within its buffer.
pub const Error = error{
    InvalidData,
    TruncatedInput,
    ChecksumMismatch,
    TrailingInput,
    UnsupportedDictionary,
    OutputTooSmall,
    OverlappingBuffers,
};

/// zipir's compression presets, from fastest to smallest output. Compressed bytes may change
/// between zipir versions; they always decode to the same values.
pub const Preset = enum { fast, even, dense };

/// Decodes exactly one zlib stream into output, checking its Adler-32. Trailing bytes, such as
/// a second stream, are an error, and expanding past output's capacity is OutputTooSmall.
pub fn decompress(output: []u8, source: []const u8) Error![]u8 {
    if (overlaps(output, source)) return error.OverlappingBuffers;
    // zipir asserts distinct addresses even for empty slices, which are disjoint here.
    if (source.len == 0) return error.TruncatedInput;
    const destination = if (output.len == 0) @constCast(source[0..0]) else output;
    // zipir's decoding workspace lives on the stack; nothing is allocated.
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
        // Reader errors are in zipir's set, but a slice source cannot fail a read.
        error.ReadFailed,
        error.InputBufferTooSmall,
        error.PeekTooLarge,
        => error.InvalidData,
    };
    return output[0..length];
}

/// Largest stream compress can write for source_len bytes. zipir emits a stored block
/// whenever compression would not be smaller, so output never exceeds the source plus
/// block headers, the zlib header, and the Adler-32 trailer.
pub fn compressBound(source_len: usize) usize {
    return source_len +| source_len / 2048 +| 32;
}

/// Reusable compression storage with one owner. Do not copy a live instance.
/// Calls are independent streams; a failed call does not prevent reuse.
pub const Compressor = struct {
    allocator: std.mem.Allocator,
    state: *zipir.zlib.Compressor,
    preset: Preset,

    /// Allocates one zipir compressor.
    pub fn init(allocator: std.mem.Allocator, preset: Preset) std.mem.Allocator.Error!Compressor {
        return .{ .allocator = allocator, .state = try allocator.create(zipir.zlib.Compressor), .preset = preset };
    }

    pub fn deinit(self: *Compressor) void {
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    /// Writes one zlib stream without allocating.
    pub fn compress(self: *Compressor, output: []u8, source: []const u8) Error![]u8 {
        if (overlaps(output, source)) return error.OverlappingBuffers;
        // zipir's only compression error is a full output writer.
        var destination = std.Io.Writer.fixed(output);
        self.state.init(&destination, .{ .preset = switch (self.preset) {
            .fast => .fast,
            .even => .even,
            .dense => .dense,
        } }) catch return error.OutputTooSmall;
        self.state.writer.writeAll(source) catch return error.OutputTooSmall;
        _ = self.state.finish() catch return error.OutputTooSmall;
        return destination.buffered();
    }
};
