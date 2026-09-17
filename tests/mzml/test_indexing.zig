//! Tests indexed output, opening, indexing, and lookup.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

fn expectDecodedNode(expected: mzml.model.Node, actual: mzml.model.Node) !void {
    try std.testing.expectEqual(expected.kind, actual.kind);
    try std.testing.expectEqualDeep(expected.attributes, actual.attributes);
    try std.testing.expectEqualDeep(expected.params, actual.params);
    try std.testing.expectEqual(expected.start_offset, actual.start_offset);
    try std.testing.expectEqual(expected.content_offset, actual.content_offset);
    try std.testing.expectEqual(expected.end_offset, actual.end_offset);
    try std.testing.expectEqualDeep(if (expected.kind == .binary) null else expected.text, actual.text);
    try std.testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |left, right| try expectDecodedNode(left, right);
}

fn expectDecodedRecord(record: mzml.model.Record, groups: []const mzml.cv.Group, actual: mzml.model.Record, output: *const mzml.StreamReader.DecodedArrays) !void {
    try expectDecodedNode(record.node, actual.node);
    try std.testing.expectEqualStrings(record.id, actual.id);
    try std.testing.expectEqual(record.index, actual.index);
    try std.testing.expectEqual(record.default_array_length, actual.default_array_length);
    try std.testing.expectEqual(record.binaryArrays().len, output.len());
    var arrays = record.arrays(groups);
    var position: usize = 0;
    while (try arrays.next()) |array| : (position += 1) {
        const decoded = output.get(position).?;
        try std.testing.expectEqualDeep(array.encoding, decoded.encoding);
        switch (decoded.values) {
            inline else => |values| {
                const T = @typeInfo(@TypeOf(values)).pointer.child;
                const expected = try std.testing.allocator.alloc(T, array.length);
                defer std.testing.allocator.free(expected);
                const transport = try std.testing.allocator.alloc(u8, array.node.child(.binary).?.text.?.len);
                defer std.testing.allocator.free(transport);
                const transformed = try std.testing.allocator.alloc(u8, try mzml.arrays.wireBound(T, array.length, array.encoding.pipeline));
                defer std.testing.allocator.free(transformed);
                try array.decode(T, expected, .{ .transport = transport, .transformed = transformed }, .{});
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(values));
            },
        }
    }
}

fn checkDecodedLookupAllocations(allocator: std.mem.Allocator) !void {
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = @embedFile("data/writer_indexed.mzML") }, .{ .policy = .open_embedded });
    defer index.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(allocator, .{});
    defer output.deinit();
    var record = (index.byIdDecoded(allocator, "scan=slof_zlib", &output) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), output.len());
        var recovered_output = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
        defer recovered_output.deinit();
        var recovered = (try index.atDecoded(std.testing.allocator, .spectrum, 0, &recovered_output)).?;
        defer recovered.deinit();
        try std.testing.expectEqual(@as(usize, 2), recovered_output.len());
        return err;
    }).?;
    defer record.deinit();
    try std.testing.expectEqual(@as(usize, 2), output.len());
}

test "[integration] - [mzML indexed decoding]: preserves codecs, groups, metadata, and independent lifetimes" {
    const allocator = std.testing.allocator;
    const source = @embedFile("data/writer_indexed.mzML");
    for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
        var output = mzml.StreamReader.DecodedArrays.init(allocator, .{});
        defer output.deinit();
        var retained = blk: {
            var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{ .policy = policy });
            defer index.deinit();
            var first = (try index.byIdDecoded(allocator, "scan=none", &output)).?;
            errdefer first.deinit();
            for (index.entries.items) |entry| {
                var decoded = (try index.atDecoded(allocator, entry.kind, entry.index, &output)).?;
                defer decoded.deinit();
                var ordinary = (try index.at(allocator, entry.kind, entry.index)).?;
                defer ordinary.deinit();
                try expectDecodedRecord(ordinary.value, index.header().groups, decoded.value, &output);
                try std.testing.expectEqualStrings("scan=none", first.value.id);
            }
            break :blk first;
        };
        defer retained.deinit();
        try std.testing.expectEqualStrings("scan=none", retained.value.id);
        try std.testing.expectEqual(@as(usize, 2), output.len());
        try std.testing.expectApproxEqAbs(@as(f64, 1), output.get(0).?.values.float64[0], 0.001);
    }
    try checkDecodedLookupAllocations(allocator);
    try std.testing.checkAllAllocationFailures(allocator, checkDecodedLookupAllocations, .{});
}

test "[failure] - [mzML indexed decoding]: clears results and recovers after decode and target failures" {
    const Selection = struct {
        fn select(_: ?*anyopaque, _: usize, _: []const mzml.model.Attribute, _: []const mzml.cv.Entry) mzml.StreamReader.Payload {
            @panic("decoded lookups must reject selectors without calling them");
        }
    };
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, @embedFile("data/writer_indexed.mzML"));
    defer allocator.free(source);
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{ .policy = .open_embedded });
    defer index.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(allocator, .{});
    defer output.deinit();
    const payload = std.mem.indexOf(u8, source, "<binary>").? + "<binary>".len;
    const end = std.mem.indexOf(u8, source, "</spectrum>").? + "</spectrum".len - 1;
    const ordinal = std.mem.indexOf(u8, source, "index=\"0\"").? + "index=\"".len;
    const id = std.mem.indexOf(u8, source, "id=\"scan=none\"").? + "id=\"".len;
    const saved = source[payload];
    for (0..4) |failure| {
        var good = (try index.atDecoded(allocator, .spectrum, 1, &output)).?;
        defer good.deinit();
        source[payload] = '!';
        const closing = source[end];
        if (failure == 1) source[end] = 'x';
        if (failure == 2) source[ordinal] = '9';
        if (failure == 3) source[id] = 'x';
        try std.testing.expectError(switch (failure) {
            0 => error.InvalidCharacter,
            1 => error.InvalidCharacter,
            else => error.InvalidIndex,
        }, index.atDecoded(allocator, .spectrum, 0, &output));
        try std.testing.expectEqual(@as(usize, 0), output.len());
        source[payload] = saved;
        source[end] = closing;
        source[ordinal] = '0';
        source[id] = 's';
    }
    var recovered = (try index.byIdDecoded(allocator, "scan=none", &output)).?;
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 2), output.len());
    try std.testing.expectEqual(null, try index.byIdDecoded(allocator, "absent", &output));
    try std.testing.expectEqual(@as(usize, 0), output.len());
    try std.testing.expectEqual(null, try index.atDecoded(allocator, .spectrum, 8, &output));
    try std.testing.expectError(error.InvalidIndex, index.atDecoded(allocator, .run, 0, &output));
    var limited = mzml.StreamReader.DecodedArrays.init(allocator, .{ .array_bytes = 1 });
    defer limited.deinit();
    try std.testing.expectError(error.LimitExceeded, index.atDecoded(allocator, .spectrum, 0, &limited));
    try std.testing.expectEqual(@as(usize, 0), limited.len());
    index.options.reader.checks = .minimal;
    try std.testing.expectError(error.InvalidOptions, index.byIdDecoded(allocator, "scan=none", &output));
    try std.testing.expectError(error.InvalidOptions, index.atDecoded(allocator, .spectrum, 0, &output));
    index.options.reader.checks = .checked;
    index.options.reader.array_selector = .{ .select = Selection.select };
    try std.testing.expectError(error.InvalidOptions, index.byIdDecoded(allocator, "scan=none", &output));
    try std.testing.expectError(error.InvalidOptions, index.atDecoded(allocator, .spectrum, 0, &output));
    try std.testing.expectEqual(@as(usize, 0), output.len());
}

