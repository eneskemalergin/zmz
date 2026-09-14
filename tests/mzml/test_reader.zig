//! Tests streaming reads, payload handling, and malformed input.

const std = @import("std");
const zmz = @import("zmz");
const mzml = zmz.mzml;
const gates = @import("gates_test_support");
const support = @import("support.zig");

test "[unit] - [package API]: exposes mzML through one namespace" {
    try std.testing.expect(@hasDecl(zmz, "mzml"));
    try std.testing.expect(!@hasDecl(zmz, "StreamReader"));
    try std.testing.expect(!@hasDecl(zmz, "Writer"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "Scope"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "parseFragment"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "readFragment"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "parseFooter"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "resumeFollowingList"));
    try std.testing.expect(!@hasDecl(mzml.StreamReader, "finishEmptySpectrumList"));
    try std.testing.expect(@hasDecl(mzml.StreamReader, "indexTrailer"));
    try std.testing.expect(!@hasDecl(mzml.owned, "Copier"));
    try std.testing.expect(@hasDecl(mzml.arrays, "Pipeline"));
    try std.testing.expect(@hasDecl(mzml.cv, "Resolver"));
}

test "[regression] - [mzML array decoding]: reads empty producer arrays with zlib declarations" {
    const array = "<binaryDataArray encodedLength='0' arrayLength='0'><cvParam cvRef='MS' accession='MS:1000523' name='64-bit float'/>" ++
        "<cvParam cvRef='MS' accession='MS:1000574' name='zlib compression'/><binary> \t\r\n</binary></binaryDataArray>";
    const source = support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'><spectrum id='scan=1' index='0' defaultArrayLength='0'>" ++
        "<binaryDataArrayList count='2'>" ++ array ++ array ++ "</binaryDataArrayList></spectrum></spectrumList></run></mzML>";
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const record = (try reader.nextRecord()).?;
    var scratch: [32]u8 = undefined;
    const node = record.binaryArrays()[0];
    try mzml.model.decodeArray(f64, &.{}, node, 5, &.{}, .{ .transport = &scratch, .transformed = &.{} }, .{});
    try std.testing.expectError(error.LimitExceeded, mzml.model.decodeArray(f64, &.{}, node, 0, &.{}, .{ .transport = &scratch, .transformed = &.{} }, .{ .base64_text = .{ .text_bytes = 0 } }));
    var one: [1]f64 = undefined;
    var nonempty = node;
    nonempty.attributes = &.{.{ .name = "encodedLength", .value = "0" }};
    try std.testing.expectError(error.TruncatedInput, mzml.model.decodeArray(f64, &one, nonempty, 1, &.{}, .{ .transport = &scratch, .transformed = &.{} }, .{}));
    try std.testing.expectError(error.TruncatedInput, mzml.zlib.decompress(&scratch, ""));
    try std.testing.expectEqual(null, try reader.nextRecord());
}

test "[property] - [mzML binary text]: counts significant characters across vector and XML text boundaries" {
    var buffer: [8192]u8 = undefined;
    var text: [257]u8 = undefined;
    const alphabet = "A =+/\t\r\n";
    for ([_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 257 }) |length| {
        var significant: usize = 0;
        for (text[0..length], 0..) |*byte, i| {
            byte.* = alphabet[i % alphabet.len];
            if (byte.* != ' ' and byte.* != '\t' and byte.* != '\r' and byte.* != '\n') significant += 1;
        }
        var source = std.Io.Writer.fixed(&buffer);
        try source.writeAll(support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'><spectrum id='scan=1' index='0' defaultArrayLength='0'><binaryDataArrayList count='2'>");
        for (0..2) |_| {
            try source.print("<binaryDataArray encodedLength='{d}'><binary><![CDATA[{s}]]></binary></binaryDataArray>", .{ significant, text[0..length] });
        }
        try source.writeAll("</binaryDataArrayList></spectrum></spectrumList></run></mzML>");
        for ([_]mzml.StreamReader.Payload{ .retain, .skip }) |payload| {
            var input = std.Io.Reader.fixed(source.buffered());
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .payload = payload });
            defer reader.deinit();
            const record = (try reader.nextRecord()).?;
            try std.testing.expectEqual(@as(usize, 2), record.binaryArrays().len);
            try std.testing.expectEqual(null, try reader.nextRecord());
        }
    }
}

