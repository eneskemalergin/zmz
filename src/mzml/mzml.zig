//! Exposes the public mzML library API.

pub const numpress = @import("../binary/numpress.zig");
pub const cv = @import("../cv/cv.zig");
pub const base64 = @import("../binary/base64.zig");
pub const zlib = @import("../binary/zlib.zig");
pub const arrays = @import("../binary/arrays.zig");
pub const model = @import("model.zig");
pub const owned = @import("owned.zig");
pub const Builder = @import("builder.zig");
pub const IndexedReader = @import("indexed_reader.zig");
pub const StreamReader = @import("stream_reader.zig").StreamReader;
pub const Writer = @import("writer.zig");
pub const Diagnostic = @import("diagnostic.zig");
/// Deepest element nesting, counting the root, that readers, writers, copies, and builders accept.
pub const MAX_DEPTH = @import("schema.zig").MAX_DEPTH;