test "[failure] - [mzML indexed decoding]: checks the source before publishing arrays" {
    const Source = struct {
        calls: usize = 0,
        fail_at: ?usize = null,

        fn stat(data: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.calls += 1;
            var result = try file.stat(std.testing.io);
            if (self.fail_at == self.calls) result.size += 1;
            return result;
        }

        fn read(_: ?*anyopaque, file: std.Io.File, slices: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
            return std.testing.io.vtable.fileReadPositional(std.testing.io.userdata, file, slices, offset);
        }
    };
    const allocator = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const file = try directory.dir.createFile(std.testing.io, "decoded.mzML", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, @embedFile("data/writer_indexed.mzML"));
    var source: Source = .{};
    var vtable = std.Io.failing.vtable.*;
    vtable.fileStat = Source.stat;
    vtable.fileReadPositional = Source.read;
    const io: std.Io = .{ .userdata = &source, .vtable = &vtable };
    var index = try mzml.IndexedReader.build(allocator, .{ .file = .{ .handle = file, .io = io } }, .{ .policy = .open_embedded });
    defer index.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(allocator, .{});
    defer output.deinit();
    for (1..4) |fail_at| {
        source = .{};
        var good = (try index.atDecoded(allocator, .spectrum, 0, &output)).?;
        defer good.deinit();
        try std.testing.expectEqual(@as(usize, 3), source.calls);
        source = .{ .fail_at = fail_at };
        try std.testing.expectError(error.StaleSource, index.byIdDecoded(allocator, "scan=zlib", &output));
        try std.testing.expectEqual(@as(usize, 0), output.len());
        try std.testing.expectEqual(fail_at, source.calls);
    }
    source = .{};
    var recovered = (try index.atDecoded(allocator, .spectrum, 1, &output)).?;
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 2), output.len());
}

test "[integration] - [mzML indexed decoding]: preserves every primitive's bits and empty arrays" {
    const allocator = std.testing.allocator;
    const wire = [_]u8{ 0, 0, 0, 0x80, 0x12, 0x34, 0xc0, 0x7f, 0, 0, 0, 0, 0, 0, 0xf8, 0x7f };
    var text_buffer: [24]u8 = undefined;
    const text = try mzml.base64.encode(&text_buffer, &wire);
    var source: std.Io.Writer.Allocating = .init(allocator);
    defer source.deinit();
    try source.writer.writeAll(support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'><spectrum id='bits' index='0' defaultArrayLength='0'><binaryDataArrayList count='5'>");
    const primitives = .{
        .{ "MS:1000521", 4 },
        .{ "MS:1000523", 2 },
        .{ "MS:1000519", 4 },
        .{ "MS:1000522", 2 },
    };
    inline for (primitives) |primitive| {
        try source.writer.print("<binaryDataArray encodedLength='{d}' arrayLength='{d}'><cvParam cvRef='MS' accession='{s}' name='primitive'/><cvParam cvRef='MS' accession='MS:1000576' name='no compression'/><binary>{s}</binary></binaryDataArray>", .{ text.len, primitive[1], primitive[0], text });
    }
    try source.writer.writeAll("<binaryDataArray encodedLength='0'><cvParam cvRef='MS' accession='MS:1000523' name='64-bit float'/><cvParam cvRef='MS' accession='MS:1000574' name='zlib compression'/><binary/></binaryDataArray></binaryDataArrayList></spectrum></spectrumList></run></mzML>");
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source.written() }, .{ .policy = .rebuild });
    defer index.deinit();
    var output = mzml.StreamReader.DecodedArrays.init(allocator, .{});
    defer output.deinit();
    var decoded = (try index.atDecoded(allocator, .spectrum, 0, &output)).?;
    defer decoded.deinit();
    var retained = (try index.byId(allocator, "bits")).?;
    defer retained.deinit();
    try expectDecodedRecord(retained.value, index.header().groups, decoded.value, &output);
    try std.testing.expectEqual(@as(usize, 5), output.len());
    try std.testing.expectEqual(@as(usize, 0), output.get(4).?.values.float64.len);
    for (0..4) |position| {
        switch (output.get(position).?.values) {
            inline else => |values| {
                const T = @typeInfo(@TypeOf(values)).pointer.child;
                const U = std.meta.Int(.unsigned, @bitSizeOf(T));
                for (values, 0..) |value, i| try std.testing.expectEqual(std.mem.readInt(U, wire[i * @sizeOf(T) ..][0..@sizeOf(T)], .little), @as(U, @bitCast(value)));
            },
        }
    }
}

test "[integration] - [mzML indexed selection]: selects only fetched arrays and restarts positions after failed lookups" {
    const Selection = struct {
        calls: usize = 0,
        wrong_position: bool = false,

        fn select(user_data: ?*anyopaque, position: usize, _: []const mzml.model.Attribute, _: []const mzml.cv.Entry) mzml.StreamReader.Payload {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            self.wrong_position = self.wrong_position or position != self.calls % 2;
            self.calls += 1;
            return if (position == 0) .retain else .skip;
        }
    };
    const allocator = std.testing.allocator;
    const source = @embedFile("data/writer_indexed.mzML");
    for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
        for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
            var selection: Selection = .{};
            var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{
                .policy = policy,
                .reader = .{ .checks = checks, .array_selector = .{ .user_data = &selection, .select = Selection.select } },
            });
            defer index.deinit();
            try std.testing.expectEqual(@as(usize, 0), selection.calls);
            var first = (try index.at(allocator, .spectrum, 0)).?;
            defer first.deinit();
            var next = (try index.at(allocator, .chromatogram, 1)).?;
            defer next.deinit();
            for ([_]mzml.model.Record{ first.value, next.value }) |record| {
                const arrays = record.binaryArrays();
                try std.testing.expectEqual(@as(usize, 2), arrays.len);
                try std.testing.expect(arrays[0].child(.binary).?.text != null);
                try std.testing.expectEqual(null, arrays[1].child(.binary).?.text);
            }
            try std.testing.expectEqual(@as(usize, 4), selection.calls);
            try std.testing.expect(!selection.wrong_position);
        }
    }
    const malformed = try allocator.dupe(u8, source);
    defer allocator.free(malformed);
    const end = std.mem.indexOf(u8, malformed, "</spectrum>").?;
    malformed[end + "</spectrum>".len - 2] = 'x';
    var selection: Selection = .{};
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = malformed }, .{
        .policy = .open_embedded,
        .reader = .{ .array_selector = .{ .user_data = &selection, .select = Selection.select } },
    });
    defer index.deinit();
    try std.testing.expectError(error.InvalidXml, index.at(allocator, .spectrum, 0));
    try std.testing.expectEqual(@as(usize, 2), selection.calls);
    var next = (try index.at(allocator, .spectrum, 1)).?;
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 4), selection.calls);
    try std.testing.expect(!selection.wrong_position);
    try std.testing.expectEqual(null, next.value.binaryArrays()[1].child(.binary).?.text);
}

