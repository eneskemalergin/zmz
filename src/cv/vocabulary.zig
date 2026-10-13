//! Provides immutable vocabulary lookup, the `is_a` graph, relations, and term metadata.
//!
//! Tables are grouped by use, and every call reaches only its group, so a program links only the
//! tables its calls need:
//!
//! - the core: IDs, names, obsolete flags, subsets, parents, and relations;
//! - the ancestor closure, for `isA`;
//! - details: definitions, synonyms, xrefs, alternate IDs, replacements, consider lists, relation
//!   modifiers, and the file's header fields;
//! - history: the releases a term was first present and obsolete in, and its former names;
//! - source fields: every stanza field as written, kept only by `parseObo`.
//!
//! The bundled resources (`cv.Resolver.BUNDLED`) are static. `parseObo` builds the same tables
//! from an OBO file at run time, so a program can use a newer release than it was built with.
//! Returned text and terms borrow from their resource.

const std = @import("std");
const generated_data = @import("generated_data.zig");
const obo = @import("obo.zig");

const Vocabulary = @This();

/// Provenance of the resource actually used, not a document's version claim.
pub const Identity = struct {
    key: []const u8,
    version: []const u8,
    namespace: []const u8,
    full_name: []const u8 = "",
    uri: []const u8 = "",
    source_version: []const u8 = "",
    repository: []const u8 = "",
    commit: []const u8 = "",
    path: []const u8 = "",
    retrieved: []const u8 = "",
    license: []const u8 = "",
    attribution: []const u8 = "",
    sha256: []const u8 = "",
    artifact_version: u32 = 1,
    counts: Counts = .{},
    /// Other URIs and full names that documents' `cv` declarations use for this resource.
    declaration_uris: []const []const u8 = &.{},
    declaration_names: []const []const u8 = &.{},
};

/// Snapshot-specific generation assertions; zero is a count, not a wildcard.
pub const Counts = struct {
    terms: usize = 0,
    native_terms: usize = 0,
    obsolete: usize = 0,
    alternate_ids: usize = 0,
    replacements: usize = 0,
    considerations: usize = 0,
    synonyms: usize = 0,
    value_types: usize = 0,
    units: usize = 0,
    binary_xrefs: usize = 0,
};

/// OBO text decoded from a quoted value or an xref identifier.
/// The suffix retains its OBO spelling (scope, references, and modifiers).
pub const Text = struct { value: []const u8, suffix: []const u8 = "" };

/// Uninterpreted OBO field with its escaped source spelling retained.
pub const Field = struct { tag: []const u8, value: []const u8 };

/// Graph failures are distinct from a completed negative query.
pub const GraphError = error{ UnknownTerm, Cycle, TraversalLimit, OutputTooSmall };

/// The table layout. Generated data and `parseObo` build it; callers read through `Term`.
pub const Strings = struct {
    text: []const u8 = "",
    /// String `i` is `text[starts[i]..starts[i + 1]]`; one more start than strings.
    starts: []const u32 = &.{0},

    pub fn count(self: Strings) usize {
        return self.starts.len - 1;
    }

    pub fn get(self: Strings, index: usize) []const u8 {
        return self.text[self.starts[index]..self.starts[index + 1]];
    }

    // The index of a string in a table sorted by bytes.
    fn find(self: Strings, value: []const u8) ?usize {
        var low: usize = 0;
        var high = self.count();
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, value, self.get(mid))) {
                .lt => high = mid,
                .gt => low = mid + 1,
                .eq => return mid,
            }
        }
        return null;
    }
};

/// Items grouped by term: term `i` owns `items[starts[i]..starts[i + 1]]`.
pub fn Lists(comptime T: type) type {
    return struct {
        starts: []const u32 = &.{0},
        items: []const T = &.{},

        pub fn get(self: @This(), index: usize) []const T {
            return self.items[self.starts[index]..self.starts[index + 1]];
        }
    };
}

/// Text items grouped by term; item `k` is `values.get(k)` with `suffixes.get(k)`.
pub const TextLists = struct {
    starts: []const u32 = &.{0},
    values: Strings = .{},
    suffixes: Strings = .{},

    fn get(self: TextLists, index: usize) TextIterator {
        return .{ .lists = self, .position = self.starts[index], .end = self.starts[index + 1] };
    }
};

