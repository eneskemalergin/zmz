# mzML examples

These complete Zig 0.16.0 programs use only `@import("zmz").mzml`. Build them from the repository root:

```sh
zig build examples -Doptimize=ReleaseFast
```

The executables go in `zig-out/bin/`. `zig build test-examples` compiles and runs them on small fixtures; `zig build test` includes those checks. No external datasets are needed.

The stream, select, indexed, and rewrite programs print saved `mzml.Diagnostic` reports on failure. These include the native error, operation, and available location or size details. Indexed opening uses `buildWithDiagnostic` so its report survives cleanup; lookup, forward-reader, writer, and `DecodedArrays` reports come from `diagnostic()`.

## Read, select, and retain

```sh
zig-out/bin/mzml-stream input.mzML
zig-out/bin/mzml-stream input.mzML --metadata
zig-out/bin/mzml-select input.mzML MS:1000514
zig-out/bin/mzml-select input.mzML MS:1000515 --stream
zig-out/bin/mzml-select input.mzML MS:1000514 --ms1
```

[stream.zig](stream.zig) reads spectra and chromatograms until the reader returns null, regardless of declared list counts. By default it decodes every modeled array and matches the returned numeric union. `--metadata` skips modeled binary text and numeric decoding. MS level is optional and queried only on spectra. Scan times keep their source units; the example does not convert them.

The example copies the first record and header, then uses that metadata after closing the reader. A record copy does not include header parameter groups or numeric buffers. `DecodedArrays` keeps numbers only until its next use, reset, or destruction, including a read that reaches EOF. Copy numeric slices separately if you need to retain them. Neither metadata-only nor decoded reading retains modeled Base64 text for `writeRecord`.

The live header pointer lasts until reader destruction; list descriptors and observed counts update during traversal. An owned header is a snapshot. A borrowed record expires on the next read, even if that read fails or reaches EOF.

`Record.index`, `Record.default_array_length`, and `RecordList.declared_count` are optional source numbers. Missing attributes remain null; observed counts and lookup ordinals are separate. Numeric decoding needs the selected array's own `arrayLength` or a record default and returns `MissingValue` when both are absent. Empty records and skipped arrays need neither.

[select.zig](select.zig) selects a role after the complete record is read. `MS:1000514` selects m/z, `MS:1000515` intensity, and `MS:1000595` time. A missing role is skipped; repeated matches return `RepeatedArray`. It handles the four primitive types and all existing compression combinations, with Numpress decoded to `f64`. Unrequested codecs are not interpreted.

By default, this example retains the current record's binary text and decodes only the requested array with `DecodedArrays.decodeArray`, reusing its buffers across records. `--stream` instead uses `array_selector` with `nextDecodedRecord`: it selects from leading array parameters and decodes into reusable buffers without retaining Base64. `--ms1` also uses `select_record` to skip decoding outside MS1 spectra. Record selection sees the kind, attributes, and record-level parameters read before the array list; array selection sees attributes and leading parameters. Neither callback sees later parameters. Use the default retained-text route when selection needs complete metadata.

Selected numeric results are compact and stay in source order. Each `DecodedArrays.Array.source_position` indexes the returned record's `binaryArrays()`, whose metadata includes unselected arrays. An empty selection returns the record with zero decoded arrays, not EOF. Without a selector, numeric reads still decode every modeled array.

## Indexed access

```sh
zig-out/bin/mzml-indexed indexed.mzML 'scan=1'
zig-out/bin/mzml-indexed plain.mzML 'scan=1' --rebuild
```

[indexed.zig](indexed.zig) opens the embedded index by default. `--rebuild` explicitly scans records to construct one; there is no automatic fallback. Keep the input file open and unchanged until the index is destroyed. Each lookup returns independently owned metadata and uses separate reusable numeric storage. Missing IDs return null; this example prints `not found`. An ID shared by a spectrum and chromatogram returns `AmbiguousId`.

For ordinal access, use `at` or `atDecoded` with the record kind. Their ordinal is zero-based within that kind, not the source `Record.index` field.

`byIdDecoded` and `atDecoded` also use `reader.array_selector`, including `select_record`, with the same metadata availability and source positions as forward reads. Index building does not call selectors. Set them when building the index; keep their user data alive until the last lookup.

