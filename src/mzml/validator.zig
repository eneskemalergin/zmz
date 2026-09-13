//! Checks mzML document structure and references without retaining records or interpreting CV terms.

const std = @import("std");
const cv = @import("../cv/source.zig");
const model = @import("model.zig");
const schema = @import("schema.zig");

const Validator = @This();

/// Bounds retained identifiers and forward references, separately from each input hierarchy.
/// Bytes charge copied strings and entry storage, not container capacity or allocator overhead.
pub const Limits = struct {
    identifiers: usize = 1_000_000,
    forward_references: usize = 1_000_000,
    bytes: usize = 128 * 1024 * 1024,
    structure: schema.Limits = .{},
};

/// Conformance, ordering, and resource failures. Failed operations leave this checker unusable.
pub const Error = schema.Error || std.mem.Allocator.Error || error{
    DuplicateId,
    MissingReference,
    WrongReferenceKind,
    InvalidReference,
    InvalidIndex,
    InvalidState,
    FailedState,
};

/// The first error and its element context, including the original location of a deferred reference.
/// Constructed nodes have zero source offsets. No borrowed source strings are retained here.
pub const Diagnostic = struct { code: Error, byte_offset: u64, element: model.Kind };

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
limits: Limits,
remaining: usize,
identifier_count: usize = 0,
metadata: std.StringHashMapUnmanaged(model.Kind) = .empty,
records: [2]std.StringHashMapUnmanaged(void) = .{ .empty, .empty },
pending: std.ArrayList(Reference) = .empty,
phase: enum { run, list, done } = .run,
sequence: schema.Sequence = .{ .rules = schema.children(.run) },
list_kind: model.Kind = .spectrum_list,
expected_count: usize = 0,
observed_count: usize = 0,
location: Location = .{ .element = .mzml, .offset = 0 },
list_location: Location = .{ .element = .run, .offset = 0 },
failure: ?Diagnostic = null,

/// Checks header structure, metadata spellings, XML IDs, and typed local references.
/// Copies retained IDs; the header can be released after this call. Do not copy the owner.
/// Unit attributes remain independently optional. CV meaning and binary payloads are not checked.
pub fn init(allocator: std.mem.Allocator, header: model.Header, limits: Limits) Error!Validator {
    try schema.checkHeader(header, limits.structure);
    var self: Validator = .{
        .allocator = allocator,
        .arena = .init(allocator),
        .limits = limits,
        .remaining = limits.bytes,
    };
    errdefer self.deinit();
    try self.collectIds(header.document);
    try self.walk(header.document);
    try self.walk(header.run);
    return self;
}

/// Releases copied identifiers and references. It does not imply successful document completion.
pub fn deinit(self: *Validator) void {
    self.metadata.deinit(self.allocator);
    for (&self.records) |*records| records.deinit(self.allocator);
    self.pending.deinit(self.allocator);
    self.arena.deinit();
    self.* = undefined;
}

/// Accepts a spectrumList or chromatogramList opening with its source attributes and no children.
/// Lists must be supplied in document order; inputs are borrowed only during this call.
pub fn beginList(self: *Validator, node: model.Node) Error!void {
    if (self.failure != null) return error.FailedState;
    self.locate(node);
    errdefer |err| self.fail(err);
    if (self.phase != .run) return error.InvalidState;
    try schema.checkList(node);
    try self.sequence.accept(node.kind);
    try self.walk(node);
    self.expected_count = try cv.parseInteger(usize, node.attribute("count"));
    self.observed_count = 0;
    self.list_kind = node.kind;
    self.list_location = self.location;
    self.phase = .list;
}

/// Checks one record's hierarchy, metadata, consecutive index, and scoped ID uniqueness.
/// Binary text may be absent; this operation does not check encoded or decoded payload contents.
/// Forward spectrum references are copied and resolved by finish, including chromatogram precursors.
pub fn record(self: *Validator, node: model.Node) Error!void {
    if (self.failure != null) return error.FailedState;
    self.locate(node);
    errdefer |err| self.fail(err);
    if (self.phase != .list) return error.InvalidState;
    const kind: model.Kind = if (self.list_kind == .spectrum_list) .spectrum else .chromatogram;
    if (node.kind != kind) return error.InvalidStructure;
    if (self.observed_count == self.expected_count) return error.CountMismatch;
    try schema.checkMetadataNode(node, self.limits.structure);
    if (try cv.parseInteger(usize, node.attribute("index")) != self.observed_count) return error.InvalidIndex;
    const id = node.attribute("id").?;
    const keys = &self.records[if (kind == .spectrum) @as(usize, 0) else 1];
    if (keys.contains(id)) return error.DuplicateId;
    try self.chargeIdentifier(id.len, @sizeOf([]const u8));
    const copied = try self.copy(id);
    try keys.put(self.allocator, copied, {});
    try self.walk(node);
    self.observed_count += 1;
}