/// A relation edge: its kind's index in `relation_kinds`, and a term index or, with `EXTERNAL`
/// set, an index into `externals` for targets outside the resource (such as `xsd:` types).
pub const Relation = struct { kind: u32, target: u32 };
pub const EXTERNAL: u32 = 1 << 31;

/// A former canonical name and the last release index that used it.
pub const FormerName = struct { release: u16, name: u32 };
pub const NO_RELEASE = std.math.maxInt(u16);

pub const Core = struct {
    /// Sorted by exact accession bytes, with no duplicate primary or alternate IDs.
    ids: Strings,
    names: Strings,
    obsolete: []const bool,
    subset_names: Strings = .{},
    /// Indexes into `subset_names`.
    subsets: Lists(u8) = .{},
    /// Sorted alternate IDs, each with its canonical term's index in `alias_terms`.
    aliases: Strings = .{},
    alias_terms: []const u32 = &.{},
    parents: Lists(u32),
    relation_kinds: Strings = .{},
    relations: Lists(Relation) = .{},
    externals: Strings = .{},
};

/// Every term's ancestors (not the term itself), sorted by index.
pub const Closure = Lists(u32);

pub const Details = struct {
    /// At most one per term.
    definitions: TextLists = .{},
    synonyms: TextLists = .{},
    xrefs: TextLists = .{},
    alternate_ids: Lists(u32) = .{},
    replaced_by: Lists(u32) = .{},
    consider: Lists(u32) = .{},
    /// The identifiers the three lists above index.
    identifiers: Strings = .{},
    /// Parallel to `Core.relations.items`.
    relation_modifiers: Strings = .{},
    header_tags: Strings = .{},
    header_values: Strings = .{},
};

pub const History = struct {
    /// Releases in order, oldest first.
    releases: Strings,
    /// Release indexes ordered by release text, for search.
    by_text: []const u16,
    /// Per term, the first release index present, or `NO_RELEASE` when the term predates the
    /// first recorded release.
    first: []const u16,
    /// Per term, the first release index where it was obsolete, or `NO_RELEASE`.
    obsolete_since: []const u16,
    former: Lists(FormerName) = .{},
    former_names: Strings = .{},
};

/// Every stanza field as written; `parseObo` keeps it, bundled resources do not.
pub const Source = struct {
    fields: Lists(u32) = .{},
    tags: Strings = .{},
    values: Strings = .{},
};

/// Where the tables beyond the core are.
pub const Tiers = union(enum) {
    /// Position in the generated per-tier tables.
    bundled: usize,
    parsed: *const Parsed,
};

pub const Parsed = struct {
    closure: Closure,
    details: Details,
    source: Source,
};

identity: Identity,
core: *const Core,
tiers: Tiers,

