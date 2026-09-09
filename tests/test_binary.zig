//! Verifies binary-array wire boundaries through the public package.

const std = @import("std");
const base64 = @import("z_mzml").base64;

test "[property] - [base64]: matches RFC 4648 vectors across every text split" {
    const cases = .{
        .{ "", "" },
        .{ "f", "Zg==" },
        .{ "fo", "Zm8=" },
        .{ "foo", "Zm9v" },
        .{ "foob", "Zm9vYg==" },
        .{ "fooba", "Zm9vYmE=" },
        .{ "foobar", "Zm9vYmFy" },
    };
    inline for (cases) |case| {
        var encoded: [32]u8 = undefined;
        try std.testing.expectEqualStrings(case[1], try base64.encode(&encoded, case[0]));
        var spaced: [64]u8 = undefined;
        var len: usize = 0;
        for (case[1]) |byte| {
            spaced[len] = byte;
            @memcpy(spaced[len + 1 ..][0..4], " \t\r\n");
            len += 5;
        }
        for (0..len + 1) |split| {
            var output: [32]u8 = undefined;
            var decoder = base64.Decoder.init(&output, .{});
            try decoder.update(spaced[0..split]);
            try decoder.update(spaced[split..len]);
            const counts = try decoder.finish();
            try std.testing.expectEqualStrings(case[0], output[0..counts.decoded_bytes]);
            try std.testing.expectEqual(case[1].len, counts.significant_bytes);
            try std.testing.expectEqual(len, counts.text_bytes);
        }
    }
}

test "[failure] - [base64]: rejects malformed tails and remains failed" {
    const cases = .{
        .{ "Z", error.TruncatedInput },
        .{ "Zg=", error.TruncatedInput },
        .{ "=g==", error.InvalidPadding },
        .{ "Z===", error.InvalidPadding },
        .{ "Zg=A", error.InvalidPadding },
        .{ "Zg==AAAA", error.InvalidPadding },
        .{ "Zh==", error.NonCanonicalTail },
        .{ "Zm9=", error.NonCanonicalTail },
        .{ "Zm-v", error.InvalidCharacter },
        .{ "Zm9v\x0b", error.InvalidCharacter },
    };
    inline for (cases) |case| {
        for (0..case[0].len + 1) |split| {
            var output: [32]u8 = undefined;
            var decoder = base64.Decoder.init(&output, .{});
            const result = blk: {
                decoder.update(case[0][0..split]) catch |err| break :blk err;
                decoder.update(case[0][split..]) catch |err| break :blk err;
                break :blk decoder.finish();
            };
            try std.testing.expectError(case[1], result);
            try std.testing.expectError(error.FailedState, decoder.update(""));
            try std.testing.expectError(error.FailedState, decoder.finish());
        }
    }
}

test "[edge] - [base64]: enforces independent bounds and destination ownership" {
    var output: [4]u8 = undefined;
    _ = try base64.decode(output[0..1], " Zg== ", .{
        .text_bytes = 6,
        .significant_bytes = 4,
        .decoded_bytes = 1,
    });
    try std.testing.expectError(error.LimitExceeded, base64.decode(&output, " Zg== ", .{ .text_bytes = 5 }));
    try std.testing.expectError(error.LimitExceeded, base64.decode(&output, "Zg==", .{ .significant_bytes = 3 }));
    try std.testing.expectError(error.LimitExceeded, base64.decode(&output, "Zg==", .{ .decoded_bytes = 0 }));
    try std.testing.expectError(error.OutputTooSmall, base64.decode(output[0..0], "Zg==", .{}));
    try std.testing.expectError(error.OutputTooSmall, base64.encode(output[0..3], "f"));
    try std.testing.expectError(error.OverlappingBuffers, base64.encode(&output, output[0..1]));
    try std.testing.expectError(error.OverlappingBuffers, base64.decode(&output, &output, .{}));
    try std.testing.expectError(error.LengthOverflow, base64.encodedSize(std.math.maxInt(usize)));
    var decoder = base64.Decoder.init(&output, .{});
    _ = try decoder.finish();
    try std.testing.expectError(error.AlreadyFinished, decoder.finish());
    try std.testing.expectError(error.AlreadyFinished, decoder.update(""));
}
