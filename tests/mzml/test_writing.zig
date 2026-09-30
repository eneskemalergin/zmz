//! Tests plain, indexed, and prepared writing.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

test "[failure] - [mzML diagnostics]: reports writer counts indexes and allocation failures" {
    const header: mzml.model.Header = .{ .document = .{ .kind = .mzml }, .run = .{ .kind = .run } };
    for (0..4) |case| {
        var bytes: [4096]u8 = undefined;
        var sink = std.Io.Writer.fixed(&bytes);
        var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
        defer writer.deinit();
        try writer.writeHeader(header);
        try writer.beginListWithAttributes(.spectrum_list, 1, &.{});
        const node: mzml.model.Node = .{ .kind = .spectrum, .attributes = if (case == 3) &.{} else &.{.{ .name = "index", .value = if (case == 0) "4" else "0" }} };
        switch (case) {
            0 => try std.testing.expectError(error.InvalidIndex, writer.writeRecord(node)),
            1 => try std.testing.expectError(error.CountMismatch, writer.endList()),
            2 => {
                try writer.writeRecord(node);
                try std.testing.expectError(error.CountMismatch, writer.writeItem(.{ .record = .{ .node = node, .id = "", .index = null, .default_array_length = null } }));
            },
            3 => try std.testing.expectError(error.MissingValue, writer.writeRecord(node)),
            else => unreachable,
        }
        const report = writer.diagnostic().?;
        if (case == 3) {
            try std.testing.expectEqual(.index, report.detail.attribute);
        } else {
            try std.testing.expectEqual(@as(u64, if (case == 0) 0 else 1), report.detail.size.expected);
            try std.testing.expectEqual(@as(u64, if (case == 0) 4 else if (case == 1) 0 else 2), report.detail.size.actual);
        }
        const operation: mzml.Diagnostic.Operation = if (case == 2) .write_item else if (case == 1) .close_list else .write_record;
        try std.testing.expectEqual(operation, report.operation);
        try std.testing.expect(report.location.?.output_byte > 0);
        try std.testing.expectError(error.FailedState, writer.finish());
        try std.testing.expectEqualDeep(report, writer.diagnostic().?);
    }
    const Check = struct {
        fn emit(writer: *mzml.Writer) mzml.Writer.Error!void {
            try writer.writeHeader(header);
            try writer.beginListWithAttributes(.spectrum_list, 1, &.{});
            try writer.writeRecord(.{ .kind = .spectrum, .attributes = &.{ .{ .name = "index", .value = "0" }, .{ .name = "id", .value = "first" } } });
            try writer.endList();
            try writer.finish();
        }
        fn run(allocator: std.mem.Allocator) !void {
            var bytes: [4096]u8 = undefined;
            var sink = std.Io.Writer.fixed(&bytes);
            var writer = try mzml.Writer.initIndexed(allocator, &sink, .{}, .{});
            defer writer.deinit();
            emit(&writer) catch |err| {
                const report = writer.diagnostic().?;
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(err, report.code);
                try std.testing.expectEqual(.out_of_memory, report.id);
                var text: [512]u8 = undefined;
                var output = std.Io.Writer.fixed(&text);
                try report.format(&output);
                return err;
            };
            try std.testing.expectEqual(null, writer.diagnostic());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "[integration] - [mzML items]: retains empty-list XML and indexes following chromatograms" {
    const source = "<mzML xmlns='http://psi.hupo.org/ms/mzml' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'><run>" ++
        "<spectrumList count='0'><first/><software/></spectrumList><between/><scan/>" ++
        "<chromatogramList count='1'><before/><chromatogram id='c' index='0' defaultArrayLength='0'/>" ++
        "<after/></chromatogramList><last/></run><tail/></mzML>";
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try support.rewriteDocument(std.testing.allocator, source, &sink.writer, true);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.written() }, .{});
    defer index.deinit();
    var record = (try index.at(std.testing.allocator, .chromatogram, 0)).?;
    defer record.deinit();
    try std.testing.expectEqualStrings("c", record.value.id);
    try std.testing.expectEqual(@as(usize, 0), index.header().spectrum_list.?.declared_count);
    var source_input = std.Io.Reader.fixed(source);
    var original = try mzml.StreamReader.init(std.testing.allocator, &source_input, .{});
    defer original.deinit();
    var output_input = std.Io.Reader.fixed(sink.written());
    var written = try mzml.StreamReader.init(std.testing.allocator, &output_input, .{});
    defer written.deinit();
    while (try original.nextItem()) |item| try support.expectItem(item, (try written.nextItem()).?);
    try std.testing.expectEqual(null, try written.nextItem());
}

test "[integration] - [mzML items]: preserves XML positions through owned plain and indexed copies" {
    const source = support.STREAM_EXTENSIONS;
    var items: std.ArrayList(mzml.owned.Item) = .empty;
    defer {
        for (items.items) |*item| item.deinit();
        items.deinit(std.testing.allocator);
    }
    var header = blk: {
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const retained = try mzml.owned.Header.init(std.testing.allocator, (try reader.readHeader()).*, .{});
        errdefer {
            var failed = retained;
            failed.deinit();
        }
        while (try reader.nextItem()) |item| {
            var retained_item = try mzml.owned.Item.init(std.testing.allocator, item, .{});
            errdefer retained_item.deinit();
            try items.append(std.testing.allocator, retained_item);
        }
        break :blk retained;
    };
    defer header.deinit();
    const tags = [_]std.meta.Tag(mzml.model.Item){
        .list_start, .xml, .record, .xml, .record,   .xml, .list_end, .xml,
        .list_start, .xml, .record, .xml, .list_end, .xml, .run_end,  .xml,
    };
    try std.testing.expectEqual(tags.len, items.items.len);
    for (items.items, tags) |item, tag| try std.testing.expectEqual(tag, std.meta.activeTag(item.value));
    const Check = struct {
        fn copy(allocator: std.mem.Allocator, source_item: mzml.model.Item) !void {
            var result = try mzml.owned.Item.init(allocator, source_item, .{});
            defer result.deinit();
            try support.expectItem(source_item, result.value);
        }
    };
    for (items.items) |item|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.copy, .{item.value});

    for ([_]bool{ false, true }) |indexed| {
        var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer sink.deinit();
        var writer = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &sink.writer, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &sink.writer, .{});
        defer writer.deinit();
        try writer.writeHeader(header.value);
        for (items.items) |item| try writer.writeItem(item.value);
        try writer.finish();
        var input = std.Io.Reader.fixed(sink.written());
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .retain_index = indexed });
        defer reader.deinit();
        for (items.items) |expected| {
            const actual = (try reader.nextItem()).?;
            try support.expectItem(expected.value, actual);
        }
        try std.testing.expectEqual(null, try reader.nextItem());
        try std.testing.expectEqual(null, try reader.nextItem());
        if (indexed) try std.testing.expect(reader.indexTrailer() != null);
        for ([_]mzml.IndexedReader.Policy{ .rebuild, .open_embedded }) |policy| {
            if (!indexed and policy == .open_embedded) continue;
            var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.written() }, .{ .policy = policy });
            defer index.deinit();
            for ([_][]const u8{ "s0", "s1", "c0" }) |id| {
                var found = (try index.byId(std.testing.allocator, id)).?;
                defer found.deinit();
                try std.testing.expectEqualStrings(id, found.value.id);
            }
        }
    }
}

test "[failure] - [mzML items]: rejects misplaced items and propagates failed output" {
    for (0..3) |phase| {
        var bytes: [1024]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&bytes);
        var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
        defer writer.deinit();
        if (phase != 0) try writer.writeHeader(.{ .document = .{ .kind = .mzml }, .run = .{ .kind = .run } });
        if (phase == 1) try writer.finish();
        const item: mzml.model.Item = .{ .xml = "<note>" ++ "x" ** 2048 ++ "</note>" };
        try std.testing.expectError(if (phase == 2) error.WriteFailed else error.InvalidState, writer.writeItem(item));
        try std.testing.expectError(error.FailedState, writer.finish());
    }
}

