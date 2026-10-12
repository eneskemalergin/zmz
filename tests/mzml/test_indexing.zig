//! Tests indexed output, opening, indexing, and lookup.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

fn expectDecodedNode(expected: mzml.model.Node, actual: mzml.model.Node) !void {
    try std.testing.expectEqual(expected.kind, actual.kind);
    try std.testing.expectEqualDeep(expected.attributes, actual.attributes);
    try std.testing.expectEqualDeep(expected.params, actual.params);
    try std.testing.expectEqualDeep(expected.content, actual.content);
    try std.testing.expectEqual(expected.start_offset, actual.start_offset);
    try std.testing.expectEqual(expected.content_offset, actual.content_offset);
    try std.testing.expectEqual(expected.end_offset, actual.end_offset);
    try std.testing.expectEqualDeep(if (expected.kind == .binary) null else expected.text, actual.text);
    try std.testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |left, right| try expectDecodedNode(left, right);
}

fn expectDecodedRecord(record: mzml.model.Record, groups: []const mzml.cv.Group, actual: mzml.model.Record, output: *const mzml.DecodedArrays) !void {
    try expectDecodedNode(record.node, actual.node);
    try std.testing.expectEqualStrings(record.id, actual.id);
    try std.testing.expectEqual(record.index, actual.index);
    try std.testing.expectEqual(record.default_array_length, actual.default_array_length);
    try std.testing.expectEqual(record.binaryArrays().len, output.len());
    var arrays = record.arrays(groups);
    var position: usize = 0;
    while (try arrays.next()) |array| : (position += 1) {
        const decoded = output.get(position).?;
        try std.testing.expectEqual(position, decoded.source_position);
        try std.testing.expectEqualDeep(array.encoding, decoded.encoding);
        switch (decoded.values) {
            inline else => |values| {
                const T = @typeInfo(@TypeOf(values)).pointer.child;
                const expected = try std.testing.allocator.alloc(T, array.length);
                defer std.testing.allocator.free(expected);
                const wire_buffer = try std.testing.allocator.alloc(u8, array.node.child(.binary).?.text.?.len);
                defer std.testing.allocator.free(wire_buffer);
                const transformed = try std.testing.allocator.alloc(u8, try mzml.arrays.wireBound(T, array.length, array.encoding.pipeline));
                defer std.testing.allocator.free(transformed);
                _ = try array.decode(T, expected, .{ .wire = wire_buffer, .transformed = transformed });
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(values));
            },
        }
    }
}

fn checkIndexed(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{});
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 16), index.entryCount());
    try std.testing.expectEqual(@as(usize, 0), index.header().spectrum_list.?.observed_count);
    var input = std.Io.Reader.fixed(bytes);
    var reader = try mzml.StreamReader.init(allocator, &input, .{});
    defer reader.deinit();
    for (0..index.entryCount()) |position| {
        const entry = index.entryAt(position).?;
        const record = (try reader.nextRecord()).?;
        try std.testing.expectEqualStrings(entry.id, record.id);
        try std.testing.expectEqual(entry.kind, record.node.kind);
        try std.testing.expectEqual(entry.start, record.node.start_offset);
        try std.testing.expect(record.node.end_offset <= entry.end);
    }
    try std.testing.expectEqual(null, try reader.nextRecord());
    for ([_]usize{ 15, 0, 7, 8, 6 }) |position| {
        const entry = index.entryAt(position).?;
        var record = (try index.byId(allocator, entry.id)).?;
        defer record.deinit();
        try std.testing.expectEqualStrings(entry.id, record.value.id);
        try std.testing.expectEqual(entry.start, record.value.node.start_offset);
        try std.testing.expect(record.value.node.end_offset <= entry.end);
        try std.testing.expectEqual(@as(usize, 2), record.value.binaryArrays().len);
        var ordinal = (try index.at(allocator, entry.kind, entry.ordinal)).?;
        defer ordinal.deinit();
        try support.expectNode(record.value.node, ordinal.value.node);
        for (record.value.binaryArrays()) |array| {
            var output: [3]f64 = undefined;
            var wire_buffer: [128]u8 = undefined;
            var transformed: [128]u8 = undefined;
            _ = try mzml.model.decodeArray(f64, &output, array, 3, index.header().groups, .{ .wire = &wire_buffer, .transformed = &transformed });
            for (output, [_]f64{ 1, 2, 3 }) |value, expected| try std.testing.expectApproxEqAbs(expected, value, 0.001);
        }
    }
    try std.testing.expectEqual(null, try index.byId(allocator, "missing"));
    try std.testing.expectEqual(null, try index.at(allocator, .spectrum, 8));
}

// Builds an index that must fail on the named limit.
fn expectBuildLimit(source: mzml.IndexedReader.Source, options: mzml.IndexedReader.Options, name: mzml.Diagnostic.Limit) !void {
    var report: ?mzml.Diagnostic = null;
    try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.buildWithDiagnostic(std.testing.allocator, source, options, &report));
    try std.testing.expectEqual(name, report.?.detail.limit.name);
}

// A sink that accepts at most one chunk of the first nonempty slice per call and passes it to out.
const ShortSink = struct {
    out: *std.Io.Writer,
    chunk: usize,
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ShortSink = @alignCast(@fieldParentPtr("writer", writer));
        for (data, 0..) |bytes, i| {
            if (bytes.len == 0 or (i == data.len - 1 and splat == 0)) continue;
            const length = @min(bytes.len, self.chunk);
            try self.out.writeAll(bytes[0..length]);
            return length;
        }
        return 0;
    }
};

test "[failure] - [mzML diagnostics]: keeps failed index builds after cleanup and clears successful builds" {
    const Check = struct {
        fn build(allocator: std.mem.Allocator, policy: mzml.IndexedReader.Policy) !void {
            var report: ?mzml.Diagnostic = null;
            var index = mzml.IndexedReader.buildWithDiagnostic(allocator, .{ .bytes = @embedFile("data/writer_indexed.mzML") }, .{ .policy = policy }, &report) catch |err| {
                try std.testing.expectEqual(err, report.?.code);
                try std.testing.expectEqual(.out_of_memory, report.?.id);
                var bytes: [512]u8 = undefined;
                var sink = std.Io.Writer.fixed(&bytes);
                try report.?.format(&sink);
                return err;
            };
            defer index.deinit();
            try std.testing.expectEqual(null, report);
        }
    };
    for ([_]mzml.IndexedReader.Policy{ .rebuild, .open_embedded }) |policy| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.build, .{policy});
        var report: ?mzml.Diagnostic = null;
        try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.buildWithDiagnostic(std.testing.allocator, .{ .bytes = @embedFile("data/writer_indexed.mzML") }, .{ .policy = policy, .records = 0 }, &report));
        try std.testing.expectEqual(.records, report.?.detail.limit.name);
        try std.testing.expectEqual(.index, report.?.stage);
        try std.testing.expectEqual(@as(u64, 0), report.?.detail.limit.maximum);
        try std.testing.expectEqual(if (policy == .rebuild) mzml.Diagnostic.Operation.rebuild_index else .open_index, report.?.operation);
        var index = try mzml.IndexedReader.buildWithDiagnostic(std.testing.allocator, .{ .bytes = @embedFile("data/writer_indexed.mzML") }, .{ .policy = policy }, &report);
        defer index.deinit();
        try std.testing.expectEqual(null, report);
        index.options.record_span_bytes = 0;
        try std.testing.expectError(error.LimitExceeded, index.at(std.testing.allocator, .spectrum, 0));
        try std.testing.expectEqual(.record_span_bytes, index.diagnostic().?.detail.limit.name);
        try std.testing.expectEqual(null, try index.at(std.testing.allocator, .spectrum, 999));
        try std.testing.expectEqual(null, index.diagnostic());
    }
    var report: ?mzml.Diagnostic = null;
    try std.testing.expectError(error.MissingIndex, mzml.IndexedReader.buildWithDiagnostic(std.testing.allocator, .{ .bytes = support.DOCUMENT }, .{}, &report));
    try std.testing.expectEqual(.missing_index, report.?.id);
    try std.testing.expectEqual(null, report.?.location);
    try std.testing.expectError(error.InvalidOptions, mzml.IndexedReader.buildWithDiagnostic(std.testing.allocator, .{ .bytes = support.DOCUMENT }, .{ .tail_bytes = 0 }, &report));
    try std.testing.expectEqual(.invalid_options, report.?.id);
    // Entry positions and ID offsets are 32 bits.
    for ([_]mzml.IndexedReader.Options{ .{ .records = 1 << 32 }, .{ .index_bytes = 1 << 32 } }) |options| {
        try std.testing.expectError(error.InvalidOptions, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = support.DOCUMENT }, options));
    }
    const missing_id = "<mzML xmlns='http://psi.hupo.org/ms/mzml'><run><spectrumList><spectrum/></spectrumList></run></mzML>";
    try std.testing.expectError(error.MissingAttribute, mzml.IndexedReader.buildWithDiagnostic(std.testing.allocator, .{ .bytes = missing_id }, .{ .policy = .rebuild }, &report));
    try std.testing.expectEqual(.id, report.?.detail.attribute);
    try std.testing.expectEqual(@as(u64, std.mem.indexOf(u8, missing_id, "<spectrum/>").?), report.?.location.?.input_event);
}

test "[failure] - [mzML diagnostics]: translates fresh and reused UTF-16 lookup events" {
    const allocator = std.testing.allocator;
    const payload = std.mem.indexOf(u8, support.DOCUMENT, "AAAAAAAA8D8=").?;
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        const source = try allocator.alloc(u8, support.DOCUMENT.len * 2 + 2);
        defer allocator.free(source);
        support.utf16(source, support.DOCUMENT, endian);
        var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{ .policy = .rebuild });
        defer index.deinit();
        var output = mzml.DecodedArrays.init(allocator, .{});
        defer output.deinit();
        for ([_]bool{ false, true }) |reuse| {
            if (reuse) {
                var record = (try index.atDecoded(allocator, .spectrum, 0, &output)).?;
                record.deinit();
                try std.testing.expectEqual(null, index.diagnostic());
            }
            std.mem.writeInt(u16, source[2 + payload * 2 ..][0..2], '!', endian);
            try std.testing.expectError(error.InvalidCharacter, index.atDecoded(allocator, .spectrum, 0, &output));
            const report = index.diagnostic().?;
            try std.testing.expectEqual(@as(u64, 2 + payload * 2), report.location.?.input_event);
            try std.testing.expectEqual(@as(usize, 1), report.array_position.?);
            std.mem.writeInt(u16, source[2 + payload * 2 ..][0..2], 'A', endian);
        }
    }
}

