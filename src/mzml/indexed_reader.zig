//! Builds explicit record indexes over stable bytes or a borrowed regular file.
//!
//! Opening reads the header and embedded index without scanning every record or
//! hashing the file. Rebuilding requires an explicit policy and parses the file once.
//! Lookups use saved ancestor opening tags and read one record span; they never
//! rebuild or scan preceding records. Keep the source unchanged.

const std = @import("std");
const model = @import("model.zig");
const cv = @import("../cv/source.zig");
const owned = @import("owned.zig");
const reader_bridge = @import("internal/indexed_reader_bridge.zig");
const PublicStreamReader = @import("stream_reader.zig").StreamReader;
const DecodedArrays = PublicStreamReader.DecodedArrays;
const StreamReader = reader_bridge.Reader;
const xml = @import("../xml/mzml_adapter.zig");

const IndexedReader = @This();

/// Borrowed immutable bytes or a regular-file handle kept open by the caller.
pub const Source = union(enum) {
    bytes: []const u8,
    file: struct { handle: std.Io.File, io: std.Io },
};

pub const Policy = enum { rebuild, open_embedded };

/// Bounds index storage and trailer parsing separately from header and record storage.
pub const Options = struct {
    policy: Policy = .open_embedded,
    max_records: usize = 1_000_000,
    index_bytes: usize = 256 * 1024 * 1024,
    /// Maximum raw XML record span read by a lookup, separate from retained-node limits.
    record_span_bytes: usize = 256 * 1024 * 1024,
    /// Bounded backward search for indexListOffset when opening an embedded index.
    tail_bytes: usize = 64 * 1024,
    /// Applies to headers and returned records; index building skips payload text.
    reader: PublicStreamReader.Options = .{},
};

/// Physical span and ID, borrowed from this index. Index is the zero-based lookup
/// ordinal within the record kind, not the source record's index. With open_embedded,
/// start may precede XML whitespace and end bounds the span at the next target or trailer.
pub const Entry = struct { kind: model.Kind, id: []const u8, index: usize, start: u64, end: u64 };

pub const Error = PublicStreamReader.Error || owned.Error || std.Io.File.StatError || std.Io.File.ReadPositionalError || error{
    MissingIndex,
    InvalidIndex,
    DuplicateId,
    AmbiguousId,
    StaleSource,
    UnsupportedSource,
    TruncatedSource,
};

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
source: Source,
options: Options,
size: u64,
stamp: ?std.Io.File.Stat = null,
remaining: usize,
entries: std.ArrayList(Entry) = .empty,
ids: [2]std.HashMapUnmanaged(usize, void, IdContext, std.hash_map.default_max_load_percentage) = .{ .empty, .empty },
metadata: ?owned.Header = null,
contexts: [2]?FragmentAncestors = .{ null, null },
counts: [2]usize = .{ 0, 0 },
lookup_reader: ?StreamReader = null,
lookup_kind: ?model.Kind = null,

