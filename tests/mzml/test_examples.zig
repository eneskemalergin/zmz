//! Runs the public example programs on small local fixtures and reads their output files.

const std = @import("std");
const mzml = @import("zmz").mzml;
const options = @import("example_test_options");
const support = @import("support.zig");

fn run(dir: std.Io.Dir, executable: []const u8, args: []const []const u8, exit_code: u8) ![]u8 {
    const allocator = std.testing.allocator;
    const path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, executable, allocator);
    defer allocator.free(path);
    const argv = try std.mem.concat(allocator, []const u8, &.{ &.{path}, args });
    defer allocator.free(argv);
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = argv, .cwd = .{ .dir = dir } });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if (!std.meta.eql(std.process.Child.Term{ .exited = exit_code }, result.term))
        std.debug.print("{s}: {s}\n", .{ executable, result.stderr });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = exit_code }, result.term);
    if (exit_code == 0) try std.testing.expectEqualStrings("", result.stderr);
    return result.stdout;
}

test "[integration] - [mzML examples]: streams all codecs and retains group-based metadata after EOF" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, @embedFile("data/writer_plain.mzML"), "<spectrumList count=\"8\"", "<spectrumList count=\"1\"");
    defer std.testing.allocator.free(source);
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = source });
    const decoded = try run(dir.dir, options.stream, &.{"input.mzML"}, 0);
    defer std.testing.allocator.free(decoded);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "spectra: declared=1 observed=8\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, decoded, "retained: scan=none ms_level=1\nrecords=16 values=96\n"));
    const metadata = try run(dir.dir, options.stream, &.{ "input.mzML", "--metadata" }, 0);
    defer std.testing.allocator.free(metadata);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "  array=") == null);
    try std.testing.expect(std.mem.endsWith(u8, metadata, "records=16 values=0\n"));
    const selected = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000514" }, 0);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, selected, "type=f64 count=3"));
    try std.testing.expect(std.mem.indexOf(u8, selected, "chromatogram=") == null);
}

test "[integration] - [mzML examples]: selected decoding leaves unrequested codecs uninterpreted" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const source = support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'>" ++
        "<spectrum id='scan=1' index='0' defaultArrayLength='1'><binaryDataArrayList count='2'>" ++
        "<binaryDataArray encodedLength='12'><referenceableParamGroupRef ref='encoding'/><binary>AAAAAAAA8D8=</binary>" ++
        "<cvParam cvRef='MS' accession='MS:1000514' name='m/z array'/></binaryDataArray>" ++
        "<binaryDataArray encodedLength='4'><cvParam cvRef='MS' accession='MS:1000523' name='64-bit float'/>" ++
        "<cvParam cvRef='MS' accession='MS:1003089' name='zstd compression'/><binary>AAAA</binary></binaryDataArray>" ++
        "</binaryDataArrayList></spectrum></spectrumList></run></mzML>";
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = source });
    const selected = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000514" }, 0);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("scan=1 MS:1000514 type=f64 count=1 first=1\n", selected);
    const failed = try run(dir.dir, options.stream, &.{"input.mzML"}, 1);
    defer std.testing.allocator.free(failed);
    const missing = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000595" }, 0);
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("", missing);
    const rewritten = try run(dir.dir, options.rewrite, &.{ "input.mzML", "copy.mzML" }, 0);
    defer std.testing.allocator.free(rewritten);
    const file = try dir.dir.openFile(std.testing.io, "copy.mzML", .{});
    defer file.close(std.testing.io);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .file = .{ .handle = file, .io = std.testing.io } }, .{});
    defer index.deinit();
    var record = (try index.byId(std.testing.allocator, "scan=1")).?;
    defer record.deinit();
    try std.testing.expectEqualStrings("AAAA", record.value.binaryArrays()[1].child(.binary).?.text.?);
}

test "[integration] - [mzML examples]: selects integer arrays and empty arrays with explicit types" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    inline for (.{
        .{ "MS:1000519", "32-bit integer", "AQAAAA==", "8", "1", "type=i32 count=1 first=1\n" },
        .{ "MS:1000522", "64-bit integer", "AQAAAAAAAAA=", "12", "1", "type=i64 count=1 first=1\n" },
        .{ "MS:1000523", "64-bit float", "", "0", "0", "type=f64 count=0\n" },
    }) |case| {
        const source = support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'>" ++
            "<spectrum id='scan=1' index='0' defaultArrayLength='" ++ case[4] ++ "'><binaryDataArrayList count='1'>" ++
            "<binaryDataArray encodedLength='" ++ case[3] ++ "'><cvParam cvRef='MS' accession='MS:1000514' name='m/z array'/>" ++
            "<cvParam cvRef='MS' accession='" ++ case[0] ++ "' name='" ++ case[1] ++ "'/>" ++
            "<cvParam cvRef='MS' accession='MS:1000576' name='no compression'/><binary>" ++ case[2] ++ "</binary>" ++
            "</binaryDataArray></binaryDataArrayList></spectrum></spectrumList></run></mzML>";
        try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = source });
        const selected = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000514" }, 0);
        defer std.testing.allocator.free(selected);
        try std.testing.expectEqualStrings("scan=1 MS:1000514 " ++ case[5], selected);
    }
}

