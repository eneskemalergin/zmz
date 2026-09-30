//! Exposes the package's format modules.

pub const mzml = @import("mzml/mzml.zig");

test {
    _ = @import("binary/core.zig");
    _ = @import("binary/sha1.zig");
    _ = @import("mzml/internal/reader_engine.zig");
    _ = @import("xml/mzml_adapter.zig");
}
