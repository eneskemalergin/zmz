//! Tests document structure, references, and validation.

const std = @import("std");
const mzml = @import("z_mzml");
const support = @import("support.zig");

test "[integration] - [mzML document validation]: owns reference storage and cleans allocation failures" {
    try support.retainValidationReferences(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.retainValidationReferences, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.validatedRewriteAllocated, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.readAll, .{
        support.REFERENCED_DOCUMENT, mzml.StreamReader.Options{ .validation = .{}, .payload = .skip },
    });
    const limits = [_]mzml.Validator.Limits{
        .{ .identifiers = 4 },             .{ .identifiers = 7 },             .{ .forward_references = 1 }, .{ .bytes = 0 },
        .{ .structure = .{ .depth = 2 } }, .{ .structure = .{ .nodes = 1 } },
    };
    for (limits) |limit| {
        try std.testing.expectError(error.LimitExceeded, support.readAll(std.testing.allocator, support.REFERENCED_DOCUMENT, .{ .validation = limit }));
    }
    try support.readAll(std.testing.allocator, support.REFERENCED_DOCUMENT, .{ .validation = .{ .identifiers = 8, .forward_references = 2 } });
    try std.testing.expectError(error.InvalidOptions, support.readAll(std.testing.allocator, support.REFERENCED_DOCUMENT, .{ .validation = .{ .structure = .{ .depth = 0 } } }));
}

test "[integration] - [mzML document validation]: reports unresolved references at EOF and keeps failures sticky" {
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.REFERENCED_DOCUMENT, "spectrumRef='scan=2'", "spectrumRef='absent'");
    defer std.testing.allocator.free(source);
    var input = std.Io.Reader.fixed(source);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .validation = .{} });
    defer reader.deinit();
    for (0..3) |_| try std.testing.expect(try reader.nextRecord() != null);
    try std.testing.expectError(error.MissingReference, reader.nextRecord());
    const diagnostic = reader.diagnostic().?;
    try std.testing.expectEqual(.scan, diagnostic.element.?);
    try std.testing.expectEqual(@as(u64, std.mem.indexOf(u8, source, "<scan spectrumRef").?), diagnostic.byte_offset);
    try std.testing.expectError(error.FailedState, reader.nextRecord());
    try std.testing.expectEqualDeep(diagnostic, reader.diagnostic().?);
    const units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(units);
    const encoded = try std.testing.allocator.alloc(u8, 2 + units.len * 2);
    defer std.testing.allocator.free(encoded);
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        std.mem.writeInt(u16, encoded[0..2], 0xfeff, endian);
        for (units, 0..) |unit, i| std.mem.writeInt(u16, encoded[2 + i * 2 ..][0..2], std.mem.littleToNative(u16, unit), endian);
        var utf16_input = std.Io.Reader.fixed(encoded);
        var utf16_reader = try mzml.StreamReader.init(std.testing.allocator, &utf16_input, .{ .validation = .{} });
        defer utf16_reader.deinit();
        for (0..3) |_| try std.testing.expect(try utf16_reader.nextRecord() != null);
        try std.testing.expectError(error.MissingReference, utf16_reader.nextRecord());
        const location = utf16_reader.diagnostic().?;
        try std.testing.expectEqual(.scan, location.element.?);
        try std.testing.expectEqual(2 + diagnostic.byte_offset * 2, location.byte_offset);
        try std.testing.expectError(error.FailedState, utf16_reader.nextRecord());
        try std.testing.expectEqualDeep(location, utf16_reader.diagnostic().?);
    }
    const mismatched = try std.mem.replaceOwned(u8, std.testing.allocator, support.REFERENCED_DOCUMENT, "<spectrumList count='2'", "<spectrumList count='3'");
    defer std.testing.allocator.free(mismatched);
    try std.testing.expectError(error.CountMismatch, support.readAll(std.testing.allocator, mismatched, .{ .validation = .{}, .check_counts = false }));
    var raw_input = std.Io.Reader.fixed(support.DOCUMENT);
    var raw_reader = try mzml.StreamReader.init(std.testing.allocator, &raw_input, .{});
    defer raw_reader.deinit();
    const header = try raw_reader.readHeader();
    const record = (try raw_reader.nextRecord()).?;
    var output: [8192]u8 = undefined;
    var sink = std.Io.Writer.fixed(&output);
    var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();
    try writer.enableValidation(.{});
    try writer.writeHeader(header.*);
    try writer.beginList(.spectrum_list, 1, "dp");
    try writer.writeRecord(record.node);
    try writer.endList();
    try std.testing.expectError(error.MissingReference, writer.finish());
    try std.testing.expect(!std.mem.endsWith(u8, sink.buffered(), "</mzML>"));
    try std.testing.expectError(error.FailedState, writer.finish());
    var failed_sink = std.Io.Writer.fixed(&.{});
    var failed = try mzml.Writer.init(std.testing.allocator, &failed_sink, .{});
    defer failed.deinit();
    try failed.enableValidation(.{});
    try std.testing.expectError(error.WriteFailed, failed.writeHeader(header.*));
    try std.testing.expectError(error.FailedState, failed.finish());
}

