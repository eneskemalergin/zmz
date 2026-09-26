# mzML examples

These complete Zig 0.16.0 programs use only `@import("zmz").mzml`. Build them from the repository root:

```sh
zig build examples -Doptimize=ReleaseFast
```

The executables go in `zig-out/bin/`. `zig build test-examples` compiles and runs them on small fixtures; `zig build test` includes those checks. No external datasets are needed.

## Read, select, and retain

```sh
zig-out/bin/mzml-stream input.mzML
zig-out/bin/mzml-stream input.mzML --metadata
zig-out/bin/mzml-select input.mzML MS:1000514
zig-out/bin/mzml-select input.mzML MS:1000515 --stream
zig-out/bin/mzml-select input.mzML MS:1000514 --ms1
```

[stream.zig](stream.zig) reads spectra and chromatograms until the reader returns null, regardless of declared list counts. By default it decodes every array and matches the returned numeric union. `--metadata` skips binary text and numeric decoding. MS level is optional and queried only on spectra. Scan times keep their source units; the example does not convert them.

The example copies the first record and header, then uses that metadata after closing the reader. A record copy does not include header parameter groups or numeric buffers. `DecodedArrays` keeps numbers only until its next use, reset, or destruction, including a read that reaches EOF. Copy numeric slices separately if you need to retain them. Neither metadata-only nor decoded reading retains Base64 text for `writeRecord`.

The live header pointer lasts until reader destruction; list descriptors and observed counts update during traversal. An owned header is a snapshot. A borrowed record expires on the next read, even if that read fails or reaches EOF.

[select.zig](select.zig) selects a role after the complete record is read. `MS:1000514` selects m/z, `MS:1000515` intensity, and `MS:1000595` time. A missing role is skipped; repeated matches return `RepeatedArray`. It handles the four primitive types and all existing compression combinations, with Numpress decoded to `f64`. Unrequested codecs are not interpreted.

By default, this example retains the current record's binary text and allocates typed output and scratch only for the requested array. `--stream` instead uses `array_selector` with `nextDecodedRecord`: it selects from leading array parameters and decodes into reusable buffers without retaining Base64. `--ms1` also uses `select_record` to skip decoding outside MS1 spectra. Record selection sees the kind, attributes, and record-level parameters read before the array list; array selection sees attributes and leading parameters. Neither callback sees later parameters. Use the default retained-text route when selection needs complete metadata.

Selected numeric results are compact and stay in source order. Each `DecodedArrays.Array.source_position` indexes the returned record's `binaryArrays()`, whose metadata includes unselected arrays. An empty selection returns the record with zero decoded arrays, not EOF. Without a selector, numeric reads still decode every array.

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

`Builder.prepareArray` creates metadata and wire bytes without retaining a Base64 copy. Each array has a separate compressed destination that remains unchanged until `writeRecordWithArrays` returns. `arrays.wireBound` excludes zlib overhead, so the example retries `OutputTooSmall` with bounded growth, capped at 1 MiB per buffer. The temporary precompression buffer can be released after zlib finishes; the compressed destination cannot. For uncompressed prepared arrays, wire can instead borrow the original numeric values or endian-conversion scratch.

Builder reset releases its metadata. The example resets only after the header or record has been written. `Writer.finish` closes the document and emits the optional index; the caller must then flush the sink. `deinit` does neither. Output creation refuses an existing path, and a failed write removes its newly created partial output.

## Copy, filter, or reencode

```sh
zig-out/bin/mzml-rewrite input.mzML copy.mzML
zig-out/bin/mzml-rewrite input.mzML ms1.mzML --ms1
zig-out/bin/mzml-rewrite input.mzML zlib.mzML --zlib
```

[rewrite.zig](rewrite.zig) writes a new indexed file. The default and `--ms1` modes retain source record metadata and binary text without decoding arrays, so an unfamiliar codec can be copied. XML spelling and the old index wrapper are not reproduced.

All modes use `nextItem` or `nextDecodedItem` and `writeItem` to keep XML before, between, and after records, inside empty lists, and after the run. `nextRecord` returns records only and skips that surrounding XML, so it is not a complete file-copy iterator. Items borrow until the next traversal call; `owned.Item.init` keeps an independent copy. Filtering leaves surrounding XML in source order, even when adjacent spectra are removed.

The default copy requires accurate declared list counts and consecutive zero-based record indexes. `--ms1` keeps spectra whose MS level is 1, skips spectra without an MS level, and keeps all chromatograms. It reads the input once and assigns consecutive output spectrum indexes while preserving all other record attributes, IDs, references, and binary text. References to removed spectra remain unchanged; choosing how to handle them is the caller's decision.

Filtering uses `Writer.initFile` and a null spectrum count in `beginListWithAttributes`. `endList` patches a fixed-width, zero-padded decimal count without moving any records. Plain file output needs write access; indexed file output also needs read access because `finish` reads the written prefix once to compute its checksum. This adds an output read, not another input scan or a retained copy of the file. `init` and `initIndexed` still need exact counts and work with forward-only sinks. Pass null index limits to `initFile` for plain output or `.{}` for indexed output.

`--zlib` streams decoded arrays through `Builder.prepareArrayFrom` and `writeRecordWithArrays`. It keeps all numeric values, record attributes, references, and unrelated array parameters. Numpress values are written as decoded `f64` values with zlib, without another lossy conversion. Reencoded arrays expand group references into local parameters; the header's groups remain unchanged. Each compressed destination stays alive until its record is written and is reused on later records. Buffer growth is capped at `arrays.Limits.array_bytes` (192 MiB by default).

All modes handle empty or absent lists. `beginListWithAttributes(kind, count, list.attributes)` writes the requested count first and retains the other attributes, including extra fields and absent versus empty `defaultDataProcessingRef`. It borrows attributes only until return. Use `beginList(kind, count, processing_ref)` when constructing a list with just those two attributes. Errors remove the new partial output, and an existing destination is never overwritten.

For metadata edits, copy the affected attribute or child slices into caller-owned storage and give the resulting node to the writer, as `--ms1` does for indexes. Changing the cached `Record.id`, `index`, or `default_array_length` fields alone does not change emitted XML. `Builder.record` and `preparedRecord` construct new record attributes; they are not source-record editors.

For numeric edits, supply your changed values to `prepareArrayFrom`. It copies the source array's metadata without its old payload, replaces primitive/codec declarations, and updates lengths. If a default array omits `arrayLength`, update the record's `defaultArrayLength` when resizing it. Update any scientific summary parameters affected by your edit yourself; reencoding alone does not change those values. Keep cached fields consistent too if you use the edited `Record` for reading.

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

The stream example prints the reader's first error, byte offset, and element when available, then returns the error. No example prechecks the whole file or silently skips a failed record. Whole-file gzip is not handled here.
