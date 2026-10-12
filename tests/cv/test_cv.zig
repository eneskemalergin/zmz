//! Verifies exact vocabulary identities, lexical interpretation, and bounded group expansion.

const std = @import("std");
const cv = @import("zmz").mzml.cv;

const GRAPH: cv.Vocabulary = .{
    .identity = .{ .key = "example", .version = "current", .namespace = "X" },
    .terms = &.{
        .{ .id = "X:1", .name = "root" },
        .{ .id = "X:2", .name = "child", .parents = &.{"X:1"} },
        .{ .id = "X:3", .name = "cycle", .parents = &.{"X:3"} },
        .{ .id = "X:4", .name = "dangling", .parents = &.{"X:missing"} },
        .{ .id = "X:5", .name = "typed", .relationships = &.{
            .{ .kind = "has_value_type", .target = "X:6" },
            .{ .kind = "has_units", .target = "UO:0000010" },
        } },
        .{ .id = "X:6", .name = "integer", .relationships = &.{
            .{ .kind = "has_value_type", .target = "xsd:integer" },
        } },
        .{ .id = "X:7", .name = "cyclic type", .relationships = &.{
            .{ .kind = "has_value_type", .target = "X:7" },
        } },
    },
    .aliases = &.{.{ .id = "X:02", .term_index = 1 }},
};

test "[unit] - [CV vocabulary]: resolves exact identities and bounded graph queries" {
    const alias = GRAPH.lookup("X:02").?;
    try std.testing.expect(alias.alternate_id);
    try std.testing.expectEqualStrings("X:2", alias.term.id);
    try std.testing.expectEqual(null, GRAPH.lookup("x:2"));
    var invalid_alias = GRAPH;
    invalid_alias.aliases = &.{.{ .id = "X:02", .term_index = GRAPH.terms.len }};
    try std.testing.expectEqual(null, invalid_alias.lookup("X:02"));
    try std.testing.expect(try GRAPH.isA("X:02", "X:1", 2));
    try std.testing.expect(try GRAPH.isA("X:02", "X:2", 1));
    try std.testing.expect(!try GRAPH.isA("X:1", "X:2", 2));
    try std.testing.expectError(error.TraversalLimit, GRAPH.isA("X:2", "X:1", 1));
    try std.testing.expectError(error.Cycle, GRAPH.isA("X:3", "X:1", 10));
    try std.testing.expectError(error.UnknownTerm, GRAPH.isA("X:4", "X:1", 10));
    try std.testing.expectError(error.UnknownTerm, GRAPH.isA("X:2", "X:missing", 10));

    var types: [2][]const u8 = undefined;
    const resolved = try GRAPH.valueTypes("X:5", &types, 3);
    try std.testing.expectEqual(@as(usize, 1), resolved.len);
    try std.testing.expectEqualStrings("xsd:integer", resolved[0]);
    try std.testing.expectError(error.TraversalLimit, GRAPH.valueTypes("X:5", &types, 2));
    try std.testing.expectError(error.OutputTooSmall, GRAPH.valueTypes("X:5", &.{}, 3));
    try std.testing.expectError(error.Cycle, GRAPH.valueTypes("X:7", &types, 10));
    try std.testing.expectEqual(@as(usize, 0), (try GRAPH.valueTypes("X:1", &types, 1)).len);
    var units = GRAPH.lookup("X:5").?.term.targets("has_units");
    try std.testing.expectEqualStrings("UO:0000010", units.next().?);
    try std.testing.expectEqual(null, units.next());
    var parents = GRAPH.lookup("X:02").?.term.targets("is_a");
    try std.testing.expectEqualStrings("X:1", parents.next().?);
    try std.testing.expectEqual(null, parents.next());
}

