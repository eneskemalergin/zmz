//! Builds the library suites as one test executable, so the library is compiled once for all of
//! them. Each suite keeps its own file and fixtures.

comptime {
    _ = @import("binary/test_numpress.zig");
    _ = @import("binary/test_codecs.zig");
    _ = @import("cv/test_cv.zig");
    _ = @import("mzml/test_metadata.zig");
    _ = @import("mzml/test_construction.zig");
    _ = @import("mzml/test_indexing.zig");
    _ = @import("mzml/test_ownership.zig");
    _ = @import("mzml/test_writing.zig");
    _ = @import("mzml/test_reader.zig");
    _ = @import("mzml/test_events.zig");
}
