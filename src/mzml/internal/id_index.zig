//! The IDs of one record kind's index entries, kept compactly and found by ID. Most mzML IDs are
//! fixed text around integers (`controllerType=0 controllerNumber=1 scan=17`), so an ID whose text
//! matches the previous ID's is stored as the change of each integer, one or two bytes each; any
//! other ID, and the first of every block, is stored whole. Decoding an ID reads at most `BLOCK`
//! records, and reading IDs in order reads one each. A position is the ID's insertion order, so
//! positions and the map's keys are 32 bits. The module is internal: the writer and
//! `IndexedReader` index records with it.

const std = @import("std");

/// IDs per block; a block starts with a whole ID, so a lookup decodes at most this many.
const BLOCK = 16;
/// Integers an ID may hold and still be stored as changes.
const MAX_NUMBERS = 8;
/// Digits an integer may have: any 18-digit value, and any difference of two, fits an i64.
const MAX_DIGITS = 18;

const WHOLE: u8 = 0;
const CHANGES: u8 = 1;

pub const IdIndex = struct {
    /// Encoded IDs in insertion order.
    encoded: std.ArrayList(u8) = .empty,
    /// Where each block starts in `encoded`.
    blocks: std.ArrayList(u64) = .empty,
    /// Each ID's hash, so the map rehashes and rejects most candidates without decoding.
    hashes: std.ArrayList(u32) = .empty,
    map: Map = .empty,
    /// The last ID added, the template for the next.
    previous: std.ArrayList(u8) = .empty,
    /// The last ID's integers, or null when it has none usable (see `numbersOf`).
    previous_numbers: ?Numbers = null,
    longest: usize = 0,
    /// Decoding space: the decoder's template, then a decoded ID, each `longest` bytes.
    scratch: std.ArrayList(u8) = .empty,
    /// The decoder after the last decoded position, whose template is in `scratch`; reused when
    /// the next decode is later in the same block.
    decoder: Decoder = .{ .offset = 0 },
    decoded: ?usize = null,
    /// The integers of the ID last prepared, when it can be stored as changes.
    prepared_numbers: Numbers = undefined,

    const Map = std.HashMapUnmanaged(u32, void, Context, std.hash_map.default_max_load_percentage);

    /// How an ID would be stored if it were added next; from `prepare`, valid until the index
    /// changes or prepares another ID.
    pub const Prepared = struct {
        position: usize,
        hash: u32,
        changes: bool,
        /// Bytes the ID adds to the encoded list.
        length: usize,
    };

    pub fn deinit(self: *IdIndex, allocator: std.mem.Allocator) void {
        self.encoded.deinit(allocator);
        self.blocks.deinit(allocator);
        self.hashes.deinit(allocator);
        self.map.deinit(allocator);
        self.previous.deinit(allocator);
        self.scratch.deinit(allocator);
        self.* = undefined;
    }

    pub fn count(self: *const IdIndex) usize {
        return self.hashes.items.len;
    }

    pub fn prepare(self: *IdIndex, id: []const u8) Prepared {
        const position = self.count();
        const changes = position % BLOCK != 0 and self.previous_numbers != null and
            matchTemplate(self.previous.items, &self.previous_numbers.?, id, &self.prepared_numbers);
        return .{
            .position = position,
            .hash = hashOf(id),
            .changes = changes,
            .length = if (changes) changesLength(&self.prepared_numbers, &self.previous_numbers.?) else wholeLength(id.len),
        };
    }

    /// Adds an ID prepared at this state at the next position, or returns `DuplicateId` when this
    /// index already holds it. Capacity comes first, so a failure leaves the index unchanged.
    pub fn add(self: *IdIndex, allocator: std.mem.Allocator, id: []const u8, prepared: Prepared) error{ OutOfMemory, DuplicateId }!void {
        const position = self.count();
        std.debug.assert(prepared.position == position and position < std.math.maxInt(u32));
        // Capacity is checked inline first: growing is rare, and the calls cost more than an ID.
        if (self.encoded.capacity - self.encoded.items.len < prepared.length)
            try self.encoded.ensureUnusedCapacity(allocator, prepared.length);
        if (position % BLOCK == 0) try self.blocks.ensureUnusedCapacity(allocator, 1);
        if (self.hashes.capacity == self.hashes.items.len) try self.hashes.ensureUnusedCapacity(allocator, 1);
        if (self.previous.capacity < id.len) try self.previous.ensureTotalCapacity(allocator, id.len);
        const longest = @max(self.longest, id.len);
        if (self.scratch.capacity < 2 * longest) {
            // A move loses the decoder's template.
            try self.scratch.ensureTotalCapacity(allocator, 2 * longest);
            self.decoded = null;
        }
        const found = try self.map.getOrPutContextAdapted(
            allocator,
            id,
            Query{ .index = self, .id_hash = prepared.hash },
            Context{ .hashes = self.hashes.items },
        );
        if (found.found_existing) return error.DuplicateId;
        found.key_ptr.* = @intCast(position);

        if (position % BLOCK == 0) self.blocks.appendAssumeCapacity(self.encoded.items.len);
        if (prepared.changes) {
            const numbers = &self.prepared_numbers;
            const previous = &self.previous_numbers.?;
            self.encoded.appendAssumeCapacity(CHANGES);
            for (numbers.values[0..numbers.len], previous.values[0..numbers.len]) |value, before|
                appendVarint(&self.encoded, zigzag(@as(i64, @intCast(value)) - @as(i64, @intCast(before))));
            previous.* = numbers.*;
        } else {
            self.encoded.appendAssumeCapacity(WHOLE);
            appendVarint(&self.encoded, id.len);
            self.encoded.appendSliceAssumeCapacity(id);
            self.previous_numbers = numbersOf(id);
        }
        self.hashes.appendAssumeCapacity(prepared.hash);
        self.previous.clearRetainingCapacity();
        self.previous.appendSliceAssumeCapacity(id);
        // The scratch regions are `longest` bytes each, so a longer ID moves the decoder's.
        if (longest != self.longest) self.decoded = null;
        self.longest = longest;
    }

    /// Returns the position of an ID, or null when this index does not hold it.
    pub fn find(self: *IdIndex, id: []const u8) ?u32 {
        return self.map.getKeyAdapted(id, Query{ .index = self, .id_hash = hashOf(id) });
    }

    /// Decodes the ID at a position into `out`, which holds at least `longest` bytes.
    pub fn idAt(self: *IdIndex, position: usize, out: []u8) []const u8 {
        std.debug.assert(position < self.count() and out.len >= self.longest);
        const template = self.scratch.allocatedSlice()[0..self.longest];
        var steps = position % BLOCK + 1;
        if (self.decoded != null and self.decoded.? <= position and self.decoded.? / BLOCK == position / BLOCK) {
            steps = position - self.decoded.?;
        } else {
            self.decoder = .{ .offset = @intCast(self.blocks.items[position / BLOCK]) };
        }
        for (0..steps) |_| self.decoder.step(self.encoded.items, template);
        self.decoded = position;
        return self.decoder.render(template, out);
    }

    /// Decodes the ID at a position into this index's scratch; valid until the next call that
    /// decodes or adds.
    pub fn get(self: *IdIndex, position: usize) []const u8 {
        return self.idAt(position, self.scratch.allocatedSlice()[self.longest..][0..self.longest]);
    }

    const Context = struct {
        hashes: []const u32,

        pub fn hash(self: Context, position: u32) u64 {
            return spread(self.hashes[position]);
        }

        pub fn eql(_: Context, left: u32, right: u32) bool {
            return left == right;
        }
    };

    const Query = struct {
        index: *IdIndex,
        id_hash: u32,

        pub fn hash(self: Query, _: []const u8) u64 {
            return spread(self.id_hash);
        }

        pub fn eql(self: Query, id: []const u8, position: u32) bool {
            if (self.index.hashes.items[position] != self.id_hash) return false;
            return std.mem.eql(u8, id, self.index.get(position));
        }
    };
};

