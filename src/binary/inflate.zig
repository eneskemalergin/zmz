//! Decodes bounded, contiguous DEFLATE bytes using Zig's checked Huffman tables.
//!
//! The zlib wrapper owns headers, checksums, and trailing-byte checks.

const std = @import("std");
const Flate = std.compress.flate.Decompress;
const Error = error{ InvalidData, TruncatedInput, OutputTooSmall };

const LENGTH_BASE = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const LENGTH_BITS = [_]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const DISTANCE_BASE = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const DISTANCE_BITS = [_]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const CODE_ORDER = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
const FIXED = blk: {
    @setEvalBranchQuota(5000);
    var table: [512]Flate.Symbol = undefined;
    for (0..288) |value| {
        const bits: u4 = if (value < 144) 8 else if (value < 256) 9 else if (value < 280) 7 else 8;
        const code: u16 = @intCast(if (value < 144) value + 48 else if (value < 256) value + 256 else if (value < 280) value - 256 else value - 88);
        var index: usize = @bitReverse(code) >> @as(u4, @intCast(16 - @as(u5, bits)));
        while (index < table.len) : (index += @as(usize, 1) << bits)
            table[index] = .{ .value = @intCast(value), .code_bits = bits };
    }
    break :blk table;
};

/// A decoded prefix and the exact number of consumed raw DEFLATE bytes.
pub const Result = struct { bytes: []u8, consumed: usize };

/// Uses disjoint caller storage without allocation. Failure leaves output unspecified.
/// This internal operation does not interpret a zlib header or verify a checksum.
pub fn decode(output: []u8, source: []const u8) Error!Result {
    var input: Bits = .{ .source = source };
    var written: usize = 0;
    var literal: Flate.LiteralDecoder = .{};
    var distance: Flate.DistanceDecoder = .{};
    while (true) {
        const final = try input.take(1) != 0;
        switch (try input.take(2)) {
            0 => {
                input.alignByte();
                if (input.source.len - input.position < 4) return error.TruncatedInput;
                const header = input.source[input.position..][0..4];
                const length = std.mem.readInt(u16, header[0..2], .little);
                if (length != ~std.mem.readInt(u16, header[2..4], .little)) return error.InvalidData;
                input.position += 4;
                if (length > output.len - written) return error.OutputTooSmall;
                if (length > input.source.len - input.position) return error.TruncatedInput;
                @memcpy(output[written..][0..length], input.source[input.position..][0..length]);
                input.position += length;
                written += length;
            },
            1 => try decodeBlock(true, &input, output, &written, &literal, &distance),
            2 => {
                try readTables(&input, &literal, &distance);
                try decodeBlock(false, &input, output, &written, &literal, &distance);
            },
            else => return error.InvalidData,
        }
        if (final) break;
    }
    input.alignByte();
    return .{ .bytes = output[0..written], .consumed = input.position };
}

fn readTables(input: *Bits, literal: *Flate.LiteralDecoder, distance: *Flate.DistanceDecoder) Error!void {
    const literals: usize = @as(usize, try input.take(5)) + 257;
    const distances: usize = @as(usize, try input.take(5)) + 1;
    const codes: usize = @as(usize, try input.take(4)) + 4;
    if (literals > 286 or distances > 30) return error.InvalidData;
    var code_lengths: [19]u4 = @splat(0);
    for (CODE_ORDER[0..codes]) |index| code_lengths[index] = @intCast(try input.take(3));
    var codegen: Flate.CodegenDecoder = .{};
    codegen.generate(&code_lengths) catch return error.InvalidData;
    var lengths: [316]u4 = undefined;
    const total = literals + distances;
    var position: usize = 0;
    while (position < total) {
        const symbol = codegen.find(@intCast(input.peek() & 127)) catch return error.InvalidData;
        try input.drop(symbol.code_bits);
        if (symbol.value < 16) {
            lengths[position] = @intCast(symbol.value);
            position += 1;
            continue;
        }
        const value: u4 = if (symbol.value == 16) blk: {
            if (position == 0) return error.InvalidData;
            break :blk lengths[position - 1];
        } else 0;
        const count: usize = switch (symbol.value) {
            16 => @as(usize, try input.take(2)) + 3,
            17 => @as(usize, try input.take(3)) + 3,
            18 => @as(usize, try input.take(7)) + 11,
            else => return error.InvalidData,
        };
        if (count > total - position) return error.InvalidData;
        @memset(lengths[position..][0..count], value);
        position += count;
    }
    literal.generate(lengths[0..literals]) catch return error.InvalidData;
    distance.generate(lengths[literals..total]) catch return error.InvalidData;
}

