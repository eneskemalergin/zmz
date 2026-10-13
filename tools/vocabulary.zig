//! Generates pinned vocabulary tables and reviews explicit local OBO candidates offline.
//!
//! `inspect` checks a manifest and the digests of its two OBO files, then prints their counts and
//! monitored terms. `candidate` writes the manifest for two new OBO files and their upstream
//! commits: digests, versions, and counts filled in. `review` compares candidates with the
//! bundled tables, failing on changes nobody reviewed. `history` records each resource's releases
//! from lists of its OBO files, oldest first: when each term first appeared, became obsolete, and
//! what it was called before. `generate` reviews, generates the tables twice, and writes
//! `OUTPUT.zig` atomically only when both runs match. `scan` resolves the parameters of explicit
//! mzML files and lists each term finding.
//! Nothing uses the network; a failure prints its error and exits with status 1.

const std = @import("std");
const zmz = @import("zmz");
const mzml = zmz.mzml;
const Vocabulary = mzml.cv.Vocabulary;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var buffer: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        stderr.interface.print("vocabulary: {s}\n", .{@errorName(err)}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
}

const Command = enum { inspect, candidate, review, history, generate, scan };

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(io, "usage: zig build vocabulary -- inspect|review MANIFEST.json PSI-MS.obo UO.obo\n" ++
        "       zig build vocabulary -- candidate MANIFEST.json PSI-MS.obo PSI-MS-COMMIT UO.obo UO-COMMIT DATE OUTPUT.json\n" ++
        "       zig build vocabulary -- history OUTPUT.json KEY LIST.txt [KEY LIST.txt ...]\n" ++
        "       zig build vocabulary -- generate MANIFEST.json HISTORY.json PSI-MS.obo UO.obo OUTPUT.zig\n" ++
        "       zig build vocabulary -- scan FILE.mzML [FILE.mzML ...]\n");
    return error.InvalidArguments;
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return usage(init.io);
    const command = std.meta.stringToEnum(Command, args[1]) orelse return usage(init.io);
    const allocator = init.arena.allocator();
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    switch (command) {
        .scan => {
            if (args.len < 3) return usage(init.io);
            for (args[2..]) |path| {
                const counts = try scan(init.gpa, init.io, path, out);
                try event(out, "scan", "", path, null, counts);
                try out.flush();
            }
        },
        .history => {
            if (args.len < 5 or (args.len - 3) % 2 != 0) return usage(init.io);
            var history: History = .{};
            var pair: usize = 3;
            while (pair < args.len) : (pair += 2) {
                const list = try readFile(allocator, init.io, args[pair + 1]);
                var paths: std.ArrayList([]const u8) = .empty;
                var lines = std.mem.tokenizeAny(u8, list, "\r\n");
                while (lines.next()) |line| try paths.append(allocator, line);
                try recordReleases(allocator, init.io, &history, args[pair], paths.items);
            }
            try publish(init.io, std.Io.Dir.cwd(), args[2], try history.render(allocator));
        },
        .candidate => {
            if (args.len != 9) return usage(init.io);
            const manifest = try readManifest(allocator, init.io, args[2]);
            var next = manifest;
            for (&next.resources, [_][]const u8{ args[3], args[5] }, [_][]const u8{ args[4], args[6] }) |*identity, path, commit| {
                const bytes = try readFile(allocator, init.io, path);
                identity.sha256 = try digestHex(allocator, bytes);
                identity.commit = commit;
                identity.retrieved = args[7];
                var probe = identity.*;
                probe.source_version = "";
                const parsed = try parseResource(allocator, bytes, probe);
                defer parsed.deinit();
                identity.source_version = try allocator.dupe(u8, dataVersion(&parsed.vocabulary));
                identity.version = try allocator.dupe(u8, releaseName(identity.key, identity.source_version));
                identity.counts = resourceCounts(&parsed.vocabulary);
            }
            try checkManifest(next);
            var written: std.Io.Writer.Allocating = .init(allocator);
            try std.json.Stringify.value(next, .{ .whitespace = .indent_2 }, &written.writer);
            try written.writer.writeByte('\n');
            try publish(init.io, std.Io.Dir.cwd(), args[8], written.written());
        },
        .inspect, .review, .generate => {
            const offset: usize = @intFromBool(command == .generate);
            const expected: usize = 5 + 2 * offset;
            if (args.len != expected) return usage(init.io);
            const manifest = try readManifest(allocator, init.io, args[2]);
            var owned: [2]*Vocabulary.Owned = undefined;
            var loaded: usize = 0;
            defer for (owned[0..loaded]) |resource| resource.deinit();
            for (&owned, manifest.resources, args[3 + offset ..][0..2]) |*resource, identity, path| {
                const bytes = try readFile(allocator, init.io, path);
                try verifyDigest(bytes, identity.sha256);
                resource.* = try parseResource(init.gpa, bytes, identity);
                loaded += 1;
                if (command != .inspect and !std.meta.eql(identity.counts, resourceCounts(&resource.*.vocabulary)))
                    return error.SnapshotCountMismatch;
            }
            const resources = [_]*const Vocabulary{ &owned[0].vocabulary, &owned[1].vocabulary };
            if (command == .inspect) {
                for (resources) |resource| {
                    try event(out, "counts", resource.identity.key, "", null, resourceCounts(resource));
                    for (0..resource.count()) |index| {
                        const term = resource.term(index);
                        if (term.obsolete()) continue;
                        const families = try monitored(resource, term);
                        if (families != 0) try event(out, "monitored", resource.identity.key, term.id(), families, term.name());
                    }
                }
                return;
            }
            const baseline = mzml.cv.Resolver.BUNDLED;
            const blocked = try review(allocator, out, baseline, &resources);
            try out.flush();
            if (blocked) return error.UnreviewedUpdate;
            if (command == .review) return;
            const history = try History.parse(allocator, try readFile(allocator, init.io, args[3]));
            var generated: std.Io.Writer.Allocating = .init(allocator);
            try generate(allocator, &generated.writer, &resources, &history);
            var repeated: std.Io.Writer.Allocating = .init(allocator);
            try generate(allocator, &repeated.writer, &resources, &history);
            if (!std.mem.eql(u8, generated.written(), repeated.written()))
                return error.NonDeterministicGeneration;
            try publish(init.io, std.Io.Dir.cwd(), args[6], generated.written());
        },
    }
}

// --- Manifest and sources ---

const Manifest = struct { format_version: u32, resources: [2]Vocabulary.Identity };
const MAX_SOURCE_BYTES = 32 * 1024 * 1024;

fn readManifest(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Manifest {
    const bytes = try readFile(allocator, io, path);
    const manifest = try std.json.parseFromSliceLeaky(Manifest, allocator, bytes, .{});
    try checkManifest(manifest);
    return manifest;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(MAX_SOURCE_BYTES));
}

fn publish(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    var output = try dir.createFileAtomic(io, path, .{});
    defer output.deinit(io);
    try output.file.writeStreamingAll(io, bytes);
    try output.link(io);
}