test "[integration] - [mzML reader]: reuses storage across growing and shrinking fragmented records" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    const lengths = [_]usize{ 1, 512, 0, 16, 1 };
    try source.writer.writeAll(support.HEADER ++ "<spectrumList count='5' defaultDataProcessingRef='dp'>");
    var zeros: [4096]u8 = @splat(0);
    var encoded: [5464]u8 = undefined;
    for (lengths, 0..) |length, index| {
        const text = try mzml.base64.encode(&encoded, zeros[0 .. length * 8]);
        try source.writer.print("<spectrum index='{d}' id='scan={d}' defaultArrayLength='{d}'><binaryDataArrayList count='2'>", .{ index, index, length });
        for (0..2) |_| {
            try source.writer.print("<binaryDataArray encodedLength='{d}'><referenceableParamGroupRef ref='encoding'/><binary>", .{text.len});
            const split = @min(37, text.len);
            try source.writer.writeAll(text[0..split]);
            try source.writer.writeAll("<![CDATA[");
            try source.writer.writeAll(text[split..]);
            try source.writer.writeAll("]]></binary></binaryDataArray>");
        }
        try source.writer.writeAll("</binaryDataArrayList></spectrum>");
    }
    try source.writer.writeAll("</spectrumList></run></mzML>");
    var input = std.Io.Reader.fixed(source.written());
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var transport: [4096]u8 = undefined;
    var output: [512]f64 = undefined;
    for (lengths, 0..) |length, index| {
        const record = (try reader.nextRecord()).?;
        try std.testing.expectEqual(index, record.index);
        try std.testing.expectEqual(length, record.default_array_length);
        try std.testing.expectEqual(@as(usize, 2), record.binaryArrays().len);
        for (record.binaryArrays()) |array| {
            const text = try mzml.base64.encode(&encoded, zeros[0 .. length * 8]);
            try std.testing.expectEqualStrings(text, array.child(.binary).?.text.?);
            try mzml.model.decodeArray(f64, output[0..length], array, length, header.groups, .{ .transport = &transport, .transformed = &.{} }, .{});
            try std.testing.expectEqualSlices(u8, zeros[0 .. length * 8], std.mem.sliceAsBytes(output[0..length]));
        }
    }
    try std.testing.expectEqual(null, try reader.nextRecord());
}

