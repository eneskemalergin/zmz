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
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    const values = [_]f64{ 5, 6 };
    const second = [_]f64{ 3, 4 };
    const first = try builder.prepareArrayFrom(f64, &values, original.binaryArrays()[0], header.groups, .{}, &encoder);
    try std.testing.expectEqualDeep(original.binaryArrays()[0].params[0], first.array.node.params[0]);
    const other = try builder.prepareArrayFrom(f64, &second, original.binaryArrays()[1], header.groups, .{}, &encoder);
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
    try writer.writeRecordWithArrays(record, &.{ first.payload, other.payload });
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

fn reencodeReferenceAllocated(allocator: std.mem.Allocator) !void {
    var input = std.Io.Reader.fixed(support.EXTENSIONS);
    var reader = try mzml.StreamReader.init(allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const source = (try reader.nextRecord()).?;
    var header_builder = mzml.Builder.init(allocator, .{});
    defer header_builder.deinit();
    var encoder = mzml.arrays.Encoder.init(allocator, .fast);
    defer encoder.deinit();
    const target: mzml.model.Encoding = .{ .primitive = .float32, .pipeline = .zlib };
    const prepared_header = try header_builder.reencoding(header.*, &.{ target, target });
    try std.testing.expectEqual(@as(usize, 2), prepared_header.header.groups.len);
    try std.testing.expectEqualDeep(header.groups, prepared_header.source_groups);
    try std.testing.expectEqualDeep(header.groups[0].entries[0].cv.xml, prepared_header.header.groups[1].entries[0].cv.xml);
    var builder = mzml.Builder.init(allocator, .{});
    defer builder.deinit();
    var compressor = try mzml.zlib.Compressor.init(allocator, .fast);
    defer compressor.deinit();
    const values = [_]f32{ 5, 6 };
    const first_source = source.binaryArrays()[0];
    try std.testing.expectError(error.GroupRewriteRequired, builder.prepareArrayFrom(f32, &values, first_source, header.groups, .{ .pipeline = .zlib }, &encoder));
    const first = try prepared_header.prepareArray(&builder, f32, &values, first_source, .{ .pipeline = .zlib }, &encoder);
    try std.testing.expectEqualDeep(first_source.params[0].group_ref.xml, first.array.node.params[0].group_ref.xml);
    try std.testing.expectEqualStrings(prepared_header.header.groups[1].id, first.array.node.params[0].group_ref.ref.?);
    try std.testing.expectEqualStrings("encoding", source.binaryArrays()[1].params[0].group_ref.ref.?);
    try std.testing.expectEqualStrings("MS:1000576", header.groups[0].entries[1].cv.accession.?.raw);
    var list = source.node.child(.binary_data_array_list).?;
    list.children = &.{ first.array.node, source.binaryArrays()[1] };
    var record = source.node;
    record.children = &.{ source.node.children[0], list };
    var buffer: [8192]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    var writer = try mzml.Writer.initIndexed(allocator, &sink, .{}, .{});
    defer writer.deinit();
    try writer.writeHeader(prepared_header.header);
    try writer.beginListWithAttributes(.spectrum_list, 1, header.spectrum_list.?.attributes);
    try writer.writeRecordWithSelectedArrays(record, &.{ first.payload, null });
    try writer.endList();
    try writer.finish();
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = sink.buffered() }, .{});
    defer index.deinit();
    var decoded = mzml.StreamReader.DecodedArrays.init(allocator, .{});
    defer decoded.deinit();
    var actual = (try index.byIdDecoded(allocator, "scan=1", &decoded)).?;
    defer actual.deinit();
    try std.testing.expectEqualSlices(f32, &values, decoded.get(0).?.values.float32);
    try std.testing.expectEqualSlices(f64, &.{ 3, 4 }, decoded.get(1).?.values.float64);
    try std.testing.expectEqual(mzml.arrays.Pipeline.zlib, decoded.get(0).?.encoding.pipeline);
    try std.testing.expectEqual(mzml.arrays.Pipeline.none, decoded.get(1).?.encoding.pipeline);
    try std.testing.expectEqualStrings(prepared_header.header.groups[1].id, actual.value.binaryArrays()[0].params[0].group_ref.ref.?);
    try std.testing.expectEqualStrings("encoding", actual.value.binaryArrays()[1].params[0].group_ref.ref.?);
    try std.testing.expect(std.mem.indexOf(u8, sink.buffered(), "extra=\"reference\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.buffered(), "schemaLocation=\"urn:group group.xsd\"") != null);
}

test "[integration] - [group reencoding]: retains annotated references without changing shared arrays" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, reencodeReferenceAllocated, .{});
}

