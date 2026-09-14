//! Tests source metadata and scientific field access.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

test "[property] - [mzML scientific metadata]: distinguishes absent repeated and contradictory record fields" {
    const model = mzml.model;
    var record: model.Record = .{ .node = .{ .kind = .spectrum }, .id = "scan=1", .index = 0, .default_array_length = 0 };
    try std.testing.expectEqual(null, try record.msLevel(&.{}));
    try std.testing.expectEqual(null, try record.polarity(&.{}));
    try std.testing.expectEqual(null, try record.representation(&.{}));
    try std.testing.expectEqual(@as(usize, 0), record.scans().len);
    try std.testing.expectEqual(@as(usize, 0), record.precursors().len);
    try std.testing.expectEqual(@as(usize, 0), record.products().len);
    const pairs = .{
        .{ "MS:1000130", "MS:1000129", model.Record.polarity, model.Polarity.positive, model.Polarity.negative },
        .{ "MS:1000127", "MS:1000128", model.Record.representation, model.Representation.centroid, model.Representation.profile },
    };
    inline for (pairs) |pair| {
        const first: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = pair[0] }, .value = "" } };
        const second: mzml.cv.Entry = .{ .cv = .{ .accession = .{ .raw = pair[1] } } };
        const groups = [_]mzml.cv.Group{.{ .id = "g", .entries = &.{first} }};
        record.node.params = &.{.{ .group_ref = "g" }};
        try std.testing.expectEqual(pair[3], (try pair[2](record, &groups)).?);
        try std.testing.expectError(error.MissingGroup, pair[2](record, &.{}));
        record.node.params = &.{second};
        try std.testing.expectEqual(pair[4], (try pair[2](record, &.{})).?);
        record.node.params = &.{ .{ .group_ref = "g" }, first };
        try std.testing.expectError(error.RepeatedParameter, pair[2](record, &groups));
        record.node.params = &.{ .{ .group_ref = "g" }, second };
        try std.testing.expectError(error.ConflictingParameter, pair[2](record, &groups));
        record.node.params = &.{.{ .cv = .{ .accession = .{ .raw = "X:future" }, .name = "positive scan" } }};
        try std.testing.expectEqual(null, try pair[2](record, &.{}));
    }
    record.node.params = &.{.{ .cv = .{ .accession = model.Terms.MS_LEVEL, .value = " +2 " } }};
    try std.testing.expectEqual(@as(?i32, 2), try record.msLevel(&.{}));
    record.node.kind = .chromatogram;
    try std.testing.expectEqual(@as(usize, 0), record.precursors().len);
    try std.testing.expectEqual(@as(usize, 0), record.products().len);
    try std.testing.expectError(error.UnexpectedElement, record.msLevel(&.{}));
    try std.testing.expectError(error.UnexpectedElement, record.representation(&.{}));
    record.node.params = &.{.{ .cv = .{ .accession = model.Terms.NEGATIVE_SCAN } }};
    try std.testing.expectEqual(model.Polarity.negative, (try record.polarity(&.{})).?);
    record.node.kind = .scan;
    try std.testing.expectError(error.UnexpectedElement, record.polarity(&.{}));
}

