//! Exposes the forward-only mzML reader while keeping indexed parsing internal.

const std = @import("std");
const model = @import("model.zig");
const impl = @import("internal/reader_engine.zig");

/// Reads header metadata and current records from a forward byte stream.
pub const StreamReader = struct {
    const Reader = @This();

    /// Independent bounds for parser state, retained metadata, records, lists, and payload text.
    pub const Limits = impl.Limits;

    /// Retains or skips binary text without decoding it.
    pub const Payload = impl.Payload;

    pub const ArraySelector = impl.ArraySelector;

    /// Reader limits, payload policy, and index retention.
    pub const Options = impl.Options;

    /// Includes decoding errors when numeric arrays are requested.
    pub const Error = impl.Error;

    /// The first reader failure and its physical source location.
    pub const Diagnostic = impl.Diagnostic;

    pub const DecodedArrays = @import("decoded_arrays.zig");

    inner: impl,

    /// Borrows input for the reader's lifetime and allocates parser state.
    pub fn init(allocator: std.mem.Allocator, input: *std.Io.Reader, options: Options) Error!Reader {
        return .{ .inner = try impl.init(allocator, input, options) };
    }

    /// Releases parser, metadata, and record storage without closing the input.
    pub fn deinit(self: *Reader) void {
        self.inner.deinit();
        self.* = undefined;
    }

    /// Returns header metadata before the first record; repeated calls do not advance input.
    pub fn readHeader(self: *Reader) Error!*const model.Header {
        return self.inner.readHeader();
    }

    /// Returns a borrowed record or null after the mzML content.
    /// Indexed trailers are read only with retain_index; input buffering may fetch ahead.
    pub fn nextRecord(self: *Reader) Error!?model.Record {
        return self.inner.nextRecord();
    }

    /// Reads a complete record and decodes every array into reusable output storage.
    /// Metadata borrows this reader as in nextRecord; binary text is not retained.
    /// Output slices last until output is reused, reset, or deinitialized. EOF and errors
    /// clear its visible results. Requires no array_selector; payload
    /// does not affect this call. The first failure stops reading and sets the diagnostic;
    /// subsequent reads return FailedState. No automatic record skipping occurs.
    pub fn nextDecodedRecord(self: *Reader, output: *DecodedArrays) Error!?model.Record {
        return self.inner.nextDecodedRecord(output);
    }

    /// Returns the first sticky failure without borrowing parser event memory.
    pub fn diagnostic(self: *const Reader) ?Diagnostic {
        return self.inner.diagnostic();
    }

    /// Returns retained indexed wrapper nodes after traversal, valid until deinit, or null when none were retained.
    pub fn indexTrailer(self: *const Reader) ?[]const model.Node {
        if (!self.inner.done or !self.inner.header.indexed or !self.inner.options.retain_index)
            return null;
        return &self.inner.index_trailer;
    }
};