test "[integration] - [mzML children]: copies retained XML without indexing nested records" {
    const allocator = std.testing.allocator;
    const Case = struct { source: []const u8, fragments: usize };
    for ([_]Case{
        .{ .source = support.KNOWN_CHILDREN, .fragments = 7 },
        .{ .source = support.REPEATED_CONTAINERS, .fragments = 0 },
    }) |case| for ([_]bool{ false, true }) |indexed| {
        var input = std.Io.Reader.fixed(case.source);
        var reader = try mzml.StreamReader.init(allocator, &input, .{});
        defer reader.deinit();
        var builder = mzml.Builder.init(allocator, .{});
        defer builder.deinit();
        const header = try builder.header((try reader.readHeader()).*);
        var sink: std.Io.Writer.Allocating = .init(allocator);
        defer sink.deinit();
        var writer = if (indexed) try mzml.Writer.initIndexed(allocator, &sink.writer, .{}, .{}) else try mzml.Writer.init(allocator, &sink.writer, .{});
        defer writer.deinit();
        try writer.writeHeader(header);
        var item = try reader.nextItem();
        while (item) |current| {
            var copy = try mzml.owned.Item.init(allocator, current, .{});
            defer copy.deinit();
            item = try reader.nextItem();
            try writer.writeItem(copy.value);
        }
        try writer.finish();
        var original_input = std.Io.Reader.fixed(case.source);
        var original = try mzml.StreamReader.init(allocator, &original_input, .{});
        defer original.deinit();
        var written_input = std.Io.Reader.fixed(sink.written());
        var written = try mzml.StreamReader.init(allocator, &written_input, .{ .retain_index = indexed });
        defer written.deinit();
        const copied_header = try written.readHeader();
        try support.expectNode(header.document, copied_header.document);
        try support.expectNode(header.run, copied_header.run);
        var fragments: usize = 0;
        while (try original.nextItem()) |expected| {
            try support.expectItem(expected, (try written.nextItem()).?);
            if (expected == .xml) fragments += 1;
        }
        try std.testing.expectEqual(case.fragments, fragments);
        try std.testing.expectEqual(null, try written.nextItem());
        for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
            if (!indexed and policy == .open_embedded) continue;
            var index = try mzml.IndexedReader.build(allocator, .{ .bytes = sink.written() }, .{ .policy = policy });
            defer index.deinit();
            try std.testing.expectEqualDeep([_]usize{ 1, 1 }, index.counts);
            try std.testing.expectEqual(null, try index.byId(allocator, "not-a-record"));
            var decoded = mzml.StreamReader.DecodedArrays.init(allocator, .{});
            defer decoded.deinit();
            for (index.entries.items) |entry| {
                var retained = (try index.byId(allocator, entry.id)).?;
                defer retained.deinit();
                var numeric = (try index.atDecoded(allocator, entry.kind, entry.index, &decoded)).?;
                defer numeric.deinit();
                try std.testing.expectEqualDeep(retained.value.node.content, numeric.value.node.content);
                try std.testing.expectEqual(if (entry.kind == .spectrum) @as(usize, 2) else 0, decoded.len());
                for (0..decoded.len()) |position|
                    try std.testing.expectEqualSlices(f64, &.{@floatFromInt(position + 1)}, decoded.get(position).?.values.float64);
            }
        }
    };
}

test "[integration] - [mzML extensions]: retains attributes and mixed XML through copies and writing" {
    var input = std.Io.Reader.fixed(support.EXTENSIONS);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    var header = try mzml.owned.Header.init(std.testing.allocator, (try reader.readHeader()).*, .{});
    defer header.deinit();
    var retained = try mzml.owned.Record.init(std.testing.allocator, (try reader.nextRecord()).?, .{});
    defer retained.deinit();
    try std.testing.expectEqual(null, try reader.nextRecord());
    for ([_]bool{ false, true }) |indexed| {
        var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer sink.deinit();
        var writer = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &sink.writer, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &sink.writer, .{});
        defer writer.deinit();
        try writer.writeHeader(header.value);
        try writer.beginListWithAttributes(.spectrum_list, 1, header.value.spectrum_list.?.attributes);
        try writer.writeRecord(retained.value.node);
        try writer.endList();
        try writer.finish();
        const bytes = sink.written();
        try std.testing.expect(std.mem.indexOf(u8, bytes, "e:note=\"A&amp;B\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "e:type=\"e:Primitive\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "extra=\"keep\"") != null);
        const before = std.mem.indexOf(u8, bytes, "name=\"before\"").?;
        const annotation = std.mem.indexOfPos(u8, bytes, before, "<e:annotation").?;
        const arrays = std.mem.indexOf(u8, bytes, "<binaryDataArrayList").?;
        const after = std.mem.indexOf(u8, bytes, "name=\"after\"").?;
        try std.testing.expect(before < annotation and annotation < arrays and arrays < after);
        var output = std.Io.Reader.fixed(bytes);
        var copied = try mzml.StreamReader.init(std.testing.allocator, &output, .{});
        defer copied.deinit();
        const record = (try copied.nextRecord()).?;
        try std.testing.expectEqual(@as(usize, 2), record.binaryArrays().len);
        try std.testing.expectEqualStrings("before", record.node.params[0].user.name.?);
        try std.testing.expectEqualStrings("after", record.node.params[1].user.name.?);
        if (indexed) {
            var lookup = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = bytes }, .{});
            defer lookup.deinit();
            var found = (try lookup.byId(std.testing.allocator, "scan=1")).?;
            defer found.deinit();
            try support.expectNode(record.node, found.value.node);
        }
    }
}

test "[integration] - [mzML extensions]: retains a foreign default namespace for attribute values" {
    const source = "<m:mzML xmlns:m='http://psi.hupo.org/ms/mzml' xmlns='urn:values' xmlns:e='urn:types'>" ++
        "<m:run><m:spectrumList count='1' e:type='Label'><m:spectrum id='x' index='0' defaultArrayLength='0' e:type='Label'>" ++
        "<m:userParam name='note' e:type='Label'/><e:note>text</e:note></m:spectrum></m:spectrumList></m:run></m:mzML>";
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try support.rewriteDocument(std.testing.allocator, source, &sink.writer, false);
    var input = std.Io.Reader.fixed(sink.written());
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const record = (try reader.nextRecord()).?;
    for ([_][]const mzml.model.Attribute{ record.node.attributes, record.node.params[0].user.xml.?.attributes }) |attributes| {
        var found: usize = 0;
        for (attributes) |attribute| {
            if (std.mem.eql(u8, attribute.name, "xmlns")) {
                try std.testing.expectEqualStrings("urn:values", attribute.value);
                found += 1;
            } else if (std.mem.eql(u8, attribute.name, "e:type")) {
                try std.testing.expectEqualStrings("urn:types", attribute.namespace_uri.?);
                try std.testing.expectEqualStrings("Label", attribute.value);
                found += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), found);
    }
}

test "[integration] - [parameter namespaces]: retains bindings without extra attributes or content" {
    const Check = struct {
        fn params(entries: []const mzml.cv.Entry, name: []const u8, uri: ?[]const u8, value_type: []const u8) !void {
            try std.testing.expectEqual(@as(usize, 3), entries.len);
            try std.testing.expectEqualStrings(value_type, entries[0].cv.value.?);
            try std.testing.expectEqualStrings(value_type, entries[1].user.value_type.?);
            try std.testing.expectEqualStrings("kept", entries[1].user.value.?);
            try std.testing.expectEqualStrings("g", entries[2].group_ref.ref.?);
            for (entries) |entry| {
                const extra = switch (entry) {
                    inline else => |parameter| parameter.xml,
                };
                if (uri) |expected| {
                    try std.testing.expect(extra != null);
                    try std.testing.expectEqual(@as(usize, 0), extra.?.content.len);
                    var found: usize = 0;
                    for (extra.?.attributes) |attribute| {
                        if (!std.mem.eql(u8, attribute.name, name)) continue;
                        try std.testing.expectEqualStrings("http://www.w3.org/2000/xmlns/", attribute.namespace_uri.?);
                        try std.testing.expectEqualStrings(expected, attribute.value);
                        found += 1;
                    }
                    try std.testing.expectEqual(@as(usize, 1), found);
                } else try std.testing.expectEqual(null, extra);
            }
        }
    };
    inline for (.{
        .{ "", "", "", "xmlns:t", @as(?[]const u8, null), "string" },
        .{ "", " xmlns:t='urn:local'", "", "xmlns:t", "urn:local", "t:Value" },
        .{ " xmlns:t='urn:outer'", " xmlns:t='urn:inner'", "", "xmlns:t", "urn:inner", "t:Value" },
        .{ " xmlns:t='urn:outer'", "", "", "xmlns:t", "urn:outer", "t:Value" },
        .{ "", " xmlns:m='http://psi.hupo.org/ms/mzml' xmlns='urn:types'", "m:", "xmlns", "urn:types", "Value" },
    }) |case| {
        inline for (.{ false, true }) |empty_tag| {
            const params = "<" ++ case[2] ++ "cvParam" ++ case[1] ++ " value='" ++ case[5] ++ "'" ++
                (if (empty_tag) "/>" else "></" ++ case[2] ++ "cvParam>") ++
                "<" ++ case[2] ++ "userParam" ++ case[1] ++ " name='note' type='" ++ case[5] ++ "' value='kept'" ++
                (if (empty_tag) "/>" else "></" ++ case[2] ++ "userParam>") ++
                "<" ++ case[2] ++ "referenceableParamGroupRef" ++ case[1] ++ " ref='g'" ++
                (if (empty_tag) "/>" else "></" ++ case[2] ++ "referenceableParamGroupRef>");
            const source = "<mzML xmlns='http://psi.hupo.org/ms/mzml'" ++ case[0] ++ ">" ++
                "<referenceableParamGroupList count='1'><referenceableParamGroup id='g'/></referenceableParamGroupList>" ++
                "<run>" ++ params ++ "<spectrumList count='1'><spectrum id='s' index='0' defaultArrayLength='0'>" ++
                params ++ "</spectrum></spectrumList></run></mzML>";
            var header: mzml.owned.Header = undefined;
            var record: mzml.owned.Record = undefined;
            {
                var input = std.Io.Reader.fixed(source);
                var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
                defer reader.deinit();
                header = try mzml.owned.Header.init(std.testing.allocator, (try reader.readHeader()).*, .{});
                errdefer header.deinit();
                record = try mzml.owned.Record.init(std.testing.allocator, (try reader.nextRecord()).?, .{});
            }
            defer header.deinit();
            defer record.deinit();
            try Check.params(header.value.run.params, case[3], case[4], case[5]);
            try Check.params(record.value.node.params, case[3], case[4], case[5]);
            for ([_]bool{ false, true }) |indexed| {
                var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer sink.deinit();
                var writer = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &sink.writer, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &sink.writer, .{});
                defer writer.deinit();
                try writer.writeHeader(header.value);
                try writer.beginListWithAttributes(.spectrum_list, 1, header.value.spectrum_list.?.attributes);
                try writer.writeRecord(record.value.node);
                try writer.endList();
                try writer.finish();
                var streamed: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer streamed.deinit();
                try support.rewriteDocument(std.testing.allocator, source, &streamed.writer, indexed);
                try std.testing.expectEqualStrings(sink.written(), streamed.written());
                var lookup = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.written() }, .{
                    .policy = if (indexed) .open_embedded else .rebuild,
                });
                defer lookup.deinit();
                var found = (try lookup.byId(std.testing.allocator, "s")).?;
                defer found.deinit();
                try Check.params(lookup.header().run.params, case[3], case[4], case[5]);
                try Check.params(found.value.node.params, case[3], case[4], case[5]);
            }
        }
    }
}

