<!-- markdownlint-disable MD033 MD041 -->

<p align="center">
  <img src="assets/logo-readme.svg" alt="zmz" width="180">
</p>

<p align="center">
  Mass Spectrometry Open Data Format Library for Zig
</p>

<p align="center">
  <a href="#what-zmz-is"><img src="https://img.shields.io/badge/first%20format-mzML-0066CC?style=flat-square" alt="First format: mzML"></a>
  <a href="https://ziglang.org/download/"><img src="https://img.shields.io/badge/Zig-0.16.0-F7A41D?style=flat-square&amp;logo=zig&amp;logoColor=white" alt="Zig 0.16.0"></a>
  <a href="#direction"><img src="https://img.shields.io/badge/status-early%20development-C17D10?style=flat-square" alt="Status: early development"></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-Apache%202.0-0066CC?style=flat-square" alt="License: Apache 2.0"></a>
</p>

<!-- markdownlint-enable MD041 -->

---

`zmz` is a Zig library for mass-spectrometry data, inspired by [`mzdata`](https://github.com/mobiusklein/mzdata), a Rust library and data model for reading several mass-spectrometry file formats. It starts as the mzML dependency for my other Zig projects. The near-term work stays focused on mzML while leaving room for more mass-spectrometry file formats later.

## What zmz is

The first version brings the pieces needed for mzML into one package:

- forward and indexed reading for sequential workflows and targeted record access;
- plain and indexed writing for generated or transformed files;
- checked metadata construction;
- records and metadata that callers can retain beyond the next read;
- binary-array decoding and encoding with Base64, zlib, and MS-Numpress;
- scientific metadata and controlled-vocabulary access.

The package imports as `zmz`. The mzML API is available under `@import("zmz").mzml`.

zlib arrays are decoded and encoded by [zipir](https://github.com/eneskemalergin/zipir), a Zig package pinned by hash in `build.zig.zon`; building needs only Zig. Compression takes zipir's presets, `fast`, `even`, and `dense`.

## Direction

The near-term design aims for:

- a small, fast reader and writer for large mzML files;
- keeping up with mzML format revisions while retaining backward compatibility with historical mzML files;
- clear rules for borrowed data, retained data, and who frees allocated memory;
- an XML engine focused on the forms required by mzML;
- separate modules for additional mass-spectrometry file formats if the project grows in that direction;
- release builds that stay fast and small without unnecessary runtime dependencies.

The project stays centered on mzML for the foreseeable future. Once that work is stable, it can follow the example set by `mzdata` and add readers for other mass-spectrometry file formats. Format-specific types should stay in their own modules, while shared XML, binary, and common data types remain reusable.

## Start

Use Zig 0.16.0. Add zmz to a project with `zig fetch --save git+https://github.com/eneskemalergin/zmz`, then import its module in `build.zig`:

```zig
const zmz = b.dependency("zmz", .{ .target = target, .optimize = optimize });
executable.root_module.addImport("zmz", zmz.module("zmz"));
```

The package holds the library and its notices; tests, examples, tools, and the benchmark stay in this repository. The public entry point is [`src/root.zig`](src/root.zig).

CPU-specific code is chosen at run time (`-Dkernel-backend=dispatch`, the default): Base64 uses AVX2, SHA-1 the SHA extensions, and zlib decoding a second zipir build for x86-64-v3, each only when the CPU has the features; `-Dkernel-backend=portable` uses none of them. Builds default to the baseline CPU; `-Dcpu=native` explicitly targets the build machine. Zig 0.16's self-hosted Debug backend uses scalar; ReleaseFast uses LLVM and runtime selection.

The build steps in this repository:

- `zig build test --summary all`: the library, example, tool, and benchmark tests. Add `-Doptimize=ReleaseFast` to test release builds.
- `zig build examples -Doptimize=ReleaseFast`: [complete, compiled examples](examples/README.md) of streamed reading, selected decoding, indexed access, array construction, and payload rewriting, with cleanup and buffer lifetimes. `zig build test-examples` runs them on small fixtures.
- `zig build check-mzml -Doptimize=ReleaseFast -- FILE.mzML [FILE.mzML ...]`: reads each file whole, resolves its scientific metadata, decodes every array, rebuilds its index and compares the first, middle, and last records looked up through it with the forward read, then prints totals. Malformed selected-ion and isolation-window fields are counted, not fatal; any other failure names the file and exits with status 1.
- `zig build bench`: times zmz on generated data (below).
- `zig build vocabulary -- ...`: prepares, reviews, and generates the bundled PSI-MS and Unit Ontology tables, or scans explicit files' vocabulary use; see [`vocabularies/README.md`](vocabularies/README.md).
- `zig build libm-data -- MUSL_MATH_DIR OUTPUT.zig`: regenerates `src/binary/libm_data.zig`, the `exp` and `log` tables SLOF uses, from `src/math` of a musl source tree that has `exp_data.c` and `log_data.c`.

`zig build bench` needs nothing to download. It writes mzML of five shapes (metadata-heavy, centroid, profile, zlib, and MS-Numpress) at two sizes into `.zig-cache/zmz-bench/` (about 200 MiB, reused by later runs), then times forward reading, full decoding, XML events, indexed lookup, copying, and writing, each in its own process, always in ReleaseFast. It reports wall time, throughput, peak memory, and a checksum of what each case read, and uses `zebrac`, a perf-counter benchmark runner, for instruction counts when it is on the `PATH`. Peak memory stays near 1 to 2 MiB from the small inputs to the four-times-larger ones.

## License

zmz is licensed under the [Apache License, Version 2.0](LICENSE). The third-party notices are in [`NOTICE`](NOTICE): zlib support uses zipir under the MIT license, and SLOF's `exp` and `log` tables (`src/binary/libm_data.zig`) come from Arm's optimized-routines under the MIT license. Include `LICENSE` and `NOTICE` with source and binary distributions. The bundled PSI-MS and Unit Ontology tables are under Creative Commons Attribution 4.0; `NOTICE` carries their attribution, and [`vocabularies/README.md`](vocabularies/README.md) describes the sources.

---

<p align="center"><sub>Built in Zig for practical mass-spectrometry data work.</sub></p>