fn checkManifest(manifest: Manifest) !void {
    if (manifest.format_version != 2) return error.UnsupportedManifestVersion;
    for (manifest.resources, [_][]const u8{ "psi-ms", "uo" }) |identity, key| {
        if (!std.mem.eql(u8, identity.key, key) or identity.artifact_version != 2)
            return error.InvalidManifest;
        if (identity.commit.len != 40 or identity.sha256.len != 64)
            return error.InvalidManifest;
        for (identity.commit) |byte| if (!std.ascii.isHex(byte)) return error.InvalidManifest;
        for (identity.sha256) |byte| if (!std.ascii.isHex(byte)) return error.InvalidManifest;
        inline for (.{ "version", "source_version", "namespace", "full_name", "uri", "repository", "path", "retrieved", "license", "attribution" }) |field|
            if (@field(identity, field).len == 0) return error.InvalidManifest;
        if (!std.mem.eql(u8, identity.namespace, if (std.mem.eql(u8, key, "psi-ms")) "MS" else "UO"))
            return error.InvalidManifest;
    }
}

fn verifyDigest(bytes: []const u8, expected: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var decoded: [32]u8 = undefined;
    const hex = std.fmt.hexToBytes(&decoded, expected) catch return error.InvalidManifest;
    if (hex.len != decoded.len or !std.mem.eql(u8, &decoded, &digest))
        return error.SourceDigestMismatch;
}

fn digestHex(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

// Parses a resource and checks that the file names the ontology its key expects.
fn parseResource(allocator: std.mem.Allocator, bytes: []const u8, identity: Vocabulary.Identity) !*Vocabulary.Owned {
    const owned = try Vocabulary.parseObo(allocator, bytes, identity);
    errdefer owned.deinit();
    const ontology = headerValue(&owned.vocabulary, "ontology") orelse return error.MissingField;
    const expected: ?[]const u8 = if (std.mem.eql(u8, identity.key, "psi-ms")) "ms" else if (std.mem.eql(u8, identity.key, "uo")) "uo" else null;
    if (expected) |name| if (!std.mem.eql(u8, ontology, name)) return error.SourceOntologyMismatch;
    return owned;
}

fn headerValue(resource: *const Vocabulary, tag: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (resource.header(index)) |field| : (index += 1)
        if (std.mem.eql(u8, field.tag, tag)) return field.value;
    return null;
}

fn dataVersion(resource: *const Vocabulary) []const u8 {
    return headerValue(resource, "data-version") orelse "";
}

// The release name a manifest records: UO's data-version is `releases/DATE`.
fn releaseName(key: []const u8, source_version: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "uo") and std.mem.startsWith(u8, source_version, "releases/"))
        return source_version["releases/".len..];
    return source_version;
}

// --- External mzML inspection ---

const ScanCounts = struct {
    records: usize = 0,
    parameters: usize = 0,
    resolved: usize = 0,
    missing_references: usize = 0,
    unknown_resources: usize = 0,
    unknown_accessions: usize = 0,
    stale_names: usize = 0,
    former_names: usize = 0,
    obsolete: usize = 0,
    units: usize = 0,
    resolved_units: usize = 0,
    partial_units: usize = 0,
    disallowed_units: usize = 0,
};

fn scan(allocator: std.mem.Allocator, io: std.Io, path: []const u8, output: *std.Io.Writer) !ScanCounts {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var input = file.reader(io, &buffer);
    var reader = try mzml.StreamReader.init(allocator, &input.interface, .{ .payload = .skip });
    defer reader.deinit();
    errdefer if (reader.diagnostic()) |report| std.debug.print("{s}: {f}\n", .{ path, report });
    const header = try reader.readHeader();
    const declarations = try header.cvDeclarations(allocator);
    defer allocator.free(declarations);
    const resolver = mzml.cv.Resolver.init(declarations);
    for (declarations) |declaration| {
        const found = try resolver.resolve(.{ .cv_ref = declaration.id });
        try event(output, "declaration", path, declaration.id orelse "", declaration, .{
            .resource = if (found.term.resource) |resource| resource.identity.key else null,
            .used_version = if (found.term.resource) |resource| resource.identity.version else null,
            .version_relationship = found.term.version,
            .unrecognized_uri = found.term.issues.unrecognized_uri,
            .unrecognized_name = found.term.issues.unrecognized_declaration_name,
        });
    }
    var counts: ScanCounts = .{};
    var findings: std.StringArrayHashMapUnmanaged(Finding) = .empty;
    defer {
        for (findings.keys()) |key| allocator.free(key);
        findings.deinit(allocator);
    }
    try scanNode(allocator, resolver, header.document, &counts, &findings);
    try scanNode(allocator, resolver, header.run, &counts, &findings);
    while (try reader.nextRecord()) |record| {
        counts.records += 1;
        try scanNode(allocator, resolver, record.node, &counts, &findings);
    }
    for (findings.keys(), findings.values()) |key, finding| try event(output, "term", path, key, null, finding);
    return counts;
}

// One accession and name pair the file uses with a finding: how often, and what was found.
const Finding = struct {
    occurrences: usize = 0,
    unknown: bool = false,
    obsolete: bool = false,
    stale_name: bool = false,
    former_name: bool = false,
    unit_disallowed: bool = false,
};

fn scanNode(
    allocator: std.mem.Allocator,
    resolver: mzml.cv.Resolver,
    node: mzml.model.Node,
    counts: *ScanCounts,
    findings: *std.StringArrayHashMapUnmanaged(Finding),
) !void {
    for (node.params) |entry| {
        const parameter: mzml.cv.Param = switch (entry) {
            .cv => |param| param,
            .user => |param| .{ .unit = param.unit },
            .group_ref => continue,
        };
        const found = try resolver.resolve(parameter);
        if (entry == .cv) {
            const issues = found.term.issues;
            counts.parameters += 1;
            counts.resolved += @intFromBool(found.term.match != null);
            counts.missing_references += @intFromBool(issues.missing_reference or issues.missing_declaration);
            counts.unknown_resources += @intFromBool(issues.unrecognized_resource);
            counts.unknown_accessions += @intFromBool(issues.unknown_accession);
            counts.stale_names += @intFromBool(issues.stale_name);
            counts.former_names += @intFromBool(issues.former_name);
            counts.obsolete += @intFromBool(issues.obsolete);
            const disallowed = found.unit_allowed == .disallowed;
            if (issues.unknown_accession or issues.obsolete or issues.stale_name or disallowed) {
                const key = try std.fmt.allocPrint(allocator, "{s}\t{s}", .{
                    if (parameter.accession) |accession| accession.raw else "",
                    parameter.name orelse "",
                });
                const slot = try findings.getOrPut(allocator, key);
                if (slot.found_existing) allocator.free(key) else slot.value_ptr.* = .{
                    .unknown = issues.unknown_accession,
                    .obsolete = issues.obsolete,
                    .stale_name = issues.stale_name,
                    .former_name = issues.former_name,
                    .unit_disallowed = disallowed,
                };
                slot.value_ptr.occurrences += 1;
            }
        }
        counts.units += @intFromBool(found.unit_fields != .absent);
        counts.resolved_units += @intFromBool(found.unit.match != null);
        counts.partial_units += @intFromBool(found.unit_fields == .partial);
        counts.disallowed_units += @intFromBool(found.unit_allowed == .disallowed);
    }
    for (node.children) |child| try scanNode(allocator, resolver, child, counts, findings);
}

