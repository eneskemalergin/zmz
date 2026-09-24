//! Small XML scanner and writer for the XML constructs used by mzML.

const std = @import("std");
const base64 = @import("../binary/base64.zig");

/// Stable mzML namespace used by reader and writer paths.
pub const NAMESPACE = "http://psi.hupo.org/ms/mzml";
/// XML Schema instance namespace used only for `schemaLocation`.
pub const XSI = "http://www.w3.org/2001/XMLSchema-instance";
const XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace";
const XMLNS_NAMESPACE = "http://www.w3.org/2000/xmlns/";
const TEXT_CHUNK_BYTES = 64 * 1024;
const MAX_XML_DEPTH = 64;

/// XML cursor failures, including malformed input and bounded-storage failures.
pub const ReadError = error{
    InvalidXml,
    InvalidEncoding,
    UnsupportedEncoding,
    UnsupportedVersion,
    DtdForbidden,
    ReadFailed,
    LimitExceeded,
    InvalidState,
    EndOfStream,
    NoText,
};

/// Cursor construction failures caused by invalid limits or input setup.
pub const InitError = error{InvalidOptions};
/// Errors returned by the mzML XML cursor.
pub const Error = ReadError || InitError || std.mem.Allocator.Error || error{
    WrongNamespace,
    UnexpectedEnd,
};
const ParserError = Error;

/// XML declaration version recognized before the mzML layer applies its policy.
pub const XmlVersion = enum {
    xml10,
    xml11,
};

const Encoding = enum {
    utf8,
    latin1,
    utf16_le,
    utf16_be,
};

const Range = struct {
    start: usize,
    len: usize,
};

const NameRange = struct {
    start: usize,
    len: usize,
    prefix_len: usize,
};

const Codepoint = struct {
    value: u21,
    start: u64,
    end: u64,
};

/// A parsed QName with its resolved namespace URI.
pub const ExpandedName = struct {
    prefix: ?[]const u8,
    local: []const u8,
    namespace_uri: ?[]const u8,
};

/// A source QName and expanded form borrowed until the next cursor event.
pub const Name = struct {
    raw: []const u8,
    expanded: ExpandedName,

    pub fn eql(self: Name, namespace_uri: ?[]const u8, local: []const u8) bool {
        const expanded = self.expanded;
        if (!optionalSliceEql(expanded.namespace_uri, namespace_uri)) return false;
        return std.mem.eql(u8, expanded.local, local);
    }
};

/// Alias used by indexed-reader helpers for a start-element event.
pub const Start = StartElement;

pub fn localName(name: Name) []const u8 {
    return name.expanded.local;
}

/// A parsed non-namespace attribute borrowed until the next cursor event.
pub const Attribute = struct {
    name: Name,
    value: []const u8,
};

/// A parsed start element and its borrowed non-namespace attributes.
pub const StartElement = struct {
    name: Name,
    attributes: []const Attribute,
    empty_element_syntax: bool,

    pub fn attribute(self: StartElement, namespace_uri: ?[]const u8, local: []const u8) ?Attribute {
        for (self.attributes) |attribute_value| {
            if (attribute_value.name.eql(namespace_uri, local)) return attribute_value;
        }
        return null;
    }

    pub fn attributeRaw(self: StartElement, raw: []const u8) ?Attribute {
        for (self.attributes) |attribute_value| {
            if (std.mem.eql(u8, attribute_value.name.raw, raw)) return attribute_value;
        }
        return null;
    }
};

/// A parsed end element with its borrowed QName.
pub const EndElement = struct {
    name: Name,
};

/// A logical text span borrowed until the next cursor event.
pub const Text = struct {
    bytes: []const u8,
};

/// Events exposed to the mzML reader and indexed-reader bridge.
pub const EventData = union(enum) {
    document_start: struct { version: XmlVersion },
    start_element: StartElement,
    end_element: EndElement,
    text: Text,
    document_end: void,
};

/// An event with physical source-byte offsets.
pub const Event = struct {
    span: struct { start: u64, end: u64 },
    data: EventData,
};

fn optionalSliceEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn isXmlWhitespace(value: u21) bool {
    return value == ' ' or value == '\t' or value == '\r' or value == '\n';
}

fn isXmlChar(value: u21) bool {
    return value == 0x9 or value == 0xA or value == 0xD or
        (value >= 0x20 and value <= 0xD7FF) or
        (value >= 0xE000 and value <= 0xFFFD) or
        (value >= 0x10000 and value <= 0x10FFFF);
}

fn isAsciiNameStart(value: u8) bool {
    return (value >= 'A' and value <= 'Z') or
        (value >= 'a' and value <= 'z') or
        value == '_';
}

fn isAsciiNameChar(value: u8) bool {
    return isAsciiNameStart(value) or
        (value >= '0' and value <= '9') or
        value == '-' or value == '.';
}

fn isNameDelimiter(value: u21) bool {
    return isXmlWhitespace(value) or value == '/' or value == '>' or value == '=' or value == '?';
}

fn ordinaryTextRun(bytes: []const u8, limit: usize) usize {
    const available = @min(bytes.len, limit);
    const width = @min(32, std.simd.suggestVectorLength(u8) orelse 16);
    const Vector = @Vector(width, u8);
    var length: usize = 0;
    while (available - length >= width) {
        const run: Vector = bytes[length..][0..width].*;
        const exceptional = (run < @as(Vector, @splat(0x20))) |
            (run >= @as(Vector, @splat(0x80))) |
            (run == @as(Vector, @splat('<'))) |
            (run == @as(Vector, @splat('&'))) |
            (run == @as(Vector, @splat(']')));
        const ordinary: usize = if (std.simd.firstTrue(exceptional)) |lane| lane else width;
        length += ordinary;
        if (ordinary < width) break;
    }
    while (length < available) : (length += 1) {
        const byte = bytes[length];
        if (byte < 0x20 or byte >= 0x80 or byte == '<' or byte == '&' or byte == ']') break;
    }
    return length;
}

fn ordinaryAttributeRun(bytes: []const u8, quote: u8) usize {
    const width = @min(16, std.simd.suggestVectorLength(u8) orelse 16);
    const Vector = @Vector(width, u8);
    var length: usize = 0;
    while (bytes.len - length >= width) {
        const run: Vector = bytes[length..][0..width].*;
        const exceptional = (run < @as(Vector, @splat(0x20))) |
            (run >= @as(Vector, @splat(0x80))) |
            (run == @as(Vector, @splat(quote))) |
            (run == @as(Vector, @splat('&'))) |
            (run == @as(Vector, @splat('<')));
        if (std.simd.firstTrue(exceptional)) |lane| return length + lane;
        length += width;
    }
    while (length < bytes.len) : (length += 1) {
        const byte = bytes[length];
        if (byte < 0x20 or byte >= 0x80 or byte == quote or byte == '&' or byte == '<') break;
    }
    return length;
}

const Source = struct {
    reader: ?*std.Io.Reader,
    detected: bool = false,
    detection_failure: ?Error = null,
    probe: [4]u8 = undefined,
    probe_len: usize = 0,
    probe_pos: usize = 0,
    encoding: Encoding = .utf8,
    position: u64 = 0,
    pending: [4]Codepoint = undefined,
    pending_len: usize = 0,
    borrowed_len: usize = 0,

    fn init(reader: *std.Io.Reader) Source {
        return .{ .reader = reader };
    }

    fn reset(self: *Source, reader: *std.Io.Reader) void {
        self.* = Source.init(reader);
    }

    fn resetEmpty(self: *Source) void {
        self.* = .{ .reader = null };
    }

    fn ensureDetected(self: *Source) ParserError!void {
        if (self.detected) return;
        if (self.detection_failure) |failure| return failure;
        const reader = self.reader orelse return error.EndOfStream;

        while (self.probe_len < self.probe.len) {
            const byte = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => {
                    self.detection_failure = error.ReadFailed;
                    return error.ReadFailed;
                },
            };
            self.probe[self.probe_len] = byte;
            self.probe_len += 1;
        }

        if (self.probe_len >= 3 and
            self.probe[0] == 0xEF and self.probe[1] == 0xBB and self.probe[2] == 0xBF)
        {
            self.encoding = .utf8;
            self.probe_pos = 3;
            self.position = 3;
        } else if (self.probe_len >= 2 and self.probe[0] == 0xFF and self.probe[1] == 0xFE) {
            self.encoding = .utf16_le;
            self.probe_pos = 2;
            self.position = 2;
        } else if (self.probe_len >= 2 and self.probe[0] == 0xFE and self.probe[1] == 0xFF) {
            self.encoding = .utf16_be;
            self.probe_pos = 2;
            self.position = 2;
        } else if (self.probe_len >= 2 and self.probe[0] == '<' and self.probe[1] == 0) {
            self.encoding = .utf16_le;
        } else if (self.probe_len >= 2 and self.probe[0] == 0 and self.probe[1] == '<') {
            self.encoding = .utf16_be;
        } else {
            self.encoding = .utf8;
        }
        self.detected = true;
    }

    fn addPosition(self: *Source, amount: usize) ParserError!void {
        self.position = std.math.add(u64, self.position, @intCast(amount)) catch return error.LimitExceeded;
    }

    fn readByte(self: *Source) ParserError!u8 {
        try self.ensureDetected();
        if (self.probe_pos < self.probe_len) {
            const byte = self.probe[self.probe_pos];
            self.probe_pos += 1;
            try self.addPosition(1);
            return byte;
        }
        const reader = self.reader orelse return error.EndOfStream;
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        try self.addPosition(1);
        return byte;
    }

    fn readUtf16Unit(self: *Source) ParserError!u16 {
        const first = try self.readByte();
        const second = self.readByte() catch |err| return switch (err) {
            error.EndOfStream => error.InvalidEncoding,
            else => err,
        };
        return if (self.encoding == .utf16_le)
            @as(u16, first) | (@as(u16, second) << 8)
        else
            (@as(u16, first) << 8) | @as(u16, second);
    }

    fn readCodepoint(self: *Source) ParserError!Codepoint {
        if (self.pending_len != 0) {
            const value = self.pending[0];
            var index: usize = 1;
            while (index < self.pending_len) : (index += 1) self.pending[index - 1] = self.pending[index];
            self.pending_len -= 1;
            return value;
        }

        try self.ensureDetected();
        const start = self.position;
        if (self.encoding == .utf16_le or self.encoding == .utf16_be) {
            const unit = try self.readUtf16Unit();
            if (unit >= 0xD800 and unit <= 0xDBFF) {
                const next = self.readUtf16Unit() catch |err| return switch (err) {
                    error.InvalidEncoding => error.InvalidEncoding,
                    else => err,
                };
                if (next < 0xDC00 or next > 0xDFFF) return error.InvalidEncoding;
                const value: u21 = 0x10000 +
                    (@as(u21, unit - 0xD800) << 10) +
                    @as(u21, next - 0xDC00);
                return .{ .value = value, .start = start, .end = self.position };
            }
            if (unit >= 0xDC00 and unit <= 0xDFFF) return error.InvalidEncoding;
            return .{ .value = unit, .start = start, .end = self.position };
        }

        const first = try self.readByte();
        if (first < 0x80 or self.encoding == .latin1) return .{ .value = first, .start = start, .end = self.position };
        const length: usize = std.unicode.utf8ByteSequenceLength(first) catch return error.InvalidEncoding;
        if (length < 2 or length > 4) return error.InvalidEncoding;
        var bytes: [4]u8 = undefined;
        bytes[0] = first;
        for (1..length) |index| {
            const byte = self.readByte() catch |err| return switch (err) {
                error.EndOfStream => error.InvalidEncoding,
                else => err,
            };
            bytes[index] = byte;
        }
        const value = std.unicode.utf8Decode(bytes[0..length]) catch return error.InvalidEncoding;
        return .{ .value = value, .start = start, .end = self.position };
    }

    fn unread(self: *Source, value: Codepoint) Error!void {
        if (self.pending_len == self.pending.len) return error.InvalidState;
        var index = self.pending_len;
        while (index != 0) : (index -= 1) self.pending[index] = self.pending[index - 1];
        self.pending[0] = value;
        self.pending_len += 1;
    }

    fn peekCodepoint(self: *Source) ParserError!Codepoint {
        if (self.pending_len != 0) return self.pending[0];
        const value = try self.readCodepoint();
        try self.unread(value);
        return value;
    }

    fn currentOffset(self: *const Source) u64 {
        return if (self.pending_len != 0) self.pending[0].start else self.position;
    }

    fn commitBorrowed(self: *Source) ParserError!void {
        if (self.borrowed_len == 0) return;
        const reader = self.reader orelse return error.InvalidState;
        reader.toss(self.borrowed_len);
        try self.addPosition(self.borrowed_len);
        self.borrowed_len = 0;
    }

    fn peekSingleByte(self: *Source) ParserError!?[]const u8 {
        try self.ensureDetected();
        if ((self.encoding != .utf8 and self.encoding != .latin1) or
            self.probe_pos != self.probe_len or self.pending_len != 0) return null;
        const reader = self.reader orelse return error.EndOfStream;
        return reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => null,
            error.ReadFailed => error.ReadFailed,
        };
    }
};

const AttributeRange = struct {
    name: NameRange,
    value: Range,
    namespace_declaration: bool,
};

const NamespaceDeclaration = struct {
    prefix: Range,
    uri: Range,
};

const NamespaceBinding = struct {
    prefix_start: usize,
    prefix_len: usize,
    uri_start: usize,
    uri_len: usize,
};

const Frame = struct {
    name_start: usize,
    name_len: usize,
    prefix_len: usize,
    binding_start: usize,
    namespace_bytes_start: usize,
    opening_end: u64,
};

