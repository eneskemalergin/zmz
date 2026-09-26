//! Tests checked construction and encoded array output.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

test "[integration] - [mzML extensions]: array replacement retains XML and late parameter order" {
    var input = std.Io.Reader.fixed(support.EXTENSIONS);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const original = (try reader.nextRecord()).?;
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    const values = [_]f64{ 5, 6 };
    const second = [_]f64{ 3, 4 };
    const scratch: mzml.arrays.Scratch = .{ .transport = &.{}, .transformed = &.{} };
    const first = try builder.prepareArrayFrom(f64, &values, original.binaryArrays()[0], header.groups, .{}, scratch, null);
    const other = try builder.prepareArrayFrom(f64, &second, original.binaryArrays()[1], header.groups, .{}, scratch, null);
    var array_list = original.node.child(.binary_data_array_list).?;
    array_list.children = &.{ first.array.node, other.array.node };
    var record = original.node;
    record.children = &.{ original.node.children[0], array_list };
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    var writer = try mzml.Writer.init(std.testing.allocator, &sink.writer, .{});
    defer writer.deinit();
    try writer.writeHeader(header.*);
    try writer.beginListWithAttributes(.spectrum_list, 1, header.spectrum_list.?.attributes);
    try writer.writeRecordWithArrays(record, &.{ first.wire, other.wire });
    try writer.endList();
    try writer.finish();
    const bytes = sink.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "e:array=\"keep\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "e:payload=\"keep\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "e:type=\"e:Primitive\"") != null);
    const units = std.mem.indexOf(u8, bytes, "<e:units").?;
    const binary = std.mem.indexOfPos(u8, bytes, units, "<binary").?;
    const late = std.mem.indexOf(u8, bytes, "name=\"late array note\"").?;
    try std.testing.expect(units < binary and binary < late);
    var copied = std.Io.Reader.fixed(bytes);
    var result = try mzml.StreamReader.init(std.testing.allocator, &copied, .{});
    defer result.deinit();
    var decoded = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer decoded.deinit();
    _ = (try result.nextDecodedRecord(&decoded)).?;
    try std.testing.expectEqualSlices(f64, &values, decoded.get(0).?.values.float64);
    try std.testing.expectEqualSlices(f64, &second, decoded.get(1).?.values.float64);
}