test "[integration] - [mzML index]: restores inherited namespaces across repeated encoded lookups" {
    const prefixed = support.HEADER ++
        "<spectrumList xmlns:p='http://psi.hupo.org/ms/mzml' xmlns:q='http://www.w3.org/2001/XMLSchema-instance' count='2' defaultDataProcessingRef='dp'>" ++
        "<p:spectrum xmlns:q='urn:shadow' xmlns:unused='" ++ "x" ** 512 ++ "' id='scan=1' index='0' defaultArrayLength='0'><p:userParam name='note' value='one'/></p:spectrum>" ++
        "<p:spectrum q:schemaLocation='restored' id='scan=2' index='1' defaultArrayLength='0'/></spectrumList>" ++
        "<chromatogramList xmlns:p='http://psi.hupo.org/ms/mzml' xmlns:q='http://www.w3.org/2001/XMLSchema-instance' count='1' defaultDataProcessingRef='dp'>" ++
        "<p:chromatogram q:schemaLocation='chromatogram' id='tic' index='0' defaultArrayLength='1'>" ++ support.ARRAYS ++ "</p:chromatogram></chromatogramList></run></mzML>";
    var bytes: [prefixed.len * 2 + 2]u8 = undefined;
    for ([_]?std.builtin.Endian{ null, .little, .big }) |encoding| {
        const encoded = if (encoding) |endian| blk: {
            std.mem.writeInt(u16, bytes[0..2], 0xfeff, endian);
            for (prefixed, 0..) |byte, i| std.mem.writeInt(u16, bytes[2 + i * 2 ..][0..2], byte, endian);
            break :blk bytes[0..];
        } else prefixed;
        for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
            var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = encoded }, .{ .policy = .rebuild, .reader = .{ .checks = checks } });
            defer index.deinit();
            for ([_]usize{ 0, 1, 0, 2, 2, 1, 1 }) |position| {
                var input = std.Io.Reader.fixed(encoded);
                var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{ .checks = checks });
                defer reader.deinit();
                for (0..position) |_| _ = try reader.nextRecord();
                const expected = (try reader.nextRecord()).?;
                var record = (try index.byId(std.testing.allocator, expected.id)).?;
                defer record.deinit();
                try std.testing.expectEqualDeep(expected, record.value);
                const first_offset = std.mem.indexOf(u8, prefixed, "<p:spectrum ").?;
                if (position == 0) try std.testing.expectEqual(@as(u64, if (encoding != null) 2 + 2 * first_offset else first_offset), record.value.node.start_offset);
            }
        }
    }
}

test "[integration] - [mzML indexed lookup]: retains records and recovers after caller allocation failure" {
    try support.checkLookupAllocator(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.checkLookupAllocator, .{});
}

test "[integration] - [mzML indexed lookup]: crosses file refills with UTF-16 and wrapped payloads" {
    const allocator = std.testing.allocator;
    const spaces: [65537]u8 = @splat(' ');
    const split = comptime std.mem.indexOf(u8, support.SPECTRUM, "<binary>").? + "<binary>".len;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    for ([_]usize{ 65534, 65535, 65536, 65537 }) |padding| {
        var source: std.Io.Writer.Allocating = .init(allocator);
        defer source.deinit();
        try source.writer.writeAll(support.HEADER ++ "<spectrumList count='1' defaultDataProcessingRef='dp'>");
        try source.writer.writeAll(support.SPECTRUM[0..split]);
        try source.writer.writeAll(spaces[0..padding]);
        try source.writer.writeAll("\r\n&#x9;" ++ support.SPECTRUM[split..] ++ "</spectrumList></run></mzML>");
        for ([_]?std.builtin.Endian{ null, .little, .big }) |endian| {
            const encoded = try allocator.alloc(u8, if (endian != null) 2 + source.written().len * 2 else source.written().len);
            defer allocator.free(encoded);
            if (endian) |order| {
                std.mem.writeInt(u16, encoded[0..2], 0xfeff, order);
                for (source.written(), 0..) |byte, i| std.mem.writeInt(u16, encoded[2 + i * 2 ..][0..2], byte, order);
            } else @memcpy(encoded, source.written());
            const file = try directory.dir.createFile(std.testing.io, "refills.mzML", .{ .read = true });
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, encoded);
            for ([_]mzml.StreamReader.Payload{ .retain, .skip }) |payload| {
                var input = std.Io.Reader.fixed(encoded);
                var reader = try mzml.StreamReader.init(allocator, &input, .{ .payload = payload });
                defer reader.deinit();
                const expected = (try reader.nextRecord()).?;
                for ([_]mzml.IndexedReader.Source{ .{ .bytes = encoded }, .{ .file = .{ .handle = file, .io = std.testing.io } } }) |indexed_source| {
                    var index = try mzml.IndexedReader.build(allocator, indexed_source, .{ .policy = .rebuild, .reader = .{ .payload = payload } });
                    defer index.deinit();
                    const span: usize = @intCast(index.entries.items[0].end - index.entries.items[0].start);
                    index.options.record_span_bytes = span - 1;
                    try std.testing.expectError(error.LimitExceeded, index.at(allocator, .spectrum, 0));
                    index.options.record_span_bytes = span;
                    var record = (try index.byId(allocator, expected.id)).?;
                    defer record.deinit();
                    try std.testing.expectEqualDeep(expected, record.value);
                    var output = mzml.StreamReader.DecodedArrays.init(allocator, .{});
                    defer output.deinit();
                    var decoded = (try index.atDecoded(allocator, .spectrum, 0, &output)).?;
                    defer decoded.deinit();
                    try std.testing.expectEqual(@as(usize, 2), output.len());
                    try std.testing.expectEqualSlices(f64, &.{1}, output.get(0).?.values.float64);
                    try std.testing.expectEqualSlices(f64, &.{1}, output.get(1).?.values.float64);
                    if (payload == .retain) {
                        try expectDecodedRecord(record.value, index.header().groups, decoded.value, &output);
                        var arrays = record.value.arrays(index.header().groups);
                        var value: [1]f64 = undefined;
                        try (try arrays.next()).?.decode(f64, &value, .{ .transport = &.{}, .transformed = &.{} }, .{});
                        try std.testing.expectEqual(@as(f64, 1), value[0]);
                    }
                }
            }
        }
    }
}