pub const Ancestors = struct {
    depth: usize,
    names: usize,
    namespace_bytes: usize,
    bindings: usize,
    encoding: Encoding,
    version: XmlVersion,
    pending_empty: bool,
};

/// Bounded streaming XML cursor for the mzML reader and indexed fragments.
pub const Cursor = struct {
    allocator: std.mem.Allocator,
    source: Source,
    max_depth: usize,
    max_attributes: usize,
    max_attribute_bytes: usize,
    current: ?Event = null,
    offset: u64 = 0,
    document_started: bool = false,
    document_ended: bool = false,
    root_seen: bool = false,
    root_closed: bool = false,
    depth: usize = 0,
    in_cdata: bool = false,
    cdata_brackets: u2 = 0,
    normal_text_brackets: u2 = 0,
    effective_version: XmlVersion = .xml10,
    frames: [MAX_XML_DEPTH]Frame = undefined,
    pending_empty: bool = false,
    event_bytes: std.ArrayList(u8) = .empty,
    text_bytes: std.ArrayList(u8) = .empty,
    declaration_bytes: std.ArrayList(u8) = .empty,
    attribute_ranges: std.ArrayList(AttributeRange) = .empty,
    namespace_declarations: std.ArrayList(NamespaceDeclaration) = .empty,
    attributes: std.ArrayList(Attribute) = .empty,
    open_names: std.ArrayList(u8) = .empty,
    namespace_bytes: std.ArrayList(u8) = .empty,
    namespace_bindings: std.ArrayList(NamespaceBinding) = .empty,

    /// Initializes a cursor without consuming the input.
    pub fn init(
        allocator: std.mem.Allocator,
        input: *std.Io.Reader,
        max_depth: usize,
        max_attributes: usize,
        max_attribute_bytes: usize,
    ) Error!Cursor {
        if (max_depth == 0 or max_depth > MAX_XML_DEPTH or max_attributes == 0 or max_attribute_bytes == 0) {
            return error.InvalidOptions;
        }
        if (input.buffer.len == 0 and input.vtable != std.Io.Reader.ending.vtable) return error.InvalidOptions;
        return .{
            .allocator = allocator,
            .source = Source.init(input),
            .max_depth = max_depth,
            .max_attributes = max_attributes,
            .max_attribute_bytes = max_attribute_bytes,
        };
    }

    /// Releases retained parser scratch and borrowed-event storage.
    pub fn deinit(self: *Cursor) void {
        self.event_bytes.deinit(self.allocator);
        self.text_bytes.deinit(self.allocator);
        self.declaration_bytes.deinit(self.allocator);
        self.attribute_ranges.deinit(self.allocator);
        self.namespace_declarations.deinit(self.allocator);
        self.attributes.deinit(self.allocator);
        self.open_names.deinit(self.allocator);
        self.namespace_bytes.deinit(self.allocator);
        self.namespace_bindings.deinit(self.allocator);
    }

    /// Reuses the cursor with a new input stream and clears parser state.
    pub fn reset(self: *Cursor, input: *std.Io.Reader) Error!void {
        self.source.reset(input);
        self.resetState(false);
    }

    /// Clears the input reference and parser state after fragment use.
    pub fn resetEmpty(self: *Cursor) void {
        self.source.resetEmpty();
        self.resetState(false);
    }

    pub fn detachFragment(self: *Cursor) void {
        self.source.resetEmpty();
        self.resetState(true);
    }

    pub fn ancestors(self: *const Cursor) Ancestors {
        return .{
            .depth = self.depth,
            .names = self.open_names.items.len,
            .namespace_bytes = self.namespace_bytes.items.len,
            .bindings = self.namespace_bindings.items.len,
            .encoding = self.source.encoding,
            .version = self.effective_version,
            .pending_empty = self.pending_empty,
        };
    }

    /// Restores ancestor storage left intact by a successful fragment read.
    /// A failed read or a different prefix requires parsing those ancestors again.
    pub fn resetToAncestors(self: *Cursor, input: *std.Io.Reader, saved: Ancestors, prefix_length: usize) Error!void {
        self.source.reset(input);
        self.resetState(true);
        self.source.detected = true;
        self.source.encoding = saved.encoding;
        self.source.position = prefix_length;
        self.offset = prefix_length;
        self.document_started = true;
        self.root_seen = true;
        self.depth = saved.depth;
        self.open_names.items = self.open_names.allocatedSlice()[0..saved.names];
        self.namespace_bytes.items = self.namespace_bytes.allocatedSlice()[0..saved.namespace_bytes];
        self.namespace_bindings.items = self.namespace_bindings.allocatedSlice()[0..saved.bindings];
        self.effective_version = saved.version;
        self.pending_empty = saved.pending_empty;
    }

    fn resetState(self: *Cursor, keep_ancestors: bool) void {
        self.current = null;
        self.offset = 0;
        self.document_started = false;
        self.document_ended = false;
        self.root_seen = false;
        self.root_closed = false;
        self.depth = 0;
        self.in_cdata = false;
        self.cdata_brackets = 0;
        self.normal_text_brackets = 0;
        self.effective_version = .xml10;
        self.pending_empty = false;
        self.event_bytes.clearRetainingCapacity();
        self.text_bytes.clearRetainingCapacity();
        self.declaration_bytes.clearRetainingCapacity();
        self.attribute_ranges.clearRetainingCapacity();
        self.namespace_declarations.clearRetainingCapacity();
        self.attributes.clearRetainingCapacity();
        // Successful fragments leave their ancestor prefixes initialized for reuse.
        if (!keep_ancestors) {
            self.open_names.clearRetainingCapacity();
            self.namespace_bytes.clearRetainingCapacity();
            self.namespace_bindings.clearRetainingCapacity();
        }
    }

    /// Advances to the next significant event, optionally returning text.
    pub fn advance(self: *Cursor, text: bool) Error!void {
        self.current = null;
        while (true) {
            const maybe_event = self.nextEvent(!text) catch |err| {
                self.offset = self.source.currentOffset();
                return switch (err) {
                    error.EndOfStream, error.NoText => error.InvalidXml,
                    else => err,
                };
            };
            const event = maybe_event orelse {
                self.offset = self.source.currentOffset();
                return error.UnexpectedEnd;
            };
            self.offset = event.span.start;
            switch (event.data) {
                .document_start => |document| {
                    if (document.version != .xml10) return error.UnsupportedVersion;
                },
                .start_element => |start| {
                    if (!optionalSliceEql(start.name.expanded.namespace_uri, NAMESPACE)) return error.WrongNamespace;
                    self.current = event;
                    return;
                },
                .end_element => {
                    self.current = event;
                    return;
                },
                .text => |value| {
                    if (text) {
                        self.current = event;
                        return;
                    }
                    for (value.bytes) |byte| if (!isXmlWhitespace(byte)) return error.InvalidXml;
                },
                .document_end => {
                    self.current = null;
                    return;
                },
            }
        }
    }

    /// Checks and skips the current start-element subtree.
    pub fn skip(self: *Cursor) Error!void {
        const start = self.current orelse return error.InvalidState;
        switch (start.data) {
            .start_element => {},
            else => return error.InvalidState,
        }
        var nested: usize = 1;
        while (nested != 0) {
            const event = (self.nextEvent(false) catch |err| return switch (err) {
                error.EndOfStream, error.NoText => error.UnexpectedEnd,
                else => err,
            }) orelse return error.UnexpectedEnd;
            switch (event.data) {
                .start_element => nested += 1,
                .end_element => nested -= 1,
                else => {},
            }
        }
        try self.advance(false);
    }

    fn beginEvent(self: *Cursor) ParserError!void {
        try self.source.commitBorrowed();
        self.event_bytes.clearRetainingCapacity();
        self.text_bytes.clearRetainingCapacity();
        self.declaration_bytes.clearRetainingCapacity();
        self.attribute_ranges.clearRetainingCapacity();
        self.namespace_declarations.clearRetainingCapacity();
        self.attributes.clearRetainingCapacity();
    }

    fn skipBufferedWhitespace(self: *Cursor) void {
        if ((self.source.encoding != .utf8 and self.source.encoding != .latin1) or self.source.probe_pos != self.source.probe_len or
            self.source.pending_len != 0) return;
        const reader = self.source.reader orelse return;
        const bytes = reader.buffered();
        const bound = @min(bytes.len, TEXT_CHUNK_BYTES);
        var length: usize = 0;
        while (length < bound and isXmlWhitespace(bytes[length])) : (length += 1) {}
        // A complete run preserves the original text event's failure order.
        if (length == 0 or length == bound or bytes[length] != '<') return;
        const end = std.math.add(u64, self.source.position, length) catch return;
        reader.toss(length);
        self.source.position = end;
        self.normal_text_brackets = 0;
    }

    fn nextEvent(self: *Cursor, ignore_whitespace: bool) ParserError!?Event {
        try self.beginEvent();
        if (self.document_ended) return null;
        if (!self.document_started) {
            try self.prepareDocument();
            self.document_started = true;
            return .{
                .span = .{ .start = 0, .end = self.source.currentOffset() },
                .data = .{ .document_start = .{ .version = self.effective_version } },
            };
        }

        if (self.pending_empty) return try self.syntheticEnd();

        while (true) {
            if (self.in_cdata) {
                return self.readTextEvent() catch |err| switch (err) {
                    error.NoText => continue,
                    else => err,
                };
            }
            if (ignore_whitespace) self.skipBufferedWhitespace();
            const first = self.source.peekCodepoint() catch |err| switch (err) {
                error.EndOfStream => {
                    if (self.root_seen and self.root_closed and self.depth == 0) {
                        self.document_ended = true;
                        return .{
                            .span = .{ .start = self.source.position, .end = self.source.position },
                            .data = .document_end,
                        };
                    }
                    return error.InvalidXml;
                },
                else => return err,
            };
            if (first.value != '<') {
                return self.readTextEvent() catch |err| switch (err) {
                    error.NoText => continue,
                    else => err,
                };
            }
            self.normal_text_brackets = 0;

            const opening = try self.requiredCodepoint();
            if (try self.readBufferedStartElement(opening.start)) |event| return event;
            const marker = self.requiredCodepoint() catch |err| return err;
            switch (marker.value) {
                '/' => return try self.readEndElement(opening.start),
                '?' => {
                    try self.readProcessingInstruction(false);
                    continue;
                },
                '!' => {
                    const declaration_marker = self.requiredCodepoint() catch |err| return err;
                    if (declaration_marker.value == '-') {
                        const second_dash = self.requiredCodepoint() catch |err| return err;
                        if (second_dash.value != '-') return error.InvalidXml;
                        try self.readComment();
                        continue;
                    }
                    if (declaration_marker.value == '[') {
                        try self.readCdataStart();
                        continue;
                    }
                    return error.DtdForbidden;
                },
                else => {
                    try self.source.unread(marker);
                    return try self.readStartElement(opening.start);
                },
            }
        }
    }

    fn prepareDocument(self: *Cursor) ParserError!void {
        const first = self.source.peekCodepoint() catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (first.value != '<') return;

        const opening = self.requiredCodepoint() catch |err| return err;
        const marker = self.source.peekCodepoint() catch |err| switch (err) {
            error.EndOfStream => {
                try self.source.unread(opening);
                return;
            },
            else => return err,
        };
        if (marker.value != '?') {
            try self.source.unread(opening);
            return;
        }
        _ = try self.requiredCodepoint();
        try self.readProcessingInstruction(true);
    }

    fn requiredCodepoint(self: *Cursor) Error!Codepoint {
        return self.source.readCodepoint() catch |err| switch (err) {
            error.EndOfStream, error.NoText => error.InvalidXml,
            else => err,
        };
    }

    fn peekRequired(self: *Cursor) Error!Codepoint {
        return self.source.peekCodepoint() catch |err| switch (err) {
            error.EndOfStream, error.NoText => error.InvalidXml,
            else => err,
        };
    }

    fn appendEventByte(self: *Cursor, value: u8) Error!void {
        if (self.event_bytes.items.len >= self.max_attribute_bytes) return error.LimitExceeded;
        try self.event_bytes.append(self.allocator, value);
    }

    fn appendEventSlice(self: *Cursor, value: []const u8) Error!void {
        const next_length = std.math.add(usize, self.event_bytes.items.len, value.len) catch return error.LimitExceeded;
        if (next_length > self.max_attribute_bytes) return error.LimitExceeded;
        try self.event_bytes.appendSlice(self.allocator, value);
    }

    fn appendCodepoint(self: *Cursor, value: u21) Error!void {
        if (!isXmlChar(value)) return error.InvalidXml;
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(value, &encoded) catch return error.InvalidXml;
        try self.appendEventSlice(encoded[0..len]);
    }

    fn appendTextCodepoint(self: *Cursor, value: u21, normalize_cr: bool) Error!void {
        if (!isXmlChar(value)) return error.InvalidXml;
        const actual = if (normalize_cr and value == '\r') '\n' else value;
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(actual, &encoded) catch return error.InvalidXml;
        const next_length = std.math.add(usize, self.text_bytes.items.len, len) catch return error.LimitExceeded;
        if (next_length > TEXT_CHUNK_BYTES) return error.LimitExceeded;
        try self.text_bytes.appendSlice(self.allocator, encoded[0..len]);
    }

    fn skipWhitespace(self: *Cursor) Error!void {
        while (true) {
            if (try self.source.peekSingleByte()) |bytes| {
                var length: usize = 0;
                while (length < bytes.len and isXmlWhitespace(bytes[length])) : (length += 1) {}
                if (length != 0) {
                    self.source.borrowed_len = length;
                    try self.source.commitBorrowed();
                }
                if (length < bytes.len) return;
                continue;
            }
            const value = self.peekRequired() catch |err| return switch (err) {
                error.InvalidXml => {},
                else => err,
            };
            if (!isXmlWhitespace(value.value)) return;
            _ = try self.requiredCodepoint();
        }
    }

    fn parseQName(self: *Cursor) Error!NameRange {
        const start = self.event_bytes.items.len;
        var have_character = false;
        var prefix_len: usize = 0;
        var segment_start = true;
        while (true) {
            if (have_character and !segment_start) {
                if (try self.source.peekSingleByte()) |bytes| {
                    const bound = @min(bytes.len, self.max_attribute_bytes -| self.event_bytes.items.len);
                    var length: usize = 0;
                    while (length < bound and isAsciiNameChar(bytes[length])) : (length += 1) {}
                    const finished = length < bytes.len and isNameDelimiter(bytes[length]);
                    if (length != 0) {
                        try self.appendEventSlice(bytes[0..length]);
                        self.source.borrowed_len = length;
                        try self.source.commitBorrowed();
                    }
                    if (finished) break;
                    if (length != 0) continue;
                }
            }
            const value = self.requiredCodepoint() catch |err| return err;
            if (value.value > 0x7F) return error.InvalidXml;
            const byte: u8 = @intCast(value.value);
            if (!have_character) {
                if (!isAsciiNameStart(byte)) return error.InvalidXml;
                have_character = true;
                segment_start = false;
                try self.appendEventByte(byte);
                continue;
            }
            if (byte == ':') {
                if (prefix_len != 0 or segment_start) return error.InvalidXml;
                prefix_len = self.event_bytes.items.len - start;
                segment_start = true;
                try self.appendEventByte(byte);
                continue;
            }
            if (segment_start) {
                if (!isAsciiNameStart(byte)) return error.InvalidXml;
                segment_start = false;
                try self.appendEventByte(byte);
                continue;
            }
            if (isAsciiNameChar(byte)) {
                try self.appendEventByte(byte);
                continue;
            }
            if (isNameDelimiter(value.value)) {
                try self.source.unread(value);
                break;
            }
            return error.InvalidXml;
        }
        return .{ .start = start, .len = self.event_bytes.items.len - start, .prefix_len = prefix_len };
    }

    fn parseAttributeValue(self: *Cursor, quote: u21) Error!Range {
        const start = self.event_bytes.items.len;
        while (true) {
            if (try self.source.peekSingleByte()) |bytes| {
                const bound = @min(bytes.len, self.max_attribute_bytes -| self.event_bytes.items.len);
                var length: usize = 0;
                while (length < bound) : (length += 1) {
                    const byte = bytes[length];
                    if (byte < 0x20 or byte >= 0x80 or byte == quote or byte == '&' or byte == '<') break;
                }
                if (length != 0) {
                    try self.appendEventSlice(bytes[0..length]);
                    self.source.borrowed_len = length;
                    try self.source.commitBorrowed();
                    continue;
                }
            }
            const value = self.requiredCodepoint() catch |err| return err;
            if (value.value == quote) break;
            if (value.value == '<') return error.InvalidXml;
            if (value.value == '&') {
                try self.readEntity(&self.event_bytes, self.max_attribute_bytes);
                continue;
            }
            if (value.value == '\r' or value.value == '\n' or value.value == '\t') {
                if (value.value == '\r') {
                    const next = self.source.peekCodepoint() catch |err| switch (err) {
                        error.EndOfStream => null,
                        else => return err,
                    };
                    if (next) |following| {
                        if (following.value == '\n') _ = try self.requiredCodepoint();
                    }
                }
                try self.appendEventByte(' ');
            } else {
                try self.appendCodepoint(value.value);
            }
        }
        return .{ .start = start, .len = self.event_bytes.items.len - start };
    }

    fn readEntity(self: *Cursor, destination: *std.ArrayList(u8), limit: usize) Error!void {
        var name: [32]u8 = undefined;
        var length: usize = 0;
        while (true) {
            const value = self.requiredCodepoint() catch |err| return err;
            if (value.value == ';') break;
            if (value.value > 0x7F or length == name.len) return error.InvalidXml;
            name[length] = @intCast(value.value);
            length += 1;
        }
        if (length == 0) return error.InvalidXml;
        if (std.mem.eql(u8, name[0..length], "amp")) return appendTo(destination, self.allocator, '&', limit);
        if (std.mem.eql(u8, name[0..length], "lt")) return appendTo(destination, self.allocator, '<', limit);
        if (std.mem.eql(u8, name[0..length], "gt")) return appendTo(destination, self.allocator, '>', limit);
        if (std.mem.eql(u8, name[0..length], "apos")) return appendTo(destination, self.allocator, '\'', limit);
        if (std.mem.eql(u8, name[0..length], "quot")) return appendTo(destination, self.allocator, '"', limit);

        if (name[0] != '#') return error.InvalidXml;
        var base: u32 = 10;
        var index: usize = 1;
        if (index < length and (name[index] == 'x' or name[index] == 'X')) {
            base = 16;
            index += 1;
        }
        if (index == length) return error.InvalidXml;
        var number: u32 = 0;
        while (index < length) : (index += 1) {
            const digit = digitValue(name[index], base) orelse return error.InvalidXml;
            number = std.math.mul(u32, number, base) catch return error.InvalidXml;
            number = std.math.add(u32, number, digit) catch return error.InvalidXml;
        }
        if (number > 0x10FFFF or !isXmlChar(@intCast(number))) return error.InvalidXml;
        return appendToCodepoint(destination, self.allocator, @intCast(number), limit);
    }

    fn bufferedName(self: *Cursor, bytes: []const u8, position: *usize, used: *usize) ?NameRange {
        const start = position.*;
        if (start == bytes.len or !isAsciiNameStart(bytes[start])) return null;
        var end = start + 1;
        while (end < bytes.len and isAsciiNameChar(bytes[end])) : (end += 1) {}
        if (end == bytes.len or !isNameDelimiter(bytes[end])) return null;
        const length = end - start;
        const capacity = @min(self.max_attribute_bytes, self.event_bytes.capacity);
        if (length > capacity -| used.*) return null;
        const result: NameRange = .{ .start = start, .len = length, .prefix_len = 0 };
        used.* += length;
        position.* = end;
        return result;
    }

    fn hasAttribute(self: *const Cursor, bytes: []const u8, name: NameRange) bool {
        const raw = bytes[name.start..][0..name.len];
        for (self.attribute_ranges.items) |previous| {
            if (std.mem.eql(u8, bytes[previous.name.start..][0..previous.name.len], raw)) return true;
        }
        return false;
    }

    fn readBufferedStartElement(self: *Cursor, start_offset: u64) Error!?Event {
        if ((self.source.encoding != .utf8 and self.source.encoding != .latin1) or self.source.probe_pos != self.source.probe_len or
            self.source.pending_len != 0) return null;
        const reader = self.source.reader orelse return null;
        const bytes = reader.buffered();
        if (bytes.len == 0 or !isAsciiNameStart(bytes[0])) return null;
        self.event_bytes.clearRetainingCapacity();
        self.attribute_ranges.clearRetainingCapacity();
        self.namespace_declarations.clearRetainingCapacity();
        self.attributes.clearRetainingCapacity();
        var position: usize = 0;
        var used: usize = 0;
        const name_range = self.bufferedName(bytes, &position, &used) orelse return null;
        var empty = false;

        // Do not consume input or grow storage until the complete tag is known.
        // The incremental parser preserves failure order on every declined tag.
        while (true) {
            while (position < bytes.len and isXmlWhitespace(bytes[position])) : (position += 1) {}
            if (position == bytes.len) return null;
            if (bytes[position] == '>') {
                position += 1;
                break;
            }
            if (bytes[position] == '/') {
                if (bytes.len - position < 2 or bytes[position + 1] != '>') return null;
                position += 2;
                empty = true;
                break;
            }
            if (self.attribute_ranges.items.len == @min(self.max_attributes, self.attribute_ranges.capacity)) return null;
            const name = self.bufferedName(bytes, &position, &used) orelse return null;
            if (std.mem.eql(u8, bytes[name.start..][0..name.len], "xmlns")) return null;
            while (position < bytes.len and isXmlWhitespace(bytes[position])) : (position += 1) {}
            if (position == bytes.len or bytes[position] != '=') return null;
            position += 1;
            while (position < bytes.len and isXmlWhitespace(bytes[position])) : (position += 1) {}
            if (position == bytes.len) return null;
            const quote = bytes[position];
            if (quote != '\'' and quote != '"') return null;
            position += 1;
            const start = position;
            position += ordinaryAttributeRun(bytes[position..], quote);
            if (position == bytes.len or bytes[position] != quote) return null;
            const length = position - start;
            const capacity = @min(self.max_attribute_bytes, self.event_bytes.capacity);
            if (length > capacity -| used) return null;
            const value: Range = .{ .start = start, .len = length };
            used += length;
            position += 1;
            if (self.hasAttribute(bytes, name)) return null;
            self.attribute_ranges.appendAssumeCapacity(.{
                .name = name,
                .value = value,
                .namespace_declaration = false,
            });
        }

        const end = std.math.add(u64, self.source.position, position) catch return null;
        reader.toss(position);
        self.source.position = end;
        return try self.finishStartElement(bytes, start_offset, name_range, empty);
    }

    fn readStartElement(self: *Cursor, start_offset: u64) Error!Event {
        self.event_bytes.clearRetainingCapacity();
        self.attribute_ranges.clearRetainingCapacity();
        self.namespace_declarations.clearRetainingCapacity();
        self.attributes.clearRetainingCapacity();
        const name_range = try self.parseQName();
        var empty = false;

        while (true) {
            try self.skipWhitespace();
            const marker = self.requiredCodepoint() catch |err| return err;
            if (marker.value == '>') break;
            if (marker.value == '/') {
                const close = try self.requiredCodepoint();
                if (close.value != '>') return error.InvalidXml;
                empty = true;
                break;
            }
            try self.source.unread(marker);

            if (self.attribute_ranges.items.len == self.max_attributes) return error.LimitExceeded;
            const attribute_name = try self.parseQName();
            const quote: u21 = opening: {
                if (try self.source.peekSingleByte()) |bytes| {
                    if (bytes.len >= 2 and bytes[0] == '=' and (bytes[1] == '\'' or bytes[1] == '"')) {
                        const value = bytes[1];
                        self.source.borrowed_len = 2;
                        try self.source.commitBorrowed();
                        break :opening value;
                    }
                }
                try self.skipWhitespace();
                const equals = try self.requiredCodepoint();
                if (equals.value != '=') return error.InvalidXml;
                try self.skipWhitespace();
                const value = try self.requiredCodepoint();
                if (value.value != '\'' and value.value != '"') return error.InvalidXml;
                break :opening value.value;
            };
            const attribute_value = try self.parseAttributeValue(quote);
            if (self.hasAttribute(self.event_bytes.items, attribute_name)) return error.InvalidXml;
            const raw_name = self.event_bytes.items[attribute_name.start..][0..attribute_name.len];
            const namespace_declaration = std.mem.eql(u8, raw_name, "xmlns") or
                (std.mem.startsWith(u8, raw_name, "xmlns:") and raw_name.len > 6);
            if (namespace_declaration) {
                const prefix = if (std.mem.eql(u8, raw_name, "xmlns"))
                    Range{ .start = attribute_name.start, .len = 0 }
                else
                    Range{ .start = attribute_name.start + 6, .len = attribute_name.len - 6 };
                try self.namespace_declarations.append(self.allocator, .{ .prefix = prefix, .uri = attribute_value });
            }
            try self.attribute_ranges.append(self.allocator, .{
                .name = attribute_name,
                .value = attribute_value,
                .namespace_declaration = namespace_declaration,
            });
        }

        return self.finishStartElement(self.event_bytes.items, start_offset, name_range, empty);
    }

    fn finishStartElement(self: *Cursor, bytes: []const u8, start_offset: u64, name_range: NameRange, empty: bool) Error!Event {
        if (self.depth == 0) {
            if (self.root_closed) return error.InvalidXml;
            self.root_seen = true;
        }
        if (self.depth == self.max_depth) return error.LimitExceeded;

        const binding_start = self.namespace_bindings.items.len;
        const namespace_bytes_start = self.namespace_bytes.items.len;
        try self.installNamespaces(binding_start);
        const element_name = try self.makeName(bytes, name_range);

        const frame_name_start = self.open_names.items.len;
        try self.open_names.appendSlice(self.allocator, bytes[name_range.start..][0..name_range.len]);
        self.frames[self.depth] = .{
            .name_start = frame_name_start,
            .name_len = name_range.len,
            .prefix_len = name_range.prefix_len,
            .binding_start = binding_start,
            .namespace_bytes_start = namespace_bytes_start,
            .opening_end = self.source.position,
        };
        self.depth += 1;
        self.pending_empty = empty;

        try self.attributes.ensureTotalCapacityPrecise(self.allocator, self.attribute_ranges.items.len);
        for (self.attribute_ranges.items) |attribute_range| {
            if (attribute_range.namespace_declaration) continue;
            const attribute_name = try self.makeAttributeName(bytes, attribute_range.name);
            const expanded = attribute_name.expanded;
            for (self.attributes.items) |previous| {
                if (previous.name.eql(expanded.namespace_uri, expanded.local)) return error.InvalidXml;
            }
            try self.attributes.append(self.allocator, .{
                .name = attribute_name,
                .value = bytes[attribute_range.value.start..][0..attribute_range.value.len],
            });
        }
        return .{
            .span = .{ .start = start_offset, .end = self.source.position },
            .data = .{ .start_element = .{
                .name = element_name,
                .attributes = self.attributes.items,
                .empty_element_syntax = empty,
            } },
        };
    }

    fn installNamespaces(self: *Cursor, binding_start: usize) Error!void {
        for (self.namespace_declarations.items) |declaration| {
            const prefix = self.event_bytes.items[declaration.prefix.start..][0..declaration.prefix.len];
            const uri = self.event_bytes.items[declaration.uri.start..][0..declaration.uri.len];
            for (self.namespace_bindings.items[binding_start..]) |previous| {
                const previous_prefix = self.namespace_bytes.items[previous.prefix_start..][0..previous.prefix_len];
                if (std.mem.eql(u8, previous_prefix, prefix)) return error.InvalidXml;
            }
            if (std.mem.eql(u8, prefix, "xmlns")) return error.InvalidXml;
            if (std.mem.eql(u8, prefix, "xml")) {
                if (!std.mem.eql(u8, uri, XML_NAMESPACE)) return error.InvalidXml;
            } else if (std.mem.eql(u8, uri, XML_NAMESPACE)) {
                return error.InvalidXml;
            }
            if (std.mem.eql(u8, uri, XMLNS_NAMESPACE)) return error.InvalidXml;
            if (prefix.len != 0 and uri.len == 0) return error.InvalidXml;
            const prefix_start = self.namespace_bytes.items.len;
            try self.namespace_bytes.appendSlice(self.allocator, prefix);
            const uri_start = self.namespace_bytes.items.len;
            try self.namespace_bytes.appendSlice(self.allocator, uri);
            try self.namespace_bindings.append(self.allocator, .{
                .prefix_start = prefix_start,
                .prefix_len = prefix.len,
                .uri_start = uri_start,
                .uri_len = uri.len,
            });
        }
    }

    fn resolveNamespace(self: *const Cursor, prefix: ?[]const u8) ?[]const u8 {
        if (prefix) |value| if (std.mem.eql(u8, value, "xml")) return XML_NAMESPACE;
        const wanted = prefix orelse "";
        var index = self.namespace_bindings.items.len;
        while (index != 0) {
            index -= 1;
            const binding = self.namespace_bindings.items[index];
            const bound_prefix = self.namespace_bytes.items[binding.prefix_start..][0..binding.prefix_len];
            if (std.mem.eql(u8, bound_prefix, wanted)) {
                return self.namespace_bytes.items[binding.uri_start..][0..binding.uri_len];
            }
        }
        return null;
    }

    fn makeName(self: *const Cursor, bytes: []const u8, range: NameRange) Error!Name {
        const raw = bytes[range.start..][0..range.len];
        const prefix = if (range.prefix_len == 0) null else raw[0..range.prefix_len];
        const local = if (range.prefix_len == 0) raw else raw[range.prefix_len + 1 ..];
        const namespace_uri = self.resolveNamespace(prefix);
        if (prefix != null and namespace_uri == null) return error.InvalidXml;
        return .{ .raw = raw, .expanded = .{
            .prefix = prefix,
            .local = local,
            .namespace_uri = namespace_uri,
        } };
    }

    fn makeAttributeName(self: *const Cursor, bytes: []const u8, range: NameRange) Error!Name {
        const raw = bytes[range.start..][0..range.len];
        const prefix = if (range.prefix_len == 0) null else raw[0..range.prefix_len];
        const local = if (range.prefix_len == 0) raw else raw[range.prefix_len + 1 ..];
        const namespace_uri = if (prefix) |value| self.resolveNamespace(value) else null;
        if (prefix != null and namespace_uri == null) return error.InvalidXml;
        return .{ .raw = raw, .expanded = .{
            .prefix = prefix,
            .local = local,
            .namespace_uri = namespace_uri,
        } };
    }

    fn readEndElement(self: *Cursor, start_offset: u64) Error!Event {
        if (self.depth == 0) return error.InvalidXml;
        const name_range = try self.parseQName();
        try self.skipWhitespace();
        const close = try self.requiredCodepoint();
        if (close.value != '>') return error.InvalidXml;
        const frame = self.frames[self.depth - 1];
        const raw = self.event_bytes.items[name_range.start..][0..name_range.len];
        const expected = self.open_names.items[frame.name_start..][0..frame.name_len];
        if (!std.mem.eql(u8, raw, expected)) return error.InvalidXml;
        const name = try self.makeName(self.event_bytes.items, name_range);
        self.depth -= 1;
        self.open_names.items.len = frame.name_start;
        self.namespace_bindings.items.len = frame.binding_start;
        self.namespace_bytes.items.len = frame.namespace_bytes_start;
        if (self.depth == 0) self.root_closed = true;
        return .{
            .span = .{ .start = start_offset, .end = self.source.position },
            .data = .{ .end_element = .{ .name = name } },
        };
    }

    fn syntheticEnd(self: *Cursor) Error!Event {
        if (!self.pending_empty or self.depth == 0) return error.InvalidState;
        const frame = self.frames[self.depth - 1];
        self.event_bytes.clearRetainingCapacity();
        try self.event_bytes.appendSlice(self.allocator, self.open_names.items[frame.name_start..][0..frame.name_len]);
        const name = try self.makeName(self.event_bytes.items, .{ .start = 0, .len = self.event_bytes.items.len, .prefix_len = frame.prefix_len });
        self.pending_empty = false;
        self.depth -= 1;
        self.open_names.items.len = frame.name_start;
        self.namespace_bindings.items.len = frame.binding_start;
        self.namespace_bytes.items.len = frame.namespace_bytes_start;
        if (self.depth == 0) self.root_closed = true;
        return .{
            .span = .{ .start = frame.opening_end, .end = frame.opening_end },
            .data = .{ .end_element = .{ .name = name } },
        };
    }

    fn readTextEvent(self: *Cursor) ParserError!Event {
        if (self.in_cdata) return self.readCdataText();
        return self.readScalarText();
    }

    fn readScalarText(self: *Cursor) ParserError!Event {
        const start = self.source.currentOffset();
        while (self.text_bytes.items.len < TEXT_CHUNK_BYTES) {
            if (self.normal_text_brackets == 0) {
                if (try self.source.peekSingleByte()) |bytes| {
                    const length = ordinaryTextRun(bytes, TEXT_CHUNK_BYTES - self.text_bytes.items.len);
                    if (length != 0) {
                        // Keep logical text chunks unchanged across input refills.
                        try self.text_bytes.appendSlice(self.allocator, bytes[0..length]);
                        self.source.borrowed_len = length;
                        try self.source.commitBorrowed();
                        continue;
                    }
                }
            }
            const value = self.source.peekCodepoint() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (value.value == '<') break;
            if (value.value == '&') {
                if (self.text_bytes.items.len != 0) break;
                _ = try self.requiredCodepoint();
                try self.readEntity(&self.text_bytes, TEXT_CHUNK_BYTES);
                self.normal_text_brackets = 0;
                continue;
            }
            const encoded_len = std.unicode.utf8CodepointSequenceLength(value.value) catch return error.InvalidXml;
            if (value.value != '\r' and encoded_len > TEXT_CHUNK_BYTES - self.text_bytes.items.len) break;
            _ = try self.requiredCodepoint();
            if (value.value == ']') {
                if (self.normal_text_brackets < 2) self.normal_text_brackets += 1;
                try self.appendTextCodepoint(value.value, false);
            } else if (value.value == '>' and self.normal_text_brackets == 2) {
                return error.InvalidXml;
            } else if (value.value == '\r') {
                self.normal_text_brackets = 0;
                const next = self.source.peekCodepoint() catch |err| switch (err) {
                    error.EndOfStream => null,
                    else => return err,
                };
                if (next) |following| {
                    if (following.value == '\n') _ = try self.requiredCodepoint();
                }
                try self.appendTextCodepoint('\n', false);
            } else {
                self.normal_text_brackets = 0;
                try self.appendTextCodepoint(value.value, false);
            }
        }
        if (self.text_bytes.items.len == 0) return error.NoText;
        return .{
            .span = .{ .start = start, .end = self.source.currentOffset() },
            .data = .{ .text = .{ .bytes = self.text_bytes.items } },
        };
    }

    fn readCdataStart(self: *Cursor) Error!void {
        if (self.depth == 0) return error.InvalidXml;
        for ("CDATA[") |expected| {
            const value = try self.requiredCodepoint();
            if (value.value != expected) return error.InvalidXml;
        }
        self.in_cdata = true;
        self.cdata_brackets = 0;
    }

    fn readCdataText(self: *Cursor) ParserError!Event {
        const start = self.source.currentOffset();
        while (self.text_bytes.items.len < TEXT_CHUNK_BYTES) {
            const value = self.source.peekCodepoint() catch |err| switch (err) {
                error.EndOfStream => return error.InvalidXml,
                else => return err,
            };
            const output_length = if (value.value == ']')
                if (self.cdata_brackets == 2) @as(usize, 1) else 0
            else if (value.value == '>' and self.cdata_brackets == 2)
                0
            else
                (if (value.value == '\r') 1 else std.unicode.utf8CodepointSequenceLength(value.value) catch return error.InvalidXml) +
                    @as(usize, self.cdata_brackets);
            if (output_length > TEXT_CHUNK_BYTES - self.text_bytes.items.len) break;
            _ = try self.source.readCodepoint();
            if (value.value == ']') {
                if (self.cdata_brackets < 2) {
                    self.cdata_brackets += 1;
                } else {
                    try self.appendTextCodepoint(']', false);
                }
                continue;
            }
            if (value.value == '>' and self.cdata_brackets == 2) {
                self.cdata_brackets = 0;
                self.in_cdata = false;
                if (self.text_bytes.items.len == 0) return error.NoText;
                break;
            }
            while (self.cdata_brackets != 0) : (self.cdata_brackets -= 1) {
                try self.appendTextCodepoint(']', false);
            }
            if (value.value == '\r') {
                const next = self.source.peekCodepoint() catch |err| switch (err) {
                    error.EndOfStream => null,
                    else => return err,
                };
                if (next) |following| {
                    if (following.value == '\n') _ = try self.requiredCodepoint();
                }
                try self.appendTextCodepoint('\n', false);
            } else {
                try self.appendTextCodepoint(value.value, false);
            }
        }
        if (self.text_bytes.items.len == 0) return error.NoText;
        return .{
            .span = .{ .start = start, .end = self.source.currentOffset() },
            .data = .{ .text = .{ .bytes = self.text_bytes.items } },
        };
    }

    fn readComment(self: *Cursor) Error!void {
        var dashes: u2 = 0;
        while (true) {
            const value = try self.requiredCodepoint();
            if (value.value == '-') {
                if (dashes == 1) {
                    const close = try self.requiredCodepoint();
                    if (close.value != '>') return error.InvalidXml;
                    return;
                }
                dashes = 1;
            } else {
                dashes = 0;
                if (!isXmlChar(value.value)) return error.InvalidXml;
            }
        }
    }

    fn readProcessingInstruction(self: *Cursor, initial: bool) Error!void {
        self.event_bytes.clearRetainingCapacity();
        const target = try self.parseQName();
        const target_bytes = self.event_bytes.items[target.start..][0..target.len];
        const separator = try self.requiredCodepoint();
        if (!isXmlWhitespace(separator.value) and separator.value != '?') return error.InvalidXml;
        const declaration = initial and std.mem.eql(u8, target_bytes, "xml");
        if (std.ascii.eqlIgnoreCase(target_bytes, "xml") and !declaration) return error.InvalidXml;
        self.declaration_bytes.clearRetainingCapacity();
        if (separator.value == '?') {
            const close = try self.requiredCodepoint();
            if (close.value != '>') return error.InvalidXml;
        } else {
            while (true) {
                const value = try self.requiredCodepoint();
                if (value.value == '?') {
                    const following = try self.requiredCodepoint();
                    if (following.value == '>') break;
                    if (declaration) try self.appendDeclarationByte('?');
                    try self.source.unread(following);
                    continue;
                }
                if (!isXmlChar(value.value)) return error.InvalidXml;
                if (declaration) {
                    if (value.value > 0x7F) return error.InvalidXml;
                    try self.appendDeclarationByte(@intCast(value.value));
                }
            }
        }
        if (declaration) try self.parseXmlDeclaration();
    }

    fn appendDeclarationByte(self: *Cursor, value: u8) Error!void {
        if (self.declaration_bytes.items.len == 4096) return error.LimitExceeded;
        try self.declaration_bytes.append(self.allocator, value);
    }

    fn parseXmlDeclaration(self: *Cursor) Error!void {
        var position: usize = 0;
        var version: ?[]const u8 = null;
        var encoding: ?[]const u8 = null;
        var order: u2 = 0;
        while (position < self.declaration_bytes.items.len and isXmlWhitespace(self.declaration_bytes.items[position])) position += 1;
        while (true) {
            if (position == self.declaration_bytes.items.len) break;
            const name_start = position;
            if (!isAsciiNameStart(self.declaration_bytes.items[position])) return error.InvalidXml;
            position += 1;
            while (position < self.declaration_bytes.items.len and isAsciiNameChar(self.declaration_bytes.items[position])) position += 1;
            const name = self.declaration_bytes.items[name_start..position];
            while (position < self.declaration_bytes.items.len and isXmlWhitespace(self.declaration_bytes.items[position])) position += 1;
            if (position == self.declaration_bytes.items.len or self.declaration_bytes.items[position] != '=') return error.InvalidXml;
            position += 1;
            while (position < self.declaration_bytes.items.len and isXmlWhitespace(self.declaration_bytes.items[position])) position += 1;
            if (position == self.declaration_bytes.items.len) return error.InvalidXml;
            const quote = self.declaration_bytes.items[position];
            if (quote != '\'' and quote != '"') return error.InvalidXml;
            position += 1;
            const value_start = position;
            while (position < self.declaration_bytes.items.len and self.declaration_bytes.items[position] != quote) position += 1;
            if (position == self.declaration_bytes.items.len) return error.InvalidXml;
            const value = self.declaration_bytes.items[value_start..position];
            position += 1;
            if (std.mem.eql(u8, name, "version")) {
                if (version != null or order != 0) return error.InvalidXml;
                version = value;
            } else if (std.mem.eql(u8, name, "encoding")) {
                if (version == null or encoding != null or order > 0) return error.InvalidXml;
                encoding = value;
                order = 1;
            } else if (std.mem.eql(u8, name, "standalone")) {
                if (version == null or order > 1) return error.InvalidXml;
                if (!std.mem.eql(u8, value, "yes") and !std.mem.eql(u8, value, "no")) return error.InvalidXml;
                order = 2;
            } else {
                return error.InvalidXml;
            }
            if (position == self.declaration_bytes.items.len) break;
            if (!isXmlWhitespace(self.declaration_bytes.items[position])) return error.InvalidXml;
            while (position < self.declaration_bytes.items.len and isXmlWhitespace(self.declaration_bytes.items[position])) position += 1;
        }
        const version_value = version orelse return error.InvalidXml;
        if (std.mem.eql(u8, version_value, "1.0")) {
            self.effective_version = .xml10;
        } else if (std.mem.eql(u8, version_value, "1.1")) {
            self.effective_version = .xml11;
        } else {
            return error.UnsupportedVersion;
        }
        if (encoding) |value| {
            if (std.ascii.eqlIgnoreCase(value, "UTF-8")) {
                if (self.source.encoding != .utf8) return error.InvalidEncoding;
            } else if (std.ascii.eqlIgnoreCase(value, "UTF-16")) {
                if (self.source.encoding != .utf16_le and self.source.encoding != .utf16_be) return error.InvalidEncoding;
            } else if (std.ascii.eqlIgnoreCase(value, "ISO-8859-1")) {
                if (self.source.encoding != .utf8 or
                    std.mem.startsWith(u8, self.source.probe[0..self.source.probe_len], "\xef\xbb\xbf")) return error.InvalidEncoding;
                self.source.encoding = .latin1;
            } else {
                return error.UnsupportedEncoding;
            }
        }
    }
};

