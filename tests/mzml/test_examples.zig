//! Runs the public example programs on small local fixtures and reads their output files.

const std = @import("std");
const mzml = @import("zmz").mzml;
const options = @import("example_test_options");
const support = @import("support.zig");

fn run(dir: std.Io.Dir, executable: []const u8, args: []const []const u8) ![]u8 {
    const result = try runProcess(dir, executable, args);
    defer std.testing.allocator.free(result.stderr);
    errdefer std.testing.allocator.free(result.stdout);
    if (!std.meta.eql(std.process.Child.Term{ .exited = 0 }, result.term))
        std.debug.print("{s}: {s}\n", .{ executable, result.stderr });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("", result.stderr);
    return result.stdout;
}

// A failing example exits with 1, prints nothing to stdout, and names its error on a stderr line.
// With report_path, stderr starts with the saved diagnostic for that file. Debug builds add an
// error trace, so the rest of stderr is not compared.
fn runFailing(dir: std.Io.Dir, executable: []const u8, args: []const []const u8, comptime err: anyerror, report_path: ?[]const u8) !void {
    const result = try runProcess(dir, executable, args);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    errdefer std.debug.print("{s}: {s}\n", .{ executable, result.stderr });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
    const line = "error: " ++ @errorName(err) ++ "\n";
    try std.testing.expect(std.mem.startsWith(u8, result.stderr, line) or std.mem.indexOf(u8, result.stderr, "\n" ++ line) != null);
    if (report_path) |path| {
        const prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}: [ZMZ", .{path});
        defer std.testing.allocator.free(prefix);
        try std.testing.expect(std.mem.startsWith(u8, result.stderr, prefix));
    }
}

fn runProcess(dir: std.Io.Dir, executable: []const u8, args: []const []const u8) !std.process.RunResult {
    const allocator = std.testing.allocator;
    const path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, executable, allocator);
    defer allocator.free(path);
    const argv = try std.mem.concat(allocator, []const u8, &.{ &.{path}, args });
    defer allocator.free(argv);
    return std.process.run(allocator, std.testing.io, .{ .argv = argv, .cwd = .{ .dir = dir } });
}

test "[cli] - [mzml-rewrite]: preserves XML on array group references" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = support.EXTENSIONS });
    const rewritten = try run(dir.dir, options.rewrite, &.{ "input.mzML", "zlib.mzML", "--zlib" });
    defer std.testing.allocator.free(rewritten);
    const file = try dir.dir.openFile(std.testing.io, "zlib.mzML", .{});
    defer file.close(std.testing.io);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .file = .{ .handle = file, .io = std.testing.io } }, .{});
    defer index.deinit();
    var decoded = mzml.DecodedArrays.init(std.testing.allocator, .{});
    defer decoded.deinit();
    var record = (try index.byIdDecoded(std.testing.allocator, "scan=1", &decoded)).?;
    defer record.deinit();
    const reference = record.value.binaryArrays()[0].params[0].group_ref;
    const xml = reference.xml.?;
    var extra = false;
    var schema_location = false;
    for (xml.attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, "extra")) {
            try std.testing.expectEqualStrings("reference", attribute.value);
            extra = true;
        }
        if (std.mem.endsWith(u8, attribute.name, ":schemaLocation")) {
            try std.testing.expectEqualStrings("urn:group group.xsd", attribute.value);
            schema_location = true;
        }
    }
    try std.testing.expect(extra and schema_location);
    try std.testing.expectEqual(@as(usize, 1), xml.content.len);
    try std.testing.expect(std.mem.indexOf(u8, xml.content[0].xml, "e:detail") != null);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, decoded.get(0).?.values.float64);
    try std.testing.expectEqualSlices(f64, &.{ 3, 4 }, decoded.get(1).?.values.float64);
}

