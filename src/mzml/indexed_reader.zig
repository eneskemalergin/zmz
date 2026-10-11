//! Builds explicit record indexes over stable bytes or a borrowed regular file.
//!
//! Opening reads only the header and the embedded index, and a damaged or missing index is an
//! error, never a silent rebuild; rebuilding is its own policy and parses the file once. Each
//! lookup reads one record span using saved ancestor opening tags. Keep the source unchanged.

const std = @import("std");
const cv = @import("../cv/source.zig");
const xml = @import("../xml/mzml_adapter.zig");
const model = @import("model.zig");
const owned = @import("owned.zig");
const StreamReader = @import("stream_reader.zig").StreamReader;
const DecodedArrays = @import("decoded_arrays.zig");
const Diagnostic = @import("diagnostic.zig");
const Engine = @import("internal/reader_engine.zig");
const Ids = @import("internal/id_index.zig").IdIndex(Stored);

const IndexedReader = @This();

/// Immutable bytes or a regular-file handle, borrowed until `deinit`.
pub const Source = union(enum) {
    bytes: []const u8,
    file: struct { handle: std.Io.File, io: std.Io },
};

pub const Policy = enum { rebuild, open_embedded };

/// Bounds index storage and trailer parsing separately from header and record storage.
pub const Options = struct {
    policy: Policy = .open_embedded,
    records: usize = 1_000_000,
    index_bytes: usize = 256 * 1024 * 1024,
    /// Largest raw XML record span a lookup reads.
    record_span_bytes: usize = 256 * 1024 * 1024,
    /// Bounded backward search for indexListOffset when opening an embedded index.
    tail_bytes: usize = 64 * 1024,
    /// Applies to headers and returned records; index building skips payload text.
    reader: StreamReader.Options = .{},
};

/// Physical span and ID, borrowed from this index. `ordinal` is the zero-based lookup position
/// within the record kind (as `at` takes it), not the source record's index. With open_embedded,
/// start may precede XML whitespace and end bounds the span at the next target or trailer.
pub const Entry = struct { kind: model.Kind, id: []const u8, ordinal: usize, start: u64, end: u64 };

