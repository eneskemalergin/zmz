//! Encodes and decodes padded Base64 in caller-owned buffers without allocating. Input and
//! output must be disjoint, and output after a failure is unspecified. On x86-64, AVX2 is used
//! when available and touches nothing outside the given slices.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("base64_options");
const core = @import("core.zig");
const overlaps = core.overlaps;
// Zig's self-hosted x86 backend cannot assemble vector memory operands yet.
const USE_AVX2 = builtin.cpu.arch == .x86_64 and options.simd and builtin.zig_backend == .stage2_llvm;

pub const Error = error{
    InvalidCharacter,
    InvalidPadding,
    NonCanonicalTail,
    TruncatedInput,
    OutputTooSmall,
    LengthOverflow,
    OverlappingBuffers,
    AlreadyFinished,
    FailedState,
};

/// Successful input and output counts; significant bytes include padding.
pub const Counts = struct {
    text_bytes: usize = 0,
    significant_bytes: usize = 0,
    decoded_bytes: usize = 0,
};

/// Returns the padded encoded length with checked arithmetic.
pub fn encodedSize(source_len: usize) Error!usize {
    const groups = source_len / 3 + @intFromBool(source_len % 3 != 0);
    return std.math.mul(usize, groups, 4) catch error.LengthOverflow;
}

/// Writes canonical padded Base64.
pub fn encode(output: []u8, source: []const u8) Error![]u8 {
    if (overlaps(output, source)) return error.OverlappingBuffers;
    const required = try encodedSize(source.len);
    if (output.len < required) return error.OutputTooSmall;
    encodeInto(output[0..required], source);
    return output[0..required];
}

/// Decodes XML text, allowing XML whitespace between Base64 characters. Decoding past output's
/// capacity fails with OutputTooSmall.
pub fn decode(output: []u8, source: []const u8) Error!Counts {
    var decoder = Decoder.init(output);
    try decoder.update(source);
    return decoder.finish();
}