fn replaceArrayAllocated(allocator: std.mem.Allocator) !void {
    const params = [_]mzml.cv.Entry{
        .{ .cv = .{ .cv_ref = "MS", .accession = mzml.model.Terms.INTENSITY_ARRAY, .name = "intensity", .unit = .{ .name = "source unit" } } },
        .{ .cv = .{ .cv_ref = "MS", .accession = .{ .raw = "MS:1000523" }, .name = "64-bit float" } },
        .{ .cv = .{ .cv_ref = "MS", .accession = .{ .raw = "MS:1000576" }, .name = "no compression" } },
        .{ .user = .{ .name = "group note", .value = "keep" } },
    };
    const groups = [_]mzml.cv.Group{.{ .id = "encoding", .entries = &params }};
    const source: mzml.model.Node = .{
        .kind = .binary_data_array,
        .attributes = &.{
            .{ .name = "dataProcessingRef", .value = "array-processing" },
            .{ .name = "arrayLength", .value = "3" },
            .{ .name = "extra", .value = "keep" },
        },
        .params = &.{ .{ .group_ref = .{ .ref = "encoding" } }, .{ .user = .{ .name = "local note", .value = "" } } },
        .children = &.{.{ .kind = .binary, .attributes = &.{.{ .name = "extra", .value = "binary" }}, .text = "A" ** 8192 }},
    };
    var builder = mzml.Builder.init(allocator, .{ .bytes = 4096 });
    defer builder.deinit();
    var compressor = try mzml.zlib.Compressor.init(allocator, .fastest);
    defer compressor.deinit();
    try std.testing.expectError(error.MissingCompressor, builder.prepareArrayFrom(f32, &.{1}, source, &groups, .{ .pipeline = .zlib }, .{ .transport = &.{}, .transformed = &.{} }, null));
    var retry_scratch: [16]u8 = undefined;
    for (0..2) |_| try std.testing.expectError(error.OutputTooSmall, builder.prepareArrayFrom(f32, &.{1}, source, &groups, .{ .pipeline = .zlib }, .{ .transport = &.{}, .transformed = &retry_scratch }, &compressor));
    for ([_]mzml.arrays.Pipeline{ .none, .zlib }) |pipeline| {
        for ([_]usize{ 0, 2 }) |length| {
            builder.reset();
            const values = [_]f32{ 2, 4 };
            var wire: [128]u8 = undefined;
            var scratch: [128]u8 = undefined;
            const result = try builder.prepareArrayFrom(f32, values[0..length], source, &groups, .{ .pipeline = pipeline }, .{
                .transport = &wire,
                .transformed = &scratch,
            }, &compressor);
            try std.testing.expectEqual(length, result.array.length);
            try std.testing.expect(result.array.is_default);
            try std.testing.expectEqual(null, result.array.node.child(.binary).?.text);
            try std.testing.expectEqualDeep(source.children[0].attributes, result.array.node.children[0].attributes);
            try std.testing.expectEqualStrings("array-processing", result.array.node.attribute("dataProcessingRef").?);
            try std.testing.expect(source.attribute("dataProcessingRef").?.ptr != result.array.node.attribute("dataProcessingRef").?.ptr);
            try std.testing.expectEqualStrings("keep", result.array.node.attribute("extra").?);
            try std.testing.expectEqual(length, try mzml.cv.parseInteger(usize, result.array.node.attribute("arrayLength")));
            try std.testing.expectEqual(try mzml.base64.encodedSize(result.wire.len), try mzml.cv.parseInteger(usize, result.array.node.attribute("encodedLength")));
            try std.testing.expectEqualDeep(mzml.model.Encoding{ .primitive = .float32, .pipeline = pipeline }, try mzml.model.arrayEncoding(result.array.node, &.{}));
            try std.testing.expectEqual(@as(usize, 5), result.array.node.params.len);
            try std.testing.expectEqualDeep(params[0], result.array.node.params[0]);
            try std.testing.expectEqualDeep(params[3], result.array.node.params[3]);
            try std.testing.expectEqualDeep(source.params[1], result.array.node.params[4]);
            try std.testing.expectEqualStrings("MS:1000576", groups[0].entries[2].cv.accession.?.raw);
            var decoded: [2]f32 = undefined;
            try mzml.arrays.decodeWire(f32, decoded[0..length], result.wire, pipeline, &.{}, .{});
            try std.testing.expectEqualSlices(f32, values[0..length], decoded[0..length]);
        }
    }
}

test "[integration] - [array replacement]: preserves source metadata while changing values and encoding" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, replaceArrayAllocated, .{});
}

test "[integration] - [array replacement]: returns metadata and allocation errors without dropping children" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const source = (try reader.nextRecord()).?.binaryArrays()[0];
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    const scratch: mzml.arrays.Scratch = .{ .transport = &.{}, .transformed = &.{} };
    try std.testing.expectError(error.MissingGroup, builder.prepareArrayFrom(f64, &.{1}, source, &.{}, .{}, scratch, null));
    var extra_child = source;
    extra_child.children = &.{ source.children[0], .{ .kind = .binary } };
    try std.testing.expectError(error.InvalidStructure, builder.prepareArrayFrom(f64, &.{1}, extra_child, header.groups, .{}, scratch, null));
    var limited = mzml.Builder.init(std.testing.allocator, .{ .bytes = 1 });
    defer limited.deinit();
    try std.testing.expectError(error.LimitExceeded, limited.prepareArrayFrom(f64, &.{1}, source, header.groups, .{}, scratch, null));
}