test "[cli] - [mzML 1.0 examples]: selects and reencodes through the ordinary API" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = support.HISTORICAL });
    const selected = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000515", "--ms1" });
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("S19 MS:1000515 type=f64 count=2 first=3\n", selected);
    const rewritten = try run(dir.dir, options.rewrite, &.{ "input.mzML", "zlib.mzML", "--zlib" });
    defer std.testing.allocator.free(rewritten);
    const file = try dir.dir.openFile(std.testing.io, "zlib.mzML", .{});
    defer file.close(std.testing.io);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .file = .{ .handle = file, .io = std.testing.io } }, .{});
    defer index.deinit();
    try std.testing.expectEqualStrings("http://psi.hupo.org/schema_revision/mzML_1.0.0", index.header().namespace_uri);
    var decoded = mzml.DecodedArrays.init(std.testing.allocator, .{});
    defer decoded.deinit();
    var first = (try index.byIdDecoded(std.testing.allocator, "S19", &decoded)).?;
    defer first.deinit();
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, decoded.get(0).?.values.float64);
    try std.testing.expectEqualSlices(f64, &.{ 3, 4 }, decoded.get(1).?.values.float64);
    try std.testing.expectEqual(mzml.arrays.Pipeline.zlib, decoded.get(0).?.encoding.pipeline);
    try std.testing.expectEqual(mzml.model.Representation.profile, (try first.value.representation(index.header().groups)).?);
    var second = (try index.byId(std.testing.allocator, "S20")).?;
    defer second.deinit();
    try std.testing.expectEqualStrings("A1", second.value.node.attribute("spotID").?);
    try std.testing.expectEqual(@as(usize, 2), second.value.node.child(.spectrum_description).?.child(.acquisition_list).?.children.len);
}

test "[cli] - [mzML examples]: streams all codecs and retains group-based metadata after EOF" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, @embedFile("data/writer_plain.mzML"), "<spectrumList count=\"8\"", "<spectrumList count=\"1\"");
    defer std.testing.allocator.free(source);
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = source });
    const decoded = try run(dir.dir, options.stream, &.{"input.mzML"});
    defer std.testing.allocator.free(decoded);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "spectra: declared=1 observed=8\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, decoded, "retained: scan=none ms_level=1\nrecords=16 values=96\n"));
    const metadata = try run(dir.dir, options.stream, &.{ "input.mzML", "--metadata" });
    defer std.testing.allocator.free(metadata);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "  array=") == null);
    try std.testing.expect(std.mem.endsWith(u8, metadata, "records=16 values=0\n"));
    const selected = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000514" });
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, selected, "type=f64 count=3"));
    try std.testing.expect(std.mem.indexOf(u8, selected, "chromatogram=") == null);
    for ([_][]const u8{ "--stream", "--ms1" }) |mode| {
        const streamed = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000514", mode });
        defer std.testing.allocator.free(streamed);
        try std.testing.expectEqualStrings(selected, streamed);
    }
}

test "[cli] - [mzML examples]: selected decoding leaves unrequested codecs uninterpreted" {
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
    const selected = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000514" });
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("scan=1 MS:1000514 type=f64 count=1 first=1\n", selected);
    try runFailing(dir.dir, options.stream, &.{"input.mzML"}, error.UnsupportedEncoding, "input.mzML");
    const missing = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000595" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("", missing);
    const rewritten = try run(dir.dir, options.rewrite, &.{ "input.mzML", "copy.mzML" });
    defer std.testing.allocator.free(rewritten);
    const file = try dir.dir.openFile(std.testing.io, "copy.mzML", .{});
    defer file.close(std.testing.io);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .file = .{ .handle = file, .io = std.testing.io } }, .{});
    defer index.deinit();
    var record = (try index.byId(std.testing.allocator, "scan=1")).?;
    defer record.deinit();
    try std.testing.expectEqualStrings("AAAA", record.value.binaryArrays()[1].child(.binary).?.text.?);
    const late = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000514", "--stream" });
    defer std.testing.allocator.free(late);
    try std.testing.expectEqualStrings("", late);
    const leading = try std.mem.replaceOwned(u8, std.testing.allocator, source, "<binary>AAAAAAAA8D8=</binary><cvParam cvRef='MS' accession='MS:1000514' name='m/z array'/>", "<cvParam cvRef='MS' accession='MS:1000514' name='m/z array'/><binary>AAAAAAAA8D8=</binary>");
    defer std.testing.allocator.free(leading);
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "leading.mzML", .data = leading });
    const streamed = try run(dir.dir, options.select, &.{ "leading.mzML", "MS:1000514", "--stream" });
    defer std.testing.allocator.free(streamed);
    try std.testing.expectEqualStrings(selected, streamed);
}

