//! Shared fixtures and helpers for the mzML integration suites.

const std = @import("std");
const mzml = @import("zmz").mzml;

pub const HISTORICAL = @embedFile("data/historical.mzML");
pub const EXTENSIONS = @embedFile("data/extensions.mzML");
pub const STREAM_EXTENSIONS = @embedFile("data/stream_extensions.mzML");
pub const KNOWN_CHILDREN = @embedFile("data/known_children.mzML");
pub const REPEATED_CONTAINERS = @embedFile("data/repeated_containers.mzML");

pub const HEADER =
    "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.1.0' id='example'>" ++
    "<cvList count='1'><cv id='MS' fullName='PSI-MS' URI='urn:test' version=''/></cvList>" ++
    "<fileDescription><fileContent><cvParam cvRef='MS' accession='X:future' name='A&amp;B' value=''/></fileContent></fileDescription>" ++
    "<referenceableParamGroupList count='1'><referenceableParamGroup id='encoding'>" ++
    "<cvParam cvRef='MS' accession='MS:1000523' name='64-bit float'/>" ++
    "<cvParam cvRef='MS' accession='MS:1000576' name='no compression'/>" ++
    "</referenceableParamGroup></referenceableParamGroupList>" ++
    "<softwareList count='1'><software id='sw' version='1'/></softwareList>" ++
    "<instrumentConfigurationList count='1'><instrumentConfiguration id='ic'/></instrumentConfigurationList>" ++
    "<dataProcessingList count='1'><dataProcessing id='dp'><processingMethod order='0' softwareRef='sw'/></dataProcessing></dataProcessingList>" ++
    "<run id='r' defaultInstrumentConfigurationRef='ic'>";
pub const ARRAYS =
    "<binaryDataArrayList count='2'>" ++
    "<binaryDataArray encodedLength='12'><referenceableParamGroupRef ref='encoding'/>" ++
    "<cvParam cvRef='MS' accession='X:unknown-role' name='future array'/>" ++
    "<binary>AAAA<![CDATA[AAAA]]>8D8&#61;</binary></binaryDataArray>" ++
    "<binaryDataArray encodedLength='12' arrayLength='1'><referenceableParamGroupRef ref='encoding'/>" ++
    "<binary>AAAAAAAA8D8=</binary></binaryDataArray></binaryDataArrayList>";
pub const SPECTRUM = "<spectrum id='native=a&amp;b' index='0' defaultArrayLength='1'>" ++
    "<scanList count='1'><scan><scanWindowList count='1'><scanWindow/></scanWindowList></scan></scanList>" ++
    "<precursorList count='1'><precursor spectrumRef='earlier'><selectedIonList count='1'>" ++
    "<selectedIon><userParam name='note' value=''/></selectedIon></selectedIonList><activation/></precursor></precursorList>" ++
    "<productList count='1'><product><isolationWindow/></product></productList>" ++ ARRAYS ++ "</spectrum>";
pub const DOCUMENT = HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'>" ++ SPECTRUM ++
    "</spectrumList><chromatogramList count='1' defaultDataProcessingRef='dp'>" ++
    "<chromatogram id='tic' index='0' defaultArrayLength='1'>" ++ ARRAYS ++
    "</chromatogram></chromatogramList></run></mzML>";

pub const REFERENCED_DOCUMENT = HEADER ++ "<spectrumList count='2' defaultDataProcessingRef='dp'>" ++
    "<spectrum id='scan=1' index='0' defaultArrayLength='1' dataProcessingRef='dp'>" ++
    "<scanList count='1'><scan spectrumRef='scan=2' instrumentConfigurationRef='ic'/></scanList>" ++
    "<precursorList count='1'><precursor spectrumRef='scan=2'><selectedIonList count='1'>" ++
    "<selectedIon><userParam name='quantity' unitCvRef='MS'/></selectedIon></selectedIonList><activation/>" ++
    "</precursor></precursorList>" ++ ARRAYS ++ "</spectrum>" ++
    "<spectrum id='scan=2' index='1' defaultArrayLength='0'/></spectrumList>" ++
    "<chromatogramList count='1' defaultDataProcessingRef='dp'>" ++
    "<chromatogram id='tic' index='0' defaultArrayLength='1' dataProcessingRef='dp'>" ++
    "<precursor spectrumRef='scan=1'><activation/></precursor>" ++ ARRAYS ++
    "</chromatogram></chromatogramList></run></mzML>";

