//! Exposes the supported z-mzML library API.

/// Encodes and decodes established MS-Numpress numeric transforms.
pub const numpress = @import("binary/numpress.zig");

/// Preserves vocabulary identity, parameter order, and explicit group expansion.
pub const cv = @import("cv.zig");

/// Handles padded Base64 with bounded, fragmented XML-text decoding.
pub const base64 = @import("binary/base64.zig");