test "[integration] - [mzML numeric attributes]: enforces schema ranges in reading and construction" {
    const cases = .{
        .{ "word", error.InvalidValue },
        .{ "1_0", error.InvalidValue },
        .{ "-1", error.Overflow },
    };
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    inline for (cases) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "order='0'", "order='" ++ case[0] ++ "'");
        defer std.testing.allocator.free(source);
        try std.testing.expectError(case[1], support.readAll(std.testing.allocator, source, .{}));
        try std.testing.expectError(case[1], builder.node(.{
            .kind = .processing_method,
            .attributes = &.{ .{ .name = "order", .value = case[0] }, .{ .name = "softwareRef", .value = "sw" } },
        }));
    }
    inline for (.{ "2147483648", "-2147483649", "1.5" }) |value| {
        const expected = if (std.mem.eql(u8, value, "1.5")) error.InvalidValue else error.Overflow;
        const components = "<instrumentConfiguration id='ic'><componentList count='3'>" ++
            "<source order='" ++ value ++ "'/><analyzer order='1'/><detector order='2'/>" ++
            "</componentList></instrumentConfiguration>";
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "<instrumentConfiguration id='ic'/>", components);
        defer std.testing.allocator.free(source);
        try std.testing.expectError(expected, support.readAll(std.testing.allocator, source, .{}));
        try std.testing.expectError(expected, builder.node(.{
            .kind = .source,
            .attributes = &.{.{ .name = "order", .value = value }},
        }));
    }
    inline for (.{ "-2147483648", "-1", "-0", "+2147483647" }) |value| {
        _ = try builder.node(.{ .kind = .source, .attributes = &.{.{ .name = "order", .value = value }} });
    }
    inline for (.{
        .{ "defaultArrayLength='1'", "defaultArrayLength='2147483648'" },
        .{ "<scanWindowList count='1'>", "<scanWindowList count='2147483648'>" },
    }) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, case[0], case[1]);
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.Overflow, support.readAll(std.testing.allocator, source, .{
            .check_counts = false,
            .limits = .{ .list_entries = std.math.maxInt(usize) },
        }));
    }
    try std.testing.expectError(error.Overflow, builder.record(.spectrum, "scan=1", 0, 2147483648, &.{}, &.{}, &.{}));

    const record_cases = [_]struct { length: []const u8, index: []const u8, failure: ?mzml.cv.ValueError }{
        .{ .length = "2147483648", .index = "bad", .failure = error.InvalidValue },
        .{ .length = "-1", .index = "bad", .failure = error.Overflow },
        .{ .length = "2147483648", .index = "0", .failure = error.Overflow },
        .{ .length = " +2147483647 ", .index = "0", .failure = null },
    };
    for (record_cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, support.HEADER ++
            "<spectrumList count='1' defaultDataProcessingRef='dp'><spectrum id='scan=1' index='{s}' defaultArrayLength='{s}'/></spectrumList></run></mzML>", .{ case.index, case.length });
        defer std.testing.allocator.free(source);
        const node: mzml.model.Node = .{ .kind = .spectrum, .attributes = &.{
            .{ .name = "id", .value = "scan=1" },
            .{ .name = "index", .value = case.index },
            .{ .name = "defaultArrayLength", .value = case.length },
        } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, support.readAll(std.testing.allocator, source, .{}));
            try std.testing.expectError(failure, builder.node(node));
        } else {
            try support.readAll(std.testing.allocator, source, .{});
            const copied = try builder.node(node);
            try std.testing.expectEqualStrings(case.length, copied.attribute("defaultArrayLength").?);
        }
    }
}

test "[integration] - [mzML chunks]: retains values across short reads and UTF-16 code units" {
    var buffer: [31]u8 = undefined;
    inline for (.{ 1, 7, 31 }) |size| {
        var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = support.DOCUMENT }});
        input.artificial_limit = .limited(size);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input.interface, .{});
        defer reader.deinit();
        const record = (try reader.nextRecord()).?;
        try std.testing.expectEqualStrings("native=a&b", record.id);
        try std.testing.expectEqualStrings("AAAAAAAA8D8=", record.binaryArrays()[0].child(.binary).?.text.?);
        while (try reader.nextRecord()) |_| {}
    }
    var utf16: [support.DOCUMENT.len * 2 + 2]u8 = undefined;
    inline for (.{ std.builtin.Endian.little, .big }) |endian| {
        std.mem.writeInt(u16, utf16[0..2], 0xfeff, endian);
        for (support.DOCUMENT, 0..) |byte, index| std.mem.writeInt(u16, utf16[2 + index * 2 ..][0..2], byte, endian);
        var input: std.testing.Reader = .init(buffer[0..7], &.{.{ .buffer = &utf16 }});
        input.artificial_limit = .limited(7);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input.interface, .{});
        defer reader.deinit();
        const record = (try reader.nextRecord()).?;
        const expected_offset = 2 + 2 * std.mem.indexOf(u8, support.DOCUMENT, "<spectrum id").?;
        try std.testing.expectEqual(@as(u64, expected_offset), record.node.start_offset);
        try std.testing.expectEqualStrings("native=a&b", record.id);
        while (try reader.nextRecord()) |_| {}
    }
}