test "[regression] - [mzML index]: decoy offset tags after the index are passed over cheaply" {
    const allocator = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    try support.constructFixture(allocator, &sink.writer, true, &.{.none});
    // Bare tags, then a complete footer, inside a comment after the document.
    try sink.writer.writeAll("<!--" ++ " <indexListOffset" ** 2_000);
    try sink.writer.writeAll("<indexListOffset>1</indexListOffset><fileChecksum>0</fileChecksum></indexedmzML>-->");
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = sink.written() }, .{ .policy = .open_embedded });
    defer index.deinit();
    var record = (try index.at(allocator, .spectrum, 0)).?;
    defer record.deinit();
    try std.testing.expectEqualStrings("scan=none", record.value.id);
}

test "[integration] - [mzML 1.0 indexes]: retains IDs, offsets, and selected values in every lookup" {
    const Check = struct {
        fn select(_: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
            return if (view.position == 0) .retain else .skip;
        }

        fn run(allocator: std.mem.Allocator, bytes: []const u8, policy: mzml.IndexedReader.Policy, selected: bool) !void {
            var index = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{
                .policy = policy,
                .reader = .{ .array_selector = if (selected) .{ .select = select } else null },
            });
            defer index.deinit();
            try std.testing.expectEqualStrings("http://psi.hupo.org/schema_revision/mzML_1.0.0", index.header().namespace_uri);
            var input = std.Io.Reader.fixed(bytes);
            var reader = try mzml.StreamReader.init(allocator, &input, .{ .array_selector = if (selected) .{ .select = select } else null });
            defer reader.deinit();
            var decoded = mzml.DecodedArrays.init(allocator, .{});
            defer decoded.deinit();
            for (0..index.entryCount()) |position| {
                const entry = index.entryAt(position).?;
                const expected = (try reader.nextRecord()).?;
                try std.testing.expectEqualStrings(entry.id, expected.id);
                var by_id = (try index.byId(allocator, entry.id)).?;
                defer by_id.deinit();
                var ordinal = (try index.at(allocator, entry.kind, entry.ordinal)).?;
                defer ordinal.deinit();
                try support.expectNode(expected.node, by_id.value.node);
                try support.expectNode(expected.node, ordinal.value.node);
                try std.testing.expectEqual(expected.node.start_offset, by_id.value.node.start_offset);
                try std.testing.expectEqual(expected.node.end_offset, by_id.value.node.end_offset);
                for ([_]bool{ false, true }) |by_name| {
                    var numeric = (if (by_name) try index.byIdDecoded(allocator, entry.id, &decoded) else try index.atDecoded(allocator, entry.kind, entry.ordinal, &decoded)).?;
                    defer numeric.deinit();
                    try std.testing.expectEqualStrings(expected.id, numeric.value.id);
                    try std.testing.expectEqual(expected.node.start_offset, numeric.value.node.start_offset);
                    const count = if (selected) @min(1, expected.binaryArrays().len) else expected.binaryArrays().len;
                    try std.testing.expectEqual(count, decoded.len());
                    for (0..decoded.len()) |i| {
                        try std.testing.expectEqual(i, decoded.get(i).?.source_position);
                        try std.testing.expectEqualSlices(f64, if (i == 0) &.{ 1, 2 } else &.{ 3, 4 }, decoded.get(i).?.values.float64);
                    }
                }
            }
            try std.testing.expectEqual(null, try reader.nextRecord());
            try std.testing.expectEqual(null, try index.byId(allocator, "19"));
            try std.testing.expectEqual(null, try index.byIdDecoded(allocator, "absent", &decoded));
            try std.testing.expectEqual(@as(usize, 0), decoded.len());
            try std.testing.expectEqual(null, try index.at(allocator, .spectrum, 2));
        }
    };
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try support.rewriteDocument(std.testing.allocator, support.HISTORICAL, &sink.writer, true);
    const bytes = sink.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<offset idRef=\"S20\" nativeID=\"20\" spotID=\"A1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<offset idRef=\"tic\" nativeID=\"tic native\">") != null);
    const checksum_start = try support.checksumStart(bytes);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes[0..checksum_start], &digest, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), bytes[checksum_start..][0..40]);
    for ([_]bool{ false, true }) |selected| {
        try Check.run(std.testing.allocator, support.HISTORICAL, .rebuild, selected);
        try Check.run(std.testing.allocator, bytes, .open_embedded, selected);
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{ bytes, mzml.IndexedReader.Policy.open_embedded, true });
    const start = std.mem.indexOf(u8, bytes, "<spectrum id=\"S19\"").? + "<spectrum id=\"".len;
    bytes[start] = 'X';
    var damaged = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = bytes }, .{});
    defer damaged.deinit();
    try std.testing.expectError(error.InvalidIndex, damaged.byId(std.testing.allocator, "S19"));
    var later = (try damaged.byId(std.testing.allocator, "S20")).?;
    defer later.deinit();
    try std.testing.expectEqualStrings("20", later.value.node.attribute("nativeID").?);
}

test "[failure] - [mzML 1.0 indexed writing]: bounds historical IDs and cleans failed allocations" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var sink: std.Io.Writer.Discarding = .init(&.{});
            try support.rewriteDocument(allocator, support.HISTORICAL, &sink.writer, true);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
    var input = std.Io.Reader.fixed(support.HISTORICAL);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const first = (try reader.nextRecord()).?.node;
    // The index keeps each record's ID and its historical nativeID and spotID.
    var needed: usize = 0;
    for ([_][]const u8{ "id", "nativeID", "spotID" }) |name| needed += if (first.attribute(name)) |value| value.len else 0;
    for ([_]usize{ needed - 1, needed }) |id_bytes| {
        var sink: std.Io.Writer.Discarding = .init(&.{});
        var writer = try mzml.Writer.initIndexed(std.testing.allocator, &sink.writer, .{}, .{ .id_bytes = id_bytes });
        defer writer.deinit();
        try writer.writeHeader(header.*);
        try writer.beginListWithAttributes(.spectrum_list, 2, &.{});
        if (id_bytes == needed) {
            try writer.writeRecord(first);
            continue;
        }
        try std.testing.expectError(error.LimitExceeded, writer.writeRecord(first));
        try std.testing.expectEqual(.id_bytes, writer.diagnostic().?.detail.limit.name);
        try std.testing.expectEqual(.index, writer.diagnostic().?.stage);
        try std.testing.expectError(error.FailedState, writer.finish());
    }
}

fn checkDecodedLookupAllocations(allocator: std.mem.Allocator, selected: bool) !void {
    const Selection = struct {
        fn select(_: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
            return if (view.position == 1) .retain else .skip;
        }
    };
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = @embedFile("data/writer_indexed.mzML") }, .{
        .policy = .open_embedded,
        .reader = .{ .array_selector = if (selected) .{ .select = Selection.select } else null },
    });
    defer index.deinit();
    var output = mzml.DecodedArrays.init(allocator, .{});
    defer output.deinit();
    var record = (index.byIdDecoded(allocator, "scan=slof_zlib", &output) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), output.len());
        var recovered_output = mzml.DecodedArrays.init(std.testing.allocator, .{});
        defer recovered_output.deinit();
        var recovered = (try index.atDecoded(std.testing.allocator, .spectrum, 0, &recovered_output)).?;
        defer recovered.deinit();
        try std.testing.expectEqual(@as(usize, if (selected) 1 else 2), recovered_output.len());
        return err;
    }).?;
    defer record.deinit();
    try std.testing.expectEqual(@as(usize, if (selected) 1 else 2), output.len());
    try std.testing.expectEqual(@as(usize, if (selected) 1 else 0), output.get(0).?.source_position);
}