/// Decodes XML text given in fragments into a borrowed output, keeping at most one incomplete
/// quartet between updates; fragments are borrowed only during update. Failures are sticky,
/// and counts and output are valid only after finish succeeds.
///
/// `take` hands out the bytes decoded since the last take and reuses output from its start,
/// so a window that holds one update's bytes replaces a buffer for the whole payload.
pub const Decoder = struct {
    output: []u8,
    counts: Counts = .{},
    // Decoded bytes already handed out by take; output index = decoded_bytes - taken.
    taken: usize = 0,
    quartet: [4]u8 = undefined,
    quartet_len: u3 = 0,
    padded: bool = false,
    finished: bool = false,
    failed: bool = false,
    /// Offset in concatenated logical text, not the physical XML source.
    error_offset: ?usize = null,

    pub fn init(output: []u8) Decoder {
        return .{ .output = output };
    }

    /// Consumes one text fragment. Empty fragments are valid before finish.
    pub noinline fn update(self: *Decoder, text: []const u8) Error!void {
        if (self.failed) return error.FailedState;
        if (self.finished) return error.AlreadyFinished;
        errdefer self.failed = true;
        if (overlaps(self.output, text)) return error.OverlappingBuffers;
        if (text.len > std.math.maxInt(usize) - self.counts.text_bytes) return error.LengthOverflow;
        return self.updateParts(text);
    }

    fn updateParts(self: *Decoder, text: []const u8) Error!void {
        var index: usize = 0;
        while (index < text.len) {
            const consumed = self.decodeRun(text[index..]);
            if (consumed != 0) {
                index += consumed;
                continue;
            }
            const byte = text[index];
            index += 1;
            const offset = self.counts.text_bytes;
            self.counts.text_bytes += 1;
            if (isWhitespace(byte)) continue;
            self.error_offset = offset;
            if (self.padded) return error.InvalidPadding;
            if (byte != '=' and alphabet(byte) == null) return error.InvalidCharacter;
            self.counts.significant_bytes += 1;
            self.quartet[self.quartet_len] = byte;
            self.quartet_len += 1;
            if (self.quartet_len == 4) try self.flushQuartet();
        }
        self.error_offset = null;
    }

    fn decodeRun(self: *Decoder, text: []const u8) usize {
        if (self.quartet_len != 0 or self.padded or text.len < 4) return 0;
        const output = self.output[self.counts.decoded_bytes - self.taken ..];
        const capacity = output.len;
        const input = text;
        const has_tail = input.len >= 4 and input.len % 4 == 0 and input[input.len - 1] == '=';
        const plain_length = input.len - @as(usize, if (has_tail) 4 else 0);
        var length = decodePrefix(output[0..capacity], input[0..plain_length]);
        var decoded = length / 4 * 3;
        if (has_tail and length == plain_length) tail: {
            const group = decodeQuartet(input[length..][0..4].*) catch break :tail;
            if (group.len > capacity - decoded) break :tail;
            inline for (0..3) |i| {
                if (i < group.len) output[decoded + i] = group.bytes[i];
            }
            length += 4;
            decoded += group.len;
            self.padded = true;
        }
        self.counts.text_bytes += length;
        self.counts.significant_bytes += length;
        self.counts.decoded_bytes += decoded;
        return length;
    }

    /// Returns the bytes decoded since the last take; the next update writes from output's
    /// start again. The slice is valid until the next update.
    pub fn take(self: *Decoder) []u8 {
        const n = self.counts.decoded_bytes - self.taken;
        self.taken = self.counts.decoded_bytes;
        return self.output[0..n];
    }

    /// Text characters per update that always fit a window of `window` bytes with take: 3
    /// bytes per 4 characters, plus the bytes of a quartet left from the previous update.
    pub fn pieceFor(window: usize) usize {
        return (window - 3) / 3 * 4;
    }

    /// Checks the final quartet and returns the counts; call it once.
    pub fn finish(self: *Decoder) Error!Counts {
        if (self.failed) return error.FailedState;
        if (self.finished) return error.AlreadyFinished;
        errdefer self.failed = true;
        if (self.quartet_len != 0) {
            self.error_offset = self.counts.text_bytes;
            return error.TruncatedInput;
        }
        self.finished = true;
        return self.counts;
    }

    fn flushQuartet(self: *Decoder) Error!void {
        const group = try decodeQuartet(self.quartet);
        const end = std.math.add(usize, self.counts.decoded_bytes, group.len) catch
            return error.LengthOverflow;
        if (end - self.taken > self.output.len) return error.OutputTooSmall;
        inline for (0..3) |i| {
            if (i < group.len) self.output[self.counts.decoded_bytes - self.taken + i] = group.bytes[i];
        }
        self.counts.decoded_bytes = end;
        self.quartet_len = 0;
        self.padded = group.len != 3;
    }
};

// --- Scalar groups ---

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const ENCODE_PAIRS: [4096]u16 = blk: {
    @setEvalBranchQuota(10000);
    var table: [4096]u16 = undefined;
    for (&table, 0..) |*pair, index|
        pair.* = @as(u16, ALPHABET[index >> 6]) | (@as(u16, ALPHABET[index & 63]) << 8);
    break :blk table;
};
const DECODE_TABLE: [256]u8 = blk: {
    var table = [_]u8{0xff} ** 256;
    for (ALPHABET, 0..) |byte, index| table[byte] = @intCast(index);
    break :blk table;
};
const DECODE_WORDS: [4][256]u32 = blk: {
    @setEvalBranchQuota(4000);
    var table = [_][256]u32{[_]u32{0x01000000} ** 256} ** 4;
    for (ALPHABET, 0..) |byte, index| {
        const value: u32 = @intCast(index);
        table[0][byte] = value << 2;
        table[1][byte] = (value >> 4) | ((value & 15) << 12);
        table[2][byte] = ((value >> 2) << 8) | ((value & 3) << 22);
        table[3][byte] = value << 16;
    }
    break :blk table;
};

