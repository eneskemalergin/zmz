# Versions and compatibility

Three kinds of version matter to a zmz program: the mzML version of a file, the Zig and platform you build with, and the version of zmz itself.

## mzML versions

mzML has used several namespaces over its history:

- **mzML 1.1** (1.1.0 and the 1.1.1 revision), namespace `http://psi.hupo.org/ms/mzml`: read and written.
- **mzML 1.0.0**, namespace `http://psi.hupo.org/schema_revision/mzML_1.0.0`: read and written.
- **Pre-release drafts** (0.93 and 0.99), each with its own namespace: not supported.

The namespace decides how zmz reads a file; the `version` attribute does not. zmz keeps that attribute as written, absent or empty included, and never rejects a file over its value: plenty of converters write `version="1.1.0"` on files that use newer terms, and some write nothing at all. A document in any other namespace fails with `WrongNamespace`.

### What mzML 1.0 does differently

mzML 1.0 shipped in 2008 and was replaced a year later, but converters kept writing it for a long time, and archives are full of it. The differences that matter:

- A spectrum's scan, precursors, and centroid or polarity flags sit inside a `spectrumDescription` element instead of directly in the spectrum.
- Indexes can carry `nativeID` and `spotID` attributes on their offsets.
- Older files use terms that are obsolete today, such as `MS:1000040` for a selected ion's m/z.

The record helpers (`scans`, `precursors`, `polarity`, `representation`, `selectedIonValues`) know both layouts, so the same code reads both versions. The model itself is not converted: a 1.0 record keeps its `spectrumDescription` node, and writing it produces 1.0 again, in the 1.0 namespace, with its index attributes.

> [!NOTE]
> zmz never upgrades or downgrades a file. A rewrite of a 1.0 file is a 1.0 file. Converting between versions moves elements around and changes terms, and that is a job for a converter that knows what it is changing.

## Character encodings

- **UTF-8**: the usual case.
- **UTF-16**, either byte order, with or without a byte-order mark: read and converted, with offsets still counting source bytes.
- **ISO-8859-1**, when the XML declaration says so: read and converted.
- Anything else, such as UTF-32 or a declared encoding zmz does not know: `UnsupportedEncoding`.

Text comes back as UTF-8 whatever the source used, and the writer always writes UTF-8.

## Zig and platforms

- **Zig 0.16.0.** zmz follows Zig releases; each zmz version names the one Zig version it builds with.
- **Little-endian only.** Binary arrays are little-endian by definition, and zmz reads them in place. A big-endian target fails at compile time instead of misreading numbers.
- **Tested** on x86_64 and aarch64 Linux and on aarch64 macOS, in Debug and ReleaseFast, and with CPU-specific code turned off.
- **No libc.** zlib comes from [zipir](https://github.com/eneskemalergin/zipir), a pure-Zig package fetched by hash.

## zmz versions

zmz follows [Semantic Versioning](https://semver.org/). Before 1.0, any version may change the API, and every breaking change is listed in the [changelog](https://github.com/eneskemalergin/zmz/blob/main/CHANGELOG.md) under its version. Pin a release tag in your `build.zig.zon` (see [Getting started](Getting-started#add-zmz-to-a-project)) and upgrade on purpose.

What stays stable across versions:

- **Diagnostic IDs.** `ZMZ0011` means the same thing in every version, and retired IDs are never reused.
- **Decoded values.** The same file decodes to the same numbers, bit for bit, whatever version, platform, or CPU path.
- **Output within a version.** For the same input and calls, the writer produces the same bytes. zlib-compressed bytes may change between zipir versions; they always decode to the same values.

## Vocabulary versions

The bundled PSI-MS and Unit Ontology tables are part of each release, and a newer vocabulary release reaches you through a zmz release, or at run time with `parseObo`. A file that declares an older release the history records is reported as `historical`, back to the releases listed in [Vocabulary](Vocabulary#what-gets-bundled). Version strings are never compared to guess at age, so a release the history does not know, newer or older, is `unrecognized_version`; the resolver's `known_versions` lets you vouch for one as `historical` or `future`. Either way, lookups use the bundled tables, and the result says which resource answered.