test "[integration] - [mzML indexed decoding]: preserves codecs, groups, metadata, and independent lifetimes" {
    const allocator = std.testing.allocator;
    const source = @embedFile("data/writer_indexed.mzML");
    for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
        var output = mzml.DecodedArrays.init(allocator, .{});
        defer output.deinit();
        var retained = blk: {
            var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{ .policy = policy });
            defer index.deinit();
            var first = (try index.byIdDecoded(allocator, "scan=none", &output)).?;
            errdefer first.deinit();
            for (0..index.entryCount()) |position| {
                const entry = index.entryAt(position).?;
                var decoded = (try index.atDecoded(allocator, entry.kind, entry.ordinal, &output)).?;
                defer decoded.deinit();
                var ordinary = (try index.at(allocator, entry.kind, entry.ordinal)).?;
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
    for ([_]bool{ false, true }) |selected| {
        try std.testing.checkAllAllocationFailures(allocator, checkDecodedLookupAllocations, .{selected});
    }
}

test "[integration] - [mzML indexed decoding]: selects arrays and records without dropping metadata" {
    const Selection = struct {
        skip_record: bool = false,
        calls: usize = 0,
        records: usize = 0,

        fn record(data: ?*anyopaque, _: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.records += 1;
            return if (self.skip_record) .skip else .retain;
        }

        fn array(data: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.calls += 1;
            return if (view.position == 1) .retain else .skip;
        }
    };
    const allocator = std.testing.allocator;
    const bytes = @embedFile("data/writer_indexed.mzML");
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const file = try directory.dir.createFile(std.testing.io, "selected.mzML", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
    for ([_]mzml.IndexedReader.Source{ .{ .bytes = bytes }, .{ .file = .{ .handle = file, .io = std.testing.io } } }) |source| {
        for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
            var selection: Selection = .{};
            var index = try mzml.IndexedReader.build(allocator, source, .{
                .policy = policy,
                .reader = .{ .payload = .skip, .array_selector = .{
                    .user_data = &selection,
                    .select = Selection.array,
                    .select_record = Selection.record,
                } },
            });
            defer index.deinit();
            try std.testing.expectEqual(@as(usize, 0), selection.calls);
            try std.testing.expectEqual(@as(usize, 0), selection.records);
            var input = std.Io.Reader.fixed(bytes);
            var reader = try mzml.StreamReader.init(allocator, &input, .{});
            defer reader.deinit();
            var output = mzml.DecodedArrays.init(allocator, .{});
            defer output.deinit();
            while (try reader.nextRecord()) |expected| {
                for ([_]bool{ false, true }) |by_id| {
                    var actual = (if (by_id)
                        try index.byIdDecoded(allocator, expected.id, &output)
                    else
                        try index.atDecoded(allocator, expected.node.kind, expected.index.?, &output)).?;
                    defer actual.deinit();
                    try expectDecodedNode(expected.node, actual.value.node);
                    try std.testing.expectEqual(@as(usize, 1), output.len());
                    const decoded = output.get(0).?;
                    try std.testing.expectEqual(@as(usize, 1), decoded.source_position);
                    const array = try mzml.model.BinaryArray.init(expected.binaryArrays()[decoded.source_position], expected.default_array_length, index.header().groups);
                    var values: [3]f64 = undefined;
                    var wire_buffer: [128]u8 = undefined;
                    var transformed: [128]u8 = undefined;
                    _ = try array.decode(f64, &values, .{ .wire = &wire_buffer, .transformed = &transformed });
                    try std.testing.expectEqualDeep(array.encoding, decoded.encoding);
                    try std.testing.expectEqualSlices(f64, &values, decoded.values.float64);
                }
            }
            try std.testing.expectEqual(@as(usize, 64), selection.calls);
            try std.testing.expectEqual(@as(usize, 32), selection.records);
            selection.skip_record = true;
            var empty = (try index.byIdDecoded(allocator, "scan=none", &output)).?;
            defer empty.deinit();
            try std.testing.expectEqual(@as(usize, 0), output.len());
            try std.testing.expectEqual(@as(usize, 2), empty.value.binaryArrays().len);
            try std.testing.expectEqual(@as(usize, 64), selection.calls);
            try std.testing.expectEqual(@as(usize, 33), selection.records);
        }
    }
}

test "[integration] - [mzML index]: keeps lookup ordinals separate from source indexes" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |missing| {
        const bytes = try allocator.dupe(u8, @embedFile("data/writer_indexed.mzML"));
        defer allocator.free(bytes);
        var offset: usize = 0;
        while (std.mem.indexOfPos(u8, bytes, offset, "index=\"")) |start| {
            offset = start + "index=\"".len;
            if (missing) @memcpy(bytes[start..][0..5], "other") else bytes[offset] = '9';
        }
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        const file = try directory.dir.createFile(std.testing.io, "indexes.mzML", .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, bytes);

        for ([_]mzml.IndexedReader.Source{ .{ .bytes = bytes }, .{ .file = .{ .handle = file, .io = std.testing.io } } }) |source| {
            for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
                var index = try mzml.IndexedReader.build(allocator, source, .{ .policy = policy });
                defer index.deinit();
                var input = std.Io.Reader.fixed(bytes);
                var reader = try mzml.StreamReader.init(allocator, &input, .{});
                defer reader.deinit();
                const header = try reader.readHeader();
                var output = mzml.DecodedArrays.init(allocator, .{});
                defer output.deinit();
                var counts = [_]usize{ 0, 0 };
                while (try reader.nextRecord()) |record| {
                    const k: usize = if (record.node.kind == .spectrum) 0 else 1;
                    const ordinal = counts[k];
                    const entry = index.entryAt(counts[0] + counts[1]).?;
                    try std.testing.expectEqual(ordinal, entry.ordinal);
                    try std.testing.expectEqualStrings(record.id, entry.id);
                    counts[k] += 1;
                    try std.testing.expectEqual(if (missing) @as(?usize, null) else 9, record.index);
                    try std.testing.expectEqualDeep(if (missing) @as(?[]const u8, null) else "9", record.node.attribute("index"));
                    var positioned = (try index.at(allocator, record.node.kind, ordinal)).?;
                    defer positioned.deinit();
                    try std.testing.expectEqualDeep(record, positioned.value);
                    var named = (try index.byId(allocator, record.id)).?;
                    defer named.deinit();
                    try std.testing.expectEqualDeep(record, named.value);
                    var decoded = (if (ordinal % 2 == 0)
                        try index.atDecoded(allocator, record.node.kind, ordinal, &output)
                    else
                        try index.byIdDecoded(allocator, record.id, &output)).?;
                    defer decoded.deinit();
                    try expectDecodedRecord(record, header.groups, decoded.value, &output);
                }
                try std.testing.expectEqualDeep(counts, support.kindCounts(&index));
                try std.testing.expectEqual(null, try index.at(allocator, .spectrum, 9));
                try std.testing.expectEqual(null, try index.at(allocator, .chromatogram, 9));
            }
        }
    }
}

test "[integration] - [mzML index]: traverses entries without trusting declared counts" {
    const allocator = std.testing.allocator;
    const empty_spectra = support.HEADER ++ "<spectrumList count='0' defaultDataProcessingRef='dp'></spectrumList>" ++
        "<chromatogramList count='1' defaultDataProcessingRef='dp'><chromatogram id='tic' index='0' defaultArrayLength='1'>" ++
        support.ARRAYS ++ "</chromatogram></chromatogramList></run></mzML>";
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    for ([_][]const u8{ empty_spectra, support.DOCUMENT }, 0..) |plain, spectra| {
        for ([_]?u8{ '0', '9', null }) |count| {
            var sink: std.Io.Writer.Allocating = .init(allocator);
            defer sink.deinit();
            try support.rewriteDocument(allocator, plain, &sink.writer, true);
            const bytes = sink.written();
            var offset: usize = 0;
            while (std.mem.indexOfPos(u8, bytes, offset, "count=\"")) |start| {
                offset = start + "count=\"".len;
                if (count) |value| bytes[offset] = value else @memcpy(bytes[start..][0..5], "total");
            }
            const file = try directory.dir.createFile(std.testing.io, "counts.mzML", .{ .read = true });
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, bytes);
            for ([_]mzml.IndexedReader.Source{ .{ .bytes = bytes }, .{ .file = .{ .handle = file, .io = std.testing.io } } }) |source| {
                for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
                    var index = try mzml.IndexedReader.build(allocator, source, .{ .policy = policy });
                    defer index.deinit();
                    try std.testing.expectEqualDeep([_]usize{ spectra, 1 }, support.kindCounts(&index));
                    try std.testing.expectEqual(if (count) |value| @as(?usize, value - '0') else null, index.header().spectrum_list.?.declared_count);
                    try std.testing.expectEqual(if (count) |value| @as(?usize, value - '0') else null, index.header().chromatogram_list.?.declared_count);
                    var input = std.Io.Reader.fixed(bytes);
                    var reader = try mzml.StreamReader.init(allocator, &input, .{ .retain_index = true });
                    defer reader.deinit();
                    var output = mzml.DecodedArrays.init(allocator, .{});
                    defer output.deinit();
                    var records: usize = 0;
                    while (try reader.nextRecord()) |record| {
                        var actual = (try index.byIdDecoded(allocator, record.id, &output)).?;
                        defer actual.deinit();
                        try expectDecodedRecord(record, index.header().groups, actual.value, &output);
                        records += 1;
                    }
                    try std.testing.expectEqual(spectra + 1, records);
                    try std.testing.expectEqualDeep(if (count) |value| @as(?[]const u8, &.{value}) else null, reader.indexTrailer().?[0].attribute("count"));
                }
            }
        }
    }
}

test "[integration] - [mzML index]: decodes explicit array lengths without a record default" {
    const allocator = std.testing.allocator;
    const plain = try std.mem.replaceOwned(u8, allocator, support.DOCUMENT, "defaultArrayLength='1'", "");
    defer allocator.free(plain);
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    try support.rewriteDocument(allocator, plain, &sink.writer, true);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const file = try directory.dir.createFile(std.testing.io, "lengths.mzML", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, sink.written());
    const Selection = struct {
        fn select(_: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
            return if (view.position == 1) .retain else .skip;
        }
    };
    for ([_]mzml.IndexedReader.Source{ .{ .bytes = sink.written() }, .{ .file = .{ .handle = file, .io = std.testing.io } } }) |source| {
        for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
            for ([_]bool{ false, true }) |selected| {
                var index = try mzml.IndexedReader.build(allocator, source, .{
                    .policy = policy,
                    .reader = .{ .array_selector = if (selected) .{ .select = Selection.select } else null },
                });
                defer index.deinit();
                var output = mzml.DecodedArrays.init(allocator, .{});
                defer output.deinit();
                for (0..index.entryCount()) |position| {
                    const entry = index.entryAt(position).?;
                    for ([_]bool{ false, true }) |by_id| {
                        const result = if (by_id) index.byIdDecoded(allocator, entry.id, &output) else index.atDecoded(allocator, entry.kind, entry.ordinal, &output);
                        if (selected) {
                            var record = (try result).?;
                            defer record.deinit();
                            try std.testing.expectEqual(null, record.value.default_array_length);
                            try std.testing.expectEqual(@as(usize, 1), output.len());
                            try std.testing.expectEqual(@as(usize, 1), output.get(0).?.source_position);
                            try std.testing.expectEqualSlices(f64, &.{1}, output.get(0).?.values.float64);
                        } else {
                            try std.testing.expectError(error.MissingAttribute, result);
                            try std.testing.expectEqual(@as(usize, 0), output.len());
                        }
                    }
                    var record = (try index.at(allocator, entry.kind, entry.ordinal)).?;
                    defer record.deinit();
                    try std.testing.expectEqual(null, record.value.default_array_length);
                    try std.testing.expectEqual(null, record.value.node.attribute("defaultArrayLength"));
                }
            }
        }
    }
}