test "[cli] - [mzML examples]: selects integer arrays and empty arrays with explicit types" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    inline for (.{
        .{ "MS:1000521", "32-bit float", "AACAPw==", "8", "1", "type=f32 count=1 first=1\n" },
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
        const selected = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000514" });
        defer std.testing.allocator.free(selected);
        try std.testing.expectEqualStrings("scan=1 MS:1000514 " ++ case[5], selected);
        const streamed = try run(dir.dir, options.select, &.{ "input.mzML", "MS:1000514", "--stream" });
        defer std.testing.allocator.free(streamed);
        try std.testing.expectEqualStrings(selected, streamed);
        const rewritten = try run(dir.dir, options.rewrite, &.{ "input.mzML", "zlib.mzML", "--zlib" });
        defer std.testing.allocator.free(rewritten);
        const fetched = try run(dir.dir, options.select, &.{ "zlib.mzML", "MS:1000514", "--stream" });
        defer std.testing.allocator.free(fetched);
        try std.testing.expectEqualStrings(selected, fetched);
        try dir.dir.deleteFile(std.testing.io, "zlib.mzML");
    }
}

test "[cli] - [mzML examples]: writes mixed primitive arrays and retrieves them under both index policies" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    inline for (.{ false, true }) |indexed| {
        const path = if (indexed) "indexed.mzML" else "plain.mzML";
        const written = try run(dir.dir, options.write, if (indexed) &.{ path, "--indexed" } else &.{path});
        defer std.testing.allocator.free(written);
        const file = try dir.dir.openFile(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .file = .{ .handle = file, .io = std.testing.io } }, .{ .policy = if (indexed) .open_embedded else .rebuild });
        defer index.deinit();
        var decoded = mzml.DecodedArrays.init(std.testing.allocator, .{});
        defer decoded.deinit();
        var record = (try index.byIdDecoded(std.testing.allocator, "scan=1", &decoded)).?;
        defer record.deinit();
        try std.testing.expectEqualSlices(f64, &.{ 100, 200, 300 }, decoded.get(0).?.values.float64);
        try std.testing.expectEqualSlices(f32, &.{ 10, 20, 30 }, decoded.get(1).?.values.float32);
        const retrieved = try run(dir.dir, options.indexed, if (indexed) &.{ path, "scan=1" } else &.{ path, "scan=1", "--rebuild" });
        defer std.testing.allocator.free(retrieved);
        try std.testing.expectEqualStrings("spectrum scan=1 arrays=2\n  array=0 type=float64 count=3 first=100\n  array=1 type=float32 count=3 first=10\n", retrieved);
        const selected = try run(dir.dir, options.select, &.{ path, "MS:1000515" });
        defer std.testing.allocator.free(selected);
        try std.testing.expectEqualStrings("scan=1 MS:1000515 type=f32 count=3 first=10\n", selected);
        const streamed = try run(dir.dir, options.select, &.{ path, "MS:1000515", "--stream" });
        defer std.testing.allocator.free(streamed);
        try std.testing.expectEqualStrings(selected, streamed);
    }
    const missing = try run(dir.dir, options.indexed, &.{ "indexed.mzML", "missing" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("not found: missing\n", missing);
    try runFailing(dir.dir, options.indexed, &.{ "plain.mzML", "scan=1" }, error.MissingIndex, "plain.mzML");
    const original = try dir.dir.readFileAlloc(std.testing.io, "plain.mzML", std.testing.allocator, .limited(16 * 1024));
    defer std.testing.allocator.free(original);
    try runFailing(dir.dir, options.write, &.{"plain.mzML"}, error.PathAlreadyExists, null);
    const after = try dir.dir.readFileAlloc(std.testing.io, "plain.mzML", std.testing.allocator, .limited(16 * 1024));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(original, after);
}

test "[cli] - [mzml-rewrite]: rewrites list attributes and records without decoding payloads" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    inline for (.{
        support.REFERENCED_DOCUMENT,
        support.STREAM_EXTENSIONS,
        support.KNOWN_CHILDREN,
        support.REPEATED_CONTAINERS,
        support.HEADER ++ "<spectrumList count='1' sourceNote='A&amp;B' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' xsi:schemaLocation='urn:example list.xsd'>" ++
            support.SPECTRUM ++ "</spectrumList><chromatogramList count='0' defaultDataProcessingRef='' sourceNote=''/></run></mzML>",
        support.HEADER ++ "<spectrumList count='0' defaultDataProcessingRef='dp'/><chromatogramList count='0' defaultDataProcessingRef='dp'/></run></mzML>",
        support.HEADER ++ "<spectrumList count='0' defaultDataProcessingRef='dp'/><chromatogramList count='1' defaultDataProcessingRef='dp'>" ++
            "<chromatogram id='tic' index='0' defaultArrayLength='1'>" ++ support.ARRAYS ++ "</chromatogram></chromatogramList></run></mzML>",
        support.HEADER ++ "</run></mzML>",
    }, 0..) |source, i| {
        try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = source });
        const path = std.fmt.comptimePrint("copy{d}.mzML", .{i});
        const rewritten = try run(dir.dir, options.rewrite, &.{ "input.mzML", path });
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
        while (try before.nextItem()) |item|
            try support.expectItem(item, (try after.nextItem()).?);
        try std.testing.expectEqual(null, try after.nextItem());
        inline for (.{ "spectrum_list", "chromatogram_list" }) |field| {
            const expected = @field(before_header, field);
            const actual = @field(after_header, field);
            try std.testing.expectEqual(expected == null, actual == null);
            if (expected) |list| try std.testing.expectEqualDeep(list, actual.?);
        }
    }
}