test "[integration] - [mzML reader]: retains hierarchy parameters and decodes grouped arrays" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();

    const header = try reader.readHeader();
    try std.testing.expectEqualStrings("example", header.document.attribute("id").?);
    const param = header.document.child(.file_description).?.child(.file_content).?.params[0].cv;
    try std.testing.expectEqualStrings("A&B", param.name.?);
    try std.testing.expectEqualStrings("", param.value.?);
    try std.testing.expectEqualStrings("", header.document.child(.cv_list).?.children[0].attribute("version").?);
    const spectrum = (try reader.nextRecord()).?;
    try std.testing.expectEqualStrings("native=a&b", spectrum.id);
    try std.testing.expectEqual(@as(usize, 2), spectrum.binaryArrays().len);
    try std.testing.expectEqual(@as(u64, std.mem.indexOf(u8, support.DOCUMENT, "<spectrum id").?), spectrum.node.start_offset);
    try std.testing.expectEqual(@as(usize, 1), spectrum.node.child(.scan_list).?.children.len);
    const precursor = spectrum.node.child(.precursor_list).?.children[0];
    try std.testing.expectEqualStrings("earlier", precursor.attribute("spectrumRef").?);
    try std.testing.expectEqualStrings("", precursor.child(.selected_ion_list).?.children[0].params[0].user.value.?);
    try std.testing.expect(spectrum.node.child(.product_list).?.children[0].child(.isolation_window) != null);
    var values: [1]f64 = undefined;
    var transport: [32]u8 = undefined;
    var transformed: [32]u8 = undefined;
    try mzml.model.decodeArray(f64, &values, spectrum.binaryArrays()[0], 1, header.groups, .{
        .transport = &transport,
        .transformed = &transformed,
    }, .{});
    try std.testing.expectEqual(@as(f64, 1), values[0]);
    try mzml.model.decodeArray(f64, &values, spectrum.binaryArrays()[1], 2, header.groups, .{
        .transport = &transport,
        .transformed = &transformed,
    }, .{});
    try std.testing.expectEqual(@as(f64, 1), values[0]);
    try std.testing.expectError(error.DecodedSizeMismatch, mzml.model.decodeArray(
        f64,
        &values,
        spectrum.binaryArrays()[0],
        2,
        header.groups,
        .{ .transport = &transport, .transformed = &transformed },
        .{},
    ));
    const chromatogram = (try reader.nextRecord()).?;
    try std.testing.expectEqual(.chromatogram, chromatogram.node.kind);
    try std.testing.expectEqualStrings("tic", chromatogram.id);
    try std.testing.expectEqualStrings("A&B", param.name.?);
    try std.testing.expectEqual(null, try reader.nextRecord());
    try std.testing.expectEqual(null, try reader.nextRecord());
    try std.testing.expectEqual(@as(usize, 1), header.spectrum_list.?.observed_count);
    try std.testing.expectEqual(@as(usize, 1), header.chromatogram_list.?.observed_count);
    try std.testing.expectEqual(@as(u64, support.DOCUMENT.len), header.document.end_offset);
}