test "[regression] - [mzML indexed lookup]: reads a later target after a malformed record" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, @embedFile("data/writer_indexed.mzML"));
    defer allocator.free(bytes);
    const end = std.mem.indexOf(u8, bytes, "</spectrum>").?;
    bytes[end + "</spectrum>".len - 2] = 'x';
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{});
    defer index.deinit();
    var retained = (try index.at(allocator, .spectrum, 1)).?;
    defer retained.deinit();
    try std.testing.expectError(error.InvalidXml, index.at(allocator, .spectrum, 0));
    for (0..2) |_| {
        var valid = (try index.at(allocator, .spectrum, 1)).?;
        defer valid.deinit();
        try std.testing.expectEqualDeep(retained.value, valid.value);
        try std.testing.expectEqualStrings("scan=zlib", valid.value.id);
    }
}

test "[property] - [mzML index]: preserves ID lookups across growth and reversed index lists" {
    const Build = struct {
        fn check(allocator: std.mem.Allocator, bytes: []const u8, policy: mzml.IndexedReader.Policy) !void {
            var index = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .policy = policy });
            defer index.deinit();
            try std.testing.expectEqual(@as(usize, 59), index.entries.items.len);
        }
    };
    const allocator = std.testing.allocator;
    const counts = [_]usize{ 40, 19 };
    const kinds = [_]mzml.model.Kind{ .spectrum, .chromatogram };
    for ([_]bool{ false, true }) |reversed| {
        var source: std.Io.Writer.Allocating = .init(allocator);
        defer source.deinit();
        var offsets: [59]usize = undefined;
        var position: usize = 0;
        try source.writer.writeAll("<indexedmzML xmlns='http://psi.hupo.org/ms/mzml'>" ++ support.HEADER);
        for (kinds, counts) |kind, count| {
            const name = kind.xmlName();
            try source.writer.print("<{s}List count='{d}' defaultDataProcessingRef='dp'>", .{ name, count });
            for (0..count) |i| {
                offsets[position] = source.written().len;
                position += 1;
                try source.writer.print("<{s} id='{s}&amp;{d:0>2}' index='{d}' defaultArrayLength='1'>" ++ support.ARRAYS ++ "</{s}>", .{ name, name, i, i, name });
            }
            try source.writer.print("</{s}List>", .{name});
        }
        try source.writer.writeAll("</run></mzML>");
        const index_start = source.written().len;
        try source.writer.writeAll("<indexList count='2'>");
        for (0..2) |order| {
            const k = if (reversed) 1 - order else order;
            const name = kinds[k].xmlName();
            try source.writer.print("<index name='{s}'>", .{name});
            for (0..counts[k]) |i| {
                try source.writer.print("<offset idRef='{s}&amp;{d:0>2}'>{d}</offset>", .{ name, i, offsets[i + if (k == 0) @as(usize, 0) else counts[0]] });
            }
            try source.writer.writeAll("</index>");
        }
        try source.writer.print("</indexList><indexListOffset>{d}</indexListOffset><fileChecksum>", .{index_start});
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(source.written(), &digest, .{});
        try source.writer.print("{s}</fileChecksum></indexedmzML>", .{std.fmt.bytesToHex(digest, .lower)});

        for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
            var retained = blk: {
                var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source.written() }, .{ .policy = policy });
                defer index.deinit();
                var first = (try index.byId(allocator, "spectrum&00")).?;
                errdefer first.deinit();
                for (kinds, counts) |kind, count| {
                    for (0..count) |i| {
                        var id: [64]u8 = undefined;
                        const query = try std.fmt.bufPrint(&id, "{s}&{d:0>2}", .{ kind.xmlName(), i });
                        var named = (try index.byId(allocator, query)).?;
                        defer named.deinit();
                        var ordinal = (try index.at(allocator, kind, i)).?;
                        defer ordinal.deinit();
                        try std.testing.expectEqualStrings(query, named.value.id);
                        try std.testing.expectEqual(i, named.value.index);
                        try std.testing.expectEqual(kind, named.value.node.kind);
                        try std.testing.expectEqualDeep(ordinal.value, named.value);
                    }
                }
                try std.testing.expectEqual(null, try index.byId(allocator, "spectrum&40"));
                try std.testing.expectEqual(null, try index.byId(allocator, "chromatogram&19"));
                break :blk first;
            };
            defer retained.deinit();
            try std.testing.expectEqualStrings("spectrum&00", retained.value.id);
            try std.testing.checkAllAllocationFailures(allocator, Build.check, .{ source.written(), policy });
            const duplicate = try std.mem.replaceOwned(u8, allocator, source.written(), "spectrum&amp;39", "spectrum&amp;00");
            defer allocator.free(duplicate);
            try std.testing.expectError(error.DuplicateId, mzml.IndexedReader.build(allocator, .{ .bytes = duplicate }, .{ .policy = policy }));
        }
    }
}

test "[integration] - [mzML index]: opens embedded targets without checking unread records or checksums" {
    var buffer: [32768]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    try support.constructFixture(std.testing.allocator, &sink, true, std.meta.tags(mzml.arrays.Pipeline), false);
    try support.checkOpenEmbedded(std.testing.allocator, sink.buffered());
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.checkOpenEmbedded, .{sink.buffered()});
    try std.testing.expectError(error.InvalidOptions, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .open_embedded, .tail_bytes = 0 }));
    try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .open_embedded, .max_records = 1 }));
    try std.testing.expectError(error.MissingIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = support.DOCUMENT }, .{ .policy = .open_embedded }));
    const checksum_start = std.mem.indexOf(u8, sink.buffered(), "<fileChecksum>").? + "<fileChecksum>".len;
    const saved = buffer[checksum_start];
    buffer[checksum_start] = if (saved == '0') '1' else '0';
    try support.checkOpenEmbedded(std.testing.allocator, sink.buffered());
    try support.checkIndexed(std.testing.allocator, sink.buffered());
    buffer[checksum_start] = saved;
    const marker = "<offset idRef=\"scan=none\">";
    const target_start = std.mem.indexOf(u8, sink.buffered(), marker).? + marker.len;
    const saved_target = buffer[target_start];
    buffer[target_start] = '0';
    try std.testing.expectError(error.InvalidIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .open_embedded }));
    buffer[target_start] = saved_target;
    const id_start = target_start - "none\">".len;
    @memcpy(buffer[id_start..][0..4], "zlib");
    try std.testing.expectError(error.DuplicateId, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .open_embedded }));
    @memcpy(buffer[id_start..][0..4], "none");
    buffer[checksum_start] = 'x';
    try support.checkIndexed(std.testing.allocator, sink.buffered());
    buffer[checksum_start] = saved;
    for ([_][]const u8{ "", "unchecked", "0" ** 41 }) |text| {
        const bytes = try std.mem.replaceOwned(u8, std.testing.allocator, sink.buffered(), sink.buffered()[checksum_start..][0..40], text);
        defer std.testing.allocator.free(bytes);
        try support.checkIndexed(std.testing.allocator, bytes);
    }
    const first_index = std.mem.indexOf(u8, sink.buffered(), "index=\"0\"").? + "index=\"".len;
    buffer[first_index] = '9';
    var opened = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{});
    defer opened.deinit();
    try std.testing.expectError(error.InvalidIndex, opened.at(std.testing.allocator, .spectrum, 0));
}

