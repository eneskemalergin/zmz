//! Exposes the package's format modules. Targets are little-endian: array bytes are used in
//! place, with no byte swapping.

const std = @import("std");
const builtin = @import("builtin");

pub const mzml = @import("mzml/mzml.zig");

/// The package version, as build.zig.zon declares it.
pub const version: std.SemanticVersion = std.SemanticVersion.parse(@import("package_options").version) catch
    @compileError("build.zig.zon's version is not a semantic version");

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("zmz supports little-endian targets only");
}

test {
    _ = @import("binary/core.zig");
    _ = @import("binary/zlib.zig");
    _ = @import("mzml/decoded_arrays.zig");
    _ = @import("mzml/internal/id_index.zig");
    _ = @import("mzml/internal/reader_engine.zig");
    _ = @import("xml/mzml_adapter.zig");
}
