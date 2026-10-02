//! Exposes the forward-only mzML reader while keeping indexed parsing internal.

const std = @import("std");
const model = @import("model.zig");
const impl = @import("internal/reader_engine.zig");

/// Reads header metadata, then records or items, from a forward byte stream it borrows until
/// deinit; copy neither the input nor the reader. Header metadata lasts until deinit, and each
/// record or item call invalidates the previous one. The first failure sets diagnostic() and
/// later reads return FailedState. A call made while another runs, as from a selection
/// callback, the input reader, or the allocator, returns InvalidState and leaves it unharmed.
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

    /// Allocates parser state without consuming input. Streaming input needs buffer capacity
    /// for peekGreedy(1), otherwise InvalidOptions; an empty fixed reader reads as malformed XML.
    pub fn init(allocator: std.mem.Allocator, input: *std.Io.Reader, options: Options) Error!Reader {
        return .{ .inner = try impl.init(allocator, input, options) };
    }

    /// Leaves the input open.
    pub fn deinit(self: *Reader) void {
        self.inner.deinit();
        self.* = undefined;
    }

    /// Repeated calls return the same header without advancing input. List observations in it
    /// update as records are consumed.
    pub fn readHeader(self: *Reader) Error!*const model.Header {
        return self.inner.readHeader();
    }

    /// Returns the next spectrum or chromatogram, or null after the mzML content, skipping list
    /// transitions and XML between records (nextItem keeps them). The indexed trailer is read
    /// only with retain_index and its offsets and checksum are not verified; buffered input may
    /// already hold bytes past the mzML content.
    pub fn nextRecord(self: *Reader) Error!?model.Record {
        return self.inner.nextRecord();
    }

    /// Returns list transitions, records, and XML after the header in source order, or null at
    /// the mzML end; the trailer follows the nextRecord rules.
    pub fn nextItem(self: *Reader) Error!?model.Item {
        return self.inner.nextItem();
    }

    /// Like nextItem, decoding each record's selected arrays as nextDecodedRecord does. Other
    /// items, EOF, and errors leave output empty.
    pub fn nextDecodedItem(self: *Reader, output: *DecodedArrays) Error!?model.Item {
        return self.inner.nextDecodedItem(output);
    }

    /// Like nextRecord, decoding the selected arrays into output instead of retaining their
    /// Base64 text: every modeled array without array_selector, whatever payload says. Skipped
    /// arrays keep their metadata. Output slices last until output is reused, reset, or
    /// deinitialized; EOF and errors leave it empty. A failed record is not skipped.
    pub fn nextDecodedRecord(self: *Reader, output: *DecodedArrays) Error!?model.Record {
        return self.inner.nextDecodedRecord(output);
    }

    /// Returns a copy of the first failure that outlives later reads.
    pub fn diagnostic(self: *const Reader) ?Diagnostic {
        return self.inner.diagnostic();
    }

    /// Returns the indexed wrapper nodes kept by retain_index once traversal ends, valid until
    /// deinit; null otherwise.
    pub fn indexTrailer(self: *const Reader) ?[]const model.Node {
        if (!self.inner.done or !self.inner.header.indexed or !self.inner.options.retain_index)
            return null;
        return &self.inner.index_trailer;
    }
};