/// A term of a resource; valid while its resource is.
pub const Term = struct {
    resource: *const Vocabulary,
    index: u32,

    pub fn id(self: Term) []const u8 {
        return self.resource.core.ids.get(self.index);
    }

    pub fn name(self: Term) []const u8 {
        return self.resource.core.names.get(self.index);
    }

    pub fn obsolete(self: Term) bool {
        return self.resource.core.obsolete[self.index];
    }

    pub fn eql(self: Term, other: Term) bool {
        return self.resource == other.resource and self.index == other.index;
    }

    /// The OBO subsets the term belongs to, such as `core` or `mzQC` in PSI-MS.
    pub fn subsets(self: Term) StringIterator {
        const core = self.resource.core;
        return .{ .indexes = .{ .u8s = core.subsets.get(self.index) }, .strings = core.subset_names };
    }

    pub fn inSubset(self: Term, subset: []const u8) bool {
        var all = self.subsets();
        while (all.next()) |value| if (std.mem.eql(u8, value, subset)) return true;
        return false;
    }

    /// Direct `is_a` parents.
    pub fn parents(self: Term) TermIterator {
        return .{ .resource = self.resource, .indexes = self.resource.core.parents.get(self.index) };
    }

    /// Every ancestor through `is_a`, in table order.
    pub fn ancestors(self: Term) TermIterator {
        return .{ .resource = self.resource, .indexes = self.resource.closureTable().get(self.index) };
    }

    /// Direct targets of one relation; `is_a` selects the parents.
    pub fn targets(self: Term, relation: []const u8) Targets {
        const core = self.resource.core;
        if (std.mem.eql(u8, relation, "is_a"))
            return .{ .resource = self.resource, .parents = core.parents.get(self.index) };
        var kind: ?u32 = null;
        for (0..core.relation_kinds.count()) |k| {
            if (std.mem.eql(u8, core.relation_kinds.get(k), relation)) kind = @intCast(k);
        }
        return .{ .resource = self.resource, .kind = kind, .edges = if (kind == null) &.{} else core.relations.get(self.index) };
    }

    /// Every relation edge with its kind, target, and source modifiers.
    pub fn relationships(self: Term) Relationships {
        const core = self.resource.core;
        return .{
            .resource = self.resource,
            .edges = core.relations.get(self.index),
            .first = core.relations.starts[self.index],
        };
    }

    pub fn definition(self: Term) ?Text {
        var all = self.resource.detailTables().definitions.get(self.index);
        return all.next();
    }

    pub fn synonyms(self: Term) TextIterator {
        return self.resource.detailTables().synonyms.get(self.index);
    }

    pub fn xrefs(self: Term) TextIterator {
        return self.resource.detailTables().xrefs.get(self.index);
    }

    /// This term's own alternate identifiers (`lookup` finds the term by any of them).
    pub fn alternateIds(self: Term) StringIterator {
        const tables = self.resource.detailTables();
        return .{ .indexes = .{ .u32s = tables.alternate_ids.get(self.index) }, .strings = tables.identifiers };
    }

    /// Suggested replacements of an obsolete term; guidance, not a rewrite.
    pub fn replacedBy(self: Term) StringIterator {
        const tables = self.resource.detailTables();
        return .{ .indexes = .{ .u32s = tables.replaced_by.get(self.index) }, .strings = tables.identifiers };
    }

    pub fn consider(self: Term) StringIterator {
        const tables = self.resource.detailTables();
        return .{ .indexes = .{ .u32s = tables.consider.get(self.index) }, .strings = tables.identifiers };
    }

    /// The first recorded release the term was present in; null when its history is not
    /// recorded or the term predates the first recorded release.
    pub fn firstRelease(self: Term) ?[]const u8 {
        const recorded = self.resource.historyTables() orelse return null;
        return release(recorded, recorded.first[self.index]);
    }

    /// The first recorded release the term was obsolete in, or null.
    pub fn obsoleteSince(self: Term) ?[]const u8 {
        const recorded = self.resource.historyTables() orelse return null;
        return release(recorded, recorded.obsolete_since[self.index]);
    }

    /// Canonical names the term had in earlier recorded releases, each with the last release
    /// that used it.
    pub fn formerNames(self: Term) FormerNames {
        const recorded = self.resource.historyTables() orelse return .{ .history = null, .entries = &.{} };
        return .{ .history = recorded, .entries = recorded.former.get(self.index) };
    }

    /// Every field of the term's stanza as written; empty for bundled resources.
    pub fn fields(self: Term) FieldIterator {
        const source = switch (self.resource.tiers) {
            .bundled => return .{ .source = null, .indexes = &.{} },
            .parsed => |parsed| &parsed.source,
        };
        return .{ .source = source, .indexes = source.fields.get(self.index) };
    }

    fn release(recorded: *const History, index: u16) ?[]const u8 {
        return if (index == NO_RELEASE) null else recorded.releases.get(index);
    }
};

/// The canonical term and whether an alternate ID found it.
pub const Match = struct { term: Term, alternate_id: bool };

pub const TermIterator = struct {
    resource: *const Vocabulary,
    indexes: []const u32,
    position: usize = 0,

    /// Skips parents the resource has no term for; `targets("is_a")` yields those too.
    pub fn next(self: *TermIterator) ?Term {
        while (self.position < self.indexes.len) {
            const index = self.indexes[self.position];
            self.position += 1;
            if (index & EXTERNAL == 0) return .{ .resource = self.resource, .index = index };
        }
        return null;
    }
};

pub const StringIterator = struct {
    indexes: union(enum) { u8s: []const u8, u32s: []const u32 },
    strings: Strings,
    position: usize = 0,

    pub fn next(self: *StringIterator) ?[]const u8 {
        const index: usize = switch (self.indexes) {
            inline else => |indexes| if (self.position == indexes.len) return null else indexes[self.position],
        };
        self.position += 1;
        return self.strings.get(index);
    }
};

pub const TextIterator = struct {
    lists: TextLists,
    position: usize,
    end: usize,

    pub fn next(self: *TextIterator) ?Text {
        if (self.position == self.end) return null;
        defer self.position += 1;
        return .{ .value = self.lists.values.get(self.position), .suffix = self.lists.suffixes.get(self.position) };
    }
};

