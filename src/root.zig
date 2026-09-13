//! Exposes the supported z-mzML library API.

/// Encodes and decodes established MS-Numpress numeric transforms.
pub const numpress = @import("binary/numpress.zig");

/// Preserves vocabulary identity, parameter order, and explicit group expansion.
pub const cv = @import("cv.zig");

/// Handles padded Base64 with bounded, fragmented XML-text decoding.
pub const base64 = @import("binary/base64.zig");

/// Encodes and checks independent zlib streams without a C dependency.
pub const zlib = @import("binary/zlib.zig");

/// Composes established binary-array pipelines using caller-owned buffers.
pub const arrays = @import("binary/arrays.zig");

/// Preserves mzML metadata, record hierarchy, and explicit binary-array interpretation.
pub const model = @import("mzml/model.zig");

/// Makes explicit independent copies of records and header metadata.
pub const owned = @import("mzml/owned.zig");

/// Constructs checked metadata hierarchies and declared encoded arrays.
pub const Builder = @import("mzml/builder.zig");

/// Checks mzML document structure, metadata spellings, and references, without CV or payload interpretation.
pub const Validator = @import("mzml/validator.zig");

/// Builds validated indexes and reads individual records from stable bytes or files.
pub const IndexedReader = @import("mzml/indexed_reader.zig");

/// Reads header metadata and current-record views from a forward byte stream.
pub const StreamReader = @import("mzml/stream_reader.zig").StreamReader;

/// Writes plain or indexed mzML metadata and retained records to a forward byte sink.
pub const Writer = @import("mzml/writer.zig");
