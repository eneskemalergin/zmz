# z-mzml

A Zig library for reading, writing, and working with mzML files, under development.

Status: early development. The public API is not stable.

The package currently exposes CV parameter helpers, MS-Numpress, Base64, zlib, and binary-array codec composition. The default build uses Zig 0.16 without C dependencies.

Whole-file mzML reading and writing are not implemented yet. The public import is `@import("z_mzml")`; its exports are in [src/root.zig](src/root.zig).

Run the self-contained checks with `zig build test --summary all` and `zig build test -Doptimize=ReleaseFast --summary all`.
