//! Verifies exact vocabulary identities, lexical interpretation, and bounded group expansion.

const std = @import("std");
const cv = @import("zmz").mzml.cv;

// A small resource with every modeled field, parsed as a newer release would be at run time.
const GRAPH_OBO =
    \\format-version: 1.2
    \\data-version: current
    \\ontology: example
    \\remark: example resource
    \\[Term]
    \\id: X:1
    \\name: root
    \\[Term]
    \\id: X:2
    \\name: child
    \\def: "A child term." [X:ref]
    \\synonym: "kid" EXACT []
    \\is_a: X:1 ! root
    \\alt_id: X:02
    \\subset: core
    \\xref: binary-data-type:MS\:1000523 "64-bit float"
    \\[Term]
    \\id: X:4
    \\name: dangling
    \\is_a: X:missing
    \\[Term]
    \\id: X:5
    \\name: typed
    \\relationship: has_value_type X:6
    \\relationship: has_units UO:0000010 {cardinality="1"}
    \\[Term]
    \\id: X:6
    \\name: integer
    \\relationship: has_value_type xsd:integer
    \\[Term]
    \\id: X:7
    \\name: cyclic type
    \\relationship: has_value_type X:7
    \\[Term]
    \\id: X:8
    \\name: retired
    \\is_obsolete: true
    \\replaced_by: X:2
    \\consider: X:5
;
const GRAPH_IDENTITY: cv.Vocabulary.Identity = .{ .key = "example", .version = "current", .namespace = "X", .source_version = "current" };

test "[unit] - [CV vocabulary]: resolves exact identities, the graph, and term metadata" {
    const graph = try cv.Vocabulary.parseObo(std.testing.allocator, GRAPH_OBO, GRAPH_IDENTITY);
    defer graph.deinit();
    const resource = &graph.vocabulary;
    const alias = resource.lookup("X:02").?;
    try std.testing.expect(alias.alternate_id);
    try std.testing.expectEqualStrings("X:2", alias.term.id());
    try std.testing.expectEqual(null, resource.lookup("x:2"));
    try std.testing.expect(try resource.isA("X:02", "X:1"));
    try std.testing.expect(try resource.isA("X:02", "X:2"));
    try std.testing.expect(!try resource.isA("X:1", "X:2"));
    try std.testing.expect(!try resource.isA("X:4", "X:1"));
    try std.testing.expectError(error.UnknownTerm, resource.isA("X:2", "X:missing"));

    var types: [2][]const u8 = undefined;
    const resolved = try resource.valueTypes("X:5", &types, 3);
    try std.testing.expectEqual(@as(usize, 1), resolved.len);
    try std.testing.expectEqualStrings("xsd:integer", resolved[0]);
    try std.testing.expectError(error.TraversalLimit, resource.valueTypes("X:5", &types, 2));
    try std.testing.expectError(error.OutputTooSmall, resource.valueTypes("X:5", &.{}, 3));
    try std.testing.expectError(error.Cycle, resource.valueTypes("X:7", &types, 10));
    try std.testing.expectEqual(@as(usize, 0), (try resource.valueTypes("X:1", &types, 1)).len);

    const typed = resource.lookup("X:5").?.term;
    var units = typed.targets("has_units");
    const unit = units.nextTarget().?;
    try std.testing.expectEqualStrings("UO:0000010", unit.id);
    try std.testing.expectEqual(null, unit.term);
    try std.testing.expectEqual(null, units.next());
    var edges = typed.relationships();
    try std.testing.expectEqualStrings("X:6", edges.next().?.target.term.?.id());
    try std.testing.expectEqualStrings("{cardinality=\"1\"}", edges.next().?.modifiers);
    // A parent the resource has no term for is a target, not a term.
    var dangling = resource.lookup("X:4").?.term.targets("is_a");
    try std.testing.expectEqualStrings("X:missing", dangling.next().?);
    var no_terms = resource.lookup("X:4").?.term.parents();
    try std.testing.expectEqual(null, no_terms.next());

    const child = alias.term;
    try std.testing.expectEqualStrings("child", child.name());
    try std.testing.expectEqualStrings("A child term.", child.definition().?.value);
    try std.testing.expectEqualStrings("[X:ref]", child.definition().?.suffix);
    var synonyms = child.synonyms();
    try std.testing.expectEqualStrings("kid", synonyms.next().?.value);
    var xrefs = child.xrefs();
    try std.testing.expectEqualStrings("binary-data-type:MS:1000523", xrefs.next().?.value);
    var alternates = child.alternateIds();
    try std.testing.expectEqualStrings("X:02", alternates.next().?);
    try std.testing.expect(child.inSubset("core"));
    try std.testing.expect(!child.inSubset("mzQC"));
    var ancestors = child.ancestors();
    try std.testing.expectEqualStrings("X:1", ancestors.next().?.id());
    try std.testing.expectEqual(null, ancestors.next());
    const retired = resource.lookup("X:8").?.term;
    try std.testing.expect(retired.obsolete());
    var replacement = retired.replacedBy();
    try std.testing.expectEqualStrings("X:2", replacement.next().?);
    var consider = retired.consider();
    try std.testing.expectEqualStrings("X:5", consider.next().?);
    // A parsed resource keeps its source fields and headers; it records no release history.
    var fields = child.fields();
    try std.testing.expectEqualStrings("id", fields.next().?.tag);
    try std.testing.expectEqualStrings("remark", resource.header(3).?.tag);
    try std.testing.expectEqual(null, resource.header(4));
    try std.testing.expectEqual(null, child.firstRelease());
    try std.testing.expectEqual(@as(usize, 0), resource.releases().count());
    try std.testing.expectEqual(@as(?usize, null), resource.findRelease("current"));
}