// Links nodes into one chain, each the only child of the one before, and returns the outermost.
pub fn nest(nodes: []mzml.model.Node) mzml.model.Node {
    var index = nodes.len - 1;
    nodes[index] = .{ .kind = .scan };
    while (index != 0) : (index -= 1) nodes[index - 1] = .{ .kind = .scan, .children = nodes[index..][0..1] };
    return nodes[0];
}

pub fn expectItem(expected: mzml.model.Item, actual: mzml.model.Item) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .record => |record| try expectNode(record.node, actual.record.node),
        .xml => |bytes| try std.testing.expectEqualStrings(bytes, actual.xml),
        .list_start => |start| try std.testing.expectEqualDeep(start, actual.list_start),
        else => {},
    }
}

// Writes source as UTF-16 with a byte-order mark into output[0 .. 2 + 2 * source.len].
pub fn utf16(output: []u8, source: []const u8, endian: std.builtin.Endian) void {
    std.mem.writeInt(u16, output[0..2], 0xfeff, endian);
    for (source, 0..) |byte, i| std.mem.writeInt(u16, output[2 + 2 * i ..][0..2], byte, endian);
}

pub fn readAll(allocator: std.mem.Allocator, bytes: []const u8, options: mzml.StreamReader.Options) !void {
    var input = std.Io.Reader.fixed(bytes);
    var reader = try mzml.StreamReader.init(allocator, &input, options);
    defer reader.deinit();
    _ = try reader.readHeader();
    while (try reader.nextRecord()) |_| {}
}

pub fn expectNode(expected: mzml.model.Node, actual: mzml.model.Node) !void {
    try std.testing.expectEqual(expected.kind, actual.kind);
    try std.testing.expectEqualDeep(expected.attributes, actual.attributes);
    try std.testing.expectEqualDeep(expected.params, actual.params);
    try std.testing.expectEqualDeep(expected.text, actual.text);
    try std.testing.expectEqualDeep(expected.content, actual.content);
    try std.testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |a, b| try expectNode(a, b);
}

pub fn rewriteDocument(allocator: std.mem.Allocator, source: []const u8, sink: *std.Io.Writer, indexed: bool) !void {
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var writer = if (indexed) try mzml.Writer.initIndexed(allocator, sink, .{}, .{}) else try mzml.Writer.init(allocator, sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header.*);
    while (try reader.nextItem()) |item| try writer.writeItem(item);
    try writer.finish();
}

pub fn constructFixture(allocator: std.mem.Allocator, sink: *std.Io.Writer, indexed: bool, pipelines: []const mzml.arrays.Pipeline) !void {
    var input = std.Io.Reader.fixed(DOCUMENT);
    var reader = try mzml.StreamReader.init(allocator, &input, .{});
    defer reader.deinit();
    var metadata = mzml.Builder.init(allocator, .{});
    defer metadata.deinit();
    var encoder = mzml.arrays.Encoder.init(allocator, .fast);
    defer encoder.deinit();
    var source_header = (try reader.readHeader()).*;
    var metadata_nodes: [8]mzml.model.Node = undefined;
    @memcpy(metadata_nodes[0..source_header.document.children.len], source_header.document.children);
    const group: mzml.model.Node = .{ .kind = .referenceable_param_group, .attributes = &.{.{ .name = "id", .value = "record-type" }}, .params = &.{.{ .cv = .{ .cv_ref = "MS", .accession = mzml.model.Terms.MS_LEVEL, .name = "ms level", .value = "1" } }} };
    for (metadata_nodes[0..source_header.document.children.len]) |*node| {
        if (node.kind == .referenceable_param_group_list)
            node.* = try metadata.list(.referenceable_param_group_list, &.{ node.children[0], group });
    }
    source_header.document.children = metadata_nodes[0..source_header.document.children.len];
    const header = try metadata.header(source_header);
    var builder = mzml.Builder.init(allocator, .{});
    defer builder.deinit();
    var writer = if (indexed) try mzml.Writer.initIndexed(allocator, sink, .{}, .{}) else try mzml.Writer.init(allocator, sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header);
    inline for (.{ mzml.model.Kind.spectrum_list, mzml.model.Kind.chromatogram_list }) |list_kind| {
        try writer.beginList(list_kind, pipelines.len, "dp");
        for (pipelines, 0..) |pipeline, index| {
            builder.reset();
            encoder.reset();
            const options: mzml.arrays.EncodeOptions = .{ .pipeline = pipeline, .fixed_point = switch (pipeline) {
                .linear, .linear_zlib => 1000,
                .slof, .slof_zlib => 10000,
                else => null,
            } };
            var nodes: [2]mzml.Builder.Array = undefined;
            var payloads: [2]mzml.Writer.ArrayPayload = undefined;
            inline for (0..2) |i| {
                const array_options: mzml.Builder.ArrayOptions = .{
                    .cv_ref = "MS",
                    .encoding = options,
                    .role = .{
                        .cv_ref = "MS",
                        .accession = if (i == 1) mzml.model.Terms.INTENSITY_ARRAY else if (list_kind == .spectrum_list) mzml.model.Terms.MZ_ARRAY else mzml.model.Terms.TIME_ARRAY,
                        .name = if (i == 1) "intensity array" else if (list_kind == .spectrum_list) "m/z array" else "time array",
                    },
                };
                const built = try builder.prepareArray(f64, &.{ 1, 2, 3 }, array_options, &encoder);
                nodes[i] = built.array;
                payloads[i] = built.payload;
            }
            var id: [64]u8 = undefined;
            const record = try builder.record(if (list_kind == .spectrum_list) .spectrum else .chromatogram, try std.fmt.bufPrint(&id, "{s}={s}", .{ if (list_kind == .spectrum_list) "scan" else "chromatogram", @tagName(pipeline) }), index, 3, if (list_kind == .spectrum_list) &.{.{ .group_ref = .{ .ref = "record-type" } }} else &.{}, &.{}, &nodes);
            try writer.writeRecordWithArrays(record.node, &payloads);
        }
        try writer.endList();
    }
    try writer.finish();
}

