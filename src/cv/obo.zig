//! Parses OBO 1.2 and 1.4 files into `Vocabulary` tables. Internal: `Vocabulary.parseObo` and the
//! vocabulary generator call it.
//!
//! Lines may continue with a trailing backslash; `!` starts a comment outside quotes, braces, and
//! brackets; values keep their escaped spelling in the source fields and are decoded in the
//! modeled ones. `[Term]` stanzas become terms, `[Typedef]` stanzas only reserve their IDs, and
//! other stanzas are refused. Terms are sorted by accession bytes, parents and relation targets
//! become table positions (or external identifiers when the file has no such term), and the
//! ancestor closure is computed, refusing a cycle in `is_a`.

const std = @import("std");
const Vocabulary = @import("vocabulary.zig");

/// The largest file `parse` accepts.
pub const MAX_BYTES = 32 * 1024 * 1024;

pub const Error = std.mem.Allocator.Error || error{
    TooLarge,
    InvalidObo,
    InvalidEscape,
    UnsupportedStanza,
    UnsupportedOboVersion,
    MissingField,
    DuplicateField,
    DuplicateId,
    MissingTerms,
    SourceVersionMismatch,
    Cycle,
};

const Record = struct {
    id: []const u8,
    name: []const u8,
    obsolete: bool = false,
    definition: ?Vocabulary.Text = null,
    synonyms: []const Vocabulary.Text = &.{},
    xrefs: []const Vocabulary.Text = &.{},
    parents: []const []const u8 = &.{},
    alternate_ids: []const []const u8 = &.{},
    replaced_by: []const []const u8 = &.{},
    consider: []const []const u8 = &.{},
    relationships: []const Edge = &.{},
    subsets: []const []const u8 = &.{},
    fields: []const Vocabulary.Field = &.{},
};

const Edge = struct { kind: []const u8, target: []const u8, modifiers: []const u8 };

/// Fills `core` and `parsed` with tables in `allocator`, an arena the caller frees as one.
pub fn parse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    identity: Vocabulary.Identity,
    core: *Vocabulary.Core,
    parsed: *Vocabulary.Parsed,
) Error!void {
    if (bytes.len > MAX_BYTES) return error.TooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null)
        return error.InvalidObo;
    const source = try allocator.dupe(u8, bytes);
    var records: std.ArrayList(Record) = .empty;
    var headers: std.ArrayList(Vocabulary.Field) = .empty;
    var fields: std.ArrayList(Vocabulary.Field) = .empty;
    var reserved: std.StringHashMapUnmanaged(void) = .empty;
    var stanza: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |physical| {
        var line = trimUnescapedEnd(std.mem.trimStart(u8, std.mem.trimEnd(u8, physical, "\r"), " \t"));
        if (line.len == 0 or line[0] == '!') continue;
        var continuation: std.ArrayList(u8) = .empty;
        while (continued(line)) {
            try continuation.appendSlice(allocator, line[0 .. line.len - 1]);
            line = std.mem.trimEnd(u8, lines.next() orelse return error.InvalidObo, "\r");
        }
        if (continuation.items.len != 0) {
            try continuation.appendSlice(allocator, line);
            line = continuation.items;
        }
        line = try content(line);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return error.InvalidObo;
            if (stanza) |kind| try finishStanza(allocator, kind, fields.items, &records, &reserved);
            fields = .empty;
            stanza = line[1 .. line.len - 1];
            if (!std.mem.eql(u8, stanza.?, "Term") and !std.mem.eql(u8, stanza.?, "Typedef"))
                return error.UnsupportedStanza;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidObo;
        if (colon == 0) return error.InvalidObo;
        const tag = line[0..colon];
        for (tag) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-')
            return error.InvalidObo;
        const value = trimUnescapedEnd(std.mem.trimStart(u8, line[colon + 1 ..], " \t\r"));
        if (value.len == 0) return error.InvalidObo;
        const field: Vocabulary.Field = .{ .tag = tag, .value = value };
        if (stanza == null) try headers.append(allocator, field) else try fields.append(allocator, field);
    }
    if (stanza) |kind| try finishStanza(allocator, kind, fields.items, &records, &reserved);
    const format = try required(headers.items, "format-version");
    if (!std.mem.eql(u8, format, "1.2") and !std.mem.eql(u8, format, "1.4"))
        return error.UnsupportedOboVersion;
    const version = try required(headers.items, "data-version");
    if (identity.source_version.len != 0 and !std.mem.eql(u8, version, identity.source_version))
        return error.SourceVersionMismatch;
    if (records.items.len == 0) return error.MissingTerms;
    std.mem.sort(Record, records.items, {}, struct {
        fn less(_: void, a: Record, b: Record) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.less);
    try build(allocator, records.items, headers.items, &reserved, core, parsed);
}

