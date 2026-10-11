//! Generates pinned vocabulary tables and reviews explicit local OBO candidates offline.
//!
//! `inspect` checks a manifest and the digests of its two OBO files, then prints their counts and
//! monitored terms. `review` also checks the manifest's expected counts and compares the candidates
//! with the bundled tables, failing on changes nobody reviewed. `generate` reviews, generates the
//! tables twice, and writes `OUTPUT.zig` atomically only when both runs match. `scan` resolves the
//! parameters of explicit mzML files. Nothing uses the network; a failure prints its error and
//! exits with status 1.

const std = @import("std");
const zmz = @import("zmz");
const mzml = zmz.mzml;
const Vocabulary = mzml.cv.Vocabulary;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var buffer: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buffer);
        stderr.interface.print("vocabulary: {s}\n", .{@errorName(err)}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return usage(init.io);
    const command = std.meta.stringToEnum(Command, args[1]) orelse return usage(init.io);
    if (command == .scan) {
        if (args.len < 3) return usage(init.io);
        var buffer: [8192]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        for (args[2..]) |path| {
            const counts = try scan(init.gpa, init.io, path, &stdout.interface);
            try event(&stdout.interface, "scan", "", path, null, counts);
            try stdout.interface.flush();
        }
        return;
    }
    if (args.len != (if (command == .generate) @as(usize, 6) else 5)) return usage(init.io);
    const allocator = init.arena.allocator();
    const manifest_bytes = try readFile(allocator, init.io, args[2]);
    const manifest = try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{});
    defer manifest.deinit();
    try checkManifest(manifest.value);
    var parsed: [2]Parsed = undefined;
    var count: usize = 0;
    defer for (parsed[0..count]) |*resource| resource.deinit();
    for (&parsed, manifest.value.resources, args[3..5]) |*resource, identity, path| {
        const bytes = try readFile(allocator, init.io, path);
        try verifyDigest(bytes, identity.sha256);
        resource.* = try parse(allocator, bytes, identity);
        count += 1;
        if (command != .inspect and !std.meta.eql(identity.counts, resourceCounts(resource.resource)))
            return error.SnapshotCountMismatch;
    }
    const resources = [_]Vocabulary{ parsed[0].resource, parsed[1].resource };
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    if (command == .inspect) {
        for (resources) |resource| {
            try event(&stdout.interface, "counts", resource.identity.key, "", null, resourceCounts(resource));
            for (resource.terms) |term| if (!term.obsolete) {
                const families = try monitored(resource, term);
                if (families != 0) try event(&stdout.interface, "monitored", resource.identity.key, term.id, families, term.name);
            };
        }
        try stdout.interface.flush();
        return;
    }
    const baseline = mzml.cv.Resolver.BUNDLED;
    const blocked = try review(&stdout.interface, baseline, &resources);
    try stdout.interface.flush();
    if (blocked) return error.UnreviewedUpdate;
    if (command == .review) return;
    var generated: std.Io.Writer.Allocating = .init(allocator);
    defer generated.deinit();
    try generate(allocator, &generated.writer, &resources);
    var repeated: std.Io.Writer.Allocating = .init(allocator);
    defer repeated.deinit();
    try generate(allocator, &repeated.writer, &resources);
    if (!std.mem.eql(u8, generated.written(), repeated.written()))
        return error.NonDeterministicGeneration;
    try publish(init.io, std.Io.Dir.cwd(), args[5], generated.written());
}

const Command = enum { generate, inspect, review, scan };

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(io, "usage: zig build vocabulary -- inspect|review MANIFEST.json PSI-MS.obo UO.obo\n" ++
        "       zig build vocabulary -- generate MANIFEST.json PSI-MS.obo UO.obo OUTPUT.zig\n" ++
        "       zig build vocabulary -- scan FILE.mzML [FILE.mzML ...]\n");
    return error.InvalidArguments;
}

const Manifest = struct { format_version: u32, resources: [2]Vocabulary.Identity };
const MAX_SOURCE_BYTES = 32 * 1024 * 1024;

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
    if (manifest.format_version != 1) return error.UnsupportedManifestVersion;
    for (manifest.resources, [_][]const u8{ "psi-ms", "uo" }) |identity, key| {
        if (!std.mem.eql(u8, identity.key, key) or identity.artifact_version != 1)
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

// --- External mzML inspection ---

const ScanCounts = struct {
    records: usize = 0,
    parameters: usize = 0,
    resolved: usize = 0,
    missing_references: usize = 0,
    unknown_resources: usize = 0,
    unknown_accessions: usize = 0,
    stale_names: usize = 0,
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
        });
    }
    var counts: ScanCounts = .{};
    try scanNode(resolver, header.document, &counts);
    try scanNode(resolver, header.run, &counts);
    while (try reader.nextRecord()) |record| {
        counts.records += 1;
        try scanNode(resolver, record.node, &counts);
    }
    return counts;
}