test "[integration] - [mzML index]: reads trailer fields used for lookup" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, @embedFile("data/writer_indexed.mzML"));
    defer allocator.free(bytes);
    const count = std.mem.indexOf(u8, bytes, "<indexList count=\"2\">").? + "<indexList ".len;
    @memset(bytes[count..][0.."count=\"2\"".len], ' ');
    {
        var index = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{});
        defer index.deinit();
        try std.testing.expectEqual(@as(usize, 16), index.entryCount());
        var record = (try index.at(allocator, .spectrum, 0)).?;
        defer record.deinit();
        try std.testing.expectEqualStrings("scan=none", record.value.id);
    }
    for ([_][]const u8{ "name=\"spectrum\"", "idRef=\"scan=none\"" }) |attribute| {
        const offset = std.mem.indexOf(u8, bytes[count..], attribute).? + count;
        @memset(bytes[offset..][0..attribute.len], ' ');
        var report: ?mzml.Diagnostic = null;
        try std.testing.expectError(error.MissingAttribute, mzml.IndexedReader.buildWithDiagnostic(allocator, .{ .bytes = bytes }, .{}, &report));
        try std.testing.expectEqual(error.MissingAttribute, report.?.code);
        try std.testing.expectEqual(.open_index, report.?.operation);
        try std.testing.expectEqual(if (std.mem.startsWith(u8, attribute, "name")) mzml.Diagnostic.Attribute.name else .id_ref, report.?.detail.attribute);
        try std.testing.expect(report.?.location.?.input_event < offset);
        try std.testing.expect(report.?.location.?.input_event >= count);
        @memcpy(bytes[offset..][0..attribute.len], attribute);
    }
}

test "[failure] - [mzML indexed decoding]: clears results and recovers after decode and target failures" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, @embedFile("data/writer_indexed.mzML"));
    defer allocator.free(source);
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{ .policy = .open_embedded });
    defer index.deinit();
    var output = mzml.DecodedArrays.init(allocator, .{});
    defer output.deinit();
    const payload = std.mem.indexOf(u8, source, "<binary>").? + "<binary>".len;
    const end = std.mem.indexOf(u8, source, "</spectrum>").? + "</spectrum".len - 1;
    const id = std.mem.indexOf(u8, source, "id=\"scan=none\"").? + "id=\"".len;
    const saved = source[payload];
    for (0..3) |failure| {
        var good = (try index.atDecoded(allocator, .spectrum, 1, &output)).?;
        defer good.deinit();
        source[payload] = '!';
        const closing = source[end];
        if (failure == 1) source[end] = 'x';
        if (failure == 2) source[id] = 'x';
        try std.testing.expectError(switch (failure) {
            0 => error.InvalidCharacter,
            1 => error.InvalidCharacter,
            else => error.InvalidIndex,
        }, index.atDecoded(allocator, .spectrum, 0, &output));
        try std.testing.expectEqual(@as(usize, 0), output.len());
        const report = index.diagnostic().?;
        try std.testing.expectEqual(.lookup_record, report.operation);
        try std.testing.expectEqual(@as(usize, 0), report.record.?.ordinal);
        if (failure != 2) {
            try std.testing.expectEqual(.invalid_base64, report.id);
            try std.testing.expectEqual(.base64, report.stage);
            try std.testing.expectEqual(@as(u64, payload), report.location.?.input_event);
            try std.testing.expectEqual(@as(usize, 0), report.array_position.?);
        } else try std.testing.expectEqual(.invalid_index, report.id);
        _ = index.header();
        try std.testing.expectEqualDeep(report, index.diagnostic().?);
        try std.testing.expectEqual(null, try index.byId(allocator, "absent"));
        try std.testing.expectEqual(null, index.diagnostic());
        source[payload] = saved;
        source[end] = closing;
        source[id] = 's';
    }
    var recovered = (try index.byIdDecoded(allocator, "scan=none", &output)).?;
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 2), output.len());
    try std.testing.expectEqual(null, index.diagnostic());
    try std.testing.expectEqual(null, try index.byIdDecoded(allocator, "absent", &output));
    try std.testing.expectEqual(@as(usize, 0), output.len());
    try std.testing.expectEqual(null, try index.atDecoded(allocator, .spectrum, 8, &output));
    // A wrong kind is the caller's argument, not a damaged index.
    try std.testing.expectError(error.InvalidOptions, index.atDecoded(allocator, .run, 0, &output));
    try std.testing.expectEqual(error.InvalidOptions, index.diagnostic().?.code);
    try std.testing.expectEqual(mzml.Diagnostic.Id.invalid_options, index.diagnostic().?.id);
    var limited = mzml.DecodedArrays.init(allocator, .{ .array_bytes = 1 });
    defer limited.deinit();
    try std.testing.expectError(error.LimitExceeded, index.atDecoded(allocator, .spectrum, 0, &limited));
    try std.testing.expectEqual(@as(usize, 0), limited.len());
    try std.testing.expectEqual(.array_bytes, index.diagnostic().?.detail.limit.name);
    try std.testing.expectEqual(@as(usize, 0), index.diagnostic().?.array_position.?);
}

test "[failure] - [mzML indexed lookup]: checks the source once before reading and once before returning" {
    const Source = struct {
        calls: usize = 0,
        reads: usize = 0,
        fail_at: ?usize = null,
        stat_error: bool = false,

        fn stat(data: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.calls += 1;
            var result = try file.stat(std.testing.io);
            if (self.fail_at == self.calls) {
                if (self.stat_error) return error.AccessDenied;
                result.size += 1;
            }
            return result;
        }

        fn read(data: ?*anyopaque, file: std.Io.File, slices: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.reads += 1;
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
    var output = mzml.DecodedArrays.init(allocator, .{});
    defer output.deinit();
    for ([_]bool{ false, true }) |by_id| {
        source = .{};
        var retained = (if (by_id) try index.byId(allocator, "scan=none") else try index.at(allocator, .spectrum, 0)).?;
        defer retained.deinit();
        try std.testing.expectEqual(@as(usize, 2), source.calls);
        try std.testing.expect(source.reads > 0);
        for ([_]bool{ false, true }) |stat_error| {
            for (1..3) |fail_at| {
                source = .{};
                var good = (if (by_id) try index.byIdDecoded(allocator, "scan=none", &output) else try index.atDecoded(allocator, .spectrum, 0, &output)).?;
                defer good.deinit();
                try std.testing.expectEqual(@as(usize, 2), source.calls);
                try std.testing.expectEqual(@as(usize, 2), output.len());
                try std.testing.expectEqual(null, index.diagnostic());
                source = .{ .fail_at = fail_at, .stat_error = stat_error };
                const result = if (by_id) index.byIdDecoded(allocator, "scan=zlib", &output) else index.atDecoded(allocator, .spectrum, 1, &output);
                try std.testing.expectError(if (stat_error) error.AccessDenied else error.StaleSource, result);
                const report = index.diagnostic().?;
                try std.testing.expectEqual(if (stat_error) error.AccessDenied else error.StaleSource, report.code);
                try std.testing.expectEqual(if (stat_error) mzml.Diagnostic.Id.io_failed else .source_changed, report.id);
                try std.testing.expectEqual(null, report.location);
                try std.testing.expectEqual(@as(usize, 0), output.len());
                try std.testing.expectEqual(fail_at, source.calls);
                if (fail_at == 1) {
                    try std.testing.expectEqual(@as(usize, 0), source.reads);
                    try std.testing.expectEqual(null, report.record);
                } else {
                    try std.testing.expect(source.reads > 0);
                    try std.testing.expectEqual(@as(usize, 1), report.record.?.ordinal);
                }
            }
        }
    }
    source = .{};
    var recovered = (try index.atDecoded(allocator, .spectrum, 1, &output)).?;
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 2), source.calls);
    try std.testing.expectEqual(null, index.diagnostic());
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
    var output = mzml.DecodedArrays.init(allocator, .{});
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

        fn select(user_data: ?*anyopaque, view: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            self.wrong_position = self.wrong_position or view.position != self.calls % 2;
            self.calls += 1;
            return if (view.position == 0) .retain else .skip;
        }
    };
    const allocator = std.testing.allocator;
    const source = @embedFile("data/writer_indexed.mzML");
    for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
        var selection: Selection = .{};
        var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{
            .policy = policy,
            .reader = .{ .array_selector = .{ .user_data = &selection, .select = Selection.select } },
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
    const malformed = try allocator.dupe(u8, source);
    defer allocator.free(malformed);
    const end = std.mem.indexOf(u8, malformed, "</spectrum>").?;
    malformed[end + "</spectrum>".len - 2] = 'x';
    for ([_]bool{ false, true }) |numeric| {
        var selection: Selection = .{};
        var index = try mzml.IndexedReader.build(allocator, .{ .bytes = malformed }, .{
            .policy = .open_embedded,
            .reader = .{ .array_selector = .{ .user_data = &selection, .select = Selection.select } },
        });
        defer index.deinit();
        var output = mzml.DecodedArrays.init(allocator, .{});
        defer output.deinit();
        try std.testing.expectError(error.InvalidXml, if (numeric) index.atDecoded(allocator, .spectrum, 0, &output) else index.at(allocator, .spectrum, 0));
        try std.testing.expectEqual(@as(usize, 0), output.len());
        try std.testing.expectEqual(@as(usize, 2), selection.calls);
        var next = (if (numeric) try index.atDecoded(allocator, .spectrum, 1, &output) else try index.at(allocator, .spectrum, 1)).?;
        defer next.deinit();
        try std.testing.expectEqual(@as(usize, 4), selection.calls);
        try std.testing.expect(!selection.wrong_position);
        try std.testing.expectEqual(null, next.value.binaryArrays()[1].child(.binary).?.text);
        if (numeric) {
            try std.testing.expectEqual(@as(usize, 1), output.len());
            try std.testing.expectEqual(@as(usize, 0), output.get(0).?.source_position);
            try std.testing.expectEqual(@as(usize, 3), output.get(0).?.values.float64.len);
        }
    }
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
            support.utf16(&bytes, prefixed, endian);
            break :blk bytes[0..];
        } else prefixed;
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = encoded }, .{ .policy = .rebuild });
        defer index.deinit();
        for ([_]usize{ 0, 1, 0, 2, 2, 1, 1 }) |position| {
            var input = std.Io.Reader.fixed(encoded);
            var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
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

test "[integration] - [mzML index]: reads Latin-1 offsets and rewrites metadata as UTF-8" {
    const allocator = std.testing.allocator;
    var source: std.Io.Writer.Allocating = .init(allocator);
    defer source.deinit();
    try source.writer.writeAll("<?xml version='1.0' encoding='ISO-8859-1'?><indexedmzML xmlns='http://psi.hupo.org/ms/mzml'>" ++
        support.HEADER ++ "<spectrumList count='2' defaultDataProcessingRef='dp'>");
    var offsets: [2]usize = undefined;
    for ([_]u8{ 0xe9, 0xff }, 0..) |byte, i| {
        offsets[i] = source.written().len;
        try source.writer.print("<spectrum id='scan={c}' index='{d}' defaultArrayLength='1'><userParam name='note' value='\xb5'/>" ++
            support.ARRAYS ++ "</spectrum>", .{ byte, i });
    }
    try source.writer.writeAll("</spectrumList></run></mzML>");
    const index_offset = source.written().len;
    try source.writer.print("<indexList count='1'><index name='spectrum'>" ++
        "<offset idRef='scan=\xe9'>{d}</offset><offset idRef='scan=\xff'>{d}</offset>" ++
        "</index></indexList><indexListOffset>{d}</indexListOffset><fileChecksum/></indexedmzML>", .{ offsets[0], offsets[1], index_offset });
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const file = try directory.dir.createFile(std.testing.io, "latin1.mzML", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, source.written());
    for ([_]mzml.IndexedReader.Source{ .{ .bytes = source.written() }, .{ .file = .{ .handle = file, .io = std.testing.io } } }) |input| {
        for (std.enums.values(mzml.IndexedReader.Policy)) |policy| {
            var index = try mzml.IndexedReader.build(allocator, input, .{ .policy = policy });
            defer index.deinit();
            var output = mzml.DecodedArrays.init(allocator, .{});
            defer output.deinit();
            for ([_]usize{ 0, 1, 0, 1 }) |position| {
                const id = ([_][]const u8{ "scan=\xc3\xa9", "scan=\xc3\xbf" })[position];
                var retained = (try index.byId(allocator, id)).?;
                defer retained.deinit();
                try std.testing.expectEqual(@as(u64, offsets[position]), retained.value.node.start_offset);
                try std.testing.expectEqualStrings("\xc2\xb5", retained.value.node.params[0].user.value.?);
                var decoded = (try index.byIdDecoded(allocator, id, &output)).?;
                defer decoded.deinit();
                try expectDecodedRecord(retained.value, index.header().groups, decoded.value, &output);
            }
        }
    }
    for ([_]bool{ false, true }) |indexed| {
        var rewritten: std.Io.Writer.Allocating = .init(allocator);
        defer rewritten.deinit();
        try support.rewriteDocument(allocator, source.written(), &rewritten.writer, indexed);
        try std.testing.expect(std.mem.startsWith(u8, rewritten.written(), "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
        var index = try mzml.IndexedReader.build(allocator, .{ .bytes = rewritten.written() }, .{ .policy = if (indexed) .open_embedded else .rebuild });
        defer index.deinit();
        var input = std.Io.Reader.fixed(source.written());
        var reader = try mzml.StreamReader.init(allocator, &input, .{});
        defer reader.deinit();
        try support.expectNode((try reader.readHeader()).document, index.header().document);
        while (try reader.nextRecord()) |expected| {
            var actual = (try index.byId(allocator, expected.id)).?;
            defer actual.deinit();
            try support.expectNode(expected.node, actual.value.node);
        }
    }
}

fn checkLookupAllocator(record_allocator: std.mem.Allocator) !void {
    var retained = blk: {
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = @embedFile("data/writer_indexed.mzML") }, .{ .policy = .open_embedded });
        defer index.deinit();
        var first = (try index.at(std.testing.allocator, .spectrum, 0)).?;
        errdefer first.deinit();
        var warm = (try index.at(std.testing.allocator, .chromatogram, 0)).?;
        warm.deinit();
        var last = (index.at(record_allocator, .chromatogram, 7) catch |err| {
            var recovered = (try index.at(std.testing.allocator, .chromatogram, 1)).?;
            defer recovered.deinit();
            try std.testing.expectEqualStrings("chromatogram=zlib", recovered.value.id);
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
    var wire_buffer: [128]u8 = undefined;
    _ = try mzml.model.decodeArray(f64, &values, retained.value.binaryArrays()[0], 3, &.{}, .{ .wire = &wire_buffer, .transformed = &.{} });
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, &values);
}

test "[integration] - [mzML indexed lookup]: retains records and recovers after caller allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkLookupAllocator, .{});
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
            if (endian) |order| support.utf16(encoded, source.written(), order) else @memcpy(encoded, source.written());
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
                    const span: usize = @intCast(index.entryAt(0).?.end - index.entryAt(0).?.start);
                    index.options.record_span_bytes = span - 1;
                    try std.testing.expectError(error.LimitExceeded, index.at(allocator, .spectrum, 0));
                    try std.testing.expectEqual(.record_span_bytes, index.diagnostic().?.detail.limit.name);
                    index.options.record_span_bytes = span;
                    var record = (try index.byId(allocator, expected.id)).?;
                    defer record.deinit();
                    try std.testing.expectEqualDeep(expected, record.value);
                    var output = mzml.DecodedArrays.init(allocator, .{});
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
                        _ = try (try arrays.next()).?.decode(f64, &value, .{ .wire = &.{}, .transformed = &.{} });
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
            try std.testing.expectEqual(@as(usize, 59), index.entryCount());
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

fn checkOpenEmbedded(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .policy = .open_embedded });
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 16), index.entryCount());
    try std.testing.expectEqual(@as(usize, 0), index.header().spectrum_list.?.observed_count);
    try std.testing.expectEqual(@as(usize, 0), index.header().chromatogram_list.?.observed_count);
    for (0..index.entryCount()) |position| {
        const entry = index.entryAt(position).?;
        var record = (try index.at(allocator, entry.kind, entry.ordinal)).?;
        defer record.deinit();
        try std.testing.expectEqualStrings(entry.id, record.value.id);
        try std.testing.expectEqual(entry.start, record.value.node.start_offset);
        try std.testing.expect(record.value.node.end_offset <= entry.end);
        for (record.value.binaryArrays()) |array| {
            var values: [3]f64 = undefined;
            var wire_buffer: [128]u8 = undefined;
            var transformed: [128]u8 = undefined;
            _ = try mzml.model.decodeArray(f64, &values, array, 3, index.header().groups, .{ .wire = &wire_buffer, .transformed = &transformed });
            for (values, [_]f64{ 1, 2, 3 }) |value, expected| try std.testing.expectApproxEqAbs(expected, value, 0.001);
        }
    }
}