fn decodeBlock(comptime fixed: bool, input: *Bits, output: []u8, written: *usize, literal: *Flate.LiteralDecoder, distance: *Flate.DistanceDecoder) Error!void {
    var position = written.*;
    while (true) {
        var symbol: Flate.Symbol = undefined;
        if (output.len - position >= 3 and input.source.len - input.position >= 8) {
            const window = std.mem.readInt(u64, input.source[input.position..][0..8], .little) >> input.shift;
            var consumed: u6 = 0;
            var decoded: usize = 0;
            while (decoded < 3) : (decoded += 1) {
                const bits: u15 = @truncate(window >> consumed);
                symbol = if (fixed) FIXED[bits & 511] else literal.find(bits) catch return error.InvalidData;
                if (symbol.value >= 256) break;
                output[position] = @intCast(symbol.value);
                position += 1;
                consumed += symbol.code_bits;
            }
            const total = @as(u6, input.shift) + consumed;
            input.position += total / 8;
            input.shift = @truncate(total);
            if (decoded == 3) continue;
        } else {
            symbol = if (fixed) FIXED[input.peek() & 511] else literal.find(input.peek()) catch return error.InvalidData;
        }
        try input.drop(symbol.code_bits);
        if (symbol.value < 256) {
            if (position == output.len) return error.OutputTooSmall;
            output[position] = @intCast(symbol.value);
            position += 1;
            continue;
        }
        if (symbol.value == 256) break;
        if (symbol.value > 285) return error.InvalidData;
        const length_index = symbol.value - 257;
        const length = LENGTH_BASE[length_index] + try input.take(LENGTH_BITS[length_index]);
        const distance_index: usize = if (fixed) @bitReverse(@as(u5, @intCast(try input.take(5)))) else blk: {
            const entry = distance.find(input.peek()) catch return error.InvalidData;
            try input.drop(entry.code_bits);
            break :blk entry.value;
        };
        if (distance_index >= DISTANCE_BASE.len) return error.InvalidData;
        const back = DISTANCE_BASE[distance_index] + try input.take(DISTANCE_BITS[distance_index]);
        if (back > position) return error.InvalidData;
        if (length > output.len - position) return error.OutputTooSmall;
        var copied: usize = 0;
        while (copied < length) {
            const amount = @min(back + copied, length - copied);
            @memcpy(output[position + copied ..][0..amount], output[position - back ..][0..amount]);
            copied += amount;
        }
        position += length;
    }
    written.* = position;
}

const Bits = struct {
    source: []const u8,
    position: usize = 0,
    shift: u3 = 0,

    fn peek(self: *const Bits) u15 {
        const remaining = self.source[self.position..];
        const value = if (remaining.len >= 4) std.mem.readInt(u32, remaining[0..4], .little) else std.mem.readVarInt(u32, remaining, .little);
        return @truncate(value >> self.shift);
    }

    fn take(self: *Bits, count: u4) Error!u16 {
        const result = self.peek() & ((@as(u16, 1) << count) - 1);
        try self.drop(count);
        return result;
    }

    fn drop(self: *Bits, count: u4) Error!void {
        const bits: u8 = @as(u8, self.shift) + count;
        const available = self.source.len - self.position;
        if (available < 3 and available * 8 < bits) return error.TruncatedInput;
        self.position += bits / 8;
        self.shift = @truncate(bits);
    }

    fn alignByte(self: *Bits) void {
        self.position += @intFromBool(self.shift != 0);
        self.shift = 0;
    }
};