test "[integration] - [record editing]: changes values and length while retaining source references" {
    const source = support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'>" ++
        "<spectrum id='scan=1' index='0' defaultArrayLength='1' dataProcessingRef='special' sourceFileRef='source' spotID='spot'>" ++
        "<userParam name='record note' value='keep'/><binaryDataArrayList count='1' extra='kept'>" ++
        "<binaryDataArray encodedLength='12' dataProcessingRef='array-processing'>" ++
        "<referenceableParamGroupRef ref='encoding'/>" ++
        "<cvParam cvRef='MS' accession='MS:1000515' name='intensity array'/>" ++
        "<userParam name='array note' value='keep'/><binary>AAAAAAAA8D8=</binary>" ++
        "</binaryDataArray></binaryDataArrayList></spectrum></spectrumList></run></mzML>";
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var decoded = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer decoded.deinit();
    const original = (try reader.nextDecodedRecord(&decoded)).?;
    const values = [_]f64{ decoded.get(0).?.values.float64[0] * 2, 3 };
    const old_array = original.binaryArrays()[0];
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var compressor = try mzml.zlib.Compressor.init(std.testing.allocator, .fastest);
    defer compressor.deinit();
    var wire_storage: [128]u8 = undefined;
    var transformed: [16]u8 = undefined;
    const prepared = try builder.prepareArrayFrom(f64, &values, old_array, header.groups, .{ .pipeline = .zlib }, .{
        .transport = &wire_storage,
        .transformed = &transformed,
    }, &compressor);
    try std.testing.expectEqual(null, prepared.array.node.attribute("arrayLength"));
    try std.testing.expectError(error.InvalidArrayLength, builder.preparedRecord(.spectrum, original.id, 0, 1, &.{}, &.{}, &.{prepared.array}));
    var attributes: [6]mzml.model.Attribute = undefined;
    @memcpy(&attributes, original.node.attributes);
    for (&attributes) |*attribute| {
        if (std.mem.eql(u8, attribute.name, "defaultArrayLength")) attribute.value = "2";
    }
    var changed_list = original.node.child(.binary_data_array_list).?;
    changed_list.children = &.{prepared.array.node};
    var changed_record = original.node;
    changed_record.attributes = &attributes;
    changed_record.children = &.{changed_list};
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    var writer = try mzml.Writer.initIndexed(std.testing.allocator, &sink.writer, .{}, .{});
    defer writer.deinit();
    try writer.writeHeader(header.*);
    try writer.beginList(.spectrum_list, 1, "dp");
    try writer.writeRecordWithArrays(changed_record, &.{prepared.wire});
    try writer.endList();
    try writer.finish();
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.written() }, .{});
    defer index.deinit();
    var fetched = (try index.byIdDecoded(std.testing.allocator, "scan=1", &decoded)).?;
    defer fetched.deinit();
    try std.testing.expectEqualSlices(f64, &.{ 2, 3 }, decoded.get(0).?.values.float64);
    try std.testing.expectEqual(.zlib, decoded.get(0).?.encoding.pipeline);
    try std.testing.expectEqual(@as(usize, 2), fetched.value.default_array_length);
    try std.testing.expectEqualDeep(changed_record.attributes, fetched.value.node.attributes);
    try std.testing.expectEqualDeep(original.node.params, fetched.value.node.params);
    try std.testing.expectEqualDeep(changed_list.attributes, fetched.value.node.child(.binary_data_array_list).?.attributes);
    try std.testing.expectEqualStrings("array-processing", fetched.value.binaryArrays()[0].attribute("dataProcessingRef").?);
    try std.testing.expectEqualDeep(old_array.params[2], fetched.value.binaryArrays()[0].params[3]);
    try std.testing.expectEqualDeep(header.groups, index.header().groups);
}

test "[integration] - [prepared construction]: retains metadata and borrows primitive wire" {
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var compressor = try mzml.zlib.Compressor.init(std.testing.allocator, .fastest);
    defer compressor.deinit();
    inline for (.{ f32, f64, i32, i64 }) |T| {
        const values: [5]T = if (@typeInfo(T) == .float)
            .{ -0.0, -12.5, 0.125, std.math.inf(T), std.math.nan(T) }
        else
            .{ std.math.minInt(T), -1, 0, 1, std.math.maxInt(T) };
        for ([_]mzml.arrays.Pipeline{ .none, .zlib }) |pipeline| {
            for ([_]usize{ 0, 1, values.len }) |length| {
                builder.reset();
                var transport: [512]u8 = undefined;
                var transformed: [512]u8 = undefined;
                const result = try builder.prepareArray(T, values[0..length], .{
                    .cv_ref = "MS",
                    .role = .{ .cv_ref = "MS", .accession = .{ .raw = "X:auxiliary" }, .name = "auxiliary" },
                    .encoding = .{ .pipeline = pipeline },
                }, .{ .transport = &transport, .transformed = &transformed }, &compressor);
                try std.testing.expectEqual(@as(?[]const u8, null), result.array.node.child(.binary).?.text);
                try std.testing.expectEqual(try mzml.base64.encodedSize(result.wire.len), try mzml.cv.parseInteger(usize, result.array.node.attribute("encodedLength")));
                try std.testing.expectEqual(length, result.array.length);
                if (pipeline == .none and @import("builtin").cpu.arch.endian() == .little)
                    try std.testing.expectEqual(std.mem.sliceAsBytes(values[0..length]).ptr, result.wire.ptr);
                var output: [5]T = undefined;
                try mzml.arrays.decodeWire(T, output[0..length], result.wire, pipeline, &.{}, .{});
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(values[0..length]), std.mem.sliceAsBytes(output[0..length]));
            }
        }
    }
}

