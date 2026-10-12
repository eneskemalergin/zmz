//! Resolves source parameters through document declarations without rewriting them.
//!
//! Inputs, resource tables, bindings, and returned views are borrowed. Nothing allocates or
//! does I/O, and units are never converted.

const std = @import("std");
const cv = @import("source.zig");
const Vocabulary = @import("vocabulary.zig");
const generated_data = @import("generated_data.zig");

const Resolver = @This();

/// Explicit association for a local declaration ID, including stale or custom declarations.
pub const Binding = struct { declaration_id: []const u8, resource_key: []const u8 };

/// The caller's reviewed relationship between a declared version and the selected resource;
/// version strings are never compared to infer one.
pub const KnownVersion = struct {
    resource_key: []const u8,
    version: []const u8,
    relationship: enum { historical, future },
};

/// Describes the declaration relative to the resource actually selected.
pub const Version = enum {
    absent,
    empty,
    exact,
    historical,
    future,
    unrecognized_version,
    unrecognized_resource,
};

/// Independent diagnostics; a resolved accession may still have several issues.
pub const Issues = struct {
    missing_reference: bool = false,
    missing_declaration: bool = false,
    unrecognized_resource: bool = false,
    missing_accession: bool = false,
    unknown_accession: bool = false,
    namespace_mismatch: bool = false,
    stale_name: bool = false,
    obsolete: bool = false,
    /// Known URI and name evidence disagree, or an explicit binding contradicts either.
    resource_mismatch: bool = false,
    unrecognized_uri: bool = false,
    unrecognized_declaration_name: bool = false,
};

/// The selected declaration and table entry, with the accession actually looked up.
pub const Resolution = struct {
    declaration: ?*const cv.Declaration = null,
    resource: ?*const Vocabulary = null,
    match: ?Vocabulary.Match = null,
    version: Version = .unrecognized_resource,
    issues: Issues = .{},
};

/// Source metadata and independent parameter/unit interpretation.
pub const Parameter = struct {
    source: cv.Param,
    term: Resolution,
    unit: Resolution,
    unit_fields: enum { absent, partial, complete },
    /// `not_declared` means no direct `has_units` relation, not a unit prohibition.
    unit_allowed: enum { unresolved, not_declared, allowed, disallowed },
};

/// A number of the caller's chosen type with its resolved parameter. Check `parameter.unit_fields`,
/// unit, and `unit_allowed` before interpreting its units; the value is not converted.
pub fn Quantity(comptime T: type) type {
    if (@typeInfo(T) != .int and T != f32 and T != f64)
        @compileError("quantity requires an integer, f32, or f64");
    return struct { value: T, parameter: Parameter };
}

/// Ambiguity is an error; no first match is chosen.
pub const Error = error{ LimitExceeded, DuplicateDeclaration, InvalidBinding, AmbiguousResource, ConflictingVersion };

/// The bundled current vocabulary snapshots. Historical snapshots are not bundled.
pub const BUNDLED: []const Vocabulary = generated_data.RESOURCES;

resources: []const Vocabulary,
declarations: []const cv.Declaration,
bindings: []const Binding = &.{},
known_versions: []const KnownVersion = &.{},
/// Bounds declaration, resource, binding, and version comparisons per operation.
max_work: usize = 100_000,

/// Resolves against `BUNDLED` and treats a psi-ms 4.1.248 declaration as `historical`; setting
/// `known_versions` replaces that entry. Every resolution borrows `declarations`.
pub fn init(declarations: []const cv.Declaration) Resolver {
    return .{
        .resources = BUNDLED,
        .declarations = declarations,
        .known_versions = &.{.{ .resource_key = "psi-ms", .version = "4.1.248", .relationship = .historical }},
    };
}

/// Resolves both references separately and checks direct allowed-unit accessions.
/// Missing or unknown metadata produces diagnostics; ambiguous configuration returns an error.
pub fn resolve(self: Resolver, parameter: cv.Param) Error!Parameter {
    var remaining = self.max_work;
    const term = try self.find(parameter.cv_ref, parameter.accession, parameter.name, &remaining);
    const unit = if (parameter.unit.isAbsent())
        Resolution{}
    else
        try self.find(parameter.unit.cv_ref, parameter.unit.accession, parameter.unit.name, &remaining);
    var result: Parameter = .{
        .source = parameter,
        .term = term,
        .unit = unit,
        .unit_fields = if (parameter.unit.isAbsent()) .absent else if (parameter.unit.isComplete()) .complete else .partial,
        .unit_allowed = .unresolved,
    };
    if (term.match) |matched| {
        var targets = matched.term.targets("has_units");
        var has_units = false;
        var allowed = false;
        while (targets.next()) |target| {
            try charge(&remaining);
            has_units = true;
            if (unit.match) |unit_match| {
                const expected = unit.resource.?.lookup(target);
                if (expected) |found|
                    allowed = allowed or std.mem.eql(u8, found.term.id, unit_match.term.id);
            }
        }
        result.unit_allowed = if (!has_units) .not_declared else if (unit.match == null or
            unit.issues.namespace_mismatch or term.issues.namespace_mismatch) .unresolved else if (allowed) .allowed else .disallowed;
    }
    return result;
}