test "[integration] - [mzML document validation]: checks external source references without opening external files" {
    const with_file = try std.mem.replaceOwned(u8, std.testing.allocator, support.REFERENCED_DOCUMENT, "</fileDescription>", "<sourceFileList count='1'><sourceFile id='sf' name='unavailable.raw' location='file:///not-opened/'/></sourceFileList></fileDescription>");
    defer std.testing.allocator.free(with_file);
    const external = try std.mem.replaceOwned(u8, std.testing.allocator, with_file, "spectrumRef='scan=2'", "externalSpectrumID='outside=1' sourceFileRef='sf'");
    defer std.testing.allocator.free(external);
    try support.readAll(std.testing.allocator, external, .{ .validation = .{} });
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try support.rewriteValidated(std.testing.allocator, external, &discard.writer, false);
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, external, " sourceFileRef='sf'", "");
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.InvalidReference, support.readAll(std.testing.allocator, missing, .{ .validation = .{} }));
    const settings = try std.mem.replaceOwned(u8, std.testing.allocator, external, "<instrumentConfigurationList", "<scanSettingsList count='1'><scanSettings id='settings'><sourceFileRefList count='1'><sourceFileRef ref='sf'/></sourceFileRefList></scanSettings></scanSettingsList><instrumentConfigurationList");
    defer std.testing.allocator.free(settings);
    try support.readAll(std.testing.allocator, settings, .{ .validation = .{} });
    const wrong_kind = try std.mem.replaceOwned(u8, std.testing.allocator, settings, "<sourceFileRef ref='sf'/>", "<sourceFileRef ref='sw'/>");
    defer std.testing.allocator.free(wrong_kind);
    try std.testing.expectError(error.WrongReferenceKind, support.readAll(std.testing.allocator, wrong_kind, .{ .validation = .{} }));
    const instrument = try std.mem.replaceOwned(u8, std.testing.allocator, settings, "<instrumentConfiguration id='ic'/>", "<instrumentConfiguration id='ic' scanSettingsRef='settings'><softwareRef ref='sw'/></instrumentConfiguration>");
    defer std.testing.allocator.free(instrument);
    const sample = try std.mem.replaceOwned(u8, std.testing.allocator, instrument, "<softwareList", "<sampleList count='1'><sample id='sample'/></sampleList><softwareList");
    defer std.testing.allocator.free(sample);
    const run = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "<run id=", "<run sampleRef='sample' defaultSourceFileRef='sf' id=");
    defer std.testing.allocator.free(run);
    try support.readAll(std.testing.allocator, run, .{ .validation = .{} });
    try support.rewriteValidated(std.testing.allocator, run, &discard.writer, true);
}