/// Builds an index under the selected policy, retaining metadata but not payloads.
/// No automatic fallback occurs. Release with deinit; do not copy the returned owner.
pub fn build(allocator: std.mem.Allocator, source: Source, options: Options) Error!IndexedReader {
    if (options.policy == .open_embedded and options.tail_bytes == 0)
        return error.InvalidOptions;
    const stamp = switch (source) {
        .bytes => null,
        .file => |file| try file.handle.stat(file.io),
    };
    if (stamp) |stat| if (stat.kind != .file) return error.UnsupportedSource;
    var self: IndexedReader = .{
        .allocator = allocator,
        .arena = .init(allocator),
        .source = source,
        .options = options,
        .size = if (stamp) |stat| stat.size else source.bytes.len,
        .stamp = stamp,
        .remaining = options.index_bytes,
    };
    errdefer self.deinit();
    var buffer: [64 * 1024]u8 = undefined;
    var fixed = std.Io.Reader.fixed(if (source == .bytes) source.bytes else &.{});
    var file_reader: std.Io.File.Reader = undefined;
    const input = switch (source) {
        .bytes => &fixed,
        .file => |file| blk: {
            file_reader = file.handle.reader(file.io, &buffer);
            file_reader.mode = .positional_simple;
            break :blk &file_reader.interface;
        },
    };
    var reader_options = options.reader;
    reader_options.payload = .skip;
    reader_options.retain_index = false;
    var reader = try StreamReader.init(allocator, input, reader_options);
    defer reader.deinit();
    const source_header = try reader.readHeader();
    if (options.policy != .rebuild and !source_header.indexed) return error.MissingIndex;
    if (options.policy == .open_embedded) {
        try self.openEmbedded(&reader);
        self.metadata = try owned.Header.init(allocator, source_header.*, .{ .bytes = options.reader.limits.header_bytes });
        try self.checkSource();
        return self;
    }
    while (try reader_bridge.nextIndexRecord(&reader)) |record| {
        if (self.entries.items.len == options.max_records) return error.LimitExceeded;
        const k = kindIndex(record.node.kind);
        if (record.node.start_offset >= record.node.end_offset or record.node.end_offset > self.size)
            return error.InvalidIndex;
        if (self.contexts[k] == null) self.contexts[k] = try self.captureAncestors(&reader, k);
        try self.charge(@sizeOf(Entry) + @sizeOf(usize) * 4);
        const id = try self.copy(record.id);
        const entry = try self.ids[k].getOrPutContextAdapted(allocator, id, IdQuery{ .entries = self.entries.items }, .{ .entries = self.entries.items });
        if (entry.found_existing) return error.DuplicateId;
        entry.key_ptr.* = self.entries.items.len;
        try self.entries.ensureUnusedCapacity(allocator, 1);
        self.entries.appendAssumeCapacity(.{ .kind = record.node.kind, .id = id, .index = self.counts[k], .start = record.node.start_offset, .end = record.node.end_offset });
        self.counts[k] += 1;
    }
    self.metadata = try owned.Header.init(allocator, source_header.*, .{ .bytes = options.reader.limits.header_bytes });
    try self.checkSource();
    return self;
}

/// Releases index and metadata storage, not the borrowed source or returned owned records.
pub fn deinit(self: *IndexedReader) void {
    if (self.lookup_reader) |*reader| reader.deinit();
    if (self.metadata) |*metadata| metadata.deinit();
    self.entries.deinit(self.allocator);
    for (&self.ids) |*ids| ids.deinit(self.allocator);
    self.arena.deinit();
    self.* = undefined;
}

/// Returns metadata until deinit. Observed counts remain zero with open_embedded;
/// its counts come from the index, not a complete traversal of the record lists.
pub fn header(self: *const IndexedReader) *const model.Header {
    return &self.metadata.?.value;
}

/// Finds an exact ID and returns an independent record owner, or null when absent.
/// Returns AmbiguousId when both a spectrum and a chromatogram use this ID.
/// Lookups reuse parser storage and must not run concurrently on this reader.
pub fn byId(self: *IndexedReader, allocator: std.mem.Allocator, id: []const u8) Error!?owned.Record {
    const position = try self.idPosition(id) orelse return null;
    return try self.readEntry(allocator, self.entries.items[position], null);
}

/// Looks up a zero-based ordinal within spectra or chromatograms; other kinds fail.
pub fn at(self: *IndexedReader, allocator: std.mem.Allocator, kind: model.Kind, ordinal: usize) Error!?owned.Record {
    const position = try self.ordinalPosition(kind, ordinal) orelse return null;
    return try self.readEntry(allocator, self.entries.items[position], null);
}

/// Returns independent metadata and decodes all arrays into caller-owned reusable storage.
/// Binary text is omitted. Requires no array selector; payload is ignored.
/// Missing IDs and failures clear output. A failed lookup stops immediately; later lookups may retry.
/// Numeric slices last until output is reused, reset, or deinitialized, independently of metadata.
pub fn byIdDecoded(self: *IndexedReader, allocator: std.mem.Allocator, id: []const u8, output: *DecodedArrays) Error!?owned.Record {
    output.reset();
    errdefer output.reset();
    if (self.options.reader.array_selector != null) return error.InvalidOptions;
    const position = try self.idPosition(id) orelse return null;
    return try self.readDecodedEntry(allocator, self.entries.items[position], output);
}