test "[integration] - [parameter XML]: preserves absent empty and escaped schema locations" {
    const Check = struct {
        fn location(attributes: []const mzml.model.Attribute) ?[]const u8 {
            for (attributes) |attribute| {
                const start = if (std.mem.indexOfScalar(u8, attribute.name, ':')) |colon| colon + 1 else 0;
                if (std.mem.eql(u8, attribute.namespace_uri orelse "", "http://www.w3.org/2001/XMLSchema-instance") and
                    std.mem.eql(u8, attribute.name[start..], "schemaLocation")) return attribute.value;
            }
            return null;
        }
    };
    inline for (.{
        .{ "", @as(?[]const u8, null) },
        .{ " q:schemaLocation=''", @as(?[]const u8, "") },
        .{ " q:schemaLocation='a&amp;b&#9;&quot;'", @as(?[]const u8, "a&b\t\"") },
    }) |case| {
        const source = "<mzML xmlns='http://psi.hupo.org/ms/mzml' xmlns:q='http://www.w3.org/2001/XMLSchema-instance' xmlns:xsi='urn:other' xsi:note='keep'>" ++
            "<run><spectrumList count='1'><spectrum id='x' index='0' defaultArrayLength='0'" ++ case[0] ++ ">" ++
            "<cvParam" ++ case[0] ++ "/><userParam" ++ case[0] ++ "/><referenceableParamGroupRef" ++ case[0] ++
            "/></spectrum></spectrumList></run></mzML>";
        for ([_]bool{ false, true }) |indexed| {
            var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer sink.deinit();
            try support.rewriteDocument(std.testing.allocator, source, &sink.writer, indexed);
            var input = std.Io.Reader.fixed(sink.written());
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
            defer reader.deinit();
            const record = (try reader.nextRecord()).?;
            try std.testing.expectEqualDeep(case[1], Check.location(record.node.attributes));
            for (record.node.params) |entry| {
                const extra = switch (entry) {
                    inline else => |parameter| parameter.xml,
                };
                try std.testing.expectEqualDeep(case[1], if (extra) |value| Check.location(value.attributes) else null);
            }
        }
    }
}

test "[integration] - [mzML writer]: does not borrow the header namespace after writing" {
    var namespace = "http://psi.hupo.org/schema_revision/mzML_1.0.0".*;
    var bytes: [1024]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();
    try writer.writeHeader(.{ .document = .{ .kind = .mzml }, .run = .{ .kind = .run }, .namespace_uri = &namespace });
    @memset(&namespace, 'x');
    try writer.beginListWithAttributes(.spectrum_list, 0, &.{});
    try writer.endList();
    try writer.finish();
    var input = std.Io.Reader.fixed(sink.buffered());
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    try std.testing.expectEqualStrings("http://psi.hupo.org/schema_revision/mzML_1.0.0", (try reader.readHeader()).namespace_uri);
    try std.testing.expectEqual(null, try reader.nextRecord());
}

test "[failure] - [mzML extensions]: rejects incomplete content and bounds fragment emission" {
    const cases = [_]struct { items: []const mzml.model.Content.Item, limits: mzml.Writer.Limits = .{}, err: mzml.Writer.Error }{
        .{ .items = &.{.{ .params = 1 }}, .err = error.InvalidStructure },
        .{ .items = &.{.{ .children = 1 }}, .err = error.InvalidStructure },
        .{ .items = &.{.{ .xml = "<extra>" }}, .err = error.InvalidXml },
        .{ .items = &.{.{ .xml = "<extra>" ** mzml.MAX_DEPTH ++ "</extra>" ** mzml.MAX_DEPTH }}, .err = error.WriterLimit },
        .{ .items = &.{.{ .xml = "<extra/>" }}, .limits = .{ .nodes = 1 }, .err = error.LimitExceeded },
        .{ .items = &.{.{ .xml = "<extra/>" }}, .limits = .{ .text_bytes = 7 }, .err = error.LimitExceeded },
    };
    for (cases) |case| {
        var bytes: [1024]u8 = undefined;
        var sink = std.Io.Writer.fixed(&bytes);
        var writer = try mzml.Writer.init(std.testing.allocator, &sink, case.limits);
        defer writer.deinit();
        try writer.writeHeader(.{ .document = .{ .kind = .mzml }, .run = .{ .kind = .run } });
        try writer.beginListWithAttributes(.spectrum_list, 1, &.{});
        const node: mzml.model.Node = .{ .kind = .spectrum, .attributes = &.{
            .{ .name = "id", .value = "x" }, .{ .name = "index", .value = "0" }, .{ .name = "defaultArrayLength", .value = "0" },
        }, .content = &.{ .items = case.items } };
        try std.testing.expectError(case.err, writer.writeRecord(node));
        try std.testing.expectError(error.FailedState, writer.finish());
    }
}

test "[integration] - [mzML 1.0 writing]: retains the namespace hierarchy and payloads" {
    for ([_]bool{ false, true }) |indexed| {
        var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer sink.deinit();
        try support.rewriteDocument(std.testing.allocator, support.HISTORICAL, &sink.writer, indexed);
        const bytes = sink.written();
        try std.testing.expect(std.mem.indexOf(u8, bytes, "xmlns=\"http://psi.hupo.org/schema_revision/mzML_1.0.0\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "<softwareParam cvRef=\"MS\" accession=\"MS:1000615\" name=\"ProteoWizard\" version=\"1.0\"/>") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "<binary>AAAAAAAACEAAAAAAAAAQQA==</binary>") != null);
        var original = std.Io.Reader.fixed(support.HISTORICAL);
        var copied = std.Io.Reader.fixed(bytes);
        var a = try mzml.StreamReader.init(std.testing.allocator, &original, .{});
        defer a.deinit();
        var b = try mzml.StreamReader.init(std.testing.allocator, &copied, .{});
        defer b.deinit();
        try std.testing.expectEqualStrings((try a.readHeader()).namespace_uri, (try b.readHeader()).namespace_uri);
        try support.expectNode((try a.readHeader()).document, (try b.readHeader()).document);
        try support.expectNode((try a.readHeader()).run, (try b.readHeader()).run);
        while (try a.nextRecord()) |record| try support.expectNode(record.node, (try b.nextRecord()).?.node);
        try std.testing.expectEqual(null, try b.nextRecord());
    }
}

test "[integration] - [mzML lists]: retains attributes and uses the requested output count" {
    inline for (.{
        .{ "", "" },
        .{ " defaultDataProcessingRef=''", " defaultDataProcessingRef=\"\"" },
        .{ " defaultDataProcessingRef='dp&amp;source'", " defaultDataProcessingRef=\"dp&amp;source\"" },
    }) |reference| {
        const source = support.HEADER ++ "<spectrumList sourceNote='A&amp;B&#9;&quot;'" ++ reference[0] ++
            " xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' xsi:schemaLocation='urn:list list.xsd' count='9'/>" ++
            "<chromatogramList count='0'/></run></mzML>";
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const header = try reader.readHeader();
        try std.testing.expectEqual(null, try reader.nextRecord());
        for ([_]bool{ false, true }) |indexed| {
            var buffer: [4096]u8 = undefined;
            var sink = std.Io.Writer.fixed(&buffer);
            var writer = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &sink, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &sink, .{});
            defer writer.deinit();
            try writer.writeHeader(header.*);
            try writer.beginListWithAttributes(.spectrum_list, 0, header.spectrum_list.?.attributes);
            try writer.endList();
            try writer.beginListWithAttributes(.chromatogram_list, 0, &.{});
            try writer.endList();
            try writer.finish();
            const bytes = sink.buffered();
            const start = std.mem.indexOf(u8, bytes, "<spectrumList").?;
            const end = std.mem.indexOfPos(u8, bytes, start, "</run>").?;
            try std.testing.expectEqualStrings("<spectrumList count=\"0\" sourceNote=\"A&amp;B&#x9;&quot;\"" ++ reference[1] ++
                " xsi:schemaLocation=\"urn:list list.xsd\"/><chromatogramList count=\"0\"/>", bytes[start..end]);
            var output = std.Io.Reader.fixed(bytes);
            var after = try mzml.StreamReader.init(std.testing.allocator, &output, .{});
            defer after.deinit();
            const result = try after.readHeader();
            try std.testing.expectEqual(null, try after.nextRecord());
            try std.testing.expectEqual(@as(usize, 0), result.spectrum_list.?.declared_count);
            var position: usize = 1;
            for (header.spectrum_list.?.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.name, "count")) continue;
                try std.testing.expectEqualDeep(attribute, result.spectrum_list.?.attributes[position]);
                position += 1;
            }
            try std.testing.expectEqual(position, result.spectrum_list.?.attributes.len);
            try std.testing.expectEqualDeep(header.chromatogram_list, result.chromatogram_list);
        }
    }
}

