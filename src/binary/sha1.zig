//! SHA-1 for the indexedmzML checksum. Whole blocks use the x86 SHA extensions when the
//! CPU has them, about 2.7 times std's scalar rounds; both paths give the same digest.

const std = @import("std");
const builtin = @import("builtin");
const kernel = @import("kernel_options");
const core = @import("core.zig");

/// Streaming SHA-1 with std's update and finalResult. It keeps std's state, partial block,
/// and padding; only whole blocks take the SHA extension path.
pub const Sha1 = struct {
    inner: std.crypto.hash.Sha1 = .init(.{}),

    pub fn update(self: *Sha1, bytes: []const u8) void {
        if (comptime !USE_SHA_NI) return self.inner.update(bytes);
        if (!core.hasSha()) return self.inner.update(bytes);
        const d = &self.inner;
        d.total_len += bytes.len;
        var rest = bytes;
        if (d.buf_len != 0) {
            const take = @min(d.buf.len - d.buf_len, rest.len);
            @memcpy(d.buf[d.buf_len..][0..take], rest[0..take]);
            d.buf_len += @intCast(take);
            rest = rest[take..];
            if (d.buf_len < d.buf.len) return;
            compress(&d.s, &d.buf);
            d.buf_len = 0;
        }
        const whole = rest.len - rest.len % 64;
        if (whole != 0) compress(&d.s, rest[0..whole]);
        @memcpy(d.buf[0 .. rest.len - whole], rest[whole..]);
        d.buf_len = @intCast(rest.len - whole);
    }

    pub fn finalResult(self: *Sha1) [20]u8 {
        return self.inner.finalResult();
    }
};

// HACK: Zig's self-hosted x86 backend cannot assemble vector memory operands; drop the
// stage2_llvm check when it can.
const USE_SHA_NI = builtin.cpu.arch == .x86_64 and builtin.zig_backend == .stage2_llvm and kernel.dispatch;

// pshufb mask reversing 16 bytes, so four big-endian words load with W0 in lane 3.
const REVERSE: [16]u8 align(16) = .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 };

// One block is 20 groups of four rounds. xmm0 holds ABCD; E alternates between xmm1 and
// xmm2, the other register saving ABCD for the next group's E. Schedule vector W[k] lives in
// xmm3 + k % 4: group g adds W[g], starts W[g + 3] (sha1msg1), folds W[g] into W[g + 2]
// (pxor), and finishes W[g + 1] (sha1msg2). The round function changes every five groups.
const ROUNDS = rounds: {
    const w = [_][]const u8{ "%%xmm3", "%%xmm4", "%%xmm5", "%%xmm6" };
    var text: []const u8 = "";
    for (0..20) |g| {
        const e = if (g % 2 == 0) "%%xmm1" else "%%xmm2";
        const saved = if (g % 2 == 0) "%%xmm2" else "%%xmm1";
        if (g < 4) text = text ++ std.fmt.comptimePrint("movdqu {d}(%[data]), {s}\npshufb %%xmm7, {s}\n", .{ g * 16, w[g], w[g] });
        text = text ++ if (g == 0) "paddd %%xmm3, %%xmm1\n" else std.fmt.comptimePrint("sha1nexte {s}, {s}\n", .{ w[g % 4], e });
        if (g >= 3 and g <= 18) text = text ++ std.fmt.comptimePrint("sha1msg2 {s}, {s}\n", .{ w[g % 4], w[(g + 1) % 4] });
        text = text ++ std.fmt.comptimePrint("movdqa %%xmm0, {s}\nsha1rnds4 ${d}, {s}, %%xmm0\n", .{ saved, g / 5, e });
        if (g >= 1 and g <= 16) text = text ++ std.fmt.comptimePrint("sha1msg1 {s}, {s}\n", .{ w[g % 4], w[(g + 3) % 4] });
        if (g >= 2 and g <= 17) text = text ++ std.fmt.comptimePrint("pxor {s}, {s}\n", .{ w[g % 4], w[(g + 2) % 4] });
    }
    break :rounds text;
};

// The CPU must have SHA and SSSE3 (core.hasSha).
noinline fn compress(state: *[5]u32, data: []const u8) void {
    var abcd: [4]u32 align(16) = state[0..4].*;
    var e: [4]u32 align(16) = .{ 0, 0, 0, state[4] };
    var cursor = @intFromPtr(data.ptr);
    var blocks = data.len / 64;
    asm volatile (
        \\movdqa (%[abcd]), %%xmm0
        \\pshufd $0x1b, %%xmm0, %%xmm0
        \\movdqa (%[e]), %%xmm1
        \\movdqa (%[mask]), %%xmm7
        \\1:
        \\movdqa %%xmm0, %%xmm8
        \\movdqa %%xmm1, %%xmm9
        \\
    ++ ROUNDS ++
        \\sha1nexte %%xmm9, %%xmm1
        \\paddd %%xmm8, %%xmm0
        \\add $64, %[data]
        \\dec %[blocks]
        \\jnz 1b
        \\pshufd $0x1b, %%xmm0, %%xmm0
        \\movdqa %%xmm0, (%[abcd])
        \\movdqa %%xmm1, (%[e])
        : [data] "+r" (cursor),
          [blocks] "+r" (blocks),
        : [abcd] "r" (&abcd),
          [e] "r" (&e),
          [mask] "r" (&REVERSE),
        : .{
          .xmm0 = true,
          .xmm1 = true,
          .xmm2 = true,
          .xmm3 = true,
          .xmm4 = true,
          .xmm5 = true,
          .xmm6 = true,
          .xmm7 = true,
          .xmm8 = true,
          .xmm9 = true,
          .cc = true,
          .memory = true,
        });
    state[0..4].* = abcd;
    state[4] = e[3];
}