test "[integration] - [parameter namespaces]: reencoding keeps reference and member bindings" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const source = "<mzML xmlns='http://psi.hupo.org/ms/mzml'><referenceableParamGroupList count='1'>" ++
                "<referenceableParamGroup id='encoding'>" ++
                "<cvParam xmlns:t='urn:primitive' accession='MS:1000523' value='t:Float'/>" ++
                "<cvParam accession='MS:1000576'/></referenceableParamGroup></referenceableParamGroupList>" ++
                "<run><spectrumList count='1'><spectrum id='s' index='0' defaultArrayLength='1'>" ++
                "<binaryDataArrayList count='1'><binaryDataArray encodedLength='12'>" ++
                "<referenceableParamGroupRef xmlns:t='urn:reference' ref='encoding'></referenceableParamGroupRef>" ++
                "<userParam xmlns:t='urn:label' name='note' type='t:Label'/>" ++
                "<cvParam accession='MS:1000514'/><binary>AAAAAAAA8D8=</binary>" ++
                "</binaryDataArray></binaryDataArrayList></spectrum></spectrumList></run></mzML>";
            var header_builder = mzml.Builder.init(allocator, .{});
            defer header_builder.deinit();
            var encoder = mzml.arrays.Encoder.init(allocator, .fast);
            defer encoder.deinit();
            var builder = mzml.Builder.init(allocator, .{});
            defer builder.deinit();
            const values = [_]f32{3};
            const prepared = blk: {
                var input = std.Io.Reader.fixed(source);
                var reader = try mzml.StreamReader.init(allocator, &input, .{});
                defer reader.deinit();
                const header = try reader.readHeader();
                const record = (try reader.nextRecord()).?;
                const rewritten = try header_builder.reencoding(header.*, &.{.{ .primitive = .float32, .pipeline = .none }});
                const array = try rewritten.prepareArray(&builder, f32, &values, record.binaryArrays()[0], .{}, &encoder);
                const copied = try builder.record(.spectrum, record.id, 0, 1, &.{}, &.{}, &.{array.array});
                break :blk .{ .header = rewritten.header, .record = copied, .payload = array.payload };
            };
            try std.testing.expectEqual(@as(usize, 2), prepared.header.groups.len);
            for ([_]bool{ false, true }) |indexed| {
                var buffer: [8192]u8 = undefined;
                var sink = std.Io.Writer.fixed(&buffer);
                try support.writeSingleRecord(allocator, &sink, prepared.header, prepared.record.node, indexed, &.{prepared.payload});
                var lookup = try mzml.IndexedReader.build(allocator, .{ .bytes = sink.buffered() }, .{ .policy = if (indexed) .open_embedded else .rebuild });
                defer lookup.deinit();
                var decoded = mzml.StreamReader.DecodedArrays.init(allocator, .{});
                defer decoded.deinit();
                var found = (try lookup.byIdDecoded(allocator, "s", &decoded)).?;
                defer found.deinit();
                try std.testing.expectEqualSlices(f32, &values, decoded.get(0).?.values.float32);
                const params = found.value.binaryArrays()[0].params;
                try std.testing.expectEqualStrings(lookup.header().groups[1].id, params[0].group_ref.ref.?);
                try std.testing.expectEqualStrings("t:Label", params[1].user.value_type.?);
                const groups = lookup.header().groups;
                try std.testing.expectEqualStrings("MS:1000523", groups[0].entries[0].cv.accession.?.raw);
                try std.testing.expectEqualStrings("MS:1000521", groups[1].entries[0].cv.accession.?.raw);
                try std.testing.expectEqualStrings("t:Float", groups[1].entries[0].cv.value.?);
                const entries = [_]mzml.cv.Entry{ groups[0].entries[0], groups[1].entries[0], params[0], params[1] };
                for (entries, [_][]const u8{ "urn:primitive", "urn:primitive", "urn:reference", "urn:label" }) |entry, uri| {
                    const extra = switch (entry) {
                        inline else => |parameter| parameter.xml,
                    };
                    try std.testing.expect(extra != null);
                    var found_binding = false;
                    for (extra.?.attributes) |attribute| {
                        if (!std.mem.eql(u8, attribute.name, "xmlns:t")) continue;
                        try std.testing.expectEqualStrings(uri, attribute.value);
                        found_binding = true;
                    }
                    try std.testing.expect(found_binding);
                }
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "[integration] - [mzML containers]: prepared writing preserves extra containers and group IDs" {
    const Check = struct {
        fn write(allocator: std.mem.Allocator) !void {
            var input = std.Io.Reader.fixed(support.REPEATED_CONTAINERS);
            var reader = try mzml.StreamReader.init(allocator, &input, .{});
            defer reader.deinit();
            const header = try reader.readHeader();
            const record = (try reader.nextRecord()).?;
            var header_builder = mzml.Builder.init(allocator, .{});
            defer header_builder.deinit();
            var encoder = mzml.arrays.Encoder.init(allocator, .fast);
            defer encoder.deinit();
            const prepared_header = try header_builder.reencoding(header.*, &.{.{ .primitive = .float32, .pipeline = .none }});
            try std.testing.expectEqual(@as(usize, 2), prepared_header.header.groups.len);
            try std.testing.expectEqualStrings("zmz-reencoded-1", prepared_header.header.groups[1].id);
            var builder = mzml.Builder.init(allocator, .{});
            defer builder.deinit();
            const first = try prepared_header.prepareArray(&builder, f32, &.{1}, record.binaryArrays()[0], .{}, &encoder);
            const second = try prepared_header.prepareArray(&builder, f32, &.{2}, record.binaryArrays()[1], .{}, &encoder);
            const children = try allocator.dupe(mzml.model.Node, record.node.children);
            defer allocator.free(children);
            for (children) |*child| if (child.kind == .binary_data_array_list) {
                child.children = &.{ first.array.node, second.array.node };
            };
            var node = record.node;
            node.children = children;
            var bytes: [16 * 1024]u8 = undefined;
            var sink: std.Io.Writer = .fixed(&bytes);
            var writer = try mzml.Writer.initIndexed(allocator, &sink, .{}, .{});
            defer writer.deinit();
            try writer.writeHeader(prepared_header.header);
            try writer.beginListWithAttributes(.spectrum_list, 1, header.spectrum_list.?.attributes);
            try writer.writeRecordWithArrays(node, &.{ first.payload, second.payload });
            try writer.endList();
            try writer.finish();
            var index = try mzml.IndexedReader.build(allocator, .{ .bytes = sink.buffered() }, .{});
            defer index.deinit();
            var decoded = mzml.StreamReader.DecodedArrays.init(allocator, .{});
            defer decoded.deinit();
            var actual = (try index.byIdDecoded(allocator, "s0", &decoded)).?;
            defer actual.deinit();
            try std.testing.expectEqual(@as(usize, 2), decoded.len());
            try std.testing.expectEqualSlices(f32, &.{1}, decoded.get(0).?.values.float32);
            try std.testing.expectEqualSlices(f32, &.{2}, decoded.get(1).?.values.float32);
            try std.testing.expectEqualDeep(record.node.content, actual.value.node.content);
            try std.testing.expectEqualStrings("encoding", index.header().groups[0].id);
            try std.testing.expectEqualStrings("zmz-reencoded-1", actual.value.binaryArrays()[0].params[0].group_ref.ref.?);
            try std.testing.expectEqualStrings(header.document.content.?.items[2].xml, index.header().document.content.?.items[2].xml);
            try support.expectNode(header.run, index.header().run);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.write, .{});
}

test "[integration] - [group reencoding]: handles partial groups, ID collisions, and ordered XML" {
    const xml: mzml.cv.ParameterXml = .{ .attributes = &.{.{ .name = "extra", .value = "keep" }}, .content = &.{.{ .xml = "<e:detail xmlns:e='urn:producer'/>" }} };
    const primitive: mzml.model.Node = .{ .kind = .referenceable_param_group, .attributes = &.{.{ .name = "id", .value = " zmz-reencoded-0 " }}, .params = &.{.{ .cv = .{ .accession = .{ .raw = "MS:1000523" }, .name = "64-bit float", .xml = &xml } }} };
    const codec: mzml.model.Node = .{ .kind = .referenceable_param_group, .attributes = &.{.{ .name = "id", .value = "codec" }}, .params = &.{.{ .cv = .{ .accession = .{ .raw = "MS:1000576" }, .name = "no compression" } }} };
    const unused: mzml.model.Node = .{ .kind = .referenceable_param_group, .attributes = &.{.{ .name = "id", .value = "unused" }}, .params = &.{.{ .group_ref = .{ .ref = "absent" } }} };
    const list: mzml.model.Node = .{ .kind = .referenceable_param_group_list, .attributes = &.{ .{ .name = "count", .value = "3" }, .{ .name = "extra", .value = "list" } }, .children = &.{ primitive, codec, unused }, .content = &.{ .items = &.{ .{ .children = 3 }, .{ .xml = "<e:note xmlns:e='urn:producer'/>" } } } };
    const header: mzml.model.Header = .{ .document = .{ .kind = .mzml, .children = &.{list} }, .run = .{ .kind = .run }, .groups = &.{} };
    var owner = mzml.Builder.init(std.testing.allocator, .{});
    defer owner.deinit();
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    const prepared = try owner.reencoding(header, &.{ .{ .primitive = .float32, .pipeline = .zlib }, .{ .primitive = .float64, .pipeline = .zlib }, .{ .primitive = .float32, .pipeline = .zlib } });
    try std.testing.expectEqual(@as(usize, 5), prepared.header.groups.len);
    try std.testing.expectEqualStrings("zmz-reencoded-1", prepared.header.groups[3].id);
    try std.testing.expectEqualStrings("zmz-reencoded-2", prepared.header.groups[4].id);
    const copied_list = prepared.header.document.children[0];
    try std.testing.expectEqualStrings("5", copied_list.attribute("count").?);
    try std.testing.expectEqualStrings("list", copied_list.attribute("extra").?);
    try std.testing.expectEqualDeep(list.content.?.items, copied_list.content.?.items[0..2]);
    try std.testing.expectEqual(@as(usize, 2), copied_list.content.?.items[2].children);
    try std.testing.expectEqualDeep(&xml, prepared.header.groups[3].entries[0].cv.xml.?);
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    const array: mzml.model.Node = .{ .kind = .binary_data_array, .params = &.{ .{ .group_ref = .{ .ref = "zmz-reencoded-0", .xml = &xml } }, .{ .group_ref = .{ .ref = " codec ", .xml = &xml } } }, .children = &.{.{ .kind = .binary }} };
    var compressor = try mzml.zlib.Compressor.init(std.testing.allocator, .fast);
    defer compressor.deinit();
    const result = try prepared.prepareArray(&builder, f32, &.{ 1, 2 }, array, .{ .pipeline = .zlib }, &encoder);
    try std.testing.expectEqualStrings("zmz-reencoded-1", result.array.node.params[0].group_ref.ref.?);
    try std.testing.expectEqualStrings("zmz-reencoded-2", result.array.node.params[1].group_ref.ref.?);
    try std.testing.expectEqualDeep(&xml, result.array.node.params[0].group_ref.xml.?);
    try std.testing.expectEqualDeep(&xml, result.array.node.params[1].group_ref.xml.?);
    try std.testing.expectError(error.GroupRewriteRequired, prepared.prepareArray(&builder, i32, &.{1}, array, .{ .pipeline = .zlib }, &encoder));
    var limited = mzml.Builder.init(std.testing.allocator, .{ .bytes = 1 });
    defer limited.deinit();
    try std.testing.expectError(error.LimitExceeded, limited.reencoding(header, &.{.{ .primitive = .float32, .pipeline = .zlib }}));
}

fn replaceArrayAllocated(allocator: std.mem.Allocator) !void {
    const params = [_]mzml.cv.Entry{
        .{ .cv = .{ .cv_ref = "MS", .accession = mzml.model.Terms.INTENSITY_ARRAY, .name = "intensity", .unit = .{ .name = "source unit" } } },
        .{ .cv = .{ .cv_ref = "MS", .accession = .{ .raw = "MS:1000523" }, .name = "64-bit float" } },
        .{ .cv = .{ .cv_ref = "MS", .accession = .{ .raw = "MS:1000576" }, .name = "no compression" } },
        .{ .user = .{ .name = "group note", .value = "keep" } },
        .{ .cv = .{ .accession = .{ .raw = "X:future-encoding" }, .name = "64-bit float", .value = "keep" } },
    };
    const groups = [_]mzml.cv.Group{.{ .id = "encoding", .entries = &params }};
    const source: mzml.model.Node = .{
        .kind = .binary_data_array,
        .attributes = &.{
            .{ .name = "dataProcessingRef", .value = "array-processing" },
            .{ .name = "arrayLength", .value = "3" },
            .{ .name = "extra", .value = "keep" },
        },
        .params = &.{ .{ .group_ref = .{ .ref = "encoding" } }, .{ .user = .{ .name = "local note", .value = "" } }, params[1], params[2] },
        .children = &.{.{ .kind = .binary, .attributes = &.{.{ .name = "extra", .value = "binary" }}, .text = "A" ** 8192 }},
    };
    var builder = mzml.Builder.init(allocator, .{ .bytes = 4096 });
    defer builder.deinit();
    var encoder = mzml.arrays.Encoder.init(allocator, .fast);
    defer encoder.deinit();
    var compressor = try mzml.zlib.Compressor.init(allocator, .fast);
    defer compressor.deinit();
    for ([_]mzml.arrays.Pipeline{ .none, .zlib }) |pipeline| {
        for ([_]usize{ 0, 2 }) |length| {
            builder.reset();
            const values = [_]f32{ 2, 4 };
            const result = try builder.prepareArrayFrom(f32, values[0..length], source, &groups, .{ .pipeline = pipeline }, &encoder);
            var copied = mzml.Builder.init(allocator, .{});
            defer copied.deinit();
            _ = try copied.node(result.array.node);
            try std.testing.expectEqual(copied.limits.bytes - copied.remaining, builder.limits.bytes - builder.remaining);
            try std.testing.expectEqual(length, result.array.length);
            try std.testing.expect(result.array.is_default);
            try std.testing.expectEqual(null, result.array.node.child(.binary).?.text);
            try std.testing.expectEqualDeep(source.children[0].attributes, result.array.node.children[0].attributes);
            try std.testing.expectEqualStrings("array-processing", result.array.node.attribute("dataProcessingRef").?);
            try std.testing.expect(source.attribute("dataProcessingRef").?.ptr != result.array.node.attribute("dataProcessingRef").?.ptr);
            try std.testing.expectEqualStrings("keep", result.array.node.attribute("extra").?);
            try std.testing.expectEqual(length, try mzml.cv.parseInteger(usize, result.array.node.attribute("arrayLength")));
            // The source's encodedLength is kept; the writer replaces it.
            try std.testing.expectEqualDeep(source.attribute("encodedLength"), result.array.node.attribute("encodedLength"));
            try std.testing.expectEqualDeep(mzml.model.Encoding{ .primitive = .float32, .pipeline = pipeline }, try mzml.model.arrayEncoding(result.array.node, &.{}));
            try std.testing.expectEqual(@as(usize, 8), result.array.node.params.len);
            try std.testing.expectEqualDeep(params[0], result.array.node.params[0]);
            try std.testing.expectEqualDeep(params[3], result.array.node.params[3]);
            try std.testing.expectEqualDeep(params[4], result.array.node.params[4]);
            try std.testing.expectEqualDeep(source.params[1], result.array.node.params[5]);
            try std.testing.expectEqualDeep(result.array.node.params[1], result.array.node.params[6]);
            try std.testing.expectEqualDeep(result.array.node.params[2], result.array.node.params[7]);
            try std.testing.expectEqualStrings("MS:1000576", groups[0].entries[2].cv.accession.?.raw);
            var decoded: [2]f32 = undefined;
            try mzml.arrays.decodeWire(f32, decoded[0..length], try encoder.encodeSource(result.payload.source), pipeline, &.{});
            try std.testing.expectEqualSlices(f32, values[0..length], decoded[0..length]);
        }
    }
}

test "[integration] - [array replacement]: preserves source metadata while changing values and encoding" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, replaceArrayAllocated, .{});
}