test "[integration] - [mzML index]: opens embedded targets without checking unread records or checksums" {
    var buffer: [32768]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    try support.constructFixture(std.testing.allocator, &sink, true, std.meta.tags(mzml.arrays.Pipeline));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkOpenEmbedded, .{sink.buffered()});
    const checksum_start = try support.checksumStart(sink.buffered());
    const marker = "<offset idRef=\"scan=none\">";
    const target_start = std.mem.indexOf(u8, sink.buffered(), marker).? + marker.len;
    const id_start = target_start - "none\">".len;
    @memcpy(buffer[id_start..][0..4], "zlib");
    try std.testing.expectError(error.DuplicateId, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .open_embedded }));
    @memcpy(buffer[id_start..][0..4], "none");
    const saved = buffer[checksum_start];
    buffer[checksum_start] = 'x';
    try checkIndexed(std.testing.allocator, sink.buffered());
    buffer[checksum_start] = saved;
    for ([_][]const u8{ "", "unchecked", "0" ** 41 }) |text| {
        const bytes = try std.mem.replaceOwned(u8, std.testing.allocator, sink.buffered(), sink.buffered()[checksum_start..][0..40], text);
        defer std.testing.allocator.free(bytes);
        try checkIndexed(std.testing.allocator, bytes);
    }
}

// An indexedmzML document in UTF-8 or UTF-16 whose targets follow indentation and optional
// padding, with a namespace declared on the chromatogram list and a correct checksum.
const IndentedDocument = struct { bytes: []u8, spectrum_start: usize, chromatogram_start: usize, index_start: usize };

fn indentedDocument(allocator: std.mem.Allocator, endian: ?std.builtin.Endian, padded: bool, spectra: usize) !IndentedDocument {
    const spaces: [65537]u8 = @splat(' ');
    const padding: usize = if (padded) spaces.len else 0;
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
    errdefer allocator.free(bytes);
    if (endian) |order| support.utf16(bytes, source.written(), order) else @memcpy(bytes, source.written());
    const checksum_start = bom + width * ((std.mem.indexOf(u8, source.written(), "<p:fileChecksum>") orelse return error.TestUnexpectedResult) + "<p:fileChecksum>".len);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes[0..checksum_start], &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (endian) |order| {
        for (hex, 0..) |byte, i| std.mem.writeInt(u16, bytes[checksum_start + 2 * i ..][0..2], byte, order);
    } else @memcpy(bytes[checksum_start..][0..hex.len], &hex);
    return .{ .bytes = bytes, .spectrum_start = spectrum_start, .chromatogram_start = chromatogram_start, .index_start = index_start };
}

test "[integration] - [mzML index]: opens indented encoded targets and restores list namespaces" {
    const allocator = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    for ([_]?std.builtin.Endian{ null, .little, .big }) |endian| {
        for ([_]bool{ false, true }) |padded| {
            for (0..2) |spectra| {
                const document = try indentedDocument(allocator, endian, padded, spectra);
                defer allocator.free(document.bytes);
                const bytes = document.bytes;
                const spectrum_start = document.spectrum_start;
                const chromatogram_start = document.chromatogram_start;
                const index_start = document.index_start;
                const file = try directory.dir.createFile(std.testing.io, "opening.mzML", .{ .read = true });
                defer file.close(std.testing.io);
                try file.writeStreamingAll(std.testing.io, bytes);
                for ([_]mzml.IndexedReader.Source{ .{ .bytes = bytes }, .{ .file = .{ .handle = file, .io = std.testing.io } } }) |indexed_source| {
                    var opened = try mzml.IndexedReader.build(allocator, indexed_source, .{});
                    defer opened.deinit();
                    var rebuilt = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .policy = .rebuild });
                    defer rebuilt.deinit();
                    try std.testing.expectEqual(spectra + 1, opened.entryCount());
                    for (0..opened.entryCount()) |position| {
                        const entry = opened.entryAt(position).?;
                        var actual = (try opened.at(allocator, entry.kind, 0)).?;
                        defer actual.deinit();
                        var expected = (try rebuilt.at(allocator, entry.kind, 0)).?;
                        defer expected.deinit();
                        try support.expectNode(expected.value.node, actual.value.node);
                        try std.testing.expectEqual(expected.value.node.start_offset, actual.value.node.start_offset);
                        try std.testing.expectEqual(expected.value.node.end_offset, actual.value.node.end_offset);
                        var output = mzml.DecodedArrays.init(allocator, .{});
                        defer output.deinit();
                        var decoded = (try opened.byIdDecoded(allocator, entry.id, &output)).?;
                        defer decoded.deinit();
                        try expectDecodedRecord(actual.value, opened.header().groups, decoded.value, &output);
                    }
                    if (spectra != 0) try expectBuildLimit(indexed_source, .{
                        .policy = .open_embedded,
                        .record_span_bytes = chromatogram_start - spectrum_start - 1,
                    }, .record_span_bytes);
                    try expectBuildLimit(indexed_source, .{
                        .policy = .open_embedded,
                        .index_bytes = bytes.len - index_start - 1,
                    }, .index_bytes);
                }
            }
        }
    }
}