/// Uses byIdDecoded's storage and failure rules for a zero-based spectrum or chromatogram ordinal.
pub fn atDecoded(self: *IndexedReader, allocator: std.mem.Allocator, kind: model.Kind, ordinal: usize, output: *DecodedArrays) Error!?owned.Record {
    output.reset();
    errdefer output.reset();
    if (self.options.reader.array_selector != null) return error.InvalidOptions;
    const position = try self.ordinalPosition(kind, ordinal) orelse return null;
    return try self.readDecodedEntry(allocator, self.entries.items[position], output);
}

fn idPosition(self: *IndexedReader, id: []const u8) Error!?usize {
    try self.checkSource();
    const query: IdQuery = .{ .entries = self.entries.items };
    const spectrum = self.ids[0].getKeyAdapted(id, query);
    const chromatogram = self.ids[1].getKeyAdapted(id, query);
    if (spectrum != null and chromatogram != null) return error.AmbiguousId;
    return spectrum orelse chromatogram;
}

fn ordinalPosition(self: *IndexedReader, kind: model.Kind, ordinal: usize) Error!?usize {
    if (kind != .spectrum and kind != .chromatogram) return error.InvalidIndex;
    try self.checkSource();
    if (ordinal >= self.counts[kindIndex(kind)]) return null;
    return ordinal + if (kind == .spectrum) @as(usize, 0) else self.counts[0];
}

fn readDecodedEntry(self: *IndexedReader, allocator: std.mem.Allocator, entry: Entry, output: *DecodedArrays) Error!owned.Record {
    const record = try self.readEntry(allocator, entry, output);
    output.complete();
    return record;
}

fn readEntry(self: *IndexedReader, allocator: std.mem.Allocator, entry: Entry, output: ?*DecodedArrays) Error!owned.Record {
    try self.checkSource();
    const context = self.contexts[kindIndex(entry.kind)].?;
    const length = std.math.cast(usize, entry.end - entry.start) orelse return error.LimitExceeded;
    if (length > self.options.record_span_bytes) return error.LimitExceeded;
    const prefix_end = std.math.add(usize, context.prefix.len, length) catch return error.LimitExceeded;
    const total = std.math.add(usize, prefix_end, context.suffix.len) catch return error.LimitExceeded;
    var buffer: [64 * 1024]u8 = undefined;
    const reuse_ancestors = self.lookup_kind == entry.kind;
    self.lookup_kind = null;
    var input = FragmentInput.init(self, if (reuse_ancestors) &.{} else context.prefix, entry.start, length, context.suffix, buffer[0..@max(4, @min(buffer.len, total))]);
    if (self.lookup_reader == null) {
        var empty_input = std.Io.Reader.fixed(&.{});
        self.lookup_reader = try StreamReader.init(self.allocator, &empty_input, self.options.reader);
        reader_bridge.resetFragmentParser(&self.lookup_reader.?);
    }
    var record = reader_bridge.readFragment(&self.lookup_reader.?, allocator, &input.interface, context.ancestors, entry.start, context.prefix.len, self.options.policy != .open_embedded, self.header().groups, output, reuse_ancestors, .{ .kind = entry.kind, .id = entry.id }) catch |err| return input.originalError(err);
    errdefer record.deinit();
    if (record.value.node.end_offset > entry.end or
        (self.options.policy == .rebuild and
            (record.value.node.start_offset != entry.start or record.value.node.end_offset != entry.end))) return error.InvalidIndex;
    try self.checkSource();
    self.lookup_kind = entry.kind;
    return record;
}

fn checkSource(self: *const IndexedReader) Error!void {
    if (self.source == .file) {
        const file = self.source.file;
        const current = try file.handle.stat(file.io);
        const original = self.stamp.?;
        if (current.size != original.size or current.inode != original.inode or
            !std.meta.eql(current.mtime, original.mtime)) return error.StaleSource;
    }
}