test "[integration] - [mzML document validation]: resolves forward references only at completion" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    var validator = try mzml.Validator.init(std.testing.allocator, (try reader.readHeader()).*, .{});
    defer validator.deinit();
    try validator.beginList(.{ .kind = .spectrum_list, .attributes = &.{
        .{ .name = "count", .value = "2" },
        .{ .name = "defaultDataProcessingRef", .value = "dp" },
    } });
    var attrs = [_]mzml.model.Attribute{
        .{ .name = "id", .value = "scan=1" },
        .{ .name = "index", .value = "0" },
        .{ .name = "defaultArrayLength", .value = "0" },
    };
    var node: mzml.model.Node = .{ .kind = .spectrum, .attributes = &attrs, .children = &.{.{
        .kind = .scan_list,
        .attributes = &.{.{ .name = "count", .value = "1" }},
        .children = &.{.{ .kind = .scan, .attributes = &.{.{ .name = "spectrumRef", .value = "scan=2" }} }},
    }} };
    try validator.record(node);
    attrs[0].value = "scan=2";
    attrs[1].value = "1";
    node.children = &.{};
    try validator.record(node);
    try validator.endList();
    try validator.finish();
    try std.testing.expectEqual(null, validator.diagnostic());
    try std.testing.expectError(error.InvalidState, validator.finish());
    try std.testing.expectError(error.FailedState, validator.endList());
}

test "[integration] - [mzML document validation]: checks timestamp and identifier spellings without rewriting them" {
    const empty = support.HEADER ++ "</run></mzML>";
    inline for (.{
        "2024-02-29T12:34:56Z",               "2000-02-29T24:00:00.000+14:00",         "1900-02-28T00:00:00-14:00",
        "2026-09-09T00:00:00",                " 2026-09-09T01:02:03.123456789+00:30 ", "-0004-02-29T00:00:00Z",
        "123456789012345600-02-29T00:00:00Z",
    }) |timestamp| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, empty, "<run id=", "<run startTimeStamp='" ++ timestamp ++ "' id=");
        defer std.testing.allocator.free(source);
        try support.readAll(std.testing.allocator, source, .{ .validation = .{} });
        var output: [4096]u8 = undefined;
        var sink = std.Io.Writer.fixed(&output);
        try support.rewriteValidated(std.testing.allocator, source, &sink, false);
        var input = std.Io.Reader.fixed(sink.buffered());
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .validation = .{} });
        defer reader.deinit();
        try std.testing.expectEqualStrings(timestamp, (try reader.readHeader()).run.attribute("startTimeStamp").?);
    }
    inline for (.{
        "",                          "today",                     "0000-01-01T00:00:00Z",   "+2026-01-01T00:00:00Z",     "02026-01-01T00:00:00Z",
        "1900-02-29T00:00:00Z",      "2023-02-29T00:00:00Z",      "2026-04-31T00:00:00Z",   "2026-00-01T00:00:00Z",      "2026-13-01T00:00:00Z",
        "2026-01-00T00:00:00Z",      "2026-01-01t00:00:00Z",      "2026-01-01T24:00:00.1Z", "2026-01-01T24:01:00Z",      "2026-01-01T25:00:00Z",
        "2026-01-01T00:60:00Z",      "2026-01-01T00:00:60Z",      "2026-01-01T00:00:00.Z",  "2026-01-01T00:00:00+14:01", "2026-01-01T00:00:00-15:00",
        "2026-01-01T00:00:00+00:60", "2026-01-01T00:00:00Zextra",
    }) |timestamp| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, empty, "<run id=", "<run startTimeStamp='" ++ timestamp ++ "' id=");
        defer std.testing.allocator.free(source);
        try support.readAll(std.testing.allocator, source, .{});
        try std.testing.expectError(error.InvalidValue, support.readAll(std.testing.allocator, source, .{ .validation = .{} }));
        var discard: std.Io.Writer.Discarding = .init(&.{});
        try std.testing.expectError(error.InvalidValue, support.rewriteValidated(std.testing.allocator, source, &discard.writer, false));
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        var builder = mzml.Builder.init(std.testing.allocator, .{});
        defer builder.deinit();
        try std.testing.expectError(error.InvalidValue, builder.header((try reader.readHeader()).*));
    }
    inline for (.{ "", "1bad", "a:b", "two words", "a&#9;b" }) |id| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, empty, "id='ic'", "id='" ++ id ++ "'");
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.InvalidDeclaration, support.readAll(std.testing.allocator, source, .{ .validation = .{} }));
    }
    inline for (.{ "ic", "器", "a&#x301;", "_a-1." }) |id| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, empty, "'ic'", "' " ++ id ++ " '");
        defer std.testing.allocator.free(source);
        try support.readAll(std.testing.allocator, source, .{ .validation = .{} });
    }
    const normalized = try std.mem.replaceOwned(u8, std.testing.allocator, support.REFERENCED_DOCUMENT, "id='encoding'", "id=' encoding '");
    defer std.testing.allocator.free(normalized);
    var input = std.Io.Reader.fixed(normalized);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .validation = .{} });
    defer reader.deinit();
    const header = try reader.readHeader();
    const record = (try reader.nextRecord()).?;
    try std.testing.expectEqualStrings(" encoding ", header.groups[0].id);
    var values: [1]f64 = undefined;
    var transport: [32]u8 = undefined;
    var transformed: [32]u8 = undefined;
    try mzml.model.decodeArray(f64, &values, record.binaryArrays()[0], 1, header.groups, .{ .transport = &transport, .transformed = &transformed }, .{});
    try std.testing.expectEqual(@as(f64, 1), values[0]);
    while (try reader.nextRecord()) |_| {}
    for ([_][]const u8{ "bad\x00text", "bad\xfftext", "bad\x01text" }) |text| {
        var bad_header = header.*;
        bad_header.document.attributes = &.{
            .{ .name = "version", .value = "1.1.0" },
            .{ .name = "id", .value = text },
        };
        try std.testing.expectError(error.InvalidValue, mzml.Validator.init(std.testing.allocator, bad_header, .{}));
        var builder = mzml.Builder.init(std.testing.allocator, .{});
        defer builder.deinit();
        try std.testing.expectError(error.InvalidValue, builder.header(bad_header));
    }
}