test "[failure] - [mzML lists]: attribute errors leave the writer failed" {
    const cases = [_]struct { attributes: []const mzml.model.Attribute, err: mzml.Writer.Error }{
        .{ .attributes = &.{ .{ .name = "note", .value = "a" }, .{ .name = "note", .value = "b" } }, .err = error.DuplicateAttribute },
        .{ .attributes = &.{.{ .name = "note", .value = "a\x00b" }}, .err = error.InvalidCharacter },
        .{ .attributes = &.{.{ .name = "bad name", .value = "a" }}, .err = error.InvalidName },
        .{ .attributes = &.{.{ .name = "count", .namespace_uri = "urn:other", .value = "9" }}, .err = error.UnknownAttribute },
    };
    for (cases) |case| {
        var bytes: [4096]u8 = undefined;
        var sink = std.Io.Writer.fixed(&bytes);
        var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
        defer writer.deinit();
        try writer.writeHeader(.{ .document = .{ .kind = .mzml }, .run = .{ .kind = .run } });
        try std.testing.expectError(case.err, writer.beginListWithAttributes(.spectrum_list, 0, case.attributes));
        try std.testing.expectError(error.FailedState, writer.beginListWithAttributes(.spectrum_list, 0, &.{}));
        try std.testing.expectError(error.FailedState, writer.finish());
    }
}

test "[integration] - [mzML writer]: preserves metadata and records through a plain rewrite" {
    var bytes: [8192]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    try support.rewriteFixture(std.testing.allocator, &sink);
    try std.testing.expect(std.mem.startsWith(u8, sink.buffered(), "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
    try std.testing.expect(std.mem.endsWith(u8, sink.buffered(), "</chromatogramList></run></mzML>"));
    var original = std.Io.Reader.fixed(support.DOCUMENT);
    var rewritten = std.Io.Reader.fixed(sink.buffered());
    var a = try mzml.StreamReader.init(std.testing.allocator, &original, .{});
    defer a.deinit();
    var b = try mzml.StreamReader.init(std.testing.allocator, &rewritten, .{});
    defer b.deinit();
    try support.expectNode((try a.readHeader()).document, (try b.readHeader()).document);
    try support.expectNode((try a.readHeader()).run, (try b.readHeader()).run);
    while (try a.nextRecord()) |record| try support.expectNode(record.node, (try b.nextRecord()).?.node);
    try std.testing.expectEqual(null, try b.nextRecord());
    var second_bytes: [8192]u8 = undefined;
    var second = std.Io.Writer.fixed(&second_bytes);
    try support.rewriteFixture(std.testing.allocator, &second);
    try std.testing.expectEqualStrings(sink.buffered(), second.buffered());
}

test "[failure] - [mzML writer]: rejects counts and keeps output failures sticky" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var bytes: [8192]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header.*);
    try writer.beginList(.spectrum_list, 1, "dp");
    try std.testing.expectError(error.CountMismatch, writer.endList());
    try std.testing.expectError(error.FailedState, writer.finish());
    for ([_]usize{ 0, 8, 128, 1024, 2048 }) |length| {
        var short_sink = std.Io.Writer.fixed(bytes[0..length]);
        try std.testing.expectError(error.WriteFailed, support.rewriteFixture(std.testing.allocator, &short_sink));
    }
    var short_sink = std.Io.Writer.fixed(bytes[0..0]);
    var failing = try mzml.Writer.init(std.testing.allocator, &short_sink, .{});
    defer failing.deinit();
    try std.testing.expectError(error.WriteFailed, failing.writeHeader(header.*));
    try std.testing.expectError(error.FailedState, failing.finish());

    const record = (try reader.nextRecord()).?;
    var array = record.binaryArrays()[0];
    array.children = &.{.{ .kind = .binary, .text = "\x00!!!!!!!!!!!" }};
    var list = record.node.child(.binary_data_array_list).?;
    list.children = &.{ array, record.binaryArrays()[1] };
    var malformed = record.node;
    malformed.children = &.{list};
    var invalid_sink = std.Io.Writer.fixed(&bytes);
    var invalid = try mzml.Writer.init(std.testing.allocator, &invalid_sink, .{});
    defer invalid.deinit();
    try invalid.writeHeader(header.*);
    try invalid.beginList(.spectrum_list, 1, "dp");
    const before = invalid_sink.buffered().len;
    try std.testing.expectError(error.InvalidCharacter, invalid.writeRecord(malformed));
    try std.testing.expect(invalid_sink.buffered().len > before);
    try std.testing.expectError(error.FailedState, invalid.finish());
}

test "[failure] - [mzML writer]: releases partial allocations during rewrite" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.rewriteAllocated, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.indexedRewriteAllocated, .{});
}

test "[integration] - [mzML references]: preserves unresolved and external links through rewriting and indexed access" {
    inline for (.{
        "spectrumRef='scan=2'",
        "spectrumRef='scan=absent'",
        "externalSpectrumID='scan=outside' sourceFileRef='unavailable'",
    }) |reference| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.REFERENCED_DOCUMENT, "spectrumRef='scan=2'", reference);
        defer std.testing.allocator.free(source);
        try support.readAll(std.testing.allocator, source, .{ .payload = .skip });
        for ([_]bool{ false, true }) |indexed| {
            var bytes: [16384]u8 = undefined;
            var sink = std.Io.Writer.fixed(&bytes);
            try support.rewriteDocument(std.testing.allocator, source, &sink, indexed);
            var original_input = std.Io.Reader.fixed(source);
            var original = try mzml.StreamReader.init(std.testing.allocator, &original_input, .{});
            defer original.deinit();
            var rewritten_input = std.Io.Reader.fixed(sink.buffered());
            var rewritten = try mzml.StreamReader.init(std.testing.allocator, &rewritten_input, .{});
            defer rewritten.deinit();
            var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{
                .policy = if (indexed) .open_embedded else .rebuild,
            });
            defer index.deinit();
            const header = try original.readHeader();
            const rewritten_header = try rewritten.readHeader();
            try support.expectNode(header.document, rewritten_header.document);
            var count: usize = 0;
            while (try original.nextRecord()) |record| {
                const next = (try rewritten.nextRecord()).?;
                try support.expectNode(record.node, next.node);
                var found = (try index.byId(std.testing.allocator, record.id)).?;
                defer found.deinit();
                try support.expectNode(record.node, found.value.node);
                for (next.binaryArrays()) |array| {
                    var values: [1]f64 = undefined;
                    try mzml.model.decodeArray(f64, &values, array, next.default_array_length, rewritten_header.groups, .{ .transport = &.{}, .transformed = &.{} });
                    try std.testing.expectEqual(@as(f64, 1), values[0]);
                }
                count += 1;
            }
            try std.testing.expectEqual(@as(usize, 3), count);
            try std.testing.expectEqual(null, try rewritten.nextRecord());
            try std.testing.expectEqual(null, try index.byId(std.testing.allocator, "scan=absent"));
        }
    }
}