fn digitValue(value: u8, base: u32) ?u32 {
    const digit: u32 = if (value >= '0' and value <= '9') value - '0' else if (value >= 'a' and value <= 'f') value - 'a' + 10 else if (value >= 'A' and value <= 'F') value - 'A' + 10 else return null;
    if (digit >= base) return null;
    return digit;
}

fn appendTo(destination: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u8, limit: usize) Error!void {
    if (destination.items.len >= limit) return error.LimitExceeded;
    try destination.append(allocator, value);
}

fn appendToCodepoint(destination: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u21, limit: usize) Error!void {
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(value, &encoded) catch return error.InvalidXml;
    const next_length = std.math.add(usize, destination.items.len, len) catch return error.LimitExceeded;
    if (next_length > limit) return error.LimitExceeded;
    try destination.appendSlice(allocator, encoded[0..len]);
}

/// Writer construction failures caused by invalid options.
pub const WriterInitError = error{InvalidOptions};
/// Writer state, namespace, character, sink, and bound failures.
pub const WriterError = error{
    InvalidState,
    InvalidName,
    InvalidCharacter,
    InvalidNamespace,
    DuplicateAttribute,
    WriterLimit,
    WriteFailed,
    OutOfMemory,
};

const WriterState = enum {
    initial,
    start_tag,
    content,
    epilog,
    done,
    failed,
};

