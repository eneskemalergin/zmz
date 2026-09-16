//! Tests indexed output, opening, indexing, and lookup.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

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

test "[integration] - [mzML index]: retains inherited namespaces and UTF-16 physical spans" {
    const prefixed = support.HEADER ++ "<spectrumList xmlns:p='http://psi.hupo.org/ms/mzml' count='1' defaultDataProcessingRef='dp'>" ++
        "<p:spectrum id='scan=1' index='0' defaultArrayLength='0'/>" ++ "</spectrumList></run></mzML>";
    var bytes: [prefixed.len * 2 + 2]u8 = undefined;
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
        std.mem.writeInt(u16, bytes[0..2], 0xfeff, endian);
        for (prefixed, 0..) |byte, i| std.mem.writeInt(u16, bytes[2 + i * 2 ..][0..2], byte, endian);
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = &bytes }, .{ .policy = .rebuild });
        defer index.deinit();
        var record = (try index.byId(std.testing.allocator, "scan=1")).?;
        defer record.deinit();
        try std.testing.expectEqual(@as(u64, 2 + 2 * std.mem.indexOf(u8, prefixed, "<p:spectrum ").?), record.value.node.start_offset);
        try std.testing.expectEqualStrings("scan=1", record.value.id);
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
                    if (payload == .retain) {
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
    var index = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .policy = .open_embedded });
    defer index.deinit();
    try std.testing.expectError(error.InvalidXml, index.at(allocator, .spectrum, 0));
    var valid = (try index.at(allocator, .spectrum, 1)).?;
    defer valid.deinit();
    try std.testing.expectEqualStrings("scan=zlib", valid.value.id);
}

test "[integration] - [mzML index]: opens embedded targets without claiming full verification" {
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
    try std.testing.expectError(error.ChecksumMismatch, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{}));
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
    try std.testing.expectError(error.InvalidIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .open_embedded }));
    buffer[checksum_start] = saved;
    const first_index = std.mem.indexOf(u8, sink.buffered(), "index=\"0\"").? + "index=\"".len;
    buffer[first_index] = '9';
    var opened = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .open_embedded });
    defer opened.deinit();
    try std.testing.expectError(error.InvalidIndex, opened.at(std.testing.allocator, .spectrum, 0));
    try std.testing.expectError(error.InvalidIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{}));
}

test "[integration] - [mzML index]: opens and verifies encoded trailers and list namespace declarations" {
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
                if (spectra != 0) try source.writer.writeAll("<spectrum id='a&amp;b' index='0' defaultArrayLength='0'/>");
                try source.writer.writeAll(spaces[0..padding]);
                try source.writer.writeAll("</spectrumList><chromatogramList xmlns:q='http://psi.hupo.org/ms/mzml' count='1' defaultDataProcessingRef='dp'>");
                const chromatogram_start = bom + width * source.written().len;
                try source.writer.writeAll("<q:chromatogram id='tic' index='0' defaultArrayLength='1'>" ++ support.ARRAYS ++ "</q:chromatogram></chromatogramList></run></mzML>");
                const index_start = bom + width * source.written().len;
                try source.writer.print("<p:indexList count='2'><p:index name='chromatogram'><p:offset idRef='tic'>{d}</p:offset></p:index><p:index name='spectrum'>", .{chromatogram_start});
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
                        var opened = try mzml.IndexedReader.build(allocator, indexed_source, .{ .policy = .open_embedded, .reader = .{ .checks = checks } });
                        defer opened.deinit();
                        var rebuilt = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .policy = .rebuild });
                        defer rebuilt.deinit();
                        var verified = try mzml.IndexedReader.build(allocator, indexed_source, .{ .reader = .{ .checks = checks } });
                        defer verified.deinit();
                        try std.testing.expectEqualDeep(rebuilt.entries.items, verified.entries.items);
                        try std.testing.expectEqualDeep(rebuilt.header().*, verified.header().*);
                        try std.testing.expectEqual(spectra + 1, opened.entries.items.len);
                        for (opened.entries.items) |entry| {
                            var actual = (try opened.at(allocator, entry.kind, 0)).?;
                            defer actual.deinit();
                            var expected = (try rebuilt.at(allocator, entry.kind, 0)).?;
                            defer expected.deinit();
                            try support.expectNode(expected.value.node, actual.value.node);
                            try std.testing.expectEqual(expected.value.node.start_offset, actual.value.node.start_offset);
                            try std.testing.expectEqual(expected.value.node.end_offset, actual.value.node.end_offset);
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
                            var name: [2]u8 = .{ 'x', 0 };
                            if (endian) |order| std.mem.writeInt(u16, &name, 'x', order);
                            if (malformed) try file.writePositionalAll(std.testing.io, name[0..width], start + width);
                            for ([_]bool{ false, true }) |truncated| {
                                var failure: FailedRead = .{ .start = start, .stop = start + 65536, .truncated = truncated };
                                const io: std.Io = .{ .userdata = &failure, .vtable = &vtable };
                                try std.testing.expectError(if (truncated) error.TruncatedSource else error.InputOutput, mzml.IndexedReader.build(allocator, .{ .file = .{ .handle = file, .io = io } }, .{ .policy = .open_embedded }));
                                try std.testing.expect(failure.failed);
                            }
                            try file.writePositionalAll(std.testing.io, bytes[start + width ..][0..width], start + width);
                        }
                    }
                }
            }
        }
    }
}