// --- Update review ---

const FAMILY_ROOTS = [_][]const u8{ "MS:1000513", "MS:1000518", "MS:1000572" };

fn monitored(resource: *const Vocabulary, term: Vocabulary.Term) !u3 {
    if (!std.mem.eql(u8, resource.identity.key, "psi-ms") or term.obsolete()) return 0;
    var families: u3 = 0;
    for (FAMILY_ROOTS, 0..) |root, index| {
        if (std.mem.eql(u8, term.id(), root)) continue;
        if (resource.lookup(root) == null) continue;
        if (try resource.isA(term.id(), root))
            families |= @as(u3, 1) << @intCast(index);
    }
    return families;
}

fn event(writer: *std.Io.Writer, kind: []const u8, resource: []const u8, accession: []const u8, before: anytype, after: anytype) !void {
    try std.json.Stringify.value(.{
        .format_version = @as(u32, 3),
        .kind = kind,
        .resource = resource,
        .accession = accession,
        .before = before,
        .after = after,
    }, .{}, writer);
    try writer.writeByte('\n');
}

const RelationView = struct { kind: []const u8, target: []const u8, modifiers: []const u8 };

// A term's modeled metadata as plain values, for comparison and reports.
const TermView = struct {
    id: []const u8,
    name: []const u8,
    obsolete: bool,
    definition: ?Vocabulary.Text,
    synonyms: []const Vocabulary.Text,
    alternate_ids: []const []const u8,
    replaced_by: []const []const u8,
    consider: []const []const u8,
    parents: []const []const u8,
    relationships: []const RelationView,
    xrefs: []const Vocabulary.Text,
    subsets: []const []const u8,
};

fn view(allocator: std.mem.Allocator, term: Vocabulary.Term) !TermView {
    var parents: std.ArrayList([]const u8) = .empty;
    var targets = term.targets("is_a");
    while (targets.next()) |parent| try parents.append(allocator, parent);
    var relationships: std.ArrayList(RelationView) = .empty;
    var edges = term.relationships();
    while (edges.next()) |edge| try relationships.append(allocator, .{ .kind = edge.kind, .target = edge.target.id, .modifiers = edge.modifiers });
    return .{
        .id = term.id(),
        .name = term.name(),
        .obsolete = term.obsolete(),
        .definition = term.definition(),
        .synonyms = try collect(allocator, Vocabulary.Text, term.synonyms()),
        .alternate_ids = try collect(allocator, []const u8, term.alternateIds()),
        .replaced_by = try collect(allocator, []const u8, term.replacedBy()),
        .consider = try collect(allocator, []const u8, term.consider()),
        .parents = parents.items,
        .relationships = relationships.items,
        .xrefs = try collect(allocator, Vocabulary.Text, term.xrefs()),
        .subsets = try collect(allocator, []const u8, term.subsets()),
    };
}

fn collect(allocator: std.mem.Allocator, comptime T: type, iterator: anytype) ![]const T {
    var items: std.ArrayList(T) = .empty;
    var all = iterator;
    while (all.next()) |item| try items.append(allocator, item);
    return items.items;
}

fn equal(a: anytype, b: @TypeOf(a)) bool {
    switch (@typeInfo(@TypeOf(a))) {
        .pointer => {
            if (a.len != b.len) return false;
            for (a, b) |left, right| if (!equal(left, right)) return false;
            return true;
        },
        .@"struct" => |structure| {
            inline for (structure.fields) |field|
                if (!equal(@field(a, field.name), @field(b, field.name))) return false;
            return true;
        },
        .optional => return if (a) |some| if (b) |other| equal(some, other) else false else b == null,
        else => return a == b,
    }
}

fn review(allocator: std.mem.Allocator, writer: *std.Io.Writer, baseline: []const Vocabulary, candidate: []const *const Vocabulary) !bool {
    if (baseline.len != candidate.len) return error.InvalidManifest;
    var blocked = false;
    for (baseline, candidate) |*old, new| {
        if (!std.mem.eql(u8, old.identity.key, new.identity.key)) return error.InvalidManifest;
        const key = new.identity.key;
        if (!equal(old.identity, new.identity))
            try event(writer, "resource", key, "", old.identity, new.identity);
        const old_headers = try headerList(allocator, old);
        const new_headers = try headerList(allocator, new);
        if (!equal(old_headers, new_headers))
            try event(writer, "headers", key, "", old_headers, new_headers);
        if (!std.mem.eql(u8, old.identity.full_name, new.identity.full_name) or
            !std.mem.eql(u8, old.identity.uri, new.identity.uri) or
            !std.mem.eql(u8, old.identity.version, new.identity.version))
            try event(writer, "writer_declaration", key, "", old.identity, new.identity);
        if (!std.mem.eql(u8, old.identity.license, new.identity.license) or
            !std.mem.eql(u8, old.identity.attribution, new.identity.attribution))
        {
            blocked = blocked or !approved(new.identity, "", .license);
            try event(writer, "blocked_license", key, "", old.identity.license, new.identity.license);
        }
        for (0..old.count()) |index| {
            const previous = old.term(index);
            const matched = new.lookup(previous.id());
            const before = try view(allocator, previous);
            if (matched == null or matched.?.alternate_id) {
                try event(writer, "missing", key, before.id, before, null);
                blocked = blocked or !approved(new.identity, before.id, .missing);
                continue;
            }
            const current = matched.?.term;
            const after = try view(allocator, current);
            inline for (std.meta.fields(TermView)) |field| {
                if (!equal(@field(before, field.name), @field(after, field.name)))
                    try event(writer, field.name, key, after.id, @field(before, field.name), @field(after, field.name));
            }
            if (before.obsolete != after.obsolete)
                try event(writer, if (after.obsolete) "newly_obsolete" else "restored", key, after.id, before.obsolete, after.obsolete);
            inline for (.{ "has_value_type", "has_units" }) |relation| {
                if (!sameTargets(previous, current, relation))
                    try event(writer, relation, key, after.id, before.relationships, after.relationships);
            }
            if (!sameBinaryXrefs(before.xrefs, after.xrefs))
                try event(writer, "binary_xrefs", key, after.id, before.xrefs, after.xrefs);
            if (!equal(before, after) and isKernel(after.id)) {
                blocked = blocked or !approved(new.identity, after.id, .kernel);
                try event(writer, "blocked_kernel", key, after.id, before.name, after.name);
            }
        }
        for (0..new.count()) |index| {
            const term = new.term(index);
            const previous = old.lookup(term.id());
            if (previous == null or previous.?.alternate_id)
                try event(writer, "added", key, term.id(), null, try view(allocator, term));
            const colon = std.mem.indexOfScalar(u8, term.id(), ':') orelse term.id().len;
            if (!std.mem.eql(u8, term.id()[0..colon], new.identity.namespace))
                try event(writer, "foreign", key, term.id(), null, term.name());
            const families = try monitored(new, term);
            if (families == 0) continue;
            const before_families = if (previous) |found| try monitored(old, found.term) else 0;
            if (families != before_families)
                try event(writer, "active_family", key, term.id(), before_families, families);
            if (try disposition(term.id(), families)) |entry| {
                try event(writer, "disposition", key, term.id(), null, .{
                    .read = entry.read,
                    .write = entry.write,
                    .preservation = entry.preservation,
                    .reason = entry.reason,
                });
            } else {
                blocked = true;
                try event(writer, "blocked_disposition", key, term.id(), null, families);
            }
        }
    }
    for (candidate, 0..) |resource, index| {
        for (candidate[index + 1 ..]) |other| for (0..resource.count()) |position| {
            const term = resource.term(position);
            if (other.lookup(term.id())) |found| {
                const mine = try view(allocator, term);
                const theirs = try view(allocator, found.term);
                try event(writer, if (equal(mine, theirs)) "duplicate_resource_id" else "resource_conflict", resource.identity.key, mine.id, mine, theirs);
            }
        };
    }
    try event(writer, "acceptance", "", "", null, .{ .blocked = blocked });
    return blocked;
}