fn encodeInto(output: []u8, source: []const u8) void {
    var position: usize = 0;
    var written: usize = 0;
    if (comptime USE_AVX2) {
        if (source.len >= 32 and core.hasAvx2()) {
            position = encodeAvx2(source, output);
            written = position / 3 * 4;
        }
    }
    if (source.len - position >= 32) {
        while (source.len - position >= 3) {
            const bits = std.mem.readInt(u24, source[position..][0..3], .big);
            std.mem.writeInt(u16, output[written..][0..2], ENCODE_PAIRS[bits >> 12], .little);
            std.mem.writeInt(u16, output[written + 2 ..][0..2], ENCODE_PAIRS[bits & 4095], .little);
            position += 3;
            written += 4;
        }
    }
    while (source.len - position >= 3) {
        encodeTriple(output[written..][0..4], source[position..][0..3]);
        position += 3;
        written += 4;
    }
    const remaining = source.len - position;
    if (remaining == 0) return;
    const first = source[position];
    output[written] = ALPHABET[first >> 2];
    if (remaining == 1) {
        output[written + 1] = ALPHABET[(first & 3) << 4];
        output[written + 2] = '=';
    } else {
        const second = source[position + 1];
        output[written + 1] = ALPHABET[(first & 3) << 4 | second >> 4];
        output[written + 2] = ALPHABET[(second & 15) << 2];
    }
    output[written + 3] = '=';
}

fn encodeTriple(output: *[4]u8, source: *const [3]u8) void {
    output[0] = ALPHABET[source[0] >> 2];
    output[1] = ALPHABET[(source[0] & 3) << 4 | source[1] >> 4];
    output[2] = ALPHABET[(source[1] & 15) << 2 | source[2] >> 6];
    output[3] = ALPHABET[source[2] & 63];
}

fn decodePrefix(output: []u8, source: []const u8) usize {
    const length = @min(source.len / 4, output.len / 3) * 4;
    var position: usize = 0;
    if (comptime USE_AVX2) {
        if (length >= 32 and core.hasAvx2()) position = decodeAvx2(source[0..length], output);
    }
    if (length - position >= 32) {
        while (position < length) : (position += 4) {
            const group = source[position..][0..4];
            const bits = DECODE_WORDS[0][group[0]] | DECODE_WORDS[1][group[1]] |
                DECODE_WORDS[2][group[2]] | DECODE_WORDS[3][group[3]];
            if (bits & 0x01000000 != 0) break;
            std.mem.writeInt(u24, output[position / 4 * 3 ..][0..3], @truncate(bits), .little);
        }
    } else {
        while (position < length) : (position += 4) {
            const group = source[position..][0..4];
            const a = DECODE_TABLE[group[0]];
            const b = DECODE_TABLE[group[1]];
            const c = DECODE_TABLE[group[2]];
            const d = DECODE_TABLE[group[3]];
            if ((a | b | c | d) & 0x80 != 0) break;
            const destination = output[position / 4 * 3 ..][0..3];
            destination[0] = a << 2 | b >> 4;
            destination[1] = b << 4 | c >> 2;
            destination[2] = c << 6 | d;
        }
    }
    return position;
}

inline fn decodeQuartet(q: [4]u8) Error!struct { bytes: [3]u8, len: usize } {
    const a = DECODE_TABLE[q[0]];
    if (a == 0xff) return error.InvalidPadding;
    const b = DECODE_TABLE[q[1]];
    if (b == 0xff) return error.InvalidPadding;
    var bytes: [3]u8 = undefined;
    bytes[0] = a << 2 | b >> 4;
    if (q[2] == '=') {
        if (q[3] != '=') return error.InvalidPadding;
        if (b & 15 != 0) return error.NonCanonicalTail;
        return .{ .bytes = bytes, .len = 1 };
    }
    const c = DECODE_TABLE[q[2]];
    if (c == 0xff) return error.InvalidCharacter;
    bytes[1] = b << 4 | c >> 2;
    if (q[3] == '=') {
        if (c & 3 != 0) return error.NonCanonicalTail;
        return .{ .bytes = bytes, .len = 2 };
    }
    const d = DECODE_TABLE[q[3]];
    if (d == 0xff) return error.InvalidCharacter;
    bytes[2] = c << 6 | d;
    return .{ .bytes = bytes, .len = 3 };
}