test "[integration] - [mzML prepared writing]: preserves primitive bytes across chunk and padding boundaries" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var compressor = try mzml.zlib.Compressor.init(std.testing.allocator, .fast);
    defer compressor.deinit();
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    inline for (.{ f32, f64, i32, i64 }) |T| {
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        var values: [769]T = undefined;
        for (&values, 0..) |*value, i| value.* = @bitCast(@as(Bits, @truncate(@as(u64, i) *% 0x9e3779b97f4a7c15)));
        for ([_]usize{ 0, 1, 2, 383, 384, 385, 768, 769 }) |count| {
            for ([_]mzml.arrays.Pipeline{ .none, .zlib }) |pipeline| {
                builder.reset();
                var text: [16384]u8 = undefined;
                var transport: [16384]u8 = undefined;
                var transformed: [8192]u8 = undefined;
                const scratch: mzml.arrays.Scratch = .{ .transport = &transport, .transformed = &transformed };
                encoder.reset();
                var arrays: [2]mzml.Builder.Array = undefined;
                for (&arrays, 0..) |*array, i| array.* = (try builder.prepareArray(T, values[0..count], .{
                    .cv_ref = "MS",
                    .encoding = .{ .pipeline = pipeline },
                    .role = .{
                        .cv_ref = "MS",
                        .accession = if (i == 0) mzml.model.Terms.MZ_ARRAY else mzml.model.Terms.INTENSITY_ARRAY,
                        .name = if (i == 0) "m/z array" else "intensity array",
                    },
                }, &encoder)).array;
                const metadata = (try builder.record(.spectrum, "scan=1", 0, count, &.{}, &.{}, &arrays)).node;
                const wire = try mzml.arrays.encodeWire(T, values[0..count], .{ .pipeline = pipeline }, scratch, &compressor);
                // The same record carrying the wire as retained Base64 text.
                const encoded_text = try mzml.base64.encode(&text, wire);
                var binaries: [2]mzml.model.Node = undefined;
                var nodes = [_]mzml.model.Node{ arrays[0].node, arrays[1].node };
                for (&nodes, 0..) |*node, i| {
                    binaries[i] = node.children[0];
                    binaries[i].text = encoded_text;
                    node.children = binaries[i..][0..1];
                }
                var list = metadata.child(.binary_data_array_list).?;
                list.children = &nodes;
                const lists = [_]mzml.model.Node{list};
                var retained = metadata;
                retained.children = &lists;
                for ([_]bool{ false, true }) |indexed| {
                    var expected_bytes: [32768]u8 = undefined;
                    var expected = std.Io.Writer.fixed(&expected_bytes);
                    try support.writeSingleRecord(std.testing.allocator, &expected, header.*, retained, indexed, null);
                    var actual_bytes: [32768]u8 = undefined;
                    var actual = std.Io.Writer.fixed(&actual_bytes);
                    try support.writeSingleRecord(std.testing.allocator, &actual, header.*, metadata, indexed, &.{ wire, wire });
                    try std.testing.expectEqualStrings(expected.buffered(), actual.buffered());
                    for ([_][2]?[]const u8{ .{ wire, null }, .{ null, wire }, .{ null, null } }) |choices| {
                        var mixed = std.Io.Writer.fixed(&actual_bytes);
                        var writer = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &mixed, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &mixed, .{});
                        defer writer.deinit();
                        try writer.writeHeader(header.*);
                        try writer.beginList(.spectrum_list, 1, "dp");
                        try writer.writeRecordWithSelectedArrays(retained, &choices);
                        try writer.endList();
                        try writer.finish();
                        try std.testing.expectEqualStrings(expected.buffered(), mixed.buffered());
                    }
                    var source = std.Io.Reader.fixed(expected.buffered());
                    var decoded_reader = try mzml.StreamReader.init(std.testing.allocator, &source, .{});
                    defer decoded_reader.deinit();
                    var decoded_arrays = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
                    defer decoded_arrays.deinit();
                    const decoded_record = (try decoded_reader.nextDecodedRecord(&decoded_arrays)).?;
                    try std.testing.expectEqual(@as(usize, 2), decoded_arrays.len());
                    for (0..decoded_arrays.len()) |position| {
                        switch (decoded_arrays.get(position).?.values) {
                            inline else => |decoded| try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(values[0..count]), std.mem.sliceAsBytes(decoded)),
                        }
                    }
                    const decoded = decoded_arrays.get(0).?.values;
                    const typed: []const T = if (T == f32) decoded.float32 else if (T == f64) decoded.float64 else if (T == i32) decoded.int32 else decoded.int64;
                    const reencoded = try mzml.arrays.encodeWire(T, typed, .{ .pipeline = pipeline }, scratch, &compressor);
                    var rewritten_bytes: [32768]u8 = undefined;
                    var rewritten = std.Io.Writer.fixed(&rewritten_bytes);
                    try support.writeSingleRecord(std.testing.allocator, &rewritten, header.*, decoded_record.node, indexed, &.{ reencoded, reencoded });
                    try std.testing.expectEqualSlices(u8, expected.buffered(), rewritten.buffered());
                    if (indexed) {
                        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = rewritten.buffered() }, .{});
                        defer index.deinit();
                        try std.testing.expectEqual(@as(usize, 1), index.entries.items.len);
                        var fetched = (try index.atDecoded(std.testing.allocator, .spectrum, 0, &decoded_arrays)).?;
                        defer fetched.deinit();
                        try std.testing.expectEqual(@as(usize, 2), decoded_arrays.len());
                        for (0..decoded_arrays.len()) |position| {
                            switch (decoded_arrays.get(position).?.values) {
                                inline else => |items| try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(values[0..count]), std.mem.sliceAsBytes(items)),
                            }
                        }
                        const fetched_values = decoded_arrays.get(0).?.values;
                        const fetched_typed: []const T = if (T == f32) fetched_values.float32 else if (T == f64) fetched_values.float64 else if (T == i32) fetched_values.int32 else fetched_values.int64;
                        const fetched_wire = try mzml.arrays.encodeWire(T, fetched_typed, .{ .pipeline = pipeline }, scratch, &compressor);
                        var fetched_bytes: [32768]u8 = undefined;
                        var fetched_sink = std.Io.Writer.fixed(&fetched_bytes);
                        try support.writeSingleRecord(std.testing.allocator, &fetched_sink, header.*, fetched.value.node, true, &.{ fetched_wire, fetched_wire });
                        try std.testing.expectEqualSlices(u8, expected.buffered(), fetched_sink.buffered());
                    }
                    try std.testing.expectEqual(null, try decoded_reader.nextDecodedRecord(&decoded_arrays));
                }
            }
        }
    }
}

test "[integration] - [mzML mixed writing]: retains unknown arrays and replaces by array position" {
    const source = "<mzML xmlns='http://psi.hupo.org/ms/mzml' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'>" ++
        "<run><spectrumList count='1'>" ++
        "<spectrum id='s' index='0'><binaryDataArrayList count='5'>" ++
        "<binaryDataArray><cvParam accession='future:codec'/></binaryDataArray>" ++
        "<binaryDataArray encodedLength='unknown'><cvParam accession='future:codec'/>" ++
        "<extra><binary>opaque</binary></extra><binary>A!&amp;&lt;]]&gt;&#xD;</binary></binaryDataArray>" ++
        "<binaryDataArray encodedLength='4'><binary>first</binary><userParam name='late'/></binaryDataArray>" ++
        "<binaryDataArray encodedLength='0'><binary>empty</binary></binaryDataArray>" ++
        "<binaryDataArray encodedLength='8'><binary>last</binary></binaryDataArray>" ++
        "</binaryDataArrayList><binaryDataArrayList count='1'>" ++
        "<binaryDataArray><binary>unmodeled</binary></binaryDataArray></binaryDataArrayList>" ++
        "</spectrum></spectrumList></run></mzML>";
    const first_text = try std.mem.replaceOwned(u8, std.testing.allocator, source, ">first<", ">AQID<");
    defer std.testing.allocator.free(first_text);
    const empty_text = try std.mem.replaceOwned(u8, std.testing.allocator, first_text, ">empty<", "><");
    defer std.testing.allocator.free(empty_text);
    const expected_text = try std.mem.replaceOwned(u8, std.testing.allocator, empty_text, ">last<", ">BAUGBw==<");
    defer std.testing.allocator.free(expected_text);
    var expected_input = std.Io.Reader.fixed(expected_text);
    var expected = try mzml.StreamReader.init(std.testing.allocator, &expected_input, .{});
    defer expected.deinit();
    const expected_record = (try expected.nextRecord()).?;

    for ([_]bool{ false, true }) |indexed| {
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const header = try reader.readHeader();
        const record = (try reader.nextRecord()).?;
        var bytes: [8192]u8 = undefined;
        var sink = std.Io.Writer.fixed(&bytes);
        var writer = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &sink, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &sink, .{});
        defer writer.deinit();
        try writer.writeHeader(header.*);
        try writer.beginListWithAttributes(.spectrum_list, 1, &.{});
        var first = [_]u8{ 1, 2, 3 };
        var last = [_]u8{ 4, 5, 6, 7 };
        var choices = [_]?[]const u8{ null, null, &first, &.{}, &last };
        try writer.writeRecordWithSelectedArrays(record.node, &choices);
        @memset(&first, 0);
        @memset(&last, 0);
        @memset(&choices, null);
        try std.testing.expectEqual(null, try reader.nextRecord());
        try writer.endList();
        try writer.finish();
        var output = std.Io.Reader.fixed(sink.buffered());
        var result = try mzml.StreamReader.init(std.testing.allocator, &output, .{});
        defer result.deinit();
        try support.expectNode(expected_record.node, (try result.nextRecord()).?.node);
        try std.testing.expectEqual(null, try result.nextRecord());
        if (indexed) {
            var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .open_embedded });
            defer index.deinit();
            var found = (try index.byId(std.testing.allocator, "s")).?;
            defer found.deinit();
            try support.expectNode(expected_record.node, found.value.node);
        }
    }
}

