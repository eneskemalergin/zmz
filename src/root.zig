//! Exposes the package's format modules.

/// Reads and writes mzML files.
pub const mzml = @import("mzml/mzml.zig");

test {
    _ = @import("binary/base64.zig");
    _ = @import("mzml/internal/reader_engine.zig");
    _ = @import("xml/mzml_adapter.zig");
}