const WriterFrame = struct {
    name_start: usize,
    name_len: usize,
    attribute_start: usize,
    namespace_start: usize,
};

/// Direct buffered XML writer for the mzML namespace and XML Schema location.
pub const Writer = struct {
    allocator: std.mem.Allocator,
    sink: *std.Io.Writer,
    state: WriterState = .initial,
    failure: ?WriterError = null,
    logical_offset: u64 = 0,
    offset_valid: bool = true,
    root_written: bool = false,
    frames: [MAX_XML_DEPTH]WriterFrame = undefined,
    frame_count: usize = 0,
    open_names: std.ArrayList(u8) = .empty,
    attribute_names: std.ArrayList(u8) = .empty,
    namespace_names: std.ArrayList(u8) = .empty,
    text_brackets: u2 = 0,

    /// Initializes a writer over a caller-owned sink.
    pub fn init(allocator: std.mem.Allocator, sink: *std.Io.Writer, options: struct {}) WriterInitError!Writer {
        _ = options;
        return .{ .allocator = allocator, .sink = sink };
    }

    /// Releases retained name and namespace scratch.
    pub fn deinit(self: *Writer) void {
        self.open_names.deinit(self.allocator);
        self.attribute_names.deinit(self.allocator);
        self.namespace_names.deinit(self.allocator);
    }

    /// Returns the physical bytes accepted by the sink, or null after a write failure.
    pub fn byteOffset(self: *const Writer) ?u64 {
        if (!self.offset_valid) return null;
        return self.logical_offset;
    }

    /// Writes the canonical UTF-8 XML declaration.
    pub fn startDocument(self: *Writer) WriterError!void {
        try self.check(.initial);
        try self.writeBytes("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        self.state = .epilog;
    }

    /// Opens an unprefixed mzML element.
    pub fn startElement(self: *Writer, name: []const u8) WriterError!void {
        try self.checkAny();
        if (self.state == .epilog and self.root_written) return self.fail(error.InvalidState);
        if (self.state != .epilog and self.state != .content and self.state != .start_tag) return self.fail(error.InvalidState);
        validateQName(name) catch |err| return self.fail(err);
        if (std.mem.indexOfScalar(u8, name, ':') != null) return self.fail(error.InvalidNamespace);
        if (self.frame_count == MAX_XML_DEPTH) return self.fail(error.WriterLimit);
        if (self.state == .start_tag) try self.writeByte('>');
        const name_start = self.open_names.items.len;
        self.open_names.appendSlice(self.allocator, name) catch return self.fail(error.OutOfMemory);
        self.frames[self.frame_count] = .{
            .name_start = name_start,
            .name_len = name.len,
            .attribute_start = self.attribute_names.items.len,
            .namespace_start = self.namespace_names.items.len,
        };
        self.frame_count += 1;
        if (self.frame_count == 1) self.root_written = true;
        self.state = .start_tag;
        try self.writeByte('<');
        try self.writeBytes(name);
    }

    /// Writes one supported default or `xsi` namespace declaration.
    pub fn namespace(self: *Writer, prefix: ?[]const u8, uri: []const u8) WriterError!void {
        try self.check(.start_tag);
        if (prefix) |value| {
            if (!std.mem.eql(u8, value, "xsi") or !std.mem.eql(u8, uri, XSI)) return self.fail(error.InvalidNamespace);
        } else if (!std.mem.eql(u8, uri, NAMESPACE)) {
            return self.fail(error.InvalidNamespace);
        }
        const frame = &self.frames[self.frame_count - 1];
        const actual_prefix = prefix orelse "";
        var position = frame.namespace_start;
        while (position < self.namespace_names.items.len) {
            const end = std.mem.indexOfScalarPos(u8, self.namespace_names.items, position, 0) orelse self.namespace_names.items.len;
            if (std.mem.eql(u8, self.namespace_names.items[position..end], actual_prefix)) return self.fail(error.DuplicateAttribute);
            position = if (end == self.namespace_names.items.len) end else end + 1;
        }
        self.namespace_names.appendSlice(self.allocator, actual_prefix) catch return self.fail(error.OutOfMemory);
        self.namespace_names.append(self.allocator, 0) catch return self.fail(error.OutOfMemory);
        try self.writeByte(' ');
        try self.writeBytes(if (prefix == null) "xmlns=\"" else "xmlns:");
        if (prefix) |value| {
            try self.writeBytes(value);
            try self.writeBytes("=\"");
        }
        try self.writeEscapedAttribute(uri);
        try self.writeByte('"');
    }

    /// Writes one ordinary or declared `xsi:schemaLocation` attribute.
    pub fn attribute(self: *Writer, name: []const u8, value: []const u8) WriterError!void {
        try self.check(.start_tag);
        validateQName(name) catch |err| return self.fail(err);
        if (std.mem.eql(u8, name, "xmlns") or std.mem.startsWith(u8, name, "xmlns:"))
            return self.fail(error.InvalidNamespace);
        if (std.mem.eql(u8, name, "xsi:schemaLocation") and !self.hasNamespace("xsi"))
            return self.fail(error.InvalidNamespace);
        if (std.mem.indexOfScalar(u8, name, ':') != null and !std.mem.eql(u8, name, "xsi:schemaLocation"))
            return self.fail(error.InvalidNamespace);
        const frame = &self.frames[self.frame_count - 1];
        var position = frame.attribute_start;
        while (position < self.attribute_names.items.len) {
            const length = std.mem.bytesToValue(usize, self.attribute_names.items[position..][0..@sizeOf(usize)]);
            position += @sizeOf(usize);
            const end = position + length;
            if (std.mem.eql(u8, self.attribute_names.items[position..end], name)) return self.fail(error.DuplicateAttribute);
            position = end;
        }
        self.attribute_names.appendSlice(self.allocator, std.mem.asBytes(&name.len)) catch return self.fail(error.OutOfMemory);
        self.attribute_names.appendSlice(self.allocator, name) catch return self.fail(error.OutOfMemory);
        try self.writeByte(' ');
        try self.writeBytes(name);
        try self.writeBytes("=\"");
        try self.writeEscapedAttribute(value);
        try self.writeByte('"');
    }

    /// Writes XML text with character and delimiter-safe escaping.
    pub fn text(self: *Writer, value: []const u8) WriterError!void {
        try self.checkAny();
        if (self.state != .start_tag and self.state != .content) return self.fail(error.InvalidState);
        if (self.state == .start_tag) {
            try self.writeByte('>');
            self.state = .content;
        }
        try self.writeEscapedText(value);
    }

    pub fn binary(self: *Writer, wire: []const u8) WriterError!void {
        try self.checkAny();
        if (self.state != .start_tag and self.state != .content) return self.fail(error.InvalidState);
        if (self.state == .start_tag) {
            try self.writeByte('>');
            self.state = .content;
        }
        var encoded: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < wire.len) {
            const available = self.sink.unusedCapacitySlice();
            const direct_length = @min(wire.len - offset, available.len / 4 * 3);
            if (direct_length != 0) {
                const required = base64.encodedSize(direct_length) catch return self.fail(error.WriterLimit);
                const next = std.math.add(u64, self.logical_offset, @intCast(required)) catch return self.fail(error.WriterLimit);
                const value = base64.encode(available, wire[offset..][0..direct_length]) catch return self.fail(error.WriterLimit);
                self.sink.advance(value.len);
                self.logical_offset = next;
                offset += direct_length;
                continue;
            }
            const length = @min(wire.len - offset, encoded.len / 4 * 3);
            // The encoder emits ASCII without XML metacharacters.
            const value = base64.encode(&encoded, wire[offset..][0..length]) catch return self.fail(error.WriterLimit);
            try self.writeBytes(value);
            offset += length;
        }
        if (wire.len != 0) self.text_brackets = 0;
    }

    /// Closes the current element.
    pub fn endElement(self: *Writer) WriterError!void {
        try self.checkAny();
        if (self.state != .start_tag and self.state != .content) return self.fail(error.InvalidState);
        if (self.frame_count == 0) return self.fail(error.InvalidState);
        const frame = self.frames[self.frame_count - 1];
        const name = self.open_names.items[frame.name_start..][0..frame.name_len];
        if (self.state == .start_tag) {
            try self.writeBytes("/>");
        } else {
            try self.writeBytes("</");
            try self.writeBytes(name);
            try self.writeByte('>');
        }
        self.frame_count -= 1;
        self.open_names.items.len = frame.name_start;
        self.attribute_names.items.len = frame.attribute_start;
        self.namespace_names.items.len = frame.namespace_start;
        self.text_brackets = 0;
        self.state = if (self.frame_count == 0) .epilog else .content;
    }

    /// Marks a complete document after the root element closes.
    pub fn endDocument(self: *Writer) WriterError!void {
        try self.check(.epilog);
        if (!self.root_written) return self.fail(error.InvalidState);
        self.state = .done;
    }

    fn check(self: *Writer, expected: WriterState) WriterError!void {
        try self.checkAny();
        if (self.state != expected) return self.fail(error.InvalidState);
    }

    fn checkAny(self: *Writer) WriterError!void {
        if (self.failure) |failure| return failure;
        if (self.state == .failed) return error.WriteFailed;
    }

    fn hasNamespace(self: *const Writer, prefix: []const u8) bool {
        var position: usize = 0;
        while (position < self.namespace_names.items.len) {
            const end = std.mem.indexOfScalarPos(u8, self.namespace_names.items, position, 0) orelse self.namespace_names.items.len;
            if (std.mem.eql(u8, self.namespace_names.items[position..end], prefix)) return true;
            position = if (end == self.namespace_names.items.len) end else end + 1;
        }
        return false;
    }

    fn fail(self: *Writer, failure: WriterError) WriterError {
        if (self.failure == null) self.failure = failure;
        self.state = .failed;
        if (failure == error.WriteFailed) self.offset_valid = false;
        return failure;
    }

    fn writeBytes(self: *Writer, bytes: []const u8) WriterError!void {
        const next = std.math.add(u64, self.logical_offset, @intCast(bytes.len)) catch return self.fail(error.WriterLimit);
        self.sink.writeAll(bytes) catch return self.fail(error.WriteFailed);
        self.logical_offset = next;
    }

    fn writeByte(self: *Writer, byte: u8) WriterError!void {
        var bytes = [1]u8{byte};
        try self.writeBytes(&bytes);
    }

    fn writeEscapedAttribute(self: *Writer, value: []const u8) WriterError!void {
        var plain_start: usize = 0;
        var index: usize = 0;
        while (index < value.len) {
            const start = index;
            const codepoint = decodeValue(value, &index) catch |err| return self.fail(err);
            if (!isXmlChar(codepoint)) return self.fail(error.InvalidCharacter);
            const replacement: []const u8 = switch (codepoint) {
                '&' => "&amp;",
                '<' => "&lt;",
                '"' => "&quot;",
                '\t' => "&#x9;",
                '\n' => "&#xA;",
                '\r' => "&#xD;",
                else => continue,
            };
            if (plain_start != start) try self.writeBytes(value[plain_start..start]);
            try self.writeBytes(replacement);
            plain_start = index;
        }
        if (plain_start != value.len) try self.writeBytes(value[plain_start..]);
    }

    fn writeEscapedText(self: *Writer, value: []const u8) WriterError!void {
        var plain_start: usize = 0;
        var index: usize = 0;
        var brackets = self.text_brackets;
        while (index < value.len) {
            if (brackets == 0) {
                const length = ordinaryTextRun(value[index..], value.len - index);
                if (length != 0) {
                    index += length;
                    continue;
                }
            }
            const start = index;
            const codepoint = decodeValue(value, &index) catch |err| return self.fail(err);
            if (!isXmlChar(codepoint)) return self.fail(error.InvalidCharacter);
            var replacement: ?[]const u8 = null;
            if (codepoint == '&') {
                replacement = "&amp;";
                brackets = 0;
            } else if (codepoint == '<') {
                replacement = "&lt;";
                brackets = 0;
            } else if (codepoint == '\r') {
                replacement = "&#xD;";
                brackets = 0;
            } else if (codepoint == ']') {
                if (brackets < 2) brackets += 1;
            } else {
                if (codepoint == '>' and brackets == 2) replacement = "&gt;";
                brackets = 0;
            }
            if (replacement) |escaped| {
                if (plain_start != start) try self.writeBytes(value[plain_start..start]);
                try self.writeBytes(escaped);
                plain_start = index;
            }
        }
        if (plain_start != value.len) try self.writeBytes(value[plain_start..]);
        self.text_brackets = brackets;
    }
};