test "[failure] - [mzML mixed writing]: checks supplied bytes and keeps failures sticky" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const record = (try reader.nextRecord()).?;
    const wire = [_]u8{0} ** 8;
    const errors = [_]mzml.Writer.Error{
        error.CountMismatch,      error.EncodedLengthMismatch, error.OverlappingBuffers,
        error.LimitExceeded,      error.PayloadNotRetained,    error.InvalidStructure,
        error.OverlappingBuffers, error.WriteFailed,
    };
    for ([_]bool{ false, true }) |indexed| {
        for (errors, 0..) |expected_error, case| {
            var output: [8192]u8 align(@alignOf(?[]const u8)) = undefined;
            var sink = std.Io.Writer.fixed(&output);
            var writer = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &sink, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &sink, .{});
            defer writer.deinit();
            try writer.writeHeader(header.*);
            try writer.beginList(.spectrum_list, 1, "dp");
            const before = writer.engine.byteOffset();
            var choices = [_]?[]const u8{ null, &wire };
            var supplied: []const ?[]const u8 = &choices;
            var arrays = [_]mzml.model.Node{ record.binaryArrays()[0], record.binaryArrays()[1] };
            var list = record.node.child(.binary_data_array_list).?;
            list.children = &arrays;
            var node = record.node;
            node.children = &.{list};
            switch (case) {
                0 => supplied = choices[0..1],
                1 => choices[1] = wire[0..1],
                2 => choices[1] = output[0..8],
                3 => writer.limits.text_bytes = 11,
                4 => arrays[0].children = &.{.{ .kind = .binary }},
                5 => arrays[1].children = &.{},
                6 => {
                    const aliased: *[2]?[]const u8 = @ptrCast(@alignCast(&output[4096]));
                    aliased.* = choices;
                    supplied = aliased;
                },
                // Indexed output reaches the sink in buffered chunks, so only plain output fails here.
                7 => if (indexed) continue else {
                    sink.buffer = sink.buffer[0 .. sink.end + 1];
                },
                else => unreachable,
            }
            try std.testing.expectError(expected_error, writer.writeRecordWithSelectedArrays(node, supplied));
            if (case != 4 and case != 7) try std.testing.expectEqual(before, writer.engine.byteOffset());
            const report = writer.diagnostic().?;
            try std.testing.expectEqual(.write_record, report.operation);
            if (case >= 1 and case <= 5)
                try std.testing.expectEqual(@as(usize, if (case == 4) 0 else 1), report.array_position.?);
            try std.testing.expectError(error.FailedState, writer.writeRecordWithSelectedArrays(node, &choices));
            try std.testing.expectError(error.FailedState, writer.finish());
            try std.testing.expectEqualDeep(report, writer.diagnostic().?);
        }
    }
}

test "[integration] - [mzML prepared writing]: rejects mismatches and keeps sink failures sticky" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const record = (try reader.nextRecord()).?;
    const bytes = [_]u8{0} ** 8;
    for ([_]bool{ false, true }) |indexed| {
        for (0..9) |failure| {
            var output: [8192]u8 = undefined;
            var sink = std.Io.Writer.fixed(&output);
            var writer = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &sink, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &sink, .{});
            defer writer.deinit();
            try writer.writeHeader(header.*);
            try writer.beginList(.spectrum_list, 1, "dp");
            const before = writer.engine.byteOffset().?;
            switch (failure) {
                0 => try std.testing.expectError(error.CountMismatch, writer.writeRecordWithArrays(record.node, &.{})),
                1 => try std.testing.expectError(error.EncodedLengthMismatch, writer.writeRecordWithArrays(record.node, &.{ &bytes, bytes[0..1] })),
                2 => try std.testing.expectError(error.OverlappingBuffers, writer.writeRecordWithArrays(record.node, &.{ output[0..8], &bytes })),
                3 => {
                    writer.limits.text_bytes = 11;
                    try std.testing.expectError(error.LimitExceeded, writer.writeRecordWithArrays(record.node, &.{ &bytes, &bytes }));
                },
                // Indexed output reaches the sink in buffered chunks, so only plain output fails here.
                4 => if (indexed) continue else {
                    sink.buffer = sink.buffer[0 .. sink.end + 1];
                    try std.testing.expectError(error.WriteFailed, writer.writeRecordWithArrays(record.node, &.{ &bytes, &bytes }));
                },
                5, 6, 7 => {
                    var array = record.binaryArrays()[0];
                    array.children = if (failure == 5) &.{} else if (failure == 6)
                        &.{ .{ .kind = .binary }, .{ .kind = .binary } }
                    else
                        &.{.{ .kind = .scan }};
                    var list = record.node.child(.binary_data_array_list).?;
                    list.children = &.{ array, record.binaryArrays()[1] };
                    var changed = record.node;
                    changed.children = &.{list};
                    try std.testing.expectError(error.InvalidStructure, writer.writeRecordWithArrays(changed, &.{ &bytes, &bytes }));
                },
                8 => {
                    var changed = record.node;
                    const list = changed.child(.binary_data_array_list).?;
                    changed.children = &.{ list, list };
                    try std.testing.expectError(error.InvalidStructure, writer.writeRecordWithArrays(changed, &.{ &bytes, &bytes }));
                    try std.testing.expect(writer.engine.byteOffset().? > before);
                },
                else => unreachable,
            }
            if (failure != 4 and failure != 8) try std.testing.expectEqual(before, writer.engine.byteOffset().?);
            const report = writer.diagnostic().?;
            try std.testing.expectEqual(.write_record, report.operation);
            try std.testing.expectEqual(@as(usize, 0), report.record.?.ordinal);
            switch (failure) {
                0 => {
                    try std.testing.expectEqual(.count_mismatch, report.id);
                    try std.testing.expectEqual(@as(u64, 2), report.detail.size.expected);
                    try std.testing.expectEqual(@as(u64, 0), report.detail.size.actual);
                    try std.testing.expectEqual(.arrays, report.detail.size.unit);
                },
                1 => {
                    try std.testing.expectEqual(.encoded_length_mismatch, report.id);
                    try std.testing.expectEqual(@as(usize, 1), report.array_position.?);
                    try std.testing.expectEqual(@as(u64, 4), report.detail.size.expected);
                    try std.testing.expectEqual(@as(u64, 12), report.detail.size.actual);
                },
                3 => {
                    try std.testing.expectEqual(.text_bytes, report.detail.limit.name);
                    try std.testing.expectEqual(@as(u64, 11), report.detail.limit.maximum);
                },
                4 => try std.testing.expectEqual(null, report.location),
                else => {},
            }
            try std.testing.expectError(error.FailedState, writer.finish());
            try std.testing.expectError(error.FailedState, writer.writeRecordWithArrays(record.node, &.{ &bytes, &bytes }));
            try std.testing.expectEqualDeep(report, writer.diagnostic().?);
        }
    }
}

test "[integration] - [mzML binary construction]: preserves text without decoding it" {
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "0" },
        .{ " \t\r\n", "0" },
        .{ " A\tA\r=\n= ", "4" },
        .{ " A\tA\r=\n= ", "11" },
        .{ "AA==", "0" },
        .{ "A!==", "0" },
        .{ "AB==", "0" },
        .{ "AAA", "0" },
        .{ "AA==AAAA", "0" },
        .{ "A!==", "bad" },
    };
    for (cases) |case| {
        builder.reset();
        const source: mzml.model.Node = .{
            .kind = .binary_data_array,
            .attributes = &.{.{ .name = "encodedLength", .value = case[1] }},
            .children = &.{.{ .kind = .binary, .text = case[0] }},
        };
        try support.expectNode(source, try builder.node(source));
    }
}

test "[integration] - [mzML writer]: preserves partial metadata and uninterpreted binary text" {
    const source = "<mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.1.0'>" ++
        "<userParam name='document parameter'/><run><userParam unitCvRef='UO'/><cvParam/><referenceableParamGroupRef/>" ++
        "<spectrumList count='1' defaultDataProcessingRef='dp'>" ++
        "<spectrum id='scan=1' index='0' defaultArrayLength='0' extra='kept'>" ++
        "<binaryDataArrayList count='7'><binaryDataArray encodedLength='unknown'>" ++
        "<binary>A!&amp;&lt;]]&gt;&#xD;</binary></binaryDataArray></binaryDataArrayList>" ++
        "<scanList count='0'/><cvParam unitName='partial'/>" ++
        "</spectrum></spectrumList><chromatogramList count='0' defaultDataProcessingRef='dp'/>" ++
        "</run></mzML>";
    for ([_]bool{ false, true }) |indexed| {
        var output: [8192]u8 = undefined;
        var sink = std.Io.Writer.fixed(&output);
        try support.rewriteDocument(std.testing.allocator, source, &sink, indexed);
        var original_input = std.Io.Reader.fixed(source);
        var original = try mzml.StreamReader.init(std.testing.allocator, &original_input, .{});
        defer original.deinit();
        var rewritten_input = std.Io.Reader.fixed(sink.buffered());
        var rewritten = try mzml.StreamReader.init(std.testing.allocator, &rewritten_input, .{});
        defer rewritten.deinit();
        try support.expectNode((try original.readHeader()).document, (try rewritten.readHeader()).document);
        try support.expectNode((try original.readHeader()).run, (try rewritten.readHeader()).run);
        try support.expectNode((try original.nextRecord()).?.node, (try rewritten.nextRecord()).?.node);
        try std.testing.expectEqual(null, try original.nextRecord());
        try std.testing.expectEqual(null, try rewritten.nextRecord());
    }
}