fn build(
    allocator: std.mem.Allocator,
    records: []const Record,
    headers: []const Vocabulary.Field,
    reserved: *std.StringHashMapUnmanaged(void),
    core: *Vocabulary.Core,
    parsed: *Vocabulary.Parsed,
) Error!void {
    var positions: std.StringHashMapUnmanaged(u32) = .empty;
    try positions.ensureTotalCapacity(allocator, @intCast(records.len));
    for (records, 0..) |record, index| positions.putAssumeCapacity(record.id, @intCast(index));

    var ids: StringsBuilder = .{};
    var names: StringsBuilder = .{};
    const obsolete = try allocator.alloc(bool, records.len);
    var subset_names: std.ArrayList([]const u8) = .empty;
    var subsets: ListsBuilder(u8) = .{};
    var parents: ListsBuilder(u32) = .{};
    var relation_kinds: std.ArrayList([]const u8) = .empty;
    var relations: ListsBuilder(Vocabulary.Relation) = .{};
    var externals: std.ArrayList([]const u8) = .empty;
    var external_positions: std.StringHashMapUnmanaged(u32) = .empty;
    var modifiers: StringsBuilder = .{};
    var definitions: TextListsBuilder = .{};
    var synonyms: TextListsBuilder = .{};
    var xrefs: TextListsBuilder = .{};
    var identifiers: StringsBuilder = .{};
    var alternate_ids: ListsBuilder(u32) = .{};
    var replaced_by: ListsBuilder(u32) = .{};
    var consider: ListsBuilder(u32) = .{};
    var tags: StringsBuilder = .{};
    var values: StringsBuilder = .{};
    var field_lists: ListsBuilder(u32) = .{};
    var aliases: std.ArrayList(struct { id: []const u8, term: u32 }) = .empty;

    for (records, 0..) |record, index| {
        try ids.append(allocator, record.id);
        try names.append(allocator, record.name);
        obsolete[index] = record.obsolete;
        for (record.subsets) |subset| {
            const position = for (subset_names.items, 0..) |known, k| {
                if (std.mem.eql(u8, known, subset)) break k;
            } else blk: {
                if (subset_names.items.len == std.math.maxInt(u8)) return error.InvalidObo;
                try subset_names.append(allocator, subset);
                break :blk subset_names.items.len - 1;
            };
            try subsets.append(allocator, @intCast(position));
        }
        try subsets.close(allocator);
        for (record.parents) |parent|
            try parents.append(allocator, try targetIndex(allocator, parent, &positions, &externals, &external_positions));
        try parents.close(allocator);
        for (record.relationships) |edge| {
            const kind = for (relation_kinds.items, 0..) |known, k| {
                if (std.mem.eql(u8, known, edge.kind)) break k;
            } else blk: {
                try relation_kinds.append(allocator, edge.kind);
                break :blk relation_kinds.items.len - 1;
            };
            try relations.append(allocator, .{
                .kind = @intCast(kind),
                .target = try targetIndex(allocator, edge.target, &positions, &externals, &external_positions),
            });
            try modifiers.append(allocator, edge.modifiers);
        }
        try relations.close(allocator);
        if (record.definition) |text| try definitions.append(allocator, text);
        try definitions.close(allocator);
        for (record.synonyms) |text| try synonyms.append(allocator, text);
        try synonyms.close(allocator);
        for (record.xrefs) |text| try xrefs.append(allocator, text);
        try xrefs.close(allocator);
        inline for (.{ .{ record.alternate_ids, &alternate_ids }, .{ record.replaced_by, &replaced_by }, .{ record.consider, &consider } }) |pair| {
            for (pair[0]) |identifier| {
                try pair[1].append(allocator, @intCast(identifiers.count()));
                try identifiers.append(allocator, identifier);
            }
            try pair[1].close(allocator);
        }
        for (record.alternate_ids) |alias| {
            if (positions.contains(alias) or reserved.contains(alias)) return error.DuplicateId;
            try reserved.put(allocator, alias, {});
            try aliases.append(allocator, .{ .id = alias, .term = @intCast(index) });
        }
        for (record.fields) |field| {
            try field_lists.append(allocator, @intCast(tags.count()));
            try tags.append(allocator, field.tag);
            try values.append(allocator, field.value);
        }
        try field_lists.close(allocator);
    }
    std.mem.sort(@TypeOf(aliases.items[0]), aliases.items, {}, struct {
        fn less(_: void, a: @TypeOf(aliases.items[0]), b: @TypeOf(aliases.items[0])) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.less);
    var alias_ids: StringsBuilder = .{};
    const alias_terms = try allocator.alloc(u32, aliases.items.len);
    for (aliases.items, alias_terms) |alias, *term| {
        try alias_ids.append(allocator, alias.id);
        term.* = alias.term;
    }
    var header_tags: StringsBuilder = .{};
    var header_values: StringsBuilder = .{};
    for (headers) |field| {
        try header_tags.append(allocator, field.tag);
        try header_values.append(allocator, field.value);
    }
    core.* = .{
        .ids = ids.done(),
        .names = names.done(),
        .obsolete = obsolete,
        .subset_names = try strings(allocator, subset_names.items),
        .subsets = subsets.done(),
        .aliases = alias_ids.done(),
        .alias_terms = alias_terms,
        .parents = parents.done(),
        .relation_kinds = try strings(allocator, relation_kinds.items),
        .relations = relations.done(),
        .externals = try strings(allocator, externals.items),
    };
    parsed.* = .{
        .closure = try closure(allocator, core.parents),
        .details = .{
            .definitions = definitions.done(),
            .synonyms = synonyms.done(),
            .xrefs = xrefs.done(),
            .alternate_ids = alternate_ids.done(),
            .replaced_by = replaced_by.done(),
            .consider = consider.done(),
            .identifiers = identifiers.done(),
            .relation_modifiers = modifiers.done(),
            .header_tags = header_tags.done(),
            .header_values = header_values.done(),
        },
        .source = .{ .fields = field_lists.done(), .tags = tags.done(), .values = values.done() },
    };
}

// A target's table position, or its index among the external identifiers with EXTERNAL set.
fn targetIndex(
    allocator: std.mem.Allocator,
    id: []const u8,
    positions: *const std.StringHashMapUnmanaged(u32),
    externals: *std.ArrayList([]const u8),
    external_positions: *std.StringHashMapUnmanaged(u32),
) Error!u32 {
    if (positions.get(id)) |index| return index;
    const found = try external_positions.getOrPut(allocator, id);
    if (!found.found_existing) {
        found.value_ptr.* = @intCast(externals.items.len);
        try externals.append(allocator, id);
    }
    return Vocabulary.EXTERNAL | found.value_ptr.*;
}

// Every term's ancestors through `is_a`, sorted by position; refuses a cycle.
fn closure(allocator: std.mem.Allocator, parents: Vocabulary.Lists(u32)) Error!Vocabulary.Closure {
    const terms = parents.starts.len - 1;
    const state = try allocator.alloc(enum(u2) { unseen, active, done }, terms);
    @memset(state, .unseen);
    const ancestors = try allocator.alloc([]const u32, terms);
    var scratch: std.ArrayList(u32) = .empty;
    // An explicit stack of terms whose ancestors are being collected, parents first.
    var stack: std.ArrayList(u32) = .empty;
    for (0..terms) |root| {
        if (state[root] == .done) continue;
        try stack.append(allocator, @intCast(root));
        while (stack.items.len != 0) {
            const index = stack.items[stack.items.len - 1];
            if (state[index] == .done) {
                _ = stack.pop();
                continue;
            }
            state[index] = .active;
            var pending = false;
            for (parents.get(index)) |parent| {
                if (parent & Vocabulary.EXTERNAL != 0) continue;
                switch (state[parent]) {
                    .active => return error.Cycle,
                    .unseen => {
                        try stack.append(allocator, parent);
                        pending = true;
                    },
                    .done => {},
                }
            }
            if (pending) continue;
            scratch.clearRetainingCapacity();
            for (parents.get(index)) |parent| {
                if (parent & Vocabulary.EXTERNAL != 0) continue;
                try scratch.append(allocator, parent);
                try scratch.appendSlice(allocator, ancestors[parent]);
            }
            std.mem.sort(u32, scratch.items, {}, std.sort.asc(u32));
            var unique: usize = 0;
            for (scratch.items) |value| {
                if (unique != 0 and scratch.items[unique - 1] == value) continue;
                scratch.items[unique] = value;
                unique += 1;
            }
            ancestors[index] = try allocator.dupe(u32, scratch.items[0..unique]);
            state[index] = .done;
            _ = stack.pop();
        }
    }
    var lists: ListsBuilder(u32) = .{};
    for (ancestors) |list| {
        try lists.items.appendSlice(allocator, list);
        try lists.close(allocator);
    }
    return lists.done();
}

fn strings(allocator: std.mem.Allocator, items: []const []const u8) Error!Vocabulary.Strings {
    var builder: StringsBuilder = .{};
    for (items) |item| try builder.append(allocator, item);
    return builder.done();
}

const StringsBuilder = struct {
    text: std.ArrayList(u8) = .empty,
    starts: std.ArrayList(u32) = .empty,

    // Strings appended so far; `starts` holds one more entry once there is any.
    fn count(self: *const StringsBuilder) usize {
        return self.starts.items.len -| 1;
    }

    fn append(self: *StringsBuilder, allocator: std.mem.Allocator, value: []const u8) Error!void {
        if (self.starts.items.len == 0) try self.starts.append(allocator, 0);
        try self.text.appendSlice(allocator, value);
        try self.starts.append(allocator, @intCast(self.text.items.len));
    }

    fn done(self: StringsBuilder) Vocabulary.Strings {
        if (self.starts.items.len == 0) return .{};
        return .{ .text = self.text.items, .starts = self.starts.items };
    }
};

fn ListsBuilder(comptime T: type) type {
    return struct {
        starts: std.ArrayList(u32) = .empty,
        items: std.ArrayList(T) = .empty,

        fn append(self: *@This(), allocator: std.mem.Allocator, item: T) Error!void {
            try self.items.append(allocator, item);
        }

        // Ends the current term's list.
        fn close(self: *@This(), allocator: std.mem.Allocator) Error!void {
            if (self.starts.items.len == 0) try self.starts.append(allocator, 0);
            try self.starts.append(allocator, @intCast(self.items.items.len));
        }

        fn done(self: @This()) Vocabulary.Lists(T) {
            if (self.starts.items.len == 0) return .{};
            return .{ .starts = self.starts.items, .items = self.items.items };
        }
    };
}

const TextListsBuilder = struct {
    starts: std.ArrayList(u32) = .empty,
    values: StringsBuilder = .{},
    suffixes: StringsBuilder = .{},
    total: u32 = 0,

    fn append(self: *TextListsBuilder, allocator: std.mem.Allocator, text: Vocabulary.Text) Error!void {
        try self.values.append(allocator, text.value);
        try self.suffixes.append(allocator, text.suffix);
        self.total += 1;
    }

    fn close(self: *TextListsBuilder, allocator: std.mem.Allocator) Error!void {
        if (self.starts.items.len == 0) try self.starts.append(allocator, 0);
        try self.starts.append(allocator, self.total);
    }

    fn done(self: TextListsBuilder) Vocabulary.TextLists {
        if (self.starts.items.len == 0) return .{};
        return .{ .starts = self.starts.items, .values = self.values.done(), .suffixes = self.suffixes.done() };
    }
};

fn continued(line: []const u8) bool {
    var backslashes: usize = 0;
    var i = line.len;
    while (i > 0 and line[i - 1] == '\\') : (i -= 1) backslashes += 1;
    return backslashes % 2 != 0;
}

fn trimUnescapedEnd(raw: []const u8) []const u8 {
    var end = raw.len;
    while (end != 0 and std.mem.indexOfScalar(u8, " \t\r", raw[end - 1]) != null) {
        if (continued(raw[0 .. end - 1])) break;
        end -= 1;
    }
    return raw[0..end];
}

fn content(line: []const u8) Error![]const u8 {
    var quoted = false;
    var escaped = false;
    var braces: usize = 0;
    var brackets: usize = 0;
    for (line, 0..) |byte, i| {
        if (escaped) {
            escaped = false;
        } else if (byte == '\\') {
            escaped = true;
        } else if (byte == '"') {
            quoted = !quoted;
        } else if (!quoted) {
            switch (byte) {
                '!' => {
                    if (braces != 0 or brackets != 0) return error.InvalidObo;
                    return trimUnescapedEnd(line[0..i]);
                },
                '{' => braces += 1,
                '}' => if (braces == 0) {
                    return error.InvalidObo;
                } else {
                    braces -= 1;
                },
                '[' => brackets += 1,
                ']' => if (brackets == 0) {
                    return error.InvalidObo;
                } else {
                    brackets -= 1;
                },
                else => {},
            }
        }
    }
    if (escaped or quoted or braces != 0 or brackets != 0) return error.InvalidObo;
    return trimUnescapedEnd(line);
}

fn escape(byte: u8) u8 {
    return switch (byte) {
        'n' => '\n',
        't' => '\t',
        'W' => ' ',
        // OBO permits escaping any character; PSI-MS uses this in regexp definitions.
        else => byte,
    };
}

fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, bytes, '\\') == null) return bytes;
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\\') {
            i += 1;
            if (i == bytes.len) return error.InvalidEscape;
            try result.append(allocator, escape(bytes[i]));
        } else try result.append(allocator, bytes[i]);
    }
    return result.items;
}