/// An ID's integers and where their digit runs start and end, in order.
const Numbers = struct { values: [MAX_NUMBERS]u64, starts: [MAX_NUMBERS]u32, ends: [MAX_NUMBERS]u32, len: usize };

// Decodes IDs one after another from a block start; `template` holds the last whole ID.
const Decoder = struct {
    offset: usize,
    template_len: usize = 0,
    numbers: ?Numbers = null,
    /// The template's own integers, so an unchanged one is copied instead of formatted.
    template_values: [MAX_NUMBERS]u64 = undefined,
    whole: bool = true,

    fn step(self: *Decoder, encoded: []const u8, template: []u8) void {
        const tag = encoded[self.offset];
        self.offset += 1;
        if (tag == WHOLE) {
            const len: usize = @intCast(readVarint(encoded, &self.offset));
            @memcpy(template[0..len], encoded[self.offset..][0..len]);
            self.offset += len;
            self.template_len = len;
            self.numbers = numbersOf(template[0..len]);
            if (self.numbers) |numbers| self.template_values = numbers.values;
            self.whole = true;
            return;
        }
        std.debug.assert(tag == CHANGES);
        const numbers = &self.numbers.?;
        for (numbers.values[0..numbers.len]) |*value| {
            const change = unzigzag(readVarint(encoded, &self.offset));
            value.* = @intCast(@as(i64, @intCast(value.*)) + change);
        }
        self.whole = false;
    }

    // Writes the current ID: the whole ID, or the template with its integers replaced.
    fn render(self: *const Decoder, template: []const u8, out: []u8) []const u8 {
        const text = template[0..self.template_len];
        if (self.whole) {
            @memcpy(out[0..text.len], text);
            return out[0..text.len];
        }
        const numbers = &self.numbers.?;
        var written: usize = 0;
        var from: usize = 0;
        // Unchanged integers keep their template digits, copied with the text around them.
        for (0..numbers.len) |k| {
            const value = numbers.values[k];
            if (value == self.template_values[k]) continue;
            const start = numbers.starts[k];
            @memcpy(out[written..][0 .. start - from], text[from..start]);
            written += start - from;
            written += writeDecimal(out[written..], value);
            from = numbers.ends[k];
        }
        @memcpy(out[written..][0 .. text.len - from], text[from..]);
        return out[0 .. written + text.len - from];
    }
};