fn validateQName(name: []const u8) WriterError!void {
    if (name.len == 0) return error.InvalidName;
    var colon_seen = false;
    var segment_start = true;
    for (name) |byte| {
        if (byte == ':') {
            if (colon_seen or segment_start) return error.InvalidName;
            colon_seen = true;
            segment_start = true;
            continue;
        }
        if (segment_start) {
            if (!isAsciiNameStart(byte)) return error.InvalidName;
            segment_start = false;
        } else if (!isAsciiNameChar(byte)) {
            return error.InvalidName;
        }
    }
    if (segment_start) return error.InvalidName;
}

fn decodeValue(value: []const u8, index: *usize) WriterError!u21 {
    const first = value[index.*];
    if (first < 0x80) {
        index.* += 1;
        return first;
    }
    const length: usize = std.unicode.utf8ByteSequenceLength(first) catch return error.InvalidCharacter;
    if (length > value.len - index.*) return error.InvalidCharacter;
    const codepoint = std.unicode.utf8Decode(value[index.* .. index.* + length]) catch return error.InvalidCharacter;
    index.* += length;
    return codepoint;
}

fn writeBinaryCase(writer: *Writer, wire: []const u8, direct: bool, prefix: []const u8) WriterError!void {
    try writer.startDocument();
    try writer.startElement("binary");
    try writer.text(prefix);
    if (direct) {
        try writer.binary(wire);
    } else if (wire.len == 0) {
        try writer.text("");
    } else {
        var encoded: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < wire.len) {
            const length = @min(wire.len - offset, encoded.len / 4 * 3);
            try writer.text(std.base64.standard.Encoder.encode(&encoded, wire[offset..][0..length]));
            offset += length;
        }
    }
    try writer.text(">");
    try writer.endElement();
    try writer.endDocument();
}