test "[regression] - [array replacement]: charges only final metadata and outlives the source" {
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    var copied = mzml.Builder.init(std.testing.allocator, .{});
    defer copied.deinit();
    const values = [_]f64{ 5, 6 };
    const nodes = blk: {
        var input = std.Io.Reader.fixed(support.EXTENSIONS);
        var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        const header = try reader.readHeader();
        const source = (try reader.nextRecord()).?.binaryArrays()[0];
        var binary = source.children[0];
        binary.text = null;
        var expected_source = source;
        expected_source.children = &.{binary};
        const expected = try copied.node(expected_source);
        const bytes = copied.limits.bytes - copied.remaining;
        var limited = mzml.Builder.init(std.testing.allocator, .{ .bytes = bytes - 1 });
        defer limited.deinit();
        try std.testing.expectError(error.LimitExceeded, limited.prepareArrayFrom(f64, &values, source, header.groups, .{}, &encoder));
        var exact = mzml.Builder.init(std.testing.allocator, .{ .bytes = bytes });
        defer exact.deinit();
        const bounded = try exact.prepareArrayFrom(f64, &values, source, header.groups, .{}, &encoder);
        try std.testing.expectEqual(@as(usize, 0), exact.remaining);
        try std.testing.expectEqualDeep(expected, bounded.array.node);
        try std.testing.expectError(error.LimitExceeded, exact.prepareArrayFrom(f64, &values, source, header.groups, .{}, &encoder));
        exact.reset();
        const retried = try exact.prepareArrayFrom(f64, &values, source, header.groups, .{}, &encoder);
        try std.testing.expectEqualDeep(expected, retried.array.node);
        const result = try builder.prepareArrayFrom(f64, &values, source, header.groups, .{}, &encoder);
        break :blk .{ expected, result.array.node };
    };
    try std.testing.expectEqualDeep(nodes[0], nodes[1]);
    try std.testing.expectEqual(copied.remaining, builder.remaining);
    builder.reset();
    try std.testing.expectEqual(builder.limits.bytes, builder.remaining);
    try std.testing.expectEqualStrings("24", nodes[0].attribute("encodedLength").?);
}