test "[cli] - [mzml-rewrite]: filtering and reencoding retain surrounding XML" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = support.STREAM_EXTENSIONS });
    inline for (.{ "--ms1", "--zlib" }, 0..) |mode, i| {
        const path = std.fmt.comptimePrint("mode{d}.mzML", .{i});
        const result = try run(dir.dir, options.rewrite, &.{ "input.mzML", path, mode });
        defer std.testing.allocator.free(result);
        const bytes = try dir.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(16 * 1024));
        defer std.testing.allocator.free(bytes);
        var a_input = std.Io.Reader.fixed(support.STREAM_EXTENSIONS);
        var a = try mzml.StreamReader.init(std.testing.allocator, &a_input, .{});
        defer a.deinit();
        var b_input = std.Io.Reader.fixed(bytes);
        var b = try mzml.StreamReader.init(std.testing.allocator, &b_input, .{});
        defer b.deinit();
        var records: usize = 0;
        var fragments: usize = 0;
        while (try a.nextItem()) |expected| {
            if (expected != .xml) continue;
            while (try b.nextItem()) |actual| {
                if (actual == .record) records += 1;
                if (actual == .xml) {
                    try support.expectItem(expected, actual);
                    fragments += 1;
                    break;
                }
            } else return error.MissingXml;
        }
        try std.testing.expectEqual(@as(usize, if (i == 0) 1 else 3), records);
        try std.testing.expectEqual(@as(usize, 8), fragments);
        try std.testing.expectEqual(null, try b.nextItem());
    }
}

