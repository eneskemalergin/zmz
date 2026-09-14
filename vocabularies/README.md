# Vocabulary resources

The optional `cv.Resolver` uses complete PSI-MS and Unit Ontology snapshots. Ordinary reading, writing, and array decoding do not use these tables. Vocabulary lookup does not enable codecs.

## Sources and attribution

[manifest.json](manifest.json) records each resource's version, immutable source commit, retrieval date, license, expected SHA-256, artifact version, and checked counts.

- [PSI-MS 4.1.258](https://github.com/HUPO-PSI/psi-ms-CV/blob/6081b684002e06484e74774975bc056caaf8927f/psi-ms.obo): 4,114 terms, including 3,986 MS terms and embedded PEFF, UO, and NCIT terms. Attribution: HUPO Proteomics Standards Initiative Mass Spectrometry Standards Working Group and Proteomics Informatics Working Group.
- [Unit Ontology 2026-07-31](https://github.com/bio-ontology-research-group/unit-ontology/blob/c706cc712ae884d72642bb2b70f917e37511f269/uo.obo): 574 terms. Its OBO `data-version` is `releases/2026-07-31`. Attribution: Unit Ontology contributors.

Both sources declare [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/). The generated tables transform their OBO representation into Zig data. They retain definitions, synonyms, relationships, obsolete status, guidance, alternate IDs, xrefs, and source term fields. Definitions and synonym text have OBO escapes decoded; their reference and scope suffixes retain OBO spelling. Original escaped field values remain available in `Term.fields`. OBO comments and typedef stanzas are not part of the term lookup tables. Header fields are retained, but imports are never fetched.

The generator follows the [OBO escape rules](https://owlcollab.github.io/oboformat/doc/GO.format.obo-1_2.html), including the permitted treatment of an unknown escape as its following character. This matters for PSI-MS regular-expression definitions. Consult the retained source field when the producer's intended spelling differs from OBO decoding; this library does not execute those expressions.

## Lookup

This fragment uses declarations copied from the document's `cvList` and a borrowed source parameter:

```zig
const resolver = mzml.cv.Resolver.init(declarations);
const result = try resolver.resolve(parameter);
if (result.term.match) |match| {
    const preferred_name = match.term.name;
    const snapshot = result.term.resource.?.identity;
    // Use preferred_name and snapshot without replacing result.source.
}
```

`result.source` retains every source field. Parameter and unit references resolve independently through declaration IDs, including IDs different from the accession prefix. Unknown metadata returns diagnostics. Duplicate declaration IDs, ambiguous resources, invalid bindings, and comparison limits return errors. `bindings` lets a caller associate a local declaration with a resource key when the document's URI and name are not recognized. All input and result slices are borrowed.

Resource lookup uses exact, case-sensitive accessions, with separate alternate-ID status. An explicit resource selects that resource's definition; a UO declaration uses standalone UO, not the foreign copy embedded in PSI-MS. A namespace mismatch remains visible even if the selected resource contains the accession.

The resolver reports absent, empty, exact, historical, future, unrecognized-version, and unrecognized-resource states. Historical and future states require an explicit catalog. The bundled catalog currently recognizes PSI-MS `4.1.248` as historical; it does not infer age from other version strings. Callers can supply additional reviewed `known_versions`. Lookup still uses the selected snapshot, not reconstructed historical metadata.

`Vocabulary.isA` checks reflexive ancestry. `Term.targets` returns direct relation targets. `Vocabulary.valueTypes` expands `has_value_type` into caller-provided slots while leaving the original targets available. Graph queries distinguish missing terms, cycles, work exhaustion, and insufficient output space. Nesting is capped at 64 terms. They allocate no memory. Exposed table slices must stay sorted, valid, and unchanged when callers provide their own resources.

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
zig build vocabulary -- inspect candidate-manifest.json psi-ms.obo uo.obo
zig build vocabulary -- review candidate-manifest.json psi-ms.obo uo.obo
zig build vocabulary -- generate candidate-manifest.json psi-ms.obo uo.obo candidate.zig
```

`inspect` checks provenance fields, source digests, OBO structure, and source versions, then prints actual counts and monitored descendants. It does not require the manifest's count assertions to match. Use its output to review those assertions before running `review` or `generate`.

`review` compares the candidate with the package's current tables. Its newline-delimited JSON report identifies `format_version: 2` and includes term and header changes, additions, removals, resource identity changes, foreign definitions, cross-resource conflicts, and operation dispositions. `generate` runs the same checks, generates twice, compares the results, and formats the Zig output. It publishes a new file atomically and refuses to replace an existing path. It does not install or accept an update automatically.

Version 2 is the current report shape. Consumers must reject other report versions before reading event fields.

Both commands reject incorrect digests, required fields, duplicate primary or alternate IDs, unsupported manifest or artifact versions, and count mismatches. Input files are limited to 32 MiB each. The ingestion profile accepts OBO 1.2 and 1.4 term and typedef stanzas and requires `format-version`, `data-version`, and `ontology` headers.

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
