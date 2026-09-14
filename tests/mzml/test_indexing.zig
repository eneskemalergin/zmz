//! Tests indexed output, opening, indexing, and lookup.

const std = @import("std");
const mzml = @import("zmz").mzml;
const support = @import("support.zig");

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
    try std.testing.expectError(error.InvalidOptions, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = sink.buffered() }, .{ .policy = .open_embedded, .reader = .{ .validation = .{} } }));
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

test "[integration] - [mzML index]: opens encoded trailers and list namespace declarations" {
    const allocator = std.testing.allocator;
    for ([_]?std.builtin.Endian{ null, .little, .big }) |endian| {
        for (0..2) |spectra| {
            const width: usize = if (endian != null) 2 else 1;
            const bom: usize = if (endian != null) 2 else 0;
            var source: std.Io.Writer.Allocating = .init(allocator);
            defer source.deinit();
            try source.writer.writeAll("<p:indexedmzML xmlns:p='http://psi.hupo.org/ms/mzml'>" ++ support.HEADER);
            try source.writer.print("<spectrumList count='{d}' defaultDataProcessingRef='dp'>", .{spectra});
            const spectrum_start = bom + width * source.written().len;
            if (spectra != 0) try source.writer.writeAll("<spectrum id='a&amp;b' index='0' defaultArrayLength='0'/>");
            try source.writer.writeAll("</spectrumList><chromatogramList xmlns:q='http://psi.hupo.org/ms/mzml' count='1' defaultDataProcessingRef='dp'>");
            const chromatogram_start = bom + width * source.written().len;
            try source.writer.writeAll("<q:chromatogram id='tic' index='0' defaultArrayLength='1'>" ++ support.ARRAYS ++ "</q:chromatogram></chromatogramList></run></mzML>");
            const index_start = bom + width * source.written().len;
            try source.writer.print("<p:indexList count='2'><p:index name='chromatogram'><p:offset idRef='tic'>{d}</p:offset></p:index><p:index name='spectrum'>", .{chromatogram_start});
            if (spectra != 0) try source.writer.print("<p:offset idRef='a&amp;b'>{d}</p:offset>", .{spectrum_start});
            try source.writer.print("</p:index></p:indexList><p:indexListOffset>{d}</p:indexListOffset><p:fileChecksum>0000000000000000000000000000000000000000</p:fileChecksum></p:indexedmzML><!-- <indexListOffset>fake -->", .{index_start});
            const bytes = try allocator.alloc(u8, bom + width * source.written().len);
            defer allocator.free(bytes);
            if (endian) |order| {
                std.mem.writeInt(u16, bytes[0..2], 0xfeff, order);
                for (source.written(), 0..) |byte, i| std.mem.writeInt(u16, bytes[2 + 2 * i ..][0..2], byte, order);
            } else @memcpy(bytes, source.written());
            for (std.enums.values(mzml.StreamReader.Checks)) |checks| {
                var opened = try mzml.IndexedReader.build(allocator, .{ .bytes = bytes }, .{ .policy = .open_embedded, .reader = .{ .checks = checks } });
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
        try std.testing.expectError(error.InvalidOptions, mzml.IndexedReader.build(allocator, .{ .bytes = source }, .{ .policy = policy, .reader = .{ .checks = .minimal, .validation = .{} } }));
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
    try file.setLength(std.testing.io, support.DOCUMENT.len - 1);
    try std.testing.expectError(error.StaleSource, index.byId(std.testing.allocator, "native=a&b"));
    try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = support.DOCUMENT }, .{ .policy = .rebuild, .max_records = 1 }));
    try std.testing.expectError(error.LimitExceeded, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = support.DOCUMENT }, .{ .policy = .rebuild, .index_bytes = 1 }));
    const duplicate = support.HEADER ++ "<spectrumList count='2' defaultDataProcessingRef='dp'>" ++
        "<spectrum id='scan=1' index='0' defaultArrayLength='0'/>" ++
        "<spectrum id='scan=1' index='1' defaultArrayLength='0'/></spectrumList></run></mzML>";
    try std.testing.expectError(error.DuplicateId, mzml.IndexedReader.build(std.testing.allocator, .{ .bytes = duplicate }, .{ .policy = .rebuild }));
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