test "[cli] - [mzml-rewrite]: replaces and removes ordered record parameters without changing other XML" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const source = @embedFile("data/ordered_metadata.mzML");
    const annotated = "<userParam name=\"note\" value=\"old\" type=\"xsd:string\" unitName=\"source unit\" e:extra=\"keep\">before<e:detail/>after</userParam>";
    const targets = [_][]const u8{ annotated, "<userParam name=\"note\"/>", "<userParam name=\"note\" value=\"\"/>", "<userParam name=\"\"/>" };
    const cases = [_]struct { args: []const []const u8, replacements: [4][]const u8 }{
        .{ .args = &.{ "--replace-user-param", "note", "A&B\"" }, .replacements = .{
            "<userParam name=\"note\" value=\"A&amp;B&quot;\" type=\"xsd:string\" unitName=\"source unit\" e:extra=\"keep\">before<e:detail/>after</userParam>",
            "<userParam name=\"note\" value=\"A&amp;B&quot;\"/>",
            "<userParam name=\"note\" value=\"A&amp;B&quot;\"/>",
            targets[3],
        } },
        .{ .args = &.{ "--remove-user-param", "note" }, .replacements = .{ "", "", "", targets[3] } },
        .{ .args = &.{ "--replace-user-param", "note", "" }, .replacements = .{
            "<userParam name=\"note\" value=\"\" type=\"xsd:string\" unitName=\"source unit\" e:extra=\"keep\">before<e:detail/>after</userParam>",
            targets[2],
            targets[2],
            targets[3],
        } },
        .{ .args = &.{ "--remove-user-param", "absent" }, .replacements = targets },
        .{ .args = &.{ "--remove-user-param", "" }, .replacements = .{ targets[0], targets[1], targets[2], "" } },
    };
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = source });
    for (cases) |case| {
        var expected = try std.testing.allocator.dupe(u8, source);
        defer std.testing.allocator.free(expected);
        for (targets, case.replacements) |old, new| {
            const changed = try std.mem.replaceOwned(u8, std.testing.allocator, expected, old, new);
            std.testing.allocator.free(expected);
            expected = changed;
        }
        const args = try std.mem.concat(std.testing.allocator, []const u8, &.{ &.{ "input.mzML", "edited.mzML" }, case.args });
        defer std.testing.allocator.free(args);
        const stdout = try run(dir.dir, options.rewrite, args);
        defer std.testing.allocator.free(stdout);
        try std.testing.expectEqualStrings("", stdout);
        const bytes = try dir.dir.readFileAlloc(std.testing.io, "edited.mzML", std.testing.allocator, .limited(16 * 1024));
        defer std.testing.allocator.free(bytes);
        var a_input = std.Io.Reader.fixed(expected);
        var a = try mzml.StreamReader.init(std.testing.allocator, &a_input, .{});
        defer a.deinit();
        var b_input = std.Io.Reader.fixed(bytes);
        var b = try mzml.StreamReader.init(std.testing.allocator, &b_input, .{});
        defer b.deinit();
        const header = try a.readHeader();
        try support.expectNode(header.document, (try b.readHeader()).document);
        try support.expectNode(header.run, (try b.readHeader()).run);
        while (try a.nextItem()) |item| try support.expectItem(item, (try b.nextItem()).?);
        try std.testing.expectEqual(null, try b.nextItem());
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = bytes }, .{});
        defer index.deinit();
        var decoded = mzml.DecodedArrays.init(std.testing.allocator, .{});
        defer decoded.deinit();
        var record = (try index.byIdDecoded(std.testing.allocator, "s0", &decoded)).?;
        defer record.deinit();
        try std.testing.expectEqualSlices(f64, &.{1}, decoded.get(0).?.values.float64);
        try std.testing.expectEqualDeep([_]usize{ 3, 1 }, index.counts);
        try dir.dir.deleteFile(std.testing.io, "edited.mzML");
    }
}

test "[cli] - [mzml-rewrite]: failed rewrites remove partial output and never overwrite input" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const source = support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'/></run></mzML>";
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = source });
    // The source declares one spectrum and holds none, so every valid rewrite fails at the list end.
    for ([_][]const []const u8{
        &.{ "input.mzML", "failed.mzML" },
        &.{ "input.mzML", "failed.mzML", "--replace-user-param", "note", "value" },
        &.{ "input.mzML", "failed.mzML", "--remove-user-param", "note" },
    }) |args| {
        try runFailing(dir.dir, options.rewrite, args, error.CountMismatch, "failed.mzML");
        try std.testing.expectError(error.FileNotFound, dir.dir.openFile(std.testing.io, "failed.mzML", .{}));
    }
    for ([_][]const []const u8{
        &.{ "input.mzML", "failed.mzML", "--replace-user-param", "note" },
        &.{ "input.mzML", "failed.mzML", "--remove-user-param" },
        &.{ "input.mzML", "failed.mzML", "--remove-user-param", "note", "extra" },
    }) |args| {
        try runFailing(dir.dir, options.rewrite, args, error.InvalidArguments, null);
        try std.testing.expectError(error.FileNotFound, dir.dir.openFile(std.testing.io, "failed.mzML", .{}));
    }
    try runFailing(dir.dir, options.rewrite, &.{ "input.mzML", "input.mzML" }, error.PathAlreadyExists, null);
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(source, try dir.dir.readFile(std.testing.io, "input.mzML", &buffer));
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "bad.mzML", .data = support.HEADER ++
        "<spectrumList count='1' defaultDataProcessingRef='dp'><spectrum index='0' id='scan=1' defaultArrayLength='1'>" ++
        "<binaryDataArrayList count='1'><binaryDataArray encodedLength='4'><referenceableParamGroupRef ref='encoding'/>" ++
        "<binary>!!!!</binary></binaryDataArray></binaryDataArrayList></spectrum></spectrumList></run></mzML>" });
    try runFailing(dir.dir, options.rewrite, &.{ "bad.mzML", "failed.mzML", "--zlib" }, error.InvalidCharacter, "bad.mzML");
    try std.testing.expectError(error.FileNotFound, dir.dir.openFile(std.testing.io, "failed.mzML", .{}));
}

