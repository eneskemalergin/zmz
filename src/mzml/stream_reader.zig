//! Exposes the forward-only mzML reader while keeping indexed parsing internal.

const std = @import("std");
const model = @import("model.zig");
const DecodedArrays = @import("decoded_arrays.zig");
const Diagnostic = @import("diagnostic.zig");
const Engine = @import("internal/reader_engine.zig");

/// Reads header metadata, then records or items, from a forward byte stream it borrows until
/// deinit. Neither may be copied or moved: the reader keeps a pointer to the input, and a copied
/// reader would free its storage twice. Header metadata lasts until deinit, and each record or item
/// call invalidates the previous one. The first failure sets `diagnostic()` and later reads return
/// `FailedState`. A call made while another runs, as from a selection callback, the input reader,
/// or the allocator, returns `InvalidState` and leaves it unharmed.
pub const StreamReader = struct {
    pub const Limits = Engine.Limits;
    pub const Payload = Engine.Payload;
    pub const ArraySelector = Engine.ArraySelector;
    pub const Selection = Engine.Selection;
    pub const Options = Engine.Options;
    pub const Error = Engine.Error;

    inner: Engine,

    /// Checks the options without consuming input; nothing is allocated until the first read.
    /// Streaming input needs buffer capacity for peekGreedy(1), otherwise InvalidOptions; an
    /// empty fixed reader reads as malformed XML.
    pub fn init(allocator: std.mem.Allocator, input: *std.Io.Reader, options: Options) error{InvalidOptions}!StreamReader {
        return .{ .inner = try Engine.init(allocator, input, options) };
    }

    /// Leaves the input open.
    pub fn deinit(self: *StreamReader) void {
        self.inner.deinit();
        self.* = undefined;
    }

    /// Reads the header once; repeated calls return it without advancing input. List observations
    /// in it update as records are consumed.
    pub fn readHeader(self: *StreamReader) Error!*const model.Header {
        return self.inner.readHeader();
    }

    /// Returns the next spectrum or chromatogram, or null after the mzML content, skipping list
    /// transitions and XML between records (nextItem keeps them). The indexed trailer is read
    /// only with retain_index and its offsets and checksum are not verified; buffered input may
    /// already hold bytes past the mzML content.
    pub fn nextRecord(self: *StreamReader) Error!?model.Record {
        return self.inner.nextRecord();
    }

    /// Returns list transitions, records, and XML after the header in source order, or null at
    /// the mzML end; the trailer follows the nextRecord rules.
    pub fn nextItem(self: *StreamReader) Error!?model.Item {
        return self.inner.nextItem();
    }

    /// Like nextItem, decoding each record's selected arrays as nextDecodedRecord does. Other
    /// items, EOF, and errors leave output empty.
    pub fn nextDecodedItem(self: *StreamReader, output: *DecodedArrays) Error!?model.Item {
        return self.inner.nextDecodedItem(output);
    }

    /// Like nextRecord, decoding the selected arrays into output instead of retaining their
    /// Base64 text: every modeled array without array_selector, whatever payload says. Skipped
    /// arrays keep their metadata. Output slices last until output is reused, reset, or
    /// deinitialized; EOF and errors leave it empty. A failed record is not skipped.
    pub fn nextDecodedRecord(self: *StreamReader, output: *DecodedArrays) Error!?model.Record {
        return self.inner.nextDecodedRecord(output);
    }

    /// Returns a copy of the first failure that outlives later reads.
    pub fn diagnostic(self: *const StreamReader) ?Diagnostic {
        return self.inner.diagnostic();
    }

    /// Returns the indexed wrapper nodes kept by retain_index once traversal ends, valid until
    /// deinit; null otherwise.
    pub fn indexTrailer(self: *const StreamReader) ?[]const model.Node {
        if (!self.inner.done or !self.inner.header.indexed or !self.inner.options.retain_index)
            return null;
        return &self.inner.index_trailer;
    }
};
