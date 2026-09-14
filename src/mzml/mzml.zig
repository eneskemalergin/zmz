//! Exposes the public mzML library API.

/// Encodes and decodes MS-Numpress numeric transforms.
pub const numpress = @import("../binary/numpress.zig");

/// Preserves controlled-vocabulary identity and parameter order.
pub const cv = @import("../cv/cv.zig");

/// Decodes fragmented XML text and encodes padded Base64.
pub const base64 = @import("../binary/base64.zig");

/// Encodes and checks independent zlib streams.
pub const zlib = @import("../binary/zlib.zig");

/// Composes primitive, Numpress, zlib, and Base64 array transforms.
pub const arrays = @import("../binary/arrays.zig");

/// Preserves mzML metadata, record hierarchy, and array interpretation.
pub const model = @import("model.zig");

/// Makes independent copies of mzML records and header metadata.
pub const owned = @import("owned.zig");

/// Constructs checked mzML metadata and encoded arrays.
pub const Builder = @import("builder.zig");

/// Checks mzML structure, metadata spellings, and references.
pub const Validator = @import("validator.zig");

/// Builds indexes and reads records from stable bytes or files.
pub const IndexedReader = @import("indexed_reader.zig");

/// Reads header metadata and records from a forward byte stream.
pub const StreamReader = @import("stream_reader.zig").StreamReader;

/// Writes plain or indexed mzML to a forward byte sink.
pub const Writer = @import("writer.zig");