test "[integration] - [mzML examples]: writes mixed primitive arrays and retrieves them under both index policies" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    inline for (.{ false, true }) |indexed| {
        const path = if (indexed) "indexed.mzML" else "plain.mzML";
        const written = try run(dir.dir, options.write, if (indexed) &.{ path, "--indexed" } else &.{path}, 0);
        defer std.testing.allocator.free(written);
        const file = try dir.dir.openFile(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .file = .{ .handle = file, .io = std.testing.io } }, .{ .policy = if (indexed) .open_embedded else .rebuild });
        defer index.deinit();
        var decoded = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
        defer decoded.deinit();
        var record = (try index.byIdDecoded(std.testing.allocator, "scan=1", &decoded)).?;
        defer record.deinit();
        try std.testing.expectEqualSlices(f64, &.{ 100, 200, 300 }, decoded.get(0).?.values.float64);
        try std.testing.expectEqualSlices(f32, &.{ 10, 20, 30 }, decoded.get(1).?.values.float32);
        const retrieved = try run(dir.dir, options.indexed, if (indexed) &.{ path, "scan=1" } else &.{ path, "scan=1", "--rebuild" }, 0);
        defer std.testing.allocator.free(retrieved);
        try std.testing.expectEqualStrings("spectrum scan=1 arrays=2\n  array=0 type=float64 count=3 first=100\n  array=1 type=float32 count=3 first=10\n", retrieved);
        const selected = try run(dir.dir, options.select, &.{ path, "MS:1000515" }, 0);
        defer std.testing.allocator.free(selected);
        try std.testing.expectEqualStrings("scan=1 MS:1000515 type=f32 count=3 first=10\n", selected);
    }
    const missing = try run(dir.dir, options.indexed, &.{ "indexed.mzML", "missing" }, 0);
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("not found: missing\n", missing);
    const no_index = try run(dir.dir, options.indexed, &.{ "plain.mzML", "scan=1" }, 1);
    defer std.testing.allocator.free(no_index);
    const original = try dir.dir.readFileAlloc(std.testing.io, "plain.mzML", std.testing.allocator, .limited(16 * 1024));
    defer std.testing.allocator.free(original);
    const failed = try run(dir.dir, options.write, &.{"plain.mzML"}, 1);
    defer std.testing.allocator.free(failed);
    const after = try dir.dir.readFileAlloc(std.testing.io, "plain.mzML", std.testing.allocator, .limited(16 * 1024));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(original, after);
}

test "[integration] - [mzML examples]: rewrites metadata and empty lists without decoding payloads" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    inline for (.{
        support.REFERENCED_DOCUMENT,
        support.HEADER ++ "<spectrumList count='0' defaultDataProcessingRef='dp'/><chromatogramList count='0' defaultDataProcessingRef='dp'/></run></mzML>",
        support.HEADER ++ "<spectrumList count='0' defaultDataProcessingRef='dp'/><chromatogramList count='1' defaultDataProcessingRef='dp'>" ++
            "<chromatogram id='tic' index='0' defaultArrayLength='1'>" ++ support.ARRAYS ++ "</chromatogram></chromatogramList></run></mzML>",
        support.HEADER ++ "</run></mzML>",
    }, 0..) |source, i| {
        try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = source });
        const path = std.fmt.comptimePrint("copy{d}.mzML", .{i});
        const rewritten = try run(dir.dir, options.rewrite, &.{ "input.mzML", path }, 0);
        defer std.testing.allocator.free(rewritten);
        const bytes = try dir.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(16 * 1024));
        defer std.testing.allocator.free(bytes);
        var before_input = std.Io.Reader.fixed(source);
        var before = try mzml.StreamReader.init(std.testing.allocator, &before_input, .{});
        defer before.deinit();
        var after_input = std.Io.Reader.fixed(bytes);
        var after = try mzml.StreamReader.init(std.testing.allocator, &after_input, .{});
        defer after.deinit();
        const before_header = try before.readHeader();
        const after_header = try after.readHeader();
        try support.expectNode(before_header.document, after_header.document);
        try support.expectNode(before_header.run, after_header.run);
        while (try before.nextRecord()) |record|
            try support.expectNode(record.node, (try after.nextRecord()).?.node);
        try std.testing.expectEqual(null, try after.nextRecord());
        inline for (.{ "spectrum_list", "chromatogram_list" }) |field| {
            const expected = @field(before_header, field);
            const actual = @field(after_header, field);
            try std.testing.expectEqual(expected == null, actual == null);
            if (expected) |list| try std.testing.expectEqualDeep(list, actual.?);
        }
    }
}

test "[failure] - [mzML examples]: failed rewrites remove partial output and never overwrite input" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const source = support.HEADER ++ "<spectrumList count='0' extra='kept' defaultDataProcessingRef='dp'/></run></mzML>";
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = source });
    const failed = try run(dir.dir, options.rewrite, &.{ "input.mzML", "failed.mzML" }, 1);
    defer std.testing.allocator.free(failed);
    try std.testing.expectError(error.FileNotFound, dir.dir.openFile(std.testing.io, "failed.mzML", .{}));
    const same_path = try run(dir.dir, options.rewrite, &.{ "input.mzML", "input.mzML" }, 1);
    defer std.testing.allocator.free(same_path);
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(source, try dir.dir.readFile(std.testing.io, "input.mzML", &buffer));
}