fn alphabet(byte: u8) ?u8 {
    const value = DECODE_TABLE[byte];
    return if (value == 0xff) null else value;
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

// --- AVX2 ---

const AVX2_ENCODE: [8][32]u8 align(32) = .{
    [_]u8{ 1, 0, 2, 1, 4, 3, 5, 4, 7, 6, 8, 7, 10, 9, 11, 10 } ** 2,
    @bitCast([_]u32{0x0fc0fc00} ** 8),
    @bitCast([_]u32{0x003f03f0} ** 8),
    @bitCast([_]u32{0x04000040} ** 8),
    @bitCast([_]u32{0x01000010} ** 8),
    [_]u8{ 65, 71, 0xfc, 0xfc, 0xfc, 0xfc, 0xfc, 0xfc, 0xfc, 0xfc, 0xfc, 0xfc, 0xed, 0xf0, 0, 0 } ** 2,
    @splat(51),
    @splat(25),
};

const AVX2_DECODE: [8][32]u8 align(32) = .{
    [_]u8{ 0x15, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x13, 0x1a, 0x1b, 0x1b, 0x1b, 0x1a } ** 2,
    [_]u8{ 0x10, 0x10, 0x01, 0x02, 0x04, 0x08, 0x04, 0x08, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10 } ** 2,
    [_]u8{ 0, 16, 19, 4, 0xbf, 0xbf, 0xb9, 0xb9, 0, 0, 0, 0, 0, 0, 0, 0 } ** 2,
    @splat(0x2f),
    @bitCast([_]u16{0x0140} ** 16),
    @bitCast([_]u32{0x00011000} ** 8),
    [_]u8{ 2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, 0xff, 0xff, 0xff, 0xff } ** 2,
    @bitCast([_]u32{ 0, 1, 2, 4, 5, 6, 3, 7 }),
};

// Pointer-only assembly keeps AVX instructions out of the baseline calling convention.
// Each encoding block reads 28 bytes for 24 input bytes; the loop requires 32 remaining.
noinline fn encodeAvx2(input: []const u8, output: []u8) usize {
    const groups = (input.len - 8) / 24;
    var source: usize = undefined;
    var destination: usize = undefined;
    var remaining: usize = undefined;
    const block =
        \\vmovdqu (%[source]), %%xmm0
        \\vinserti128 $1, 12(%[source]), %%ymm0, %%ymm0
        \\vpshufb %%ymm4, %%ymm0, %%ymm0
        \\vpand %%ymm5, %%ymm0, %%ymm1
        \\vpand %%ymm6, %%ymm0, %%ymm2
        \\vpmulhuw %%ymm7, %%ymm1, %%ymm1
        \\vpmullw %%ymm8, %%ymm2, %%ymm2
        \\vpor %%ymm2, %%ymm1, %%ymm0
        \\vpsubusb %%ymm10, %%ymm0, %%ymm1
        \\vpcmpgtb %%ymm11, %%ymm0, %%ymm2
        \\vpsubb %%ymm2, %%ymm1, %%ymm1
        \\vpshufb %%ymm1, %%ymm9, %%ymm1
        \\vpaddb %%ymm0, %%ymm1, %%ymm0
        \\vmovdqu %%ymm0, (%[destination])
        \\add $24, %[source]
        \\add $32, %[destination]
        \\
    ;
    asm volatile (
        \\vmovdqa 0(%[tables]), %%ymm4
        \\vmovdqa 32(%[tables]), %%ymm5
        \\vmovdqa 64(%[tables]), %%ymm6
        \\vmovdqa 96(%[tables]), %%ymm7
        \\vmovdqa 128(%[tables]), %%ymm8
        \\vmovdqa 160(%[tables]), %%ymm9
        \\vmovdqa 192(%[tables]), %%ymm10
        \\vmovdqa 224(%[tables]), %%ymm11
        \\cmp $4, %[remaining]
        \\jb 2f
        \\1:
        \\
    ++ block ++ block ++ block ++ block ++
        \\sub $4, %[remaining]
        \\cmp $4, %[remaining]
        \\jae 1b
        \\2:
        \\test %[remaining], %[remaining]
        \\jz 4f
        \\3:
        \\
    ++ block ++
        \\dec %[remaining]
        \\jnz 3b
        \\4:
        \\vzeroupper
        : [source] "=&r" (source),
          [destination] "=&r" (destination),
          [remaining] "=&r" (remaining),
        : [_] "0" (@intFromPtr(input.ptr)),
          [_] "1" (@intFromPtr(output.ptr)),
          [_] "2" (groups),
          [tables] "r" (&AVX2_ENCODE),
        : .{
          .ymm0 = true,
          .ymm1 = true,
          .ymm2 = true,
          .ymm4 = true,
          .ymm5 = true,
          .ymm6 = true,
          .ymm7 = true,
          .ymm8 = true,
          .ymm9 = true,
          .ymm10 = true,
          .ymm11 = true,
          .cc = true,
          .memory = true,
        });
    return groups * 24;
}

// A failed block writes nothing. The scalar prefix handles its first exceptional group.
// The two stores write exactly 24 bytes, including when output ends at that block.
noinline fn decodeAvx2(input: []const u8, output: []u8) usize {
    var source: usize = undefined;
    var destination: usize = undefined;
    var remaining: usize = undefined;
    const groups = input.len / 32;
    const block =
        \\vmovdqu (%[source]), %%ymm0
        \\vpsrld $4, %%ymm0, %%ymm1
        \\vpand %%ymm7, %%ymm1, %%ymm1
        \\vpand %%ymm7, %%ymm0, %%ymm2
        \\vpshufb %%ymm1, %%ymm5, %%ymm3
        \\vpshufb %%ymm2, %%ymm4, %%ymm2
        \\vptest %%ymm3, %%ymm2
        \\jnz 4f
        \\vpcmpeqb %%ymm7, %%ymm0, %%ymm2
        \\vpaddb %%ymm2, %%ymm1, %%ymm1
        \\vpshufb %%ymm1, %%ymm6, %%ymm1
        \\vpaddb %%ymm1, %%ymm0, %%ymm0
        \\vpmaddubsw %%ymm8, %%ymm0, %%ymm0
        \\vpmaddwd %%ymm9, %%ymm0, %%ymm0
        \\vpshufb %%ymm10, %%ymm0, %%ymm0
        \\vpermd %%ymm0, %%ymm11, %%ymm0
        \\vmovdqu %%xmm0, (%[destination])
        \\vextracti128 $1, %%ymm0, %%xmm1
        \\vmovq %%xmm1, 16(%[destination])
        \\add $32, %[source]
        \\add $24, %[destination]
        \\dec %[remaining]
        \\
    ;
    asm volatile (
        \\vmovdqa 0(%[tables]), %%ymm4
        \\vmovdqa 32(%[tables]), %%ymm5
        \\vmovdqa 64(%[tables]), %%ymm6
        \\vmovdqa 96(%[tables]), %%ymm7
        \\vmovdqa 128(%[tables]), %%ymm8
        \\vmovdqa 160(%[tables]), %%ymm9
        \\vmovdqa 192(%[tables]), %%ymm10
        \\vmovdqa 224(%[tables]), %%ymm11
        \\cmp $4, %[remaining]
        \\jb 2f
        \\1:
        \\
    ++ block ++ block ++ block ++ block ++
        \\cmp $4, %[remaining]
        \\jae 1b
        \\2:
        \\test %[remaining], %[remaining]
        \\jz 4f
        \\3:
        \\
    ++ block ++
        \\jnz 3b
        \\4:
        \\vzeroupper
        : [source] "=&r" (source),
          [destination] "=&r" (destination),
          [remaining] "=&r" (remaining),
        : [_] "0" (@intFromPtr(input.ptr)),
          [_] "1" (@intFromPtr(output.ptr)),
          [_] "2" (groups),
          [tables] "r" (&AVX2_DECODE),
        : .{
          .ymm0 = true,
          .ymm1 = true,
          .ymm2 = true,
          .ymm3 = true,
          .ymm4 = true,
          .ymm5 = true,
          .ymm6 = true,
          .ymm7 = true,
          .ymm8 = true,
          .ymm9 = true,
          .ymm10 = true,
          .ymm11 = true,
          .cc = true,
          .memory = true,
        });
    return (groups - remaining) * 32;
}