fn scanNode(resolver: mzml.cv.Resolver, node: mzml.model.Node, counts: *ScanCounts) !void {
    for (node.params) |entry| {
        const parameter: mzml.cv.Param = switch (entry) {
            .cv => |param| param,
            .user => |param| .{ .unit = param.unit },
            .group_ref => continue,
        };
        const found = try resolver.resolve(parameter);
        if (entry == .cv) {
            counts.parameters += 1;
            counts.resolved += @intFromBool(found.term.match != null);
            counts.missing_references += @intFromBool(found.term.issues.missing_reference or found.term.issues.missing_declaration);
            counts.unknown_resources += @intFromBool(found.term.issues.unrecognized_resource);
            counts.unknown_accessions += @intFromBool(found.term.issues.unknown_accession);
            counts.stale_names += @intFromBool(found.term.issues.stale_name);
            counts.obsolete += @intFromBool(found.term.issues.obsolete);
        }
        counts.units += @intFromBool(found.unit_fields != .absent);
        counts.resolved_units += @intFromBool(found.unit.match != null);
        counts.partial_units += @intFromBool(found.unit_fields == .partial);
        counts.disallowed_units += @intFromBool(found.unit_allowed == .disallowed);
    }
    for (node.children) |child| try scanNode(resolver, child, counts);
}