// The single value of a field the stanza must have.
fn required(fields: []const Vocabulary.Field, tag: []const u8) Error![]const u8 {
    var found: ?[]const u8 = null;
    for (fields) |field| if (std.mem.eql(u8, field.tag, tag)) {
        if (found != null) return error.DuplicateField;
        found = field.value;
    };
    return found orelse error.MissingField;
}

fn quotedText(allocator: std.mem.Allocator, raw: []const u8) Error!Vocabulary.Text {
    if (raw.len < 2 or raw[0] != '"') return error.InvalidObo;
    var i: usize = 1;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') {
            i += 1;
            continue;
        }
        if (raw[i] == '"') return .{
            .value = try decode(allocator, raw[1..i]),
            .suffix = trimUnescapedEnd(std.mem.trimStart(u8, raw[i + 1 ..], " \t")),
        };
    }
    return error.InvalidObo;
}

fn token(raw: []const u8) Vocabulary.Text {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') {
            i += 1;
            continue;
        }
        if (raw[i] == ' ' or raw[i] == '\t' or raw[i] == '{') break;
    }
    return .{ .value = raw[0..@min(i, raw.len)], .suffix = trimUnescapedEnd(std.mem.trimStart(u8, raw[@min(i, raw.len)..], " \t")) };
}