test "[integration] - [mzML minimal checks]: retains index verification and record identity checks" {
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
    try std.testing.expectError(error.ChecksumMismatch, mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .reader = .{ .checks = .minimal } }));
    @memcpy(bytes, source);
    const first_index = std.mem.indexOf(u8, bytes, "index=\"0\"").? + "index=\"".len;
    bytes[first_index] = '9';
    var opened = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .policy = .open_embedded, .reader = .{ .checks = .minimal } });
    defer opened.deinit();
    try std.testing.expectError(error.InvalidIndex, opened.at(allocator, .spectrum, 0));
    const malformed = try std.mem.replaceOwned(u8, allocator, source, "order=\"0\"", "order=\"bad\"");
    defer allocator.free(malformed);
    for ([_]mzml.IndexedReader.Policy{ .rebuild, .verify_embedded }) |policy| {
        try std.testing.expectError(error.InvalidValue, mzml.IndexedReader.build(allocator, .{ .bytes = malformed }, .{ .policy = policy, .reader = .{ .checks = .minimal } }));
    }
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
    const saved = buffer[checksum_start];
    buffer[checksum_start] = if (saved == '0') '1' else '0';
    try std.testing.expectError(error.ChecksumMismatch, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{}));
    buffer[checksum_start] = saved;
    const marker = "<offset idRef=\"scan=none\">";
    const target_start = std.mem.indexOf(u8, sink.buffered(), marker).? + marker.len;
    const target_end = std.mem.indexOfScalarPos(u8, sink.buffered(), target_start, '<').?;
    var target: [32]u8 = undefined;
    const target_length = target_end - target_start;
    @memcpy(target[0..target_length], buffer[target_start..target_end]);
    @memset(buffer[target_start..target_end], '0');
    try std.testing.expectError(error.InvalidIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{}));
    @memcpy(buffer[target_start..target_end], target[0..target_length]);
    buffer[target_end - 1] = if (buffer[target_end - 1] == '9') '8' else buffer[target_end - 1] + 1;
    try std.testing.expectError(error.InvalidIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{}));
    @memcpy(buffer[target_start..target_end], target[0..target_length]);
    const offset_start = std.mem.indexOf(u8, sink.buffered(), "<indexListOffset>").? + "<indexListOffset>".len;
    buffer[offset_start] = '0';
    try std.testing.expectError(error.InvalidIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{}));
    var rebuilt = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .rebuild });
    defer rebuilt.deinit();
    try std.testing.expectEqual(@as(usize, 16), rebuilt.entries.items.len);
}

test "[property] - [mzML index]: retains trailer limits before reporting unmatched entries" {
    const Parse = struct {
        fn failure(bytes: []const u8, limits: mzml.StreamReader.Limits) ?mzml.StreamReader.Error {
            var input = std.Io.Reader.fixed(bytes);
            var reader = mzml.StreamReader.init(std.testing.allocator, &input, .{ .payload = .skip, .retain_index = true, .limits = limits }) catch |err| return err;
            defer reader.deinit();
            while ((reader.nextRecord() catch |err| return err) != null) {}
            return null;
        }
    };
    const source = @embedFile("data/writer_indexed.mzML");
    var bytes: [source.len]u8 = source.*;
    const id = std.mem.indexOf(u8, &bytes, "idRef=\"scan=none\"").? + "idRef=\"".len;
    bytes[id] = 'x';
    for ([_]usize{ 0, 1, 2, 3, 4, 7, 8, 16, 24, 32, 39, 40, 64, 128, 1024, 4096, 8192 }) |limit| {
        for ([_]mzml.StreamReader.Limits{
            .{ .header_bytes = limit },      .{ .nodes = limit },           .{ .list_entries = limit },
            .{ .binary_text_bytes = limit }, .{ .depth = @min(limit, 64) },
        }) |limits| {
            const expected = Parse.failure(&bytes, limits) orelse error.InvalidIndex;
            try std.testing.expectError(expected, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = &bytes }, .{ .reader = .{ .limits = limits } }));
        }
    }
}

test "[failure] - [mzML index]: checks the complete trailer before deferred matching errors" {
    const source = @embedFile("data/writer_indexed.mzML");
    var bytes: [source.len]u8 = source.*;
    const target = std.mem.indexOf(u8, &bytes, "<offset idRef=\"scan=none\">").? + "<offset idRef=\"scan=none\">".len;
    const list_offset = std.mem.indexOf(u8, &bytes, "<indexListOffset>").? + "<indexListOffset>".len;
    bytes[target] = 'x';
    bytes[list_offset] = '0';
    try std.testing.expectError(error.InvalidIndex, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = &bytes }, .{}));
    bytes[list_offset] = source[list_offset];
    try std.testing.expectError(error.InvalidValue, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = &bytes }, .{}));
    const closing = std.mem.indexOf(u8, &bytes, "</fileChecksum>").?;
    bytes[closing + 2] = 'x';
    try std.testing.expectError(error.InvalidXml, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = &bytes }, .{}));
    const trailer = std.mem.indexOf(u8, &bytes, "<indexList ").?;
    try std.testing.expectError(error.InvalidXml, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = bytes[0..trailer] }, .{}));
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

test "[integration] - [mzML indexed writer]: verifies empty indexes and escaped IDs" {
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
        var index = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{});
        defer index.deinit();
        try std.testing.expectEqual(count, index.entries.items.len);
        var opened = try mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .open_embedded });
        defer opened.deinit();
        try std.testing.expectEqual(count, opened.entries.items.len);
        if (try index.byId(std.testing.allocator, "native=a&b")) |copied| {
            var owner = copied;
            defer owner.deinit();
            try std.testing.expectEqual(@as(usize, 1), count);
            try std.testing.expectEqualStrings("native=a&b", owner.value.id);
        } else try std.testing.expectEqual(@as(usize, 0), count);
    }
}