## Construct and write arrays

```sh
zig-out/bin/mzml-write example.mzML
zig-out/bin/mzml-write example-indexed.mzML --indexed
zig-out/bin/mzml-stream example.mzML
zig-out/bin/mzml-indexed example-indexed.mzML 'scan=1'
```

[write.zig](write.zig) constructs a small example spectrum with `f64` m/z and `f32` intensity arrays, compressed with zlib. Its header labels the data as example values, not an acquisition. Replace that metadata and those numbers with your own acquisition information.

`Builder.prepareArray` creates metadata and a payload that borrows the values; nothing is encoded until `writeRecordWithArrays` writes the record. The writer encodes each array while writing it, with the `arrays.Encoder`'s compressor, and sets `encodedLength` from the text it writes. Keep the values and the encoder alive until the record is written.

Builder reset releases its metadata. The example resets only after the header or record has been written. `Writer.finish` closes the document and emits the optional index; the caller must then flush the sink. `deinit` does neither. Output creation refuses an existing path, and a failed write removes its newly created partial output.

## Copy, filter, or reencode

```sh
zig-out/bin/mzml-rewrite input.mzML copy.mzML
zig-out/bin/mzml-rewrite input.mzML ms1.mzML --ms1
zig-out/bin/mzml-rewrite input.mzML zlib.mzML --zlib
zig-out/bin/mzml-rewrite input.mzML edited.mzML --replace-user-param note "reviewed"
zig-out/bin/mzml-rewrite input.mzML removed.mzML --remove-user-param note
```

[rewrite.zig](rewrite.zig) writes a new indexed file. Copying, filtering, and parameter edits retain binary text without decoding arrays, so an unfamiliar codec can be copied. XML spelling and the old index wrapper are not reproduced.

All modes use `nextItem` or `nextDecodedItem` and `writeItem` to keep XML before, between, and after records, inside empty lists, and after the run. `nextRecord` returns records only and skips that surrounding XML, so it is not a complete file-copy iterator. Items borrow until the next traversal call; `owned.Item.init` keeps an independent copy. Filtering leaves surrounding XML in source order, even when adjacent spectra are removed.

The default copy requires accurate declared list counts and consecutive zero-based record indexes. `--ms1` keeps spectra whose MS level is 1, skips spectra without an MS level, and keeps all chromatograms. It reads the input once and assigns consecutive output spectrum indexes, adding `index` when absent. All other record attributes, IDs, references, and binary text stay unchanged. References to removed spectra remain unchanged; choosing how to handle them is the caller's decision.

Filtering uses `Writer.initFile` and a null spectrum count in `beginListWithAttributes`. `endList` patches a fixed-width, zero-padded decimal count without moving any records. Plain file output needs write access; indexed file output also needs read access because `finish` reads the written prefix once to compute its checksum. This adds an output read, not another input scan or a retained copy of the file. `init` and `initIndexed` still need exact counts and work with forward-only sinks. Pass null index limits to `initFile` for plain output or `.{}` for indexed output.

`--zlib` prepares the header with `Builder.reencoding`, then streams decoded arrays through its `prepareArray` method and `writeRecordWithArrays`. It keeps all numeric values, record attributes, unrelated array parameters, and XML on group references and their members. Numpress values are written as decoded `f64` values with zlib, without another lossy conversion. Changed encoding groups get new definitions and reference IDs; original definitions remain available to unchanged metadata and arrays. Preparing the four output primitive types does not read records ahead, so some added definitions may remain unused. Each compressed destination stays alive until its record is written and is reused on later records. Each decoded array is capped at `DecodedArrays.Options.array_bytes` (192 MiB by default).

All modes handle empty or absent lists. `beginListWithAttributes(kind, count, list.attributes)` writes the requested count first and retains the other attributes, including extra fields and absent versus empty `defaultDataProcessingRef`. It borrows attributes only until return. Use `beginList(kind, count, processing_ref)` when constructing a list with just those two attributes. Errors remove the new partial output, and an existing destination is never overwritten.

Writing still needs consecutive record indexes. Every mode except `--ms1` uses a forward-only writer and needs declared list counts; use `Writer.initFile` for unknown output counts, as `--ms1` does. Copying and parameter edits retain an absent `defaultArrayLength`; numeric rewriting needs an array length or record default.