fn headerList(allocator: std.mem.Allocator, resource: *const Vocabulary) ![]const Vocabulary.Field {
    var fields: std.ArrayList(Vocabulary.Field) = .empty;
    var index: usize = 0;
    while (resource.header(index)) |field| : (index += 1) try fields.append(allocator, field);
    return fields.items;
}

fn isKernel(id: []const u8) bool {
    inline for (comptime std.meta.declarations(mzml.model.Terms)) |declaration| {
        if (std.mem.eql(u8, id, @field(mzml.model.Terms, declaration.name).raw)) return true;
    }
    for (DISPOSITIONS) |entry| {
        if (entry.family == 1) continue;
        for (entry.terms) |known| if (std.mem.eql(u8, id, known)) return true;
    }
    return false;
}

const Approval = struct {
    resource: []const u8,
    commit: []const u8,
    sha256: []const u8,
    accession: []const u8,
    change: enum { missing, kernel, license },
    evidence: []const u8,
};

// Approval records require upstream intent or codec/writer review evidence for these exact bytes.
const APPROVALS: []const Approval = &.{};

fn approved(identity: Vocabulary.Identity, accession: []const u8, change: @FieldType(Approval, "change")) bool {
    for (APPROVALS) |approval|
        if (approvalMatches(approval, identity, accession, change)) return true;
    return false;
}

fn approvalMatches(approval: Approval, identity: Vocabulary.Identity, accession: []const u8, change: @FieldType(Approval, "change")) bool {
    return approval.change == change and approval.evidence.len != 0 and
        std.mem.eql(u8, approval.resource, identity.key) and
        std.mem.eql(u8, approval.commit, identity.commit) and
        std.mem.eql(u8, approval.sha256, identity.sha256) and
        std.mem.eql(u8, approval.accession, accession);
}

fn sameTargets(a: Vocabulary.Term, b: Vocabulary.Term, relation: []const u8) bool {
    var left = a.targets(relation);
    var right = b.targets(relation);
    while (left.next()) |target| {
        if (!std.mem.eql(u8, target, right.next() orelse return false)) return false;
    }
    return right.next() == null;
}

fn sameBinaryXrefs(a: []const Vocabulary.Text, b: []const Vocabulary.Text) bool {
    var position: usize = 0;
    for (a) |xref| {
        if (!std.mem.startsWith(u8, xref.value, "binary-data-type:")) continue;
        while (position < b.len and !std.mem.startsWith(u8, b[position].value, "binary-data-type:")) position += 1;
        if (position == b.len or !equal(xref, b[position])) return false;
        position += 1;
    }
    for (b[position..]) |xref| if (std.mem.startsWith(u8, xref.value, "binary-data-type:")) return false;
    return true;
}

const Operation = enum { supported, preserved_only, blocked };
const Disposition = struct {
    family: u3,
    terms: []const []const u8,
    read: Operation,
    write: Operation,
    preservation: Operation,
    reason: []const u8,
};

const DISPOSITIONS = [_]Disposition{
    .{ .family = 1, .terms = &.{ "MS:1000514", "MS:1000515", "MS:1000595" }, .read = .supported, .write = .supported, .preservation = .supported, .reason = "model.Terms and Builder provide primary-array access and construction" },
    .{ .family = 1, .terms = &.{
        "MS:1000516", "MS:1000517", "MS:1000617", "MS:1000786", "MS:1000820", "MS:1000821", "MS:1000822",
        "MS:1002477", "MS:1002478", "MS:1002529", "MS:1002530", "MS:1002742", "MS:1002743", "MS:1002744",
        "MS:1002745", "MS:1002816", "MS:1002893", "MS:1003006", "MS:1003007", "MS:1003008", "MS:1003143",
        "MS:1003153", "MS:1003154", "MS:1003155", "MS:1003156", "MS:1003157", "MS:1003158", "MS:1003870",
    }, .read = .preserved_only, .write = .preserved_only, .preservation = .supported, .reason = "Generic array access retains these roles; no role-specific scientific interpretation is claimed" },
    .{ .family = 2, .terms = &.{ "MS:1000519", "MS:1000521", "MS:1000522", "MS:1000523" }, .read = .supported, .write = .supported, .preservation = .supported, .reason = "binary/encoding.zig and arrays.zig implement these four primitives; binary and mzML suites check bytes and failures" },
    .{ .family = 2, .terms = &.{"MS:1001479"}, .read = .blocked, .write = .blocked, .preservation = .supported, .reason = "The array API has no string primitive; retained source arrays can be re-emitted" },
    .{ .family = 4, .terms = &.{
        "MS:1000574", "MS:1000576", "MS:1002312", "MS:1002313", "MS:1002314", "MS:1002746", "MS:1002747", "MS:1002748",
    }, .read = .supported, .write = .supported, .preservation = .supported, .reason = "Eight established pipelines in binary/encoding.zig; frozen writer bytes, Numpress vectors, and malformed-array tests" },
    .{ .family = 4, .terms = &.{
        "MS:1003088", "MS:1003089", "MS:1003090", "MS:1003780", "MS:1003781", "MS:1003782",
        "MS:1003783", "MS:1003784", "MS:1003785", "MS:1003826",
    }, .read = .blocked, .write = .blocked, .preservation = .supported, .reason = "No production implementation for these transforms; ontology recognition does not enable payload operations" },
};

fn disposition(id: []const u8, families: u3) !?Disposition {
    var found: ?Disposition = null;
    for (DISPOSITIONS) |entry| for (entry.terms) |known| {
        if (!std.mem.eql(u8, id, known)) continue;
        if (found != null) return error.DuplicateDisposition;
        if (entry.family != families) return null;
        found = entry;
    };
    return found;
}

fn resourceCounts(resource: *const Vocabulary) Vocabulary.Counts {
    var counts: Vocabulary.Counts = .{ .terms = resource.count() };
    for (0..resource.count()) |index| {
        const term = resource.term(index);
        const colon = std.mem.indexOfScalar(u8, term.id(), ':') orelse term.id().len;
        counts.native_terms += @intFromBool(std.mem.eql(u8, term.id()[0..colon], resource.identity.namespace));
        counts.obsolete += @intFromBool(term.obsolete());
        counts.alternate_ids += countOf(term.alternateIds());
        counts.replacements += countOf(term.replacedBy());
        counts.considerations += countOf(term.consider());
        counts.synonyms += countOf(term.synonyms());
        var edges = term.relationships();
        while (edges.next()) |edge| {
            counts.value_types += @intFromBool(std.mem.eql(u8, edge.kind, "has_value_type"));
            counts.units += @intFromBool(std.mem.eql(u8, edge.kind, "has_units"));
        }
        var xrefs = term.xrefs();
        while (xrefs.next()) |xref|
            counts.binary_xrefs += @intFromBool(std.mem.startsWith(u8, xref.value, "binary-data-type:"));
    }
    return counts;
}

