//! Detects and caches CPU and OS support for the binary codecs' AVX2 paths.
//! Codec build options and compiler restrictions stay with their callers.

const std = @import("std");
const builtin = @import("builtin");

const AVX_STATE: u32 = (1 << 26) | (1 << 27) | (1 << 28);
var avx2_cached = std.atomic.Value(u8).init(0);

pub fn hasAvx2() bool {
    if (comptime builtin.cpu.arch != .x86_64) return false;
    const saved = avx2_cached.load(.monotonic);
    if (saved != 0) return saved == 2;
    const available = detectAvx2();
    avx2_cached.store(if (available) 2 else 1, .monotonic);
    return available;
}

fn detectAvx2() bool {
    if (cpuid(0, 0).eax < 7) return false;
    const leaf1 = cpuid(1, 0).ecx;
    if (leaf1 & AVX_STATE != AVX_STATE) return false;
    const leaf7 = cpuid(7, 0).ebx;
    if (leaf7 & (1 << 5) == 0) return false;
    const xcr0 = asm volatile (
        \\xgetbv
        : [_] "={eax}" (-> u32),
        : [_] "{ecx}" (@as(u32, 0)),
        : .{ .edx = true });
    return avx2Usable(leaf1, leaf7, xcr0);
}

fn avx2Usable(leaf1: u32, leaf7: u32, xcr0: u32) bool {
    return leaf1 & AVX_STATE == AVX_STATE and leaf7 & (1 << 5) != 0 and xcr0 & 6 == 6;
}

fn cpuid(leaf: u32, subleaf: u32) struct { eax: u32, ebx: u32, ecx: u32 } {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (subleaf),
        : .{ .edx = true });
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx };
}

test "[property] - [AVX2 detection]: requires hardware and OS vector state" {
    try std.testing.expect(avx2Usable(AVX_STATE, 1 << 5, 6));
    for ([_]u5{ 26, 27, 28 }) |bit|
        try std.testing.expect(!avx2Usable(AVX_STATE & ~(@as(u32, 1) << bit), 1 << 5, 6));
    try std.testing.expect(!avx2Usable(AVX_STATE, 0, 6));
    for ([_]u32{ 0, 2, 4 }) |state|
        try std.testing.expect(!avx2Usable(AVX_STATE, 1 << 5, state));
}

test "[unit] - [AVX2 detection]: agrees with host detection on repeated calls" {
    const expected = if (comptime builtin.cpu.arch == .x86_64)
        (try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_model = .native })).cpu.has(.x86, .avx2)
    else
        false;
    try std.testing.expectEqual(expected, hasAvx2());
    try std.testing.expectEqual(expected, hasAvx2());
}

test "[property] - [base64 dispatch]: cached scalar fallback preserves both directions" {
    const base64 = @import("base64.zig");
    const saved = avx2_cached.swap(1, .monotonic);
    defer avx2_cached.store(saved, .monotonic);
    try std.testing.expect(!hasAvx2());
    var source: [257]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @truncate(i);
    var expected: [344]u8 = undefined;
    var encoded: [344]u8 = undefined;
    var decoded: [257]u8 = undefined;
    const text = try base64.encode(&encoded, &source);
    try std.testing.expectEqualSlices(u8, std.base64.standard.Encoder.encode(&expected, &source), text);
    const counts = try base64.decode(&decoded, text, .{});
    try std.testing.expectEqualSlices(u8, &source, decoded[0..counts.decoded_bytes]);
}

test "[property] - [SLOF dispatch]: detected and cached fallback paths preserve values and bytes" {
    const numpress = @import("numpress.zig");
    const saved = avx2_cached.load(.monotonic);
    defer avx2_cached.store(saved, .monotonic);
    const values = [_]f64{ 0, 1, 10, 0, 1, 10, 0 };
    const expected = [_]u8{
        0x40, 0xaf, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xd5, 0x0a, 0x78, 0x25, 0x00, 0x00,
        0xd5, 0x0a, 0x78, 0x25, 0x00, 0x00,
    };
    for ([_]u8{ 0, 1 }) |state| {
        avx2_cached.store(state, .monotonic);
        var encoded: [expected.len]u8 = undefined;
        var decoded: [values.len]f64 = undefined;
        const length = try numpress.encodeSlof(&values, 4_000, &encoded);
        try std.testing.expectEqualSlices(u8, &expected, encoded[0..length]);
        try numpress.decodeSlofExact(&expected, &decoded);
        const relative_bound = @exp(0.5 / 4_000.0) - 1.0;
        for (values, decoded) |value, actual| {
            if (value == 0)
                try std.testing.expectEqual(@as(f64, 0), actual)
            else
                try std.testing.expect(@abs(actual - value) / (value + 1) <= relative_bound * 1.000001);
        }
    }
}