`--replace-user-param NAME VALUE` changes the value attribute on every matching direct `userParam` of each spectrum and chromatogram. Names are case-sensitive; absent names never match, and an empty name is distinct from an absent name. An empty value writes `value=""`. Replacement retains the parameter's type, units, extra attributes, and child XML, so supply a value suitable for its retained type and units. `--remove-user-param NAME` removes the whole matching parameter, including its attached XML. Neither mode adds an absent parameter, edits shared groups or nested metadata, nor decodes arrays. Choose one mode per invocation.

For metadata edits, copy the affected slices into caller-owned storage and give the resulting node to the writer. `ParameterEditor` in `rewrite.zig` copies parameter entries and adjusts each `.params` run in `Node.content` after removal. It leaves `.children` runs and `.xml` fragments in place. Null content means parameters precede children and needs no run edits. The reusable slices and content descriptor stay alive through `writeRecord`; strings, parameter XML, and untouched children still borrow from the reader. Write before the next read or editor call. Removing children follows the same rule for `.children` runs and may also require updating the enclosing list's `count` attribute.

`--ms1` separately shows editing the attribute slice. Changing the cached `Record.id`, `index`, or `default_array_length` fields alone does not change emitted XML. `Builder.record` constructs new record attributes; they are not source-record editors.

For numeric edits, supply your changed values to `prepareArrayFrom`. It copies the source array's metadata without its old payload, replaces primitive/codec declarations, and updates lengths. Bare group references become local parameters; annotated references remain intact when their group's encoding stays unchanged. Changing an annotated group's encoding returns `GroupRewriteRequired` without a prepared replacement. Use `header_builder.reencoding(header, targets)` before writing the header, then `prepared.prepareArray(&record_builder, ...)` as the example does. Write `prepared.header` and keep its builder alive while preparing arrays; reset only the separate record builder between records. Targets are the primitive/compression combinations you intend to write.

If a default array omits `arrayLength`, update the record's `defaultArrayLength` when resizing it. Update any scientific summary parameters affected by your edit yourself; reencoding alone does not change those values. Keep cached fields consistent too if you use the edited `Record` for reading.

## Use from a separate package

Create an application directory beside the `zmz` checkout. Copy one example, such as `stream.zig`, into it as `main.zig`. Add these two files.

`build.zig.zon`:

```zig
.{
    .name = .mzml_example,
    .fingerprint = 0x306df90502d2ef18,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{ .zmz = .{ .path = "../zmz" } },
    .paths = .{ "build.zig", "build.zig.zon", "main.zig" },
}
```

`build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("zmz", .{ .target = target, .optimize = optimize });
    const executable = b.addExecutable(.{
        .name = "read-mzml",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zmz", .module = dependency.module("zmz") }},
        }),
    });
    b.installArtifact(executable);
}
```

Run from that application directory:

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/read-mzml input.mzML
```

This uses a local package dependency, including the library's build options. It does not import `src/root.zig` directly or fetch a copy of the working tree. For a differently named application, use its own `zig init` name and fingerprint.

## Current input limits

The reader handles XML 1.0 in UTF-8, UTF-16, and declared ISO-8859-1. Returned text and written XML use UTF-8; source offsets count original bytes. The mzML version attribute is preserved, including empty or absent values, without rejecting its value. Original mzML 1.0.0 and modern mzML namespaces and structures use the same API. Extra attributes and unknown XML inside header and record nodes survive copying and writing without being interpreted as scans or arrays. `UnsupportedVersion` concerns the XML declaration; an unrecognized document namespace returns `WrongNamespace`. A schema filename alone does not establish that the input is readable.

When a singular metadata container repeats, only the first occurrence is modeled. Later occurrences remain intact in `Node.content` as XML. Scan helpers, array decoding, and group expansion do not read those fragments. Copying preserves them; `--zlib` leaves their payloads unchanged. Even `--metadata` retains their XML bytes, within the reader's retained-byte limits. Multiple binary payloads in one modeled array and unsupported run/list ordering still fail.

The stream example prints the reader's first error, its location, and the element when available, then returns the error. No example prechecks the whole file or silently skips a failed record. Whole-file gzip is not handled here.