/// A relation target: its identifier, and its term when the resource holds it.
pub const Target = struct { id: []const u8, term: ?Term };

/// Allocates nothing.
pub const Targets = struct {
    resource: *const Vocabulary,
    kind: ?u32 = null,
    edges: []const Relation = &.{},
    parents: []const u32 = &.{},
    position: usize = 0,

    /// Returns the next target's identifier, or null after the last.
    pub fn next(self: *Targets) ?[]const u8 {
        return (self.nextTarget() orelse return null).id;
    }

    pub fn nextTarget(self: *Targets) ?Target {
        if (self.kind == null) {
            if (self.position == self.parents.len) return null;
            defer self.position += 1;
            return self.resource.target(self.parents[self.position]);
        }
        while (self.position < self.edges.len) {
            const edge = self.edges[self.position];
            self.position += 1;
            if (edge.kind == self.kind.?) return self.resource.target(edge.target);
        }
        return null;
    }
};

/// One relation edge as written.
pub const Relationship = struct { kind: []const u8, target: Target, modifiers: []const u8 };

pub const Relationships = struct {
    resource: *const Vocabulary,
    edges: []const Relation,
    first: u32,
    position: usize = 0,

    pub fn next(self: *Relationships) ?Relationship {
        if (self.position == self.edges.len) return null;
        defer self.position += 1;
        const edge = self.edges[self.position];
        return .{
            .kind = self.resource.core.relation_kinds.get(edge.kind),
            .target = self.resource.target(edge.target),
            .modifiers = self.resource.detailTables().relation_modifiers.get(self.first + self.position),
        };
    }
};

pub const FormerNames = struct {
    history: ?*const History,
    entries: []const FormerName,
    position: usize = 0,

    pub fn next(self: *FormerNames) ?struct { name: []const u8, last_release: []const u8 } {
        const recorded = self.history orelse return null;
        if (self.position == self.entries.len) return null;
        defer self.position += 1;
        const entry = self.entries[self.position];
        return .{ .name = recorded.former_names.get(entry.name), .last_release = recorded.releases.get(entry.release) };
    }
};

pub const FieldIterator = struct {
    source: ?*const Source,
    indexes: []const u32,
    position: usize = 0,

    pub fn next(self: *FieldIterator) ?Field {
        const source = self.source orelse return null;
        if (self.position == self.indexes.len) return null;
        defer self.position += 1;
        const index = self.indexes[self.position];
        return .{ .tag = source.tags.get(index), .value = source.values.get(index) };
    }
};

/// Number of terms, by table position.
pub fn count(self: *const Vocabulary) usize {
    return self.core.ids.count();
}

/// The term at a table position, which orders terms by accession bytes.
pub fn term(self: *const Vocabulary, index: usize) Term {
    return .{ .resource = self, .index = @intCast(index) };
}

/// Finds a term by exact primary or alternate accession.
pub fn lookup(self: *const Vocabulary, accession: []const u8) ?Match {
    if (self.core.ids.find(accession)) |index| return .{ .term = self.term(index), .alternate_id = false };
    const alias = self.core.aliases.find(accession) orelse return null;
    return .{ .term = self.term(self.core.alias_terms[alias]), .alternate_id = true };
}

/// Tests reflexive ancestry within this resource, including alternate IDs, from the precomputed
/// closure: constant work, no walk.
pub fn isA(self: *const Vocabulary, child: []const u8, parent: []const u8) error{UnknownTerm}!bool {
    const descendant = (self.lookup(child) orelse return error.UnknownTerm).term.index;
    const ancestor = (self.lookup(parent) orelse return error.UnknownTerm).term.index;
    if (descendant == ancestor) return true;
    return std.sort.binarySearch(u32, self.closureTable().get(descendant), ancestor, struct {
        fn order(key: u32, item: u32) std.math.Order {
            return std.math.order(key, item);
        }
    }.order) != null;
}

/// Expands direct `has_value_type` edges recursively into caller-owned slots.
/// XSD targets and semantic terms without further value-type edges are leaves.
/// Returns the filled prefix, preserving multiplicity. On failure its contents are partial.
pub fn valueTypes(
    self: *const Vocabulary,
    accession: []const u8,
    output: [][]const u8,
    max_work: usize,
) GraphError![][]const u8 {
    const found = self.lookup(accession) orelse return error.UnknownTerm;
    var walk: Walk = .{ .resource = self, .remaining = max_work };
    var filled: usize = 0;
    try walk.types(.{ .id = found.term.id(), .term = found.term }, output, &filled, 0, true);
    return output[0..filled];
}