fn countOf(iterator: anytype) usize {
    var all = iterator;
    var total: usize = 0;
    while (all.next()) |_| total += 1;
    return total;
}

// --- Release history ---

// Per resource: the releases recorded, oldest first, and per term the release it first appeared
// in (absent: present in the first recorded release), the release it became obsolete in, and its
// former canonical names with the last release using each.
const History = struct {
    resources: std.ArrayList(Resource) = .empty,

    const Resource = struct {
        key: []const u8,
        releases: std.ArrayList([]const u8) = .empty,
        first: std.StringArrayHashMapUnmanaged(u16) = .empty,
        obsolete_since: std.StringArrayHashMapUnmanaged(u16) = .empty,
        former: std.StringArrayHashMapUnmanaged(std.ArrayList(Former)) = .empty,
    };
    const Former = struct { name: []const u8, last: u16 };

    const Json = struct {
        format_version: u32,
        resources: []const struct {
            key: []const u8,
            releases: []const []const u8,
            first: std.json.ArrayHashMap(u16),
            obsolete_since: std.json.ArrayHashMap(u16),
            former_names: std.json.ArrayHashMap([]const struct { name: []const u8, last: u16 }),
        },
    };

    fn parse(allocator: std.mem.Allocator, bytes: []const u8) !History {
        const json = try std.json.parseFromSliceLeaky(Json, allocator, bytes, .{});
        if (json.format_version != 1) return error.UnsupportedHistoryVersion;
        var history: History = .{};
        for (json.resources) |entry| {
            var resource: Resource = .{ .key = entry.key };
            try resource.releases.appendSlice(allocator, entry.releases);
            for (entry.first.map.keys(), entry.first.map.values()) |id, release| {
                if (release >= entry.releases.len) return error.InvalidHistory;
                try resource.first.put(allocator, id, release);
            }
            for (entry.obsolete_since.map.keys(), entry.obsolete_since.map.values()) |id, release| {
                if (release >= entry.releases.len) return error.InvalidHistory;
                try resource.obsolete_since.put(allocator, id, release);
            }
            for (entry.former_names.map.keys(), entry.former_names.map.values()) |id, names| {
                var list: std.ArrayList(Former) = .empty;
                for (names) |name| {
                    if (name.last >= entry.releases.len) return error.InvalidHistory;
                    try list.append(allocator, .{ .name = name.name, .last = name.last });
                }
                try resource.former.put(allocator, id, list);
            }
            try history.resources.append(allocator, resource);
        }
        return history;
    }

    fn render(self: *const History, allocator: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        const writer = &out.writer;
        try writer.writeAll("{\n  \"format_version\": 1,\n  \"resources\": [");
        for (self.resources.items, 0..) |resource, index| {
            try writer.writeAll(if (index == 0) "\n    {\n" else ",\n    {\n");
            try writer.print("      \"key\": {f},\n      \"releases\": [", .{std.json.fmt(resource.key, .{})});
            for (resource.releases.items, 0..) |release, i|
                try writer.print("{s}{f}", .{ if (i == 0) "" else ", ", std.json.fmt(release, .{}) });
            try writer.writeAll("],\n");
            inline for (.{ "first", "obsolete_since" }) |name| {
                try writer.print("      \"{s}\": {{", .{name});
                const map = @field(resource, name);
                for (map.keys(), map.values(), 0..) |id, release, i|
                    try writer.print("{s}\n        {f}: {d}", .{ if (i == 0) "" else ",", std.json.fmt(id, .{}), release });
                try writer.writeAll(if (map.count() == 0) "},\n" else "\n      },\n");
            }
            try writer.writeAll("      \"former_names\": {");
            for (resource.former.keys(), resource.former.values(), 0..) |id, names, i| {
                try writer.print("{s}\n        {f}: [", .{ if (i == 0) "" else ",", std.json.fmt(id, .{}) });
                for (names.items, 0..) |name, k|
                    try writer.print("{s}{{\"name\": {f}, \"last\": {d}}}", .{ if (k == 0) "" else ", ", std.json.fmt(name.name, .{}), name.last });
                try writer.writeAll("]");
            }
            try writer.writeAll(if (resource.former.count() == 0) "}\n    }" else "\n      }\n    }");
        }
        try writer.writeAll("\n  ]\n}\n");
        return out.written();
    }

    fn findConst(self: *const History, key: []const u8) ?*const Resource {
        for (self.resources.items) |*resource| if (std.mem.eql(u8, resource.key, key)) return resource;
        return null;
    }

    // Records one more release: new terms, newly obsolete terms, and renames since `old`, the
    // release at index `old_release`.
    fn record(allocator: std.mem.Allocator, resource: *Resource, old: ?*const Release, old_release: u16, new: *const Release) !u16 {
        for (resource.releases.items) |known| if (std.mem.eql(u8, known, new.version)) return error.ReleaseAlreadyRecorded;
        if (resource.releases.items.len == std.math.maxInt(u16) - 1) return error.InvalidHistory;
        const index: u16 = @intCast(resource.releases.items.len);
        try resource.releases.append(allocator, try allocator.dupe(u8, new.version));
        const previous = old orelse return index;
        for (new.terms.keys(), new.terms.values()) |key, term| {
            const was = previous.terms.get(key) orelse {
                const id = try allocator.dupe(u8, key);
                if (!resource.first.contains(id)) try resource.first.put(allocator, id, index);
                continue;
            };
            const id = try allocator.dupe(u8, key);
            if (term.obsolete and !was.obsolete and !resource.obsolete_since.contains(id))
                try resource.obsolete_since.put(allocator, id, index);
            if (!std.mem.eql(u8, term.name, was.name)) {
                const slot = try resource.former.getOrPut(allocator, id);
                if (!slot.found_existing) slot.value_ptr.* = .empty;
                try slot.value_ptr.append(allocator, .{ .name = try allocator.dupe(u8, was.name), .last = old_release });
            }
        }
        return index;
    }
};