// The integers of an ID, or null when it has more than MAX_NUMBERS, one longer than MAX_DIGITS,
// or one with a leading zero (which a decimal rendering would lose).
fn numbersOf(id: []const u8) ?Numbers {
    var numbers: Numbers = .{ .values = undefined, .starts = undefined, .ends = undefined, .len = 0 };
    var i: usize = 0;
    while (i < id.len) {
        if (!std.ascii.isDigit(id[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < id.len and std.ascii.isDigit(id[i])) i += 1;
        if (numbers.len == MAX_NUMBERS) return null;
        numbers.values[numbers.len] = parseRun(id[start..i]) orelse return null;
        numbers.starts[numbers.len] = @intCast(start);
        numbers.ends[numbers.len] = @intCast(i);
        numbers.len += 1;
    }
    return numbers;
}

// Whether `id` is `previous` with only its integers changed, filling them if so: the text
// between the previous ID's digit runs must recur unchanged, each run must be a storable integer,
// and nothing else may differ.
fn matchTemplate(previous: []const u8, previous_numbers: *const Numbers, id: []const u8, numbers: *Numbers) bool {
    if (previous.len == id.len) if (matchSameLength(previous, previous_numbers, id, numbers)) |matched| return matched;
    numbers.len = previous_numbers.len;
    var i: usize = 0;
    var j: usize = 0;
    for (0..previous_numbers.len) |k| {
        const text = previous[i..previous_numbers.starts[k]];
        if (id.len - j < text.len or !std.mem.eql(u8, id[j..][0..text.len], text)) return false;
        j += text.len;
        const start = j;
        while (j < id.len and std.ascii.isDigit(id[j])) j += 1;
        numbers.values[k] = parseRun(id[start..j]) orelse return false;
        numbers.starts[k] = @intCast(start);
        numbers.ends[k] = @intCast(j);
        i = previous_numbers.ends[k];
    }
    return std.mem.eql(u8, id[j..], previous[i..]);
}

// The common case, an ID as long as the previous one: when they differ only in digits, they share
// their digit runs, and only a run holding a difference is parsed again. Null when a non-digit
// differs, which matchTemplate's general walk decides.
fn matchSameLength(previous: []const u8, previous_numbers: *const Numbers, id: []const u8, numbers: *Numbers) ?bool {
    numbers.* = previous_numbers.*;
    var k: usize = 0;
    var from: usize = 0;
    while (firstDifference(previous, id, from)) |at| {
        if (!std.ascii.isDigit(previous[at]) or !std.ascii.isDigit(id[at])) return null;
        while (numbers.ends[k] <= at) k += 1;
        numbers.values[k] = parseRun(id[numbers.starts[k]..numbers.ends[k]]) orelse return false;
        from = numbers.ends[k];
    }
    return true;
}

// The first position at or after `from` where two equally long slices differ, 16 bytes at a time.
fn firstDifference(a: []const u8, b: []const u8, from: usize) ?usize {
    const Vector = @Vector(16, u8);
    var i = from;
    while (a.len - i >= 16) : (i += 16) {
        const mask: u16 = @bitCast(@as(Vector, a[i..][0..16].*) != @as(Vector, b[i..][0..16].*));
        if (mask != 0) return i + @ctz(mask);
    }
    if (i == a.len) return null;
    if (a.len >= 16) {
        // The last 16 bytes overlap what was compared; the shift drops those lanes.
        const last = a.len - 16;
        const mask: u16 = @bitCast(@as(Vector, a[last..][0..16].*) != @as(Vector, b[last..][0..16].*));
        const rest = mask >> @intCast(i - last);
        return if (rest != 0) i + @ctz(rest) else null;
    }
    while (i < a.len) : (i += 1) if (a[i] != b[i]) return i;
    return null;
}

fn parseRun(run: []const u8) ?u64 {
    if (run.len == 0 or run.len > MAX_DIGITS or (run.len > 1 and run[0] == '0')) return null;
    var value: u64 = 0;
    for (run) |digit| value = value * 10 + (digit - '0');
    return value;
}

fn changesLength(numbers: *const Numbers, previous: *const Numbers) usize {
    var length: usize = 1;
    for (numbers.values[0..numbers.len], previous.values[0..numbers.len]) |value, before|
        length += varintLength(zigzag(@as(i64, @intCast(value)) - @as(i64, @intCast(before))));
    return length;
}

// Writes the digits straight into place, last first, once their count is known.
fn writeDecimal(out: []u8, value: u64) usize {
    var length: usize = 1;
    var bound: u64 = 10;
    while (length < 20 and value >= bound) : (length += 1) bound *%= 10;
    var rest = value;
    var i = length;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast('0' + rest % 10);
        rest /= 10;
    }
    return length;
}

fn wholeLength(len: usize) usize {
    return 1 + varintLength(len) + len;
}

fn hashOf(id: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0, id));
}