const FragmentInput = struct {
    index: *const IndexedReader,
    prefix: []const u8,
    offset: u64,
    remaining: usize,
    suffix: []const u8,
    failure: ?Error = null,
    interface: std.Io.Reader,

    fn init(index: *const IndexedReader, prefix: []const u8, offset: u64, length: usize, suffix: []const u8, buffer: []u8) FragmentInput {
        return .{
            .index = index,
            .prefix = prefix,
            .offset = offset,
            .remaining = length,
            .suffix = suffix,
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *FragmentInput = @fieldParentPtr("interface", reader);
        if (self.failure != null) return error.ReadFailed;
        if (limit == .nothing) return 0;
        if (self.prefix.len != 0) {
            const n = try writer.write(limit.sliceConst(self.prefix));
            self.prefix = self.prefix[n..];
            return n;
        }
        if (self.remaining != 0) {
            const output = limit.min(.limited(self.remaining)).slice(try writer.writableSliceGreedy(1));
            self.index.readAt(output, self.offset) catch |err| {
                self.failure = err;
                return error.ReadFailed;
            };
            self.offset += output.len;
            self.remaining -= output.len;
            writer.advance(output.len);
            return output.len;
        }
        if (self.suffix.len != 0) {
            const n = try writer.write(limit.sliceConst(self.suffix));
            self.suffix = self.suffix[n..];
            return n;
        }
        return error.EndOfStream;
    }

    fn originalError(self: *const FragmentInput, err: Error) Error {
        return if (err == error.ReadFailed) self.failure orelse err else err;
    }
};

fn trailerLimits(self: *const IndexedReader) PublicStreamReader.Limits {
    var limits = self.options.reader.limits;
    limits.header_bytes = self.options.index_bytes;
    limits.list_entries = @max(2, self.options.max_records);
    limits.nodes = self.options.max_records +| 5;
    return limits;
}

fn openEmbedded(self: *IndexedReader, reader: *StreamReader) Error!void {
    const scopes = reader_bridge.scopes(reader);
    const prefix_len = std.math.cast(usize, scopes[0].end) orelse return error.LimitExceeded;
    if (prefix_len > self.options.reader.limits.header_bytes) return error.LimitExceeded;
    const prefix = try self.allocator.alloc(u8, prefix_len);
    defer self.allocator.free(prefix);
    try self.readAt(prefix, 0);
    const endian = try self.encoding();
    const tail_len: usize = @intCast(@min(self.size, self.options.tail_bytes));
    const tail = try self.allocator.alloc(u8, tail_len);
    defer self.allocator.free(tail);
    const tail_start = self.size - tail.len;
    try self.readAt(tail, tail_start);
    var search_end = tail.len;
    var index_start: ?u64 = null;
    var trailer_options = self.options.reader;
    trailer_options.limits = self.trailerLimits();
    while (offsetTag(tail[0..search_end], endian)) |start| {
        search_end = start;
        const physical_start = tail_start + start;
        if (physical_start < prefix_len) continue;
        const length = std.math.add(usize, prefix_len, tail.len - start) catch return error.LimitExceeded;
        const bytes = try self.allocator.alloc(u8, length);
        defer self.allocator.free(bytes);
        @memcpy(bytes[0..prefix_len], prefix);
        @memcpy(bytes[prefix_len..], tail[start..]);
        var parsed = reader_bridge.parseFooter(self.allocator, bytes, trailer_options, physical_start, prefix_len) catch |err| switch (err) {
            error.OutOfMemory, error.LimitExceeded => return err,
            else => continue,
        };
        defer parsed.arena.deinit();
        index_start = cv.parseInteger(u64, parsed.nodes[0].text) catch continue;
        break;
    }
    const start = index_start orelse return error.MissingIndex;
    const final_scope = scopes[scopes.len - 1];
    if (start < final_scope.end or start >= self.size or start > std.math.maxInt(i64) or
        (endian != null and start % 2 != 0)) return error.InvalidIndex;
    const trailer_len = std.math.cast(usize, self.size - start) orelse return error.LimitExceeded;
    if (trailer_len > self.options.index_bytes) return error.LimitExceeded;
    const bytes_len = std.math.add(usize, prefix_len, trailer_len) catch return error.LimitExceeded;
    var buffer: [64 * 1024]u8 = undefined;
    var input = FragmentInput.init(self, prefix, start, trailer_len, &.{}, buffer[0..@max(4, @min(buffer.len, bytes_len))]);
    self.readEmbeddedEntries(&input.interface, start, final_scope.end, endian) catch |err| return input.originalError(err);
    for (self.entries.items, 0..) |*entry, i| {
        if (i + 1 < self.entries.items.len) entry.end = self.entries.items[i + 1].start;
        if (entry.start >= entry.end) return error.InvalidIndex;
    }
    if (reader_bridge.listScope(reader, 0) != null) self.contexts[0] = try self.captureAncestors(reader, 0);
    if (reader_bridge.listScope(reader, 1) != null) self.contexts[1] = try self.captureAncestors(reader, 1);
    if (self.counts[1] != 0 and self.contexts[1] == null) {
        if (self.counts[0] == 0) {
            try reader_bridge.finishEmptySpectrumList(reader);
        } else {
            const last = self.entries.items[self.counts[0] - 1];
            const context = self.contexts[0] orelse return error.InvalidIndex;
            const span = std.math.cast(usize, last.end - last.start) orelse return error.LimitExceeded;
            if (span > self.options.record_span_bytes) return error.LimitExceeded;
            const fragment_len = std.math.add(usize, context.prefix.len, span) catch return error.LimitExceeded;
            var fragment = FragmentInput.init(self, context.prefix, last.start, span, &.{}, buffer[0..@max(4, @min(buffer.len, fragment_len))]);
            reader_bridge.resumeFollowingList(reader, &fragment.interface, context.ancestors, last.start, context.prefix.len) catch |err| return fragment.originalError(err);
        }
        self.contexts[1] = try self.captureAncestors(reader, 1);
    }
    const source_header = reader_bridge.header(reader);
    for ([_]?model.RecordList{ source_header.spectrum_list, source_header.chromatogram_list }, 0..) |list, k| {
        if (list != null) {
            if (self.counts[k] != 0) {
                const first = self.entries.items[if (k == 0) 0 else self.counts[0]];
                if (first.start < reader_bridge.listScope(reader, k).?.end) return error.InvalidIndex;
            }
        } else if (self.counts[k] != 0) return error.InvalidIndex;
    }
}

fn readEmbeddedEntries(self: *IndexedReader, input: *std.Io.Reader, index_start: u64, minimum: u64, endian: ?std.builtin.Endian) Error!void {
    const limits = self.options.reader.limits;
    var cursor = try xml.Cursor.init(self.allocator, input, limits.depth, limits.attributes, limits.attribute_bytes);
    defer cursor.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.allocator);
    try cursor.advance(false);
    _ = try indexStart(&cursor, .indexed_mzml);
    try cursor.advance(false);
    _ = try indexStart(&cursor, .index_list);
    var seen = [_]bool{ false, false };
    try cursor.advance(false);
    while ((cursor.current orelse return error.UnexpectedEnd).data == .start_element) {
        const index = try indexStart(&cursor, .index);
        const name = (index.attribute(null, "name") orelse return error.MissingAttribute).value;
        const kind: model.Kind = if (std.mem.eql(u8, name, "spectrum")) .spectrum else if (std.mem.eql(u8, name, "chromatogram")) .chromatogram else return error.InvalidIndex;
        const k = kindIndex(kind);
        if (seen[k]) return error.InvalidIndex;
        seen[k] = true;
        var previous: u64 = 0;
        try cursor.advance(false);
        while ((cursor.current orelse return error.UnexpectedEnd).data == .start_element) {
            const offset = try indexStart(&cursor, .offset);
            const id_ref = (offset.attribute(null, "idRef") orelse return error.MissingAttribute).value;
            if (self.entries.items.len == self.options.max_records) return error.LimitExceeded;
            try self.charge(@sizeOf(Entry) + @sizeOf(usize) * 4);
            const id = try self.copy(id_ref);
            const target = try cv.parseInteger(u64, try self.indexText(&cursor, &text, .offset));
            if (target <= previous or target >= index_start or target < minimum or
                (endian != null and target % 2 != 0) or target > std.math.maxInt(i64)) return error.InvalidIndex;
            previous = target;
            const entry = try self.ids[k].getOrPutContextAdapted(self.allocator, id, IdQuery{ .entries = self.entries.items }, .{ .entries = self.entries.items });
            if (entry.found_existing) return error.DuplicateId;
            entry.key_ptr.* = self.entries.items.len;
            try self.entries.append(self.allocator, .{ .kind = kind, .id = id, .index = self.counts[k], .start = target, .end = index_start });
            self.counts[k] += 1;
        }
        try indexEnd(&cursor, .index);
    }
    try indexEnd(&cursor, .index_list);
    _ = try indexStart(&cursor, .index_list_offset);
    if (try cv.parseInteger(u64, try self.indexText(&cursor, &text, .index_list_offset)) != index_start) return error.InvalidIndex;
    _ = try indexStart(&cursor, .file_checksum);
    _ = try self.indexText(&cursor, &text, .file_checksum);
    try indexEnd(&cursor, .indexed_mzml);
    if (cursor.current != null) return error.InvalidStructure;
    // Each kind is already ordered. Rotate only when the two index elements are reversed.
    if (self.counts[0] != 0 and self.counts[1] != 0 and self.entries.items[0].kind == .chromatogram) {
        std.mem.rotate(Entry, self.entries.items, self.counts[1]);
        // Move positions with their entries so each stored hash still names the same ID.
        var spectra = self.ids[0].keyIterator();
        while (spectra.next()) |position| position.* -= self.counts[1];
        var chromatograms = self.ids[1].keyIterator();
        while (chromatograms.next()) |position| position.* += self.counts[0];
    }
}