test "[integration] - [prepared construction]: keeps builder and writer failure checks" {
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var other = mzml.Builder.init(std.testing.allocator, .{});
    defer other.deinit();
    const options: mzml.Builder.ArrayOptions = .{ .cv_ref = "MS", .role = .{ .cv_ref = "MS", .accession = mzml.model.Terms.MZ_ARRAY, .name = "m/z array" } };
    const scratch: mzml.arrays.Scratch = .{ .transport = &.{}, .transformed = &.{} };
    var intensity_options = options;
    intensity_options.role.accession = mzml.model.Terms.INTENSITY_ARRAY;
    intensity_options.role.name = "intensity array";
    const a = try builder.prepareArray(f64, &.{1}, options, scratch, null);
    const b = try builder.prepareArray(f64, &.{2}, intensity_options, scratch, null);
    try std.testing.expectError(error.PayloadNotRetained, builder.record(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{ a.array, b.array }));
    try std.testing.expectError(error.InvalidRecord, other.preparedRecord(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{ a.array, b.array }));
    try std.testing.expectError(error.InvalidArrayLength, builder.preparedRecord(.spectrum, "scan=1", 0, 2, &.{}, &.{}, &.{ a.array, b.array }));
    const single = try builder.preparedRecord(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{a.array});
    try std.testing.expectEqual(@as(usize, 1), single.binaryArrays().len);
    var bad = options;
    bad.role.unit.cv_ref = "UO";
    const partial = try builder.prepareArray(f64, &.{1}, bad, scratch, null);
    try std.testing.expectEqualDeep(bad.role.unit, partial.array.node.params[0].cv.unit);
    bad = options;
    bad.encoding.pipeline = .zlib;
    try std.testing.expectError(error.MissingCompressor, builder.prepareArray(f64, &.{1}, bad, scratch, null));
    bad.encoding.pipeline = .linear;
    try std.testing.expectError(error.MissingFixedPoint, builder.prepareArray(f64, &.{1}, bad, scratch, null));
    try std.testing.expectError(error.TypeMismatch, builder.prepareArray(f32, &.{1}, bad, scratch, null));
    var limited = mzml.Builder.init(std.testing.allocator, .{ .bytes = 1 });
    defer limited.deinit();
    try std.testing.expectError(error.LimitExceeded, limited.prepareArray(f64, &.{1}, options, scratch, null));
    const record = try builder.preparedRecord(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{ a.array, b.array });
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    var buffer: [8192]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();
    try writer.writeHeader((try reader.readHeader()).*);
    try writer.beginList(.spectrum_list, 1, "dp");
    const before = sink.buffered().len;
    try std.testing.expectError(error.EncodedLengthMismatch, writer.writeRecordWithArrays(record.node, &.{ a.wire[0..4], b.wire }));
    try std.testing.expectEqual(before, sink.buffered().len);
    try std.testing.expectError(error.FailedState, writer.writeRecordWithArrays(record.node, &.{ a.wire, b.wire }));
}

test "[integration] - [mzML prepared writing]: matches frozen plain and indexed codec output" {
    var bytes: [32768]u8 = undefined;
    for ([_]bool{ false, true }) |indexed| {
        var sink = std.Io.Writer.fixed(&bytes);
        try support.constructFixture(std.testing.allocator, &sink, indexed, std.meta.tags(mzml.arrays.Pipeline), true);
        const expected = if (indexed) @embedFile("data/writer_indexed.mzML") else @embedFile("data/writer_plain.mzML");
        try std.testing.expectEqualStrings(std.mem.trimEnd(u8, expected, "\n"), sink.buffered());
    }
}