test "[integration] - [array replacement]: returns metadata and allocation errors without dropping children" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const source = (try reader.nextRecord()).?.binaryArrays()[0];
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    try std.testing.expectError(error.MissingGroup, builder.prepareArrayFrom(f64, &.{1}, source, &.{}, .{}, &encoder));
    var extra_child = source;
    extra_child.children = &.{ source.children[0], .{ .kind = .binary } };
    try std.testing.expectError(error.InvalidStructure, builder.prepareArrayFrom(f64, &.{1}, extra_child, header.groups, .{}, &encoder));
    var limited = mzml.Builder.init(std.testing.allocator, .{ .bytes = 1 });
    defer limited.deinit();
    try std.testing.expectError(error.LimitExceeded, limited.prepareArrayFrom(f64, &.{1}, source, header.groups, .{}, &encoder));
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
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    var compressor = try mzml.zlib.Compressor.init(std.testing.allocator, .fast);
    defer compressor.deinit();
    const prepared = try builder.prepareArrayFrom(f64, &values, old_array, header.groups, .{ .pipeline = .zlib }, &encoder);
    try std.testing.expectEqual(null, prepared.array.node.attribute("arrayLength"));
    try std.testing.expectError(error.InvalidArrayLength, builder.record(.spectrum, original.id, 0, 1, &.{}, &.{}, &.{prepared.array}));
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
    try writer.writeRecordWithArrays(changed_record, &.{prepared.payload});
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
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    var compressor = try mzml.zlib.Compressor.init(std.testing.allocator, .fast);
    defer compressor.deinit();
    inline for (.{ f32, f64, i32, i64 }) |T| {
        const values: [5]T = if (@typeInfo(T) == .float)
            .{ -0.0, -12.5, 0.125, std.math.inf(T), std.math.nan(T) }
        else
            .{ std.math.minInt(T), -1, 0, 1, std.math.maxInt(T) };
        for ([_]mzml.arrays.Pipeline{ .none, .zlib }) |pipeline| {
            for ([_]usize{ 0, 1, values.len }) |length| {
                builder.reset();
                const result = try builder.prepareArray(T, values[0..length], .{
                    .cv_ref = "MS",
                    .role = .{ .cv_ref = "MS", .accession = .{ .raw = "X:auxiliary" }, .name = "auxiliary" },
                    .encoding = .{ .pipeline = pipeline },
                }, &encoder);
                try std.testing.expectEqual(@as(?[]const u8, null), result.array.node.child(.binary).?.text);
                // The writer writes encodedLength from the text it writes.
                try std.testing.expectEqual(null, result.array.node.attribute("encodedLength"));
                try std.testing.expectEqual(length, result.array.length);
                // The payload borrows the values; nothing is encoded until the record is written.
                try std.testing.expectEqual(std.mem.sliceAsBytes(values[0..length]).ptr, std.mem.sliceAsBytes(@field(result.payload.source.values, @tagName(mzml.model.Primitive.of(T)))).ptr);
                var output: [5]T = undefined;
                try mzml.arrays.decodeWire(T, output[0..length], try encoder.encodeSource(result.payload.source), pipeline, &.{});
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(values[0..length]), std.mem.sliceAsBytes(output[0..length]));
            }
        }
    }
}