// Widens a stored 32-bit hash so the map's bucket bits and its fingerprint bits both vary.
fn spread(hash: u32) u64 {
    return @as(u64, hash) *% 0x9e3779b97f4a7c15;
}

fn zigzag(value: i64) u64 {
    return @bitCast((value << 1) ^ (value >> 63));
}

fn unzigzag(value: u64) i64 {
    return @as(i64, @bitCast(value >> 1)) ^ -@as(i64, @bitCast(value & 1));
}

fn varintLength(value: u64) usize {
    var rest = value;
    var length: usize = 1;
    while (rest >= 0x80) : (length += 1) rest >>= 7;
    return length;
}

fn appendVarint(list: *std.ArrayList(u8), value: u64) void {
    var rest = value;
    while (rest >= 0x80) : (rest >>= 7) list.appendAssumeCapacity(@as(u8, @truncate(rest)) | 0x80);
    list.appendAssumeCapacity(@intCast(rest));
}

fn readVarint(bytes: []const u8, offset: *usize) u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (true) : (shift += 7) {
        const byte = bytes[offset.*];
        offset.* += 1;
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte < 0x80) return value;
    }
}

fn expectRoundTrip(ids: []const []const u8) !void {
    const allocator = std.testing.allocator;
    var index: IdIndex = .{};
    defer index.deinit(allocator);
    for (ids, 0..) |id, position| {
        const before = index.encoded.items.len;
        const prepared = index.prepare(id);
        try index.add(allocator, id, prepared);
        try std.testing.expectEqual(prepared.length, index.encoded.items.len - before);
        try std.testing.expectEqual(@as(?u32, @intCast(position)), index.find(id));
    }
    const out = try allocator.alloc(u8, index.longest);
    defer allocator.free(out);
    for (ids, 0..) |id, position| {
        try std.testing.expectEqualStrings(id, index.idAt(position, out));
        try std.testing.expectEqualStrings(id, index.get(position));
        try std.testing.expectEqual(@as(?u32, @intCast(position)), index.find(id));
        try std.testing.expectError(error.DuplicateId, index.add(allocator, id, index.prepare(id)));
    }
    // In order, out of order, and backward, so the decoder is reused and restarted.
    for (ids, 0..) |id, position| try std.testing.expectEqualStrings(id, index.get(position));
    var position = ids.len;
    while (position > 0) {
        position -= 1;
        try std.testing.expectEqualStrings(ids[position], index.get(position));
        try std.testing.expectEqualStrings(ids[position / 2], index.get(position / 2));
    }
    try std.testing.expectEqual(ids.len, index.count());
}