// What history needs from one release: its version, and each term's name and obsolete flag.
// Read tolerantly, because old releases repeat IDs and fields the library parser refuses: the
// first stanza for an ID wins. Names decode as the library decodes them.
const Release = struct {
    version: []const u8,
    terms: std.StringArrayHashMapUnmanaged(State) = .empty,

    const State = struct { name: []const u8, obsolete: bool };

    fn read(allocator: std.mem.Allocator, bytes: []const u8) !Release {
        var release: Release = .{ .version = "" };
        var in_term = false;
        var id: ?[]const u8 = null;
        var state: State = .{ .name = "", .obsolete = false };
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (true) {
            const next = lines.next();
            const line = if (next) |physical| fieldText(physical) else "";
            if (next == null or (line.len != 0 and line[0] == '[')) {
                if (id) |key| if (!release.terms.contains(key)) try release.terms.put(allocator, key, state);
                id = null;
                state = .{ .name = "", .obsolete = false };
                if (next == null) break;
                in_term = std.mem.eql(u8, line, "[Term]");
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const tag = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (!in_term) {
                if (std.mem.eql(u8, tag, "data-version") and release.version.len == 0) release.version = value;
            } else if (std.mem.eql(u8, tag, "id")) {
                if (id == null) id = value;
            } else if (std.mem.eql(u8, tag, "name")) {
                if (state.name.len == 0) state.name = try decodeName(allocator, value);
            } else if (std.mem.eql(u8, tag, "is_obsolete")) {
                state.obsolete = std.mem.eql(u8, value, "true");
            }
        }
        if (release.version.len == 0) return error.MissingField;
        return release;
    }

    // A line without its trailing comment and surrounding blanks.
    fn fieldText(physical: []const u8) []const u8 {
        const line = std.mem.trim(u8, physical, " \t\r");
        var i: usize = 0;
        while (i < line.len) : (i += 1) switch (line[i]) {
            '\\' => i += 1,
            '!' => return std.mem.trimEnd(u8, line[0..i], " \t"),
            else => {},
        };
        return line;
    }

    // The name before any `{...}` modifiers, with OBO escapes decoded.
    fn decodeName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) switch (raw[i]) {
            '\\' => {
                i += 1;
                if (i == raw.len) return error.InvalidEscape;
                try result.append(allocator, switch (raw[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'W' => ' ',
                    else => raw[i],
                });
            },
            '{' => break,
            else => try result.append(allocator, raw[i]),
        };
        return std.mem.trimEnd(u8, result.items, " \t");
    }
};

// Records one resource's releases from its OBO files, oldest first; a file repeating the previous
// file's data-version adds nothing.
fn recordReleases(allocator: std.mem.Allocator, io: std.Io, history: *History, key: []const u8, paths: []const []const u8) !void {
    if (history.findConst(key) != null) return error.DuplicateResource;
    try history.resources.append(allocator, .{ .key = try allocator.dupe(u8, key) });
    const resource = &history.resources.items[history.resources.items.len - 1];
    var previous: ?Release = null;
    var previous_release: u16 = 0;
    for (paths) |path| {
        const release = try Release.read(allocator, try readFile(allocator, io, path));
        const known = for (resource.releases.items) |item| {
            if (std.mem.eql(u8, item, release.version)) break true;
        } else false;
        if (known) continue;
        previous_release = try History.record(allocator, resource, if (previous) |*old| old else null, previous_release, &release);
        previous = release;
    }
}

// --- Generated tables ---

fn generate(allocator: std.mem.Allocator, writer: *std.Io.Writer, resources: []const *const Vocabulary, history: *const History) !void {
    var raw: std.Io.Writer.Allocating = .init(allocator);
    const w = &raw.writer;
    try w.writeAll("//! Generated vocabulary tables, artifact format 2; regenerate with the vocabulary command.\n\n" ++
        "const Vocabulary = @import(\"vocabulary.zig\");\n\npub const RESOURCES = [_]Vocabulary{\n");
    for (resources, 0..) |resource, index| {
        try w.writeAll(".{ .identity = ");
        try writeZig(w, resource.identity);
        try w.print(", .core = &CORE_{d}, .tiers = .{{ .bundled = {d} }} }},\n", .{ index, index });
    }
    try w.writeAll("};\n\npub const CLOSURES = [_]Vocabulary.Closure{");
    for (0..resources.len) |index| try w.print("CLOSURE_{d},", .{index});
    try w.writeAll("};\n\npub const DETAILS = [_]Vocabulary.Details{");
    for (0..resources.len) |index| try w.print("DETAILS_{d},", .{index});
    try w.writeAll("};\n\npub const HISTORIES = [_]?Vocabulary.History{");
    for (resources, 0..) |resource, index| {
        if (history.findConst(resource.identity.key) != null) try w.print("HISTORY_{d},", .{index}) else try w.writeAll("null,");
    }
    try w.writeAll("};\n");
    for (resources, 0..) |resource, index| {
        const parsed = resource.tiers.parsed;
        try w.print("\nconst CORE_{d}: Vocabulary.Core = ", .{index});
        try writeZig(w, resource.core.*);
        try w.print(";\n\nconst CLOSURE_{d}: Vocabulary.Closure = ", .{index});
        try writeZig(w, parsed.closure);
        try w.print(";\n\nconst DETAILS_{d}: Vocabulary.Details = ", .{index});
        try writeZig(w, parsed.details);
        try w.writeAll(";\n");
        if (history.findConst(resource.identity.key)) |recorded| {
            try w.print("\nconst HISTORY_{d}: Vocabulary.History = ", .{index});
            try writeZig(w, try historyTables(allocator, recorded, resource));
            try w.writeAll(";\n");
        }
    }
    const source = try allocator.dupeZ(u8, raw.written());
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidGeneratedSource;
    try writer.writeAll(try tree.renderAlloc(allocator));
}

// The history tables in the resource's term order.
fn historyTables(allocator: std.mem.Allocator, recorded: *const History.Resource, resource: *const Vocabulary) !Vocabulary.History {
    const terms = resource.count();
    const first = try allocator.alloc(u16, terms);
    const obsolete_since = try allocator.alloc(u16, terms);
    var starts: std.ArrayList(u32) = .empty;
    var items: std.ArrayList(Vocabulary.FormerName) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    try starts.append(allocator, 0);
    for (0..terms) |index| {
        const id = resource.term(index).id();
        first[index] = recorded.first.get(id) orelse Vocabulary.NO_RELEASE;
        obsolete_since[index] = recorded.obsolete_since.get(id) orelse Vocabulary.NO_RELEASE;
        if (recorded.former.get(id)) |list| for (list.items) |former| {
            try items.append(allocator, .{ .release = former.last, .name = @intCast(names.items.len) });
            try names.append(allocator, former.name);
        };
        try starts.append(allocator, @intCast(items.items.len));
    }
    const by_text = try allocator.alloc(u16, recorded.releases.items.len);
    for (by_text, 0..) |*slot, index| slot.* = @intCast(index);
    std.mem.sort(u16, by_text, recorded.releases.items, struct {
        fn less(releases: []const []const u8, a: u16, b: u16) bool {
            return std.mem.lessThan(u8, releases[a], releases[b]);
        }
    }.less);
    return .{
        .releases = try stringsOf(allocator, recorded.releases.items),
        .by_text = by_text,
        .first = first,
        .obsolete_since = obsolete_since,
        .former = .{ .starts = starts.items, .items = items.items },
        .former_names = try stringsOf(allocator, names.items),
    };
}

fn stringsOf(allocator: std.mem.Allocator, items: []const []const u8) !Vocabulary.Strings {
    var text: std.ArrayList(u8) = .empty;
    var starts: std.ArrayList(u32) = .empty;
    try starts.append(allocator, 0);
    for (items) |item| {
        try text.appendSlice(allocator, item);
        try starts.append(allocator, @intCast(text.items.len));
    }
    return .{ .text = text.items, .starts = starts.items };
}