test "[integration] - [mzML construction]: writes and decodes every declared pipeline" {
    var buffer: [32768]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    try support.constructFixture(std.testing.allocator, &sink, false, std.meta.tags(mzml.arrays.Pipeline), false);
    var input = std.Io.Reader.fixed(sink.buffered());
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var count: usize = 0;
    while (try reader.nextRecord()) |record| {
        try std.testing.expectEqual(@as(usize, 3), record.default_array_length);
        var typed_arrays = record.arrays(header.groups);
        while (try typed_arrays.next()) |array| {
            const encoding = array.encoding;
            try std.testing.expectEqual(@as(mzml.arrays.Pipeline, @enumFromInt(count % 8)), encoding.pipeline);
            var output: [3]f64 = undefined;
            var transport: [512]u8 = undefined;
            var transformed: [512]u8 = undefined;
            try array.decode(f64, &output, .{ .transport = &transport, .transformed = &transformed }, .{});
            for (output, [_]f64{ 1, 2, 3 }) |value, expected| try std.testing.expectApproxEqAbs(expected, value, 0.001);
            if (encoding.pipeline == .pic or encoding.pipeline == .pic_zlib) {
                const counts = try mzml.base64.decode(&transport, array.node.child(.binary).?.text.?, .{});
                const wire = if (encoding.pipeline == .pic_zlib)
                    try mzml.zlib.decompress(&transformed, transport[0..counts.decoded_bytes])
                else
                    transport[0..counts.decoded_bytes];
                // Each PIC integer has seven leading zero nibbles, followed by 1, 2, or 3.
                try std.testing.expectEqualSlices(u8, &.{ 0x71, 0x72, 0x73 }, wire);
            }
        }
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 16), count);
    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, @embedFile("data/writer_plain.mzML"), "\n"), sink.buffered());
    const cases = .{
        .{ @embedFile("data/writer_linear_slof.mzML"), &[_]mzml.arrays.Pipeline{ .none, .zlib, .linear, .slof, .linear_zlib, .slof_zlib } },
        .{ @embedFile("data/writer_raw_zlib.mzML"), &[_]mzml.arrays.Pipeline{ .none, .zlib } },
    };
    inline for (cases) |case| {
        var variant_buffer: [32768]u8 = undefined;
        var variant = std.Io.Writer.fixed(&variant_buffer);
        try support.constructFixture(std.testing.allocator, &variant, true, case[1], false);
        try std.testing.expectEqualStrings(std.mem.trimEnd(u8, case[0], "\n"), variant.buffered());
    }
}

test "[integration] - [mzML construction]: cleans failed allocations and preserves source references" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.constructAllocated, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.constructAllocated, .{true});
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    var header = (try reader.readHeader()).*;
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    header.run.attributes = &.{ .{ .name = "id", .value = "r" }, .{ .name = "defaultInstrumentConfigurationRef", .value = "missing" } };
    try support.expectNode(header.run, (try builder.header(header)).run);
    try std.testing.expectError(error.InvalidRecord, builder.record(.scan, "bad", 0, 0, &.{}, &.{}, &.{}));
    header.run.attributes = &.{ .{ .name = "id", .value = "r" }, .{ .name = "defaultInstrumentConfigurationRef", .value = "sw" } };
    try support.expectNode(header.run, (try builder.header(header)).run);
    header.run.kind = .scan;
    try std.testing.expectError(error.InvalidStructure, builder.header(header));
    const declaration = try builder.vocabulary(.{ .id = "units", .full_name = "Units", .uri = "urn:units", .version = "" });
    try std.testing.expectEqualStrings("", declaration.attribute("version").?);
    const param = try builder.number(.{ .cv_ref = "MS", .accession = mzml.model.Terms.SCAN_START_TIME, .name = "scan start time" }, -0.0);
    try std.testing.expect(std.math.signbit(try mzml.cv.parseFloat(f64, param.value)));
    var encoded: [128]u8 = undefined;
    var transport: [64]u8 = undefined;
    var transformed: [64]u8 = undefined;
    const options: mzml.Builder.ArrayOptions = .{ .cv_ref = "MS", .role = .{ .cv_ref = "MS", .accession = mzml.model.Terms.MZ_ARRAY, .name = "m/z array" } };
    const array = try builder.binaryArray(f64, &.{1}, options, &encoded, .{ .transport = &transport, .transformed = &transformed }, null);
    try std.testing.expectEqual(null, array.node.attribute("arrayLength"));
    try std.testing.expectEqual(null, array.node.attribute("dataProcessingRef"));
    var intensity_options = options;
    intensity_options.role.accession = mzml.model.Terms.INTENSITY_ARRAY;
    intensity_options.role.name = "intensity array";
    const intensity = try builder.binaryArray(f64, &.{1}, intensity_options, &encoded, .{ .transport = &transport, .transformed = &transformed }, null);
    const record = try builder.record(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{ array, intensity });
    try std.testing.expect(record.binaryArrays()[0].child(.binary).?.text.?.ptr == array.node.child(.binary).?.text.?.ptr);
    try std.testing.expect(record.binaryArrays()[1].child(.binary).?.text.?.ptr == intensity.node.child(.binary).?.text.?.ptr);
    var other = mzml.Builder.init(std.testing.allocator, .{});
    defer other.deinit();
    try std.testing.expectError(error.InvalidRecord, other.record(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{ array, intensity }));
    try std.testing.expectError(error.InvalidArrayLength, builder.record(.spectrum, "scan=1", 0, 2, &.{}, &.{}, &.{array}));
    var bad = options;
    bad.data_processing_ref = "dp";
    const processing = try builder.binaryArray(f64, &.{1}, bad, &encoded, .{ .transport = &transport, .transformed = &transformed }, null);
    try std.testing.expectEqualStrings("dp", processing.node.attribute("dataProcessingRef").?);
    try std.testing.expectEqual(null, processing.node.attribute("arrayLength"));
    bad = options;
    bad.encoding.pipeline = .pic;
    try std.testing.expectError(error.TypeMismatch, builder.binaryArray(f32, &.{1}, bad, &encoded, .{ .transport = &transport, .transformed = &transformed }, null));
}