test "[integration] - [prepared construction]: keeps builder and writer failure checks" {
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    var other = mzml.Builder.init(std.testing.allocator, .{});
    defer other.deinit();
    const options: mzml.Builder.ArrayOptions = .{ .cv_ref = "MS", .role = .{ .cv_ref = "MS", .accession = mzml.model.Terms.MZ_ARRAY, .name = "m/z array" } };
    var intensity_options = options;
    intensity_options.role.accession = mzml.model.Terms.INTENSITY_ARRAY;
    intensity_options.role.name = "intensity array";
    const a = try builder.prepareArray(f64, &.{1}, options, &encoder);
    const b = try builder.prepareArray(f64, &.{2}, intensity_options, &encoder);
    try std.testing.expectError(error.InvalidRecord, other.record(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{ a.array, b.array }));
    try std.testing.expectError(error.InvalidArrayLength, builder.record(.spectrum, "scan=1", 0, 2, &.{}, &.{}, &.{ a.array, b.array }));
    const single = try builder.record(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{a.array});
    try std.testing.expectEqual(@as(usize, 1), single.binaryArrays().len);
    // A reset frees what the arrays point into.
    var stale = mzml.Builder.init(std.testing.allocator, .{});
    defer stale.deinit();
    const old = try stale.prepareArray(f64, &.{1}, options, &encoder);
    stale.reset();
    try std.testing.expectError(error.InvalidRecord, stale.record(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{old.array}));
    var bad = options;
    bad.role.unit.cv_ref = "UO";
    const partial = try builder.prepareArray(f64, &.{1}, bad, &encoder);
    try std.testing.expectEqualDeep(bad.role.unit, partial.array.node.params[0].cv.unit);
    bad = options;
    bad.encoding.pipeline = .zlib;
    // The encoder supplies its own compressor for zlib pipelines when the record is written.
    try std.testing.expect((try builder.prepareArray(f64, &.{1}, bad, &encoder)).payload == .source);
    bad.encoding.pipeline = .linear;
    try std.testing.expectError(error.MissingFixedPoint, builder.prepareArray(f64, &.{1}, bad, &encoder));
    try std.testing.expectError(error.MissingFixedPoint, builder.prepareArray(f32, &.{1}, bad, &encoder));
    try std.testing.expectError(error.TypeMismatch, builder.prepareArray(i32, &.{1}, bad, &encoder));
    // A bad fixed point fails here, not midway through a written record.
    for ([_]mzml.arrays.Pipeline{ .linear, .slof_zlib }) |pipeline| {
        bad.encoding.pipeline = pipeline;
        for ([_]f64{ 0, -1, std.math.nan(f64), std.math.inf(f64) }) |fixed_point| {
            bad.encoding.fixed_point = fixed_point;
            try std.testing.expectError(error.InvalidFixedPoint, builder.prepareArray(f64, &.{1}, bad, &encoder));
        }
        bad.encoding.fixed_point = 0;
        _ = try builder.prepareArray(f64, &.{}, bad, &encoder);
    }
    var limited = mzml.Builder.init(std.testing.allocator, .{ .bytes = 1 });
    defer limited.deinit();
    try std.testing.expectError(error.LimitExceeded, limited.prepareArray(f64, &.{1}, options, &encoder));
    const record = try builder.record(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{ a.array, b.array });
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
    const a_wire = try encoder.encodeSource(a.payload.source);
    const b_wire = try encoder.encodeSource(b.payload.source);
    // The writer sets encodedLength from the text it writes, whatever the metadata declares.
    try writer.writeRecordWithArrays(record.node, &.{ .{ .wire = a_wire[0..4] }, .{ .wire = b_wire } });
    try std.testing.expect(std.mem.indexOf(u8, sink.buffered()[before..], "encodedLength=\"8\"") != null);
}

