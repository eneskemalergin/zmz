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

const std = @import("std");
const zmz = @import("zmz");

test "[unit] - [package]: reports the version build.zig.zon declares" {
    var buffer: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{f}", .{zmz.version});
    try std.testing.expectEqualStrings(@import("declared_version").text, text);
}