// --- Tests ---

test "[property] - [mzML XML writer]: generated Base64 preserves text state, offsets, and sink failures" {
    var wire: [6145]u8 = undefined;
    for (&wire, 0..) |*byte, i| byte.* = @truncate(i);
    var output: [2][9000]u8 = undefined;
    for ([_]usize{ 0, 1, 2, 3, 3071, 3072, 3073, wire.len }) |length| {
        for ([_]usize{ 0, 8, 48, 49, 100, 4096, 8192, output[0].len }) |capacity| {
            for ([_][]const u8{ "", "]]" }) |prefix| {
                var lengths: [2]usize = undefined;
                var offsets: [2]?u64 = undefined;
                var failures: [2]?WriterError = .{ null, null };
                for (0..2) |i| {
                    var sink = std.Io.Writer.fixed(output[i][0..capacity]);
                    var writer = try Writer.init(std.testing.allocator, &sink, .{});
                    defer writer.deinit();
                    writeBinaryCase(&writer, wire[0..length], i == 1, prefix) catch |err| {
                        failures[i] = err;
                        try std.testing.expectError(err, writer.binary(""));
                    };
                    lengths[i] = sink.buffered().len;
                    offsets[i] = writer.byteOffset();
                    if (failures[i] == null) try std.testing.expectError(error.InvalidState, writer.binary(""));
                }
                try std.testing.expectEqual(failures[0], failures[1]);
                try std.testing.expectEqual(offsets[0], offsets[1]);
                try std.testing.expectEqualSlices(u8, output[0][0..lengths[0]], output[1][0..lengths[1]]);
            }
        }
    }
}

test "[unit] - [mzML XML cursor]: skips declarations, comments, processing instructions, and decodes text" {
    const source = "<?xml version='1.0' encoding='UTF-8'?><?p?><p:mzML xmlns:p='" ++ NAMESPACE ++
        "'><p:child xmlns:q='" ++ XSI ++ "' q:schemaLocation='a&amp;b'>A&amp;B<![CDATA[<x>]]></p:child></p:mzML>";
    var input = std.Io.Reader.fixed(source);
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 64, 1024);
    defer cursor.deinit();

    try cursor.advance(false);
    try std.testing.expectEqualStrings("p:mzML", cursor.current.?.data.start_element.name.raw);
    try cursor.advance(false);
    const child = cursor.current.?.data.start_element;
    try std.testing.expectEqualStrings("p:child", child.name.raw);
    try std.testing.expectEqualStrings("a&b", child.attribute(XSI, "schemaLocation").?.value);
    try cursor.advance(true);
    try std.testing.expectEqualStrings("A", cursor.current.?.data.text.bytes);
    try cursor.advance(true);
    try std.testing.expectEqualStrings("&B", cursor.current.?.data.text.bytes);
    try cursor.advance(true);
    try std.testing.expectEqualStrings("<x>", cursor.current.?.data.text.bytes);
    try cursor.advance(false);
    try std.testing.expectEqual(.end_element, std.meta.activeTag(cursor.current.?.data));
    try cursor.advance(false);
    try std.testing.expectEqualStrings("p:mzML", cursor.current.?.data.end_element.name.raw);
    try cursor.advance(false);
    try std.testing.expectEqual(@as(?Event, null), cursor.current);
}

test "[property] - [mzML XML cursor]: decodes Latin-1 attributes text and CDATA across refills" {
    var latin1: [128]u8 = undefined;
    var utf8: [256]u8 = undefined;
    for (&latin1, 0..) |*byte, i| {
        byte.* = @intCast(128 + i);
        utf8[2 * i] = 0xc2 + @as(u8, @intCast(i / 64));
        utf8[2 * i + 1] = 0x80 + @as(u8, @intCast(i % 64));
    }
    const source = try std.fmt.allocPrint(std.testing.allocator, "<?xml version='1.0' encoding='ISO-8859-1'?><mzML xmlns='" ++ NAMESPACE ++
        "' value='{s}'>{s}<![CDATA[{s}]]></mzML>", .{ latin1, latin1, latin1 });
    defer std.testing.allocator.free(source);
    var buffer: [4096]u8 = undefined;
    for ([_]usize{ 1, 7, buffer.len }) |size| {
        var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = source }});
        input.artificial_limit = .limited(size);
        var cursor = try Cursor.init(std.testing.allocator, &input.interface, 64, 64, 1024);
        defer cursor.deinit();
        try cursor.advance(false);
        try std.testing.expectEqualStrings(&utf8, cursor.current.?.data.start_element.attributeRaw("value").?.value);
        try cursor.advance(true);
        try std.testing.expectEqualStrings(&utf8, cursor.current.?.data.text.bytes);
        try std.testing.expectEqual(@as(u64, latin1.len), cursor.current.?.span.end - cursor.current.?.span.start);
        try cursor.advance(true);
        try std.testing.expectEqualStrings(&utf8, cursor.current.?.data.text.bytes);
        try cursor.advance(false);
        try std.testing.expectEqual(@as(u64, source.len - "</mzML>".len), cursor.current.?.span.start);
        try cursor.advance(false);
        try std.testing.expectEqual(null, cursor.current);
    }
}

test "[failure] - [mzML XML cursor]: keeps encoding errors distinct from Latin-1 decoding" {
    const cases = .{
        .{ "<?xml version='1.0' encoding='windows-1252'?><mzML/>", error.UnsupportedEncoding },
        .{ "\xef\xbb\xbf<?xml version='1.0' encoding='ISO-8859-1'?><mzML/>", error.InvalidEncoding },
        .{ "<?xml version='1.0' encoding='UTF-8'?><mzML value='\xe9'/>", error.InvalidEncoding },
        .{ "<?xml version='1.0' encoding='ISO-8859-1'?><mzML value='\x00'/>", error.InvalidXml },
    };
    inline for (cases) |case| {
        var input = std.Io.Reader.fixed(case[0]);
        var cursor = try Cursor.init(std.testing.allocator, &input, 64, 64, 1024);
        defer cursor.deinit();
        try std.testing.expectError(case[1], cursor.advance(false));
    }
    const declaration = "<?xml version='1.0' encoding='ISO-8859-1'?><mzML/>";
    var bytes: [2 + declaration.len * 2]u8 = undefined;
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        std.mem.writeInt(u16, bytes[0..2], 0xfeff, endian);
        for (declaration, 0..) |byte, i| std.mem.writeInt(u16, bytes[2 + i * 2 ..][0..2], byte, endian);
        var input = std.Io.Reader.fixed(&bytes);
        var cursor = try Cursor.init(std.testing.allocator, &input, 64, 64, 1024);
        defer cursor.deinit();
        try std.testing.expectError(error.InvalidEncoding, cursor.advance(false));
    }
}

test "[unit] - [mzML XML cursor]: rejects malformed names, namespace declarations, and XML targets" {
    const cases = .{
        .{ "<mzML xmlns='" ++ NAMESPACE ++ "'><p:1bad/></mzML>", 1 },
        .{ "<mzML xmlns='" ++ NAMESPACE ++ "' xmlns:p='one' xmlns:p='two'/>", 0 },
        .{ "<mzML xmlns='" ++ NAMESPACE ++ "'><?xml version='1.0'?><child/></mzML>", 1 },
    };
    inline for (cases) |case| {
        var input = std.Io.Reader.fixed(case[0]);
        var cursor = try Cursor.init(std.testing.allocator, &input, 64, 64, 1024);
        defer cursor.deinit();
        for (0..case[1]) |_| try cursor.advance(false);
        try std.testing.expectError(error.InvalidXml, cursor.advance(false));
    }
}