test "[cli] - [mzml-rewrite]: reencodes all codecs without changing values or record metadata" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const repeated = try std.mem.replaceOwned(u8, std.testing.allocator, support.REFERENCED_DOCUMENT, "<referenceableParamGroupRef ref='encoding'/>", "<referenceableParamGroupRef ref='encoding'/><cvParam accession='MS:1000523' name='source label'/>" ++
        "<cvParam accession='MS:1000576' name='source codec label'/>");
    defer std.testing.allocator.free(repeated);
    for ([_][]const u8{
        @embedFile("data/writer_plain.mzML"),
        support.REFERENCED_DOCUMENT,
        repeated,
        support.HEADER ++ "<spectrumList count='1' sourceNote='keep'>" ++ support.SPECTRUM ++
            "</spectrumList><chromatogramList count='0' defaultDataProcessingRef=''/></run></mzML>",
    }) |source| {
        try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = source });
        const stdout = try run(dir.dir, options.rewrite, &.{ "input.mzML", "zlib.mzML", "--zlib" });
        defer std.testing.allocator.free(stdout);
        try std.testing.expectEqualStrings("", stdout);
        const bytes = try dir.dir.readFileAlloc(std.testing.io, "zlib.mzML", std.testing.allocator, .limited(64 * 1024));
        defer std.testing.allocator.free(bytes);
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = bytes }, .{});
        defer index.deinit();
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const header = try reader.readHeader();
        const document = index.header().document;
        try std.testing.expectEqualDeep(header.document.attributes, document.attributes);
        try std.testing.expectEqualDeep(header.document.params, document.params);
        try std.testing.expectEqual(header.document.children.len, document.children.len);
        for (header.document.children, document.children) |expected, actual| {
            if (expected.kind != .referenceable_param_group_list) {
                try support.expectNode(expected, actual);
                continue;
            }
            try std.testing.expectEqual(expected.children.len + 4, actual.children.len);
            try std.testing.expectEqual(actual.children.len, try mzml.cv.parseInteger(usize, actual.attribute("count")));
            try std.testing.expectEqual(expected.attributes.len, actual.attributes.len);
            for (expected.attributes, actual.attributes) |left, right| {
                try std.testing.expectEqualStrings(left.name, right.name);
                if (!std.mem.eql(u8, left.name, "count")) try std.testing.expectEqualDeep(left, right);
            }
            var original = actual;
            original.attributes = expected.attributes;
            original.children = actual.children[0..expected.children.len];
            try support.expectNode(expected, original);
            inline for (.{
                .{ "MS:1000521", "32-bit float", "zmz-reencoded-0" },
                .{ "MS:1000523", "64-bit float", "zmz-reencoded-1" },
                .{ "MS:1000519", "32-bit integer", "zmz-reencoded-2" },
                .{ "MS:1000522", "64-bit integer", "zmz-reencoded-3" },
            }, 0..) |fields, i| {
                var replacement = expected.children[0];
                var params = [_]mzml.cv.Entry{ replacement.params[0], replacement.params[1] };
                params[0].cv.accession = .{ .raw = fields[0] };
                params[0].cv.name = fields[1];
                params[1].cv.accession = .{ .raw = "MS:1000574" };
                params[1].cv.name = "zlib compression";
                replacement.params = &params;
                replacement.attributes = &.{.{ .name = "id", .value = fields[2] }};
                try support.expectNode(replacement, actual.children[expected.children.len + i]);
            }
        }
        try support.expectNode(header.run, index.header().run);
        var before = mzml.DecodedArrays.init(std.testing.allocator, .{});
        defer before.deinit();
        var after = mzml.DecodedArrays.init(std.testing.allocator, .{});
        defer after.deinit();
        var ordinals = [_]usize{ 0, 0 };
        while (try reader.nextDecodedRecord(&before)) |record| {
            const kind: usize = if (record.node.kind == .spectrum) 0 else 1;
            var found = (try index.atDecoded(std.testing.allocator, record.node.kind, ordinals[kind], &after)).?;
            defer found.deinit();
            ordinals[kind] += 1;
            const actual = found.value;
            try std.testing.expectEqualDeep(record.node.attributes, actual.node.attributes);
            try std.testing.expectEqualDeep(record.node.params, actual.node.params);
            try std.testing.expectEqual(record.node.children.len, actual.node.children.len);
            for (record.node.children, actual.node.children) |a, b| {
                if (a.kind != .binary_data_array_list) {
                    try support.expectNode(a, b);
                } else try std.testing.expectEqualDeep(a.attributes, b.attributes);
            }
            try std.testing.expectEqual(before.len(), after.len());
            for (0..before.len()) |i| {
                const left = before.get(i).?;
                const right = after.get(i).?;
                try std.testing.expectEqual(.zlib, right.encoding.pipeline);
                try std.testing.expectEqual(std.meta.activeTag(left.values), std.meta.activeTag(right.values));
                switch (left.values) {
                    inline else => |values, tag| try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(values), std.mem.sliceAsBytes(@field(right.values, @tagName(tag)))),
                }
                var entries: mzml.cv.EffectiveIterator = .{ .entries = record.binaryArrays()[i].params, .groups = header.groups };
                var changed_entries: mzml.cv.EffectiveIterator = .{ .entries = actual.binaryArrays()[i].params, .groups = index.header().groups };
                while (try entries.next()) |entry| {
                    const changed = (try changed_entries.next()).?;
                    if (changed == .cv and changed.cv.accession != null and changed.cv.accession.?.eql(.{ .raw = "MS:1000574" })) {
                        try std.testing.expectEqualStrings("zlib compression", changed.cv.name.?);
                    } else try std.testing.expectEqualDeep(entry, changed);
                }
                try std.testing.expectEqual(null, try changed_entries.next());
            }
        }
        try std.testing.expectEqualDeep(ordinals, index.counts);
        var output = std.Io.Reader.fixed(bytes);
        var written = try mzml.StreamReader.init(std.testing.allocator, &output, .{ .payload = .skip });
        defer written.deinit();
        const written_header = try written.readHeader();
        while (try written.nextRecord()) |_| {}
        inline for (.{ "spectrum_list", "chromatogram_list" }) |field| {
            const expected = @field(header.*, field);
            const actual = @field(written_header.*, field);
            try std.testing.expectEqual(expected == null, actual == null);
            if (expected) |list| {
                try std.testing.expectEqualDeep(list.attributes, actual.?.attributes);
                try std.testing.expectEqual(list.declared_count, actual.?.declared_count);
            }
        }
        try dir.dir.deleteFile(std.testing.io, "zlib.mzML");
    }
}