test "[integration] - [mzML minimal checks]: preserves complete metadata across fragmented encodings" {
    const prefixed = support.HEADER ++ "<spectrumList xmlns:p='http://psi.hupo.org/ms/mzml' count='1' defaultDataProcessingRef='dp'>" ++
        "<p:spectrum xmlns:q='http://www.w3.org/2001/XMLSchema-instance' q:schemaLocation='unchanged' id='scan=1' index='0' defaultArrayLength='0'>" ++
        "<p:userParam name='note' value='e&#x301;&#x9;&amp;'/></p:spectrum></spectrumList></run></mzML>";
    const sources = [_][]const u8{ support.DOCUMENT, prefixed, @embedFile("data/scientific_metadata.mzML"), @embedFile("data/writer_indexed.mzML"), gates.EMPTY_RUN };
    for (sources) |source| {
        for (std.enums.values(mzml.StreamReader.Payload)) |payload| try support.expectMinimalRead(source, payload);
    }
    var utf16: [prefixed.len * 2 + 2]u8 = undefined;
    for (std.enums.values(std.builtin.Endian)) |endian| {
        std.mem.writeInt(u16, utf16[0..2], 0xfeff, endian);
        for (prefixed, 0..) |byte, i| std.mem.writeInt(u16, utf16[2 + i * 2 ..][0..2], byte, endian);
        try support.expectMinimalRead(&utf16, .retain);
    }
}

test "[integration] - [mzML minimal checks]: distinguishes omitted checks from retained failures" {
    const omitted = .{
        .{ "http://psi.hupo.org/ms/mzml", "urn:unchecked", error.WrongNamespace },
        .{ "count='1'", "count='2'", error.CountMismatch },
        .{ "encodedLength='12'", "encodedLength='13'", error.EncodedLengthMismatch },
        .{ "encodedLength='12'", "encodedLength='bad'", error.InvalidValue },
        .{ "<scanWindowList count='1'>", "<scanWindowList count='bad'>", error.InvalidValue },
        .{ "order='0'", "order='bad'", error.InvalidValue },
        .{ "defaultArrayLength='1'", "defaultArrayLength='2147483648'", error.Overflow },
        .{ "<activation/>", "", error.InvalidStructure },
        .{ "<scanWindow/>", "<scanWindow/><scanWindow/>", error.CountMismatch },
        .{ "<userParam name='note' value=''/>", "<userParam name='note' value=''/><cvParam cvRef='MS' accession='X:future' name='later'/>", error.InvalidStructure },
        .{ "<referenceableParamGroup id='encoding'>", "<referenceableParamGroup id='encoding'><referenceableParamGroupRef ref='other'/>", error.InvalidStructure },
        .{ "index='0'", "index='0' extra='source'", error.UnknownAttribute },
    };
    inline for (omitted) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, case[0], case[1]);
        defer std.testing.allocator.free(source);
        try std.testing.expectError(case[2], support.readAll(std.testing.allocator, source, .{}));
        for (std.enums.values(mzml.StreamReader.Payload)) |payload| {
            try support.readAll(std.testing.allocator, source, .{ .checks = .minimal, .payload = payload });
        }
    }
    const retained = .{
        .{ "<mzML ", "<!DOCTYPE mzML><mzML ", error.DtdForbidden },
        .{ "<mzML ", "<?xml version='1.1'?><mzML ", error.UnsupportedVersion },
        .{ "value=''", "value='&#x1;'", error.InvalidXml },
        .{ "value=''", "value='\xff'", error.InvalidEncoding },
        .{ "<activation/>", "<!--a--b--><activation/>", error.InvalidXml },
        .{ "<activation/>", "<future/>", error.InvalidStructure },
        .{ "<activation/>", "<activation xmlns:q='urn:foreign' q:value='x'/>", error.UnknownAttribute },
        .{ "<activation/>", "<activation></precursor>", error.InvalidXml },
        .{ "name='note'", "", error.MissingAttribute },
        .{ "index='0'", "index='bad'", error.InvalidValue },
        .{ "defaultArrayLength='1'", "defaultArrayLength='-1'", error.Overflow },
        .{ "index='0'", "index='0' index='1'", error.InvalidXml },
    };
    inline for (retained) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, case[0], case[1]);
        defer std.testing.allocator.free(source);
        for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
            try std.testing.expectError(case[2], support.readAll(std.testing.allocator, source, .{ .checks = checks }));
        }
    }
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    try std.testing.expectError(error.InvalidOptions, mzml.StreamReader.init(std.testing.allocator, &input, .{ .checks = .minimal, .validation = .{} }));
    try std.testing.expectEqual(@as(usize, 0), input.seek);

    const extra = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "index='0'", "index='0' extra='source'");
    defer std.testing.allocator.free(extra);
    var extra_input = std.Io.Reader.fixed(extra);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &extra_input, .{ .checks = .minimal });
    defer reader.deinit();
    try std.testing.expectEqualStrings("source", (try reader.nextRecord()).?.node.attribute("extra").?);

    const invalid_payload = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "<binary>AAAA", "<binary>!AAA");
    defer std.testing.allocator.free(invalid_payload);
    var invalid_input = std.Io.Reader.fixed(invalid_payload);
    var invalid = try mzml.StreamReader.init(std.testing.allocator, &invalid_input, .{ .checks = .minimal });
    defer invalid.deinit();
    const record = (try invalid.nextRecord()).?;
    var values: [1]f64 = undefined;
    var transport: [32]u8 = undefined;
    try std.testing.expectError(error.InvalidCharacter, mzml.model.decodeArray(f64, &values, record.binaryArrays()[0], record.default_array_length, (try invalid.readHeader()).groups, .{ .transport = &transport, .transformed = &.{} }, .{}));
}

