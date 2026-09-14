# Local mzML peer tools

This directory keeps locally built or locally installed peers for `zmz`. The peer commands use one small adapter interface so the same mzML file can be checked for record counts, decoded array counts, indexed access, and a normalized spectrum fingerprint. The standalone codec commands are a separate comparison layer for MS-Numpress itself.

The machine-readable inventory is [`manifest.json`](manifest.json). Its version pins were checked on 2026-09-14.

The reader peers and codec peers answer different questions. The reader peers test complete mzML handling: XML structure, indexed and sequential access, base64 and zlib decoding, Numpress integration, chromatograms, metadata, and failure behavior. The codec peers test MS-Numpress in isolation, including exact encoded bytes and round-trip values. The reader tests therefore do not replace the C++ and Rust Numpress tests. `mzdata` also depends on `numpress-rs`, so the independent codec check is the C++ peer against the direct Rust `numpress-rs` peer.

## Peer inventory

| Command | Package | Version | Role |
| --- | --- | --- | --- |
| `mzdata-peer` | [`mzdata`](https://github.com/mobiusklein/mzdata) | `0.66.7` | Closest Rust library peer |
| `pyteomics-peer` | [`pyteomics`](https://pypi.org/project/pyteomics/) | `5.0.1` | Python XML and binary-array reader |
| `pymzml-peer` | [`pymzml`](https://pypi.org/project/pymzml/) | `2.6.1` | Python streaming and indexed reader |
| `mzmlpy-peer` | [`mzmlpy`](https://pypi.org/project/mzmlpy/) | `0.3.1` | Lightweight lazy-loading Python reader |
| `pyopenms-peer` | [`pyopenms`](https://pypi.org/project/pyopenms/) | `3.5.0` | OpenMS C++ reader through Python bindings |

The manifest keeps three research exclusions under `not_included`: OpenMassSpec is vendor-file ingestion and mzML conversion rather than a direct reader, ProteoWizard has no current local build pin here, and standalone OpenMS `FileInfo` adds no reader API beyond the enabled pyOpenMS peer.

The current OpenMS peer uses the `pyOpenMS` wheel. It does not install the standalone OpenMS TOPP executables.

### Standalone MS-Numpress codecs

| Command | Source | Pin | Role |
| --- | --- | --- | --- |
| `ms-numpress-cpp-peer` | [`ms-numpress`](https://github.com/ms-numpress/ms-numpress) | commit `61acddb` | Upstream C++ implementation |
| `numpress-rs-peer` | [`numpress-rs`](https://github.com/mobiusklein/numpress-rs) | crates.io `1.1.1` | Independent Rust implementation |

Both codec commands read decimal values from stdin and accept `linear`, `pic`, or `slof`. They emit encoded byte count, decoded value count, maximum absolute round-trip error, and fingerprints for the encoded and decoded data.

The Python readers use separate virtual environments. Each tracked requirement file pins the resolved packages installed into that environment. `pyteomics` includes its XML and Numpress extras. `pymzML` is kept without its optional PyNumpress wheel so its built-in Python decoder is used. `mzmlpy` is kept without its optional Numpress extra because version `0.3.1` calls the older camelCase API while the current `pynumpress` package exposes snake_case functions. This is recorded as a peer limitation, not hidden by a compatibility patch. The Rust codec uses the crates.io `numpress-rs` `1.1.1` package recorded in its `Cargo.lock`; the upstream revision checked during research is recorded in the manifest but is not claimed as the package source pin.

Observed limits in the checked fixtures are part of the comparison record:

- `mzdata` `0.66.7` panics on the whitespace-padded `ms level` value in `scientific_metadata.mzML` and stops after three records on the mixed-encoding writer files.
- `pymzML` `2.6.1` fails on some Numpress records through its built-in decoder and on the checked writer files with an unsupported missing data type; the raw/zlib fixture passes. Its API reports the tested `scan=1` native ID as integer `1`, so a fingerprint can differ even when counts and arrays agree.
- `mzmlpy` `0.3.1` has no Numpress path in its default local environment because of the PyNumpress API mismatch described above.
- pyOpenMS returns some Numpress intensity arrays as `float32`, so its exact fingerprint can differ from `f64` readers even when record and value counts agree. It also exposes one retention time for a multi-scan spectrum; on `scientific_metadata.mzML` it returns `76` seconds while the other adapters use the first scan's `1.25` minutes.
- `pyteomics` `5.0.1` agrees on counts with the other readers but decodes some SLOF values differently in `writer_linear_slof.mzML`; the mismatch is visible in the fingerprint and is not hidden.

These cases are reported as unavailable inputs or result mismatches by `tools/bench.sh compare`; the adapter does not edit third-party packages to make them disappear.

## Install

Run the installer from the repository root:

```text
tools/install.sh
tools/install.sh --check
tools/install.sh --list
```

The installer needs `cargo`, `rustc`, `git`, `g++`, `python3`, Python virtual-environment support, and network access to crates.io, PyPI, and the pinned MS-Numpress repository. It does not write to a global package directory or modify `PATH`.

The initial installer target is Linux x86_64. Each package is installed below `tools/`; the generated directories are ignored by the root `.gitignore`.

Cargo compile concurrency is capped at four jobs by default. Set `TOOL_JOBS=N` when a different local limit is appropriate. Python package installs run one environment at a time. Repeat installs reuse a valid peer environment and skip pip when every pinned requirement already matches. Package and compiler caches stay below `tools/build/` so repeat installs can reuse them; generated cache directories can be removed when reclaiming disk space, then recreated by the installer.

The tracked layout is intentionally small: `install.sh` builds and checks peers, `versions.sh` holds source pins, `manifest.json` describes the inventory, `peer.sh` dispatches the isolated Python readers, `mzml_peer.py` normalizes their output, `bench.sh` runs all comparisons and timings, and `wrappers/` contains the two Rust binaries and the C++ Numpress wrapper.

## Common commands

Every enabled peer accepts these commands:

```text
tools/bin/<peer> summary FILE.mzML
tools/bin/<peer> fingerprint FILE.mzML
tools/bin/<peer> random FILE.mzML ZERO_BASED_INDEX
```

Each command writes one JSON object to stdout and errors to stderr. `summary` reports spectra, chromatograms when the backend exposes that count, non-empty canonical m/z and intensity array counts, decoded value counts, array length mismatches, and MS-level counts. `fingerprint` decodes every spectrum and reports the same spectrum-only fingerprint fields without doing a second chromatogram pass. `random` reads one spectrum by zero-based index and includes the access mode. The access mode is `indexed` for file-index lookup, `full-file-load` for pyOpenMS, or `sequential-fallback` when pymzML cannot use its index for that file.

The fingerprint is an FNV-1a 64-bit comparison signal. It hashes the native ID, zero-based spectrum order, MS level, reader-reported scan start time normalized to minutes with missing values as zero, and the m/z and intensity values normalized to little-endian `f64`. It is not a cryptographic digest. A matching count is necessary but not sufficient evidence that two readers agree; investigate the first differing spectrum with `random` and inspect the source file when fingerprints differ.

The common fingerprint covers spectra and the two required mzML arrays. The manifest records broader backend features, including chromatograms and indexed access, because those APIs do not have identical behavior across all peers.

## Compare and benchmark

Run the correctness comparison before timing a file:

```text
tools/bench.sh compare tests/mzml/data/writer_raw_zlib.mzML
tools/bench.sh benchmark tests/mzml/data/writer_raw_zlib.mzML
tools/bench.sh numpress-compare
tools/bench.sh numpress-benchmark
```

`tools/bench.sh compare` runs the local enabled commands and compares the common summary fields, including chromatogram counts and the spectrum fingerprint. A peer that cannot decode a file is reported as unavailable for that input and is excluded from the comparison; that is not recorded as a correctness mismatch. The command exits `1` for a result mismatch, `2` when fewer than two peers can be compared, and `0` when all available peers agree. `tools/bench.sh benchmark` runs the common `fingerprint` command three times by default and prints tab-separated wall time, maximum resident memory, and exit status. The timing includes process startup, parsing, binary decoding, adapter normalization, and FNV hashing; it is not an isolated parser-throughput measurement. Set `RUNS=N` to change the run count. The command does not flush the operating-system page cache, pin CPUs, or claim cold-cache results, so record the host and cache state with any published benchmark.

`tools/bench.sh numpress-compare` sends the vectors in `tests/numpress/vectors.tsv` through both standalone codec implementations, compares the emitted encoded bytes, and sends each implementation's bytes through the other decoder. It also compares decoded value fingerprints. `tools/bench.sh numpress-benchmark` times the same codec roundtrip for each algorithm. This is the Numpress-specific comparison; the mzML peer benchmark measures complete file-reader behavior.

The benchmark harness reports measurements only. It does not define an acceptance threshold and does not replace correctness checks.

For project changes, use the ignored local workbench at `tmp/bench/run.sh`. It checks the tracked mzML shape registry, runs the ReleaseSafe project tests and validator, records a source receipt, and only then permits Zebrac timing. It uses three warmups and exact measured counts from 15 to 25 based on input size. `tools/bench.sh` remains the direct peer and standalone Numpress comparison command.

## Local generated state

The installer owns these ignored paths:

- `tools/bin/`: peer launchers and the compiled `mzdata-peer` binary.
- `tools/build/`: Cargo registry, Cargo target output, Python package cache, and the installer lock file.
- `tools/venv/<peer>/`: isolated Python virtual environments containing the pinned wheels.
- `tools/wrappers/target/`: Rust target output when built directly with Cargo.

The tracked inputs are the manifest, version pins, installer, one benchmark runner, the peer launcher and adapter, four pinned Python requirement files, the Rust wrapper project and its `Cargo.lock`, the C++ wrapper source, and the Numpress vector file. Do not commit downloaded packages, virtual environments, source checkouts, binaries, or benchmark output.
