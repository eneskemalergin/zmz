<!-- markdownlint-disable MD033 MD041 -->

<h1 align="center">zmz</h1>

<p align="center">
  <strong>A Zig mass-spectrometry data library, starting with mzML.</strong>
</p>

<p align="center">
  <a href="#what-zmz-is"><img src="https://img.shields.io/badge/first%20format-mzML-0066CC?style=flat-square" alt="First format: mzML"></a>
  <a href="https://ziglang.org/download/"><img src="https://img.shields.io/badge/Zig-0.16.0-F7A41D?style=flat-square&amp;logo=zig&amp;logoColor=white" alt="Zig 0.16.0"></a>
  <a href="#direction"><img src="https://img.shields.io/badge/status-early%20development-C17D10?style=flat-square" alt="Status: early development"></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-not%20selected-94a3b8?style=flat-square" alt="License: not selected"></a>
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

## Direction

The near-term design aims for:

- a small, fast reader and writer for large mzML files;
- clear rules for borrowed data, retained data, and who frees allocated memory;
- an XML engine focused on the forms required by mzML;
- separate modules for additional mass-spectrometry file formats if the project grows in that direction;
- release builds that stay fast and small without unnecessary runtime dependencies.

The project stays centered on mzML for the foreseeable future. Once that work is stable, it can follow the example set by `mzdata` and add readers for other mass-spectrometry file formats. Format-specific types should stay in their own modules, while shared XML, binary, and common data types remain reusable.

## Start

Use Zig 0.16.0. Run the library checks with:

```sh
zig build test --summary all
zig build test -Doptimize=ReleaseFast --summary all
```

Base64 uses runtime AVX2 selection in LLVM x86-64 builds and scalar fallback elsewhere. `-Dbase64_simd=false` forces scalar. Builds default to the baseline CPU; `-Dcpu=native` explicitly targets the build machine. Zig 0.16's self-hosted Debug backend uses scalar; ReleaseFast uses LLVM and runtime selection.

The public entry point is [`src/root.zig`](src/root.zig). Vocabulary resources and their source notices are described in [`vocabularies/README.md`](vocabularies/README.md).

## Peer readers and benchmarks

The local mzML reader inventory, reproducible installer, C++ and Rust MS-Numpress peers, comparison commands, and benchmark commands are in [`tools/README.md`](tools/README.md). Install them with `tools/install.sh`; generated checkouts, virtual environments, caches, binaries, and benchmark output remain local and ignored.

## License

The project license has not been selected yet. The bundled vocabulary resources retain their source terms and attribution requirements; see [`vocabularies/README.md`](vocabularies/README.md).

---

<p align="center"><sub>Built in Zig for practical mass-spectrometry data work.</sub></p>