test "[integration] - [mzML prepared writing]: matches frozen plain and indexed output apart from zlib bytes" {
    var bytes: [32768]u8 = undefined;
    for ([_]bool{ false, true }) |indexed| {
        var sink = std.Io.Writer.fixed(&bytes);
        try support.constructFixture(std.testing.allocator, &sink, indexed, std.meta.tags(mzml.arrays.Pipeline));
        const expected = if (indexed) @embedFile("data/writer_indexed.mzML") else @embedFile("data/writer_plain.mzML");
        try support.expectWritten(std.mem.trimEnd(u8, expected, "\n"), sink.buffered());
    }
}

test "[integration] - [mzML construction]: writes and decodes every declared pipeline" {
    var buffer: [32768]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    try support.constructFixture(std.testing.allocator, &sink, false, std.meta.tags(mzml.arrays.Pipeline));
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
            try array.decode(f64, &output, .{ .transport = &transport, .transformed = &transformed });
            for (output, [_]f64{ 1, 2, 3 }) |value, expected| try std.testing.expectApproxEqAbs(expected, value, 0.001);
            if (encoding.pipeline == .pic or encoding.pipeline == .pic_zlib) {
                const counts = try mzml.base64.decode(&transport, array.node.child(.binary).?.text.?);
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
    try support.expectWritten(std.mem.trimEnd(u8, @embedFile("data/writer_plain.mzML"), "\n"), sink.buffered());
    const cases = .{
        .{ @embedFile("data/writer_linear_slof.mzML"), &[_]mzml.arrays.Pipeline{ .none, .zlib, .linear, .slof, .linear_zlib, .slof_zlib } },
        .{ @embedFile("data/writer_raw_zlib.mzML"), &[_]mzml.arrays.Pipeline{ .none, .zlib } },
    };
    inline for (cases) |case| {
        var variant_buffer: [32768]u8 = undefined;
        var variant = std.Io.Writer.fixed(&variant_buffer);
        try support.constructFixture(std.testing.allocator, &variant, true, case[1]);
        try support.expectWritten(std.mem.trimEnd(u8, case[0], "\n"), variant.buffered());
    }
}

test "[integration] - [mzML construction]: cleans failed allocations and preserves source references" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.constructAllocated, .{});
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
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    const options: mzml.Builder.ArrayOptions = .{ .cv_ref = "MS", .role = .{ .cv_ref = "MS", .accession = mzml.model.Terms.MZ_ARRAY, .name = "m/z array" } };
    const array = (try builder.prepareArray(f64, &.{1}, options, &encoder)).array;
    try std.testing.expectEqual(null, array.node.attribute("arrayLength"));
    try std.testing.expectEqual(null, array.node.attribute("dataProcessingRef"));
    var intensity_options = options;
    intensity_options.role.accession = mzml.model.Terms.INTENSITY_ARRAY;
    intensity_options.role.name = "intensity array";
    const intensity = (try builder.prepareArray(f64, &.{1}, intensity_options, &encoder)).array;
    const record = try builder.record(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{ array, intensity });
    try std.testing.expect(record.binaryArrays()[0].params.ptr == array.node.params.ptr);
    try std.testing.expect(record.binaryArrays()[1].params.ptr == intensity.node.params.ptr);
    var other = mzml.Builder.init(std.testing.allocator, .{});
    defer other.deinit();
    try std.testing.expectError(error.InvalidRecord, other.record(.spectrum, "scan=1", 0, 1, &.{}, &.{}, &.{ array, intensity }));
    try std.testing.expectError(error.InvalidArrayLength, builder.record(.spectrum, "scan=1", 0, 2, &.{}, &.{}, &.{array}));
    var bad = options;
    bad.data_processing_ref = "dp";
    const processing = (try builder.prepareArray(f64, &.{1}, bad, &encoder)).array;
    try std.testing.expectEqualStrings("dp", processing.node.attribute("dataProcessingRef").?);
    try std.testing.expectEqual(null, processing.node.attribute("arrayLength"));
    bad = options;
    bad.encoding.pipeline = .pic;
    try std.testing.expectError(error.TypeMismatch, builder.prepareArray(i64, &.{1}, bad, &encoder));
    // f32 Numpress input keeps its declared 32-bit float term; reading decodes it to f64.
    const narrow = (try builder.prepareArray(f32, &.{1}, bad, &encoder)).array;
    try std.testing.expectEqualStrings("MS:1000521", narrow.node.params[1].cv.accession.?.raw);
}