fn indexStart(cursor: *const xml.Cursor, kind: model.Kind) Error!xml.Start {
    const event = cursor.current orelse return error.UnexpectedEnd;
    if (event.data != .start_element or !event.data.start_element.name.eql(xml.NAMESPACE, kind.xmlName())) return error.InvalidStructure;
    return event.data.start_element;
}

fn indexEnd(cursor: *xml.Cursor, kind: model.Kind) Error!void {
    const event = cursor.current orelse return error.UnexpectedEnd;
    if (event.data != .end_element or !event.data.end_element.name.eql(xml.NAMESPACE, kind.xmlName())) return error.InvalidStructure;
    try cursor.advance(false);
}

fn indexText(self: *const IndexedReader, cursor: *xml.Cursor, text: *std.ArrayList(u8), kind: model.Kind) Error![]const u8 {
    text.clearRetainingCapacity();
    try cursor.advance(true);
    while (cursor.current) |event| {
        if (event.data != .text) break;
        const fragment = event.data.text.bytes;
        if (fragment.len > self.options.reader.limits.binary_text_bytes -| text.items.len) return error.LimitExceeded;
        try text.appendSlice(self.allocator, fragment);
        try cursor.advance(true);
    }
    try indexEnd(cursor, kind);
    return text.items;
}