test "[integration] - [mzML index]: opens indented encoded targets and restores list namespaces" {
    const FailedRead = struct {
        start: u64,
        stop: u64,
        truncated: bool,
        active: bool = false,
        failed: bool = false,

        fn stat(_: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
            return file.stat(std.testing.io);
        }

        fn read(data: ?*anyopaque, file: std.Io.File, slices: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (offset == self.start) self.active = true;
            if (self.active and offset >= self.stop) {
                self.failed = true;
                if (self.truncated) return 0;
                return error.InputOutput;
            }
            const length: usize = @intCast(@min(slices[0].len, 113, if (self.active) self.stop - offset else std.math.maxInt(u64)));
            return std.testing.io.vtable.fileReadPositional(std.testing.io.userdata, file, &.{slices[0][0..length]}, offset);
        }
    };
    const allocator = std.testing.allocator;
    const spaces: [65537]u8 = @splat(' ');
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    for ([_]?std.builtin.Endian{ null, .little, .big }) |endian| {
        for ([_]usize{ 0, spaces.len }) |padding| {
            for (0..2) |spectra| {
                const width: usize = if (endian != null) 2 else 1;
                const bom: usize = if (endian != null) 2 else 0;
                var source: std.Io.Writer.Allocating = .init(allocator);
                defer source.deinit();
                try source.writer.writeAll("<p:indexedmzML xmlns:p='http://psi.hupo.org/ms/mzml'>" ++ support.HEADER);
                try source.writer.print("<spectrumList count='{d}' defaultDataProcessingRef='dp'>", .{spectra});
                const spectrum_start = bom + width * source.written().len;
                if (spectra != 0) try source.writer.writeAll("\r\n \t<spectrum id='a&amp;b' index='0' defaultArrayLength='0'/>");
                try source.writer.writeAll(spaces[0..padding]);
                try source.writer.writeAll("</spectrumList><chromatogramList xmlns:q='http://psi.hupo.org/ms/mzml' count='1' defaultDataProcessingRef='dp'>");
                const chromatogram_start = bom + width * source.written().len;
                try source.writer.writeAll(spaces[0..padding]);
                try source.writer.writeAll("\r\n \t<q:chromatogram id='tic' index='0' defaultArrayLength='1'>" ++ support.ARRAYS ++ "</q:chromatogram></chromatogramList></run></mzML>");
                const index_start = bom + width * source.written().len;
                try source.writer.writeAll(spaces[0..padding]);
                try source.writer.print("\r\n \t<p:indexList count='2'><p:index name='chromatogram'><p:offset idRef='tic'>{d}</p:offset></p:index><p:index name='spectrum'>", .{chromatogram_start});
                try source.writer.writeAll(spaces[0..padding]);
                if (spectra != 0) try source.writer.print("<p:offset idRef='a&amp;b'>{d}</p:offset>", .{spectrum_start});
                try source.writer.print("</p:index></p:indexList><p:indexListOffset>{d}</p:indexListOffset><p:fileChecksum>0000000000000000000000000000000000000000</p:fileChecksum></p:indexedmzML><!-- <indexListOffset>fake -->", .{index_start});
                const bytes = try allocator.alloc(u8, bom + width * source.written().len);
                defer allocator.free(bytes);
                if (endian) |order| {
                    std.mem.writeInt(u16, bytes[0..2], 0xfeff, order);
                    for (source.written(), 0..) |byte, i| std.mem.writeInt(u16, bytes[2 + 2 * i ..][0..2], byte, order);
                } else @memcpy(bytes, source.written());
                const checksum_start = bom + width * (std.mem.indexOf(u8, source.written(), "<p:fileChecksum>").? + "<p:fileChecksum>".len);
                var digest: [20]u8 = undefined;
                std.crypto.hash.Sha1.hash(bytes[0..checksum_start], &digest, .{});
                const hex = std.fmt.bytesToHex(digest, .lower);
                if (endian) |order| {
                    for (hex, 0..) |byte, i| std.mem.writeInt(u16, bytes[checksum_start + 2 * i ..][0..2], byte, order);
                } else @memcpy(bytes[checksum_start..][0..hex.len], &hex);
                const file = try directory.dir.createFile(std.testing.io, "opening.mzML", .{ .read = true });
                defer file.close(std.testing.io);
                try file.writeStreamingAll(std.testing.io, bytes);
                for ([_]mzml.IndexedReader.Source{ .{ .bytes = bytes }, .{ .file = .{ .handle = file, .io = std.testing.io } } }) |indexed_source| {
                    for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
                        var opened = try mzml.IndexedReader.build(allocator, indexed_source, .{ .reader = .{ .checks = checks } });
                        defer opened.deinit();
                        var rebuilt = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .policy = .rebuild });
                        defer rebuilt.deinit();
                        try std.testing.expectEqual(spectra + 1, opened.entries.items.len);
                        for (opened.entries.items) |entry| {
                            var actual = (try opened.at(allocator, entry.kind, 0)).?;
                            defer actual.deinit();
                            var expected = (try rebuilt.at(allocator, entry.kind, 0)).?;
                            defer expected.deinit();
                            try support.expectNode(expected.value.node, actual.value.node);
                            try std.testing.expectEqual(expected.value.node.start_offset, actual.value.node.start_offset);
                            try std.testing.expectEqual(expected.value.node.end_offset, actual.value.node.end_offset);
                            if (checks == .checked) {
                                var output = mzml.StreamReader.DecodedArrays.init(allocator, .{});
                                defer output.deinit();
                                var decoded = (try opened.byIdDecoded(allocator, entry.id, &output)).?;
                                defer decoded.deinit();
                                try expectDecodedRecord(actual.value, opened.header().groups, decoded.value, &output);
                            }
                        }
                        if (spectra != 0) try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.build(allocator, indexed_source, .{
                            .policy = .open_embedded,
                            .record_span_bytes = chromatogram_start - spectrum_start - 1,
                            .reader = .{ .checks = checks },
                        }));
                        try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.build(allocator, indexed_source, .{
                            .policy = .open_embedded,
                            .index_bytes = bytes.len - index_start - 1,
                            .reader = .{ .checks = checks },
                        }));
                    }
                }
                if (padding != 0 and spectra != 0) {
                    var vtable = std.Io.failing.vtable.*;
                    vtable.fileStat = FailedRead.stat;
                    vtable.fileReadPositional = FailedRead.read;
                    for ([_]usize{ index_start, spectrum_start }) |start| {
                        for ([_]bool{ false, true }) |malformed| {
                            const damaged: u8 = if (start == index_start) '<' else 'x';
                            var name: [2]u8 = .{ damaged, 0 };
                            if (endian) |order| std.mem.writeInt(u16, &name, damaged, order);
                            const damage_offset = start + "\r\n \t<".len * width;
                            if (malformed) try file.writePositionalAll(std.testing.io, name[0..width], damage_offset);
                            for ([_]bool{ false, true }) |truncated| {
                                var failure: FailedRead = .{ .start = start, .stop = start + 65536, .truncated = truncated };
                                const io: std.Io = .{ .userdata = &failure, .vtable = &vtable };
                                const expected = if (malformed)
                                    (if (start == index_start) error.InvalidXml else error.InvalidStructure)
                                else if (truncated) error.TruncatedSource else error.InputOutput;
                                try std.testing.expectError(expected, mzml.IndexedReader.build(allocator, .{ .file = .{ .handle = file, .io = io } }, .{ .policy = .open_embedded }));
                                try std.testing.expectEqual(!malformed, failure.failed);
                            }
                            try file.writePositionalAll(std.testing.io, bytes[damage_offset..][0..width], damage_offset);
                        }
                    }
                    var opened = try mzml.IndexedReader.build(allocator, .{ .file = .{ .handle = file, .io = std.testing.io } }, .{});
                    defer opened.deinit();
                    var failure: FailedRead = .{ .start = spectrum_start, .stop = spectrum_start + 65536, .truncated = false };
                    opened.source.file.io = .{ .userdata = &failure, .vtable = &vtable };
                    var record = (try opened.at(allocator, .spectrum, 0)).?;
                    defer record.deinit();
                    try std.testing.expectEqualStrings("a&b", record.value.id);
                    try std.testing.expect(!failure.failed);
                }
            }
        }
    }
}