test "[integration] - [mzML document validation]: shares reference checks across reading and writing" {
    try support.readAll(std.testing.allocator, support.REFERENCED_DOCUMENT, .{ .validation = .{} });
    try support.readAll(std.testing.allocator, support.REFERENCED_DOCUMENT, .{ .validation = .{}, .payload = .skip });
    inline for (.{ "scan=1", "", "MS" }) |id| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.REFERENCED_DOCUMENT, "id='tic'", "id='" ++ id ++ "'");
        defer std.testing.allocator.free(source);
        try support.readAll(std.testing.allocator, source, .{ .validation = .{} });
        var output: [16384]u8 = undefined;
        var sink = std.Io.Writer.fixed(&output);
        try support.rewriteValidated(std.testing.allocator, source, &sink, true);
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{
            .policy = .verify_embedded,
            .reader = .{ .validation = .{} },
        });
        defer index.deinit();
        var record = (try index.at(std.testing.allocator, .chromatogram, 0)).?;
        defer record.deinit();
        try std.testing.expectEqualStrings(id, record.value.id);
    }
    const cases = .{
        .{ "defaultInstrumentConfigurationRef='ic'", "defaultInstrumentConfigurationRef='absent'", error.MissingReference },
        .{ "defaultInstrumentConfigurationRef='ic'", "defaultInstrumentConfigurationRef='sw'", error.WrongReferenceKind },
        .{ "defaultDataProcessingRef='dp'", "defaultDataProcessingRef='absent'", error.MissingReference },
        .{ "defaultDataProcessingRef='dp'", "defaultDataProcessingRef='ic'", error.WrongReferenceKind },
        .{ "softwareRef='sw'", "softwareRef='absent'", error.MissingReference },
        .{ "softwareRef='sw'", "softwareRef='ic'", error.WrongReferenceKind },
        .{ "ref='encoding'", "ref='absent'", error.MissingReference },
        .{ "ref='encoding'", "ref='sw'", error.WrongReferenceKind },
        .{ "cvRef='MS'", "cvRef='absent'", error.MissingReference },
        .{ "cvRef='MS'", "cvRef='sw'", error.WrongReferenceKind },
        .{ "unitCvRef='MS'", "unitCvRef='absent'", error.MissingReference },
        .{ "unitCvRef='MS'", "unitCvRef='sw'", error.WrongReferenceKind },
        .{ "instrumentConfigurationRef='ic'", "instrumentConfigurationRef='sw'", error.WrongReferenceKind },
        .{ "dataProcessingRef='dp'", "dataProcessingRef='absent'", error.MissingReference },
        .{ "spectrumRef='scan=2'", "spectrumRef='absent'", error.MissingReference },
        .{ "spectrumRef='scan=2'", "spectrumRef='tic'", error.WrongReferenceKind },
        .{ "id='scan=2'", "id='scan=1'", error.DuplicateId },
        .{ "index='1'", "index='2'", error.InvalidIndex },
        .{ "id='scan=1'", "id='not-a-native-id'", error.InvalidDeclaration },
        .{ "id='r'", "id=''", error.InvalidDeclaration },
        .{ "id='ic'", "id='sw'", error.DuplicateId },
        .{ "<scan spectrumRef", "<scan sourceFileRef='sw' spectrumRef", error.WrongReferenceKind },
        .{ "<precursor spectrumRef", "<precursor sourceFileRef='absent' spectrumRef", error.MissingReference },
        .{ "<spectrum id=", "<spectrum sourceFileRef='absent' id=", error.MissingReference },
        .{ "<binaryDataArray encodedLength", "<binaryDataArray dataProcessingRef='sw' encodedLength", error.WrongReferenceKind },
        .{ "<run id=", "<run sampleRef='sw' id=", error.WrongReferenceKind },
        .{ "<run id=", "<run defaultSourceFileRef='ic' id=", error.WrongReferenceKind },
        .{ "<instrumentConfiguration id='ic'/>", "<instrumentConfiguration id='ic' scanSettingsRef='sw'/>", error.WrongReferenceKind },
        .{ "<instrumentConfiguration id='ic'/>", "<instrumentConfiguration id='ic'><softwareRef ref='ic'/></instrumentConfiguration>", error.WrongReferenceKind },
    };
    inline for (cases) |case| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.REFERENCED_DOCUMENT, case[0], case[1]);
        defer std.testing.allocator.free(source);
        try std.testing.expectError(case[2], support.readAll(std.testing.allocator, source, .{ .validation = .{} }));
        try support.readAll(std.testing.allocator, source, .{});
        var discard: std.Io.Writer.Discarding = .init(&.{});
        try std.testing.expectError(case[2], support.rewriteValidated(std.testing.allocator, source, &discard.writer, false));
    }
    for ([_]bool{ false, true }) |indexed| {
        var output: [16384]u8 = undefined;
        var sink = std.Io.Writer.fixed(&output);
        try support.rewriteValidated(std.testing.allocator, support.REFERENCED_DOCUMENT, &sink, indexed);
        try support.readAll(std.testing.allocator, sink.buffered(), .{ .validation = .{} });
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{
            .policy = if (indexed) .verify_embedded else .rebuild,
            .reader = .{ .validation = .{} },
        });
        defer index.deinit();
        try std.testing.expectEqual(@as(usize, 3), index.entries.items.len);
    }
}