// This only finds candidates. The XML cursor parses the candidate and complete trailer.
fn offsetTag(bytes: []const u8, endian: ?std.builtin.Endian) ?usize {
    const name = "indexListOffset";
    var encoded: [name.len * 2]u8 = undefined;
    const width: usize = if (endian != null) 2 else 1;
    const needle = if (endian) |order| blk: {
        for (name, 0..) |byte, i| std.mem.writeInt(u16, encoded[i * 2 ..][0..2], byte, order);
        break :blk encoded[0..];
    } else name;
    var end = bytes.len;
    while (std.mem.lastIndexOf(u8, bytes[0..end], needle)) |position| {
        end = position;
        if (position < width) continue;
        var before = position - width;
        const preceding = codeUnit(bytes, before, endian);
        if (preceding == '<') return before;
        if (preceding != ':') continue;
        while (before >= width) {
            before -= width;
            const unit = codeUnit(bytes, before, endian);
            if (unit == '<') return before;
            if (unit == '/' or unit == '>' or unit <= ' ') break;
        }
    }
    return null;
}

fn codeUnit(bytes: []const u8, start: usize, endian: ?std.builtin.Endian) u16 {
    return if (endian) |order| std.mem.readInt(u16, bytes[start..][0..2], order) else bytes[start];
}

