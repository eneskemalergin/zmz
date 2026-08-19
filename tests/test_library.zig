//! Verifies the supported z-mzML package import.

const mzml = @import("z_mzml");

test "[integration] - [library]: imports the public module" {
    _ = mzml;
}
