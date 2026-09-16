//! Shared fixtures and helpers for the mzML integration suites.

const std = @import("std");
const mzml = @import("zmz").mzml;

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

// --- Shared helpers ---

pub fn readAll(allocator: std.mem.Allocator, bytes: []const u8, options: mzml.StreamReader.Options) !void {
    var input = std.Io.Reader.fixed(bytes);
    var reader = try mzml.StreamReader.init(allocator, &input, options);
    defer reader.deinit();
    _ = try reader.readHeader();
    while (try reader.nextRecord()) |_| {}
}

pub fn rewriteFixture(allocator: std.mem.Allocator, sink: *std.Io.Writer) !void {
    var input = std.Io.Reader.fixed(DOCUMENT);
    var reader = try mzml.StreamReader.init(allocator, &input, .{});
    defer reader.deinit();
    var writer = try mzml.Writer.init(allocator, sink, .{});
    defer writer.deinit();
    const header = try reader.readHeader();
    try writer.writeHeader(header.*);
    try writer.beginList(.spectrum_list, 1, "dp");
    try writer.writeRecord((try reader.nextRecord()).?.node);
    try writer.endList();
    try writer.beginList(.chromatogram_list, 1, "dp");
    try writer.writeRecord((try reader.nextRecord()).?.node);
    try writer.endList();
    try std.testing.expectEqual(null, try reader.nextRecord());
    try writer.finish();
}

pub fn expectNode(expected: mzml.model.Node, actual: mzml.model.Node) !void {
    try std.testing.expectEqual(expected.kind, actual.kind);
    try std.testing.expectEqualDeep(expected.attributes, actual.attributes);
    try std.testing.expectEqualDeep(expected.params, actual.params);
    try std.testing.expectEqualDeep(expected.text, actual.text);
    try std.testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |a, b| try expectNode(a, b);
}

pub fn rewriteAllocated(allocator: std.mem.Allocator) !void {
    var bytes: [8192]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    try rewriteFixture(allocator, &sink);
}

pub fn rewriteDocument(allocator: std.mem.Allocator, source: []const u8, sink: *std.Io.Writer, indexed: bool) !void {
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var writer = if (indexed) try mzml.Writer.initIndexed(allocator, sink, .{}, .{}) else try mzml.Writer.init(allocator, sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header.*);
    var current = try reader.nextRecord();
    inline for (.{ mzml.model.Kind.spectrum_list, mzml.model.Kind.chromatogram_list }) |kind| {
        const list = if (kind == .spectrum_list) header.spectrum_list else header.chromatogram_list;
        if (list) |descriptor| {
            const opening: mzml.model.Node = .{ .kind = kind, .attributes = descriptor.attributes };
            try writer.beginList(kind, descriptor.declared_count, opening.attribute("defaultDataProcessingRef").?);
            while (current) |record| {
                if (record.node.kind != (if (kind == .spectrum_list) mzml.model.Kind.spectrum else .chromatogram)) break;
                try writer.writeRecord(record.node);
                current = try reader.nextRecord();
            }
            try writer.endList();
        }
    }
    try std.testing.expectEqual(null, current);
    try writer.finish();
}

pub fn indexedRewriteAllocated(allocator: std.mem.Allocator) !void {
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try rewriteDocument(allocator, REFERENCED_DOCUMENT, &discard.writer, true);
}