/// The file's header field at a position (`format-version`, `data-version`, remarks, and others)
/// as written, or null past the last.
pub fn header(self: *const Vocabulary, index: usize) ?Field {
    const tables = self.detailTables();
    if (index >= tables.header_tags.count()) return null;
    return .{ .tag = tables.header_tags.get(index), .value = tables.header_values.get(index) };
}

/// The releases this resource's history records, oldest first; empty without history.
pub fn releases(self: *const Vocabulary) Strings {
    const recorded = self.historyTables() orelse return .{};
    return recorded.releases;
}

/// The position in `releases` of a release this resource's history records, by exact text.
pub fn findRelease(self: *const Vocabulary, version: []const u8) ?usize {
    const recorded = self.historyTables() orelse return null;
    var low: usize = 0;
    var high = recorded.by_text.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const index = recorded.by_text[mid];
        switch (std.mem.order(u8, version, recorded.releases.get(index))) {
            .lt => high = mid,
            .gt => low = mid + 1,
            .eq => return index,
        }
    }
    return null;
}

fn target(self: *const Vocabulary, value: u32) Target {
    if (value & EXTERNAL != 0) return .{ .id = self.core.externals.get(value & ~EXTERNAL), .term = null };
    const found = self.term(value);
    return .{ .id = found.id(), .term = found };
}

fn closureTable(self: *const Vocabulary) *const Closure {
    return switch (self.tiers) {
        .bundled => |index| &generated_data.CLOSURES[index],
        .parsed => |parsed| &parsed.closure,
    };
}

fn detailTables(self: *const Vocabulary) *const Details {
    return switch (self.tiers) {
        .bundled => |index| &generated_data.DETAILS[index],
        .parsed => |parsed| &parsed.details,
    };
}

fn historyTables(self: *const Vocabulary) ?*const History {
    return switch (self.tiers) {
        .bundled => |index| if (generated_data.HISTORIES[index]) |*found| found else null,
        .parsed => null,
    };
}

/// A vocabulary `parseObo` built, with storage it owns until `deinit`.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    core: Core,
    parsed: Parsed,
    vocabulary: Vocabulary,

    pub fn deinit(self: *Owned) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

pub const ParseError = obo.Error;

/// Parses an OBO 1.2 or 1.4 file of at most `obo.MAX_BYTES` into tables that work as the bundled
/// ones do, and keeps every stanza field as written. `identity` is copied as given; a nonempty
/// `source_version` must equal the file's `data-version`. A cycle in `is_a` is an error.
pub fn parseObo(allocator: std.mem.Allocator, bytes: []const u8, identity: Identity) ParseError!*Owned {
    const owned = try allocator.create(Owned);
    errdefer allocator.destroy(owned);
    owned.arena = .init(allocator);
    errdefer owned.arena.deinit();
    try obo.parse(owned.arena.allocator(), bytes, identity, &owned.core, &owned.parsed);
    owned.vocabulary = .{ .identity = identity, .core = &owned.core, .tiers = .{ .parsed = &owned.parsed } };
    return owned;
}

const Walk = struct {
    resource: *const Vocabulary,
    remaining: usize,
    path: [64]u32 = undefined,

    fn enter(self: *Walk, index: u32, depth: usize) error{ Cycle, TraversalLimit }!void {
        if (depth == self.path.len or self.remaining == 0) return error.TraversalLimit;
        self.remaining -= 1;
        for (self.path[0..depth]) |seen| if (seen == index) return error.Cycle;
        self.path[depth] = index;
    }

    fn types(self: *Walk, at: Target, output: [][]const u8, filled: *usize, depth: usize, root: bool) GraphError!void {
        if (at.term) |found| {
            try self.enter(found.index, depth);
            var edges = found.targets("has_value_type");
            var has_targets = false;
            while (edges.nextTarget()) |next| {
                has_targets = true;
                try self.types(next, output, filled, depth + 1, false);
            }
            if (has_targets or root) return;
        } else {
            if (self.remaining == 0) return error.TraversalLimit;
            self.remaining -= 1;
            if (!std.mem.startsWith(u8, at.id, "xsd:") or at.id.len == 4) return error.UnknownTerm;
        }
        if (filled.* == output.len) return error.OutputTooSmall;
        output[filled.*] = at.id;
        filled.* += 1;
    }
};
