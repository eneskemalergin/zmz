<!-- markdownlint-disable MD024 MD034 -->

# Changelog

All notable changes to zmz are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/). Each version starts with a short release summary, followed by user-visible changes grouped by area. Until 1.0, any version may change the API, and every breaking change is listed under its version.

## [0.1.0] - Unreleased

The first release of zmz, a Zig library for mass-spectrometry data, starting with mzML. It streams mzML of any size in flat memory, looks records up by ID or position, decodes and encodes the standard binary-array encodings, and writes plain or indexed mzML, with optional PSI-MS and Unit Ontology lookup. It needs Zig 0.16.0 and nothing else. Not supported yet: whole-file gzip (planned for 0.2.0), Zstandard-compressed arrays, pre-release mzML drafts, and formats other than mzML.

### Added

- **Reading:**
  - `StreamReader` reads mzML forward to the end of the file: the header, then every spectrum and chromatogram. Records borrow from the reader until the next read; `owned` copies keep them as long as you need.
  - `nextDecodedRecord` decodes arrays while it reads, into reusable `DecodedArrays` buffers. `array_selector` and `select_record` decode only the arrays and records you choose. Memory stays flat as files grow.
  - `nextItem` returns the XML between records too, so a file can be copied whole.
  - `Events` exposes every XML event with its source offsets, for tools that work on the raw structure.
  - Reads the mzML 1.1 namespace (1.1.0 and 1.1.1) and the original 1.0.0 namespace, in UTF-8, UTF-16, or declared ISO-8859-1. DTDs and external entities are rejected.
- **Indexed access:**
  - `IndexedReader` opens the embedded `indexedmzML` index or rebuilds one by scanning, then fetches records by ID or by position, with or without decoding their arrays. IDs are stored compactly, so large indexes stay small.
- **Writing:**
  - `Writer` writes plain mzML to any `std.Io.Writer`, indexed mzML with its offsets and SHA-1 checksum, or a file whose unknown counts and lengths are patched in place afterwards.
  - Arrays are encoded while they are written; on file output no buffer holds a whole compressed array.
  - Rewriting keeps every attribute, parameter, and unfamiliar XML element it read. Output is deterministic.
- **Construction:**
  - `Builder` builds headers, records, lists, and arrays from your values, checked against the mzML structure and bounded by its limits. `reencoding` writes a file's arrays in other encodings and keeps the rest of its metadata.
- **Binary arrays:**
  - Decodes and encodes 32- and 64-bit floats and integers with no compression, zlib, or MS-Numpress Linear, PIC, and SLOF, alone or with zlib. zlib comes from zipir, with the presets `fast`, `even`, and `dense`. Numpress bytes match the C++ ms-numpress reference wherever its input is valid.
  - Base64 uses AVX2, SHA-1 the SHA extensions, and zlib decoding an x86-64-v3 build, each chosen at run time when the CPU has them. `-Dkernel-backend=portable` leaves CPU-specific code out.
  - Refuses encodings it does not implement (16-bit floats, Zstandard, truncation, coordinate grids, and null-terminated text) with `UnsupportedEncoding` instead of misreading them.
- **Metadata:**
  - Keeps every `cvParam`, `userParam`, and referenceable parameter group as written, with absent and empty values kept apart. Groups expand on request.
  - Reads scientific fields directly: MS level, polarity, centroid or profile, scan start time, precursors, selected ions, isolation windows, and arrays by role.
- **Vocabulary:**
  - `cv.Resolver` checks parameters against bundled PSI-MS 4.2.5 and Unit Ontology 2026-10-12 tables: names, obsolete terms, allowed units, numeric quantities, and declared versions back to PSI-MS 3.80 and the Unit Ontology's 2011 releases.
  - `cv.Vocabulary` gives each term's name, definition, synonyms, relations, ancestry (`isA`), value types, subsets, and release history. A program links only the tables it uses.
  - `Vocabulary.parseObo` loads a newer PSI-MS release, or another OBO file, at run time.
- **Errors and safety:**
  - Every failure returns a named error, and `Diagnostic` saves where it happened: the operation, element, record, offset, and limit involved. Readers and writers keep their first failure.
  - Limits bound memory and work on untrusted input, and no input reaches undefined behavior, in ReleaseFast too. Fuzz targets and allocation-failure sweeps check the parsers.
- **Tools and examples:**
  - Five example programs (`zig build examples`): streamed reading, selected decoding, indexed access, writing, and rewriting.
  - `zig build check-mzml` reads, decodes, and index-checks real files.
  - `zig build bench` times reading, decoding, lookup, copying, and writing on generated data, with nothing to download.
- **Platforms:**
  - Zig 0.16.0 with no libc dependency, tested on x86_64 and aarch64 Linux and on aarch64 macOS. Big-endian targets are refused at build time.
  - `zmz.version` reports the package version that `build.zig.zon` declares.

[0.1.0]: https://github.com/eneskemalergin/zmz/releases/tag/v0.1.0