test "[property] - [mzML XML cursor]: preserves qualified names and namespace restoration across refills" {
    const root = "<m:mzML xmlns='" ++ NAMESPACE ++ "' xmlns:m='" ++ NAMESPACE ++ "' xmlns:a='urn:outer'>";
    const first = "<m:child \r\n a:value \t= \r'one' />";
    const second = "<child xmlns:a='urn:inner' a:value='two'>";
    const closing = "</child \t>";
    const last = "<m:child a:value='three'/>";
    const source = root ++ first ++ second ++ closing ++ last ++ "</m:mzML>";
    const Expected = struct { token: []const u8, raw: []const u8, prefix: ?[]const u8, local: []const u8, opening: bool };
    const expected = [_]Expected{
        .{ .token = root, .raw = "m:mzML", .prefix = "m", .local = "mzML", .opening = true },
        .{ .token = first, .raw = "m:child", .prefix = "m", .local = "child", .opening = true },
        .{ .token = "", .raw = "m:child", .prefix = "m", .local = "child", .opening = false },
        .{ .token = second, .raw = "child", .prefix = null, .local = "child", .opening = true },
        .{ .token = closing, .raw = "child", .prefix = null, .local = "child", .opening = false },
        .{ .token = last, .raw = "m:child", .prefix = "m", .local = "child", .opening = true },
        .{ .token = "", .raw = "m:child", .prefix = "m", .local = "child", .opening = false },
        .{ .token = "</m:mzML>", .raw = "m:mzML", .prefix = "m", .local = "mzML", .opening = false },
    };
    var utf16: [source.len * 2 + 2]u8 = undefined;
    var buffer: [source.len * 2 + 2]u8 = undefined;
    for ([_]?std.builtin.Endian{ null, .little, .big }) |encoding| {
        const bytes = if (encoding) |endian| blk: {
            std.mem.writeInt(u16, utf16[0..2], 0xfeff, endian);
            for (source, 0..) |byte, index| std.mem.writeInt(u16, utf16[2 + index * 2 ..][0..2], byte, endian);
            break :blk utf16[0..];
        } else source;
        for ([_]usize{ 4, 7, 16, 31, 64, buffer.len }) |size| {
            var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = bytes }});
            input.artificial_limit = .limited(size);
            var cursor = try Cursor.init(std.testing.allocator, &input.interface, 64, 64, 1024);
            defer cursor.deinit();
            var child: usize = 0;
            const scale: u64 = if (encoding != null) 2 else 1;
            var offset: u64 = if (encoding != null) 2 else 0;
            for (expected) |item| {
                try cursor.advance(false);
                const event = cursor.current.?;
                try std.testing.expectEqual(item.opening, event.data == .start_element);
                const name = if (item.opening) event.data.start_element.name else event.data.end_element.name;
                try std.testing.expectEqualStrings(item.raw, name.raw);
                try std.testing.expectEqualStrings(item.local, localName(name));
                try std.testing.expectEqualDeep(item.prefix, name.expanded.prefix);
                try std.testing.expectEqualStrings(NAMESPACE, name.expanded.namespace_uri.?);
                try std.testing.expectEqual(offset, event.span.start);
                offset += item.token.len * scale;
                try std.testing.expectEqual(offset, event.span.end);
                if (item.opening and std.mem.eql(u8, item.local, "child")) {
                    const attribute = event.data.start_element.attributes[0];
                    try std.testing.expectEqualStrings("a:value", attribute.name.raw);
                    try std.testing.expectEqualStrings(([_][]const u8{ "one", "two", "three" })[child], attribute.value);
                    try std.testing.expectEqualStrings("a", attribute.name.expanded.prefix.?);
                    try std.testing.expectEqualStrings("value", attribute.name.expanded.local);
                    try std.testing.expectEqualStrings(if (child == 1) "urn:inner" else "urn:outer", attribute.name.expanded.namespace_uri.?);
                    child += 1;
                }
            }
            try cursor.advance(false);
            try std.testing.expectEqual(null, cursor.current);
        }
    }
}

test "[property] - [mzML XML cursor]: preserves attribute openings across refills" {
    var utf8: [256]u8 = undefined;
    var utf16: [514]u8 = undefined;
    var buffer: [514]u8 = undefined;
    for ([_][]const u8{ "='", "=\"", " = '", "\t=\r\n\"", "= '" }) |opening| {
        const source = try std.fmt.bufPrint(&utf8, "<mzML xmlns='{s}' a{s}x&amp;y{c}/>", .{ NAMESPACE, opening, opening[opening.len - 1] });
        for ([_]?std.builtin.Endian{ null, .little, .big }) |encoding| {
            const bytes = if (encoding) |endian| blk: {
                std.mem.writeInt(u16, utf16[0..2], 0xfeff, endian);
                for (source, 0..) |byte, index| std.mem.writeInt(u16, utf16[2 + index * 2 ..][0..2], byte, endian);
                break :blk utf16[0 .. 2 + source.len * 2];
            } else source;
            for ([_]usize{ 4, 5, 7, 16, 64, buffer.len }) |size| {
                var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = bytes }});
                input.artificial_limit = .limited(size);
                var cursor = try Cursor.init(std.testing.allocator, &input.interface, 64, 64, 1024);
                defer cursor.deinit();
                try cursor.advance(false);
                const event = cursor.current.?;
                const start = event.data.start_element;
                try std.testing.expectEqualStrings("a", start.attributes[0].name.raw);
                try std.testing.expectEqualStrings("x&y", start.attributes[0].value);
                try std.testing.expectEqual(@as(u64, bytes.len), event.span.end);
                try cursor.advance(false);
                try std.testing.expectEqual(.end_element, std.meta.activeTag(cursor.current.?.data));
                try std.testing.expectEqual(@as(u64, bytes.len), cursor.current.?.span.end);
                try cursor.advance(false);
                try std.testing.expectEqual(null, cursor.current);
            }
        }
    }
}

test "[property] - [mzML XML cursor]: quoted runs stop at the first exceptional byte" {
    var storage: [128]u8 = undefined;
    for ([_]u8{ '\'', '"' }) |quote| {
        for ([_]usize{ 0, 1, 7, 15 }) |alignment| {
            for ([_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 96 }) |length| {
                const bytes = storage[alignment..][0..length];
                @memset(bytes, 'x');
                try std.testing.expectEqual(length, ordinaryAttributeRun(bytes, quote));
                for (0..length) |position| {
                    for (0..256) |value| {
                        const byte: u8 = @intCast(value);
                        bytes[position] = byte;
                        const expected = if (byte < 0x20 or byte >= 0x80 or byte == quote or byte == '&' or byte == '<') position else length;
                        try std.testing.expectEqual(expected, ordinaryAttributeRun(bytes, quote));
                    }
                    bytes[position] = 'x';
                }
                if (length >= 2) {
                    bytes[0] = quote;
                    bytes[1] = 0xff;
                    try std.testing.expectEqual(@as(usize, 0), ordinaryAttributeRun(bytes, quote));
                }
            }
        }
    }
}

test "[property] - [mzML XML cursor]: buffered opening tags match incremental parsing and leave declined input unread" {
    const cases = .{
        .{ "child>", true },
        .{ "child/>", true },
        .{ "child \r\n a = 'one>two' b=\"\"/>", true },
        .{ "child a='one' b='two'>", true },
        .{ "child a='one'a='two'>", false },
        .{ "child a='one' b='&amp;'>", false },
        .{ "child a='one' b='\r\ntwo'>", false },
        .{ "child a='one' b='\xc2\xb5'>", false },
        .{ "child a='one' b='\xff'>", false },
        .{ "child xmlns='http://psi.hupo.org/ms/mzml'>", false },
        .{ "p:child>", false },
        .{ "child p:a='one'>", false },
        .{ "child a='one' b=two>", false },
        .{ "child a='one' b='two' /", false },
        .{ "child a='one' b='two", false },
        .{ "child?", false },
    };
    inline for (cases) |case| {
        for ([_]usize{ 1, 10, 128 }) |limit| {
            for ([_]usize{ 1, 4 }) |attributes| {
                var input = std.Io.Reader.fixed(case[0]);
                var reference_input = std.Io.Reader.fixed(case[0]);
                var cursor = try Cursor.init(std.testing.allocator, &input, 64, attributes, limit);
                defer cursor.deinit();
                var reference = try Cursor.init(std.testing.allocator, &reference_input, 64, attributes, limit);
                defer reference.deinit();
                cursor.source.detected = true;
                reference.source.detected = true;
                try cursor.event_bytes.ensureTotalCapacity(std.testing.allocator, 128);
                try cursor.attribute_ranges.ensureTotalCapacity(std.testing.allocator, 4);

                const event = try cursor.readBufferedStartElement(0);
                if (limit == 128 and attributes == 4) try std.testing.expectEqual(case[1], event != null);
                if (event) |actual| {
                    try std.testing.expectEqualDeep(try reference.readStartElement(0), actual);
                    try std.testing.expectEqual(@as(usize, 0), cursor.event_bytes.items.len);
                    const base = @intFromPtr(case[0].ptr);
                    const name = actual.data.start_element.name.raw;
                    try std.testing.expect(@intFromPtr(name.ptr) >= base);
                    try std.testing.expect(@intFromPtr(name.ptr) + name.len <= base + case[0].len);
                    for (actual.data.start_element.attributes) |attribute| {
                        try std.testing.expect(@intFromPtr(attribute.value.ptr) >= base);
                        try std.testing.expect(@intFromPtr(attribute.value.ptr) + attribute.value.len <= base + case[0].len);
                    }
                } else {
                    try std.testing.expectEqual(@as(u64, 0), cursor.source.position);
                    try std.testing.expectEqualStrings(case[0], input.buffered());
                    const expected = reference.readStartElement(0) catch |err| {
                        try std.testing.expectError(err, cursor.readStartElement(0));
                        try std.testing.expectEqual(reference.source.currentOffset(), cursor.source.currentOffset());
                        continue;
                    };
                    try std.testing.expectEqualDeep(expected, try cursor.readStartElement(0));
                }
            }
        }
    }
}

test "[property] - [mzML XML cursor]: closing names survive consumed opening-buffer reuse" {
    const root = "<mzML xmlns='" ++ NAMESPACE ++ "'>";
    const first = "<child value='one'>";
    const close = "</child>";
    const second = "<other value='two'/>";
    var bytes = (root ++ first ++ close ++ second ++ "</mzML>").*;
    var input = std.Io.Reader.fixed(&bytes);
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 64, 1024);
    defer cursor.deinit();
    try cursor.advance(false);
    try cursor.advance(false);
    try std.testing.expectEqualStrings("one", cursor.current.?.data.start_element.attributes[0].value);
    try std.testing.expectEqual(@as(usize, 0), cursor.event_bytes.items.len);
    @memset(bytes[root.len..][0..first.len], '?');
    try cursor.advance(false);
    try std.testing.expectEqualStrings("child", cursor.current.?.data.end_element.name.raw);
    try cursor.advance(false);
    try std.testing.expectEqualStrings("two", cursor.current.?.data.start_element.attributes[0].value);
    @memset(bytes[root.len + first.len + close.len ..][0..second.len], '?');
    try cursor.advance(false);
    try std.testing.expectEqualStrings("other", cursor.current.?.data.end_element.name.raw);
    try cursor.advance(false);
    try std.testing.expectEqualStrings("mzML", cursor.current.?.data.end_element.name.raw);
    try cursor.advance(false);
    try std.testing.expectEqual(null, cursor.current);
}

test "[property] - [mzML XML cursor]: leaves QName delimiters unread at exact token limits" {
    var source: [64]u8 = undefined;
    var buffer: [64]u8 = undefined;
    for ([_][]const u8{ "a", "scan_123", "p:array", "long_prefix:data-array.name" }) |name| {
        for (" \t\r\n/>=?") |delimiter| {
            const bytes = try std.fmt.bufPrint(&source, "{s}{c}x", .{ name, delimiter });
            for ([_]usize{ 4, 7, 31, buffer.len }) |size| {
                for (name.len..name.len + 3) |limit| {
                    var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = bytes }});
                    var cursor = try Cursor.init(std.testing.allocator, &input.interface, 64, 64, limit);
                    defer cursor.deinit();
                    try cursor.appendEventByte('z');
                    if (limit == name.len) {
                        try std.testing.expectError(error.LimitExceeded, cursor.parseQName());
                        continue;
                    }
                    const parsed = try cursor.parseQName();
                    try std.testing.expectEqualStrings(name, cursor.event_bytes.items[parsed.start..][0..parsed.len]);
                    try std.testing.expectEqual(@as(usize, 1), parsed.start);
                    try std.testing.expectEqual(std.mem.indexOfScalar(u8, name, ':') orelse 0, parsed.prefix_len);
                    const next = try cursor.requiredCodepoint();
                    try std.testing.expectEqual(@as(u21, delimiter), next.value);
                    try std.testing.expectEqual(@as(u64, name.len), next.start);
                    try std.testing.expectEqual(@as(u64, name.len + 1), next.end);
                }
            }
        }
    }
}

test "[unit] - [mzML XML cursor]: enforces expanded names, document CDATA, text delimiters, and declaration order" {
    const cases = .{
        .{ "<mzML xmlns='" ++ NAMESPACE ++ "' xmlns:a='urn:test' xmlns:b='urn:test' a:x='1' b:x='2'/>", 0 },
        .{ "<![CDATA[outside]]><mzML xmlns='" ++ NAMESPACE ++ "'/>", 0 },
        .{ "<mzML xmlns='" ++ NAMESPACE ++ "'>]]></mzML>", 1 },
        .{ "<?xml encoding='UTF-8' version='1.0'?><mzML xmlns='" ++ NAMESPACE ++ "'/>", 0 },
        .{ "<?xml version='1.0'encoding='UTF-8'?><mzML xmlns='" ++ NAMESPACE ++ "'/>", 0 },
    };
    inline for (cases) |case| {
        var input = std.Io.Reader.fixed(case[0]);
        var cursor = try Cursor.init(std.testing.allocator, &input, 64, 64, 1024);
        defer cursor.deinit();
        for (0..case[1]) |_| try cursor.advance(false);
        try std.testing.expectError(error.InvalidXml, cursor.advance(false));
    }

    const xml_attribute = "<mzML xmlns='" ++ NAMESPACE ++ "' xml:lang='en'/>";
    var input = std.Io.Reader.fixed(xml_attribute);
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 64, 1024);
    defer cursor.deinit();
    try cursor.advance(false);
    try std.testing.expectEqualStrings(XML_NAMESPACE, cursor.current.?.data.start_element.attribute(XML_NAMESPACE, "lang").?.name.expanded.namespace_uri.?);
}

