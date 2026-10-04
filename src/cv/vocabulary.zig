//! Provides immutable vocabulary lookup and bounded ontology queries.
//!
//! Tables and returned text borrow from their resource owner. Generated resources
//! have static lifetime; caller-supplied tables must remain sorted and unchanged.

const std = @import("std");
const Vocabulary = @This();

identity: Identity,
headers: []const Field = &.{},
/// Sorted by exact accession bytes, with no duplicate primary or alternate IDs.
terms: []const Term,
/// Sorted by alternate accession bytes; indexes refer to `terms`.
aliases: []const Alias = &.{},

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

/// An explicit relation and exact decoded target, including non-CURIE targets.
pub const Relationship = struct {
    kind: []const u8,
    target: []const u8,
    modifiers: []const u8 = "",
};

/// Complete term metadata. Replacement and consider lists are guidance, not rewrites.
pub const Term = struct {
    id: []const u8,
    name: []const u8,
    obsolete: bool = false,
    definition: ?Text = null,
    synonyms: []const Text = &.{},
    alternate_ids: []const []const u8 = &.{},
    replaced_by: []const []const u8 = &.{},
    consider: []const []const u8 = &.{},
    parents: []const []const u8 = &.{},
    relationships: []const Relationship = &.{},
    xrefs: []const Text = &.{},
    /// All source term fields, including unknown tags and trailing modifiers.
    fields: []const Field = &.{},

    /// Iterates this term's direct targets for one relation.
    pub fn targets(self: Term, relation: []const u8) Targets {
        return .{ .term = self, .relation = relation };
    }
};

/// Allocates nothing.
pub const Targets = struct {
    term: Term,
    relation: []const u8,
    position: usize = 0,

    /// Returns null after the last target. `is_a` selects the parent list.
    pub fn next(self: *Targets) ?[]const u8 {
        if (std.mem.eql(u8, self.relation, "is_a")) {
            if (self.position == self.term.parents.len) return null;
            defer self.position += 1;
            return self.term.parents[self.position];
        }
        while (self.position < self.term.relationships.len) {
            const edge = self.term.relationships[self.position];
            self.position += 1;
            if (std.mem.eql(u8, edge.kind, self.relation)) return edge.target;
        }
        return null;
    }
};

/// An alternate identifier's index into the canonical term table.
pub const Alias = struct { id: []const u8, term_index: usize };

/// The canonical metadata and the identity basis used to find it.
pub const Match = struct { term: *const Term, alternate_id: bool };

/// Finds a term by exact primary or alternate accession.
pub fn lookup(self: Vocabulary, accession: []const u8) ?Match {
    if (search(Term, self.terms, accession)) |index| return .{ .term = &self.terms[index], .alternate_id = false };
    const alias = search(Alias, self.aliases, accession) orelse return null;
    const index = self.aliases[alias].term_index;
    if (index >= self.terms.len) return null;
    return .{ .term = &self.terms[index], .alternate_id = true };
}

/// Binary search over items sorted by exact id bytes.
fn search(comptime T: type, items: []const T, id: []const u8) ?usize {
    var low: usize = 0;
    var high = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, id, items[mid].id)) {
            .lt => high = mid,
            .gt => low = mid + 1,
            .eq => return mid,
        }
    }
    return null;
}

/// Graph failures are distinct from a completed negative ancestry query.
pub const GraphError = error{ UnknownTerm, Cycle, TraversalLimit, OutputTooSmall };

/// Tests reflexive ancestry within this resource, including alternate IDs.
/// Limits edge and node visits; nesting is additionally capped at 64 terms.
/// Missing nodes and cycles encountered before a match return explicit errors.
pub fn isA(self: Vocabulary, child: []const u8, parent: []const u8, max_work: usize) error{ UnknownTerm, Cycle, TraversalLimit }!bool {
    const target = self.lookup(parent) orelse return error.UnknownTerm;
    var walk: Walk = .{ .resource = self, .remaining = max_work };
    return walk.ancestor(child, target.term.id, 0);
}

/// Expands direct `has_value_type` edges recursively into caller-owned slots.
/// XSD targets and semantic terms without further value-type edges are leaves.
/// Returns the filled prefix, preserving multiplicity. On failure its contents are partial.
pub fn valueTypes(
    self: Vocabulary,
    accession: []const u8,
    output: [][]const u8,
    max_work: usize,
) GraphError![][]const u8 {
    const term = self.lookup(accession) orelse return error.UnknownTerm;
    var walk: Walk = .{ .resource = self, .remaining = max_work };
    var count: usize = 0;
    try walk.types(term.term.id, output, &count, 0, true);
    return output[0..count];
}

const Walk = struct {
    resource: Vocabulary,
    remaining: usize,
    path: [64][]const u8 = undefined,

    fn enter(self: *Walk, id: []const u8, depth: usize) error{ Cycle, TraversalLimit }!void {
        if (depth == self.path.len or self.remaining == 0) return error.TraversalLimit;
        self.remaining -= 1;
        for (self.path[0..depth]) |seen|
            if (std.mem.eql(u8, id, seen)) return error.Cycle;
        self.path[depth] = id;
    }

    fn ancestor(self: *Walk, id: []const u8, target: []const u8, depth: usize) error{ UnknownTerm, Cycle, TraversalLimit }!bool {
        const match = self.resource.lookup(id) orelse return error.UnknownTerm;
        try self.enter(match.term.id, depth);
        if (std.mem.eql(u8, match.term.id, target)) return true;
        for (match.term.parents) |parent|
            if (try self.ancestor(parent, target, depth + 1)) return true;
        return false;
    }

    fn types(
        self: *Walk,
        id: []const u8,
        output: [][]const u8,
        count: *usize,
        depth: usize,
        root: bool,
    ) GraphError!void {
        const match = self.resource.lookup(id);
        const canonical = if (match) |found| found.term.id else id;
        try self.enter(canonical, depth);
        if (match) |found| {
            var targets = found.term.targets("has_value_type");
            var has_targets = false;
            while (targets.next()) |target| {
                has_targets = true;
                try self.types(target, output, count, depth + 1, false);
            }
            if (has_targets or root) return;
        } else if (!std.mem.startsWith(u8, id, "xsd:") or id.len == 4) {
            return error.UnknownTerm;
        }
        if (count.* == output.len) return error.OutputTooSmall;
        output[count.*] = canonical;
        count.* += 1;
    }
};