test "[failure] - [mzML index]: opening reports read failures and truncation at targets, and lookups read only their spans" {
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
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    for ([_]?std.builtin.Endian{ null, .little, .big }) |endian| {
        const width: usize = if (endian != null) 2 else 1;
        const document = try indentedDocument(allocator, endian, true, 1);
        defer allocator.free(document.bytes);
        const bytes = document.bytes;
        const spectrum_start = document.spectrum_start;
        const index_start = document.index_start;
        const file = try directory.dir.createFile(std.testing.io, "opening.mzML", .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, bytes);
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
                    var report: ?mzml.Diagnostic = null;
                    try std.testing.expectError(expected, mzml.IndexedReader.buildWithDiagnostic(allocator, .{ .file = .{ .handle = file, .io = io } }, .{ .policy = .open_embedded }, &report));
                    try std.testing.expectEqual(expected, report.?.code);
                    try std.testing.expectEqual(.open_index, report.?.operation);
                    if (malformed) {
                        try std.testing.expect(report.?.location.?.input_event >= start);
                        try std.testing.expect(report.?.location.?.input_event < start + 113);
                    } else try std.testing.expectEqual(null, report.?.location);
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

test "[integration] - [mzML index]: rebuilds without interpreting metadata numbers it does not use" {
    const allocator = std.testing.allocator;
    const source = @embedFile("data/writer_indexed.mzML");
    const malformed = try std.mem.replaceOwned(u8, allocator, source, "order=\"0\"", "order=\"bad\"");
    defer allocator.free(malformed);
    var rebuilt = try mzml.IndexedReader.build(allocator, .{ .bytes = malformed }, .{ .policy = .rebuild });
    defer rebuilt.deinit();
    const method = rebuilt.header().document.child(.data_processing_list).?.children[0].children[0];
    try std.testing.expectEqualStrings("bad", method.attribute("order").?);
}

test "[integration] - [mzML index]: verifies emitted targets, checksum, and independent lookups" {
    var buffer: [32768]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    try support.constructFixture(std.testing.allocator, &sink, true, std.meta.tags(mzml.arrays.Pipeline));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkIndexed, .{sink.buffered()});
    const checksum_start = try support.checksumStart(sink.buffered());
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(sink.buffered()[0..checksum_start], &digest, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), sink.buffered()[checksum_start..][0..40]);
    try support.expectWritten(std.mem.trimEnd(u8, @embedFile("data/writer_indexed.mzML"), "\n"), sink.buffered());
    const marker = "<offset idRef=\"scan=none\">";
    const target_start = std.mem.indexOf(u8, sink.buffered(), marker).? + marker.len;
    const target_end = std.mem.indexOfScalarPos(u8, sink.buffered(), target_start, '<').?;
    var target: [32]u8 = undefined;
    const target_length = target_end - target_start;
    @memcpy(target[0..target_length], buffer[target_start..target_end]);
    @memset(buffer[target_start..target_end], '0');
    try std.testing.expectError(error.InvalidIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{}));
    @memcpy(buffer[target_start..target_end], target[0..target_length]);
    var rebuilt = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .rebuild });
    defer rebuilt.deinit();
    try std.testing.expectEqual(@as(usize, 16), rebuilt.entryCount());
}

test "[integration] - [mzML index]: discarded metadata does not consume retained record bytes" {
    const allocator = std.testing.allocator;
    const large: [1024]u8 = @splat('x');
    for (0..3) |case| {
        const children = switch (case) {
            0 => try std.fmt.allocPrint(allocator, "<scanList count='1'><scan><userParam name='note' value='{s}'/></scan></scanList>", .{large}),
            1 => try std.fmt.allocPrint(allocator, "<scanList count='1'><scan instrumentConfigurationRef='{s}'/></scanList>", .{large}),
            else => try allocator.dupe(u8, "<scanList count='16'>" ++ "<scan/>" ** 16 ++ "</scanList>"),
        };
        defer allocator.free(children);
        const bytes = try std.fmt.allocPrint(allocator, support.HEADER ++ "<spectrumList count='2' defaultDataProcessingRef='dp'>" ++
            "<spectrum id='large' index='0' defaultArrayLength='0'>{s}</spectrum>" ++
            "<spectrum id='small' index='1' defaultArrayLength='0'/></spectrumList></run></mzML>", .{children});
        defer allocator.free(bytes);
        var index = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{
            .policy = .rebuild,
            .reader = .{ .limits = .{ .record_bytes = 384 } },
        });
        defer index.deinit();
        try std.testing.expectEqual(@as(usize, 2), index.entryCount());
        try std.testing.expectEqualStrings("large", index.entryAt(0).?.id);
        try std.testing.expectEqualStrings("small", index.entryAt(1).?.id);
        try std.testing.expectError(error.LimitExceeded, index.at(allocator, .spectrum, 0));
        try std.testing.expectEqual(.record_bytes, index.diagnostic().?.detail.limit.name);
        var small = (try index.at(allocator, .spectrum, 1)).?;
        defer small.deinit();
        try std.testing.expectEqualStrings("small", small.value.id);
        try std.testing.expectEqual(@as(usize, 1), small.value.index);
        try std.testing.expectEqual(@as(usize, 0), small.value.node.children.len);
        try std.testing.expectError(error.LimitExceeded, support.readAll(allocator, bytes, .{ .limits = .{ .record_bytes = 384 } }));
        try expectBuildLimit(.{ .bytes = bytes }, .{ .policy = .rebuild, .reader = .{ .limits = .{ .record_bytes = 0 } } }, .record_bytes);
        if (case != 2) try expectBuildLimit(.{ .bytes = bytes }, .{ .policy = .rebuild, .reader = .{ .limits = .{ .attribute_bytes = 512 } } }, .attribute_bytes);
        if (case == 2) {
            try expectBuildLimit(.{ .bytes = bytes }, .{ .policy = .rebuild, .reader = .{ .limits = .{ .nodes = 17 } } }, .nodes);
            try expectBuildLimit(.{ .bytes = bytes }, .{ .policy = .rebuild, .reader = .{ .limits = .{ .list_entries = 15 } } }, .list_entries);
        }
    }
}

test "[integration] - [mzML index]: skips extra XML while preserving record spans and retained lookups" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ support.EXTENSIONS, support.STREAM_EXTENSIONS, support.KNOWN_CHILDREN, support.REPEATED_CONTAINERS }) |source| {
        var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{ .policy = .rebuild });
        defer index.deinit();
        var input = std.Io.Reader.fixed(source);
        var reader = try mzml.StreamReader.init(allocator, &input, .{});
        defer reader.deinit();
        var count: usize = 0;
        while (try reader.nextItem()) |item| {
            if (item != .record) continue;
            const record = item.record;
            const entry = index.entryAt(count).?;
            count += 1;
            try std.testing.expectEqual(record.node.start_offset, entry.start);
            try std.testing.expectEqual(record.node.end_offset, entry.end);
            var found = (try index.byId(allocator, record.id)).?;
            defer found.deinit();
            try std.testing.expectEqualDeep(record, found.value);
        }
        try std.testing.expectEqual(index.entryCount(), count);
        try std.testing.expectEqual(null, index.entryAt(count));
        try std.testing.expectEqualDeep((try reader.readHeader()).*, index.header().*);
    }
}

test "[property] - [mzML index]: preserves parser checks and limits during rebuilding" {
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
            try std.testing.expectEqual(@as(usize, 2), index.entryCount());
        }
    };
    for ([_]usize{ 0, 1, 2, 3, 4, 8, 16, 32, 64, 256, 1024, 4096, 8192 }) |limit| {
        for ([_]mzml.StreamReader.Limits{
            .{ .nodes = limit }, .{ .list_entries = limit },
        }) |limits| try Parse.compare(support.DOCUMENT, limits);
    }
    for ([_]usize{ 3, 4, 5 }) |limit| {
        const bytes = "<mzML xmlns='http://psi.hupo.org/ms/mzml'><run><spectrumList>" ++
            "<spectrum id='s'><scanList/><scanList><scan/><scan/></scanList></spectrum>" ++
            "<spectrum id='t'/></spectrumList></run></mzML>";
        try Parse.compare(bytes, .{ .nodes = limit });
    }
    for ([_][]const u8{ "<scanList><scan>", "<scanList></wrong>", "<scanList>&missing;</scanList>" }) |fragment| {
        const bytes = try std.mem.concat(std.testing.allocator, u8, &.{
            "<mzML xmlns='http://psi.hupo.org/ms/mzml'><run><spectrumList><spectrum id='s'><scanList/>", fragment,
        });
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqual(error.InvalidXml, Parse.failure(bytes, .{}).?);
        try Parse.compare(bytes, .{});
    }
    for ([_][2][]const u8{
        .{ "<userParam name='note' value=''/>", "<userParam value='' extra='x'/>" },
        .{ "<userParam name='note' value=''/>", "<userParam name='note' extra='x'/>" },
        .{ "<scan>", "<scan xmlns='urn:wrong'>" },
    }) |replacement| {
        const bytes = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, replacement[0], replacement[1]);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqual(null, Parse.failure(bytes, .{}));
        try Parse.compare(bytes, .{});
    }
    for ([_][2][]const u8{
        .{ "<activation/>", "" },
        .{ "<scanList count='1'>", "<scanList count='2'>" },
        .{ "<scanWindowList count='1'>", "<scanWindowList count='bad'>" },
        .{ "<scanWindow/>", "<scanWindow/><scanWindow/>" },
        .{ "encodedLength='12'", "encodedLength='11'" },
        .{ "encodedLength='12'", "encodedLength='bad'" },
        .{ "encodedLength='12'", "" },
        .{ "arrayLength='1'", "arrayLength='bad'" },
    }) |replacement| {
        const bytes = try std.mem.replaceOwned(u8, std.testing.allocator, support.DOCUMENT, replacement[0], replacement[1]);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqual(null, Parse.failure(bytes, .{}));
        try Parse.compare(bytes, .{});
    }
}