test "[property] - [mzML XML cursor]: ignores only XML whitespace when text is not requested" {
    const prefix = "<mzML xmlns='" ++ NAMESPACE ++ "'>";
    const cases = [_]struct { text: []const u8, whitespace: bool }{
        .{ .text = "", .whitespace = true },
        .{ .text = " \t\r\n", .whitespace = true },
        .{ .text = "&#x20;&#x9;&#xD;&#xA;", .whitespace = true },
        .{ .text = "<![CDATA[ \t\r\n]]>", .whitespace = true },
        .{ .text = " x ", .whitespace = false },
        .{ .text = "&#x20;x", .whitespace = false },
        .{ .text = "&#x85;", .whitespace = false },
        .{ .text = "&#xA0;", .whitespace = false },
        .{ .text = "&#x2003;", .whitespace = false },
        .{ .text = "<![CDATA[x]]>", .whitespace = false },
    };
    var utf8: [256]u8 = undefined;
    var utf16: [514]u8 = undefined;
    var buffer: [514]u8 = undefined;
    for (cases) |case| {
        const source = try std.fmt.bufPrint(&utf8, "{s}{s}</mzML>", .{ prefix, case.text });
        for ([_]?std.builtin.Endian{ null, .little, .big }) |encoding| {
            const bytes = if (encoding) |endian| blk: {
                std.mem.writeInt(u16, utf16[0..2], 0xfeff, endian);
                for (source, 0..) |byte, index| std.mem.writeInt(u16, utf16[2 + index * 2 ..][0..2], byte, endian);
                break :blk utf16[0 .. 2 + source.len * 2];
            } else source;
            for ([_]usize{ 4, 7, 31, buffer.len }) |size| {
                var input: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = bytes }});
                var cursor = try Cursor.init(std.testing.allocator, &input.interface, 64, 64, 1024);
                defer cursor.deinit();
                try cursor.advance(false);
                if (case.whitespace) {
                    try cursor.advance(false);
                    try std.testing.expectEqualStrings("mzML", cursor.current.?.data.end_element.name.raw);
                    try cursor.advance(false);
                    try std.testing.expectEqual(null, cursor.current);
                } else try std.testing.expectError(error.InvalidXml, cursor.advance(false));
            }
        }
    }
}

test "[property] - [mzML XML cursor]: discards complete buffered indentation without moving pending closes" {
    const prefix = "<mzML xmlns='" ++ NAMESPACE ++ "'><child/>";
    const suffix = "</mzML>";
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, prefix.len + TEXT_CHUNK_BYTES + 4 + suffix.len);
    defer allocator.free(source);
    const buffer = try allocator.alloc(u8, source.len);
    defer allocator.free(buffer);
    @memcpy(source[0..prefix.len], prefix);
    for ([_]usize{ 0, 1, 3, 19, TEXT_CHUNK_BYTES - 1, TEXT_CHUNK_BYTES, TEXT_CHUNK_BYTES + 1 }) |length| {
        for (source[prefix.len..][0..length], 0..) |*byte, i| byte.* = " \t\r\n"[i % 4];
        @memcpy(source[prefix.len + length ..][0..suffix.len], suffix);
        const bytes = source[0 .. prefix.len + length + suffix.len];
        for ([_]usize{ 0, 4, 31, buffer.len }) |size| {
            var fixed = std.Io.Reader.fixed(bytes);
            var chunks: std.testing.Reader = .init(buffer[0..size], &.{.{ .buffer = bytes }});
            var cursor = try Cursor.init(allocator, if (size == 0) &fixed else &chunks.interface, 64, 64, 1024);
            defer cursor.deinit();
            try cursor.advance(false);
            try cursor.advance(false);
            const before_close = cursor.source.currentOffset();
            try cursor.advance(false);
            try std.testing.expectEqualStrings("child", cursor.current.?.data.end_element.name.raw);
            try std.testing.expectEqual(before_close, cursor.source.currentOffset());
            try std.testing.expectEqual(prefix.len, cursor.current.?.span.start);
            try cursor.advance(false);
            try std.testing.expectEqualStrings("mzML", cursor.current.?.data.end_element.name.raw);
            try std.testing.expectEqual(prefix.len + length, cursor.current.?.span.start);
            try std.testing.expectEqual(bytes.len, cursor.current.?.span.end);
            if (size == 0 and length < TEXT_CHUNK_BYTES)
                try std.testing.expectEqual(@as(usize, 0), cursor.text_bytes.capacity);
            try cursor.advance(false);
            try std.testing.expectEqual(null, cursor.current);
        }
    }
}

test "[unit] - [mzML XML cursor]: bounds borrowed ordinary text events" {
    const prefix = "<mzML xmlns='" ++ NAMESPACE ++ "'>";
    const suffix = "</mzML>";
    const text_length = TEXT_CHUNK_BYTES + 7;
    const source = try std.testing.allocator.alloc(u8, prefix.len + text_length + suffix.len);
    defer std.testing.allocator.free(source);
    @memcpy(source[0..prefix.len], prefix);
    @memset(source[prefix.len..][0..text_length], 'A');
    @memcpy(source[prefix.len + text_length ..], suffix);

    var input = std.Io.Reader.fixed(source);
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 64, 1024);
    defer cursor.deinit();
    try cursor.advance(false);
    try cursor.advance(true);
    try std.testing.expectEqual(TEXT_CHUNK_BYTES, cursor.current.?.data.text.bytes.len);
    try cursor.advance(true);
    try std.testing.expectEqual(@as(usize, 7), cursor.current.?.data.text.bytes.len);
    try cursor.advance(false);
    try std.testing.expectEqual(.end_element, std.meta.activeTag(cursor.current.?.data));
}

test "[regression] - [mzML XML cursor]: preserves text and attribute boundaries" {
    const prefix = "<mzML xmlns='" ++ NAMESPACE ++ "' id='a\r\nb' ref='a&#xD;&#xA;b'>";
    const suffix = "</mzML>";
    const text_length = TEXT_CHUNK_BYTES - 1;
    const source = try std.testing.allocator.alloc(u8, prefix.len + text_length + 2 + suffix.len);
    defer std.testing.allocator.free(source);
    @memcpy(source[0..prefix.len], prefix);
    @memset(source[prefix.len..][0..text_length], 'A');
    @memcpy(source[prefix.len + text_length ..][0..2], "\xC2\xB5");
    @memcpy(source[prefix.len + text_length + 2 ..], suffix);

    var input = std.Io.Reader.fixed(source);
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 64, 1024);
    defer cursor.deinit();
    try cursor.advance(false);
    const root = cursor.current.?.data.start_element;
    try std.testing.expectEqualStrings("a b", root.attribute(null, "id").?.value);
    try std.testing.expectEqualStrings("a\r\nb", root.attribute(null, "ref").?.value);
    try cursor.advance(true);
    try std.testing.expectEqual(text_length, cursor.current.?.data.text.bytes.len);
    try cursor.advance(true);
    try std.testing.expectEqualStrings("\xC2\xB5", cursor.current.?.data.text.bytes);
}

test "[regression] - [mzML XML cursor]: keeps CDATA codepoints within text chunks" {
    const prefix = "<mzML xmlns='" ++ NAMESPACE ++ "'><![CDATA[";
    const suffix = "]]></mzML>";
    const text_length = TEXT_CHUNK_BYTES - 1;
    const source = try std.testing.allocator.alloc(u8, prefix.len + text_length + 2 + suffix.len);
    defer std.testing.allocator.free(source);
    @memcpy(source[0..prefix.len], prefix);
    @memset(source[prefix.len..][0..text_length], 'A');
    @memcpy(source[prefix.len + text_length ..][0..2], "\xC2\xB5");
    @memcpy(source[prefix.len + text_length + 2 ..], suffix);

    var input = std.Io.Reader.fixed(source);
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 64, 1024);
    defer cursor.deinit();
    try cursor.advance(false);
    try cursor.advance(true);
    try std.testing.expectEqual(text_length, cursor.current.?.data.text.bytes.len);
    try cursor.advance(true);
    try std.testing.expectEqualStrings("\xC2\xB5", cursor.current.?.data.text.bytes);
}

test "[property] - [mzML XML writer]: preserves text runs, split brackets, and late character failures" {
    const ordinary: [4097]u8 = @splat('A');
    var value_buffer: [8192]u8 = undefined;
    var expected_buffer: [8192]u8 = undefined;
    var output: [8192]u8 = undefined;
    const opening = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><binary";
    for ([_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 4095, 4096, 4097 }) |length| {
        const value = try std.fmt.bufPrint(&value_buffer, "{s}]]><&\r\xc2\xb5]]", .{ordinary[0..length]});
        const expected = try std.fmt.bufPrint(&expected_buffer, opening ++ ">]]{s}]]&gt;&lt;&amp;&#xD;\xc2\xb5]]&gt;</binary>", .{ordinary[0..length]});
        for ([_]usize{ 0, length / 2, length, length + 1, length + 2, length + 3, value.len }) |split| {
            var sink = std.Io.Writer.fixed(&output);
            var writer = try Writer.init(std.testing.allocator, &sink, .{});
            defer writer.deinit();
            try writer.startDocument();
            try writer.startElement("binary");
            try writer.text("]]");
            try writer.text(value[0..split]);
            try writer.text(value[split..]);
            try writer.text(">");
            try writer.endElement();
            try writer.endDocument();
            try std.testing.expectEqualStrings(expected, sink.buffered());
            try std.testing.expectEqual(@as(?u64, expected.len), writer.byteOffset());
        }
        for ([_][]const u8{ "\x00", "\x01", "\xc0\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xef\xbf\xbe", "\xc2" }) |invalid| {
            const bad = try std.fmt.bufPrint(&value_buffer, "{s}&{s}", .{ ordinary[0..length], invalid });
            for ([_]bool{ false, true }) |attribute| {
                var sink = std.Io.Writer.fixed(&output);
                var writer = try Writer.init(std.testing.allocator, &sink, .{});
                defer writer.deinit();
                try writer.startDocument();
                try writer.startElement("binary");
                try std.testing.expectError(error.InvalidCharacter, if (attribute) writer.attribute("id", bad) else writer.text(bad));
                const partial = try std.fmt.bufPrint(&expected_buffer, opening ++ "{s}{s}&amp;", .{ if (attribute) " id=\"" else ">", ordinary[0..length] });
                try std.testing.expectEqualStrings(partial, sink.buffered());
                try std.testing.expectEqual(@as(?u64, partial.len), writer.byteOffset());
                try std.testing.expectError(error.InvalidCharacter, writer.text("later"));
                try std.testing.expectError(error.InvalidCharacter, writer.attribute("more", "later"));
            }
        }
    }
}

test "[unit] - [mzML XML writer]: emits escaped values and flushes empty text" {
    var output: [1024]u8 = undefined;
    var sink = std.Io.Writer.fixed(&output);
    var writer = try Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("mzML");
    try writer.namespace(null, NAMESPACE);
    try writer.attribute("id", "a&\"b\t\n\r\xc2\xb5\xe2\x82\xac\xf0\x9f\x98\x80");
    try writer.text("]]> &<\r");
    try writer.endElement();
    try writer.endDocument();
    try std.testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><mzML xmlns=\"" ++ NAMESPACE ++ "\" id=\"a&amp;&quot;b&#x9;&#xA;&#xD;\xc2\xb5\xe2\x82\xac\xf0\x9f\x98\x80\">]]&gt; &amp;&lt;&#xD;</mzML>",
        sink.buffered(),
    );
    try std.testing.expectEqual(@as(?u64, sink.buffered().len), writer.byteOffset());
}

test "[unit] - [mzML XML writer]: keeps duplicate-attribute failures sticky" {
    var output: [128]u8 = undefined;
    var sink = std.Io.Writer.fixed(&output);
    var writer = try Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("mzML");
    try writer.attribute("id", "one");
    try std.testing.expectError(error.DuplicateAttribute, writer.attribute("id", "two"));
    try std.testing.expectError(error.DuplicateAttribute, writer.text("later"));
}

test "[property] - [mzML XML writer]: copies attribute names and permits reuse on child and sibling tags" {
    const original: [4096]u8 = @splat('a');
    const changed: [4096]u8 = @splat('b');
    var name: [4096]u8 = undefined;
    var output: [32768]u8 = undefined;
    var expected_buffer: [32768]u8 = undefined;
    for ([_]usize{ 1, 7, 8, 9, 15, 16, 17, 255, 256, 257, 4096 }) |length| {
        var sink = std.Io.Writer.fixed(&output);
        var writer = try Writer.init(std.testing.allocator, &sink, .{});
        defer writer.deinit();
        try writer.startDocument();
        try writer.startElement("mzML");
        @memcpy(name[0..length], original[0..length]);
        try writer.attribute(name[0..length], "one");
        @memcpy(name[0..length], changed[0..length]);
        try writer.attribute(name[0..length], "two");
        for (0..2) |_| {
            try writer.startElement("run");
            try writer.attribute(original[0..length], "three");
            try writer.endElement();
        }
        try writer.endElement();
        try writer.endDocument();
        const expected = try std.fmt.bufPrint(
            &expected_buffer,
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><mzML {s}=\"one\" {s}=\"two\"><run {s}=\"three\"/><run {s}=\"three\"/></mzML>",
            .{ original[0..length], changed[0..length], original[0..length], original[0..length] },
        );
        try std.testing.expectEqualStrings(expected, sink.buffered());
        try std.testing.expectEqual(@as(?u64, expected.len), writer.byteOffset());
    }
}

test "[unit] - [mzML XML writer]: rejects generic and undeclared namespace names" {
    {
        var output: [256]u8 = undefined;
        var sink = std.Io.Writer.fixed(&output);
        var writer = try Writer.init(std.testing.allocator, &sink, .{});
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("mzML");
        try writer.namespace(null, NAMESPACE);
        try std.testing.expectError(error.InvalidNamespace, writer.attribute("xsi:schemaLocation", "location"));
    }
    {
        var output: [256]u8 = undefined;
        var sink = std.Io.Writer.fixed(&output);
        var writer = try Writer.init(std.testing.allocator, &sink, .{});
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("mzML");
        try writer.namespace(null, NAMESPACE);
        try std.testing.expectError(error.InvalidNamespace, writer.startElement("p:child"));
    }
}