test "[failure] - [mzML construction]: rejects depth options before copying or encoding" {
    for ([_]usize{ 0, 65 }) |depth| {
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        var builder = mzml.Builder.init(empty.allocator(), .{ .depth = depth });
        defer builder.deinit();
        try std.testing.expectError(error.LimitExceeded, builder.record(.spectrum, "one", 0, 0, &.{}, &.{}, &.{}));
        try std.testing.expectError(error.LimitExceeded, builder.preparedRecord(.spectrum, "one", 0, 0, &.{}, &.{}, &.{}));
        const options: mzml.Builder.ArrayOptions = .{ .cv_ref = "MS", .role = .{ .cv_ref = "MS", .accession = mzml.model.Terms.MZ_ARRAY, .name = "m/z" } };
        const scratch: mzml.arrays.Scratch = .{ .transport = &.{}, .transformed = &.{} };
        try std.testing.expectError(error.LimitExceeded, builder.binaryArray(f64, &.{1}, options, &.{}, scratch, null));
        try std.testing.expectError(error.LimitExceeded, builder.prepareArray(f64, &.{1}, options, scratch, null));
    }
}

test "[integration] - [mzML construction]: preserves partial fields and supplied array order" {
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    const source: mzml.model.Header = .{
        .document = .{ .kind = .mzml, .attributes = &.{.{ .name = "version", .value = "1.1.0" }} },
        .run = .{ .kind = .run, .params = &.{ .{ .user = .{ .unit = .{ .name = "partial" } } }, .{ .cv = .{} }, .{ .group_ref = .{ .ref = null } } } },
    };
    const header = try builder.header(source);
    try support.expectNode(source.document, header.document);
    try support.expectNode(source.run, header.run);
    const number = try builder.number(.{ .unit = .{ .name = "partial" } }, 2.5);
    try std.testing.expectEqual(@as(f64, 2.5), try mzml.cv.parseFloat(f64, number.value));
    try std.testing.expectEqualStrings("partial", number.unit.name.?);
    try std.testing.expectEqual(null, number.name);
    var arrays: [3]mzml.Builder.Array = undefined;
    var output: [64]u8 = undefined;
    for ([_]mzml.cv.Accession{ mzml.model.Terms.INTENSITY_ARRAY, mzml.model.Terms.TIME_ARRAY, mzml.model.Terms.MZ_ARRAY }, &arrays, 0..) |role, *array, position| {
        array.* = try builder.binaryArray(f64, &.{@floatFromInt(position + 1)}, .{ .cv_ref = "MS", .role = .{ .cv_ref = "MS", .accession = role, .name = "caller role" } }, &output, .{ .transport = &.{}, .transformed = &.{} }, null);
    }
    const record = try builder.record(.spectrum, "one", 0, 1, &.{}, &.{}, &arrays);
    for (arrays, record.binaryArrays()) |array, copied| try support.expectNode(array.node, copied);
    var xml: [4096]u8 = undefined;
    var sink = std.Io.Writer.fixed(&xml);
    try support.writeSingleRecord(std.testing.allocator, &sink, header, record.node, false, null);
    var input = std.Io.Reader.fixed(sink.buffered());
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    var decoded = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer decoded.deinit();
    const actual = (try reader.nextDecodedRecord(&decoded)).?;
    try std.testing.expectEqual(@as(usize, 3), decoded.len());
    for (arrays, actual.binaryArrays(), 0..) |array, copied, position| {
        try std.testing.expectEqualDeep(array.node.params, copied.params);
        try std.testing.expectEqual(@as(f64, @floatFromInt(position + 1)), decoded.get(position).?.values.float64[0]);
    }
    var missing = source;
    missing.document.children = &.{.{ .kind = .referenceable_param_group_list, .children = &.{.{ .kind = .referenceable_param_group }} }};
    try std.testing.expectError(error.MissingAttribute, builder.header(missing));
}

