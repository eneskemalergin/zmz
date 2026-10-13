//! Checks the offline vocabulary command's process status, output, and file handling.

const std = @import("std");
const options = @import("vocabulary_test_options");

test "[cli] - [vocabulary]: rejects bad arguments and unreadable inputs without creating output" {
    var dir = std.testing.tmpDir(.{ .iterate = true });
    defer dir.cleanup();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, options.executable, std.testing.allocator);
    defer std.testing.allocator.free(executable);
    const cases = .{
        .{ &[_][]const u8{ executable, "generate", "missing", "history", "ms", "uo", "result.zig" }, "vocabulary: FileNotFound\n" },
        .{ &[_][]const u8{ executable, "candidate", "missing", "ms", "0000000000000000000000000000000000000000", "uo", "0000000000000000000000000000000000000000", "2026-01-01", "result.json" }, "vocabulary: FileNotFound\n" },
        .{ &[_][]const u8{ executable, "history", "result.json", "psi-ms", "missing.txt" }, "vocabulary: FileNotFound\n" },
        .{ &[_][]const u8{ executable, "review", "missing", "ms", "uo" }, "vocabulary: FileNotFound\n" },
        .{ &[_][]const u8{ executable, "inspect", "missing", "ms", "uo" }, "vocabulary: FileNotFound\n" },
        .{ &[_][]const u8{ executable, "scan", "missing.mzML" }, "vocabulary: FileNotFound\n" },
    };
    inline for (cases) |case| {
        const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = case[0], .cwd = .{ .dir = dir.dir } });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expectEqualStrings(case[1], result.stderr);
    }
    const invalid = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ executable, "fetch" }, .cwd = .{ .dir = dir.dir } });
    defer std.testing.allocator.free(invalid.stdout);
    defer std.testing.allocator.free(invalid.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, invalid.term);
    try std.testing.expectEqualStrings("", invalid.stdout);
    try std.testing.expectEqualStrings("usage: zig build vocabulary -- inspect|review MANIFEST.json PSI-MS.obo UO.obo\n" ++
        "       zig build vocabulary -- candidate MANIFEST.json PSI-MS.obo PSI-MS-COMMIT UO.obo UO-COMMIT DATE OUTPUT.json\n" ++
        "       zig build vocabulary -- history OUTPUT.json KEY LIST.txt [KEY LIST.txt ...]\n" ++
        "       zig build vocabulary -- generate MANIFEST.json HISTORY.json PSI-MS.obo UO.obo OUTPUT.zig\n" ++
        "       zig build vocabulary -- scan FILE.mzML [FILE.mzML ...]\n" ++
        "vocabulary: InvalidArguments\n", invalid.stderr);
    var entries = dir.dir.iterate();
    try std.testing.expectEqual(null, try entries.next(std.testing.io));
}

test "[cli] - [vocabulary scan]: reports source metadata, with or without CV declarations, without modifying the file" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, options.executable, std.testing.allocator);
    defer std.testing.allocator.free(executable);
    const cases = .{
        .{ @embedFile("empty_run"), "{\"format_version\":3,\"kind\":\"declaration\",\"resource\":\"input.mzML\",\"accession\":\"MS\",\"before\":{\"id\":\"MS\",\"full_name\":\"PSI-MS\",\"uri\":\"urn:test\",\"version\":null},\"after\":{\"resource\":\"psi-ms\",\"used_version\":\"4.1.258\",\"version_relationship\":\"absent\",\"unrecognized_uri\":true,\"unrecognized_name\":false}}\n" ++
            "{\"format_version\":3,\"kind\":\"term\",\"resource\":\"input.mzML\",\"accession\":\"X:unknown\\tµ < & \\\"\",\"before\":null,\"after\":{\"occurrences\":1,\"unknown\":true,\"obsolete\":false,\"stale_name\":false,\"former_name\":false,\"unit_disallowed\":false}}\n" ++
            "{\"format_version\":3,\"kind\":\"scan\",\"resource\":\"\",\"accession\":\"input.mzML\",\"before\":null,\"after\":{\"records\":0,\"parameters\":1,\"resolved\":0,\"missing_references\":0,\"unknown_resources\":0,\"unknown_accessions\":1,\"stale_names\":0,\"former_names\":0,\"obsolete\":0,\"units\":1,\"resolved_units\":0,\"partial_units\":1,\"disallowed_units\":0}}\n" },
        .{ "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.1.0'><run/></mzML>", "{\"format_version\":3,\"kind\":\"scan\",\"resource\":\"\",\"accession\":\"input.mzML\",\"before\":null,\"after\":{\"records\":0,\"parameters\":0,\"resolved\":0,\"missing_references\":0,\"unknown_resources\":0,\"unknown_accessions\":0,\"stale_names\":0,\"former_names\":0,\"obsolete\":0,\"units\":0,\"resolved_units\":0,\"partial_units\":0,\"disallowed_units\":0}}\n" },
    };
    inline for (cases) |case| {
        try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = case[0] });
        const result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{ executable, "scan", "input.mzML" },
            .cwd = .{ .dir = dir.dir },
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqualStrings(case[1], result.stdout);
        var buffer: [2048]u8 = undefined;
        try std.testing.expectEqualStrings(case[0], try dir.dir.readFile(std.testing.io, "input.mzML", &buffer));
    }
}

test "[cli] - [vocabulary scan]: reports where an unreadable file broke and exits with status 1" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, options.executable, std.testing.allocator);
    defer std.testing.allocator.free(executable);
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = "<mzML xmlns='http://psi.hupo.org/ms/mzml'><run><broken" });
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ executable, "scan", "input.mzML" },
        .cwd = .{ .dir = dir.dir },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.startsWith(u8, result.stderr, "input.mzML: "));
    try std.testing.expect(std.mem.endsWith(u8, result.stderr, "\nvocabulary: InvalidXml\n"));
}