test "[failure] - [mzML reader]: rejects unsafe XML wrong namespaces and malformed structure" {
    const cases = .{
        .{ "<!DOCTYPE mzML>" ++ support.DOCUMENT, error.DtdForbidden },
        .{ "<mzML xmlns='wrong' version='1.1.0'/>", error.WrongNamespace },
        .{ "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.0.0'/>", error.UnsupportedVersion },
        .{ "<?xml version='1.1'?>" ++ support.DOCUMENT, error.UnsupportedVersion },
        .{ "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.1.0'/>", error.InvalidStructure },
        .{ support.HEADER ++ "<spectrumList count='2' defaultDataProcessingRef='dp'>" ++ support.SPECTRUM ++
            "</spectrumList></run></mzML>", error.CountMismatch },
    };
    inline for (cases) |case| {
        try std.testing.expectError(case[1], support.readAll(std.testing.allocator, case[0], .{}));
    }
    var input = std.Io.Reader.fixed("<mzML xmlns='wrong'/>");
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    try std.testing.expectError(error.WrongNamespace, reader.readHeader());
    try std.testing.expectEqual(@as(u64, 0), reader.diagnostic().?.byte_offset);
    try std.testing.expectError(error.FailedState, reader.nextRecord());
}

test "[edge] - [mzML reader]: skips payload storage without dropping array descriptors" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .payload = .skip });
    defer reader.deinit();
    const spectrum = (try reader.nextRecord()).?;
    const descriptors = spectrum.binaryArrays();
    try std.testing.expectEqual(@as(usize, 2), descriptors.len);
    try std.testing.expectEqual(null, descriptors[0].child(.binary).?.text);
    while (try reader.nextRecord()) |_| {}
}

test "[failure] - [mzML reader]: releases partial allocations and enforces retention limits" {
    for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, support.readAll, .{ support.DOCUMENT, mzml.StreamReader.Options{ .checks = checks } });
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{
            .limits = .{ .header_bytes = 1 },
            .checks = checks,
        }));
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{
            .limits = .{ .record_bytes = 1 },
            .checks = checks,
        }));
        const limits = [_]mzml.StreamReader.Limits{
            .{ .depth = 2 },
            .{ .attributes = 1 },
            .{ .attribute_bytes = 1 },
            .{ .nodes = 1 },
            .{ .list_entries = 1 },
            .{ .binary_text_bytes = 11 },
        };
        for (limits) |limit| {
            try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{ .limits = limit, .checks = checks }));
        }
        try support.readAll(std.testing.allocator, support.DOCUMENT, .{ .limits = .{ .binary_text_bytes = 12 }, .checks = checks });
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.DOCUMENT, .{
            .limits = .{ .binary_text_bytes = 11 },
            .payload = .skip,
            .checks = checks,
        }));
    }
}

