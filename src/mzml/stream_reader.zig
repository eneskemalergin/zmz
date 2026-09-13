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

    /// Selects full structural checks or the explicitly reduced reader checks.
    pub const Checks = impl.Checks;

    /// Reader limits, payload policy, check mode, and optional document validation.
    pub const Options = impl.Options;

    /// Structural, XML, validation, and allocation failures from reader operations.
    pub const Error = impl.Error;

    /// The first reader failure and its physical source location.
    pub const Diagnostic = impl.Diagnostic;

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

    /// Returns the current borrowed record or null at document end.
    pub fn nextRecord(self: *Reader) Error!?model.Record {
        return self.inner.nextRecord();
    }

    /// Returns the first sticky failure without borrowing parser event memory.
    pub fn diagnostic(self: *const Reader) ?Diagnostic {
        return self.inner.diagnostic();
    }

    /// Returns retained indexed wrapper nodes after EOF, valid until deinit, or null when none were retained.
    pub fn indexTrailer(self: *const Reader) ?[]const model.Node {
        if (!self.inner.done or !self.inner.header.indexed or !self.inner.options.retain_index)
            return null;
        return &self.inner.index_trailer;
    }
};