test "[failure] - [mzML writer]: checks node bounds and missing payloads during emission" {
    const node: mzml.model.Node = .{ .kind = .spectrum, .attributes = &.{
        .{ .name = "id", .value = "one" },
        .{ .name = "index", .value = "0" },
        .{ .name = "defaultArrayLength", .value = "0" },
    }, .children = &.{.{ .kind = .binary_data_array_list, .children = &.{.{
        .kind = .binary_data_array,
        .children = &.{.{ .kind = .binary, .text = "AA==" }},
    }} }} };
    const header: mzml.model.Header = .{
        .document = .{ .kind = .mzml, .attributes = &.{.{ .name = "version", .value = "1.1.0" }} },
        .run = .{ .kind = .run },
    };
    const cases = [_]struct { mzml.Writer.Limits, ?mzml.Writer.Error }{
        .{ .{ .nodes = 4, .text_bytes = 4 }, null },
        .{ .{ .nodes = 3 }, error.LimitExceeded },
        .{ .{ .text_bytes = 3 }, error.LimitExceeded },
    };
    for (cases) |case| {
        var bytes: [2048]u8 = undefined;
        var sink = std.Io.Writer.fixed(&bytes);
        var writer = try mzml.Writer.init(std.testing.allocator, &sink, case[0]);
        defer writer.deinit();
        try writer.writeHeader(header);
        try writer.beginList(.spectrum_list, 1, "dp");
        if (case[1]) |failure| {
            try std.testing.expectError(failure, writer.writeRecord(node));
            try std.testing.expectError(error.FailedState, writer.finish());
        } else {
            try writer.writeRecord(node);
            try writer.endList();
            try writer.finish();
            var input = std.Io.Reader.fixed(sink.buffered());
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
            defer reader.deinit();
            try support.expectNode(node, (try reader.nextRecord()).?.node);
        }
    }
    var bytes: [2048]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    var writer = try mzml.Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();
    try writer.writeHeader(header);
    try writer.beginList(.spectrum_list, 1, "dp");
    var array = node.children[0].children[0];
    array.children = &.{.{ .kind = .binary }};
    var list = node.children[0];
    list.children = &.{array};
    var missing = node;
    missing.children = &.{list};
    try std.testing.expectError(error.PayloadNotRetained, writer.writeRecord(missing));
    try std.testing.expectEqual(.missing_payload, writer.diagnostic().?.id);
    try std.testing.expectEqual(.binary, writer.diagnostic().?.element.?);
    try std.testing.expectEqual(@as(usize, 0), writer.diagnostic().?.array_position.?);
    try std.testing.expectError(error.FailedState, writer.finish());
}

test "[integration] - [mzML writer]: leaves the final sink flush to its caller" {
    const FailingFlush = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
    };
    var bytes: [8192]u8 = undefined;
    var sink: std.Io.Writer = .{ .vtable = &.{ .drain = FailingFlush.drain }, .buffer = &bytes };
    try support.rewriteFixture(std.testing.allocator, &sink);
    try std.testing.expect(std.mem.endsWith(u8, sink.buffered(), "</mzML>"));
    try std.testing.expectError(error.WriteFailed, sink.flush());
}

test "[integration] - [mzML file writer]: patches counts without changing records or indexed offsets" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const cases = [_]struct { counts: [2]usize, unknown: [2]bool, buffer_size: usize }{
        .{ .counts = .{ 0, 0 }, .unknown = .{ true, true }, .buffer_size = 1 },
        .{ .counts = .{ 1, 12 }, .unknown = .{ false, true }, .buffer_size = 137 },
        .{ .counts = .{ 100, 1 }, .unknown = .{ true, false }, .buffer_size = 8192 },
        .{ .counts = .{ 1, 1 }, .unknown = .{ false, false }, .buffer_size = 8192 },
    };
    for ([_]bool{ false, true }) |indexed| {
        for (cases) |case| {
            const file = try dir.dir.createFile(std.testing.io, "out.mzML", .{ .read = indexed });
            defer file.close(std.testing.io);
            var buffer: [8192]u8 = undefined;
            var sink = file.writer(std.testing.io, buffer[0..case.buffer_size]);
            var writer = try mzml.Writer.initFile(std.testing.allocator, &sink, .{}, if (indexed) .{} else null);
            defer writer.deinit();
            var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer expected.deinit();
            var known = try mzml.Writer.init(std.testing.allocator, &expected.writer, .{});
            defer known.deinit();
            var input = std.Io.Reader.fixed(support.DOCUMENT);
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
            defer reader.deinit();
            const header = try reader.readHeader();
            try writer.writeHeader(header.*);
            try known.writeHeader(header.*);
            for ([_]mzml.model.Kind{ .spectrum_list, .chromatogram_list }, 0..) |kind, list_index| {
                const record = (try reader.nextRecord()).?;
                var node = record.node;
                var attributes: [3]mzml.model.Attribute = undefined;
                @memcpy(&attributes, node.attributes);
                node.attributes = &attributes;
                const list_attributes: []const mzml.model.Attribute = if (kind == .spectrum_list) &.{
                    .{ .name = "sourceNote", .value = "A&B\t\"" },
                    .{ .name = "count", .value = "999" },
                } else &.{
                    .{ .name = "defaultDataProcessingRef", .value = "" },
                    .{ .name = "sourceNote", .value = "" },
                };
                try writer.beginListWithAttributes(kind, if (case.unknown[list_index]) null else case.counts[list_index], list_attributes);
                try known.beginListWithAttributes(kind, case.counts[list_index], list_attributes);
                for (0..case.counts[list_index]) |position| {
                    var index_text: [32]u8 = undefined;
                    var id_text: [64]u8 = undefined;
                    attributes[0].value = try std.fmt.bufPrint(&id_text, "{s}&{d}", .{ kind.xmlName(), position });
                    attributes[1].value = try std.fmt.bufPrint(&index_text, "{d}", .{position});
                    try known.writeRecord(node);
                    if (position % 2 == 0) {
                        try writer.writeRecord(node);
                    } else {
                        const one = [_]u8{ 0, 0, 0, 0, 0, 0, 0xf0, 0x3f };
                        try writer.writeRecordWithArrays(node, &.{ &one, &one });
                    }
                }
                try known.endList();
                try writer.endList();
                try std.testing.expectEqual(sink.logicalPos(), writer.engine.byteOffset().?);
            }
            try known.finish();
            try writer.finish();
            try sink.interface.flush();
            const bytes = try dir.dir.readFileAlloc(std.testing.io, "out.mzML", std.testing.allocator, .limited(256 * 1024));
            defer std.testing.allocator.free(bytes);
            var before_input = std.Io.Reader.fixed(expected.written());
            var before = try mzml.StreamReader.init(std.testing.allocator, &before_input, .{});
            defer before.deinit();
            const before_header = try before.readHeader();
            var after_input = std.Io.Reader.fixed(bytes);
            var after = try mzml.StreamReader.init(std.testing.allocator, &after_input, .{});
            defer after.deinit();
            const after_header = try after.readHeader();
            while (try before.nextRecord()) |record|
                try support.expectNode(record.node, (try after.nextRecord()).?.node);
            try std.testing.expectEqual(null, try after.nextRecord());
            try std.testing.expectEqual(case.counts[0], after_header.spectrum_list.?.declared_count);
            try std.testing.expectEqual(case.counts[1], after_header.chromatogram_list.?.declared_count);
            for ([_]?mzml.model.RecordList{ after_header.spectrum_list, after_header.chromatogram_list }, 0..) |list, i| {
                const expected_list = if (i == 0) before_header.spectrum_list.? else before_header.chromatogram_list.?;
                try std.testing.expectEqualDeep(expected_list.attributes[1..], list.?.attributes[1..]);
                if (case.unknown[i]) {
                    const opening: mzml.model.Node = .{ .kind = .spectrum_list, .attributes = list.?.attributes };
                    const text = opening.attribute("count").?;
                    try std.testing.expectEqual(std.fmt.comptimePrint("{d}", .{std.math.maxInt(usize)}).len, text.len);
                    for (text) |byte| try std.testing.expect(byte >= '0' and byte <= '9');
                }
            }
            if (indexed) {
                var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = bytes }, .{ .policy = .open_embedded });
                defer index.deinit();
                try std.testing.expectEqualDeep(case.counts, index.counts);
                for (index.entries.items) |entry| {
                    var found = (try index.byId(std.testing.allocator, entry.id)).?;
                    defer found.deinit();
                    try std.testing.expectEqual(entry.start, found.value.node.start_offset);
                    try std.testing.expectEqualStrings(entry.id, found.value.id);
                    try std.testing.expectEqualStrings("AAAAAAAA8D8=", found.value.binaryArrays()[0].child(.binary).?.text.?);
                }
                const checksum_start = try support.checksumStart(bytes);
                var digest: [20]u8 = undefined;
                std.crypto.hash.Sha1.hash(bytes[0..checksum_start], &digest, .{});
                try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), bytes[checksum_start .. checksum_start + 40]);
            }
        }
    }
}

