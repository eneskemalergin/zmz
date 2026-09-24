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
```

[stream.zig](stream.zig) reads spectra and chromatograms until the reader returns null, regardless of declared list counts. By default it decodes every array and matches the returned numeric union. `--metadata` skips binary text and numeric decoding. MS level is optional and queried only on spectra. Scan times keep their source units; the example does not convert them.

The example copies the first record and header, then uses that metadata after closing the reader. A record copy does not include header parameter groups or numeric buffers. `DecodedArrays` keeps numbers only until its next use, reset, or destruction, including a read that reaches EOF. Copy numeric slices separately if you need to retain them. Neither metadata-only nor decoded reading retains Base64 text for `writeRecord`.

The live header pointer lasts until reader destruction; list descriptors and observed counts update during traversal. An owned header is a snapshot. A borrowed record expires on the next read, even if that read fails or reaches EOF.

[select.zig](select.zig) selects a role after the complete record is read. `MS:1000514` selects m/z, `MS:1000515` intensity, and `MS:1000595` time. A missing role is skipped; repeated matches return `RepeatedArray`. It handles the four primitive types and all existing compression combinations, with Numpress decoded to `f64`. Unrequested codecs are not interpreted.

This selection route retains the current record's binary text and allocates typed output and scratch only for the requested array. It does not use `array_selector`: that callback runs before the complete array metadata is available. All-array numeric streaming cannot currently select individual arrays.

## Indexed access

```sh
zig-out/bin/mzml-indexed indexed.mzML 'scan=1'
zig-out/bin/mzml-indexed plain.mzML 'scan=1' --rebuild
```

[indexed.zig](indexed.zig) opens the embedded index by default. `--rebuild` explicitly scans records to construct one; there is no automatic fallback. Keep the input file open and unchanged until the index is destroyed. Each lookup returns independently owned metadata and uses separate reusable numeric storage. Missing IDs return null; this example prints `not found`. An ID shared by a spectrum and chromatogram returns `AmbiguousId`.

For ordinal access, use `at` or `atDecoded` with the record kind. Their ordinal is zero-based within that kind, not the source `Record.index` field.

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

## Copy retained payloads

```sh
zig-out/bin/mzml-rewrite input.mzML copy.mzML
```

[rewrite.zig](rewrite.zig) writes a new indexed file while retaining source record metadata and binary text. It does not decode or re-encode arrays, so an unfamiliar codec can be copied. XML spelling and the old index wrapper are not reproduced.

This example requires accurate declared list counts, consecutive zero-based record indexes, and a present `defaultDataProcessingRef` on each list. It handles empty or absent lists. The current `beginList` call cannot carry other list attributes or an absent processing reference; the example reports `ListAttributesNotWritable` instead of silently losing them. Errors remove the new partial output, and an existing destination is never overwritten.

For filtering, determine the output counts before calling `beginList`. Changing the cached `Record.id`, `index`, or `default_array_length` fields does not change the node attributes that the writer emits. `Builder.record` constructs new record attributes; it does not automatically carry every source attribute. Array replacement likewise needs to preserve unrelated source parameters and update the primitive, compression, and encoded-length declarations. These examples do not supply a general editing helper.

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

These examples expose existing library behavior, not broader format compatibility. Reading and writing currently accept mzML `1.1.0` in the stable namespace. UTF-8 and UTF-16 XML are handled; ISO-8859-1 and genuine mzML 1.0 structures are not. XML and mzML version failures both use `UnsupportedVersion`; a legacy namespace can return `WrongNamespace`. A schema filename alone does not establish that the input is readable.

The stream example prints the reader's first error, byte offset, and element when available, then returns the error. No example prechecks the whole file or silently skips a failed record. Whole-file gzip is not handled here.