pub const Error = StreamReader.Error || owned.Error || std.Io.File.StatError || std.Io.File.ReadPositionalError || error{
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
entry_list: std.ArrayList(Stored) = .empty,
id_list: std.ArrayList(u8) = .empty,
// The embedded index listed chromatograms before spectra, so its entries are rotated.
chromatograms_first: bool = false,
ids: [2]Ids.Map = .{ .empty, .empty },
metadata: ?owned.Header = null,
contexts: [2]?FragmentAncestors = .{ null, null },
counts: [2]usize = .{ 0, 0 },
lookup_reader: ?Engine = null,
active: bool = false,
lookup_kind: ?model.Kind = null,
failure: ?Diagnostic = null,

/// Builds an index under `options.policy`, keeping metadata but no payloads. Do not copy the
/// returned reader: a copy and the original would free the same storage on deinit.
pub fn build(allocator: std.mem.Allocator, source: Source, options: Options) Error!IndexedReader {
    var failure: ?Diagnostic = null;
    return buildWithDiagnostic(allocator, source, options, &failure);
}

/// Clears failure on entry and fills it before cleanup if opening fails. The report
/// contains no borrowed data; its pointer is not kept by the returned reader.
pub fn buildWithDiagnostic(allocator: std.mem.Allocator, source: Source, options: Options, failure: *?Diagnostic) Error!IndexedReader {
    failure.* = null;
    errdefer |err| {
        if (failure.* == null) failure.* = Diagnostic.init(err, .open_index, .index, .none);
        failure.*.?.operation = if (options.policy == .rebuild) .rebuild_index else .open_index;
    }
    if (options.policy == .open_embedded and options.tail_bytes == 0)
        return error.InvalidOptions;
    // Entry positions and ID offsets are 32 bits.
    if (options.records > std.math.maxInt(u32) or options.index_bytes > std.math.maxInt(u32))
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
    errdefer failure.* = self.failure;
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
    var reader = try Engine.init(allocator, input, reader_options);
    defer reader.deinit();
    errdefer if (self.failure == null) {
        self.failure = reader.diagnostic();
    };
    const source_header = try reader.readHeader();
    if (options.policy != .rebuild and !source_header.indexed) return error.MissingIndex;
    if (options.policy == .open_embedded) {
        try self.openEmbedded(&reader);
    } else while (try reader.nextIndexRecord()) |record| {
        errdefer |err| {
            self.capture(err, .index, .none);
            self.failure.?.record = Diagnostic.RecordPosition.of(record.node.kind, self.counts[kindIndex(record.node.kind)]);
            self.failure.?.location = .{ .input_event = record.node.start_offset };
            self.failure.?.element = record.node.kind;
        }
        const k = kindIndex(record.node.kind);
        if (record.node.start_offset >= record.node.end_offset or record.node.end_offset > self.size)
            return error.InvalidIndex;
        if (self.contexts[k] == null) self.contexts[k] = try self.captureAncestors(&reader, k);
        try self.addEntry(record.node.kind, try self.entryId(record.id), record.node.start_offset, record.node.end_offset);
    }
    self.metadata = owned.Header.init(
        allocator,
        source_header.*,
        .{ .bytes = options.reader.limits.header_bytes },
    ) catch |err| return try self.headerCopyError(err);
    try self.checkSource();
    return self;
}

/// Leaves the source and returned records alive.
pub fn deinit(self: *IndexedReader) void {
    if (self.lookup_reader) |*reader| reader.deinit();
    if (self.metadata) |*metadata| metadata.deinit();
    self.entry_list.deinit(self.allocator);
    self.id_list.deinit(self.allocator);
    for (&self.ids) |*ids| ids.deinit(self.allocator);
    self.arena.deinit();
    self.* = undefined;
}

/// Returns how many entries the index holds, spectra first.
pub fn entryCount(self: *const IndexedReader) usize {
    return self.entry_list.items.len;
}

/// Returns the entry at a zero-based position, spectra first, or null at or past `entryCount`.
/// Its ID is valid until deinit.
pub fn entryAt(self: *const IndexedReader, position: usize) ?Entry {
    if (position >= self.entry_list.items.len) return null;
    const stored = self.entry_list.items[position];
    const chromatogram = position >= self.counts[0];
    return .{
        .kind = if (chromatogram) .chromatogram else .spectrum,
        .id = Ids.idOf(stored, self.id_list.items),
        .ordinal = if (chromatogram) position - self.counts[0] else position,
        .start = stored.start,
        .end = stored.end,
    };
}

/// Returns the header, valid until deinit. With `open_embedded`, list observed counts stay zero;
/// the index gives the record counts.
pub fn header(self: *const IndexedReader) *const model.Header {
    return &self.metadata.?.value;
}

/// Returns the last lookup failure. Each new lookup clears it, including an absent
/// target. A failure does not prevent later lookups; header access leaves it intact.
pub fn diagnostic(self: *const IndexedReader) ?Diagnostic {
    return self.failure;
}

/// Finds an exact ID and returns an independent record owner, or null when absent.
/// Returns AmbiguousId when both a spectrum and a chromatogram use this ID.
/// Lookups reuse parser storage: concurrent lookups on one reader are a data race, and a lookup
/// made inside another returns `InvalidState`.
pub fn byId(self: *IndexedReader, allocator: std.mem.Allocator, id: []const u8) Error!?owned.Record {
    return self.lookup(allocator, .{ .id = id }, null);
}

/// Looks up a zero-based ordinal within spectra or chromatograms; other kinds are
/// InvalidOptions.
pub fn at(self: *IndexedReader, allocator: std.mem.Allocator, kind: model.Kind, ordinal: usize) Error!?owned.Record {
    return self.lookup(allocator, .{ .ordinal = .{ .kind = kind, .ordinal = ordinal } }, null);
}

/// Like byId, decoding the selected arrays into output as StreamReader.nextDecodedRecord does,
/// without their binary text. An absent ID or a failure leaves output empty.
pub fn byIdDecoded(self: *IndexedReader, allocator: std.mem.Allocator, id: []const u8, output: *DecodedArrays) Error!?owned.Record {
    return self.lookup(allocator, .{ .id = id }, output);
}

/// Uses byIdDecoded's storage and failure rules for a zero-based spectrum or chromatogram ordinal.
pub fn atDecoded(
    self: *IndexedReader,
    allocator: std.mem.Allocator,
    kind: model.Kind,
    ordinal: usize,
    output: *DecodedArrays,
) Error!?owned.Record {
    return self.lookup(allocator, .{ .ordinal = .{ .kind = kind, .ordinal = ordinal } }, output);
}

fn entryId(self: *IndexedReader, id: []const u8) Error!Stored {
    if (self.entry_list.items.len == self.options.records) return try self.limitError(.records, self.options.records, null);
    try self.charge(@sizeOf(Stored) + @sizeOf(u32) * 4 + id.len);
    const id_start = self.id_list.items.len;
    try self.id_list.appendSlice(self.allocator, id);
    return .{ .id_start = @intCast(id_start), .id_len = @intCast(id.len), .start = 0, .end = 0 };
}

// Adds an entry whose ID entryId copied, unique within its kind.
fn addEntry(self: *IndexedReader, kind: model.Kind, copied: Stored, start: u64, end: u64) Error!void {
    const k = kindIndex(kind);
    if (self.entry_list.items.len == 0) self.chromatograms_first = kind == .chromatogram;
    var entry = copied;
    entry.start = start;
    entry.end = end;
    try Ids.insert(&self.ids[k], self.allocator, &self.entry_list, self.id_list.items, entry);
    self.counts[k] += 1;
}

fn captureAncestors(self: *IndexedReader, reader: *Engine, k: usize) Error!FragmentAncestors {
    const current_scopes = reader.scopes[0..reader.scope_count];
    var scopes: [4]Engine.Scope = undefined;
    @memcpy(scopes[0..current_scopes.len], current_scopes);
    scopes[0].start = 0;
    scopes[current_scopes.len] = reader.list_scopes[k].?;
    const count = current_scopes.len + 1;
    var length: usize = 0;
    for (scopes[0..count]) |scope| {
        const span = std.math.cast(usize, scope.end - scope.start) orelse return error.LimitExceeded;
        length = std.math.add(usize, length, span) catch return error.LimitExceeded;
    }
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

// An entry as stored: its ID addressed in id_list; kind and ordinal follow from its position.
const Stored = struct { id_start: u32, id_len: u32, start: u64, end: u64 };

const FragmentAncestors = struct { prefix: []const u8, suffix: []const u8, ancestors: usize };

fn openEmbedded(self: *IndexedReader, reader: *Engine) Error!void {
    const scopes = reader.scopes[0..reader.scope_count];
    const prefix_len = std.math.cast(usize, scopes[0].end) orelse return error.LimitExceeded;
    if (prefix_len > self.options.reader.limits.header_bytes)
        return try self.limitError(.header_bytes, self.options.reader.limits.header_bytes, prefix_len);
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
        if (!footerShape(tail, start, endian)) continue;
        const length = std.math.add(usize, prefix_len, tail.len - start) catch return error.LimitExceeded;
        const bytes = try self.allocator.alloc(u8, length);
        defer self.allocator.free(bytes);
        @memcpy(bytes[0..prefix_len], prefix);
        @memcpy(bytes[prefix_len..], tail[start..]);
        var footer_failure: ?Diagnostic = null;
        var parsed = Engine.parseFooter(
            self.allocator,
            bytes,
            trailer_options,
            physical_start,
            prefix_len,
            &footer_failure,
        ) catch |err| switch (err) {
            error.OutOfMemory, error.LimitExceeded => {
                self.failure = footer_failure;
                if (self.failure) |*report| if (report.detail == .limit and report.detail.limit.name == .header_bytes) {
                    report.detail.limit.name = .index_bytes;
                };
                return err;
            },
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
    if (trailer_len > self.options.index_bytes) return try self.limitError(.index_bytes, self.options.index_bytes, trailer_len);
    const bytes_len = std.math.add(usize, prefix_len, trailer_len) catch return error.LimitExceeded;
    var buffer: [64 * 1024]u8 = undefined;
    var input = FragmentInput.init(self, prefix, start, trailer_len, &.{}, buffer[0..@max(4, @min(buffer.len, bytes_len))]);
    self.readEmbeddedEntries(
        &input.interface,
        start,
        prefix_len,
        final_scope.end,
        endian,
    ) catch |err| return try self.inputError(&input, err);
    for (self.entry_list.items, 0..) |*entry, i| {
        if (i + 1 < self.entry_list.items.len) entry.end = self.entry_list.items[i + 1].start;
        if (entry.start >= entry.end) return error.InvalidIndex;
    }
    if (reader.list_scopes[0] != null) self.contexts[0] = try self.captureAncestors(reader, 0);
    if (reader.list_scopes[1] != null) self.contexts[1] = try self.captureAncestors(reader, 1);
    if (self.counts[1] != 0 and self.contexts[1] == null) {
        // Chromatograms listed in the index must follow an open spectrum list.
        if (reader.active_list != .spectrum_list) return error.InvalidIndex;
        if (self.counts[0] == 0) {
            try reader.finishEmptySpectrumList();
        } else {
            const last = self.entry_list.items[self.counts[0] - 1];
            const context = self.contexts[0] orelse return error.InvalidIndex;
            const span = std.math.cast(usize, last.end - last.start) orelse return error.LimitExceeded;
            if (span > self.options.record_span_bytes) return try self.limitError(.record_span_bytes, self.options.record_span_bytes, span);
            const fragment_len = std.math.add(usize, context.prefix.len, span) catch return error.LimitExceeded;
            var fragment = FragmentInput.init(
                self,
                context.prefix,
                last.start,
                span,
                &.{},
                buffer[0..@max(4, @min(buffer.len, fragment_len))],
            );
            reader.resumeFollowingList(&fragment.interface, context.ancestors, last.start, context.prefix.len) catch |err| {
                self.failure = reader.diagnostic();
                if (self.failure) |*report| report.translate(last.start, span, context.prefix.len);
                return try self.inputError(&fragment, err);
            };
        }
        self.contexts[1] = try self.captureAncestors(reader, 1);
    }
    const source_header = &reader.header;
    for ([_]?model.RecordList{ source_header.spectrum_list, source_header.chromatogram_list }, 0..) |list, k| {
        if (list != null) {
            if (self.counts[k] != 0) {
                const first = self.entry_list.items[if (k == 0) 0 else self.counts[0]];
                if (first.start < reader.list_scopes[k].?.end) return error.InvalidIndex;
            }
        } else if (self.counts[k] != 0) return error.InvalidIndex;
    }
}

fn trailerLimits(self: *const IndexedReader) StreamReader.Limits {
    var limits = self.options.reader.limits;
    limits.header_bytes = self.options.index_bytes;
    limits.list_entries = @max(2, self.options.records);
    limits.nodes = self.options.records +| 5;
    return limits;
}

fn readEmbeddedEntries(
    self: *IndexedReader,
    input: *std.Io.Reader,
    index_start: u64,
    prefix_length: usize,
    minimum: u64,
    endian: ?std.builtin.Endian,
) Error!void {
    const limits = self.options.reader.limits;
    var cursor = try xml.Cursor.init(self.allocator, input, limits.attributes, limits.attribute_bytes);
    defer cursor.deinit();
    errdefer |err| {
        self.capture(err, if (cursor.failure != null) .xml else .index, Diagnostic.xmlDetail(&cursor));
        self.failure.?.location = .{ .input_event = cursor.offset };
        self.failure.?.translate(index_start, self.size - index_start, prefix_length);
    }
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
        const name = (index.attribute(null, "name") orelse return try self.attributeError(.name)).value;
        const kind: model.Kind = if (std.mem.eql(u8, name, "spectrum"))
            .spectrum
        else if (std.mem.eql(u8, name, "chromatogram"))
            .chromatogram
        else
            return error.InvalidIndex;
        const k = kindIndex(kind);
        if (seen[k]) return error.InvalidIndex;
        seen[k] = true;
        var previous: u64 = 0;
        try cursor.advance(false);
        while ((cursor.current orelse return error.UnexpectedEnd).data == .start_element) {
            const offset = try indexStart(&cursor, .offset);
            errdefer |err| {
                self.capture(err, if (cursor.failure != null) .xml else .index, Diagnostic.xmlDetail(&cursor));
                self.failure.?.element = .offset;
                self.failure.?.record = Diagnostic.RecordPosition.of(kind, self.counts[k]);
            }
            // The attribute is borrowed from the cursor, so it is copied before reading on.
            const id = try self.entryId((offset.attribute(null, "idRef") orelse return try self.attributeError(.id_ref)).value);
            const target = try cv.parseInteger(u64, try self.indexText(&cursor, &text, .offset));
            if (target <= previous or target >= index_start or target < minimum or
                (endian != null and target % 2 != 0) or target > std.math.maxInt(i64)) return error.InvalidIndex;
            previous = target;
            try self.addEntry(kind, id, target, index_start);
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
    if (self.counts[0] != 0 and self.counts[1] != 0 and self.chromatograms_first) {
        std.mem.rotate(Stored, self.entry_list.items, self.counts[1]);
        // Move positions with their entries so each stored hash still names the same ID.
        var spectra = self.ids[0].keyIterator();
        while (spectra.next()) |position| position.* -= @intCast(self.counts[1]);
        var chromatograms = self.ids[1].keyIterator();
        while (chromatograms.next()) |position| position.* += @intCast(self.counts[0]);
    }
}

fn indexStart(cursor: *const xml.Cursor, kind: model.Kind) Error!xml.StartElement {
    const event = cursor.current orelse return error.UnexpectedEnd;
    if (event.data != .start_element or
        !event.data.start_element.name.eql(cursor.mzml_namespace, kind.xmlName())) return error.InvalidStructure;
    return event.data.start_element;
}

fn indexEnd(cursor: *xml.Cursor, kind: model.Kind) Error!void {
    const event = cursor.current orelse return error.UnexpectedEnd;
    if (event.data != .end_element or
        !event.data.end_element.name.eql(cursor.mzml_namespace, kind.xmlName())) return error.InvalidStructure;
    try cursor.advance(false);
}

fn indexText(self: *IndexedReader, cursor: *xml.Cursor, text: *std.ArrayList(u8), kind: model.Kind) Error![]const u8 {
    text.clearRetainingCapacity();
    try cursor.advance(true);
    while (cursor.current) |event| {
        if (event.data != .text) break;
        const fragment = event.data.text.bytes;
        const maximum = self.options.reader.limits.binary_text_bytes;
        if (fragment.len > maximum -| text.items.len)
            return try self.limitError(.binary_text_bytes, maximum, text.items.len +| fragment.len);
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

// Whether the tail from an indexListOffset candidate has the only shape a footer can have:
// the offset, fileChecksum, and the end of indexedmzML, apart only by whitespace, comments, and
// processing instructions, then nothing else. A decoy fails at its first wrong tag, so the
// search stays linear in the tail; the parse that follows still decides.
fn footerShape(bytes: []const u8, start: usize, endian: ?std.builtin.Endian) bool {
    var shape: FooterShape = .{ .bytes = bytes, .endian = endian, .position = start };
    return shape.element("indexListOffset") and shape.space() and
        shape.element("fileChecksum") and shape.space() and
        shape.tag(true, "indexedmzML") != .none and shape.space() and shape.position == bytes.len;
}

const FooterShape = struct {
    bytes: []const u8,
    endian: ?std.builtin.Endian,
    position: usize,

    fn width(self: *const FooterShape) usize {
        return if (self.endian != null) 2 else 1;
    }

    fn peek(self: *const FooterShape, ahead: usize) ?u16 {
        const offset = self.position + ahead * self.width();
        if (offset + self.width() > self.bytes.len) return null;
        return codeUnit(self.bytes, offset, self.endian);
    }

    fn skip(self: *FooterShape, units: usize) void {
        self.position += units * self.width();
    }

    fn startsWith(self: *const FooterShape, text: []const u8) bool {
        for (text, 0..) |byte, i| if (self.peek(i) != byte) return false;
        return true;
    }

    // Skips to just past end; false when the input ends first.
    fn skipPast(self: *FooterShape, end: []const u8) bool {
        while (self.peek(0) != null) : (self.skip(1)) {
            if (self.startsWith(end)) {
                self.skip(end.len);
                return true;
            }
        }
        return false;
    }

    // Whitespace, comments, and processing instructions.
    fn space(self: *FooterShape) bool {
        while (self.peek(0)) |unit| {
            if (unit == ' ' or unit == '\t' or unit == '\r' or unit == '\n') {
                self.skip(1);
            } else if (self.startsWith("<!--")) {
                if (!self.skipPast("-->")) return false;
            } else if (self.startsWith("<?")) {
                if (!self.skipPast("?>")) return false;
            } else break;
        }
        return true;
    }

    // An element with text and no children, or its empty form.
    fn element(self: *FooterShape, name: []const u8) bool {
        switch (self.tag(false, name)) {
            .none => return false,
            .empty => return true,
            .open => {},
        }
        while (self.peek(0)) |unit| : (self.skip(1)) if (unit == '<') break;
        return self.tag(true, name) != .none;
    }

    // A start or end tag whose local name is name, with any prefix and, for a start, attributes.
    fn tag(self: *FooterShape, closing: bool, name: []const u8) enum { none, open, empty } {
        if (self.peek(0) != '<') return .none;
        self.skip(1);
        if (closing) {
            if (self.peek(0) != '/') return .none;
            self.skip(1);
        }
        const name_start = self.position;
        while (self.peek(0)) |unit| : (self.skip(1)) {
            if (unit == '>' or unit == '/' or unit == ' ' or unit == '\t' or unit == '\r' or unit == '\n') break;
        }
        const units = (self.position - name_start) / self.width();
        if (units < name.len) return .none;
        const local = name_start + (units - name.len) * self.width();
        for (name, 0..) |byte, i| if (codeUnit(self.bytes, local + i * self.width(), self.endian) != byte) return .none;
        if (local != name_start and codeUnit(self.bytes, local - self.width(), self.endian) != ':') return .none;
        while (self.peek(0)) |unit| : (self.skip(1)) {
            if (unit == '<') return .none;
            if (unit == '>') {
                const empty = !closing and self.position >= self.width() and
                    codeUnit(self.bytes, self.position - self.width(), self.endian) == '/';
                self.skip(1);
                return if (empty) .empty else .open;
            }
        }
        return .none;
    }
};

fn codeUnit(bytes: []const u8, start: usize, endian: ?std.builtin.Endian) u16 {
    return if (endian) |order| std.mem.readInt(u16, bytes[start..][0..2], order) else bytes[start];
}

fn encoding(self: *const IndexedReader) Error!?std.builtin.Endian {
    var signature: [4]u8 = @splat(0);
    try self.readAt(signature[0..@intCast(@min(4, self.size))], 0);
    return if (signature[0] == 0xff or (signature[0] == '<' and signature[1] == 0))
        .little
    else if (signature[0] == 0xfe or (signature[0] == 0 and signature[1] == '<'))
        .big
    else
        null;
}

const Target = union(enum) { id: []const u8, ordinal: struct { kind: model.Kind, ordinal: usize } };

fn lookup(self: *IndexedReader, allocator: std.mem.Allocator, target: Target, output: ?*DecodedArrays) Error!?owned.Record {
    // Caller code runs inside a lookup (selection callbacks, the allocator, the source's Io);
    // it must leave the lookup and its output alone.
    if (self.active) return error.InvalidState;
    if (output) |decoded| if (decoded.busy) return error.InvalidState;
    self.active = true;
    defer self.active = false;
    self.failure = null;
    errdefer |err| self.capture(err, .index, .none);
    if (output) |decoded| decoded.reset();
    errdefer if (output) |decoded| decoded.reset();
    if (output) |decoded| decoded.busy = true;
    defer if (output) |decoded| {
        decoded.busy = false;
    };
    const position = try switch (target) {
        .id => |id| self.idPosition(id),
        .ordinal => |ordinal| self.ordinalPosition(ordinal.kind, ordinal.ordinal),
    } orelse return null;
    const record = try self.readEntry(allocator, self.entryAt(position).?, output);
    if (output) |decoded| decoded.complete();
    return record;
}

fn idPosition(self: *IndexedReader, id: []const u8) Error!?usize {
    try self.checkSource();
    const query: Ids.Query = .{ .entries = self.entry_list.items, .ids = self.id_list.items };
    const spectrum = self.ids[0].getKeyAdapted(id, query);
    const chromatogram = self.ids[1].getKeyAdapted(id, query);
    if (spectrum != null and chromatogram != null) return error.AmbiguousId;
    // The maps store u32 positions; the final orelse widens them to ?usize.
    return spectrum orelse chromatogram orelse null;
}

fn ordinalPosition(self: *IndexedReader, kind: model.Kind, ordinal: usize) Error!?usize {
    if (kind != .spectrum and kind != .chromatogram) return error.InvalidOptions;
    try self.checkSource();
    if (ordinal >= self.counts[kindIndex(kind)]) return null;
    return ordinal + if (kind == .spectrum) @as(usize, 0) else self.counts[0];
}

fn readEntry(self: *IndexedReader, allocator: std.mem.Allocator, entry: Entry, output: ?*DecodedArrays) Error!owned.Record {
    errdefer |err| {
        self.capture(err, .index, .none);
        self.failure.?.record = Diagnostic.RecordPosition.of(entry.kind, entry.ordinal);
    }
    const context = self.contexts[kindIndex(entry.kind)].?;
    const length = std.math.cast(usize, entry.end - entry.start) orelse return error.LimitExceeded;
    if (length > self.options.record_span_bytes) return try self.limitError(.record_span_bytes, self.options.record_span_bytes, length);
    const prefix_end = std.math.add(usize, context.prefix.len, length) catch return error.LimitExceeded;
    const total = std.math.add(usize, prefix_end, context.suffix.len) catch return error.LimitExceeded;
    var buffer: [64 * 1024]u8 = undefined;
    const reuse_ancestors = self.lookup_kind == entry.kind;
    self.lookup_kind = null;
    var input = FragmentInput.init(
        self,
        if (reuse_ancestors) &.{} else context.prefix,
        entry.start,
        length,
        context.suffix,
        buffer[0..@max(4, @min(buffer.len, total))],
    );
    if (self.lookup_reader == null) {
        var empty_input = std.Io.Reader.fixed(&.{});
        self.lookup_reader = try Engine.init(self.allocator, &empty_input, self.options.reader);
        self.lookup_reader.?.cursor.resetEmpty();
    }
    // The lookup reader borrows the index's groups and the decoded output for this fragment only.
    const fragment_reader = &self.lookup_reader.?;
    const groups = self.header().groups;
    fragment_reader.header.groups = groups;
    fragment_reader.reference_groups = groups;
    fragment_reader.decoded_arrays = output;
    defer {
        fragment_reader.header.groups = &.{};
        fragment_reader.reference_groups = &.{};
        fragment_reader.decoded_arrays = null;
    }
    var record = fragment_reader.readFragment(
        allocator,
        &input.interface,
        context.ancestors,
        entry.start,
        context.prefix.len,
        self.options.policy != .open_embedded,
        reuse_ancestors,
        .{ .kind = entry.kind, .id = entry.id },
    ) catch |err| {
        self.failure = fragment_reader.diagnostic();
        if (self.failure) |*report| report.translate(entry.start, length, context.prefix.len);
        return try self.inputError(&input, err);
    };
    errdefer record.deinit();
    if (record.value.node.end_offset > entry.end or
        (self.options.policy == .rebuild and
            (record.value.node.start_offset != entry.start or record.value.node.end_offset != entry.end))) return error.InvalidIndex;
    try self.checkSource();
    self.lookup_kind = entry.kind;
    return record;
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

fn capture(self: *IndexedReader, err: Error, stage: Diagnostic.Stage, detail: Diagnostic.Detail) void {
    if (self.failure == null) self.failure = Diagnostic.init(err, .lookup_record, stage, detail);
}

fn limitError(self: *IndexedReader, name: Diagnostic.Limit, maximum: usize, needed: ?usize) Error!noreturn {
    self.capture(error.LimitExceeded, .index, .{ .limit = .{ .name = name, .maximum = maximum, .needed = needed } });
    return error.LimitExceeded;
}

fn attributeError(self: *IndexedReader, attribute: Diagnostic.Attribute) Error!noreturn {
    self.capture(error.MissingAttribute, .index, .{ .attribute = attribute });
    return error.MissingAttribute;
}

fn headerCopyError(self: *IndexedReader, err: owned.Error) Error!noreturn {
    self.capture(
        err,
        .metadata,
        if (err == error.LimitExceeded) .{
            .limit = .{ .name = .header_bytes, .maximum = self.options.reader.limits.header_bytes },
        } else .none,
    );
    return err;
}

fn inputError(self: *IndexedReader, input: *const FragmentInput, err: Error) Error!noreturn {
    const original = input.originalError(err);
    if (input.failure != null and err == error.ReadFailed) {
        self.failure = Diagnostic.init(original, .lookup_record, .index, .none);
    }
    return original;
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

fn readAt(self: *const IndexedReader, output: []u8, offset: u64) Error!void {
    if (offset > self.size or output.len > self.size - offset) return error.TruncatedSource;
    switch (self.source) {
        .bytes => |bytes| @memcpy(output, bytes[@intCast(offset)..][0..output.len]),
        .file => |file| if (try file.handle.readPositionalAll(file.io, output, offset) != output.len) return error.TruncatedSource,
    }
}

fn charge(self: *IndexedReader, bytes: usize) Error!void {
    if (bytes > self.remaining)
        return try self.limitError(.index_bytes, self.options.index_bytes, self.options.index_bytes - self.remaining +| bytes);
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