test "[unit] - [CV resolver]: separates source metadata from current vocabulary interpretation" {
    const declarations = [_]cv.Declaration{
        .{ .id = "mass-spec", .full_name = "PSI-MS", .uri = "urn:stale", .version = "4.1.258" },
        .{ .id = "units", .full_name = "Unit Ontology", .version = "releases/2026-07-31" },
    };
    const resolver = cv.Resolver.init(&declarations);
    const source: cv.Param = .{
        .cv_ref = " mass-spec\t",
        .accession = .{ .raw = "MS:1000016" },
        .name = "stale time label",
        .value = "01.00",
        .unit = .{ .cv_ref = "units", .accession = .{ .raw = "UO:0000031" }, .name = "minute" },
    };
    const result = try resolver.resolve(source);
    try std.testing.expectEqualDeep(source, result.source);
    try std.testing.expectEqual(.exact, result.term.version);
    try std.testing.expectEqual(.exact, result.unit.version);
    try std.testing.expectEqualStrings("scan start time", result.term.match.?.term.name);
    try std.testing.expect(result.term.issues.stale_name);
    try std.testing.expect(!result.term.issues.namespace_mismatch);
    try std.testing.expectEqual(.allowed, result.unit_allowed);
    try std.testing.expectEqualStrings("uo", result.unit.resource.?.identity.key);
    try std.testing.expectEqualStrings("2026-07-31", result.unit.resource.?.identity.version);
    var changed = source;
    changed.unit.accession = .{ .raw = "UO:0000008" };
    try std.testing.expectEqual(.disallowed, (try resolver.resolve(changed)).unit_allowed);
    changed.unit.cv_ref = null;
    const partial = try resolver.resolve(changed);
    try std.testing.expectEqual(.partial, partial.unit_fields);
    try std.testing.expect(partial.unit.issues.missing_reference);
    try std.testing.expectEqual(.unresolved, partial.unit_allowed);
    changed.unit = .{};
    try std.testing.expectEqual(.absent, (try resolver.resolve(changed)).unit_fields);
    changed.accession = .{ .raw = "MS:future-unknown" };
    try std.testing.expect((try resolver.resolve(changed)).term.issues.unknown_accession);
    changed.cv_ref = "undeclared";
    try std.testing.expect((try resolver.resolve(changed)).term.issues.missing_declaration);

    const ms = resolver.resources[0];
    const uo = resolver.resources[1];
    try std.testing.expectEqual(@as(usize, 4114), ms.terms.len);
    try std.testing.expectEqual(@as(usize, 574), uo.terms.len);
    try std.testing.expectEqualStrings("UO:0000001", ms.lookup("UO:0000008").?.term.parents[0]);
    try std.testing.expectEqualStrings("UO:1000008", uo.lookup("UO:0000008").?.term.parents[1]);
    try std.testing.expect(ms.lookup("UO:0000149").?.alternate_id);
    try std.testing.expectEqualStrings("UO:0000003", ms.lookup("UO:0000149").?.term.id);
    try std.testing.expect(try ms.isA("MS:1003870", "MS:1000513", 1000));
    var types: [3][]const u8 = undefined;
    const resolved_types = try ms.valueTypes("MS:1003163", &types, 10);
    try std.testing.expectEqual(@as(usize, 1), resolved_types.len);
    try std.testing.expectEqualStrings("xsd:integer", resolved_types[0]);

    const obsolete = try resolver.resolve(.{ .cv_ref = "mass-spec", .accession = .{ .raw = "MS:1000266" } });
    try std.testing.expect(obsolete.term.issues.obsolete);
    try std.testing.expectEqualStrings("MS:1000266", obsolete.source.accession.?.raw);
    try std.testing.expectEqualStrings("MS:1000393", obsolete.term.match.?.term.replaced_by[0]);
    const mz = try resolver.resolve(.{
        .cv_ref = "mass-spec",
        .accession = .{ .raw = "MS:1000744" },
        .value = "400",
        .unit = .{ .cv_ref = "mass-spec", .accession = .{ .raw = "MS:1000040" }, .name = "m/z" },
    });
    try std.testing.expectEqual(.allowed, mz.unit_allowed);
}

test "[property] - [CV quantities]: parses source values without converting or hiding unit diagnostics" {
    const declarations = [_]cv.Declaration{
        .{ .id = "mass-spec", .full_name = "PSI-MS" },
        .{ .id = "units", .full_name = "Unit Ontology" },
    };
    var resolver = cv.Resolver.init(&declarations);
    var source: cv.Param = .{
        .cv_ref = "mass-spec",
        .accession = .{ .raw = "MS:1000016" },
        .name = "old name",
        .value = " +1.25 ",
    };
    for (0..8) |fields| {
        source.unit = .{
            .cv_ref = if (fields & 1 != 0) "units" else null,
            .accession = if (fields & 2 != 0) .{ .raw = "UO:0000031" } else null,
            .name = if (fields & 4 != 0) "minute" else null,
        };
        const result = try resolver.quantity(f64, source);
        try std.testing.expectEqual(@as(f64, 1.25), result.value);
        try std.testing.expectEqualDeep(try resolver.resolve(source), result.parameter);
        try std.testing.expectEqualDeep(source, result.parameter.source);
        try std.testing.expectEqual(fields & 3 == 3, result.parameter.unit.match != null);
        try std.testing.expect(result.parameter.term.issues.stale_name);
    }
    source.value = "-2147483648";
    try std.testing.expectEqual(std.math.minInt(i32), (try resolver.quantity(i32, source)).value);
    const cases = .{
        .{ @as(?[]const u8, null), error.MissingValue }, .{ "", error.EmptyValue },
        .{ "1 2", error.InvalidValue },                  .{ "1e9999", error.Overflow },
    };
    resolver.max_work = 0;
    inline for (cases) |case| {
        source.value = case[0];
        try std.testing.expectError(case[1], resolver.quantity(f64, source));
    }
    source.value = "1";
    try std.testing.expectError(error.LimitExceeded, resolver.quantity(f64, source));
}