fn encoding(self: *const IndexedReader) Error!?std.builtin.Endian {
    var signature: [4]u8 = @splat(0);
    try self.readAt(signature[0..@intCast(@min(4, self.size))], 0);
    return if (signature[0] == 0xff or (signature[0] == '<' and signature[1] == 0)) .little else if (signature[0] == 0xfe or (signature[0] == 0 and signature[1] == '<')) .big else null;
}

const IdContext = struct {
    entries: []const Entry,

    pub fn hash(self: IdContext, position: usize) u64 {
        return std.hash_map.hashString(self.entries[position].id);
    }

    pub fn eql(_: IdContext, left: usize, right: usize) bool {
        return left == right;
    }
};

const IdQuery = struct {
    entries: []const Entry,

    pub fn hash(_: IdQuery, id: []const u8) u64 {
        return std.hash_map.hashString(id);
    }

    pub fn eql(self: IdQuery, id: []const u8, position: usize) bool {
        return std.mem.eql(u8, id, self.entries[position].id);
    }
};

fn captureAncestors(self: *IndexedReader, reader: *StreamReader, k: usize) Error!FragmentAncestors {
    const current_scopes = reader_bridge.scopes(reader);
    var scopes: [4]reader_bridge.Scope = undefined;
    @memcpy(scopes[0..current_scopes.len], current_scopes);
    scopes[0].start = 0;
    scopes[current_scopes.len] = reader_bridge.listScope(reader, k).?;
    const count = current_scopes.len + 1;
    var length: usize = 0;
    for (scopes[0..count]) |scope| length = std.math.add(usize, length, std.math.cast(usize, scope.end - scope.start) orelse return error.LimitExceeded) catch return error.LimitExceeded;
    const prefix = try self.alloc(length);
    var position: usize = 0;
    for (scopes[0..count]) |scope| {
        const size: usize = @intCast(scope.end - scope.start);
        try self.readAt(prefix[position..][0..size], scope.start);
        position += size;
    }
    var suffix: std.Io.Writer.Allocating = .init(self.allocator);
    defer suffix.deinit();
    for (0..count) |i| suffix.writer.print("</{s}>", .{scopes[count - i - 1].name}) catch return error.OutOfMemory;
    const endian = try self.encoding();
    if (endian) |order| {
        const units = std.unicode.utf8ToUtf16LeAlloc(self.allocator, suffix.written()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return error.InvalidXml,
        };
        defer self.allocator.free(units);
        const encoded = try self.alloc(units.len * 2);
        for (units, 0..) |unit, i| std.mem.writeInt(u16, encoded[i * 2 ..][0..2], std.mem.littleToNative(u16, unit), order);
        return .{ .prefix = prefix, .suffix = encoded, .ancestors = count };
    }
    return .{ .prefix = prefix, .suffix = try self.copy(suffix.written()), .ancestors = count };
}

fn readAt(self: *const IndexedReader, output: []u8, offset: u64) Error!void {
    if (offset > self.size or output.len > self.size - offset) return error.TruncatedSource;
    switch (self.source) {
        .bytes => |bytes| @memcpy(output, bytes[@intCast(offset)..][0..output.len]),
        .file => |file| if (try file.handle.readPositionalAll(file.io, output, offset) != output.len) return error.TruncatedSource,
    }
}

fn charge(self: *IndexedReader, bytes: usize) Error!void {
    if (bytes > self.remaining) return error.LimitExceeded;
    self.remaining -= bytes;
}

fn alloc(self: *IndexedReader, bytes: usize) Error![]u8 {
    try self.charge(bytes);
    return self.arena.allocator().alloc(u8, bytes);
}

fn copy(self: *IndexedReader, bytes: []const u8) Error![]const u8 {
    const result = try self.alloc(bytes.len);
    @memcpy(result, bytes);
    return result;
}

fn kindIndex(kind: model.Kind) usize {
    return if (kind == .spectrum) 0 else 1;
}

const FragmentAncestors = struct { prefix: []const u8, suffix: []const u8, ancestors: usize };