/// Closes the current list only when its declared count and minimum cardinality are satisfied.
pub fn endList(self: *Validator) Error!void {
    if (self.failure != null) return error.FailedState;
    self.location = self.list_location;
    errdefer |err| self.fail(err);
    if (self.phase != .list) return error.InvalidState;
    if (self.observed_count != self.expected_count) return error.CountMismatch;
    if (self.list_kind == .chromatogram_list and self.observed_count == 0)
        return error.InvalidStructure;
    self.phase = .run;
}

/// Resolves deferred spectrum references after all lists close. Can succeed only once.
/// A reader must also reach XML EOF; a writer must still finish and flush its output.
/// External spectrum identifiers are not fetched or checked against another document.
pub fn finish(self: *Validator) Error!void {
    if (self.failure != null) return error.FailedState;
    errdefer |err| self.fail(err);
    if (self.phase != .run) return error.InvalidState;
    try self.sequence.finish();
    for (self.pending.items) |reference| {
        self.location = reference.location;
        if (!self.records[0].contains(reference.id)) {
            if (self.records[1].contains(reference.id)) return error.WrongReferenceKind;
            return error.MissingReference;
        }
    }
    self.phase = .done;
}

/// Returns the first failure without borrowing record storage.
pub fn diagnostic(self: *const Validator) ?Diagnostic {
    return self.failure;
}

fn collectIds(self: *Validator, node: model.Node) Error!void {
    if (schema.hasXmlId(node.kind)) {
        const id = try schema.normalizedId(node.attribute("id").?);
        if (self.metadata.contains(id)) return error.DuplicateId;
        try self.chargeIdentifier(id.len, @sizeOf([]const u8) + @sizeOf(model.Kind));
        try self.metadata.put(self.allocator, try self.copy(id), node.kind);
    }
    for (node.children) |child| try self.collectIds(child);
}

fn walk(self: *Validator, node: model.Node) Error!void {
    self.locate(node);
    try schema.checkLexical(node);
    for (node.attributes) |attr| {
        if (attr.namespace_uri != null) continue;
        if (schema.referenceKind(node.kind, attr.name)) |kind| try self.checkRef(attr.value, kind);
    }
    for (node.params) |param| switch (param) {
        .group_ref => |ref| try self.checkRef(ref.?, .referenceable_param_group),
        .cv => |entry| {
            try self.checkRef(entry.cv_ref.?, .cv);
            if (entry.unit.cv_ref) |ref| try self.checkRef(ref, .cv);
        },
        .user => |entry| if (entry.unit.cv_ref) |ref| try self.checkRef(ref, .cv),
    };
    if (node.kind == .scan or node.kind == .precursor) {
        if (node.attribute("externalSpectrumID") != null and node.attribute("sourceFileRef") == null)
            return error.InvalidReference;
        if (node.attribute("spectrumRef")) |id| {
            if (!self.records[0].contains(id)) {
                if (self.pending.items.len == self.limits.forward_references) return error.LimitExceeded;
                try self.charge(@sizeOf(Reference));
                const copied = try self.copy(id);
                try self.pending.ensureUnusedCapacity(self.allocator, 1);
                self.pending.appendAssumeCapacity(.{ .id = copied, .location = self.location });
            }
        }
    }
    for (node.children) |child| try self.walk(child);
}

fn checkRef(self: *const Validator, text: []const u8, kind: model.Kind) Error!void {
    const id = try schema.normalizedId(text);
    const target = self.metadata.get(id) orelse return error.MissingReference;
    if (target != kind) return error.WrongReferenceKind;
}

fn locate(self: *Validator, node: model.Node) void {
    self.location = .{ .element = node.kind, .offset = node.start_offset };
}

fn fail(self: *Validator, err: Error) void {
    self.failure = .{ .code = err, .byte_offset = self.location.offset, .element = self.location.element };
}

fn chargeIdentifier(self: *Validator, text_bytes: usize, entry_bytes: usize) Error!void {
    if (self.identifier_count == self.limits.identifiers) return error.LimitExceeded;
    if (text_bytes > self.remaining) return error.LimitExceeded;
    try self.charge(entry_bytes);
    self.identifier_count += 1;
}

fn charge(self: *Validator, bytes: usize) Error!void {
    if (bytes > self.remaining) return error.LimitExceeded;
    self.remaining -= bytes;
}

fn copy(self: *Validator, text: []const u8) Error![]const u8 {
    try self.charge(text.len);
    return self.arena.allocator().dupe(u8, text);
}

const Location = struct { element: model.Kind, offset: u64 };
const Reference = struct { id: []const u8, location: Location };