test "[edge] - [CV resolver]: classifies only explicitly catalogued historical and future versions" {
    var declarations = [_]cv.Declaration{.{ .id = "local", .version = null }};
    var resolver: cv.Resolver = .{
        .resources = &.{GRAPH},
        .declarations = &declarations,
        .bindings = &.{.{ .declaration_id = "local", .resource_key = "example" }},
        .known_versions = &.{
            .{ .resource_key = "example", .version = "old", .relationship = .historical },
            .{ .resource_key = "example", .version = "future", .relationship = .future },
        },
    };
    const parameter: cv.Param = .{ .cv_ref = "local", .accession = .{ .raw = "X:02" }, .name = "old label" };
    const cases = .{
        .{ null, cv.Resolver.Version.absent },     .{ "", cv.Resolver.Version.empty },
        .{ "current", cv.Resolver.Version.exact }, .{ "old", cv.Resolver.Version.historical },
        .{ "future", cv.Resolver.Version.future }, .{ "9999", cv.Resolver.Version.unrecognized_version },
    };
    inline for (cases) |case| {
        declarations[0].version = case[0];
        const result = try resolver.resolve(parameter);
        try std.testing.expectEqual(case[1], result.term.version);
        try std.testing.expectEqualStrings("current", result.term.resource.?.identity.version);
        try std.testing.expect(result.term.match.?.alternate_id);
        try std.testing.expect(result.term.issues.stale_name);
    }
    resolver.bindings = &.{};
    const unknown = try resolver.resolve(parameter);
    try std.testing.expectEqual(.unrecognized_resource, unknown.term.version);
    try std.testing.expect(unknown.term.issues.unrecognized_resource);
    try std.testing.expectEqual(null, unknown.term.match);
}

test "[failure] - [CV resolver]: rejects exhausted work, duplicate declarations, and missing bindings" {
    const declarations = [_]cv.Declaration{.{ .id = "local", .version = null }};
    var resolver: cv.Resolver = .{ .resources = &.{GRAPH}, .declarations = &declarations, .max_work = 0 };
    const parameter: cv.Param = .{ .cv_ref = "local", .accession = .{ .raw = "X:02" }, .name = "old label" };
    try std.testing.expectError(error.LimitExceeded, resolver.resolve(parameter));
    resolver.max_work = 100;
    resolver.declarations = &.{ declarations[0], declarations[0] };
    try std.testing.expectError(error.DuplicateDeclaration, resolver.resolve(parameter));
    resolver.declarations = &declarations;
    resolver.bindings = &.{.{ .declaration_id = "local", .resource_key = "missing" }};
    try std.testing.expectError(error.InvalidBinding, resolver.resolve(parameter));
}

test "[failure] - [CV resolver]: reports namespace conflicts and refuses ambiguous resource selection" {
    const declarations = [_]cv.Declaration{.{ .id = "local", .full_name = "Unit Ontology", .uri = "http://purl.obolibrary.org/obo/ms/psi-ms.obo" }};
    var resolver = cv.Resolver.init(&declarations);
    const parameter: cv.Param = .{ .cv_ref = "local", .accession = .{ .raw = "UO:0000010" } };
    try std.testing.expectError(error.AmbiguousResource, resolver.resolve(parameter));
    resolver.bindings = &.{.{ .declaration_id = "local", .resource_key = "psi-ms" }};
    const bound = try resolver.resolve(parameter);
    try std.testing.expectEqualStrings("psi-ms", bound.term.resource.?.identity.key);
    try std.testing.expect(bound.term.issues.resource_mismatch);
    try std.testing.expect(bound.term.issues.namespace_mismatch);
    try std.testing.expect(bound.term.match != null);
    resolver.bindings = &.{ resolver.bindings[0], resolver.bindings[0] };
    try std.testing.expectError(error.InvalidBinding, resolver.resolve(parameter));
    resolver.bindings = &.{};
    resolver.declarations = &.{.{ .id = "local", .full_name = "PSI-MS", .version = "4.1.248" }};
    try std.testing.expectEqual(.historical, (try resolver.resolve(parameter)).term.version);
    resolver.known_versions = &.{ resolver.known_versions[0], resolver.known_versions[0] };
    try std.testing.expectError(error.ConflictingVersion, resolver.resolve(parameter));
}