test "[integration] - [mzML minimal checks]: retains index bounds and record identity checks" {
    const allocator = std.testing.allocator;
    const source = @embedFile("data/writer_indexed.mzML");
    for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
        var expected = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{ .policy = policy });
        defer expected.deinit();
        var actual = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{ .policy = policy, .reader = .{ .checks = .minimal } });
        defer actual.deinit();
        try std.testing.expectEqualDeep(expected.header().*, actual.header().*);
        try std.testing.expectEqualDeep(expected.entries.items, actual.entries.items);
        for (actual.entries.items) |entry| {
            var checked = (try expected.at(allocator, entry.kind, entry.index)).?;
            defer checked.deinit();
            var minimal = (try actual.byId(allocator, entry.id)).?;
            defer minimal.deinit();
            try std.testing.expectEqualDeep(checked.value, minimal.value);
        }
    }
    const bytes = try allocator.dupe(u8, source);
    defer allocator.free(bytes);
    const checksum_start = std.mem.indexOf(u8, bytes, "<fileChecksum>").? + "<fileChecksum>".len;
    bytes[checksum_start] = if (bytes[checksum_start] == '0') '1' else '0';
    var changed_checksum = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .reader = .{ .checks = .minimal } });
    changed_checksum.deinit();
    @memcpy(bytes, source);
    const first_index = std.mem.indexOf(u8, bytes, "index=\"0\"").? + "index=\"".len;
    bytes[first_index] = '9';
    var opened = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .policy = .open_embedded, .reader = .{ .checks = .minimal } });
    defer opened.deinit();
    try std.testing.expectError(error.InvalidIndex, opened.at(allocator, .spectrum, 0));
    const malformed = try std.mem.replaceOwned(u8, allocator, source, "order=\"0\"", "order=\"bad\"");
    defer allocator.free(malformed);
    try std.testing.expectError(error.InvalidValue, mzml.IndexedReader.build(allocator, .{ .bytes = malformed }, .{ .policy = .rebuild, .reader = .{ .checks = .minimal } }));
}

test "[integration] - [mzML index]: verifies emitted targets checksum and independent lookups" {
    var buffer: [32768]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    try support.constructFixture(std.testing.allocator, &sink, true, std.meta.tags(mzml.arrays.Pipeline), false);
    try support.checkIndexed(std.testing.allocator, sink.buffered());
    try std.testing.checkAllAllocationFailures(std.testing.allocator, support.checkIndexed, .{sink.buffered()});
    const checksum_start = std.mem.indexOf(u8, sink.buffered(), "<fileChecksum>").? + "<fileChecksum>".len;
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(sink.buffered()[0..checksum_start], &digest, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), sink.buffered()[checksum_start..][0..40]);
    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, @embedFile("data/writer_indexed.mzML"), "\n"), sink.buffered());
    const marker = "<offset idRef=\"scan=none\">";
    const target_start = std.mem.indexOf(u8, sink.buffered(), marker).? + marker.len;
    const target_end = std.mem.indexOfScalarPos(u8, sink.buffered(), target_start, '<').?;
    var target: [32]u8 = undefined;
    const target_length = target_end - target_start;
    @memcpy(target[0..target_length], buffer[target_start..target_end]);
    @memset(buffer[target_start..target_end], '0');
    try std.testing.expectError(error.InvalidIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{}));
    @memcpy(buffer[target_start..target_end], target[0..target_length]);
    const id_start = target_start - "none\">".len;
    buffer[id_start] = 'x';
    var wrong_target = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{});
    defer wrong_target.deinit();
    try std.testing.expectError(error.InvalidIndex, wrong_target.byId(std.testing.allocator, "scan=xone"));
    buffer[id_start] = 'n';
    const offset_start = std.mem.indexOf(u8, sink.buffered(), "<indexListOffset>").? + "<indexListOffset>".len;
    buffer[offset_start] = '0';
    try std.testing.expectError(error.InvalidXml, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{}));
    var rebuilt = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .rebuild });
    defer rebuilt.deinit();
    try std.testing.expectEqual(@as(usize, 16), rebuilt.entries.items.len);
}