test "[integration] - [mzML reader]: reports the list that has a count mismatch" {
    const document = support.HEADER ++ "<spectrumList count='2' defaultDataProcessingRef='dp'>" ++
        support.SPECTRUM ++ "</spectrumList></run></mzML>";
    var input = std.Io.Reader.fixed(document);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    _ = (try reader.nextRecord()).?;
    try std.testing.expectError(error.CountMismatch, reader.nextRecord());
    const diagnostic = reader.diagnostic().?;
    try std.testing.expectEqual(.spectrum_list, diagnostic.element.?);
    try std.testing.expectEqual(@as(u64, std.mem.indexOf(u8, document, "</spectrumList>").?), diagnostic.byte_offset);
    try std.testing.expectError(error.FailedState, reader.nextRecord());
    try std.testing.expectEqualDeep(diagnostic, reader.diagnostic().?);
    try support.readAll(std.testing.allocator, document, .{ .check_counts = false });
}

test "[integration] - [mzML writer]: matches frozen XML and preserves attribute characters" {
    const expected = std.mem.trimEnd(u8, gates.EMPTY_RUN, "\n");
    var input = std.Io.Reader.fixed(expected);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const params = header.document.child(.file_description).?.child(.file_content).?.params;
    try std.testing.expectEqualStrings("\xc2\xb5 < & \"", params[0].cv.name.?);
    try std.testing.expectEqualStrings("\t\n\r", params[0].cv.value.?);
    try std.testing.expectEqual(null, params[1].user.value);
    try std.testing.expectEqualStrings("", params[1].user.unit.name.?);
    const declaration_node = header.document.child(.cv_list).?.children[0];
    const declarations = [_]mzml.cv.Declaration{.{
        .id = declaration_node.attribute("id"),
        .full_name = declaration_node.attribute("fullName"),
        .uri = declaration_node.attribute("URI"),
        .version = declaration_node.attribute("version"),
    }};
    const resolver = mzml.cv.Resolver.init(&declarations);
    const resolved = try resolver.resolve(params[0].cv);
    try std.testing.expectEqualDeep(params[0].cv, resolved.source);
    try std.testing.expectEqual(null, resolved.term.match);
    try std.testing.expectEqual(null, try reader.nextRecord());

    var bytes: [2048]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header.*);
    try writer.finish();
    try std.testing.expectEqualStrings(expected, sink.buffered());
    try std.testing.expectError(error.InvalidState, writer.finish());
}

test "[integration] - [mzML reader]: distinguishes read failures from truncated XML" {
    var unbuffered = std.Io.Reader.failing;
    try std.testing.expectError(error.InvalidOptions, mzml.StreamReader.init(std.testing.allocator, &unbuffered, .{}));
    for ([_]mzml.StreamReader.Options{ .{}, .{ .validation = .{} }, .{ .checks = .minimal } }) |options| {
        var bytes: [support.DOCUMENT.len]u8 = undefined;
        for ([_]usize{ 0, support.HEADER.len, support.DOCUMENT.len / 2, support.DOCUMENT.len }) |length| {
            @memcpy(&bytes, support.DOCUMENT);
            var input = std.Io.Reader.failing;
            input.buffer = &bytes;
            input.end = length;
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, options);
            defer reader.deinit();
            while (reader.nextRecord()) |_| {} else |err| {
                try std.testing.expectEqual(error.ReadFailed, err);
                try std.testing.expectError(error.FailedState, reader.nextRecord());
                continue;
            }
            return error.TestUnexpectedResult;
        }
        for ([_]usize{ 0, 1, support.HEADER.len, support.DOCUMENT.len / 2, support.DOCUMENT.len - 1 }) |length| {
            try std.testing.expectError(error.InvalidXml, support.readAll(std.testing.allocator, support.DOCUMENT[0..length], options));
        }
    }
}