pub fn constructFixture(allocator: std.mem.Allocator, sink: *std.Io.Writer, indexed: bool, pipelines: []const mzml.arrays.Pipeline, prepared: bool) !void {
    var input = std.Io.Reader.fixed(DOCUMENT);
    var reader = try mzml.StreamReader.init(allocator, &input, .{});
    defer reader.deinit();
    var metadata = mzml.Builder.init(allocator, .{});
    defer metadata.deinit();
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
    var compressor = try mzml.zlib.Compressor.init(allocator, .fastest);
    defer compressor.deinit();
    var writer = if (indexed) try mzml.Writer.initIndexed(allocator, sink, .{}, .{}) else try mzml.Writer.init(allocator, sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header);
    inline for (.{ mzml.model.Kind.spectrum_list, mzml.model.Kind.chromatogram_list }) |list_kind| {
        try writer.beginList(list_kind, pipelines.len, "dp");
        for (pipelines, 0..) |pipeline, index| {
            builder.reset();
            var encoded: [1024]u8 = undefined;
            var transport: [512]u8 = undefined;
            var transformed: [512]u8 = undefined;
            const options: mzml.arrays.EncodeOptions = .{ .pipeline = pipeline, .fixed_point = switch (pipeline) {
                .linear, .linear_zlib => 1000,
                .slof, .slof_zlib => 10000,
                else => null,
            } };
            var nodes: [2]mzml.Builder.Array = undefined;
            var wires: [2][]const u8 = undefined;
            var prepared_transport: [2][512]u8 = undefined;
            var prepared_transformed: [2][512]u8 = undefined;
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
                if (prepared) {
                    const built = try builder.prepareArray(f64, &.{ 1, 2, 3 }, array_options, .{ .transport = &prepared_transport[i], .transformed = &prepared_transformed[i] }, &compressor);
                    nodes[i] = built.array;
                    wires[i] = built.wire;
                } else nodes[i] = try builder.binaryArray(f64, &.{ 1, 2, 3 }, array_options, &encoded, .{ .transport = &transport, .transformed = &transformed }, &compressor);
            }
            var id: [64]u8 = undefined;
            const build_record: *const @TypeOf(mzml.Builder.record) = if (prepared) mzml.Builder.preparedRecord else mzml.Builder.record;
            const record = try build_record(&builder, if (list_kind == .spectrum_list) .spectrum else .chromatogram, try std.fmt.bufPrint(&id, "{s}={s}", .{ if (list_kind == .spectrum_list) "scan" else "chromatogram", @tagName(pipeline) }), index, 3, if (list_kind == .spectrum_list) &.{.{ .group_ref = "record-type" }} else &.{}, &.{}, &nodes);
            if (prepared) {
                try writer.writeRecordWithArrays(record.node, &wires);
            } else try writer.writeRecord(record.node);
        }
        try writer.endList();
    }
    try writer.finish();
}

pub fn constructAllocated(allocator: std.mem.Allocator, prepared: bool) !void {
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try constructFixture(allocator, &discard.writer, true, std.meta.tags(mzml.arrays.Pipeline), prepared);
}

pub fn checkIndexed(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{});
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 16), index.entries.items.len);
    try std.testing.expectEqual(@as(usize, 8), index.header().spectrum_list.?.observed_count);
    for ([_]usize{ 15, 0, 7, 8, 6 }) |position| {
        const entry = index.entries.items[position];
        var record = (try index.byId(allocator, entry.id)).?;
        defer record.deinit();
        try std.testing.expectEqualStrings(entry.id, record.value.id);
        try std.testing.expectEqual(entry.start, record.value.node.start_offset);
        try std.testing.expectEqual(entry.end, record.value.node.end_offset);
        try std.testing.expectEqual(@as(usize, 2), record.value.binaryArrays().len);
        var ordinal = (try index.at(allocator, entry.kind, entry.index)).?;
        defer ordinal.deinit();
        try expectNode(record.value.node, ordinal.value.node);
        for (record.value.binaryArrays()) |array| {
            var output: [3]f64 = undefined;
            var transport: [128]u8 = undefined;
            var transformed: [128]u8 = undefined;
            try mzml.model.decodeArray(f64, &output, array, 3, index.header().groups, .{ .transport = &transport, .transformed = &transformed }, .{});
            for (output, [_]f64{ 1, 2, 3 }) |value, expected| try std.testing.expectApproxEqAbs(expected, value, 0.001);
        }
    }
    try std.testing.expectEqual(null, try index.byId(allocator, "missing"));
    try std.testing.expectEqual(null, try index.at(allocator, .spectrum, 8));
}

pub fn checkLookupAllocator(record_allocator: std.mem.Allocator) !void {
    var retained = blk: {
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = @embedFile("data/writer_indexed.mzML") }, .{ .policy = .open_embedded });
        defer index.deinit();
        var first = (try index.at(std.testing.allocator, .spectrum, 0)).?;
        errdefer first.deinit();
        var last = (index.at(record_allocator, .chromatogram, 7) catch |err| {
            var recovered = (try index.at(std.testing.allocator, .spectrum, 1)).?;
            defer recovered.deinit();
            try std.testing.expectEqualStrings("scan=zlib", recovered.value.id);
            try std.testing.expectEqualStrings("scan=none", first.value.id);
            return err;
        }).?;
        defer last.deinit();
        try std.testing.expectEqualStrings("chromatogram=slof_zlib", last.value.id);
        try std.testing.expectEqualStrings("scan=none", first.value.id);
        break :blk first;
    };
    defer retained.deinit();
    try std.testing.expectEqualStrings("scan=none", retained.value.id);
    var values: [3]f64 = undefined;
    var transport: [128]u8 = undefined;
    try mzml.model.decodeArray(f64, &values, retained.value.binaryArrays()[0], 3, &.{}, .{ .transport = &transport, .transformed = &.{} }, .{});
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, &values);
}