test "[property] - [mzML index]: preserves record checks and byte limits during rebuilding" {
    const Parse = struct {
        fn failure(bytes: []const u8, limits: mzml.StreamReader.Limits) ?anyerror {
            support.readAll(std.testing.allocator, bytes, .{ .payload = .skip, .limits = limits }) catch |err| return err;
            return null;
        }

        fn compare(bytes: []const u8, limits: mzml.StreamReader.Limits) !void {
            const expected = failure(bytes, limits);
            var index = mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = bytes }, .{ .policy = .rebuild, .reader = .{ .limits = limits } }) catch |err| {
                try std.testing.expectEqual(expected, @as(?anyerror, err));
                return;
            };
            defer index.deinit();
            try std.testing.expectEqual(null, expected);
            try std.testing.expectEqual(@as(usize, 2), index.entries.items.len);
        }
    };
    for ([_]usize{ 0, 1, 2, 3, 4, 8, 16, 32, 64, 256, 1024, 4096, 8192 }) |limit| {
        for ([_]mzml.StreamReader.Limits{
            .{ .record_bytes = limit }, .{ .nodes = limit }, .{ .list_entries = limit },
        }) |limits| try Parse.compare(support.DOCUMENT, limits);
    }
    for ([_][2][]const u8{
        .{ "encodedLength='12'", "encodedLength='11'" },
        .{ "arrayLength='1'", "arrayLength='bad'" },
        .{ "<scanList count='1'>", "<scanList count='2'>" },
        .{ "<userParam name='note' value=''/>", "<userParam value='' extra='x'/>" },
        .{ "<userParam name='note' value=''/>", "<userParam name='note' extra='x'/>" },
        .{ "<scan>", "<scan xmlns='urn:wrong'>" },
        .{ "<activation/>", "" },
    }) |replacement| {
        const bytes = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, replacement[0], replacement[1]);
        defer std.testing.allocator.free(bytes);
        try std.testing.expect(Parse.failure(bytes, .{}) != null);
        for ([_]usize{ 0, 512, 4096, 256 * 1024 * 1024 }) |limit|
            try Parse.compare(bytes, .{ .record_bytes = limit });
    }
}

test "[integration] - [mzML index]: separates trailer budgets from header and record limits" {
    const allocator = std.testing.allocator;
    const source = @embedFile("data/writer_indexed.mzML");
    for ([_]mzml.StreamReader.Limits{
        .{ .nodes = 32 }, .{ .list_entries = 4 }, .{ .header_bytes = 4096 },
    }) |limits| {
        try std.testing.expectError(error.LimitExceeded, support.readAll(allocator, source, .{ .retain_index = true, .limits = limits }));
        var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{
            .max_records = 16,
            .reader = .{ .limits = limits },
        });
        defer index.deinit();
        try std.testing.expectEqual(@as(usize, 16), index.entries.items.len);
        var record = (try index.byId(allocator, "chromatogram=slof_zlib")).?;
        defer record.deinit();
        try std.testing.expectEqualStrings("chromatogram=slof_zlib", record.value.id);
        try std.testing.expectEqual(@as(usize, 7), record.value.index);
    }
    for ([_]mzml.IndexedReader.Options{
        .{ .max_records = 15 },                               .{ .index_bytes = 1024 },
        .{ .reader = .{ .limits = .{ .header_bytes = 1 } } }, .{ .reader = .{ .limits = .{ .nodes = 1 } } },
        .{ .reader = .{ .limits = .{ .list_entries = 1 } } },
    }) |options| {
        try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.build(allocator, .{ .bytes = source }, options));
    }
    try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{
        .policy = .rebuild,
        .reader = .{ .limits = .{ .record_bytes = 1 } },
    }));
    var opened = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{
        .policy = .open_embedded,
        .reader = .{ .limits = .{ .record_bytes = 1 } },
    });
    defer opened.deinit();
    try std.testing.expectError(error.LimitExceeded, opened.at(allocator, .spectrum, 0));
}

test "[failure] - [mzML index]: rejects unusable and truncated indexes without rebuilding" {
    const source = @embedFile("data/writer_indexed.mzML");
    var bytes: [source.len]u8 = source.*;
    const target = std.mem.indexOf(u8, &bytes, "<offset idRef=\"scan=none\">").? + "<offset idRef=\"scan=none\">".len;
    const list_offset = std.mem.indexOf(u8, &bytes, "<indexListOffset>").? + "<indexListOffset>".len;
    bytes[target] = 'x';
    bytes[list_offset] = '0';
    try std.testing.expectError(error.InvalidXml, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = &bytes }, .{}));
    bytes[list_offset] = source[list_offset];
    try std.testing.expectError(error.InvalidValue, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = &bytes }, .{}));
    const closing = std.mem.indexOf(u8, &bytes, "</fileChecksum>").?;
    bytes[closing + 2] = 'x';
    try std.testing.expectError(error.MissingIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = &bytes }, .{}));
    const trailer = std.mem.indexOf(u8, &bytes, "<indexList ").?;
    try std.testing.expectError(error.MissingIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = bytes[0..trailer] }, .{}));
}

test "[integration] - [mzML index]: builds plain files explicitly and rejects changed file sources" {
    try std.testing.expectError(error.MissingIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = support.DOCUMENT }, .{}));
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const file = try directory.dir.createFile(std.testing.io, "plain.mzML", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, support.DOCUMENT);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .file = .{ .handle = file, .io = std.testing.io } }, .{ .policy = .rebuild });
    defer index.deinit();
    var record = (try index.byId(std.testing.allocator, "native=a&b")).?;
    defer record.deinit();
    try std.testing.expectEqualStrings("native=a&b", record.value.id);
    try std.testing.expectEqual(null, try index.byId(std.testing.allocator, "absent"));
    try std.testing.expectEqual(null, try index.at(std.testing.allocator, .spectrum, 100));
    try file.setLength(std.testing.io, support.DOCUMENT.len - 1);
    try std.testing.expectError(error.StaleSource, index.byId(std.testing.allocator, "native=a&b"));
    try std.testing.expectError(error.StaleSource, index.byId(std.testing.allocator, "absent"));
    try std.testing.expectError(error.StaleSource, index.at(std.testing.allocator, .spectrum, 100));
    try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = support.DOCUMENT }, .{ .policy = .rebuild, .max_records = 1 }));
    try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = support.DOCUMENT }, .{ .policy = .rebuild, .index_bytes = 1 }));
    const duplicate = support.HEADER ++ "<spectrumList count='2' defaultDataProcessingRef='dp'>" ++
        "<spectrum id='scan=1' index='0' defaultArrayLength='0'/>" ++
        "<spectrum id='scan=1' index='1' defaultArrayLength='0'/></spectrumList></run></mzML>";
    try std.testing.expectError(error.DuplicateId, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = duplicate }, .{ .policy = .rebuild }));
}