test "[integration] - [mzML arrays]: classifies explicit encodings without guessing" {
    const primitives = .{
        .{ "MS:1000521", mzml.model.Primitive.float32 },
        .{ "MS:1000523", mzml.model.Primitive.float64 },
        .{ "MS:1000519", mzml.model.Primitive.int32 },
        .{ "MS:1000522", mzml.model.Primitive.int64 },
    };
    const pipelines = .{
        .{ "MS:1000576", mzml.arrays.Pipeline.none },
        .{ "MS:1000574", mzml.arrays.Pipeline.zlib },
        .{ "MS:1002312", mzml.arrays.Pipeline.linear },
        .{ "MS:1002313", mzml.arrays.Pipeline.pic },
        .{ "MS:1002314", mzml.arrays.Pipeline.slof },
        .{ "MS:1002746", mzml.arrays.Pipeline.linear_zlib },
        .{ "MS:1002747", mzml.arrays.Pipeline.pic_zlib },
        .{ "MS:1002748", mzml.arrays.Pipeline.slof_zlib },
    };
    inline for (primitives) |primitive| {
        inline for (pipelines) |pipeline| {
            const entries = [_]mzml.cv.Entry{
                .{ .cv = .{ .accession = .{ .raw = primitive[0] } } },
                .{ .cv = .{ .accession = .{ .raw = pipeline[0] } } },
                .{ .cv = .{ .accession = .{ .raw = "X:future-role" } } },
            };
            const array: mzml.model.Node = .{ .kind = .binary_data_array, .params = &entries };
            try std.testing.expectEqualDeep(mzml.model.Encoding{
                .primitive = primitive[1],
                .pipeline = pipeline[1],
            }, try mzml.model.arrayEncoding(array, &.{}));
        }
    }
    const primitive: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = "MS:1000523" } } };
    const compression: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = "MS:1000576" } } };
    const cases = .{
        .{ &[_]mzml.cv.Entry{}, error.MissingPrimitive },
        .{ &[_]mzml.cv.Entry{primitive}, error.MissingCompression },
        .{ &[_]mzml.cv.Entry{ primitive, primitive, compression }, error.ConflictingPrimitive },
        .{ &[_]mzml.cv.Entry{ primitive, compression, compression }, error.ConflictingCompression },
        .{ &[_]mzml.cv.Entry{.{ .group_ref = "absent" }}, error.MissingGroup },
        .{ &[_]mzml.cv.Entry{.{ .cv = .{ .accession = .{ .raw = "MS:1003780" } } }}, error.UnsupportedEncoding },
    };
    inline for (cases) |case| {
        try std.testing.expectError(case[1], mzml.model.arrayEncoding(.{
            .kind = .binary_data_array,
            .params = case[0],
        }, &.{}));
    }
    inline for (.{ "MS:1003088", "MS:1003089", "MS:1003090" }) |accession| {
        const unsupported: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = accession } } };
        const groups = [_]mzml.cv.Group{.{ .id = "codec", .entries = &.{unsupported} }};
        inline for (.{
            &[_]mzml.cv.Entry{ primitive, unsupported, compression },
            &[_]mzml.cv.Entry{ primitive, compression, unsupported },
            &[_]mzml.cv.Entry{ .{ .group_ref = "codec" }, primitive, compression },
        }) |entries| {
            var output: [0]f64 = .{};
            var transport: [1]u8 = undefined;
            var transformed: [1]u8 = undefined;
            try std.testing.expectError(error.UnsupportedEncoding, mzml.model.decodeArray(f64, &output, .{
                .kind = .binary_data_array,
                .params = entries,
                .children = &.{.{ .kind = .binary, .text = "" }},
            }, 0, &groups, .{ .transport = &transport, .transformed = &transformed }, .{}));
        }
    }
}