/// Parses the parameter's value, then resolves its term and unit. Numeric errors come first;
/// unit problems are diagnostics alongside the value.
pub fn quantity(self: Resolver, comptime T: type, parameter: cv.Param) (cv.ValueError || Error)!Quantity(T) {
    const value = if (@typeInfo(T) == .int)
        try cv.parseInteger(T, parameter.value)
    else
        try cv.parseFloat(T, parameter.value);
    return .{ .value = value, .parameter = try self.resolve(parameter) };
}

fn find(
    self: Resolver,
    reference: ?[]const u8,
    accession: ?cv.Accession,
    name: ?[]const u8,
    remaining: *usize,
) Error!Resolution {
    var result: Resolution = .{};
    result.issues.missing_accession = accession == null;
    const ref = reference orelse {
        result.issues.missing_reference = true;
        return result;
    };
    for (self.declarations) |*declaration| {
        try charge(remaining);
        const id = declaration.id orelse continue;
        if (!cv.sameId(id, ref)) continue;
        if (result.declaration != null) return error.DuplicateDeclaration;
        result.declaration = declaration;
    }
    const declaration = result.declaration orelse {
        result.issues.missing_declaration = true;
        return result;
    };
    var bound: ?[]const u8 = null;
    for (self.bindings) |binding| {
        try charge(remaining);
        if (!cv.sameId(binding.declaration_id, ref)) continue;
        if (bound != null) return error.InvalidBinding;
        bound = binding.resource_key;
    }
    var evidence: ?*const Vocabulary = null;
    for (self.resources) |*resource| {
        try charge(remaining);
        if (bound) |key| if (std.mem.eql(u8, key, resource.identity.key)) {
            if (result.resource != null) return error.AmbiguousResource;
            result.resource = resource;
        };
        const recognized = knownUri(declaration.uri, resource.identity) or
            knownName(declaration.full_name, resource.identity);
        if (recognized) {
            if (evidence != null) {
                if (bound == null) return error.AmbiguousResource;
                result.issues.resource_mismatch = true;
            }
            evidence = resource;
        }
    }
    if (bound != null and result.resource == null) return error.InvalidBinding;
    if (result.resource == null) result.resource = evidence;
    if (evidence != null and result.resource != evidence) result.issues.resource_mismatch = true;
    const resource = result.resource orelse {
        result.issues.unrecognized_resource = true;
        return result;
    };
    result.issues.unrecognized_uri = declaration.uri != null and !knownUri(declaration.uri, resource.identity);
    result.issues.unrecognized_declaration_name = declaration.full_name != null and
        !knownName(declaration.full_name, resource.identity);
    result.version = try self.version(resource.*, declaration.version, remaining);
    if (accession) |identity| {
        if (identity.curie()) |curie|
            result.issues.namespace_mismatch = !std.mem.eql(u8, curie.prefix, resource.identity.namespace);
        result.match = resource.lookup(identity.raw);
        result.issues.unknown_accession = result.match == null;
        if (result.match) |match| {
            result.issues.obsolete = match.term.obsolete;
            if (name) |label| result.issues.stale_name = !std.mem.eql(u8, label, match.term.name);
        }
    }
    return result;
}

fn version(self: Resolver, resource: Vocabulary, declared: ?[]const u8, remaining: *usize) Error!Version {
    const text = declared orelse return .absent;
    if (text.len == 0) return .empty;
    if (std.mem.eql(u8, text, resource.identity.version) or
        (resource.identity.source_version.len != 0 and std.mem.eql(u8, text, resource.identity.source_version)))
        return .exact;
    var known: ?Version = null;
    for (self.known_versions) |entry| {
        try charge(remaining);
        if (std.mem.eql(u8, entry.resource_key, resource.identity.key) and std.mem.eql(u8, entry.version, text)) {
            if (known != null) return error.ConflictingVersion;
            known = switch (entry.relationship) {
                .historical => .historical,
                .future => .future,
            };
        }
    }
    return known orelse .unrecognized_version;
}

fn charge(remaining: *usize) Error!void {
    if (remaining.* == 0) return error.LimitExceeded;
    remaining.* -= 1;
}

fn matches(source: ?[]const u8, known: []const u8) bool {
    return known.len != 0 and if (source) |text| std.mem.eql(u8, text, known) else false;
}

fn knownName(source: ?[]const u8, identity: Vocabulary.Identity) bool {
    if (matches(source, identity.full_name)) return true;
    if (std.mem.eql(u8, identity.key, "psi-ms")) {
        return matches(source, "Proteomics Standards Initiative Mass Spectrometry Ontology") or
            matches(source, "Mass spectrometry ontology");
    }
    return false;
}

fn knownUri(source: ?[]const u8, identity: Vocabulary.Identity) bool {
    if (matches(source, identity.uri)) return true;
    if (std.mem.eql(u8, identity.key, "psi-ms"))
        return matches(source, "https://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo");
    if (std.mem.eql(u8, identity.key, "uo"))
        return matches(source, "https://raw.githubusercontent.com/bio-ontology-research-group/unit-ontology/master/unit.obo");
    return false;
}
