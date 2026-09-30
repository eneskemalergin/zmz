//! Exposes the forward-only mzML reader while keeping indexed parsing internal.

const std = @import("std");
const model = @import("model.zig");
const impl = @import("internal/reader_engine.zig");

/// Reads header metadata and current records from a forward byte stream.
pub const StreamReader = struct {
    const Reader = @This();

    pub const Limits = impl.Limits;
    pub const Payload = impl.Payload;
    pub const ArraySelector = impl.ArraySelector;
    pub const Selection = impl.Selection;
    pub const Options = impl.Options;
    pub const Error = impl.Error;
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

    /// Returns records only, skipping XML outside them and list transitions.
    /// Use nextItem for a rewrite that retains those fields and their positions.
    /// Indexed trailers are read only with retain_index; input buffering may fetch ahead.
    pub fn nextRecord(self: *Reader) Error!?model.Record {
        return self.inner.nextRecord();
    }

    /// Returns list transitions, records, and XML after the header in source order.
    /// Each call invalidates the previous record or XML item. Null marks mzML end;
    /// retain_index controls trailer reading as for nextRecord.
    pub fn nextItem(self: *Reader) Error!?model.Item {
        return self.inner.nextItem();
    }

    /// Like nextItem, with selected record arrays decoded into output. Non-record
    /// items, EOF, and errors clear visible arrays. Lifetimes follow nextDecodedRecord.
    pub fn nextDecodedItem(self: *Reader, output: *DecodedArrays) Error!?model.Item {
        return self.inner.nextDecodedItem(output);
    }

    /// Reads a complete record and decodes selected arrays into reusable output storage.
    /// Without array_selector, decodes every modeled array. Skipped arrays keep their metadata.
    /// Metadata borrows this reader as in nextRecord; modeled binary text is not retained.
    /// Output slices last until output is reused, reset, or deinitialized. EOF and errors
    /// clear its visible results. Payload does not affect this call.
    /// The first failure stops reading and sets the diagnostic;
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
