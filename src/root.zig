//! Exposes the package's format modules. Targets are little-endian: array bytes are used in
//! place, with no byte swapping.

const builtin = @import("builtin");

pub const mzml = @import("mzml/mzml.zig");

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("zmz supports little-endian targets only");
}

test {
    _ = @import("binary/core.zig");
    _ = @import("binary/zlib.zig");
    _ = @import("mzml/decoded_arrays.zig");
    _ = @import("mzml/internal/reader_engine.zig");
    _ = @import("xml/mzml_adapter.zig");
}