test "[property] - [mzML scientific metadata]: preserves independent fields and propagates scalar errors" {
    const model = mzml.model;
    var scan: model.Node = .{ .kind = .scan };
    var ion: model.Node = .{ .kind = .selected_ion };
    var window: model.Node = .{ .kind = .isolation_window };
    try std.testing.expectEqual(null, try scan.scanStartTime(&.{}));
    try std.testing.expectEqualDeep(model.SelectedIon{ .mz = null, .charge = null, .intensity = null }, try ion.selectedIonValues(&.{}));
    try std.testing.expectEqualDeep(model.IsolationWindow{ .target = null, .lower_offset = null, .upper_offset = null }, try window.isolationWindowValues(&.{}));
    try std.testing.expectError(error.UnexpectedElement, scan.selectedIonValues(&.{}));
    try std.testing.expectError(error.UnexpectedElement, ion.scanStartTime(&.{}));
    try std.testing.expectError(error.UnexpectedElement, ion.isolationWindowValues(&.{}));
    try std.testing.expectError(error.UnexpectedElement, ion.selectedIons());
    const cases = .{
        .{ @as(?[]const u8, null), error.MissingValue }, .{ "", error.EmptyValue },
        .{ "bad", error.InvalidValue },                  .{ "1e9999", error.Overflow },
    };
    inline for (cases) |case| {
        scan.params = &.{.{ .cv = .{ .accession = model.Terms.SCAN_START_TIME, .value = case[0] } }};
        ion.params = &.{.{ .cv = .{ .accession = model.Terms.SELECTED_ION_MZ, .value = case[0] } }};
        window.params = &.{.{ .cv = .{ .accession = model.Terms.ISOLATION_UPPER_OFFSET, .value = case[0] } }};
        try std.testing.expectError(case[1], scan.scanStartTime(&.{}));
        try std.testing.expectError(case[1], ion.selectedIonValues(&.{}));
        try std.testing.expectError(case[1], window.isolationWindowValues(&.{}));
    }
    for ([_][]const u8{ "-2147483648", "2147483647", "0" }, [_]i32{ std.math.minInt(i32), std.math.maxInt(i32), 0 }) |text, expected| {
        ion.params = &.{.{ .cv = .{ .accession = model.Terms.CHARGE_STATE, .value = text } }};
        try std.testing.expectEqual(@as(?i32, expected), (try ion.selectedIonValues(&.{})).charge);
    }
    ion.params = &.{.{ .cv = .{ .accession = model.Terms.CHARGE_STATE, .value = "2147483648" } }};
    try std.testing.expectError(error.Overflow, ion.selectedIonValues(&.{}));
    window.params = &.{ .{ .cv = .{ .accession = model.Terms.ISOLATION_TARGET_MZ, .value = "1" } }, .{ .cv = .{ .accession = model.Terms.ISOLATION_TARGET_MZ, .value = "2" } } };
    try std.testing.expectError(error.RepeatedParameter, window.isolationWindowValues(&.{}));
    scan.params = &.{.{ .group_ref = "missing" }};
    try std.testing.expectError(error.MissingGroup, scan.scanStartTime(&.{}));
}

test "[integration] - [mzML field access]: preserves source units and rejects ambiguous lookups" {
    const model = mzml.model;
    const entries = [_]mzml.cv.Entry{
        .{ .cv = .{ .accession = model.Terms.MS_LEVEL, .value = " +2 " } },
        .{ .cv = .{ .accession = model.Terms.SCAN_START_TIME, .value = "1.25", .unit = .{
            .cv_ref = "units",
            .accession = .{ .raw = "UO:0000031" },
            .name = "minute",
        } } },
    };
    const groups = [_]mzml.cv.Group{.{ .id = "fields", .entries = &entries }};
    var node: model.Node = .{ .kind = .scan, .params = &.{.{ .group_ref = "fields" }} };
    try std.testing.expectEqual(@as(?u32, 2), try node.integer(u32, &groups, model.Terms.MS_LEVEL));
    const time = (try node.number(&groups, model.Terms.SCAN_START_TIME)).?;
    try std.testing.expectEqual(@as(f64, 1.25), time.value);
    try std.testing.expectEqualDeep(entries[1].cv, time.parameter);
    try std.testing.expectEqual(null, try node.number(&groups, model.Terms.SELECTED_ION_MZ));
    try std.testing.expectError(error.MissingGroup, node.parameter(&.{}, model.Terms.MS_LEVEL));
    node.params = &.{ .{ .group_ref = "fields" }, entries[0] };
    try std.testing.expectError(error.RepeatedParameter, node.integer(u32, &groups, model.Terms.MS_LEVEL));
    node.params = &.{.{ .cv = .{ .accession = model.Terms.SCAN_START_TIME, .unit = .{ .name = "" } } }};
    try std.testing.expectError(error.MissingValue, node.number(&.{}, model.Terms.SCAN_START_TIME));
    try std.testing.expectEqualStrings("", (try node.parameter(&.{}, model.Terms.SCAN_START_TIME)).?.unit.name.?);

    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var record = (try reader.nextRecord()).?;
    const role: mzml.cv.Accession = .{ .raw = "X:unknown-role" };
    const array = (try record.arrayByRole(header.groups, role)).?;
    try std.testing.expectEqualStrings("AAAAAAAA8D8=", array.child(.binary).?.text.?);
    try std.testing.expectEqual(null, try record.arrayByRole(header.groups, model.Terms.MZ_ARRAY));
    record.node.children = &.{.{ .kind = .binary_data_array_list, .children = &.{ array, array } }};
    try std.testing.expectError(error.RepeatedArray, record.arrayByRole(header.groups, role));
    record.node.children = &.{.{ .kind = .binary_data_array_list, .children = &.{.{
        .kind = .binary_data_array,
        .params = &.{ .{ .cv = .{ .accession = role } }, .{ .cv = .{ .accession = role } } },
    }} }};
    try std.testing.expectError(error.RepeatedParameter, record.arrayByRole(&.{}, role));
}