fn writeZig(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.child == u8) return writeString(writer, value);
            try writer.writeAll("&.{");
            const numbers = @typeInfo(pointer.child) == .int or pointer.child == bool;
            for (value, 0..) |item, i| {
                if (numbers and i % 24 == 0) try writer.writeByte('\n');
                try writeZig(writer, item);
                try writer.writeAll(if (numbers) "," else ",\n");
            }
            try writer.writeAll("}");
        },
        .@"struct" => |structure| {
            try writer.writeAll(".{");
            inline for (structure.fields) |field| {
                try writer.print(".{s}=", .{field.name});
                try writeZig(writer, @field(value, field.name));
                try writer.writeAll(",");
            }
            try writer.writeAll("}");
        },
        .optional => if (value) |some| {
            try writeZig(writer, some);
        } else {
            try writer.writeAll("null");
        },
        .int, .bool => try writer.print("{any}", .{value}),
        else => @compileError("unsupported generated field"),
    }
}

// A Zig string literal: printable bytes as they are, others escaped.
fn writeString(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (bytes) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11...31, 127 => try writer.print("\\x{x:0>2}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

// --- Tests ---

const EXAMPLE_IDENTITY: Vocabulary.Identity = .{
    .key = "example",
    .namespace = "X",
    .version = "current",
    .source_version = "current",
};
const EXAMPLE_OBO =
    \\format-version: 1.2
    \\data-version: current
    \\ontology: example
    \\[Term]
    \\id: X:2
    \\name: child\Wname
    \\def: "Quoted \"name\" and colon\: here" [X:ref]
    \\synonym: "alias" EXACT []
    \\is_a: X:1 ! root
    \\alt_id: X:02
    \\subset: core
    \\relationship: has_value_type xsd:integer
    \\relationship: has_units UO:0000010
    \\xref: binary-data-type:MS\:1000523 "64-bit float"
    \\[Term]
    \\id: X:1
    \\name: root
    \\is_obsolete: true
    \\replaced_by: X:2
    \\consider: X:3
;

test "[unit] - [vocabulary generation]: emits repeatable tables that parse back as Zig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const owned = try Vocabulary.parseObo(std.testing.allocator, EXAMPLE_OBO, EXAMPLE_IDENTITY);
    defer owned.deinit();
    const resource = &owned.vocabulary;
    try std.testing.expectEqualDeep(Vocabulary.Counts{
        .terms = 2,
        .native_terms = 2,
        .obsolete = 1,
        .alternate_ids = 1,
        .replacements = 1,
        .considerations = 1,
        .synonyms = 1,
        .value_types = 1,
        .units = 1,
        .binary_xrefs = 1,
    }, resourceCounts(resource));
    var history: History = .{};
    try history.resources.append(allocator, .{ .key = "example" });
    _ = try History.record(allocator, &history.resources.items[0], null, 0, &try Release.read(allocator, EXAMPLE_OBO));
    var first: std.Io.Writer.Allocating = .init(allocator);
    var second: std.Io.Writer.Allocating = .init(allocator);
    try generate(allocator, &first.writer, &.{resource}, &history);
    try generate(allocator, &second.writer, &.{resource}, &history);
    try std.testing.expectEqualStrings(first.written(), second.written());
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "child name") != null);
    var short = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, generate(allocator, &short, &.{resource}, &history));
}

test "[unit] - [vocabulary history]: records new, newly obsolete, and renamed terms by release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const header = "format-version: 1.2\nontology: example\n";
    const releases = [_][]const u8{
        header ++ "data-version: 1\n[Term]\nid: X:1\nname: one\n",
        header ++ "data-version: 2\n[Term]\nid: X:1\nname: uno\n[Term]\nid: X:2\nname: two\n",
        header ++ "data-version: 3\n[Term]\nid: X:1\nname: uno\nis_obsolete: true\n[Term]\nid: X:2\nname: two\n",
    };
    var history: History = .{};
    try history.resources.append(allocator, .{ .key = "example" });
    var previous: ?Release = null;
    var previous_release: u16 = 0;
    for (releases) |bytes| {
        const release = try Release.read(allocator, bytes);
        previous_release = try History.record(allocator, &history.resources.items[0], if (previous) |*old| old else null, previous_release, &release);
        previous = release;
    }
    const recorded = &history.resources.items[0];
    try std.testing.expectEqual(@as(?u16, 1), recorded.first.get("X:2"));
    try std.testing.expectEqual(@as(?u16, null), recorded.first.get("X:1"));
    try std.testing.expectEqual(@as(?u16, 2), recorded.obsolete_since.get("X:1"));
    try std.testing.expectEqualStrings("one", recorded.former.get("X:1").?.items[0].name);
    try std.testing.expectEqual(@as(u16, 0), recorded.former.get("X:1").?.items[0].last);
    const round_trip = try History.parse(allocator, try history.render(allocator));
    try std.testing.expectEqualStrings(try history.render(allocator), try round_trip.render(allocator));
    try std.testing.expectError(error.ReleaseAlreadyRecorded, History.record(allocator, &history.resources.items[0], null, 0, &previous.?));
}

test "[unit] - [vocabulary history]: reads names as the library does, from releases it refuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const owned = try Vocabulary.parseObo(std.testing.allocator, EXAMPLE_OBO, EXAMPLE_IDENTITY);
    defer owned.deinit();
    const release = try Release.read(allocator, EXAMPLE_OBO);
    try std.testing.expectEqual(owned.vocabulary.count(), release.terms.count());
    for (0..owned.vocabulary.count()) |index| {
        const term = owned.vocabulary.term(index);
        const state = release.terms.get(term.id()).?;
        try std.testing.expectEqualStrings(term.name(), state.name);
        try std.testing.expectEqual(term.obsolete(), state.obsolete);
    }
    // A repeated ID and a repeated field: the first stanza and the first name win.
    const repeated = try Release.read(allocator, "format-version: 1.2\ndata-version: 7 ! comment\n" ++
        "[Term]\nid: X:1\nname: first\\Wname {source=\"x\"} ! note\nname: second\n[Typedef]\nid: part_of\nname: part of\n" ++
        "[Term]\nid: X:1\nname: again\nis_obsolete: true\n");
    try std.testing.expectEqualStrings("7", repeated.version);
    try std.testing.expectEqual(@as(usize, 1), repeated.terms.count());
    try std.testing.expectEqualStrings("first name", repeated.terms.get("X:1").?.name);
    try std.testing.expect(!repeated.terms.get("X:1").?.obsolete);
    try std.testing.expectError(error.MissingField, Release.read(allocator, "format-version: 1.2\n[Term]\nid: X:1\n"));
}