// Checks written mzML against a frozen fixture without depending on the zlib encoder's bytes.
// Both documents must match after encoderIndependent, and an indexed output must carry
// offsets and a checksum that are correct for its own bytes.
pub fn expectWritten(expected: []const u8, actual: []const u8) !void {
    const allocator = std.testing.allocator;
    const expected_view = try encoderIndependent(allocator, expected);
    defer allocator.free(expected_view);
    const actual_view = try encoderIndependent(allocator, actual);
    defer allocator.free(actual_view);
    try std.testing.expectEqualStrings(expected_view, actual_view);
    if (std.mem.indexOf(u8, actual, "<fileChecksum>") == null) return;
    try expectCompleteIndexed(actual);
    const hashed = try checksumStart(actual);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(actual[0..hashed], &digest, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), actual[hashed..][0..40]);
    var embedded = try mzml.IndexedReader.build(allocator, .{ .bytes = actual }, .{});
    defer embedded.deinit();
    var rebuilt = try mzml.IndexedReader.build(allocator, .{ .bytes = actual }, .{ .policy = .rebuild });
    defer rebuilt.deinit();
    try std.testing.expectEqual(rebuilt.entries().len, embedded.entries().len);
    for (rebuilt.entries(), embedded.entries()) |found, listed| {
        try std.testing.expectEqualStrings(found.id, listed.id);
        try std.testing.expectEqual(found.start, listed.start);
    }
}

pub fn checksumStart(bytes: []const u8) !usize {
    const tag = "<fileChecksum>";
    const start = (std.mem.indexOf(u8, bytes, tag) orelse return error.TestUnexpectedResult) + tag.len;
    if (bytes.len - start < 40 + "</fileChecksum>".len or
        !std.mem.startsWith(u8, bytes[start + 40 ..], "</fileChecksum>")) return error.TestUnexpectedResult;
    return start;
}

pub fn expectEncodedLengths(document: []const u8) !void {
    var at: usize = 0;
    var arrays: usize = 0;
    while (std.mem.indexOfPos(u8, document, at, "<binaryDataArray ")) |tag| {
        const length = (std.mem.indexOfPos(u8, document, tag, "encodedLength=\"") orelse return error.TestUnexpectedResult) + "encodedLength=\"".len;
        const length_end = std.mem.indexOfScalarPos(u8, document, length, '"') orelse return error.TestUnexpectedResult;
        const text = (std.mem.indexOfPos(u8, document, tag, "<binary>") orelse return error.TestUnexpectedResult) + "<binary>".len;
        const text_end = std.mem.indexOfPos(u8, document, text, "</binary>") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(text_end - text, try std.fmt.parseInt(usize, document[length..length_end], 10));
        arrays += 1;
        at = text_end;
    }
    try std.testing.expect(arrays != 0);
}