test "[integration] - [mzML scientific metadata]: keeps all scans ions and windows across ownership writing and indexed lookup" {
    const source = @embedFile("data/scientific_metadata.mzML");
    var header: mzml.owned.Header = undefined;
    var spectrum: mzml.owned.Record = undefined;
    var chromatogram: mzml.owned.Record = undefined;
    {
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        header = try mzml.owned.Header.init(std.testing.allocator, (try reader.readHeader()).*, .{});
        errdefer header.deinit();
        spectrum = try mzml.owned.Record.init(std.testing.allocator, (try reader.nextRecord()).?, .{});
        errdefer spectrum.deinit();
        chromatogram = try mzml.owned.Record.init(std.testing.allocator, (try reader.nextRecord()).?, .{});
        errdefer chromatogram.deinit();
        try std.testing.expectEqual(null, try reader.nextRecord());
    }
    defer header.deinit();
    defer spectrum.deinit();
    defer chromatogram.deinit();

    const groups = header.value.groups;
    const record = spectrum.value;
    try std.testing.expectEqual(@as(?i32, 2), try record.msLevel(groups));
    try std.testing.expectEqual(mzml.model.Polarity.positive, (try record.polarity(groups)).?);
    try std.testing.expectEqual(mzml.model.Representation.centroid, (try record.representation(groups)).?);
    const scans = record.scans();
    try std.testing.expectEqual(@as(usize, 2), scans.len);
    const time = (try scans[0].scanStartTime(groups)).?;
    try std.testing.expectEqual(@as(f64, 1.25), time.value);
    try std.testing.expectEqualStrings("UO:0000031", time.parameter.unit.accession.?.raw);
    try std.testing.expectEqual(@as(f64, 76), (try scans[1].scanStartTime(groups)).?.value);
    const nodes = header.value.document.child(.cv_list).?.children;
    var declarations: [2]mzml.cv.Declaration = undefined;
    for (&declarations, nodes) |*declaration, node| declaration.* = .{
        .id = node.attribute("id"),
        .full_name = node.attribute("fullName"),
        .uri = node.attribute("URI"),
        .version = node.attribute("version"),
    };
    const resolver = mzml.cv.Resolver.init(&declarations);
    const quantity = try resolver.quantity(f64, time.parameter);
    try std.testing.expectEqual(@as(f64, 1.25), quantity.value);
    try std.testing.expectEqual(.allowed, quantity.parameter.unit_allowed);
    try std.testing.expectEqual(.historical, quantity.parameter.term.version);
    try std.testing.expectEqualStrings("minute", quantity.parameter.unit.match.?.term.name);

    const precursors = record.precursors();
    try std.testing.expectEqual(@as(usize, 2), precursors.len);
    const ions = try precursors[0].selectedIons();
    try std.testing.expectEqual(@as(usize, 2), ions.len);
    const ion = try ions[0].selectedIonValues(groups);
    try std.testing.expectEqual(@as(f64, 500.25), ion.mz.?.value);
    try std.testing.expectEqual(@as(?i32, -2), ion.charge);
    try std.testing.expectEqual(@as(f64, 250), ion.intensity.?.value);
    const other = try ions[1].selectedIonValues(groups);
    try std.testing.expectEqual(@as(f64, 501), other.mz.?.value);
    try std.testing.expectEqual(null, other.charge);
    try std.testing.expectEqual(null, other.intensity);
    try std.testing.expectEqual(@as(usize, 0), (try precursors[1].selectedIons()).len);
    const window = try precursors[0].child(.isolation_window).?.isolationWindowValues(groups);
    try std.testing.expectEqual(@as(f64, 500), window.target.?.value);
    try std.testing.expectEqual(@as(f64, 0.5), window.lower_offset.?.value);
    try std.testing.expect(window.lower_offset.?.parameter.unit.isAbsent());
    try std.testing.expectEqual(@as(f64, 1.5), window.upper_offset.?.value);
    try std.testing.expectEqualStrings("", window.upper_offset.?.parameter.unit.name.?);
    try std.testing.expectEqual(.partial, (try resolver.quantity(f64, window.upper_offset.?.parameter)).parameter.unit_fields);
    const activation = precursors[0].child(.activation).?;
    try std.testing.expectEqual(@as(usize, 3), activation.params.len);
    try std.testing.expectEqualStrings("MS:1000133", activation.params[0].cv.accession.?.raw);
    try std.testing.expectEqualStrings("MS:1000598", activation.params[1].cv.accession.?.raw);
    try std.testing.expectEqual(@as(f64, 30), (try activation.number(groups, .{ .raw = "MS:1000045" })).?.value);
    try std.testing.expectEqual(@as(usize, 2), record.products().len);
    try std.testing.expectEqual(null, record.products()[1].child(.isolation_window));
    const chrom = chromatogram.value;
    try std.testing.expectEqual(@as(usize, 0), chrom.scans().len);
    try std.testing.expectEqual(@as(usize, 1), chrom.precursors().len);
    try std.testing.expectEqual(@as(usize, 1), chrom.products().len);
    try std.testing.expectEqual(mzml.model.Polarity.negative, (try chrom.polarity(groups)).?);
    try std.testing.expectEqual(@as(f64, 600), (try chrom.precursors()[0].child(.isolation_window).?.isolationWindowValues(groups)).target.?.value);
    try std.testing.expectEqual(@as(f64, 100), (try chrom.products()[0].child(.isolation_window).?.isolationWindowValues(groups)).target.?.value);

    var bytes: [8192]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header.value);
    try writer.beginList(.spectrum_list, 1, "dp");
    try writer.writeRecord(record.node);
    try writer.endList();
    try writer.beginList(.chromatogram_list, 1, "dp");
    try writer.writeRecord(chrom.node);
    try writer.endList();
    try writer.finish();
    var rewritten_input = std.Io.Reader.fixed(sink.buffered());
    var rewritten = try mzml.StreamReader.init(std.testing.allocator, &rewritten_input, .{});
    defer rewritten.deinit();
    try support.expectNode(header.value.document, (try rewritten.readHeader()).document);
    try support.expectNode(record.node, (try rewritten.nextRecord()).?.node);
    try support.expectNode(chrom.node, (try rewritten.nextRecord()).?.node);
    try std.testing.expectEqual(null, try rewritten.nextRecord());

    var indexed_header: mzml.owned.Header = undefined;
    var indexed_record: mzml.owned.Record = undefined;
    {
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{
            .policy = .rebuild,
        });
        defer index.deinit();
        indexed_header = try mzml.owned.Header.init(std.testing.allocator, index.header().*, .{});
        errdefer indexed_header.deinit();
        indexed_record = (try index.byId(std.testing.allocator, record.id)).?;
    }
    defer indexed_header.deinit();
    defer indexed_record.deinit();
    const indexed_groups = indexed_header.value.groups;
    try std.testing.expectEqualDeep(groups, indexed_groups);
    try support.expectNode(record.node, indexed_record.value.node);
    try std.testing.expectEqual(@as(?i32, 2), try indexed_record.value.msLevel(indexed_groups));
    try std.testing.expectEqual(mzml.model.Polarity.positive, (try indexed_record.value.polarity(indexed_groups)).?);
    try std.testing.expectEqual(mzml.model.Representation.centroid, (try indexed_record.value.representation(indexed_groups)).?);
    try std.testing.expectEqualDeep(time, (try indexed_record.value.scans()[0].scanStartTime(indexed_groups)).?);
    const indexed_ions = try indexed_record.value.precursors()[0].selectedIons();
    try std.testing.expectEqualDeep(ion, try indexed_ions[0].selectedIonValues(indexed_groups));
}