test "[failure] - [mzML indexed lookup]: checks the source after array selection" {
    const Selection = struct {
        file: std.Io.File,
        changed: bool = false,
        failed: bool = false,

        fn select(data: ?*anyopaque, _: usize, _: []const mzml.model.Attribute, _: []const mzml.cv.Entry) mzml.StreamReader.Payload {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.file.setLength(std.testing.io, support.DOCUMENT.len - 1) catch {
                self.failed = true;
                return .skip;
            };
            self.changed = true;
            return .skip;
        }
    };
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const file = try directory.dir.createFile(std.testing.io, "changing.mzML", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, support.DOCUMENT);
    var selection: Selection = .{ .file = file };
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .file = .{ .handle = file, .io = std.testing.io } }, .{
        .policy = .rebuild,
        .reader = .{ .array_selector = .{ .user_data = &selection, .select = Selection.select } },
    });
    defer index.deinit();
    try std.testing.expect(!selection.changed);
    try std.testing.expectError(error.StaleSource, index.at(std.testing.allocator, .spectrum, 0));
    try std.testing.expect(selection.changed);
    try std.testing.expect(!selection.failed);
}

test "[integration] - [mzML record IDs]: keeps spectrum and chromatogram keys separate" {
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, "id='tic'", "id='native=a&amp;b'");
    defer std.testing.allocator.free(source);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .rebuild });
    defer index.deinit();
    try std.testing.expectError(error.AmbiguousId, index.byId(std.testing.allocator, "native=a&b"));
    var decoded = mzml.StreamReader.DecodedArrays.init(std.testing.allocator, .{});
    defer decoded.deinit();
    var decoded_record = (try index.atDecoded(std.testing.allocator, .chromatogram, 0, &decoded)).?;
    defer decoded_record.deinit();
    try std.testing.expectEqual(@as(usize, 2), decoded.len());
    try std.testing.expectError(error.AmbiguousId, index.byIdDecoded(std.testing.allocator, "native=a&b", &decoded));
    try std.testing.expectEqual(@as(usize, 0), decoded.len());
    var spectrum = (try index.at(std.testing.allocator, .spectrum, 0)).?;
    defer spectrum.deinit();
    var chromatogram = (try index.at(std.testing.allocator, .chromatogram, 0)).?;
    defer chromatogram.deinit();
    try std.testing.expectEqualStrings(spectrum.value.id, chromatogram.value.id);
    var output: [8192]u8 = undefined;
    var sink = std.Io.Writer.fixed(&output);
    var writer = try mzml.Writer.initIndexed(std.testing.allocator, &sink, .{}, .{});
    defer writer.deinit();
    try writer.writeHeader(index.header().*);
    try writer.beginList(.spectrum_list, 1, "dp");
    try writer.writeRecord(spectrum.value.node);
    try writer.endList();
    try writer.beginList(.chromatogram_list, 1, "dp");
    try writer.writeRecord(chromatogram.value.node);
    try writer.endList();
    try writer.finish();
    var verified = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{});
    defer verified.deinit();
    try std.testing.expectError(error.AmbiguousId, verified.byId(std.testing.allocator, spectrum.value.id));
    var found = (try verified.at(std.testing.allocator, .chromatogram, 0)).?;
    defer found.deinit();
    try std.testing.expectEqual(.chromatogram, found.value.node.kind);
}

test "[integration] - [mzML indexed writer]: preserves bytes and checksum through short sink writes" {
    const ShortSink = struct {
        out: std.Io.Writer,
        chunk: usize,
        writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            std.debug.assert(data.len == 1 and splat == 1);
            const self: *@This() = @alignCast(@fieldParentPtr("writer", writer));
            const length = @min(data[0].len, self.chunk);
            try self.out.writeAll(data[0][0..length]);
            return length;
        }
    };
    const expected = std.mem.trimEnd(u8, @embedFile("data/writer_indexed.mzML"), "\n");
    for ([_]usize{ 1, 7, 63, 64, 65, 4096 }) |chunk| {
        var bytes: [16384]u8 = undefined;
        var sink: ShortSink = .{ .out = .fixed(&bytes), .chunk = chunk };
        try support.constructFixture(std.testing.allocator, &sink.writer, true, std.meta.tags(mzml.arrays.Pipeline), false);
        try sink.writer.flush();
        try std.testing.expectEqualStrings(expected, sink.out.buffered());
        try support.checkIndexed(std.testing.allocator, sink.out.buffered());
    }
}

test "[failure] - [mzML indexed writer]: keeps record-limit and sink failures sticky" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const record = (try reader.nextRecord()).?;
    var buffer: [8192]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    var writer = try mzml.Writer.initIndexed(std.testing.allocator, &sink, .{}, .{ .records = 0 });
    defer writer.deinit();
    try writer.writeHeader(header.*);
    try writer.beginList(.spectrum_list, 1, "dp");
    try std.testing.expectError(error.LimitExceeded, writer.writeRecord(record.node));
    try std.testing.expectError(error.FailedState, writer.finish());
    var full = std.Io.Writer.fixed(&.{});
    var failed = try mzml.Writer.initIndexed(std.testing.allocator, &full, .{}, .{});
    defer failed.deinit();
    try std.testing.expectError(error.WriteFailed, failed.writeHeader(header.*));
    try std.testing.expectError(error.FailedState, failed.finish());
}

test "[integration] - [mzML indexed writer]: opens empty indexes and escaped IDs" {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const record = (try reader.nextRecord()).?;
    for (0..2) |count| {
        var buffer: [8192]u8 = undefined;
        var sink = std.Io.Writer.fixed(&buffer);
        var writer = try mzml.Writer.initIndexed(std.testing.allocator, &sink, .{}, .{});
        defer writer.deinit();
        try writer.writeHeader(header.*);
        if (count != 0) {
            try writer.beginList(.spectrum_list, count, "dp");
            try writer.writeRecord(record.node);
            try writer.endList();
        }
        try writer.finish();
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .max_records = count });
        defer index.deinit();
        try std.testing.expectEqual(count, index.entries.items.len);
        var rebuilt = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .rebuild, .max_records = count });
        defer rebuilt.deinit();
        try std.testing.expectEqual(count, rebuilt.entries.items.len);
        if (try index.byId(std.testing.allocator, "native=a&b")) |copied| {
            var owner = copied;
            defer owner.deinit();
            try std.testing.expectEqual(@as(usize, 1), count);
            try std.testing.expectEqualStrings("native=a&b", owner.value.id);
        } else try std.testing.expectEqual(@as(usize, 0), count);
    }
}