test "[cli] - [mzml-rewrite]: filtering assigns missing indexes and retains attributes and references" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const indexed_source = support.HEADER ++ "<spectrumList count='3' sourceNote='A&amp;B'>" ++
        "<spectrum id='scan=0' index='0' defaultArrayLength='0'><cvParam accession='MS:1000511' value='2'/></spectrum>" ++
        "<spectrum id='scan=1' index='1' defaultArrayLength='1' dataProcessingRef='dp' spotID='kept'>" ++
        "<cvParam accession='MS:1000511' value='1'/>" ++ support.ARRAYS ++ "</spectrum>" ++
        "<spectrum id='scan=2' defaultArrayLength='1' index='2'><cvParam accession='MS:1000511' value='1'/>" ++
        "<scanList count='1'><scan spectrumRef='scan=0'/></scanList>" ++ support.ARRAYS ++ "</spectrum>" ++
        "</spectrumList><chromatogramList count='1' defaultDataProcessingRef='' sourceNote=''>" ++
        "<chromatogram id='tic' index='0' defaultArrayLength='1'>" ++ support.ARRAYS ++
        "</chromatogram></chromatogramList></run></mzML>";
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, indexed_source, " index='2'", "");
    defer std.testing.allocator.free(source);
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = source });
    try runFailing(dir.dir, options.rewrite, &.{ "input.mzML", "copy.mzML" }, error.MissingAttribute, "copy.mzML");
    try std.testing.expectError(error.FileNotFound, dir.dir.openFile(std.testing.io, "copy.mzML", .{}));
    const stdout = try run(dir.dir, options.rewrite, &.{ "input.mzML", "ms1.mzML", "--ms1" });
    defer std.testing.allocator.free(stdout);
    try std.testing.expectEqualStrings("", stdout);
    const bytes = try dir.dir.readFileAlloc(std.testing.io, "ms1.mzML", std.testing.allocator, .limited(16 * 1024));
    defer std.testing.allocator.free(bytes);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = bytes }, .{ .policy = .open_embedded });
    defer index.deinit();
    try std.testing.expectEqualDeep([2]usize{ 2, 1 }, index.counts);
    try std.testing.expectEqual(@as(usize, 2), index.header().spectrum_list.?.declared_count);
    try std.testing.expectEqual(null, try index.byId(std.testing.allocator, "scan=0"));
    var input = std.Io.Reader.fixed(indexed_source);
    var original = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer original.deinit();
    const header = try original.readHeader();
    var known_bytes: [8192]u8 = undefined;
    var known_sink = std.Io.Writer.fixed(&known_bytes);
    var known = try mzml.Writer.init(std.testing.allocator, &known_sink, .{});
    defer known.deinit();
    try known.writeHeader(header.*);
    try known.beginListWithAttributes(.spectrum_list, 2, header.spectrum_list.?.attributes);
    _ = try original.nextRecord();
    for ([_][]const u8{ "0", "1" }) |ordinal| {
        const record = (try original.nextRecord()).?;
        var expected = record.node;
        const attributes = try std.testing.allocator.dupe(mzml.model.Attribute, expected.attributes);
        defer std.testing.allocator.free(attributes);
        for (attributes) |*attribute| {
            if (std.mem.eql(u8, attribute.name, "index")) attribute.value = ordinal;
        }
        expected.attributes = attributes;
        try known.writeRecord(expected);
        var found = (try index.byId(std.testing.allocator, record.id)).?;
        defer found.deinit();
        try std.testing.expectEqual(try mzml.cv.parseInteger(usize, ordinal), found.value.index.?);
        try support.expectNode(expected, found.value.node);
    }
    try known.endList();
    const chromatogram = (try original.nextRecord()).?;
    try known.beginListWithAttributes(.chromatogram_list, 1, header.chromatogram_list.?.attributes);
    try known.writeRecord(chromatogram.node);
    try known.endList();
    try known.finish();
    var before_input = std.Io.Reader.fixed(known_sink.buffered());
    var before = try mzml.StreamReader.init(std.testing.allocator, &before_input, .{});
    defer before.deinit();
    var after_input = std.Io.Reader.fixed(bytes);
    var after = try mzml.StreamReader.init(std.testing.allocator, &after_input, .{});
    defer after.deinit();
    while (try before.nextRecord()) |record|
        try support.expectNode(record.node, (try after.nextRecord()).?.node);
    try std.testing.expectEqual(null, try after.nextRecord());
    inline for (.{ "spectrum_list", "chromatogram_list" }) |field| {
        const expected = @field(header.*, field).?;
        const actual = @field(index.header().*, field).?;
        try std.testing.expectEqualDeep(expected.attributes[1..], actual.attributes[1..]);
    }
}