// --- OBO ingestion ---

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    resource: Vocabulary,

    fn deinit(self: *Parsed) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn parse(allocator: std.mem.Allocator, bytes: []const u8, identity: Vocabulary.Identity) !Parsed {
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null)
        return error.InvalidObo;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const storage = arena.allocator();
    const source = try storage.dupe(u8, bytes);
    var terms: std.ArrayList(Vocabulary.Term) = .empty;
    var aliases: std.ArrayList(Vocabulary.Alias) = .empty;
    var headers: std.ArrayList(Vocabulary.Field) = .empty;
    var fields: std.ArrayList(Vocabulary.Field) = .empty;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    var stanza: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |physical| {
        var line = trimUnescapedEnd(std.mem.trimStart(u8, std.mem.trimEnd(u8, physical, "\r"), " \t"));
        if (line.len == 0 or line[0] == '!') continue;
        var continuation: std.ArrayList(u8) = .empty;
        while (continued(line)) {
            try continuation.appendSlice(storage, line[0 .. line.len - 1]);
            line = std.mem.trimEnd(u8, lines.next() orelse return error.InvalidObo, "\r");
        }
        if (continuation.items.len != 0) {
            try continuation.appendSlice(storage, line);
            line = continuation.items;
        }
        line = try content(line);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return error.InvalidObo;
            if (stanza) |kind| try finishStanza(storage, kind, fields.items, &terms, &ids);
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
        if (stanza == null) try headers.append(storage, field) else try fields.append(storage, field);
    }
    if (stanza) |kind| try finishStanza(storage, kind, fields.items, &terms, &ids);
    const format = try required(headers.items, "format-version");
    if (!std.mem.eql(u8, format, "1.2") and !std.mem.eql(u8, format, "1.4"))
        return error.UnsupportedOboVersion;
    const version = try required(headers.items, "data-version");
    const ontology = try required(headers.items, "ontology");
    if (std.mem.eql(u8, identity.key, "psi-ms") and !std.mem.eql(u8, ontology, "ms"))
        return error.SourceOntologyMismatch;
    if (std.mem.eql(u8, identity.key, "uo") and !std.mem.eql(u8, ontology, "uo"))
        return error.SourceOntologyMismatch;
    if (!std.mem.eql(u8, version, identity.source_version)) return error.SourceVersionMismatch;
    if (terms.items.len == 0) return error.MissingTerms;
    std.mem.sort(Vocabulary.Term, terms.items, {}, struct {
        fn less(_: void, a: Vocabulary.Term, b: Vocabulary.Term) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.less);
    for (terms.items, 0..) |term, index| for (term.alternate_ids) |alias| {
        const entry = try ids.getOrPut(storage, alias);
        if (entry.found_existing) return error.DuplicateId;
        try aliases.append(storage, .{ .id = alias, .term_index = index });
    };
    std.mem.sort(Vocabulary.Alias, aliases.items, {}, struct {
        fn less(_: void, a: Vocabulary.Alias, b: Vocabulary.Alias) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.less);
    return .{ .arena = arena, .resource = .{
        .identity = identity,
        .headers = headers.items,
        .terms = terms.items,
        .aliases = aliases.items,
    } };
}

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

fn content(line: []const u8) ![]const u8 {
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

fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
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

fn required(fields: []const Vocabulary.Field, tag: []const u8) ![]const u8 {
    var found: ?[]const u8 = null;
    for (fields) |field| if (std.mem.eql(u8, field.tag, tag)) {
        if (found != null) return error.DuplicateField;
        found = field.value;
    };
    return found orelse error.MissingField;
}

fn quotedText(allocator: std.mem.Allocator, raw: []const u8) !Vocabulary.Text {
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
    return .{ .value = raw[0..i], .suffix = trimUnescapedEnd(std.mem.trimStart(u8, raw[i..], " \t")) };
}

fn targetToken(raw: []const u8) !Vocabulary.Text {
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
    terms: *std.ArrayList(Vocabulary.Term),
    ids: *std.StringHashMapUnmanaged(void),
) !void {
    const id = try decode(allocator, (try targetToken(try required(fields, "id"))).value);
    if ((try ids.getOrPut(allocator, id)).found_existing) return error.DuplicateId;
    if (!std.mem.eql(u8, kind, "Term")) return;
    var term: Vocabulary.Term = .{
        .id = id,
        .name = try decode(allocator, nameText(try required(fields, "name"))),
        .fields = fields,
    };
    if (term.name.len == 0) return error.InvalidObo;
    var synonyms: std.ArrayList(Vocabulary.Text) = .empty;
    var xrefs: std.ArrayList(Vocabulary.Text) = .empty;
    var parents: std.ArrayList([]const u8) = .empty;
    var aliases: std.ArrayList([]const u8) = .empty;
    var replacements: std.ArrayList([]const u8) = .empty;
    var considerations: std.ArrayList([]const u8) = .empty;
    var relationships: std.ArrayList(Vocabulary.Relationship) = .empty;
    var obsolete_seen = false;
    for (fields) |field| {
        const tag = field.tag;
        const raw = field.value;
        if (std.mem.eql(u8, tag, "def")) {
            if (term.definition != null) return error.DuplicateField;
            term.definition = try quotedText(allocator, raw);
            if (!std.mem.startsWith(u8, term.definition.?.suffix, "[")) return error.InvalidObo;
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
            term.obsolete = std.mem.eql(u8, flag.value, "true");
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
            const list = if (std.mem.eql(u8, tag, "is_a")) &parents else if (std.mem.eql(u8, tag, "alt_id")) &aliases else if (std.mem.eql(u8, tag, "replaced_by")) &replacements else if (std.mem.eql(u8, tag, "consider")) &considerations else continue;
            const target = try targetToken(raw);
            try list.append(allocator, try decode(allocator, target.value));
        }
    }
    term.synonyms = synonyms.items;
    term.xrefs = xrefs.items;
    term.parents = parents.items;
    term.alternate_ids = aliases.items;
    term.replaced_by = replacements.items;
    term.consider = considerations.items;
    term.relationships = relationships.items;
    try terms.append(allocator, term);
}

// --- Update review ---

const FAMILY_ROOTS = [_][]const u8{ "MS:1000513", "MS:1000518", "MS:1000572" };

fn monitored(resource: Vocabulary, term: Vocabulary.Term) !u3 {
    if (!std.mem.eql(u8, resource.identity.key, "psi-ms") or term.obsolete) return 0;
    var families: u3 = 0;
    for (FAMILY_ROOTS, 0..) |root, index| {
        if (std.mem.eql(u8, term.id, root)) continue;
        if (try resource.isA(term.id, root, 100_000))
            families |= @as(u3, 1) << @intCast(index);
    }
    return families;
}

fn event(writer: *std.Io.Writer, kind: []const u8, resource: []const u8, accession: []const u8, before: anytype, after: anytype) !void {
    try std.json.Stringify.value(.{
        .format_version = @as(u32, 2),
        .kind = kind,
        .resource = resource,
        .accession = accession,
        .before = before,
        .after = after,
    }, .{}, writer);
    try writer.writeByte('\n');
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

fn termEqual(a: Vocabulary.Term, b: Vocabulary.Term) bool {
    inline for (std.meta.fields(Vocabulary.Term)) |field| {
        if (comptime std.mem.eql(u8, field.name, "fields")) continue;
        if (!equal(@field(a, field.name), @field(b, field.name))) return false;
    }
    return true;
}

fn review(writer: *std.Io.Writer, baseline: []const Vocabulary, candidate: []const Vocabulary) !bool {
    if (baseline.len != candidate.len) return error.InvalidManifest;
    var blocked = false;
    for (baseline, candidate) |old, new| {
        if (!std.mem.eql(u8, old.identity.key, new.identity.key)) return error.InvalidManifest;
        const key = new.identity.key;
        if (!equal(old.identity, new.identity))
            try event(writer, "resource", key, "", old.identity, new.identity);
        if (!equal(old.headers, new.headers))
            try event(writer, "headers", key, "", old.headers, new.headers);
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
        for (old.terms) |previous| {
            const matched = new.lookup(previous.id);
            if (matched == null or matched.?.alternate_id) {
                try event(writer, "missing", key, previous.id, previous, null);
                blocked = blocked or !approved(new.identity, previous.id, .missing);
                continue;
            }
            const current = matched.?.term.*;
            inline for (std.meta.fields(Vocabulary.Term)) |field| {
                if (!equal(@field(previous, field.name), @field(current, field.name)))
                    try event(writer, field.name, key, current.id, @field(previous, field.name), @field(current, field.name));
            }
            if (previous.obsolete != current.obsolete)
                try event(writer, if (current.obsolete) "newly_obsolete" else "restored", key, current.id, previous.obsolete, current.obsolete);
            inline for (.{ "has_value_type", "has_units" }) |relation| {
                if (!sameTargets(previous, current, relation))
                    try event(writer, relation, key, current.id, previous.relationships, current.relationships);
            }
            if (!sameBinaryXrefs(previous, current))
                try event(writer, "binary_xrefs", key, current.id, previous.xrefs, current.xrefs);
            if (!equal(previous, current) and isKernel(current.id)) {
                blocked = blocked or !approved(new.identity, current.id, .kernel);
                try event(writer, "blocked_kernel", key, current.id, previous.name, current.name);
            }
        }
        for (new.terms) |term| {
            const previous = old.lookup(term.id);
            if (previous == null or previous.?.alternate_id)
                try event(writer, "added", key, term.id, null, term);
            const colon = std.mem.indexOfScalar(u8, term.id, ':') orelse term.id.len;
            if (!std.mem.eql(u8, term.id[0..colon], new.identity.namespace))
                try event(writer, "foreign", key, term.id, null, term.name);
            const families = try monitored(new, term);
            if (families == 0) continue;
            const before_families = if (previous) |found| try monitored(old, found.term.*) else 0;
            if (families != before_families)
                try event(writer, "active_family", key, term.id, before_families, families);
            if (try disposition(term.id, families)) |entry| {
                try event(writer, "disposition", key, term.id, null, .{
                    .read = entry.read,
                    .write = entry.write,
                    .preservation = entry.preservation,
                    .reason = entry.reason,
                });
            } else {
                blocked = true;
                try event(writer, "blocked_disposition", key, term.id, null, families);
            }
        }
    }
    for (candidate, 0..) |resource, index| {
        for (candidate[index + 1 ..]) |other| for (resource.terms) |term| {
            if (other.lookup(term.id)) |found| {
                try event(writer, if (termEqual(term, found.term.*)) "duplicate_resource_id" else "resource_conflict", resource.identity.key, term.id, term, found.term.*);
            }
        };
    }
    try event(writer, "acceptance", "", "", null, .{ .blocked = blocked });
    return blocked;
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

fn sameBinaryXrefs(a: Vocabulary.Term, b: Vocabulary.Term) bool {
    var position: usize = 0;
    for (a.xrefs) |xref| {
        if (!std.mem.startsWith(u8, xref.value, "binary-data-type:")) continue;
        while (position < b.xrefs.len and !std.mem.startsWith(u8, b.xrefs[position].value, "binary-data-type:")) position += 1;
        if (position == b.xrefs.len or !equal(xref, b.xrefs[position])) return false;
        position += 1;
    }
    for (b.xrefs[position..]) |xref| if (std.mem.startsWith(u8, xref.value, "binary-data-type:")) return false;
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

// --- Deterministic tables ---

fn resourceCounts(resource: Vocabulary) Vocabulary.Counts {
    var counts: Vocabulary.Counts = .{ .terms = resource.terms.len };
    for (resource.terms) |term| {
        const colon = std.mem.indexOfScalar(u8, term.id, ':') orelse term.id.len;
        counts.native_terms += @intFromBool(std.mem.eql(u8, term.id[0..colon], resource.identity.namespace));
        counts.obsolete += @intFromBool(term.obsolete);
        counts.alternate_ids += term.alternate_ids.len;
        counts.replacements += term.replaced_by.len;
        counts.considerations += term.consider.len;
        counts.synonyms += term.synonyms.len;
        for (term.relationships) |edge| {
            counts.value_types += @intFromBool(std.mem.eql(u8, edge.kind, "has_value_type"));
            counts.units += @intFromBool(std.mem.eql(u8, edge.kind, "has_units"));
        }
        for (term.xrefs) |xref|
            counts.binary_xrefs += @intFromBool(std.mem.startsWith(u8, xref.value, "binary-data-type:"));
    }
    return counts;
}

fn generate(allocator: std.mem.Allocator, writer: *std.Io.Writer, resources: []const Vocabulary) !void {
    var raw: std.Io.Writer.Allocating = .init(allocator);
    defer raw.deinit();
    try raw.writer.writeAll("//! Generated vocabulary metadata. Artifact format 1; regenerate with the vocabulary command.\n\nconst Vocabulary = @import(\"vocabulary.zig\");\n\npub const RESOURCES: []const Vocabulary = ");
    try writeZig(&raw.writer, resources);
    try raw.writer.writeAll(";\n");
    const source = try allocator.dupeZ(u8, raw.written());
    defer allocator.free(source);
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidGeneratedSource;
    const formatted = try tree.renderAlloc(allocator);
    defer allocator.free(formatted);
    try writer.writeAll(formatted);
}

fn writeZig(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .pointer => |pointer| {
            if (pointer.child == u8) return std.zon.stringify.serialize(value, .{}, writer);
            try writer.writeAll("&.{");
            for (value) |item| {
                try writeZig(writer, item);
                try writer.writeAll(",\n");
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

test "[unit] - [vocabulary generation]: retains metadata and emits repeatable sorted tables" {
    var parsed = try parse(std.testing.allocator, EXAMPLE_OBO, EXAMPLE_IDENTITY);
    defer parsed.deinit();
    const resource = parsed.resource;
    try std.testing.expectEqualStrings("X:1", resource.terms[0].id);
    const term = resource.lookup("X:02").?.term;
    try std.testing.expectEqualStrings("child name", term.name);
    try std.testing.expectEqualStrings("Quoted \"name\" and colon: here", term.definition.?.value);
    try std.testing.expectEqualStrings("binary-data-type:MS:1000523", term.xrefs[0].value);
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
    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try generate(std.testing.allocator, &first.writer, &.{resource});
    try generate(std.testing.allocator, &second.writer, &.{resource});
    try std.testing.expectEqualStrings(first.written(), second.written());
    var short = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, generate(std.testing.allocator, &short, &.{resource}));
}

test "[failure] - [OBO ingestion]: rejects malformed required fields and duplicate identities" {
    const prefix = "format-version: 1.2\ndata-version: current\nontology: example\n";
    const cases = .{
        .{ "", error.MissingField },
        .{ prefix ++ "[Term]\nid: X:1\n", error.MissingField },
        .{ prefix ++ "[Term]\nid: X:1\nname: one\nname: two\n", error.DuplicateField },
        .{ prefix ++ "[Term]\nid: X:1\nname: one\n[Term]\nid: X:1\nname: two\n", error.DuplicateId },
        .{ prefix ++ "[Term]\nid: X:1\nname: one\nalt_id: X:1\n", error.DuplicateId },
        .{ prefix ++ "[Term]\nid: X:1\nname: bad\\", error.InvalidObo },
        .{ prefix ++ "[Term]\nid: X:1\nname: one\ndef: \"unfinished\n", error.InvalidObo },
        .{ prefix ++ "[Term]\nid: X:1\nname: one\ndef: \"text\" [X:ref ! comment\n", error.InvalidObo },
        .{ prefix ++ "[Term]\nid: X:1\nname: one\nis_a: X:2 {key=value ! comment\n", error.InvalidObo },
        .{ prefix ++ "[Term]\nid: X:1\nname: one\nrelationship: has_units\n", error.InvalidObo },
        .{ prefix ++ "[Term]\nid: X:1\nname: one\nis_obsolete: yes\n", error.InvalidObo },
    };
    inline for (cases) |case| {
        if (parse(std.testing.allocator, case[0], EXAMPLE_IDENTITY)) |value| {
            var unexpected = value;
            defer unexpected.deinit();
            return error.TestExpectedError;
        } else |err| try std.testing.expectEqual(case[1], err);
    }
}

test "[failure] - [OBO ingestion]: cleans up each failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var parsed = try parse(allocator, EXAMPLE_OBO, EXAMPLE_IDENTITY);
            defer parsed.deinit();
        }
    }.run, .{});
}

test "[property] - [OBO ingestion]: preserves escaping and equivalent line endings" {
    const bytes = "format-version: 1.2\ndata-version: current\nontology: example\n" ++
        "[Term]\nid: X:001\nname: escaped\\Wspace\\:colon\\ \n" ++
        "def: \"a\\n\\t\\!\\q\\\\b\" [] ! ignored\\q\n" ++
        "comment: continued\\\nline\n";
    var parsed = try parse(std.testing.allocator, bytes, EXAMPLE_IDENTITY);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("X:001", parsed.resource.terms[0].id);
    try std.testing.expectEqualStrings("escaped space:colon ", parsed.resource.terms[0].name);
    try std.testing.expectEqualStrings("a\n\t!q\\b", parsed.resource.terms[0].definition.?.value);
    const comment = try required(parsed.resource.terms[0].fields, "comment");
    try std.testing.expectEqualStrings("continuedline", comment);
    const crlf = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\n", "\r\n");
    defer std.testing.allocator.free(crlf);
    var windows = try parse(std.testing.allocator, crlf, EXAMPLE_IDENTITY);
    defer windows.deinit();
    try std.testing.expectEqualDeep(parsed.resource, windows.resource);
    var no_newline = try parse(std.testing.allocator, bytes[0 .. bytes.len - 1], EXAMPLE_IDENTITY);
    defer no_newline.deinit();
    try std.testing.expectEqualDeep(parsed.resource, no_newline.resource);

    const names = .{
        .{ "space\\  ", "space " },
        .{ "space\\ \t", "space " },
        .{ "space\\  ! comment", "space " },
        .{ "tab\\\t", "tab\t" },
        .{ "slash\\\\ ", "slash\\" },
        .{ "both\\\\\\ ", "both\\ " },
        .{ "modifier\\ {source=\"fixture\"}", "modifier " },
    };
    inline for (names) |case| {
        var named = try parse(std.testing.allocator, "format-version: 1.2\ndata-version: current\nontology: example\n" ++
            "[Term]\nid: X:1\nname: " ++ case[0] ++ "\n", EXAMPLE_IDENTITY);
        defer named.deinit();
        try std.testing.expectEqualStrings(case[1], named.resource.terms[0].name);
    }
}

test "[unit] - [vocabulary update]: reports each metadata change without changing source objects" {
    const old: Vocabulary = .{ .identity = EXAMPLE_IDENTITY, .terms = &.{.{ .id = "X:1", .name = "old" }} };
    var next = old;
    next.headers = &.{.{ .tag = "remark", .value = "changed source notice" }};
    next.terms = &.{.{
        .id = "X:1",
        .name = "new",
        .obsolete = true,
        .definition = .{ .value = "definition" },
        .synonyms = &.{.{ .value = "synonym" }},
        .alternate_ids = &.{"X:alias"},
        .replaced_by = &.{"X:2"},
        .consider = &.{"X:3"},
        .parents = &.{"X:parent"},
        .relationships = &.{
            .{ .kind = "has_value_type", .target = "xsd:integer" },
            .{ .kind = "has_units", .target = "UO:0000010" },
        },
        .xrefs = &.{.{ .value = "binary-data-type:MS:1000523" }},
    }};
    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    try std.testing.expect(!try review(&report.writer, &.{old}, &.{next}));
    const expected = [_][]const u8{
        "headers", "name",          "obsolete", "definition",     "synonyms",       "alternate_ids", "replaced_by",  "consider",
        "parents", "relationships", "xrefs",    "newly_obsolete", "has_value_type", "has_units",     "binary_xrefs", "acceptance",
    };
    var lines = std.mem.tokenizeScalar(u8, report.written(), '\n');
    for (expected) |kind| {
        const line = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lines.next().?, .{});
        defer line.deinit();
        try std.testing.expectEqualStrings(kind, line.value.object.get("kind").?.string);
    }
    try std.testing.expectEqual(null, lines.next());
    try std.testing.expectEqualStrings("old", old.terms[0].name);
    report.clearRetainingCapacity();
    try std.testing.expect(!try review(&report.writer, &.{next}, &.{old}));
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"kind\":\"restored\"") != null);
}