test "[integration] - [mzML index]: rebuilds from records without reading the unused trailer" {
    const allocator = std.testing.allocator;
    const source = @embedFile("data/writer_indexed.mzML");
    const end = std.mem.indexOf(u8, source, "</mzML>").? + "</mzML>".len;
    var expected = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{ .policy = .rebuild });
    defer expected.deinit();
    for ([_][]const u8{ "", "<broken" }) |suffix| {
        const bytes = try std.mem.concat(allocator, u8, &.{ source[0..end], suffix });
        defer allocator.free(bytes);
        var actual = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .policy = .rebuild });
        defer actual.deinit();
        try std.testing.expectEqualDeep(expected.header().*, actual.header().*);
        try std.testing.expectEqual(expected.entryCount(), actual.entryCount());
        for (0..expected.entryCount()) |position| try std.testing.expectEqualDeep(expected.entryAt(position).?, actual.entryAt(position).?);
        for ([_]usize{ 0, 7, 8, 15 }) |position| {
            const entry = actual.entryAt(position).?;
            var left = (try expected.byId(allocator, entry.id)).?;
            defer left.deinit();
            var right = (try actual.at(allocator, entry.kind, entry.ordinal)).?;
            defer right.deinit();
            try std.testing.expectEqualDeep(left.value, right.value);
        }
        try std.testing.expectError(error.MissingIndex, mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{}));
    }
}

test "[integration] - [mzML index]: separates trailer budgets from header and record limits" {
    const allocator = std.testing.allocator;
    const source = @embedFile("data/writer_indexed.mzML");
    for ([_]mzml.StreamReader.Limits{
        .{ .nodes = 32 }, .{ .list_entries = 4 }, .{ .header_bytes = 4352 },
    }) |limits| {
        try std.testing.expectError(error.LimitExceeded, support.readAll(allocator, source, .{ .retain_index = true, .limits = limits }));
        var index = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{
            .records = 16,
            .reader = .{ .limits = limits },
        });
        defer index.deinit();
        try std.testing.expectEqual(@as(usize, 16), index.entryCount());
        var record = (try index.byId(allocator, "chromatogram=slof_zlib")).?;
        defer record.deinit();
        try std.testing.expectEqualStrings("chromatogram=slof_zlib", record.value.id);
        try std.testing.expectEqual(@as(usize, 7), record.value.index);
    }
    for ([_]mzml.IndexedReader.Options{
        .{ .records = 15 },                                   .{ .index_bytes = 1024 },
        .{ .reader = .{ .limits = .{ .header_bytes = 1 } } }, .{ .reader = .{ .limits = .{ .nodes = 1 } } },
        .{ .reader = .{ .limits = .{ .list_entries = 1 } } },
    }, [_]mzml.Diagnostic.Limit{ .records, .index_bytes, .header_bytes, .nodes, .list_entries }) |options, name| {
        try expectBuildLimit(.{ .bytes = source }, options, name);
    }
    try expectBuildLimit(.{ .bytes = source }, .{ .policy = .rebuild, .reader = .{ .limits = .{ .record_bytes = 1 } } }, .record_bytes);
    var opened = try mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{
        .policy = .open_embedded,
        .reader = .{ .limits = .{ .record_bytes = 1 } },
    });
    defer opened.deinit();
    try std.testing.expectError(error.LimitExceeded, opened.at(allocator, .spectrum, 0));
    try std.testing.expectEqual(.record_bytes, opened.diagnostic().?.detail.limit.name);
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
    const closing = std.mem.indexOf(u8, &bytes, "</fileChecksum>") orelse return error.TestUnexpectedResult;
    bytes[closing + 2] = 'x';
    try std.testing.expectError(error.MissingIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = &bytes }, .{}));
    const trailer = std.mem.indexOf(u8, &bytes, "<indexList ").?;
    try std.testing.expectError(error.MissingIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = bytes[0..trailer] }, .{}));
}

test "[integration] - [mzML index]: builds plain files explicitly and rejects changed file sources" {
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
    try std.testing.expectError(error.StaleSource, index.at(std.testing.allocator, .spectrum, 0));
    try std.testing.expectError(error.StaleSource, index.at(std.testing.allocator, .spectrum, 100));
    var decoded = mzml.DecodedArrays.init(std.testing.allocator, .{});
    defer decoded.deinit();
    try std.testing.expectError(error.StaleSource, index.byIdDecoded(std.testing.allocator, "absent", &decoded));
    try std.testing.expectError(error.StaleSource, index.atDecoded(std.testing.allocator, .spectrum, 100, &decoded));
    try std.testing.expectEqual(@as(usize, 0), decoded.len());
    try expectBuildLimit(.{ .bytes = support.DOCUMENT }, .{ .policy = .rebuild, .index_bytes = 1 }, .index_bytes);
}

test "[failure] - [mzML indexed lookup]: checks the source after array selection" {
    const Selection = struct {
        file: std.Io.File,
        changed: bool = false,
        failed: bool = false,

        fn select(data: ?*anyopaque, _: mzml.StreamReader.Selection) mzml.model.MetadataError!mzml.StreamReader.Payload {
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
    var decoded = mzml.DecodedArrays.init(std.testing.allocator, .{});
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
    var whole_bytes: [16384]u8 = undefined;
    var whole = std.Io.Writer.fixed(&whole_bytes);
    try support.constructFixture(std.testing.allocator, &whole, true, std.meta.tags(mzml.arrays.Pipeline));
    try support.expectWritten(std.mem.trimEnd(u8, @embedFile("data/writer_indexed.mzML"), "\n"), whole.buffered());
    for ([_]usize{ 1, 7, 63, 64, 65, 4096 }) |chunk| {
        var bytes: [16384]u8 = undefined;
        var out = std.Io.Writer.fixed(&bytes);
        var sink: ShortSink = .{ .out = &out, .chunk = chunk };
        try support.constructFixture(std.testing.allocator, &sink.writer, true, std.meta.tags(mzml.arrays.Pipeline));
        try sink.writer.flush();
        try std.testing.expectEqualStrings(whole.buffered(), out.buffered());
        try checkIndexed(std.testing.allocator, out.buffered());
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
    var fitting = try mzml.Writer.initIndexed(std.testing.allocator, &sink, .{}, .{ .records = 1 });
    defer fitting.deinit();
    try fitting.writeHeader(header.*);
    try fitting.beginList(.spectrum_list, 1, "dp");
    try fitting.writeRecord(record.node);
    try fitting.endList();
    try fitting.finish();
    sink = std.Io.Writer.fixed(&buffer);
    var writer = try mzml.Writer.initIndexed(std.testing.allocator, &sink, .{}, .{ .records = 0 });
    defer writer.deinit();
    try writer.writeHeader(header.*);
    try writer.beginList(.spectrum_list, 1, "dp");
    try std.testing.expectError(error.LimitExceeded, writer.writeRecord(record.node));
    try std.testing.expectEqual(.records, writer.diagnostic().?.detail.limit.name);
    try std.testing.expectEqual(.index, writer.diagnostic().?.stage);
    const report = writer.diagnostic().?;
    try std.testing.expectError(error.FailedState, writer.finish());
    try std.testing.expectEqualDeep(report, writer.diagnostic().?);
    var full = std.Io.Writer.fixed(&.{});
    var failed = try mzml.Writer.initIndexed(std.testing.allocator, &full, .{}, .{});
    defer failed.deinit();
    // Indexed output reaches the sink in buffered chunks; this one fails when finish flushes it.
    try failed.writeHeader(header.*);
    try std.testing.expectError(error.WriteFailed, failed.finish());
    try std.testing.expectEqual(.write_failed, failed.diagnostic().?.id);
    try std.testing.expectEqual(.finish, failed.diagnostic().?.operation);
    try std.testing.expectEqual(null, failed.diagnostic().?.location);
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
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .records = count });
        defer index.deinit();
        try std.testing.expectEqual(count, index.entryCount());
        var rebuilt = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .rebuild, .records = count });
        defer rebuilt.deinit();
        try std.testing.expectEqual(count, rebuilt.entryCount());
        if (try index.byId(std.testing.allocator, "native=a&b")) |copied| {
            var owner = copied;
            defer owner.deinit();
            try std.testing.expectEqual(@as(usize, 1), count);
            try std.testing.expectEqualStrings("native=a&b", owner.value.id);
        } else try std.testing.expectEqual(@as(usize, 0), count);
    }
}