test "[failure] - [mzML construction]: rejects nodes nested past the depth ceiling" {
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var chain: [mzml.MAX_DEPTH + 1]mzml.model.Node = undefined;
    _ = try builder.node(support.nest(chain[1..]));
    try std.testing.expectError(error.LimitExceeded, builder.node(support.nest(&chain)));
    try std.testing.expectError(error.LimitExceeded, builder.record(.spectrum, "one", 0, 0, &.{}, &.{support.nest(chain[1..])}, &.{}));
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
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    var arrays: [3]mzml.Builder.Array = undefined;
    var wires: [3]mzml.Writer.ArrayPayload = undefined;
    const values = [_]f64{ 1, 2, 3 };
    for ([_]mzml.cv.Accession{ mzml.model.Terms.INTENSITY_ARRAY, mzml.model.Terms.TIME_ARRAY, mzml.model.Terms.MZ_ARRAY }, &arrays, &wires, 0..) |role, *array, *wire, position| {
        const prepared = try builder.prepareArray(f64, values[position..][0..1], .{ .cv_ref = "MS", .role = .{ .cv_ref = "MS", .accession = role, .name = "caller role" } }, &encoder);
        array.* = prepared.array;
        wire.* = prepared.payload;
    }
    const record = try builder.record(.spectrum, "one", 0, 1, &.{}, &.{}, &arrays);
    for (arrays, record.binaryArrays()) |array, copied| try support.expectNode(array.node, copied);
    var xml: [4096]u8 = undefined;
    var sink = std.Io.Writer.fixed(&xml);
    try support.writeSingleRecord(std.testing.allocator, &sink, header, record.node, false, &wires);
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
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    inline for (.{ f32, f64, i32, i64 }) |T| {
        const values: [5]T = if (@typeInfo(T) == .float)
            .{ -0.0, -12.5, 0.125, std.math.inf(T), std.math.nan(T) }
        else
            .{ std.math.minInt(T), -1, 0, 1, std.math.maxInt(T) };
        for ([_]mzml.arrays.Pipeline{ .none, .zlib }) |pipeline| {
            for ([_]usize{ 0, 1, values.len }) |length| {
                builder.reset();
                const prepared = try builder.prepareArray(T, values[0..length], .{
                    .cv_ref = "MS",
                    .role = .{ .cv_ref = "MS", .accession = .{ .raw = "X:auxiliary" }, .name = "auxiliary" },
                    .encoding = .{ .pipeline = pipeline },
                }, &encoder);
                // Decode the wire as the emitted declarations describe it.
                const declared = try mzml.model.arrayEncoding(prepared.array.node, &.{});
                try std.testing.expectEqual(mzml.model.Primitive.of(T), declared.primitive);
                var decoded: [5]T = undefined;
                const wire = try encoder.encodeSource(prepared.payload.source);
                try mzml.arrays.decodeWire(T, decoded[0..length], wire, declared.pipeline, &.{});
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

test "[failure] - [group reencoding]: refuses a reencoding whose builder was reset" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const record = (try reader.nextRecord()).?;
    var header_builder = mzml.Builder.init(std.testing.allocator, .{});
    defer header_builder.deinit();
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    const prepared = try header_builder.reencoding(header.*, &.{.{ .primitive = .float32, .pipeline = .zlib }});
    const values = [_]f32{1};
    _ = try prepared.prepareArray(&builder, f32, &values, record.binaryArrays()[0], .{ .pipeline = .zlib }, &encoder);
    header_builder.reset();
    try std.testing.expectError(error.InvalidState, prepared.prepareArray(&builder, f32, &values, record.binaryArrays()[0], .{ .pipeline = .zlib }, &encoder));
}