test "[unit] - [vocabulary update]: reports each metadata change without changing source objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const header = "format-version: 1.2\ndata-version: current\nontology: example\n";
    const old = try Vocabulary.parseObo(std.testing.allocator, header ++ "[Term]\nid: X:1\nname: old\n", EXAMPLE_IDENTITY);
    defer old.deinit();
    const next = try Vocabulary.parseObo(std.testing.allocator, header ++ "remark: changed source notice\n" ++
        "[Term]\nid: X:1\nname: new\nis_obsolete: true\ndef: \"definition\" []\nsynonym: \"synonym\" EXACT []\n" ++
        "alt_id: X:alias\nreplaced_by: X:2\nconsider: X:3\nis_a: X:parent\n" ++
        "relationship: has_value_type xsd:integer\nrelationship: has_units UO:0000010\n" ++
        "xref: binary-data-type:MS\\:1000523\nsubset: core\n", EXAMPLE_IDENTITY);
    defer next.deinit();
    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    try std.testing.expect(!try review(allocator, &report.writer, &.{old.vocabulary}, &.{&next.vocabulary}));
    const expected = [_][]const u8{
        "headers",    "name",          "obsolete", "definition", "synonyms",       "alternate_ids",  "replaced_by", "consider",
        "parents",    "relationships", "xrefs",    "subsets",    "newly_obsolete", "has_value_type", "has_units",   "binary_xrefs",
        "acceptance",
    };
    var lines = std.mem.tokenizeScalar(u8, report.written(), '\n');
    for (expected) |kind| {
        const line = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lines.next().?, .{});
        defer line.deinit();
        try std.testing.expectEqualStrings(kind, line.value.object.get("kind").?.string);
    }
    try std.testing.expectEqual(null, lines.next());
    try std.testing.expectEqualStrings("old", old.vocabulary.term(0).name());
    report.clearRetainingCapacity();
    try std.testing.expect(!try review(allocator, &report.writer, &.{next.vocabulary}, &.{&old.vocabulary}));
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"kind\":\"restored\"") != null);
}

test "[failure] - [vocabulary update]: blocks removals, kernel changes, and new family terms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const baseline = mzml.cv.Resolver.BUNDLED;
    const header = "format-version: 1.2\ndata-version: current\nontology: ms\n";
    const identity = baseline[0].identity;
    var probe = identity;
    probe.source_version = "";
    // A candidate changing one kernel term's name, and one without a monitored term.
    const kernel = try Vocabulary.parseObo(std.testing.allocator, header ++ "[Term]\nid: MS:1000523\nname: changed kernel label\n", probe);
    defer kernel.deinit();
    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    try std.testing.expect(try review(allocator, &report.writer, baseline[0..1], &.{&kernel.vocabulary}));
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"kind\":\"blocked_kernel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"kind\":\"missing\"") != null);
    const before = try Vocabulary.parseObo(std.testing.allocator, header ++
        "[Term]\nid: MS:1000513\nname: roles\n[Term]\nid: MS:1000518\nname: primitives\n[Term]\nid: MS:1000572\nname: codecs\n", probe);
    defer before.deinit();
    const after = try Vocabulary.parseObo(std.testing.allocator, header ++
        "[Term]\nid: MS:1000513\nname: roles\n[Term]\nid: MS:1000518\nname: primitives\n[Term]\nid: MS:1000572\nname: codecs\n" ++
        "[Term]\nid: MS:future\nname: new\nis_a: MS:1000572\n", probe);
    defer after.deinit();
    report.clearRetainingCapacity();
    try std.testing.expect(try review(allocator, &report.writer, &.{before.vocabulary}, &.{&after.vocabulary}));
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"kind\":\"blocked_disposition\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"kind\":\"active_family\"") != null);
}

test "[property] - [vocabulary coverage]: every active monitored term has one reviewed disposition" {
    const resource = &mzml.cv.Resolver.BUNDLED[0];
    var counts = [_]usize{ 0, 0, 0 };
    for (0..resource.count()) |index| {
        const term = resource.term(index);
        const families = try monitored(resource, term);
        if (families == 0) continue;
        try std.testing.expect((try disposition(term.id(), families)) != null);
        for (&counts, 0..) |*count, i| if (families & (@as(u3, 1) << @intCast(i)) != 0) {
            count.* += 1;
        };
    }
    try std.testing.expectEqualSlices(usize, &.{ 31, 5, 18 }, &counts);
    for (DISPOSITIONS) |entry| for (entry.terms) |id| {
        const term = resource.lookup(id).?.term;
        try std.testing.expectEqual(entry.family, try monitored(resource, term));
    };
    for (mzml.cv.Resolver.BUNDLED) |*bundled| try std.testing.expectEqualDeep(bundled.identity.counts, resourceCounts(bundled));
}

test "[property] - [vocabulary manifest]: matches pinned identities and rejects invalid metadata" {
    const resources = mzml.cv.Resolver.BUNDLED;
    const pinned = try std.json.parseFromSlice(Manifest, std.testing.allocator, @embedFile("pinned_manifest"), .{});
    defer pinned.deinit();
    try checkManifest(pinned.value);
    for (pinned.value.resources, resources) |identity, resource|
        try std.testing.expectEqualDeep(identity, resource.identity);
    var manifest: Manifest = .{ .format_version = 2, .resources = .{ resources[0].identity, resources[1].identity } };
    try checkManifest(manifest);
    manifest.format_version = 1;
    try std.testing.expectError(error.UnsupportedManifestVersion, checkManifest(manifest));
    manifest.format_version = 2;
    manifest.resources[0].artifact_version = 1;
    try std.testing.expectError(error.InvalidManifest, checkManifest(manifest));
    manifest.resources[0] = resources[0].identity;
    manifest.resources[0].commit = "main";
    try std.testing.expectError(error.InvalidManifest, checkManifest(manifest));
    try verifyDigest("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try std.testing.expectError(error.SourceDigestMismatch, verifyDigest("abd", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    try std.testing.expectError(error.InvalidManifest, verifyDigest("abc", "not hex"));
    const identity = resources[0].identity;
    var approval: Approval = .{
        .resource = identity.key,
        .commit = identity.commit,
        .sha256 = identity.sha256,
        .accession = "MS:1000523",
        .change = .kernel,
        .evidence = "synthetic review evidence",
    };
    try std.testing.expect(approvalMatches(approval, identity, "MS:1000523", .kernel));
    try std.testing.expect(!approvalMatches(approval, identity, "MS:1000523", .missing));
    try std.testing.expect(!approvalMatches(approval, identity, "MS:1000521", .kernel));
    var changed_identity = identity;
    changed_identity.sha256 = resources[1].identity.sha256;
    try std.testing.expect(!approvalMatches(approval, changed_identity, "MS:1000523", .kernel));
    changed_identity = identity;
    changed_identity.commit = resources[1].identity.commit;
    try std.testing.expect(!approvalMatches(approval, changed_identity, "MS:1000523", .kernel));
    approval.evidence = "";
    try std.testing.expect(!approvalMatches(approval, identity, "MS:1000523", .kernel));
}

test "[integration] - [vocabulary publication]: refuses replacement and removes temporary files" {
    var dir = std.testing.tmpDir(.{ .iterate = true });
    defer dir.cleanup();
    try publish(std.testing.io, dir.dir, "generated.zig", "first");
    try std.testing.expectError(error.PathAlreadyExists, publish(std.testing.io, dir.dir, "generated.zig", "second"));
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("first", try dir.dir.readFile(std.testing.io, "generated.zig", &buffer));
    var entries = dir.dir.iterate();
    try std.testing.expectEqualStrings("generated.zig", (try entries.next(std.testing.io)).?.name);
    try std.testing.expectEqual(null, try entries.next(std.testing.io));
}
