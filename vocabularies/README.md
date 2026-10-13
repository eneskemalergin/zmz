# Vocabulary resources

The optional `cv.Resolver` uses bundled PSI-MS and Unit Ontology snapshots. Ordinary reading, writing, and array decoding do not use these tables. Vocabulary lookup does not enable codecs.

## Sources and attribution

[manifest.json](manifest.json) records each resource's version, immutable source commit, retrieval date, license, expected SHA-256, artifact version, and checked counts.

- [PSI-MS 4.2.5](https://github.com/HUPO-PSI/psi-ms-CV/blob/bfc95f2a1cd1ab104d265b15910f153bfcfeac86/psi-ms-core.obo), from `psi-ms-core.obo`: 4,154 terms, including 4,026 MS terms and embedded PEFF, UO, and NCIT terms. Attribution: HUPO Proteomics Standards Initiative Mass Spectrometry Standards Working Group and Proteomics Informatics Working Group.
- [Unit Ontology 2026-10-12](https://github.com/bio-ontology-research-group/unit-ontology/blob/311f3d222444fcf8adf032dfa58f3c1b55bd22af/uo.obo): 574 terms. Its OBO `data-version` is `releases/2026-10-12`. Attribution: Unit Ontology contributors.

`psi-ms-core.obo` is the curated PSI-MS source: every term of the release except the chromatographic column models (`MS:5000000` to `MS:5999999`, subset `columns`). The published `psi-ms.obo` adds those 1,928 models, which derive from the [RepoRT](https://github.com/michaelwitting/RepoRT) column database under its own license. They are not bundled; a program that needs them parses `psi-ms.obo` at run time (see below).

Both sources declare [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/). The generated tables transform their OBO representation into Zig data. They retain names, obsolete status, subsets, parents and relationships, definitions, synonyms, alternate IDs, replacements, consider lists, xrefs, and header fields. Definitions and synonym text have OBO escapes decoded; their reference and scope suffixes retain OBO spelling. OBO comments and typedef stanzas are not part of the term tables, and imports are never fetched.

The tables are grouped by use, and each `Term` method reads one group, so a program links only the groups its calls reach:

- **core:** IDs, names, obsolete flags, subsets, parents, and relationships. Lookup needs only this; the resolver also reads history.
- **closure:** every term's ancestors, for `Vocabulary.isA`.
- **details:** definitions, synonyms, xrefs, alternate IDs, replacements, consider lists, relationship modifiers, and header fields.
- **history:** the recorded releases, each term's first release and the release it became obsolete in, and its former names.

A program that reads mzML without the vocabulary links none of it. In a stripped x86-64 ReleaseFast build, lookup adds about 0.2 MB, resolution about 0.4 MB, and reading every definition, synonym, and xref about 1 MB.

The generator follows the [OBO escape rules](https://owlcollab.github.io/oboformat/doc/GO.format.obo-1_2.html), including the permitted treatment of an unknown escape as its following character. This matters for PSI-MS regular-expression definitions. When the producer's intended spelling differs from OBO decoding, parse the file at run time and consult `Term.fields`, which keeps every field as written; this library does not execute those expressions.

## Lookup

This fragment uses declarations copied from the document's `cvList` and a borrowed source parameter:

```zig
const resolver = mzml.cv.Resolver.init(declarations);
const result = try resolver.resolve(parameter);
if (result.term.match) |match| {
    const preferred_name = match.term.name();
    const snapshot = result.term.resource.?.identity;
    // Use preferred_name and snapshot without replacing result.source.
}
```

`result.source` retains every source field. Parameter and unit references resolve independently through declaration IDs, including IDs different from the accession prefix. Unknown metadata returns diagnostics. Duplicate declaration IDs, ambiguous resources, invalid bindings, and comparison limits return errors. `bindings` lets a caller associate a local declaration with a resource key when the document's URI and name are not recognized. All input and result slices are borrowed.

Resource lookup uses exact, case-sensitive accessions, with separate alternate-ID status. An explicit resource selects that resource's definition; a UO declaration uses standalone UO, not the foreign copy embedded in PSI-MS. A namespace mismatch remains visible even if the selected resource contains the accession.

The resolver reports absent, empty, exact, historical, future, unrecognized-version, and unrecognized-resource states. A declared version is historical when the resource's history records that release: every PSI-MS release from 3.80.0_rc1 (December 2015) on, and every Unit Ontology release from March 2011 on. Unit Ontology files before 2023 have no `data-version`, and documents declare them by the day of their `date:` header, such as `09:04:2014`; the history names them the same way. The resolver never infers age from a version string, so earlier releases such as PSI-MS 2.26.0 stay unrecognized. Callers can supply further reviewed `known_versions`; one that calls a recorded release `future` is a `ConflictingVersion`. Lookup still uses the selected snapshot, not reconstructed historical metadata.

A declaration is recognized by the resource's URI and full name, and by the other URIs and names that documents use for it, such as the SourceForge and PURL locations and "Proteomics Standards Initiative Mass Spectrometry Vocabularies". The manifest lists them.

A name that differs from the term's current name sets `stale_name`. When it was the term's name in a recorded earlier release, `former_name` is also set: "Q-Tof ultima" for `MS:1000189`, for example. `Term.formerNames` lists each former name with the last release that used it; `Term.firstRelease` and `Term.obsoleteSince` give a term's lifetime, and `Vocabulary.findRelease` finds a release by its text.

`Vocabulary.isA` checks reflexive ancestry from the precomputed closure: a binary search, at any depth. `Term.parents` and `Term.ancestors` list terms; `Term.targets` returns direct relation targets, including ones outside the resource such as `xsd:` types. `Term.subsets` lists a term's subsets. `Vocabulary.valueTypes` expands `has_value_type` into caller-provided slots while leaving the original targets available; it distinguishes missing terms, cycles, work exhaustion, and insufficient output space, and caps nesting at 64 terms. None of these allocate.

## Newer releases at run time

`Vocabulary.parseObo` builds the same tables from an OBO 1.2 or 1.4 file of at most 32 MiB, so a program can use a newer PSI-MS release than the one it was built with, or the full `psi-ms.obo` with its column models:

```zig
// The declaration spellings let the resolver recognize documents' `cv` entries for PSI-MS.
const bundled = mzml.cv.Resolver.BUNDLED[0].identity;
const owned = try mzml.cv.Vocabulary.parseObo(allocator, bytes, .{
    .key = bundled.key,
    .version = "4.2.5",
    .namespace = bundled.namespace,
    .full_name = bundled.full_name,
    .uri = bundled.uri,
    .declaration_uris = bundled.declaration_uris,
    .declaration_names = bundled.declaration_names,
    .source_version = "4.2.5",
});
defer owned.deinit();
const resources = [_]mzml.cv.Vocabulary{ owned.vocabulary, mzml.cv.Resolver.BUNDLED[1] };
const resolver: mzml.cv.Resolver = .{ .resources = &resources, .declarations = declarations };
```

The identity is copied as given and describes the file the caller supplies. A parsed resource also keeps every stanza field as written, through `Term.fields`; it records no release history. A nonempty `source_version` must equal the file's `data-version`. Duplicate primary or alternate IDs, an `is_a` cycle, a missing required field, and malformed OBO are errors. The result owns its memory until `deinit`.

`unit_allowed` checks direct `has_units` targets only. `not_declared` means no such relation exists, not that units are prohibited. The resolver does not parse lists, convert units, enforce value types, normalize a document.

## Numeric quantities

`resolver.quantity(T, parameter)` parses the source value as an integer, `f32`, or `f64` and returns a `Resolver.Quantity(T)`. Its `value` is numeric; its `parameter` contains the same source and resolution results as `resolve`. Missing, empty, malformed, and overflowing values return distinct errors before resolution. A parsed value does not prove that its units are known or allowed: inspect the returned unit fields and diagnostics. No units are inferred or converted, and the selected numeric type does not enforce the ontology's declared datatype.

This fragment reads every scan's own time. Keep the record, header, and the resolver's borrowed declarations and resource tables alive while using the results:

```zig
for (record.scans()) |scan| {
    if (try scan.scanStartTime(header.groups)) |time| {
        const quantity = try resolver.quantity(f64, time.parameter);
        // A source value of 1.25 minutes remains 1.25, not 75 seconds.
        // Inspect quantity.parameter.unit_allowed and quantity.parameter.unit.
        _ = quantity;
    }
}
```

The [record model](../src/mzml/model.zig) also exposes MS level, polarity, centroid/profile representation, all precursors and products, selected-ion values, and isolation-window targets and offsets. Single-value helpers reject repetition; opposing polarity or representation flags return `ConflictingParameter`. Missing charge remains absent rather than zero. Offsets may be asymmetric and are not absolute boundaries. Other acquisition and activation terms remain accessible through exact-accession parameter lookup; these helpers do not choose a scan, merge activation methods, or add analysis policy.

## Offline updates

Normal builds use [the generated tables](../src/cv/generated_data.zig) and need no downloads. The Zig maintainer command takes explicit local files. It never follows mzML or OBO URIs.

```bash
zig build vocabulary -- candidate vocabularies/manifest.json psi-ms-core.obo PSI_MS_COMMIT uo.obo UO_COMMIT DATE candidate-manifest.json
zig build vocabulary -- inspect candidate-manifest.json psi-ms-core.obo uo.obo
zig build vocabulary -- review candidate-manifest.json psi-ms-core.obo uo.obo
zig build vocabulary -- extend vocabularies/history.json history.json psi-ms psi-ms-releases.txt uo uo-releases.txt
zig build vocabulary -- generate candidate-manifest.json history.json psi-ms-core.obo uo.obo candidate.zig
```

`candidate` writes the next manifest from the current one, two OBO files, and the upstream commits they came from: versions, digests, retrieval date, and counts. Declaration spellings, licenses, and attribution carry over for review.

`inspect` checks provenance fields, source digests, OBO structure, and source versions, then prints actual counts and monitored descendants. It does not require the manifest's count assertions to match.

`review` compares the candidate with the package's current tables. Its newline-delimited JSON report identifies `format_version: 3` and includes term, subset, and header changes, additions, removals, resource identity changes, foreign definitions, cross-resource conflicts, and operation dispositions. Version 3 is the current report shape. Consumers must reject other report versions before reading event fields.

`history` replays each resource's releases, oldest first, from a list of OBO files with one path a line: every release upstream git holds, the tagged commit where a tag names it. For PSI-MS that is `psi-ms.obo` through 4.1.261 and `psi-ms-core.obo` from 4.2.0, where the curated file split from the published one. It records each release, when each term first appeared and became obsolete, and each former name with the last release that used it. It reads only IDs, names, and obsolete flags, and reads them tolerantly, because old releases repeat IDs that the library parser refuses. [history.json](history.json) is the recorded history the bundled tables come from. `extend` adds the releases since its last one: each list starts with that last recorded release, the baseline the next is compared with. `generate` refuses a history that does not end at the release it generates.

`generate` runs the review checks, generates twice, compares the results, and formats the Zig output. It publishes a new file atomically and refuses to replace an existing path. It does not install or accept an update automatically.

The [vocabulary update workflow](../.github/workflows/vocabulary.yml) runs these steps every week. When either resource has released since the bundled snapshot, it collects every release from upstream git, reviews the newest, extends the history, generates, tests, and opens a pull request with a summary of the review. A blocked review fails the run and lists the blocking events. The pull request still needs a maintainer: read the full review, update the snapshot facts above, and run the release-gate checks. GitHub does not start other workflows for pull requests a workflow opens, and the repository must allow workflows to open pull requests.

`review` and `generate` reject incorrect digests, required fields, duplicate primary or alternate IDs, unsupported manifest or artifact versions, and count mismatches. Input files are limited to 32 MiB each. The ingestion profile accepts OBO 1.2 and 1.4 term and typedef stanzas and requires `format-version`, `data-version`, and `ontology` headers.

The update policy lives in [tools/vocabulary.zig](../tools/vocabulary.zig), separate from generated data:

- Every active descendant of `MS:1000513`, `MS:1000518`, and `MS:1000572` needs exactly one reviewed operation disposition. A new or reparented term without one blocks generation.
- Missing terms and changes to format-kernel metadata block generation until a record in `APPROVALS` identifies the exact candidate commit, digest, accession, change kind, and review evidence. Changes to the manifest's license or attribution also require review. There are no current approval exceptions. Review source-header notices against the manifest yourself; the command reports their changes but does not interpret legal text.
- Dispositions record review status, not a runtime feature registry. A preserved role does not promise scientific interpretation. A blocked transform has no supported payload operation, even though its term resolves and retained XML can be written.
- Metadata updates never change executable codec dispatch. Review code and wire tests separately when an update affects it.

After reviewing the report, apply the candidate tables and manifest together, run the previous test set in Debug and ReleaseFast, repeat generation, check representative external files, and measure artifact size. The tests compare the shipped manifest with the generated resource identities. Keep provenance, attribution, and documented snapshot facts synchronized. A successful report means no unreviewed update blockers remain; it does not replace those acceptance checks.

## External-file check

```bash
zig build vocabulary -Doptimize=ReleaseFast -- scan FILE.mzML [FILE.mzML ...]
```

`scan` reads each explicit file through EOF, skips binary text retention, and resolves source parameters and supplied unit identities. It reports physical parameter occurrences, including group definitions once rather than every effective use. It does not decode arrays or verify an embedded index. Unknown, obsolete, and stale metadata are reported, not treated as parse failures. Source files are opened read-only. External files never enter the unit or integration tests.