test "[edge] - [CV vocabulary graph]: bounds depth and identifies dangling datatype targets" {
    var terms: [65]cv.Vocabulary.Term = undefined;
    var names: [65][8]u8 = undefined;
    var parents: [65][1][]const u8 = undefined;
    for (&terms, &names, 0..) |*term, *name, index| {
        term.* = .{ .id = try std.fmt.bufPrint(name, "X:{d:0>3}", .{index}), .name = "term" };
    }
    for (terms[0..64], parents[0..64], 0..) |*term, *parent, index| {
        parent[0] = terms[index + 1].id;
        term.parents = parent;
    }
    const resource: cv.Vocabulary = .{ .identity = GRAPH.identity, .terms = &terms };
    try std.testing.expect(try resource.isA("X:001", "X:064", 64));
    try std.testing.expectError(error.TraversalLimit, resource.isA("X:000", "X:064", 65));
    terms[0].relationships = &.{.{ .kind = "has_value_type", .target = "X:missing" }};
    var destination: [1][]const u8 = undefined;
    try std.testing.expectError(error.UnknownTerm, resource.valueTypes("X:000", &destination, 10));
}

test "[unit] - [CV identity]: keeps exact accessions and optional numeric local parts" {
    const accession: cv.Accession = .{ .raw = "MS:00123" };
    const curie = accession.curie().?;
    try std.testing.expectEqualStrings("MS", curie.prefix);
    try std.testing.expectEqualStrings("00123", curie.local);
    try std.testing.expectEqual(@as(?u16, 123), try curie.numericLocal(u16));
    try std.testing.expect(!accession.eql(.{ .raw = "MS:123" }));
    try std.testing.expect(!accession.eql(.{ .raw = "ms:00123" }));
    for ([_][]const u8{ "", "MS", ":1", "MS:" }) |raw|
        try std.testing.expectEqual(null, (cv.Accession{ .raw = raw }).curie());
    try std.testing.expectEqual(
        @as(?u8, null),
        try (cv.Accession{ .raw = "X:abc" }).curie().?.numericLocal(u8),
    );
    try std.testing.expectError(
        error.Overflow,
        (cv.Accession{ .raw = "X:256" }).curie().?.numericLocal(u8),
    );
}

test "[unit] - [CV expansion]: expands at the reference position without overriding repetition" {
    const accession: cv.Accession = .{ .raw = "MS:1" };
    const group_entries = [_]cv.Entry{.{ .cv = .{ .accession = accession, .value = "group" } }};
    const groups = [_]cv.Group{.{ .id = "g", .entries = &group_entries }};
    const entries = [_]cv.Entry{
        .{ .user = .{ .name = "before", .value = "" } },
        .{ .group_ref = .{ .ref = "g" } },
        .{ .cv = .{ .accession = accession, .value = "local" } },
        .{ .group_ref = .{ .ref = "g" } },
    };
    var iterator: cv.EffectiveIterator = .{ .entries = &entries, .groups = &groups };
    try std.testing.expectEqualStrings("before", (try iterator.next()).?.user.name.?);
    try std.testing.expectEqualStrings("group", (try iterator.next()).?.cv.value.?);
    try std.testing.expectEqualStrings("local", (try iterator.next()).?.cv.value.?);
    try std.testing.expectEqualStrings("group", (try iterator.next()).?.cv.value.?);
    try std.testing.expectEqual(null, try iterator.next());
    try std.testing.expectEqual(null, try iterator.next());
    try std.testing.expectEqual(.repeated, try cv.findOne(&entries, &groups, accession));
    try std.testing.expectEqual(
        .missing,
        try cv.findOne(&entries, &groups, .{ .raw = "X:absent" }),
    );
    const unique = try cv.findOne(&group_entries, &.{}, accession);
    try std.testing.expectEqualStrings("group", unique.one.value.?);
    const collapsed = try cv.findOne(&.{.{ .group_ref = .{ .ref = "\t g \n" } }}, &groups, accession);
    try std.testing.expectEqualStrings("group", collapsed.one.value.?);
    try std.testing.expectError(error.DuplicateGroup, cv.findOne(&.{.{ .group_ref = .{ .ref = "g" } }}, &.{
        groups[0], .{ .id = " g ", .entries = &group_entries },
    }, accession));
}