test "[edge] - [mzML ID index]: gives back every ID exactly, whatever its digits" {
    try expectRoundTrip(&.{});
    try expectRoundTrip(&.{ "", "0", "1", "a", "a0", "a1" });
    // Templates that change mid-block, digit runs that cannot change, and runs at either end.
    try expectRoundTrip(&.{
        "controllerType=0 controllerNumber=1 scan=1",
        "controllerType=0 controllerNumber=1 scan=2",
        "controllerType=0 controllerNumber=1 scan=10",
        "controllerType=0 controllerNumber=1 scan=9",
        "scan=007",
        "scan=008",
        "scan=9",
        "scan=10",
        "12345678901234567890",
        "12345678901234567891",
        "123456789012345678",
        "123456789012345679",
        "0",
        "1 2 3 4 5 6 7 8",
        "1 2 3 4 5 6 7 9",
        "1 2 3 4 5 6 7 8 9",
        "1 2 3 4 5 6 7 8 10",
        "merged=0 frame=1 scanStart=0 scanEnd=927",
        "merged=1 frame=2 scanStart=30 scanEnd=70",
        "merged=2 frame=2 scanStart=85 scanEnd=125",
        // Equally long neighbours: digits that change in several runs, across 16-byte steps, to a
        // leading zero, and non-digits that move.
        "merged=10 frame=11 scanStart=30 scanEnd=70",
        "merged=11 frame=11 scanStart=31 scanEnd=71",
        "merged=11 frame=12 scanStart=31 scanEnd=79",
        "scan=20",
        "scan=09",
        "a1b22",
        "a12b2",
        "a12b3",
        "x\xffy1",
        "x\xffy2",
        "9a",
        "10a",
        "a9b",
        "a10b",
        "a",
        "",
    });
}

test "[property] - [mzML ID index]: keeps sequential IDs across many blocks and in both directions" {
    const allocator = std.testing.allocator;
    var ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    var state: u64 = 0x2545f4914f6cdd1d;
    for (0..1000) |i| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const jump = state >> 54;
        const id = switch (i % 4) {
            0 => try std.fmt.allocPrint(allocator, "sample=1 period=1 cycle={d} experiment={d}", .{ i / 4, jump % 40 }),
            1 => try std.fmt.allocPrint(allocator, "merged={d} frame={d} scanStart={d} scanEnd={d}", .{ i, i / 3, jump, jump + 40 }),
            2 => try std.fmt.allocPrint(allocator, "scan={d}", .{999_999_999_999_999_999 - i}),
            else => try std.fmt.allocPrint(allocator, "index={d}", .{i}),
        };
        try ids.append(allocator, id);
    }
    // Interleaved styles change template at every ID; one style throughout changes only integers.
    try expectRoundTrip(ids.items);
    var sequential: std.ArrayList([]const u8) = .empty;
    defer sequential.deinit(allocator);
    for (ids.items, 0..) |id, i| if (i % 4 == 1) try sequential.append(allocator, id);
    try expectRoundTrip(sequential.items);
}

test "[edge] - [mzML ID index]: tells IDs apart when their stored hashes collide" {
    const allocator = std.testing.allocator;
    // Among this many IDs some 32-bit hashes collide; each must still be its own entry.
    const count = 200_000;
    var index: IdIndex = .{};
    defer index.deinit(allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(allocator);
    var collisions: usize = 0;
    var buffer: [64]u8 = undefined;
    for (0..count) |i| {
        const id = try std.fmt.bufPrint(&buffer, "controllerType=0 controllerNumber=1 scan={d}", .{i});
        if ((try seen.getOrPut(allocator, hashOf(id))).found_existing) collisions += 1;
        try index.add(allocator, id, index.prepare(id));
    }
    try std.testing.expect(collisions > 0);
    for (0..count) |i| {
        const id = try std.fmt.bufPrint(&buffer, "controllerType=0 controllerNumber=1 scan={d}", .{i});
        try std.testing.expectEqual(@as(?u32, @intCast(i)), index.find(id));
    }
    try std.testing.expectEqual(null, index.find("controllerType=0 controllerNumber=1 scan=200000"));
    // A changes record is a tag and one byte per unchanged or stepped integer, here 4 bytes, and
    // every 16th ID is whole: under 7 bytes an ID where each is 45 to 48.
    try std.testing.expect(index.encoded.items.len < count * 7);
}

test "[failure] - [mzML ID index]: leaves the index unchanged when adding fails" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var index: IdIndex = .{};
            defer index.deinit(allocator);
            for ([_][]const u8{ "scan=1", "scan=2", "a long ID that grows the scratch", "scan=3" }) |id|
                try index.add(allocator, id, index.prepare(id));
            try std.testing.expectError(error.DuplicateId, index.add(allocator, "scan=2", index.prepare("scan=2")));
            try std.testing.expectEqualStrings("scan=3", index.get(3));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