pub fn checkOpenEmbedded(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .policy = .open_embedded });
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 16), index.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), index.header().spectrum_list.?.observed_count);
    try std.testing.expectEqual(@as(usize, 0), index.header().chromatogram_list.?.observed_count);
    for (index.entries.items) |entry| {
        var record = (try index.at(allocator, entry.kind, entry.index)).?;
        defer record.deinit();
        try std.testing.expectEqualStrings(entry.id, record.value.id);
        try std.testing.expectEqual(entry.start, record.value.node.start_offset);
        try std.testing.expect(record.value.node.end_offset <= entry.end);
        for (record.value.binaryArrays()) |array| {
            var values: [3]f64 = undefined;
            var transport: [128]u8 = undefined;
            var transformed: [128]u8 = undefined;
            try mzml.model.decodeArray(f64, &values, array, 3, index.header().groups, .{ .transport = &transport, .transformed = &transformed }, .{});
            for (values, [_]f64{ 1, 2, 3 }) |value, expected| try std.testing.expectApproxEqAbs(expected, value, 0.001);
        }
    }
}

pub fn copyRetained(allocator: std.mem.Allocator) !void {
    var input = std.Io.Reader.fixed(DOCUMENT);
    var header: mzml.owned.Header = undefined;
    var record: mzml.owned.Record = undefined;
    {
        var reader = try mzml.StreamReader.init(allocator, &input, .{});
        defer reader.deinit();
        const source_header = try reader.readHeader();
        const source_record = (try reader.nextRecord()).?;
        header = try mzml.owned.Header.init(allocator, source_header.*, .{});
        errdefer header.deinit();
        record = try mzml.owned.Record.init(allocator, source_record, .{});
        errdefer record.deinit();
        try expectNode(source_header.document, header.value.document);
        try expectNode(source_header.run, header.value.run);
        try std.testing.expectEqualDeep(source_header.groups, header.value.groups);
        try std.testing.expectEqualDeep(source_header.spectrum_list, header.value.spectrum_list);
        try expectNode(source_record.node, record.value.node);
        try std.testing.expectEqual(source_record.node.start_offset, record.value.node.start_offset);
        try std.testing.expectEqual(source_record.node.end_offset, record.value.node.end_offset);
        while (try reader.nextRecord()) |_| {}
    }
    defer header.deinit();
    defer record.deinit();
    try std.testing.expectEqualStrings("native=a&b", record.value.id);
    try std.testing.expectEqualStrings("A&B", header.value.document.child(.file_description).?.child(.file_content).?.params[0].cv.name.?);
    var output: [1]f64 = undefined;
    var transport: [16]u8 = undefined;
    var transformed: [16]u8 = undefined;
    for (record.value.binaryArrays()) |array| {
        try mzml.model.decodeArray(f64, &output, array, record.value.default_array_length, header.value.groups, .{
            .transport = &transport,
            .transformed = &transformed,
        }, .{});
        try std.testing.expectEqual(@as(f64, 1), output[0]);
    }
}

pub fn writeSingleRecord(allocator: std.mem.Allocator, sink: *std.Io.Writer, header: mzml.model.Header, record: mzml.model.Node, indexed: bool, arrays: ?[]const []const u8) !void {
    var writer = if (indexed) try mzml.Writer.initIndexed(allocator, sink, .{}, .{}) else try mzml.Writer.init(allocator, sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header);
    try writer.beginList(.spectrum_list, 1, "dp");
    if (arrays) |wire| try writer.writeRecordWithArrays(record, wire) else try writer.writeRecord(record);
    try writer.endList();
    try writer.finish();
}

pub fn expectMinimalRead(bytes: []const u8, payload: mzml.StreamReader.Payload) !void {
    var expected_input = std.Io.Reader.fixed(bytes);
    var expected = try mzml.StreamReader.init(std.testing.allocator, &expected_input, .{ .payload = payload, .retain_index = true });
    defer expected.deinit();
    var buffer: [7]u8 = undefined;
    var actual_input: std.testing.Reader = .init(&buffer, &.{.{ .buffer = bytes }});
    actual_input.artificial_limit = .limited(buffer.len);
    var actual = try mzml.StreamReader.init(std.testing.allocator, &actual_input.interface, .{ .checks = .minimal, .payload = payload, .retain_index = true });
    defer actual.deinit();
    const expected_header = try expected.readHeader();
    const actual_header = try actual.readHeader();
    while (try expected.nextRecord()) |record| {
        try std.testing.expectEqualDeep(record, (try actual.nextRecord()).?);
    }
    try std.testing.expectEqual(null, try actual.nextRecord());
    try std.testing.expectEqualDeep(expected_header.*, actual_header.*);
    try std.testing.expectEqualDeep(expected.indexTrailer(), actual.indexTrailer());
}