test "[failure] - [CV vocabulary]: refuses an is_a cycle and a version that differs from the expected" {
    const cycle = "format-version: 1.2\ndata-version: current\n[Term]\nid: X:1\nname: a\nis_a: X:2\n[Term]\nid: X:2\nname: b\nis_a: X:1\n";
    try std.testing.expectError(error.Cycle, cv.Vocabulary.parseObo(std.testing.allocator, cycle, GRAPH_IDENTITY));
    var newer = GRAPH_IDENTITY;
    newer.source_version = "next";
    try std.testing.expectError(error.SourceVersionMismatch, cv.Vocabulary.parseObo(std.testing.allocator, GRAPH_OBO, newer));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const owned = try cv.Vocabulary.parseObo(allocator, GRAPH_OBO, GRAPH_IDENTITY);
            owned.deinit();
        }
    }.run, .{});
}

test "[unit] - [CV vocabulary]: bundled resources carry subsets and release history" {
    const ms = &cv.Resolver.BUNDLED[0];
    try std.testing.expect(ms.releases().count() > 200);
    try std.testing.expectEqualStrings("3.80.0_rc1", ms.releases().get(0));
    try std.testing.expectEqualStrings(ms.identity.source_version, ms.releases().get(ms.releases().count() - 1));
    try std.testing.expectEqual(@as(?usize, 0), ms.findRelease("3.80.0_rc1"));
    try std.testing.expectEqualStrings("4.1.204", ms.releases().get(ms.findRelease("4.1.204").?));
    try std.testing.expectEqual(@as(?usize, null), ms.findRelease("4.1"));
    try std.testing.expectEqual(@as(?usize, null), ms.findRelease("1.18.2"));
    // Present in the first recorded release: no recorded first release.
    try std.testing.expectEqual(null, ms.lookup("MS:1000514").?.term.firstRelease());
    try std.testing.expectEqualStrings("3.84.0", ms.lookup("MS:1002631").?.term.firstRelease().?);
    try std.testing.expectEqualStrings("3.89.0", ms.lookup("MS:1002455").?.term.obsoleteSince().?);
    var former = ms.lookup("MS:1000189").?.term.formerNames();
    try std.testing.expectEqualStrings("Q-Tof ultima", former.next().?.name);
    var fields = ms.lookup("MS:1000514").?.term.fields();
    try std.testing.expectEqual(null, fields.next());
    try std.testing.expectEqualStrings("format-version", ms.header(0).?.tag);
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
    try std.testing.expectEqualStrings("scan start time", result.term.match.?.term.name());
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

    const ms = &resolver.resources[0];
    const uo = &resolver.resources[1];
    try std.testing.expectEqual(ms.identity.counts.terms, ms.count());
    try std.testing.expectEqual(uo.identity.counts.terms, uo.count());
    var ms_parents = ms.lookup("UO:0000008").?.term.targets("is_a");
    try std.testing.expectEqualStrings("UO:0000001", ms_parents.next().?);
    var uo_parents = uo.lookup("UO:0000008").?.term.targets("is_a");
    _ = uo_parents.next();
    try std.testing.expectEqualStrings("UO:1000008", uo_parents.next().?);
    try std.testing.expect(ms.lookup("UO:0000149").?.alternate_id);
    try std.testing.expectEqualStrings("UO:0000003", ms.lookup("UO:0000149").?.term.id());
    try std.testing.expect(try ms.isA("MS:1003870", "MS:1000513"));
    var types: [3][]const u8 = undefined;
    const resolved_types = try ms.valueTypes("MS:1003163", &types, 10);
    try std.testing.expectEqual(@as(usize, 1), resolved_types.len);
    try std.testing.expectEqualStrings("xsd:integer", resolved_types[0]);

    const obsolete = try resolver.resolve(.{ .cv_ref = "mass-spec", .accession = .{ .raw = "MS:1000266" } });
    try std.testing.expect(obsolete.term.issues.obsolete);
    try std.testing.expectEqualStrings("MS:1000266", obsolete.source.accession.?.raw);
    var replacement = obsolete.term.match.?.term.replacedBy();
    try std.testing.expectEqualStrings("MS:1000393", replacement.next().?);
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
    const graph = try cv.Vocabulary.parseObo(std.testing.allocator, GRAPH_OBO, GRAPH_IDENTITY);
    defer graph.deinit();
    const resources = [_]cv.Vocabulary{graph.vocabulary};
    var declarations = [_]cv.Declaration{.{ .id = "local", .version = null }};
    var resolver: cv.Resolver = .{
        .resources = &resources,
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
    const graph = try cv.Vocabulary.parseObo(std.testing.allocator, GRAPH_OBO, GRAPH_IDENTITY);
    defer graph.deinit();
    const resources = [_]cv.Vocabulary{graph.vocabulary};
    const declarations = [_]cv.Declaration{.{ .id = "local", .version = null }};
    var resolver: cv.Resolver = .{ .resources = &resources, .declarations = &declarations, .max_work = 0 };
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
    const repeated: cv.Resolver.KnownVersion = .{ .resource_key = "psi-ms", .version = "4.1.248", .relationship = .historical };
    resolver.known_versions = &.{ repeated, repeated };
    try std.testing.expectError(error.ConflictingVersion, resolver.resolve(parameter));
    // A recorded release cannot be declared future.
    resolver.known_versions = &.{.{ .resource_key = "psi-ms", .version = "4.1.248", .relationship = .future }};
    try std.testing.expectError(error.ConflictingVersion, resolver.resolve(parameter));
}

test "[unit] - [CV resolver]: resolves against a release parsed at run time" {
    const bundled = cv.Resolver.BUNDLED[0].identity;
    const owned = try cv.Vocabulary.parseObo(std.testing.allocator,
        \\format-version: 1.2
        \\data-version: 9.0.0
        \\ontology: ms
        \\[Term]
        \\id: MS:1000016
        \\name: scan start time
        \\relationship: has_units UO:0000031
        \\[Term]
        \\id: MS:9999999
        \\name: a term from a newer release
        \\
    , .{
        .key = bundled.key,
        .version = "9.0.0",
        .namespace = bundled.namespace,
        .full_name = bundled.full_name,
        .uri = bundled.uri,
        .declaration_uris = bundled.declaration_uris,
        .declaration_names = bundled.declaration_names,
        .source_version = "9.0.0",
    });
    defer owned.deinit();
    const resources = [_]cv.Vocabulary{ owned.vocabulary, cv.Resolver.BUNDLED[1] };
    const declarations = [_]cv.Declaration{
        .{ .id = "MS", .full_name = "Proteomics Standards Initiative Mass Spectrometry Ontology", .uri = "https://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo", .version = "9.0.0" },
        .{ .id = "UO", .full_name = "Unit Ontology", .uri = "https://raw.githubusercontent.com/bio-ontology-research-group/unit-ontology/master/unit.obo" },
    };
    const resolver: cv.Resolver = .{ .resources = &resources, .declarations = &declarations };
    const newer = try resolver.resolve(.{ .cv_ref = "MS", .accession = .{ .raw = "MS:9999999" }, .name = "a term from a newer release" });
    try std.testing.expectEqual(.exact, newer.term.version);
    try std.testing.expectEqualStrings("a term from a newer release", newer.term.match.?.term.name());
    const time = try resolver.resolve(.{
        .cv_ref = "MS",
        .accession = .{ .raw = "MS:1000016" },
        .name = "scan start time",
        .unit = .{ .cv_ref = "UO", .accession = .{ .raw = "UO:0000031" }, .name = "minute" },
    });
    try std.testing.expectEqual(.allowed, time.unit_allowed);
    try std.testing.expect(!time.term.issues.unrecognized_uri);
}

test "[unit] - [CV resolver]: recognizes recorded releases, earlier spellings, and former names" {
    const declarations = [_]cv.Declaration{
        // As converters wrote them: an older release, and SourceForge-era locations and names.
        .{ .id = "MS", .full_name = "Proteomics Standards Initiative Mass Spectrometry Ontology", .uri = "http://psidev.cvs.sourceforge.net/*checkout*/psidev/psi/psi-ms/mzML/controlledVocabulary/psi-ms.obo", .version = "4.1.204" },
        .{ .id = "UO", .full_name = "Unit Ontology", .uri = "http://obo.cvs.sourceforge.net/*checkout*/obo/obo/ontology/phenotype/unit.obo", .version = "09:04:2014" },
    };
    const resolver = cv.Resolver.init(&declarations);
    const renamed = try resolver.resolve(.{
        .cv_ref = "MS",
        .accession = .{ .raw = "MS:1000189" },
        .name = "Q-Tof ultima",
        .unit = .{ .cv_ref = "UO", .accession = .{ .raw = "UO:0000031" }, .name = "minute" },
    });
    try std.testing.expectEqual(.historical, renamed.term.version);
    try std.testing.expect(!renamed.term.issues.unrecognized_uri);
    try std.testing.expect(!renamed.term.issues.unrecognized_declaration_name);
    try std.testing.expect(renamed.term.issues.stale_name);
    try std.testing.expect(renamed.term.issues.former_name);
    // A release before the recorded history is not guessed from its spelling.
    try std.testing.expectEqual(.unrecognized_version, renamed.unit.version);
    try std.testing.expect(!renamed.unit.issues.unrecognized_uri);
    const wrong = try resolver.resolve(.{ .cv_ref = "MS", .accession = .{ .raw = "MS:1000189" }, .name = "not a name" });
    try std.testing.expect(wrong.term.issues.stale_name);
    try std.testing.expect(!wrong.term.issues.former_name);
}

test "[edge] - [CV vocabulary graph]: answers ancestry at any depth and identifies dangling datatype targets" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("format-version: 1.2\ndata-version: current\n");
    // A chain of 200 terms, each the child of the next, and a datatype nobody defines.
    for (0..200) |index| {
        try source.writer.print("[Term]\nid: X:{d:0>3}\nname: term\n", .{index});
        if (index < 199) try source.writer.print("is_a: X:{d:0>3}\n", .{index + 1});
    }
    try source.writer.writeAll("relationship: has_value_type X:missing\n");
    const chain = try cv.Vocabulary.parseObo(std.testing.allocator, source.written(), GRAPH_IDENTITY);
    defer chain.deinit();
    try std.testing.expect(try chain.vocabulary.isA("X:000", "X:199"));
    try std.testing.expect(!try chain.vocabulary.isA("X:199", "X:000"));
    var destination: [1][]const u8 = undefined;
    try std.testing.expectError(error.UnknownTerm, chain.vocabulary.valueTypes("X:199", &destination, 10));
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
