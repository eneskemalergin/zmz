//! Encodes padded Base64 and decodes fragmented XML text into caller-owned storage.

const std = @import("std");

/// Checked lexical, capacity, and state failures. Output after failure is unspecified.
pub const Error = error{
    InvalidCharacter,
    InvalidPadding,
    NonCanonicalTail,
    TruncatedInput,
    OutputTooSmall,
    LimitExceeded,
    LengthOverflow,
    OverlappingBuffers,
    AlreadyFinished,
    FailedState,
};

/// Independent bounds on logical XML text, significant Base64 characters, and output.
/// Physical XML byte limits belong to the XML reader, before entity expansion.
pub const Limits = struct {
    text_bytes: usize = 256 * 1024 * 1024,
    significant_bytes: usize = 256 * 1024 * 1024,
    decoded_bytes: usize = 192 * 1024 * 1024,
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

/// Writes canonical padded Base64. Source and destination must not overlap.
pub fn encode(output: []u8, source: []const u8) Error![]u8 {
    if (overlaps(output, source)) return error.OverlappingBuffers;
    const required = try encodedSize(source.len);
    if (output.len < required) return error.OutputTooSmall;
    _ = std.base64.standard.Encoder.encode(output[0..required], source);
    return output[0..required];
}

/// Decodes logical XML text, accepting only XML whitespace between Base64 characters.
/// No allocation or complete whitespace-stripped copy is made.
pub fn decode(output: []u8, source: []const u8, limits: Limits) Error!Counts {
    var decoder = Decoder.init(output, limits);
    try decoder.update(source);
    return decoder.finish();
}

/// Checks the same lexical rules and limits as decode without allocating or writing output.
pub fn validate(source: []const u8, limits: Limits) Error!Counts {
    var decoder = Decoder.init(&.{}, limits);
    decoder.discard_output = true;
    try decoder.update(source);
    return decoder.finish();
}

/// A bounded decoder borrowing its destination until finish or abandonment.
/// Input slices need remain alive only during update and must not overlap the destination.
/// Failures are sticky; counters and partially written output are not a successful result.
pub const Decoder = struct {
    output: []u8,
    limits: Limits,
    counts: Counts = .{},
    quartet: [4]u8 = undefined,
    quartet_len: u3 = 0,
    padded: bool = false,
    finished: bool = false,
    failed: bool = false,
    discard_output: bool = false,
    /// Offset in concatenated logical text, not the physical XML source.
    error_offset: ?usize = null,

    /// Borrows the destination without allocating or writing it.
    pub fn init(output: []u8, limits: Limits) Decoder {
        return .{ .output = output, .limits = limits };
    }

    /// Consumes one text fragment. Empty fragments are valid before finish.
    pub fn update(self: *Decoder, text: []const u8) Error!void {
        if (self.failed) return error.FailedState;
        if (self.finished) return error.AlreadyFinished;
        errdefer self.failed = true;
        if (overlaps(self.output, text)) return error.OverlappingBuffers;
        const total = std.math.add(usize, self.counts.text_bytes, text.len) catch
            return error.LengthOverflow;
        if (total > self.limits.text_bytes) return error.LimitExceeded;
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
            if (self.counts.significant_bytes == self.limits.significant_bytes)
                return error.LimitExceeded;
            self.counts.significant_bytes += 1;
            self.quartet[self.quartet_len] = byte;
            self.quartet_len += 1;
            if (self.quartet_len == 4) try self.flushQuartet();
        }
        self.error_offset = null;
    }

    fn decodeRun(self: *Decoder, text: []const u8) usize {
        if (self.quartet_len != 0 or self.padded or text.len < 32) return 0;
        var length: usize = @min(text.len, 256) / 4 * 4;
        if (text[length - 1] == '=') length -= 4;
        var decoded: usize = length / 4 * 3;
        if (length > self.limits.significant_bytes -| self.counts.significant_bytes or
            decoded > self.limits.decoded_bytes -| self.counts.decoded_bytes) return 0;
        var discarded: [192]u8 = undefined;
        const output = if (self.discard_output) discarded[0..decoded] else blk: {
            if (decoded > self.output.len -| self.counts.decoded_bytes) return 0;
            break :blk self.output[self.counts.decoded_bytes..][0..decoded];
        };
        // A failed attempt leaves counters unchanged. The quartet path owns whitespace,
        // padding, limits, and exact diagnostics, including errors after partial progress.
        std.base64.standard_no_pad.Decoder.decode(output, text[0..length]) catch {
            length = @call(.never_inline, decodePrefix, .{ output, text[0..length] });
            if (length == 0) return 0;
            decoded = length / 4 * 3;
        };
        self.counts.text_bytes += length;
        self.counts.significant_bytes += length;
        self.counts.decoded_bytes += decoded;
        return length;
    }

    /// Checks the final quartet and returns counts once. Does not free the destination.
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
        const q = self.quartet;
        const a = alphabet(q[0]) orelse return error.InvalidPadding;
        const b = alphabet(q[1]) orelse return error.InvalidPadding;
        const c = alphabet(q[2]);
        const d = alphabet(q[3]);
        var count: usize = 3;
        if (q[2] == '=') {
            if (q[3] != '=') return error.InvalidPadding;
            if (b & 15 != 0) return error.NonCanonicalTail;
            count = 1;
        } else if (q[3] == '=') {
            if (c.? & 3 != 0) return error.NonCanonicalTail;
            count = 2;
        }
        const end = std.math.add(usize, self.counts.decoded_bytes, count) catch
            return error.LengthOverflow;
        if (end > self.limits.decoded_bytes) return error.LimitExceeded;
        if (!self.discard_output) {
            if (end > self.output.len) return error.OutputTooSmall;
            const destination = self.output[self.counts.decoded_bytes..end];
            destination[0] = a << 2 | b >> 4;
            if (count >= 2) destination[1] = b << 4 | c.? >> 2;
            if (count == 3) destination[2] = c.? << 6 | d.?;
        }
        self.counts.decoded_bytes = end;
        self.quartet_len = 0;
        self.padded = count != 3;
    }
};

fn decodePrefix(output: []u8, text: []const u8) usize {
    const stop = std.mem.findAny(u8, text, " \t\r\n") orelse return 0;
    const length = stop / 4 * 4;
    if (length == 0) return 0;
    std.base64.standard_no_pad.Decoder.decode(output[0 .. length / 4 * 3], text[0..length]) catch return 0;
    return length;
}

fn alphabet(byte: u8) ?u8 {
    return switch (byte) {
        'A'...'Z' => byte - 'A',
        'a'...'z' => byte - 'a' + 26,
        '0'...'9' => byte - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn overlaps(output: []u8, source: []const u8) bool {
    if (output.len == 0 or source.len == 0) return false;
    const a = @intFromPtr(output.ptr);
    const b = @intFromPtr(source.ptr);
    return if (a <= b) b - a < output.len else a - b < source.len;
}