test "[integration] - [mzML document validation]: checks trailer spellings without claiming index integrity" {
    const source = "<indexedmzML xmlns='http://psi.hupo.org/ms/mzml'>" ++ support.HEADER ++
        "</run></mzML><indexList count='1'><index name='spectrum'><offset idRef='absent' scanTime='INF'>0</offset></index>" ++
        "</indexList><indexListOffset>0</indexListOffset><fileChecksum>not-verified</fileChecksum></indexedmzML>";
    try support.readAll(std.testing.allocator, source, .{ .validation = .{} });
    try std.testing.expectError(error.InvalidIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .verify_embedded }));
    const cases = .{
        .{ "<indexedmzML ", "<indexedmzML unexpected='1' ", error.UnknownAttribute },
        .{ "<indexList count='1'>", "<indexList count='2'>", error.CountMismatch },
        .{ "name='spectrum'", "name='other'", error.InvalidDeclaration },
        .{ "scanTime='INF'", "scanTime='now'", error.InvalidValue },
        .{ ">0</offset>", ">9223372036854775808</offset>", error.Overflow },
        .{ ">0</indexListOffset>", ">missing</indexListOffset>", error.InvalidValue },
    };
    inline for (cases) |case| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, case[0], case[1]);
        defer std.testing.allocator.free(changed);
        try support.readAll(std.testing.allocator, changed, .{});
        try support.readAll(std.testing.allocator, changed, .{ .retain_index = true, .check_counts = false });
        try std.testing.expectError(case[2], support.readAll(std.testing.allocator, changed, .{ .validation = .{} }));
        try std.testing.expectError(case[2], support.readAll(std.testing.allocator, changed, .{ .validation = .{}, .check_counts = false }));
    }
}