fn targetToken(raw: []const u8) Error!Vocabulary.Text {
    const parsed = token(raw);
    if (parsed.value.len == 0 or (parsed.suffix.len != 0 and parsed.suffix[0] != '{'))
        return error.InvalidObo;
    return parsed;
}

fn nameText(raw: []const u8) []const u8 {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') {
            i += 1;
            continue;
        }
        if (raw[i] == '{') return trimUnescapedEnd(raw[0..i]);
    }
    return raw;
}

fn finishStanza(
    allocator: std.mem.Allocator,
    kind: []const u8,
    fields: []const Vocabulary.Field,
    records: *std.ArrayList(Record),
    reserved: *std.StringHashMapUnmanaged(void),
) Error!void {
    const id = try decode(allocator, (try targetToken(try required(fields, "id"))).value);
    if ((try reserved.getOrPut(allocator, id)).found_existing) return error.DuplicateId;
    if (!std.mem.eql(u8, kind, "Term")) return;
    var record: Record = .{
        .id = id,
        .name = try decode(allocator, nameText(try required(fields, "name"))),
        .fields = fields,
    };
    if (record.name.len == 0) return error.InvalidObo;
    var synonyms: std.ArrayList(Vocabulary.Text) = .empty;
    var xrefs: std.ArrayList(Vocabulary.Text) = .empty;
    var parents: std.ArrayList([]const u8) = .empty;
    var aliases: std.ArrayList([]const u8) = .empty;
    var replacements: std.ArrayList([]const u8) = .empty;
    var considerations: std.ArrayList([]const u8) = .empty;
    var subsets: std.ArrayList([]const u8) = .empty;
    var relationships: std.ArrayList(Edge) = .empty;
    var obsolete_seen = false;
    for (fields) |field| {
        const tag = field.tag;
        const raw = field.value;
        if (std.mem.eql(u8, tag, "def")) {
            if (record.definition != null) return error.DuplicateField;
            record.definition = try quotedText(allocator, raw);
            if (!std.mem.startsWith(u8, record.definition.?.suffix, "[")) return error.InvalidObo;
        } else if (std.mem.eql(u8, tag, "synonym")) {
            const text = try quotedText(allocator, raw);
            const scope = token(text.suffix);
            if (!std.mem.eql(u8, scope.value, "EXACT") and !std.mem.eql(u8, scope.value, "BROAD") and
                !std.mem.eql(u8, scope.value, "NARROW") and !std.mem.eql(u8, scope.value, "RELATED"))
                return error.InvalidObo;
            if (std.mem.indexOfScalar(u8, scope.suffix, '[') == null) return error.InvalidObo;
            try synonyms.append(allocator, text);
        } else if (std.mem.eql(u8, tag, "is_obsolete")) {
            if (obsolete_seen) return error.DuplicateField;
            obsolete_seen = true;
            const flag = try targetToken(raw);
            if (!std.mem.eql(u8, flag.value, "true") and !std.mem.eql(u8, flag.value, "false")) return error.InvalidObo;
            record.obsolete = std.mem.eql(u8, flag.value, "true");
        } else if (std.mem.eql(u8, tag, "relationship")) {
            const relation = token(raw);
            const target = try targetToken(relation.suffix);
            try relationships.append(allocator, .{
                .kind = try decode(allocator, relation.value),
                .target = try decode(allocator, target.value),
                .modifiers = target.suffix,
            });
        } else if (std.mem.eql(u8, tag, "xref")) {
            const text = token(raw);
            try xrefs.append(allocator, .{ .value = try decode(allocator, text.value), .suffix = text.suffix });
        } else {
            const list = if (std.mem.eql(u8, tag, "is_a")) &parents else if (std.mem.eql(u8, tag, "alt_id")) &aliases else if (std.mem.eql(u8, tag, "replaced_by")) &replacements else if (std.mem.eql(u8, tag, "consider")) &considerations else if (std.mem.eql(u8, tag, "subset")) &subsets else continue;
            const target = try targetToken(raw);
            try list.append(allocator, try decode(allocator, target.value));
        }
    }
    record.synonyms = synonyms.items;
    record.xrefs = xrefs.items;
    record.parents = parents.items;
    record.alternate_ids = aliases.items;
    record.replaced_by = replacements.items;
    record.consider = considerations.items;
    record.subsets = subsets.items;
    record.relationships = relationships.items;
    try records.append(allocator, record);
}