test "[failure] - [vocabulary update]: blocks removals, kernel changes, and new family terms" {
    const baseline = mzml.cv.Resolver.BUNDLED;
    var next = [_]Vocabulary{ baseline[0], baseline[1] };
    const terms = try std.testing.allocator.dupe(Vocabulary.Term, baseline[0].terms);
    defer std.testing.allocator.free(terms);
    next[0].terms = terms;
    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    for ([_][]const u8{ "MS:1000523", "MS:1000127", "MS:1000128", "MS:1000129", "MS:1000130" }) |id| {
        const index = for (terms, 0..) |term, i| {
            if (std.mem.eql(u8, term.id, id)) break i;
        } else return error.TestUnexpectedResult;
        terms[index].name = "changed kernel label";
        report.clearRetainingCapacity();
        try std.testing.expect(try review(&report.writer, baseline, &next));
        try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"kind\":\"blocked_kernel\"") != null);
        terms[index] = baseline[0].terms[index];
    }
    next[0].terms = terms[1..];
    next[0].aliases = &.{};
    report.clearRetainingCapacity();
    try std.testing.expect(try review(&report.writer, baseline, &next));
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"kind\":\"missing\"") != null);
    const small: Vocabulary = .{ .identity = baseline[0].identity, .terms = &.{
        .{ .id = "MS:1000513", .name = "roles" },
        .{ .id = "MS:1000518", .name = "primitives" },
        .{ .id = "MS:1000572", .name = "codecs" },
        .{ .id = "MS:future", .name = "new", .parents = &.{"MS:1000572"} },
    } };
    var before = small;
    before.terms = small.terms[0..3];
    report.clearRetainingCapacity();
    try std.testing.expect(try review(&report.writer, &.{before}, &.{small}));
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"kind\":\"blocked_disposition\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"kind\":\"active_family\"") != null);
}