test "[integration] - [mzML writer]: separates absent source numbers from output requirements" {
    const source = support.HEADER ++ "<spectrumList><spectrum id='x' index='0'>" ++ support.ARRAYS ++
        "</spectrum></spectrumList></run></mzML>";
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    for ([_]bool{ false, true }) |indexed| {
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const header = try reader.readHeader();
        const opening = (try reader.nextItem()).?;
        try std.testing.expectEqual(null, opening.list_start.list.declared_count);
        const record = (try reader.nextRecord()).?;
        var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer sink.deinit();
        var forward = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &sink.writer, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &sink.writer, .{});
        defer forward.deinit();
        try forward.writeHeader(header.*);
        try std.testing.expectError(error.InvalidOptions, forward.writeItem(opening));
        try std.testing.expectError(error.FailedState, forward.finish());

        const file = try dir.dir.createFile(std.testing.io, "numbers.mzML", .{ .read = true });
        defer file.close(std.testing.io);
        var buffer: [4096]u8 = undefined;
        var file_sink = file.writer(std.testing.io, &buffer);
        var writer = try mzml.Writer.initFile(std.testing.allocator, &file_sink, .{}, if (indexed) .{} else null);
        defer writer.deinit();
        try writer.writeHeader(header.*);
        try writer.writeItem(opening);
        try writer.writeRecord(record.node);
        try writer.endList();
        try writer.finish();
        try file_sink.interface.flush();
        var input_buffer: [4096]u8 = undefined;
        var written_input = file.reader(std.testing.io, &input_buffer);
        var written = try mzml.StreamReader.init(std.testing.allocator, &written_input.interface, .{});
        defer written.deinit();
        try std.testing.expectEqual(@as(?usize, 1), (try written.readHeader()).spectrum_list.?.declared_count);
        const copied = (try written.nextRecord()).?;
        try support.expectNode(record.node, copied.node);
        try std.testing.expectEqual(null, copied.default_array_length);
        try std.testing.expectEqual(null, try written.nextRecord());

        var discard: std.Io.Writer.Discarding = .init(&.{});
        var required = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &discard.writer, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &discard.writer, .{});
        defer required.deinit();
        try required.writeHeader(header.*);
        try required.beginListWithAttributes(.spectrum_list, 1, opening.list_start.list.attributes);
        var missing = record.node;
        missing.attributes = &.{.{ .name = "id", .value = "x" }};
        try std.testing.expectError(error.MissingValue, required.writeRecord(missing));
        try std.testing.expectError(error.FailedState, required.finish());
    }
}

test "[failure] - [mzML file writer]: unknown counts need a file and do not bypass record indexes" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    for ([_]bool{ false, true }) |indexed| {
        var buffer: [4096]u8 = undefined;
        var sink = std.Io.Writer.fixed(&buffer);
        var writer = if (indexed) try mzml.Writer.initIndexed(std.testing.allocator, &sink, .{}, .{}) else try mzml.Writer.init(std.testing.allocator, &sink, .{});
        defer writer.deinit();
        try writer.writeHeader(header.*);
        const before = sink.buffered().len;
        try std.testing.expectError(error.InvalidOptions, writer.beginList(.spectrum_list, null, "dp"));
        try std.testing.expectEqual(before, sink.buffered().len);
        try std.testing.expectError(error.FailedState, writer.finish());
    }
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const file = try dir.dir.createFile(std.testing.io, "out.mzML", .{});
    defer file.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var sink = file.writer(std.testing.io, &buffer);
    var writer = try mzml.Writer.initFile(std.testing.allocator, &sink, .{}, null);
    defer writer.deinit();
    try writer.writeHeader(header.*);
    try writer.beginList(.spectrum_list, null, "dp");
    const record = (try reader.nextRecord()).?;
    try writer.writeRecord(record.node);
    try std.testing.expectError(error.InvalidIndex, writer.writeRecord(record.node));
    try std.testing.expectError(error.FailedState, writer.endList());
    try std.testing.expectError(error.InvalidOptions, mzml.Writer.initFile(std.testing.allocator, &sink, .{}, null));
    var streaming = file.writerStreaming(std.testing.io, &buffer);
    try std.testing.expectError(error.InvalidOptions, mzml.Writer.initFile(std.testing.allocator, &streaming, .{}, null));
}

test "[failure] - [mzML file writer]: flush, count patch, and checksum read failures remain sticky" {
    const Failure = enum { flush, patch, unseekable, read, eof };
    const Sink = struct {
        failure: Failure,
        active: bool = false,
        end: u64 = 0,
        patched: bool = false,

        fn write(data: ?*anyopaque, file: std.Io.File, header: []const u8, slices: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (self.active and self.failure == .flush) return error.NoSpaceLeft;
            if (offset < self.end) {
                if (self.failure == .unseekable) return error.Unseekable;
                if (self.failure == .patch) {
                    if (self.patched) return error.NoSpaceLeft;
                    self.patched = true;
                    return file.writePositional(std.testing.io, &.{slices[0][0..1]}, offset);
                }
            }
            const length = try std.testing.io.vtable.fileWritePositional(std.testing.io.userdata, file, header, slices, splat, offset);
            self.end = @max(self.end, offset + length);
            return length;
        }

        fn read(data: ?*anyopaque, file: std.Io.File, slices: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (offset != 0) {
                if (self.failure == .read) return error.InputOutput;
                if (self.failure == .eof) return 0;
            }
            return file.readPositional(std.testing.io, &.{slices[0][0..@min(slices[0].len, 17)]}, offset);
        }
    };
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    for (std.meta.tags(Failure)) |failure| {
        const file = try dir.dir.createFile(std.testing.io, "out.mzML", .{ .read = true });
        defer file.close(std.testing.io);
        var injected: Sink = .{ .failure = failure };
        var vtable = std.Io.failing.vtable.*;
        vtable.fileWritePositional = Sink.write;
        vtable.fileReadPositional = Sink.read;
        const io: std.Io = .{ .userdata = &injected, .vtable = &vtable };
        var buffer: [8192]u8 = undefined;
        var sink = file.writer(io, &buffer);
        var writer = try mzml.Writer.initFile(std.testing.allocator, &sink, .{}, .{});
        defer writer.deinit();
        var input = std.Io.Reader.fixed(support.DOCUMENT);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        try writer.writeHeader((try reader.readHeader()).*);
        try writer.beginList(.spectrum_list, null, "dp");
        try writer.writeRecord((try reader.nextRecord()).?.node);
        injected.active = true;
        switch (failure) {
            .flush => try std.testing.expectError(error.WriteFailed, writer.endList()),
            .patch => try std.testing.expectError(error.NoSpaceLeft, writer.endList()),
            .unseekable => try std.testing.expectError(error.Unseekable, writer.endList()),
            .read, .eof => {
                try writer.endList();
                try std.testing.expectError(if (failure == .read) error.InputOutput else error.UnexpectedEndOfFile, writer.finish());
            },
        }
        const report = writer.diagnostic().?;
        try std.testing.expectEqual(switch (failure) {
            .flush => error.WriteFailed,
            .patch => error.NoSpaceLeft,
            .unseekable => error.Unseekable,
            .read => error.InputOutput,
            .eof => error.UnexpectedEndOfFile,
        }, report.code);
        try std.testing.expectEqual(.output, report.stage);
        try std.testing.expectEqual(null, report.location);
        try std.testing.expectEqual(if (failure == .read or failure == .eof) mzml.Diagnostic.Operation.finish else .close_list, report.operation);
        try std.testing.expectError(error.FailedState, writer.endList());
        try std.testing.expectError(error.FailedState, writer.finish());
        try std.testing.expectEqualDeep(report, writer.diagnostic().?);
    }
}

test "[failure] - [mzML file writer]: releases partial allocations with unknown counts" {
    const Check = struct {
        fn write(allocator: std.mem.Allocator, file: std.Io.File, indexed: bool) !void {
            try file.setLength(std.testing.io, 0);
            var buffer: [4096]u8 = undefined;
            var sink = file.writer(std.testing.io, &buffer);
            var writer = try mzml.Writer.initFile(allocator, &sink, .{}, if (indexed) .{} else null);
            defer writer.deinit();
            var input = std.Io.Reader.fixed(support.DOCUMENT);
            var reader = try mzml.StreamReader.init(allocator, &input, .{});
            defer reader.deinit();
            try writer.writeHeader((try reader.readHeader()).*);
            try writer.beginList(.spectrum_list, null, "dp");
            try writer.writeRecord((try reader.nextRecord()).?.node);
            try writer.endList();
            try writer.finish();
            try sink.interface.flush();
        }
    };
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const file = try dir.dir.createFile(std.testing.io, "out.mzML", .{ .read = true });
    defer file.close(std.testing.io);
    for ([_]bool{ false, true }) |indexed|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.write, .{ file, indexed });
}

test "[integration] - [mzML declarations]: preserves version metadata across reading construction and writing" {
    for ([_]?[]const u8{ null, "", "1.0", "1.0.0", "1.1.0", "1.1.1", "1.2.0" }) |version| {
        var attribute: [64]u8 = undefined;
        const declaration = if (version) |value| try std.fmt.bufPrint(&attribute, "version='{s}'", .{value}) else "";
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "version='1.1.0'", declaration);
        defer std.testing.allocator.free(source);
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const header = try reader.readHeader();
        try std.testing.expectEqualDeep(version, header.document.attribute("version"));
        var builder = mzml.Builder.init(std.testing.allocator, .{});
        defer builder.deinit();
        try support.expectNode(header.document, (try builder.header(header.*)).document);
        for ([_]bool{ false, true }) |indexed| {
            var bytes: [8192]u8 = undefined;
            var sink = std.Io.Writer.fixed(&bytes);
            try support.rewriteDocument(std.testing.allocator, source, &sink, indexed);
            var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{
                .policy = if (indexed) .open_embedded else .rebuild,
            });
            defer index.deinit();
            try std.testing.expectEqualDeep(version, index.header().document.attribute("version"));
            try std.testing.expectEqualDeep([2]usize{ 1, 1 }, index.counts);
            var decoded = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
            defer decoded.deinit();
            var record = (try index.byIdDecoded(std.testing.allocator, "native=a&b", &decoded)).?;
            defer record.deinit();
            try std.testing.expectEqualSlices(f64, &.{1}, decoded.get(0).?.values.float64);
        }
    }
}