test "[property] - [mzML indexed writer]: preserves IDs and offsets across index growth" {
    const Growing = struct {
        fn write(allocator: std.mem.Allocator, sink: *std.Io.Writer, counts: [2]usize, duplicate: bool) !void {
            var writer = try mzml.Writer.initIndexed(allocator, sink, .{}, .{});
            defer writer.deinit();
            try writer.writeHeader(.{
                .document = .{ .kind = .mzml, .attributes = &.{.{ .name = "version", .value = "1.1.0" }} },
                .run = .{ .kind = .run },
            });
            for ([_]mzml.model.Kind{ .spectrum, .chromatogram }, counts) |kind, count| {
                if (count == 0) continue;
                try writer.beginList(if (kind == .spectrum) .spectrum_list else .chromatogram_list, count, "dp");
                for (0..count) |position| {
                    var id: [32]u8 = undefined;
                    var ordinal: [32]u8 = undefined;
                    const node: mzml.model.Node = .{ .kind = kind, .attributes = &.{
                        .{ .name = "id", .value = try std.fmt.bufPrint(&id, "id&{d}", .{if (duplicate and position == count - 1) 0 else position}) },
                        .{ .name = "index", .value = try std.fmt.bufPrint(&ordinal, "{d}", .{position}) },
                        .{ .name = "defaultArrayLength", .value = "0" },
                    } };
                    writer.writeRecord(node) catch |err| {
                        try std.testing.expectError(error.FailedState, writer.finish());
                        return err;
                    };
                }
                try writer.endList();
            }
            try writer.finish();
        }

        fn allocated(allocator: std.mem.Allocator) !void {
            var bytes: [16384]u8 = undefined;
            var sink = std.Io.Writer.fixed(&bytes);
            try write(allocator, &sink, .{ 40, 19 }, false);
        }
    };
    for ([_][2]usize{ .{ 40, 0 }, .{ 0, 19 }, .{ 40, 19 } }) |counts| {
        var bytes: [16384]u8 = undefined;
        var sink = std.Io.Writer.fixed(&bytes);
        try Growing.write(std.testing.allocator, &sink, counts, false);
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{});
        defer index.deinit();
        try std.testing.expectEqualDeep(counts, support.kindCounts(&index));
        for ([_]mzml.model.Kind{ .spectrum, .chromatogram }, counts) |kind, count| {
            for (0..count) |position| {
                var id: [32]u8 = undefined;
                const expected = try std.fmt.bufPrint(&id, "id&{d}", .{position});
                var found = (try index.at(std.testing.allocator, kind, position)).?;
                defer found.deinit();
                try std.testing.expectEqualStrings(expected, found.value.id);
                try std.testing.expectEqual(kind, found.value.node.kind);
                try std.testing.expectEqual(position, found.value.index);
                const entry = index.entryAt(position + if (kind == .spectrum) @as(usize, 0) else counts[0]).?;
                try std.testing.expectEqual(entry.start, found.value.node.start_offset);
            }
        }
        if (counts[0] != 0 and counts[1] != 0) try std.testing.expectError(error.AmbiguousId, index.byId(std.testing.allocator, "id&0"));
        const checksum_start = try support.checksumStart(sink.buffered());
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(sink.buffered()[0..checksum_start], &digest, .{});
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), sink.buffered()[checksum_start..][0..40]);
        var failed_bytes: [16384]u8 = undefined;
        var failed_sink = std.Io.Writer.fixed(&failed_bytes);
        try std.testing.expectError(error.DuplicateId, Growing.write(std.testing.allocator, &failed_sink, counts, true));
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Growing.allocated, .{});
}

// Six spectra with 40 KB arrays: output spans many writer chunks, and each uncompressed
// array's Base64 crosses chunk boundaries on the writer's direct encoding path.
const LARGE_RECORDS = 6;
const LARGE_VALUES = 5000;

fn writeLargeIndexed(writer: *mzml.Writer) !void {
    var input = std.Io.Reader.fixed(support.DOCUMENT);
    var reader = try mzml.StreamReader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    try writer.writeHeader((try reader.readHeader()).*);
    var builder = mzml.Builder.init(std.testing.allocator, .{});
    defer builder.deinit();
    var encoder = mzml.arrays.Encoder.init(std.testing.allocator, .fast);
    defer encoder.deinit();
    var values: [LARGE_VALUES]f64 = undefined;
    try writer.beginList(.spectrum_list, LARGE_RECORDS, "dp");
    for (0..LARGE_RECORDS) |index| {
        builder.reset();
        encoder.reset();
        for (&values, 0..) |*value, i| value.* = @as(f64, @floatFromInt(i)) * 0.5 + @as(f64, @floatFromInt(index));
        var arrays: [2]mzml.Builder.Array = undefined;
        var wires: [2]mzml.Writer.ArrayPayload = undefined;
        inline for (.{ mzml.arrays.Pipeline.none, mzml.arrays.Pipeline.zlib }, 0..) |pipeline, i| {
            const prepared = try builder.prepareArray(f64, &values, .{
                .cv_ref = "MS",
                .encoding = .{ .pipeline = pipeline },
                .role = if (i == 0)
                    .{ .cv_ref = "MS", .accession = mzml.model.Terms.MZ_ARRAY, .name = "m/z array" }
                else
                    .{ .cv_ref = "MS", .accession = mzml.model.Terms.INTENSITY_ARRAY, .name = "intensity array" },
            }, &encoder);
            arrays[i] = prepared.array;
            wires[i] = prepared.payload;
        }
        var id: [16]u8 = undefined;
        const record = try builder.record(.spectrum, try std.fmt.bufPrint(&id, "scan={d}", .{index}), index, LARGE_VALUES, &.{}, &.{}, &arrays);
        try writer.writeRecordWithArrays(record.node, &wires);
    }
    try writer.endList();
    try writer.finish();
}

fn checkLargeIndexed(bytes: []const u8) !void {
    try support.expectCompleteIndexed(bytes);
    const end = try support.checksumStart(bytes);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes[0..end], &digest, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), bytes[end..][0..40]);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = bytes }, .{});
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, LARGE_RECORDS), index.entryCount());
    var decoded = mzml.DecodedArrays.init(std.testing.allocator, .{});
    defer decoded.deinit();
    for (0..LARGE_RECORDS) |position| {
        var record = (try index.at(std.testing.allocator, .spectrum, position)).?;
        defer record.deinit();
        try decoded.decodeRecord(record.value, index.header().groups);
        for (0..2) |array| {
            const values = decoded.get(array).?.values.float64;
            try std.testing.expectEqual(@as(usize, LARGE_VALUES), values.len);
            try std.testing.expectEqual(@as(f64, @floatFromInt(position)) + 0.5 * (LARGE_VALUES - 1), values[LARGE_VALUES - 1]);
        }
    }
}

test "[integration] - [mzML indexed writer]: streams multi-chunk output through short sinks and files" {
    var whole: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer whole.deinit();
    {
        var writer = try mzml.Writer.initIndexed(std.testing.allocator, &whole.writer, .{}, .{});
        defer writer.deinit();
        try writeLargeIndexed(&writer);
    }
    try std.testing.expect(whole.written().len > 20 * 16 * 1024);
    try checkLargeIndexed(whole.written());

    for ([_]usize{ 7, 4097, 20000 }) |chunk| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var sink: ShortSink = .{ .out = &out.writer, .chunk = chunk };
        var writer = try mzml.Writer.initIndexed(std.testing.allocator, &sink.writer, .{}, .{});
        defer writer.deinit();
        try writeLargeIndexed(&writer);
        try std.testing.expectEqualStrings(whole.written(), out.written());
    }

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    {
        const file = try dir.dir.createFile(std.testing.io, "large.mzML", .{ .read = true });
        defer file.close(std.testing.io);
        var buffer: [1000]u8 = undefined;
        var sink = file.writer(std.testing.io, &buffer);
        var writer = try mzml.Writer.initFile(std.testing.allocator, &sink, .{}, .{});
        defer writer.deinit();
        try writeLargeIndexed(&writer);
        try sink.interface.flush();
    }
    const bytes = try dir.dir.readFileAlloc(std.testing.io, "large.mzML", std.testing.allocator, .limited(4 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    // File output patches each streamed encodedLength into a placeholder as wide as its longest
    // possible text, so leading zeros can shift bytes and offsets; the document must still be
    // complete and consistent, with every length equal to its text.
    try checkLargeIndexed(bytes);
    try support.expectEncodedLengths(bytes);

    // A sink that fills mid-document fails a record write when the chunk drains, not finish.
    const capacity = 100 * 1024;
    const storage = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(storage);
    var full = std.Io.Writer.fixed(storage);
    var writer = try mzml.Writer.initIndexed(std.testing.allocator, &full, .{}, .{});
    defer writer.deinit();
    try std.testing.expectError(error.WriteFailed, writeLargeIndexed(&writer));
    const report = writer.diagnostic().?;
    try std.testing.expectEqual(.write_failed, report.id);
    try std.testing.expectEqual(.write_record, report.operation);
    try std.testing.expectEqual(null, report.location);
    try std.testing.expectError(error.FailedState, writer.finish());
}

test "[failure] - [mzML index]: bounds embedded offset text by binary_text_bytes and reports the need" {
    // Padding inside the index keeps every offset valid; open_embedded does not check the checksum.
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, @embedFile("data/writer_indexed.mzML"), ">1242</offset>", ">" ++ " " ** 100 ++ "1242</offset>");
    defer std.testing.allocator.free(source);
    var failure: ?mzml.Diagnostic = null;
    try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.buildWithDiagnostic(std.testing.allocator, .{ .bytes = source }, .{
        .policy = .open_embedded,
        .reader = .{ .limits = .{ .binary_text_bytes = 64 } },
    }, &failure));
    const limit = failure.?.detail.limit;
    try std.testing.expectEqual(.binary_text_bytes, limit.name);
    try std.testing.expectEqual(@as(u64, 64), limit.maximum);
    try std.testing.expectEqual(@as(?u64, 104), limit.needed);
}

test "[failure] - [mzML index]: a failed lookup reports no element from the lookup before it" {
    // Same length, so every indexed offset stays valid; only scan=zlib's opening tag breaks.
    const source = try std.mem.replaceOwned(u8, std.testing.allocator, @embedFile("data/writer_indexed.mzML"), "<spectrum id=\"scan=zlib\" index=\"1\"", "<spectrum id=\"scan=zlib\" index=!1\"");
    defer std.testing.allocator.free(source);
    var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = source }, .{ .policy = .open_embedded });
    defer index.deinit();
    var chromatogram = (try index.at(std.testing.allocator, .chromatogram, 0)).?;
    chromatogram.deinit();
    try std.testing.expectError(error.InvalidXml, index.at(std.testing.allocator, .spectrum, 1));
    try std.testing.expectEqual(null, index.diagnostic().?.element);
}

test "[failure] - [mzML index]: chromatograms listed in the index but missing from the file are an index fault" {
    const source = try std.testing.allocator.dupe(u8, @embedFile("data/writer_indexed.mzML"));
    defer std.testing.allocator.free(source);
    // The run ends where the chromatogram list began; the rest of the old list is blank, so
    // every indexed offset stays valid but no chromatogram list follows the spectra.
    const start = std.mem.indexOf(u8, source, "<chromatogramList").?;
    const end = std.mem.indexOf(u8, source, "</chromatogramList>").? + "</chromatogramList>".len;
    @memset(source[start..end], ' ');
    @memcpy(source[start..][0.."</run></mzML>".len], "</run></mzML>");
    var failure: ?mzml.Diagnostic = null;
    try std.testing.expectError(error.InvalidIndex, mzml.IndexedReader.buildWithDiagnostic(std.testing.allocator, .{ .bytes = source }, .{ .policy = .open_embedded }, &failure));
    try std.testing.expectEqual(mzml.Diagnostic.Id.invalid_index, failure.?.id);
}