test "[integration] - [mzML construction]: preserves primitive bits through emitted declarations" {
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var compressor = try mzml.zlib.Compressor.init(std.testing.allocator, .fastest);
    defer compressor.deinit();
    inline for (.{ f32, f64, i32, i64 }) |T| {
        const values: [5]T = if (@typeInfo(T) == .float)
            .{ -0.0, -12.5, 0.125, std.math.inf(T), std.math.nan(T) }
        else
            .{ std.math.minInt(T), -1, 0, 1, std.math.maxInt(T) };
        for ([_]mzml.arrays.Pipeline{ .none, .zlib }) |pipeline| {
            for ([_]usize{ 0, 1, values.len }) |length| {
                builder.reset();
                var encoded: [1024]u8 = undefined;
                var transport: [512]u8 = undefined;
                var transformed: [512]u8 = undefined;
                const array = try builder.binaryArray(T, values[0..length], .{
                    .cv_ref = "MS",
                    .role = .{ .cv_ref = "MS", .accession = .{ .raw = "X:auxiliary" }, .name = "auxiliary" },
                    .encoding = .{ .pipeline = pipeline },
                }, &encoded, .{ .transport = &transport, .transformed = &transformed }, &compressor);
                var decoded: [5]T = undefined;
                try mzml.model.decodeArray(T, decoded[0..length], array.node, 99, &.{}, .{ .transport = &transport, .transformed = &transformed }, .{});
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(values[0..length]), std.mem.sliceAsBytes(decoded[0..length]));
            }
        }
    }
}

test "[integration] - [mzML header IDs]: preserves document labels, run labels, and source references" {
    inline for (.{ "sw", "", "ic" }) |id| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "id='example'", "id='" ++ id ++ "'");
        defer std.testing.allocator.free(source);
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        var builder = mzml.Builder.init(std.testing.allocator, .{});
        defer builder.deinit();
        const copied = try builder.header((try reader.readHeader()).*);
        try std.testing.expectEqualStrings(id, copied.document.attribute("id").?);
    }
    inline for (.{ "sw", "ic", "run label: 1" }) |id| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "id='r'", "id='" ++ id ++ "'");
        defer std.testing.allocator.free(source);
        var source_input = std.Io.Reader.fixed(source);
        var source_reader = try mzml.StreamReader.init(std.testing.allocator, &source_input, .{});
        defer source_reader.deinit();
        var owner = mzml.Builder.init(std.testing.allocator, .{});
        defer owner.deinit();
        const copied = try owner.header((try source_reader.readHeader()).*);
        try std.testing.expectEqualStrings(id, copied.run.attribute("id").?);
    }
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    var header = (try reader.readHeader()).*;
    header.run.attributes = &.{
        .{ .name = "id", .value = "r" },
        .{ .name = "defaultInstrumentConfigurationRef", .value = "example" },
    };
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    try support.expectNode(header.run, (try builder.header(header)).run);
}