// Indexed output must end with its wrapper, so a lost final flush fails here.
pub fn expectCompleteIndexed(bytes: []const u8) !void {
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, bytes, "\n"), "</fileChecksum></indexedmzML>"));
}

pub fn writeSingleRecord(allocator: std.mem.Allocator, sink: *std.Io.Writer, header: mzml.model.Header, record: mzml.model.Node, indexed: bool, arrays: ?[]const mzml.Writer.ArrayPayload) !void {
    var writer = if (indexed) try mzml.Writer.initIndexed(allocator, sink, .{}, .{}) else try mzml.Writer.init(allocator, sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header);
    try writer.beginList(.spectrum_list, 1, "dp");
    if (arrays) |wire| try writer.writeRecordWithArrays(record, wire) else try writer.writeRecord(record);
    try writer.endList();
    try writer.finish();
}

// Pipelines whose wire bytes are one zlib stream.
const ZLIB_PIPELINES = [_][]const u8{ "MS:1000574", "MS:1002746", "MS:1002747", "MS:1002748" };

// Copies a document, replacing each zlib stream with the hex of its decoded bytes and each value
// that follows from compressed sizes (zlib encodedLength, index offsets, checksum) with '#'.
// Every stream must decode to the same bytes with zmz and with the standard library.
fn encoderIndependent(allocator: std.mem.Allocator, document: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, document, at, '<')) |tag| {
        const rest = document[tag..];
        if (std.mem.startsWith(u8, rest, "<binaryDataArray ")) {
            const text = (std.mem.indexOfPos(u8, document, tag, "<binary>") orelse return error.TestUnexpectedResult) + "<binary>".len;
            const text_end = std.mem.indexOfPos(u8, document, text, "</binary>") orelse return error.TestUnexpectedResult;
            const declaration = document[tag..text];
            for (ZLIB_PIPELINES) |accession| {
                if (std.mem.indexOf(u8, declaration, accession) != null) break;
            } else {
                try out.appendSlice(allocator, document[at..text_end]);
                at = text_end;
                continue;
            }
            const length = (std.mem.indexOf(u8, declaration, "encodedLength=\"") orelse return error.TestUnexpectedResult) + "encodedLength=\"".len;
            const length_end = std.mem.indexOfScalarPos(u8, declaration, length, '"') orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(text_end - text, try std.fmt.parseInt(usize, declaration[length..length_end], 10));
            try out.appendSlice(allocator, document[at .. tag + length]);
            try out.append(allocator, '#');
            try out.appendSlice(allocator, document[tag + length_end .. text]);
            var wire: [512]u8 = undefined;
            const compressed = try mzml.base64.decode(&wire, document[text..text_end]);
            var reference: [512]u8 = undefined;
            var input = std.Io.Reader.fixed(compressed);
            var plain = std.Io.Writer.fixed(&reference);
            var inflater: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
            _ = try inflater.reader.streamRemaining(&plain);
            var decoded: [512]u8 = undefined;
            try std.testing.expectEqualSlices(u8, plain.buffered(), try mzml.zlib.decompress(&decoded, compressed));
            for (plain.buffered()) |byte| try out.print(allocator, "{x:0>2}", .{byte});
            at = text_end;
        } else if (try sizeDependentValue(rest)) |prefix| {
            try out.appendSlice(allocator, document[at .. tag + prefix]);
            try out.append(allocator, '#');
            at = std.mem.indexOfScalarPos(u8, document, tag + prefix, '<') orelse return error.TestUnexpectedResult;
        } else {
            try out.appendSlice(allocator, document[at .. tag + 1]);
            at = tag + 1;
        }
    }
    try out.appendSlice(allocator, document[at..]);
    return out.toOwnedSlice(allocator);
}

fn sizeDependentValue(tag: []const u8) !?usize {
    inline for (.{ "<indexListOffset>", "<fileChecksum>" }) |open| {
        if (std.mem.startsWith(u8, tag, open)) return open.len;
    }
    if (std.mem.startsWith(u8, tag, "<offset ")) return (std.mem.indexOfScalar(u8, tag, '>') orelse return error.TestUnexpectedResult) + 1;
    return null;
}
