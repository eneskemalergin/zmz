//! Tests checked construction and encoded array output.

const std = @import("std");
const mzml = @import("z_mzml");
const support = @import("support.zig");

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
        for (record.binaryArrays()) |array| {
            const encoding = try mzml.model.arrayEncoding(array, header.groups);
            try std.testing.expectEqual(@as(mzml.arrays.Pipeline, @enumFromInt(count % 8)), encoding.pipeline);
            var output: [3]f64 = undefined;
            var transport: [512]u8 = undefined;
            var transformed: [512]u8 = undefined;
            try mzml.model.decodeArray(f64, &output, array, 3, header.groups, .{ .transport = &transport, .transformed = &transformed }, .{});
            for (output, [_]f64{ 1, 2, 3 }) |value, expected| try std.testing.expectApproxEqAbs(expected, value, 0.001);
            if (encoding.pipeline == .pic or encoding.pipeline == .pic_zlib) {
                const counts = try mzml.base64.decode(&transport, array.child(.binary).?.text.?, .{});
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

test "[integration] - [mzML construction]: cleans failed allocations and rejects missing references" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.constructAllocated, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.constructAllocated, .{true});
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    var header = (try reader.readHeader()).*;
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    header.run.attributes = &.{ .{ .name = "id", .value = "r" }, .{ .name = "defaultInstrumentConfigurationRef", .value = "missing" } };
    try std.testing.expectError(error.MissingReference, builder.header(header));
    try std.testing.expectError(error.InvalidRecord, builder.record(.scan, "bad", 0, 0, &.{}, &.{}, &.{}));
    header.run.attributes = &.{ .{ .name = "id", .value = "r" }, .{ .name = "defaultInstrumentConfigurationRef", .value = "sw" } };
    try std.testing.expectError(error.WrongReferenceKind, builder.header(header));
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
    try std.testing.expectError(error.InvalidDeclaration, builder.binaryArray(f64, &.{1}, bad, &encoded, .{ .transport = &transport, .transformed = &transformed }, null));
    bad = options;
    bad.encoding.pipeline = .pic;
    try std.testing.expectError(error.TypeMismatch, builder.binaryArray(f32, &.{1}, bad, &encoded, .{ .transport = &transport, .transformed = &transformed }, null));
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

test "[integration] - [mzML header IDs]: keeps the document label outside metadata reference IDs" {
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
    try std.testing.expectError(error.MissingReference, builder.header(header));
}