test "[property] - [vocabulary coverage]: every active monitored term has one reviewed disposition" {
    const resources = mzml.cv.Resolver.BUNDLED;
    var counts = [_]usize{ 0, 0, 0 };
    for (resources[0].terms) |term| {
        const families = try monitored(resources[0], term);
        if (families == 0) continue;
        try std.testing.expect((try disposition(term.id, families)) != null);
        for (&counts, 0..) |*count, i| if (families & (@as(u3, 1) << @intCast(i)) != 0) {
            count.* += 1;
        };
    }
    try std.testing.expectEqualSlices(usize, &.{ 31, 5, 18 }, &counts);
    for (DISPOSITIONS) |entry| for (entry.terms) |id| {
        const term = resources[0].lookup(id).?.term;
        try std.testing.expectEqual(entry.family, try monitored(resources[0], term.*));
    };
    for (resources) |resource| try std.testing.expectEqualDeep(resource.identity.counts, resourceCounts(resource));
}

test "[property] - [vocabulary manifest]: matches pinned identities and rejects invalid metadata" {
    const resources = mzml.cv.Resolver.BUNDLED;
    const pinned = try std.json.parseFromSlice(Manifest, std.testing.allocator, @embedFile("pinned_manifest"), .{});
    defer pinned.deinit();
    try checkManifest(pinned.value);
    for (pinned.value.resources, resources) |identity, resource|
        try std.testing.expectEqualDeep(identity, resource.identity);
    var manifest: Manifest = .{ .format_version = 1, .resources = .{ resources[0].identity, resources[1].identity } };
    try checkManifest(manifest);
    manifest.format_version = 2;
    try std.testing.expectError(error.UnsupportedManifestVersion, checkManifest(manifest));
    manifest.format_version = 1;
    manifest.resources[0].artifact_version = 2;
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