test "[failure] - [CV expansion]: bounds missing, duplicate, and nested references" {
    const entries = [_]cv.Entry{.{ .group_ref = .{ .ref = "g" } }};
    const group: cv.Group = .{ .id = "g", .entries = &.{} };
    try std.testing.expectError(error.MissingGroup, cv.findOne(&entries, &.{}, .{ .raw = "MS:1" }));
    try std.testing.expectError(
        error.DuplicateGroup,
        cv.findOne(&entries, &.{ group, group }, .{ .raw = "MS:1" }),
    );
    const nested: cv.Group = .{ .id = "g", .entries = &entries };
    try std.testing.expectError(
        error.NestedGroup,
        cv.findOne(&entries, &.{nested}, .{ .raw = "MS:1" }),
    );
    var iterator: cv.EffectiveIterator = .{
        .entries = &entries,
        .groups = &.{group},
        .remaining_work = 1,
    };
    try std.testing.expectError(error.ExpansionLimit, iterator.next());
    try std.testing.expectError(error.ExpansionLimit, iterator.next());
}

test "[edge] - [CV lexical values]: distinguishes absence, empty, invalid, and overflow" {
    try std.testing.expect(try cv.parseBoolean(" \ttrue\r\n"));
    try std.testing.expect(!(try cv.parseBoolean("0")));
    try std.testing.expectError(error.MissingValue, cv.parseBoolean(null));
    try std.testing.expectError(error.EmptyValue, cv.parseBoolean(" \t"));
    try std.testing.expectError(error.InvalidValue, cv.parseBoolean("TRUE"));
    try std.testing.expectError(error.InvalidValue, cv.parseBoolean("t rue"));
    try std.testing.expectEqual(@as(i8, -128), try cv.parseInteger(i8, " -128 "));
    try std.testing.expectEqual(@as(u8, 255), try cv.parseInteger(u8, "+255"));
    try std.testing.expectError(error.Overflow, cv.parseInteger(i8, "128"));
    for ([_][]const u8{ "+", "1_0", "0xff", "1.0", "1 0" }) |lexical|
        try std.testing.expectError(error.InvalidValue, cv.parseInteger(i32, lexical));
}

test "[edge] - [CV floating values]: checks decimal syntax, range, and special spellings" {
    inline for (.{ f32, f64 }) |T| {
        try std.testing.expectEqual(@as(T, 125), try cv.parseFloat(T, " \t+1.25E2\r\n"));
        try std.testing.expectEqual(@as(T, 0.5), try cv.parseFloat(T, ".5"));
        try std.testing.expectEqual(@as(T, 1), try cv.parseFloat(T, "1."));
        try std.testing.expect(std.math.signbit(try cv.parseFloat(T, "-0")));
        try std.testing.expectEqual(std.math.inf(T), try cv.parseFloat(T, "INF"));
        try std.testing.expectEqual(-std.math.inf(T), try cv.parseFloat(T, "-INF"));
        try std.testing.expect(std.math.isNan(try cv.parseFloat(T, "NaN")));
        try std.testing.expectError(error.MissingValue, cv.parseFloat(T, null));
        try std.testing.expectError(error.EmptyValue, cv.parseFloat(T, " \n"));
        try std.testing.expectError(error.Overflow, cv.parseFloat(T, "1e9999"));
        try std.testing.expectEqual(@as(T, 0), try cv.parseFloat(T, "1e-9999"));
        for ([_][]const u8{ "+", ".", "1e", "1e+", "0x1p2", "1_0", "1 0", "inf", "+INF", "nan", "-NaN" }) |value|
            try std.testing.expectError(error.InvalidValue, cv.parseFloat(T, value));
    }
    try std.testing.expectError(error.Overflow, cv.parseFloat(f32, "3.5e38"));
    try std.testing.expect(std.math.isFinite(try cv.parseFloat(f64, "3.5e38")));
}
