//! Small XML scanner and writer for the XML constructs used by mzML.
//!
//! The module is internal. Its event types (`Event` and the types it is built from),
//! `Cursor.Namespace`, `ReadError`, `Rule`, and `MAX_DEPTH` reach callers through `mzml.Events`,
//! `Diagnostic`, and `mzml.MAX_DEPTH`; the cursor and the writer serve the readers and the mzML
//! writer only.

const std = @import("std");
const base64 = @import("../binary/base64.zig");
const overlaps = @import("../binary/core.zig").overlaps;

pub const NAMESPACE = "http://psi.hupo.org/ms/mzml";
pub const NAMESPACE_1_0 = "http://psi.hupo.org/schema_revision/mzML_1.0.0";
pub const XSI = "http://www.w3.org/2001/XMLSchema-instance";
pub const XMLNS_NAMESPACE = "http://www.w3.org/2000/xmlns/";
/// Deepest element nesting, counting the root, that readers, writers, copies, and builders accept.
pub const MAX_DEPTH = 64;
pub const MAX_DECLARATION_BYTES = 4096;

pub const ReadError = error{
    InvalidXml,
    InvalidEncoding,
    UnsupportedEncoding,
    UnsupportedVersion,
    DtdForbidden,
    ReadFailed,
    LimitExceeded,
    InvalidState,
};

/// Which XML rule malformed input broke, kept with `InvalidXml` (`Cursor.xml_rule`).
pub const Rule = enum {
    /// The input ended inside markup or before the root element closed.
    unexpected_end,
    /// An end tag that does not close the innermost open element, or closes none.
    mismatched_end_tag,
    /// Non-whitespace text where no text is accepted.
    unexpected_text,
    /// An element or text after the root element closed.
    content_after_root,
    /// A malformed tag: a missing `>`, `=`, or quote.
    malformed_tag,
    /// `<` inside an attribute value.
    less_than_in_attribute,
    /// A malformed comment, CDATA section, or processing instruction, or `]]>` in text.
    malformed_markup,
    /// A malformed XML declaration.
    malformed_declaration,
    invalid_name,
    duplicate_attribute,
    /// A prefix with no namespace declaration in scope.
    unbound_prefix,
    /// A reserved prefix or namespace misused, or a prefix bound to an empty URI.
    invalid_namespace_declaration,
    unknown_entity,
    invalid_character_reference,
    /// A character XML 1.0 does not allow.
    invalid_character,
};

pub const InitError = error{InvalidOptions};
pub const Error = ReadError || std.mem.Allocator.Error || error{
    WrongNamespace,
    UnexpectedEnd,
};
// What a fragment advance can return: it never checks the root's namespace, and after the
// document ends it leaves current null again instead of failing.
pub const AdvanceError = ReadError || std.mem.Allocator.Error;

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

/// A parsed non-namespace attribute borrowed until the next cursor event.
pub const Attribute = struct {
    name: Name,
    value: []const u8,
    /// Source offset of the attribute's name.
    offset: u64,
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

/// An event with physical source-byte offsets.
pub const Event = struct {
    span: struct { start: u64, end: u64 },
    data: EventData,
};

pub const Ancestors = struct {
    depth: usize,
    names: usize,
    namespace_bytes: usize,
    bindings: usize,
    encoding: Encoding,
    mzml_namespace: []const u8,
    pending_empty: bool,
};

pub const Cursor = struct {
    pub const Namespace = struct { prefix: []const u8, uri: []const u8 };

    allocator: std.mem.Allocator,
    source: Source,
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
    mzml_namespace: []const u8 = NAMESPACE,
    frames: [MAX_DEPTH]Frame = undefined,
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
    additional_namespaces: ?bool = null,
    // Changes whenever the in-scope bindings do, so a reader can reuse what it built for a scope.
    namespace_scope: u64 = 0,
    // Requested text still leaves out whitespace-only runs, through the readers' buffered skip.
    skip_whitespace_text: bool = false,
    failure: ?Error = null,
    limit_failure: ?enum { depth, attributes, attribute_bytes, nodes, declaration_bytes } = null,
    // The rule broken by the input when failure is InvalidXml.
    xml_rule: ?Rule = null,
    // Where the input broke a rule or its declared encoding, reported as offset.
    failure_offset: ?u64 = null,
    // Source offset of the XML declaration's first byte after the <?xml opener.
    declaration_start: u64 = 0,
    // The bytes an over-limit attribute value needed, when known.
    limit_needed: ?usize = null,

    pub fn init(
        allocator: std.mem.Allocator,
        input: *std.Io.Reader,
        max_attributes: usize,
        max_attribute_bytes: usize,
    ) InitError!Cursor {
        if (max_attributes == 0 or max_attribute_bytes == 0) {
            return error.InvalidOptions;
        }
        if (input.buffer.len == 0 and input.vtable != std.Io.Reader.ending.vtable) return error.InvalidOptions;
        return .{
            .allocator = allocator,
            .source = Source.init(input),
            .max_attributes = max_attributes,
            .max_attribute_bytes = max_attribute_bytes,
        };
    }

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
        self.* = undefined;
    }

    pub fn reset(self: *Cursor, input: *std.Io.Reader) void {
        self.source.reset(input);
        self.resetState(false);
    }

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
            .mzml_namespace = self.mzml_namespace,
            .pending_empty = self.pending_empty,
        };
    }

    // Restores ancestor storage left intact by a successful fragment read. A failed read or a
    // different prefix requires parsing those ancestors again.
    pub fn resetToAncestors(self: *Cursor, input: *std.Io.Reader, saved: Ancestors, prefix_length: usize) void {
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
        if (self.namespace_bindings.items.len > saved.bindings) self.truncateBindings(saved.bindings);
        self.namespace_bindings.items = self.namespace_bindings.allocatedSlice()[0..saved.bindings];
        self.mzml_namespace = saved.mzml_namespace;
        self.pending_empty = saved.pending_empty;
    }

    pub fn advance(self: *Cursor, text: bool) Error!void {
        return self.advanceInner(text, true);
    }

    pub fn advanceFragment(self: *Cursor, text: bool) AdvanceError!void {
        return self.advanceInner(text, false);
    }

    pub fn hasAdditionalNamespaces(self: *Cursor) bool {
        if (self.additional_namespaces) |value| return value;
        for (self.namespace_bindings.items) |binding| {
            const prefix = self.namespace_bytes.items[binding.prefix_start..][0..binding.prefix_len];
            const uri = self.namespace_bytes.items[binding.uri_start..][0..binding.uri_len];
            if (prefix.len == 0 and std.mem.eql(u8, uri, self.mzml_namespace)) continue;
            if (std.mem.eql(u8, prefix, "xsi") and std.mem.eql(u8, uri, XSI)) continue;
            if (std.mem.eql(u8, prefix, "xml") and std.mem.eql(u8, uri, XML_NAMESPACE)) continue;
            self.additional_namespaces = true;
            return true;
        }
        self.additional_namespaces = false;
        return false;
    }

    // Skips shadowed declarations. Views expire on advance.
    pub fn namespaceAt(self: *const Cursor, position: *usize) ?Namespace {
        while (position.* < self.namespace_bindings.items.len) {
            const binding = self.namespace_bindings.items[position.*];
            position.* += 1;
            if (binding.shadowed) continue;
            const prefix = self.namespace_bytes.items[binding.prefix_start..][0..binding.prefix_len];
            // resolveNamespace answers the xml prefix itself, so its bindings are never listed.
            if (std.mem.eql(u8, prefix, "xml")) continue;
            return .{ .prefix = prefix, .uri = self.namespace_bytes.items[binding.uri_start..][0..binding.uri_len] };
        }
        return null;
    }

    // Starts at a current start element and leaves the subtree's end event current. Namespace
    // bindings make the emitted fragment independent of its former ancestors.
    pub fn writeElement(
        self: *Cursor,
        output: *Writer,
        remaining_nodes: *usize,
    ) (AdvanceError || WriterError || error{UnexpectedEnd})!void {
        std.debug.assert(self.current.?.data == .start_element);
        var nesting: usize = 0;
        while (self.current) |event| {
            switch (event.data) {
                .start_element => |start| {
                    if (remaining_nodes.* == 0) return self.limitError(.nodes);
                    remaining_nodes.* -= 1;
                    nesting += 1;
                    try output.startElement(start.name.raw);
                    // The fragment's root declares every binding in scope; nested elements then
                    // inherit them and declare only their own, as the source did.
                    var position: usize = if (nesting == 1) 0 else self.frames[self.depth - 1].binding_start;
                    var default_seen = false;
                    while (self.namespaceAt(&position)) |binding| {
                        default_seen = default_seen or binding.prefix.len == 0;
                        if (!optionalSliceEql(output.namespaceUri(binding.prefix), binding.uri))
                            try output.namespace(if (binding.prefix.len == 0) null else binding.prefix, binding.uri);
                    }
                    if (nesting == 1 and !default_seen and !optionalSliceEql(output.namespaceUri(""), "")) try output.namespace(null, "");
                    for (start.attributes) |attribute| try output.attribute(attribute.name.raw, attribute.value);
                },
                .end_element => {
                    try output.endElement();
                    nesting -= 1;
                    if (nesting == 0) return;
                },
                .text => |value| try output.text(value.bytes),
            }
            try self.advanceFragment(true);
        }
        return error.UnexpectedEnd;
    }

    // Starts at a current start element and leaves the subtree's end event current.
    pub fn skipElement(self: *Cursor, remaining_nodes: *usize) (AdvanceError || error{UnexpectedEnd})!void {
        std.debug.assert(self.current.?.data == .start_element);
        var nesting: usize = 0;
        while (self.current) |event| {
            switch (event.data) {
                .start_element => {
                    if (remaining_nodes.* == 0) return self.limitError(.nodes);
                    remaining_nodes.* -= 1;
                    nesting += 1;
                },
                .end_element => {
                    nesting -= 1;
                    if (nesting == 0) return;
                },
                .text => {},
            }
            try self.advanceFragment(true);
        }
        return error.UnexpectedEnd;
    }

    fn resetState(self: *Cursor, keep_ancestors: bool) void {
        self.failure = null;
        self.limit_failure = null;
        self.limit_needed = null;
        self.xml_rule = null;
        self.failure_offset = null;
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
        self.mzml_namespace = NAMESPACE;
        self.scopeChanged();
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

    fn advanceInner(
        self: *Cursor,
        text: bool,
        comptime mzml_root: bool,
    ) (if (mzml_root) Error else AdvanceError)!void {
        errdefer |err| self.failure = err;
        self.current = null;
        const ended_before = self.document_ended;
        while (true) {
            const maybe_event = self.nextEvent(!text or self.skip_whitespace_text) catch |err| {
                self.offset = self.failedAt(err);
                if (err == error.EndOfStream) self.xml_rule = .unexpected_end;
                return switch (err) {
                    error.EndOfStream => error.InvalidXml,
                    else => |other| other,
                };
            };
            // The document's end leaves no event; advancing again past it is an error only for
            // the mzML root walk.
            const event = maybe_event orelse {
                self.offset = self.source.currentOffset();
                if (mzml_root and ended_before) return error.UnexpectedEnd;
                return;
            };
            self.offset = event.span.start;
            switch (event.data) {
                .start_element => |start| {
                    if (self.depth == 1 and optionalSliceEql(start.name.expanded.namespace_uri, NAMESPACE_1_0))
                        self.mzml_namespace = NAMESPACE_1_0;
                    if (mzml_root and self.depth == 1 and
                        !optionalSliceEql(start.name.expanded.namespace_uri, self.mzml_namespace)) return error.WrongNamespace;
                    self.current = event;
                    return;
                },
                .end_element => {
                    self.current = event;
                    return;
                },
                .text => |value| {
                    // Text outside the root element must be whitespace and is never returned.
                    if (text and self.depth != 0) {
                        if (self.skip_whitespace_text and isXmlWhitespaceRun(value.bytes)) continue;
                        self.current = event;
                        return;
                    }
                    if (!isXmlWhitespaceRun(value.bytes)) {
                        self.xml_rule = .unexpected_text;
                        return error.InvalidXml;
                    }
                },
            }
        }
    }

    fn beginEvent(self: *Cursor) AdvanceError!void {
        try self.source.commitBorrowed();
        self.event_bytes.clearRetainingCapacity();
        self.text_bytes.clearRetainingCapacity();
        self.declaration_bytes.clearRetainingCapacity();
        self.attribute_ranges.clearRetainingCapacity();
        self.namespace_declarations.clearRetainingCapacity();
        self.attributes.clearRetainingCapacity();
    }

    fn skipBufferedWhitespace(self: *Cursor) void {
        if (!self.source.bytesAreCharacters()) return;
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
        }

        if (self.pending_empty) return try self.syntheticEnd();

        while (true) {
            if (self.in_cdata) {
                if (try self.readCdataText()) |event| return event;
                continue;
            }
            if (ignore_whitespace) self.skipBufferedWhitespace();
            if (self.source.bytesAreCharacters()) if (self.source.reader) |reader| {
                // A start or end tag opening in the buffer skips the codepoint reads; comments,
                // processing instructions, and CDATA keep them.
                const bytes = reader.buffered();
                if (bytes.len >= 2 and bytes[0] == '<' and (isAsciiNameStart(bytes[1]) or bytes[1] == '/')) {
                    const opening_start = self.source.position;
                    self.normal_text_brackets = 0;
                    if (bytes[1] == '/') {
                        reader.toss(2);
                        try self.source.addPosition(2);
                        self.source.last_start = opening_start + 1;
                        return try self.readEndElement(opening_start);
                    }
                    reader.toss(1);
                    try self.source.addPosition(1);
                    self.source.last_start = opening_start;
                    if (try self.readBufferedStartElement(opening_start)) |event| return event;
                    return try self.readStartElement(opening_start);
                }
            };
            const first = self.source.peekCodepoint() catch |err| switch (err) {
                error.EndOfStream => {
                    if (self.root_seen and self.root_closed and self.depth == 0) {
                        self.document_ended = true;
                        return null;
                    }
                    return self.malformed(.unexpected_end);
                },
                else => |other| return other,
            };
            if (first.value != '<') {
                if (try self.readScalarText()) |event| return event;
                continue;
            }
            self.normal_text_brackets = 0;

            const opening = try self.requiredCodepoint();
            if (try self.readBufferedStartElement(opening.start)) |event| return event;
            const marker = try self.requiredCodepoint();
            switch (marker.value) {
                '/' => return try self.readEndElement(opening.start),
                '?' => {
                    try self.readProcessingInstruction(false);
                    continue;
                },
                '!' => {
                    const declaration_marker = try self.requiredCodepoint();
                    if (declaration_marker.value == '-') {
                        const second_dash = try self.requiredCodepoint();
                        if (second_dash.value != '-') return self.malformed(.malformed_markup);
                        try self.readComment();
                        continue;
                    }
                    if (declaration_marker.value == '[') {
                        try self.readCdataStart(opening.start);
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
            else => |other| return other,
        };
        if (first.value != '<') return;

        const opening = try self.requiredCodepoint();
        const marker = self.source.peekCodepoint() catch |err| switch (err) {
            error.EndOfStream => {
                try self.source.unread(opening);
                return;
            },
            else => |other| return other,
        };
        if (marker.value != '?') {
            try self.source.unread(opening);
            return;
        }
        _ = try self.requiredCodepoint();
        try self.readProcessingInstruction(true);
    }

    // A line feed right after a carriage return belongs to the same line end.
    fn skipLineFeed(self: *Cursor) AdvanceError!void {
        const next = self.source.peekCodepoint() catch |err| switch (err) {
            error.EndOfStream => return,
            else => |other| return other,
        };
        if (next.value == '\n') _ = try self.requiredCodepoint();
    }

    fn requiredCodepoint(self: *Cursor) AdvanceError!Codepoint {
        return self.source.readCodepoint() catch |err| switch (err) {
            error.EndOfStream => self.malformed(.unexpected_end),
            else => |other| other,
        };
    }

    fn appendEventByte(self: *Cursor, value: u8) AdvanceError!void {
        return self.appendEventSlice(&.{value});
    }

    fn appendEventSlice(self: *Cursor, value: []const u8) AdvanceError!void {
        const next_length = std.math.add(usize, self.event_bytes.items.len, value.len) catch return error.LimitExceeded;
        if (next_length > self.max_attribute_bytes) {
            self.limit_needed = next_length;
            return self.limitError(.attribute_bytes);
        }
        try self.event_bytes.appendSlice(self.allocator, value);
    }

    fn appendCodepoint(self: *Cursor, value: u21) AdvanceError!void {
        var encoded: [4]u8 = undefined;
        try self.appendEventSlice(encodeChar(value, &encoded) orelse return self.malformed(.invalid_character));
    }

    // Callers check the chunk has room first, so text ends a chunk instead of failing.
    fn appendTextCodepoint(self: *Cursor, value: u21) AdvanceError!void {
        var encoded: [4]u8 = undefined;
        const bytes = encodeChar(value, &encoded) orelse return self.malformed(.invalid_character);
        std.debug.assert(bytes.len <= TEXT_CHUNK_BYTES - self.text_bytes.items.len);
        try self.text_bytes.appendSlice(self.allocator, bytes);
    }

    fn skipWhitespace(self: *Cursor) ParserError!void {
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
            const value = self.source.peekCodepoint() catch |err| return switch (err) {
                error.EndOfStream => {},
                else => |other| other,
            };
            if (!isXmlWhitespace(value.value)) return;
            _ = try self.requiredCodepoint();
        }
    }

    fn parseQName(self: *Cursor) ParserError!NameRange {
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
            const value = try self.requiredCodepoint();
            if (value.value > 0x7F) return self.malformed(.invalid_name);
            const byte: u8 = @intCast(value.value);
            if (!have_character) {
                if (!isAsciiNameStart(byte)) return self.malformed(.invalid_name);
                have_character = true;
                segment_start = false;
                try self.appendEventByte(byte);
                continue;
            }
            if (byte == ':') {
                if (prefix_len != 0 or segment_start) return self.malformed(.invalid_name);
                prefix_len = self.event_bytes.items.len - start;
                segment_start = true;
                try self.appendEventByte(byte);
                continue;
            }
            if (segment_start) {
                if (!isAsciiNameStart(byte)) return self.malformed(.invalid_name);
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
            return self.malformed(.invalid_name);
        }
        return .{ .start = start, .len = self.event_bytes.items.len - start, .prefix_len = prefix_len };
    }

    fn parseAttributeValue(self: *Cursor, quote: u21) ParserError!Range {
        const start = self.event_bytes.items.len;
        while (true) {
            if (try self.source.peekSingleByte()) |bytes| {
                const bound = @min(bytes.len, self.max_attribute_bytes -| self.event_bytes.items.len);
                const length = ordinaryAttributeRun(bytes[0..bound], @intCast(quote));
                if (length != 0) {
                    try self.appendEventSlice(bytes[0..length]);
                    self.source.borrowed_len = length;
                    try self.source.commitBorrowed();
                    continue;
                }
            }
            const value = try self.requiredCodepoint();
            if (value.value == quote) break;
            if (value.value == '<') return self.malformed(.less_than_in_attribute);
            if (value.value == '&') {
                try self.appendCodepoint(try self.readEntity());
                continue;
            }
            if (value.value == '\r' or value.value == '\n' or value.value == '\t') {
                if (value.value == '\r') try self.skipLineFeed();
                try self.appendEventByte(' ');
            } else {
                try self.appendCodepoint(value.value);
            }
        }
        return .{ .start = start, .len = self.event_bytes.items.len - start };
    }

    // Digits stream, so any number of leading zeros is accepted.
    fn readEntity(self: *Cursor) AdvanceError!u21 {
        const start = self.source.last_start;
        const first = (try self.requiredCodepoint()).value;
        if (first != '#') {
            var name: [4]u8 = undefined;
            var length: usize = 0;
            var value = first;
            while (value != ';') : (value = (try self.requiredCodepoint()).value) {
                if (value > 0x7F or length == name.len) return self.malformedAt(.unknown_entity, start);
                name[length] = @intCast(value);
                length += 1;
            }
            const entities = [_]struct { []const u8, u21 }{
                .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "apos", '\'' }, .{ "quot", '"' },
            };
            for (entities) |entity| {
                if (std.mem.eql(u8, name[0..length], entity[0])) return entity[1];
            }
            return self.malformedAt(.unknown_entity, start);
        }

        var value = (try self.requiredCodepoint()).value;
        var base: u32 = 10;
        if (value == 'x') {
            base = 16;
            value = (try self.requiredCodepoint()).value;
        }
        var number: u32 = 0;
        var digits: usize = 0;
        while (value != ';') : (value = (try self.requiredCodepoint()).value) {
            if (value > 0x7F) return self.malformedAt(.invalid_character_reference, start);
            const digit = digitValue(@intCast(value), base) orelse return self.malformedAt(.invalid_character_reference, start);
            number = number * base + digit;
            if (number > 0x10FFFF) return self.malformedAt(.invalid_character_reference, start);
            digits += 1;
        }
        if (digits == 0 or !isXmlChar(@intCast(number))) return self.malformedAt(.invalid_character_reference, start);
        return @intCast(number);
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

    fn readBufferedStartElement(self: *Cursor, start_offset: u64) AdvanceError!?Event {
        if (!self.source.bytesAreCharacters()) return null;
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
                .offset = self.source.position + name.start,
            });
        }

        const name_offset = self.source.position;
        const end = std.math.add(u64, self.source.position, position) catch return null;
        reader.toss(position);
        self.source.position = end;
        return try self.finishStartElement(bytes, start_offset, name_offset, name_range, empty);
    }

    fn readStartElement(self: *Cursor, start_offset: u64) ParserError!Event {
        self.event_bytes.clearRetainingCapacity();
        self.attribute_ranges.clearRetainingCapacity();
        self.namespace_declarations.clearRetainingCapacity();
        self.attributes.clearRetainingCapacity();
        const name_offset = self.source.currentOffset();
        const name_range = try self.parseQName();
        var empty = false;

        while (true) {
            try self.skipWhitespace();
            const marker = try self.requiredCodepoint();
            if (marker.value == '>') break;
            if (marker.value == '/') {
                const close = try self.requiredCodepoint();
                if (close.value != '>') return self.malformed(.malformed_tag);
                empty = true;
                break;
            }
            try self.source.unread(marker);

            if (self.attribute_ranges.items.len == self.max_attributes) return self.limitError(.attributes);
            const attribute_offset = self.source.currentOffset();
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
                if (equals.value != '=') return self.malformed(.malformed_tag);
                try self.skipWhitespace();
                const value = try self.requiredCodepoint();
                if (value.value != '\'' and value.value != '"') return self.malformed(.malformed_tag);
                break :opening value.value;
            };
            const attribute_value = try self.parseAttributeValue(quote);
            if (self.hasAttribute(self.event_bytes.items, attribute_name)) return self.malformedAt(.duplicate_attribute, attribute_offset);
            const raw_name = self.event_bytes.items[attribute_name.start..][0..attribute_name.len];
            const namespace_declaration = std.mem.eql(u8, raw_name, "xmlns") or
                (std.mem.startsWith(u8, raw_name, "xmlns:") and raw_name.len > 6);
            if (namespace_declaration) {
                const prefix = if (std.mem.eql(u8, raw_name, "xmlns"))
                    Range{ .start = attribute_name.start, .len = 0 }
                else
                    Range{ .start = attribute_name.start + 6, .len = attribute_name.len - 6 };
                try self.namespace_declarations.append(
                    self.allocator,
                    .{ .prefix = prefix, .uri = attribute_value, .offset = attribute_offset },
                );
            }
            try self.attribute_ranges.append(self.allocator, .{
                .name = attribute_name,
                .value = attribute_value,
                .namespace_declaration = namespace_declaration,
                .offset = attribute_offset,
            });
        }

        return self.finishStartElement(self.event_bytes.items, start_offset, name_offset, name_range, empty);
    }

    fn finishStartElement(
        self: *Cursor,
        bytes: []const u8,
        start_offset: u64,
        name_offset: u64,
        name_range: NameRange,
        empty: bool,
    ) AdvanceError!Event {
        if (self.depth == 0) {
            if (self.root_closed) return self.malformedAt(.content_after_root, start_offset);
            self.root_seen = true;
        }
        if (self.depth == MAX_DEPTH) return self.limitError(.depth);

        const binding_start = self.namespace_bindings.items.len;
        const namespace_bytes_start = self.namespace_bytes.items.len;
        try self.installNamespaces();
        const element_name = try self.makeName(bytes, name_range, false, name_offset);

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
            const attribute_name = try self.makeName(bytes, attribute_range.name, true, attribute_range.offset);
            const expanded = attribute_name.expanded;
            // Raw names are unique by now and an unprefixed name has no namespace, so only two
            // prefixed names can expand to the same name.
            if (expanded.prefix != null) for (self.attributes.items) |previous| {
                if (previous.name.expanded.prefix != null and previous.name.eql(expanded.namespace_uri, expanded.local))
                    return self.malformedAt(.duplicate_attribute, attribute_range.offset);
            };
            self.attributes.appendAssumeCapacity(.{
                .name = attribute_name,
                .value = bytes[attribute_range.value.start..][0..attribute_range.value.len],
                .offset = attribute_range.offset,
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

    // Raw attribute names are unique, so each prefix is declared once per element.
    fn installNamespaces(self: *Cursor) AdvanceError!void {
        if (self.namespace_declarations.items.len != 0) self.scopeChanged();
        for (self.namespace_declarations.items) |declaration| {
            const prefix = self.event_bytes.items[declaration.prefix.start..][0..declaration.prefix.len];
            const uri = self.event_bytes.items[declaration.uri.start..][0..declaration.uri.len];
            if (std.mem.eql(u8, prefix, "xmlns")) return self.malformedAt(.invalid_namespace_declaration, declaration.offset);
            if (std.mem.eql(u8, prefix, "xml")) {
                if (!std.mem.eql(u8, uri, XML_NAMESPACE)) return self.malformedAt(.invalid_namespace_declaration, declaration.offset);
            } else if (std.mem.eql(u8, uri, XML_NAMESPACE)) {
                return self.malformedAt(.invalid_namespace_declaration, declaration.offset);
            }
            if (std.mem.eql(u8, uri, XMLNS_NAMESPACE)) return self.malformedAt(.invalid_namespace_declaration, declaration.offset);
            if (prefix.len != 0 and uri.len == 0) return self.malformedAt(.invalid_namespace_declaration, declaration.offset);
            try self.namespace_bindings.ensureUnusedCapacity(self.allocator, 1);
            const shadows = self.bindingIndex(prefix);
            const prefix_start = self.namespace_bytes.items.len;
            try self.namespace_bytes.appendSlice(self.allocator, prefix);
            const uri_start = self.namespace_bytes.items.len;
            try self.namespace_bytes.appendSlice(self.allocator, uri);
            if (shadows) |index| self.namespace_bindings.items[index].shadowed = true;
            self.namespace_bindings.appendAssumeCapacity(.{
                .prefix_start = prefix_start,
                .prefix_len = prefix.len,
                .uri_start = uri_start,
                .uri_len = uri.len,
                .shadows = shadows,
            });
        }
    }

    // xmlns="" undeclares the default namespace: no namespace, as when none is bound.
    fn defaultNamespace(self: *const Cursor) ?[]const u8 {
        const uri = self.resolveNamespace(null) orelse return null;
        return if (uri.len == 0) null else uri;
    }

    fn bindingIndex(self: *const Cursor, prefix: []const u8) ?usize {
        var index = self.namespace_bindings.items.len;
        while (index != 0) {
            index -= 1;
            const binding = self.namespace_bindings.items[index];
            if (std.mem.eql(u8, self.namespace_bytes.items[binding.prefix_start..][0..binding.prefix_len], prefix)) return index;
        }
        return null;
    }

    // Drops the bindings from length on, showing again the ones they hid.
    fn truncateBindings(self: *Cursor, length: usize) void {
        var index = self.namespace_bindings.items.len;
        while (index > length) {
            index -= 1;
            if (self.namespace_bindings.items[index].shadows) |hidden| self.namespace_bindings.items[hidden].shadowed = false;
        }
        self.namespace_bindings.items.len = length;
    }

    fn resolveNamespace(self: *const Cursor, prefix: ?[]const u8) ?[]const u8 {
        if (prefix) |value| if (std.mem.eql(u8, value, "xml")) return XML_NAMESPACE;
        const binding = self.namespace_bindings.items[self.bindingIndex(prefix orelse "") orelse return null];
        return self.namespace_bytes.items[binding.uri_start..][0..binding.uri_len];
    }

    // An unprefixed attribute has no namespace; an unprefixed element has the default one.
    fn makeName(self: *Cursor, bytes: []const u8, range: NameRange, comptime attribute: bool, offset: u64) AdvanceError!Name {
        const raw = bytes[range.start..][0..range.len];
        const prefix = if (range.prefix_len == 0) null else raw[0..range.prefix_len];
        const local = if (range.prefix_len == 0) raw else raw[range.prefix_len + 1 ..];
        const namespace_uri = if (prefix) |value|
            self.resolveNamespace(value) orelse return self.malformedAt(.unbound_prefix, offset)
        else if (attribute) null else self.defaultNamespace();
        return .{ .raw = raw, .expanded = .{
            .prefix = prefix,
            .local = local,
            .namespace_uri = namespace_uri,
        } };
    }

    fn scopeChanged(self: *Cursor) void {
        self.additional_namespaces = null;
        self.namespace_scope +%= 1;
    }

    fn popFrame(self: *Cursor, frame: Frame) void {
        self.depth -= 1;
        self.open_names.items.len = frame.name_start;
        if (self.namespace_bindings.items.len != frame.binding_start) {
            self.scopeChanged();
            self.truncateBindings(frame.binding_start);
        }
        self.namespace_bytes.items.len = frame.namespace_bytes_start;
        if (self.depth == 0) self.root_closed = true;
    }

    fn readEndElement(self: *Cursor, start_offset: u64) ParserError!Event {
        if (self.depth == 0) return self.malformedAt(.mismatched_end_tag, start_offset);
        const frame = self.frames[self.depth - 1];
        const expected = self.open_names.items[frame.name_start..][0..frame.name_len];
        if (self.source.bytesAreCharacters()) if (self.source.reader) |reader| {
            // The open element's name and `>` already in the buffer close it in place; every
            // other shape, including whitespace before `>`, takes the checked path below.
            const bytes = reader.buffered();
            if (bytes.len > expected.len and bytes[expected.len] == '>' and std.mem.eql(u8, bytes[0..expected.len], expected)) {
                const name_offset = self.source.position;
                reader.toss(expected.len + 1);
                try self.source.addPosition(expected.len + 1);
                // As for a synthetic end, the open name's bytes outlive this event.
                const name = try self.makeName(
                    self.open_names.items,
                    .{ .start = frame.name_start, .len = frame.name_len, .prefix_len = frame.prefix_len },
                    false,
                    name_offset,
                );
                self.popFrame(frame);
                return .{
                    .span = .{ .start = start_offset, .end = self.source.position },
                    .data = .{ .end_element = .{ .name = name } },
                };
            }
        };
        const name_offset = self.source.currentOffset();
        const name_range = try self.parseQName();
        try self.skipWhitespace();
        const close = try self.requiredCodepoint();
        if (close.value != '>') return self.malformed(.malformed_tag);
        const raw = self.event_bytes.items[name_range.start..][0..name_range.len];
        if (!std.mem.eql(u8, raw, expected)) return self.malformedAt(.mismatched_end_tag, start_offset);
        const name = try self.makeName(self.event_bytes.items, name_range, false, name_offset);
        self.popFrame(frame);
        return .{
            .span = .{ .start = start_offset, .end = self.source.position },
            .data = .{ .end_element = .{ .name = name } },
        };
    }

    fn syntheticEnd(self: *Cursor) AdvanceError!Event {
        std.debug.assert(self.pending_empty and self.depth != 0);
        const frame = self.frames[self.depth - 1];
        // The open name's bytes stay in place after the pop until the next start tag, which is
        // after this event's lifetime.
        const name = try self.makeName(
            self.open_names.items,
            .{ .start = frame.name_start, .len = frame.name_len, .prefix_len = frame.prefix_len },
            false,
            frame.opening_end,
        );
        self.pending_empty = false;
        self.popFrame(frame);
        return .{
            .span = .{ .start = frame.opening_end, .end = frame.opening_end },
            .data = .{ .end_element = .{ .name = name } },
        };
    }

    // Null when markup or the end of input comes before any text.
    fn readScalarText(self: *Cursor) ParserError!?Event {
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
                else => |other| return other,
            };
            if (value.value == '<') break;
            if (value.value == '&') {
                if (self.text_bytes.items.len != 0) break;
                _ = try self.requiredCodepoint();
                try self.appendTextCodepoint(try self.readEntity());
                self.normal_text_brackets = 0;
                continue;
            }
            const encoded_len = std.unicode.utf8CodepointSequenceLength(value.value) catch return self.malformed(.invalid_character);
            if (encoded_len > TEXT_CHUNK_BYTES - self.text_bytes.items.len) break;
            _ = try self.requiredCodepoint();
            if (value.value == ']') {
                if (self.normal_text_brackets < 2) self.normal_text_brackets += 1;
                try self.appendTextCodepoint(value.value);
            } else if (value.value == '>' and self.normal_text_brackets == 2) {
                return self.malformedAt(.malformed_markup, value.start - 2 * self.source.unitWidth());
            } else if (value.value == '\r') {
                self.normal_text_brackets = 0;
                try self.skipLineFeed();
                try self.appendTextCodepoint('\n');
            } else {
                self.normal_text_brackets = 0;
                try self.appendTextCodepoint(value.value);
            }
        }
        if (self.text_bytes.items.len == 0) return null;
        return .{
            .span = .{ .start = start, .end = self.source.currentOffset() },
            .data = .{ .text = .{ .bytes = self.text_bytes.items } },
        };
    }

    fn readCdataStart(self: *Cursor, start_offset: u64) AdvanceError!void {
        if (self.depth == 0) return self.malformedAt(.malformed_markup, start_offset);
        for ("CDATA[") |expected| {
            const value = try self.requiredCodepoint();
            if (value.value != expected) return self.malformed(.malformed_markup);
        }
        self.in_cdata = true;
        self.cdata_brackets = 0;
    }

    // Null when the section closes with no text left in it.
    fn readCdataText(self: *Cursor) ParserError!?Event {
        const start = self.source.currentOffset();
        while (self.text_bytes.items.len < TEXT_CHUNK_BYTES) {
            const value = self.source.peekCodepoint() catch |err| switch (err) {
                error.EndOfStream => return self.malformed(.unexpected_end),
                else => |other| return other,
            };
            const output_length = if (value.value == ']')
                if (self.cdata_brackets == 2) @as(usize, 1) else 0
            else if (value.value == '>' and self.cdata_brackets == 2)
                0
            else
                (if (value.value == '\r') 1 else std.unicode.utf8CodepointSequenceLength(value.value) catch
                    return self.malformed(.invalid_character)) + @as(usize, self.cdata_brackets);
            if (output_length > TEXT_CHUNK_BYTES - self.text_bytes.items.len) break;
            _ = try self.source.readCodepoint();
            if (value.value == ']') {
                if (self.cdata_brackets < 2) {
                    self.cdata_brackets += 1;
                } else {
                    try self.appendTextCodepoint(']');
                }
                continue;
            }
            if (value.value == '>' and self.cdata_brackets == 2) {
                self.cdata_brackets = 0;
                self.in_cdata = false;
                break;
            }
            while (self.cdata_brackets != 0) : (self.cdata_brackets -= 1) {
                try self.appendTextCodepoint(']');
            }
            if (value.value == '\r') {
                try self.skipLineFeed();
                try self.appendTextCodepoint('\n');
            } else {
                try self.appendTextCodepoint(value.value);
            }
        }
        if (self.text_bytes.items.len == 0) return null;
        return .{
            .span = .{ .start = start, .end = self.source.currentOffset() },
            .data = .{ .text = .{ .bytes = self.text_bytes.items } },
        };
    }

    fn readComment(self: *Cursor) AdvanceError!void {
        var dashes: u2 = 0;
        while (true) {
            const value = try self.requiredCodepoint();
            if (value.value == '-') {
                if (dashes == 1) {
                    const close = try self.requiredCodepoint();
                    if (close.value != '>') return self.malformed(.malformed_markup);
                    return;
                }
                dashes = 1;
            } else {
                dashes = 0;
                if (!isXmlChar(value.value)) return self.malformed(.invalid_character);
            }
        }
    }

    fn readProcessingInstruction(self: *Cursor, initial: bool) ParserError!void {
        self.event_bytes.clearRetainingCapacity();
        const target_offset = self.source.currentOffset();
        const target = try self.parseQName();
        const target_bytes = self.event_bytes.items[target.start..][0..target.len];
        const separator = try self.requiredCodepoint();
        if (!isXmlWhitespace(separator.value) and separator.value != '?') return self.malformed(.malformed_markup);
        const declaration = initial and std.mem.eql(u8, target_bytes, "xml");
        if (std.ascii.eqlIgnoreCase(target_bytes, "xml") and !declaration) return self.malformedAt(.malformed_markup, target_offset);
        self.declaration_bytes.clearRetainingCapacity();
        self.declaration_start = self.source.currentOffset();
        if (separator.value == '?') {
            const close = try self.requiredCodepoint();
            if (close.value != '>') return self.malformed(.malformed_markup);
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
                if (!isXmlChar(value.value)) return self.malformed(.invalid_character);
                if (declaration) {
                    if (value.value > 0x7F) return self.malformed(.malformed_declaration);
                    try self.appendDeclarationByte(@intCast(value.value));
                }
            }
        }
        if (declaration) try self.parseXmlDeclaration();
    }

    fn appendDeclarationByte(self: *Cursor, value: u8) AdvanceError!void {
        if (self.declaration_bytes.items.len == MAX_DECLARATION_BYTES) return self.limitError(.declaration_bytes);
        try self.declaration_bytes.append(self.allocator, value);
    }

    // The rule's offending character is the last one read, except at the end of input.
    fn malformed(self: *Cursor, rule: Rule) AdvanceError {
        return self.malformedAt(rule, if (rule == .unexpected_end) self.source.currentOffset() else self.source.last_start);
    }

    fn malformedAt(self: *Cursor, rule: Rule, offset: u64) AdvanceError {
        self.xml_rule = rule;
        self.failure_offset = offset;
        self.offset = offset;
        return error.InvalidXml;
    }

    // Declaration bytes are ASCII, one character each.
    fn declarationError(self: *Cursor, position: usize, err: AdvanceError) AdvanceError {
        const offset = self.declaration_start + position * self.source.unitWidth();
        if (err == error.InvalidXml) return self.malformedAt(.malformed_declaration, offset);
        self.failure_offset = offset;
        self.offset = offset;
        return err;
    }

    // A failure's offset: the offending character for broken rules and encodings, otherwise
    // the next unread byte.
    fn failedAt(self: *const Cursor, err: ParserError) u64 {
        if (self.failure_offset) |offset| return offset;
        if (err == error.InvalidEncoding) return self.source.last_start;
        return self.source.currentOffset();
    }

    fn limitError(self: *Cursor, limit: @TypeOf(self.limit_failure.?)) AdvanceError {
        self.limit_failure = limit;
        return error.LimitExceeded;
    }

    fn parseXmlDeclaration(self: *Cursor) AdvanceError!void {
        const bytes = self.declaration_bytes.items;
        var position: usize = 0;
        var version: ?[]const u8 = null;
        var version_at: usize = 0;
        var encoding: ?[]const u8 = null;
        var encoding_at: usize = 0;
        var order: u2 = 0;
        while (position < bytes.len and isXmlWhitespace(bytes[position])) position += 1;
        while (true) {
            if (position == bytes.len) break;
            const name_start = position;
            if (!isAsciiNameStart(bytes[position])) return self.declarationError(position, error.InvalidXml);
            position += 1;
            while (position < bytes.len and isAsciiNameChar(bytes[position])) position += 1;
            const name = bytes[name_start..position];
            while (position < bytes.len and isXmlWhitespace(bytes[position])) position += 1;
            if (position == bytes.len or bytes[position] != '=') return self.declarationError(position, error.InvalidXml);
            position += 1;
            while (position < bytes.len and isXmlWhitespace(bytes[position])) position += 1;
            if (position == bytes.len) return self.declarationError(position, error.InvalidXml);
            const quote = bytes[position];
            if (quote != '\'' and quote != '"') return self.declarationError(position, error.InvalidXml);
            position += 1;
            const value_start = position;
            while (position < bytes.len and bytes[position] != quote) position += 1;
            if (position == bytes.len) return self.declarationError(position, error.InvalidXml);
            const value = bytes[value_start..position];
            position += 1;
            if (std.mem.eql(u8, name, "version")) {
                if (version != null or order != 0) return self.declarationError(name_start, error.InvalidXml);
                version = value;
                version_at = value_start;
            } else if (std.mem.eql(u8, name, "encoding")) {
                if (version == null or encoding != null or order > 0) return self.declarationError(name_start, error.InvalidXml);
                encoding = value;
                encoding_at = value_start;
                order = 1;
            } else if (std.mem.eql(u8, name, "standalone")) {
                if (version == null or order > 1) return self.declarationError(name_start, error.InvalidXml);
                if (!std.mem.eql(u8, value, "yes") and !std.mem.eql(u8, value, "no"))
                    return self.declarationError(value_start, error.InvalidXml);
                order = 2;
            } else {
                return self.declarationError(name_start, error.InvalidXml);
            }
            if (position == bytes.len) break;
            if (!isXmlWhitespace(bytes[position])) return self.declarationError(position, error.InvalidXml);
            while (position < bytes.len and isXmlWhitespace(bytes[position])) position += 1;
        }
        const version_value = version orelse return self.declarationError(0, error.InvalidXml);
        if (!std.mem.eql(u8, version_value, "1.0")) return self.declarationError(version_at, error.UnsupportedVersion);
        if (encoding) |value| {
            if (std.ascii.eqlIgnoreCase(value, "UTF-8")) {
                if (self.source.encoding != .utf8) return self.declarationError(encoding_at, error.InvalidEncoding);
            } else if (std.ascii.eqlIgnoreCase(value, "UTF-16")) {
                if (self.source.encoding != .utf16_le and self.source.encoding != .utf16_be)
                    return self.declarationError(encoding_at, error.InvalidEncoding);
            } else if (std.ascii.eqlIgnoreCase(value, "ISO-8859-1") or
                std.ascii.eqlIgnoreCase(value, "US-ASCII") or std.ascii.eqlIgnoreCase(value, "ASCII"))
            {
                const bom = std.mem.startsWith(u8, self.source.probe[0..self.source.probe_len], "\xef\xbb\xbf");
                if (self.source.encoding != .utf8 or bom) return self.declarationError(encoding_at, error.InvalidEncoding);
                // Seven-bit text is read as is; a byte at or above 0x80 is an encoding error.
                self.source.encoding = if (std.ascii.eqlIgnoreCase(value, "ISO-8859-1")) .latin1 else .ascii;
            } else {
                return self.declarationError(encoding_at, error.UnsupportedEncoding);
            }
        }
    }
};

const XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace";
const TEXT_CHUNK_BYTES = 64 * 1024;

const ParserError = AdvanceError || error{EndOfStream};

const EventData = union(enum) {
    start_element: StartElement,
    end_element: EndElement,
    text: Text,
};

const Encoding = enum {
    utf8,
    latin1,
    ascii,
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
};

fn optionalSliceEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn isXmlWhitespace(value: u21) bool {
    return value == ' ' or value == '\t' or value == '\r' or value == '\n';
}

fn isXmlWhitespaceRun(bytes: []const u8) bool {
    for (bytes) |byte| if (!isXmlWhitespace(byte)) return false;
    return true;
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
    return NAME_CHARS[value];
}

// One table entry per byte, so a name scan tests each byte once instead of by ranges.
const NAME_CHARS = blk: {
    var table: [256]bool = @splat(false);
    for (0..256) |byte| table[byte] = isAsciiNameStart(byte) or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.';
    break :blk table;
};

fn isNameDelimiter(value: u21) bool {
    return isXmlWhitespace(value) or value == '/' or value == '>' or value == '=' or value == '?';
}

// Text runs are long (Base64), so they scan 32 bytes at a time; attribute values are short.
fn ordinaryTextRun(bytes: []const u8, limit: usize) usize {
    return ordinaryRun(32, bytes[0..@min(bytes.len, limit)], .{ '<', '&', ']' });
}

fn ordinaryAttributeRun(bytes: []const u8, quote: u8) usize {
    return ordinaryRun(16, bytes, .{ quote, '&', '<' });
}

fn ordinaryRun(comptime max_width: usize, bytes: []const u8, stops: [3]u8) usize {
    const width = @min(max_width, std.simd.suggestVectorLength(u8) orelse 16);
    const Vector = @Vector(width, u8);
    var length: usize = 0;
    while (bytes.len - length >= width) {
        const run: Vector = bytes[length..][0..width].*;
        var exceptional = (run < @as(Vector, @splat(0x20))) | (run >= @as(Vector, @splat(0x80)));
        inline for (stops) |stop| exceptional |= run == @as(Vector, @splat(stop));
        // A lane mask finds the first exceptional byte with one bit count, where std.simd.firstTrue
        // takes a horizontal minimum.
        const mask: std.meta.Int(.unsigned, width) = @bitCast(exceptional);
        if (mask != 0) return length + @ctz(mask);
        length += width;
    }
    while (length < bytes.len) : (length += 1) {
        const byte = bytes[length];
        if (byte < 0x20 or byte >= 0x80 or byte == stops[0] or byte == stops[1] or byte == stops[2]) break;
    }
    return length;
}

const Source = struct {
    reader: ?*std.Io.Reader,
    detected: bool = false,
    detection_failure: ?AdvanceError = null,
    probe: [4]u8 = undefined,
    probe_len: usize = 0,
    probe_pos: usize = 0,
    encoding: Encoding = .utf8,
    position: u64 = 0,
    pending: [4]Codepoint = undefined,
    pending_len: usize = 0,
    borrowed_len: usize = 0,
    // Start of the last codepoint read or peeked, including one that failed to decode.
    last_start: u64 = 0,

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

    fn addPosition(self: *Source, amount: usize) AdvanceError!void {
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
            else => |other| other,
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
            self.last_start = value.start;
            return value;
        }

        try self.ensureDetected();
        const start = self.position;
        self.last_start = start;
        if (self.encoding == .utf16_le or self.encoding == .utf16_be) {
            const unit = try self.readUtf16Unit();
            if (unit >= 0xD800 and unit <= 0xDBFF) {
                const next_start = self.position;
                const next = self.readUtf16Unit() catch |err| return self.brokenAt(next_start, err);
                if (next < 0xDC00 or next > 0xDFFF) return self.brokenAt(next_start, error.InvalidEncoding);
                const value: u21 = 0x10000 +
                    (@as(u21, unit - 0xD800) << 10) +
                    @as(u21, next - 0xDC00);
                return .{ .value = value, .start = start };
            }
            if (unit >= 0xDC00 and unit <= 0xDFFF) return error.InvalidEncoding;
            return .{ .value = unit, .start = start };
        }

        const first = try self.readByte();
        if (first < 0x80 or self.encoding == .latin1) return .{ .value = first, .start = start };
        if (self.encoding == .ascii) return self.brokenAt(start, error.InvalidEncoding);
        // Unicode's well-formed sequences: the first byte sets the length and the second byte's
        // range, so a failure is reported at the first byte that cannot continue the sequence.
        const length: u3, const low: u8, const high: u8 = switch (first) {
            0xC2...0xDF => .{ 2, 0x80, 0xBF },
            0xE0 => .{ 3, 0xA0, 0xBF },
            0xE1...0xEC, 0xEE, 0xEF => .{ 3, 0x80, 0xBF },
            0xED => .{ 3, 0x80, 0x9F },
            0xF0 => .{ 4, 0x90, 0xBF },
            0xF1...0xF3 => .{ 4, 0x80, 0xBF },
            0xF4 => .{ 4, 0x80, 0x8F },
            else => return error.InvalidEncoding,
        };
        var value: u21 = first & (@as(u8, 0x7F) >> length);
        for (1..length) |index| {
            const byte_start = self.position;
            const byte = self.readByte() catch |err| return self.brokenAt(byte_start, err);
            if (byte < (if (index == 1) low else 0x80) or byte > (if (index == 1) high else 0xBF))
                return self.brokenAt(byte_start, error.InvalidEncoding);
            value = (value << 6) | (byte & 0x3F);
        }
        return .{ .value = value, .start = start };
    }

    // A sequence broken at offset, or cut off there by the end of input.
    fn brokenAt(self: *Source, offset: u64, err: ParserError) ParserError {
        if (err != error.EndOfStream and err != error.InvalidEncoding) return err;
        self.last_start = offset;
        return error.InvalidEncoding;
    }

    fn unread(self: *Source, value: Codepoint) AdvanceError!void {
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

    // Bytes per ASCII character.
    fn unitWidth(self: *const Source) u64 {
        return if (self.encoding == .utf16_le or self.encoding == .utf16_be) 2 else 1;
    }

    fn commitBorrowed(self: *Source) AdvanceError!void {
        if (self.borrowed_len == 0) return;
        // Borrowed bytes come from the reader's buffer, so a reader is present.
        const reader = self.reader.?;
        reader.toss(self.borrowed_len);
        try self.addPosition(self.borrowed_len);
        self.borrowed_len = 0;
    }

    // Whether the reader's buffered bytes are the next characters, one byte each, so they
    // can be scanned directly.
    fn bytesAreCharacters(self: *const Source) bool {
        return (self.encoding == .utf8 or self.encoding == .latin1 or self.encoding == .ascii) and
            self.probe_pos == self.probe_len and self.pending_len == 0;
    }

    fn peekSingleByte(self: *Source) ParserError!?[]const u8 {
        try self.ensureDetected();
        if (!self.bytesAreCharacters()) return null;
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
    offset: u64,
};

const NamespaceDeclaration = struct {
    prefix: Range,
    uri: Range,
    offset: u64,
};

const NamespaceBinding = struct {
    prefix_start: usize,
    prefix_len: usize,
    uri_start: usize,
    uri_len: usize,
    // The cursor marks a binding that a later declaration of its prefix hides, and records in
    // that declaration which binding it hid, so listing bindings needs no prefix lookup.
    shadowed: bool = false,
    shadows: ?usize = null,
};

const Frame = struct {
    name_start: usize,
    name_len: usize,
    prefix_len: usize,
    binding_start: usize,
    namespace_bytes_start: usize,
    opening_end: u64,
};

fn encodeChar(value: u21, buffer: *[4]u8) ?[]const u8 {
    if (!isXmlChar(value)) return null;
    return buffer[0 .. std.unicode.utf8Encode(value, buffer) catch return null];
}

fn digitValue(value: u8, base: u32) ?u32 {
    const digit: u32 = if (value >= '0' and value <= '9')
        value - '0'
    else if (value >= 'a' and value <= 'f')
        value - 'a' + 10
    else if (value >= 'A' and value <= 'F')
        value - 'A' + 10
    else
        return null;
    if (digit >= base) return null;
    return digit;
}

// --- XML writing ---

pub const WriterError = error{
    InvalidState,
    OverlappingBuffers,
    InvalidName,
    InvalidCharacter,
    InvalidNamespace,
    DuplicateAttribute,
    LimitExceeded,
    WriteFailed,
    OutOfMemory,
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    sink: *std.Io.Writer,
    // A writer the sink drains into, such as a hashing sink's destination. Written bytes may
    // overlap neither its buffer nor the sink's, read at each write since either can grow.
    guard: ?*const std.Io.Writer = null,
    state: WriterState = .initial,
    failure: ?WriterError = null,
    logical_offset: u64 = 0,
    offset_valid: bool = true,
    root_written: bool = false,
    frames: [MAX_DEPTH]WriterFrame = undefined,
    frame_count: usize = 0,
    open_names: std.ArrayList(u8) = .empty,
    attribute_names: std.ArrayList(u8) = .empty,
    // In-scope declarations, innermost last, so a lookup searches backward and stops early.
    namespace_bindings: std.ArrayList(NamespaceBinding) = .empty,
    namespace_bytes: std.ArrayList(u8) = .empty,
    text_brackets: u2 = 0,
    // Binary bytes waiting for a whole Base64 group between binaryPart calls.
    binary_carry: [3]u8 = undefined,
    binary_carry_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, sink: *std.Io.Writer, options: struct { fragment: bool = false }) Writer {
        return .{ .allocator = allocator, .sink = sink, .state = if (options.fragment) .epilog else .initial };
    }

    pub fn deinit(self: *Writer) void {
        self.open_names.deinit(self.allocator);
        self.attribute_names.deinit(self.allocator);
        self.namespace_bindings.deinit(self.allocator);
        self.namespace_bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn overlapsOutput(self: *const Writer, bytes: []const u8) bool {
        const guard = if (self.guard) |writer| writer.buffer else &.{};
        return overlaps(self.sink.buffer, bytes) or overlaps(guard, bytes);
    }

    // Null after a write failure.
    pub fn byteOffset(self: *const Writer) ?u64 {
        if (!self.offset_valid) return null;
        return self.logical_offset;
    }

    pub fn startDocument(self: *Writer) WriterError!void {
        try self.check(.initial);
        try self.writeBytes("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        self.state = .epilog;
    }

    // Any prefix must have a declaration before the element's content is written.
    pub fn startElement(self: *Writer, name: []const u8) WriterError!void {
        try self.checkInput(name);
        validateQName(name) catch |err| return self.fail(err);
        return self.startElementTrusted(name);
    }

    // For a name the mzML writer supplies from its own tables, which is a valid name and not
    // caller memory, so it skips those two checks.
    pub fn startElementTrusted(self: *Writer, name: []const u8) WriterError!void {
        try self.checkContent();
        if (self.state == .epilog and self.root_written) return self.fail(error.InvalidState);
        if (self.state != .epilog and self.state != .content and self.state != .start_tag) return self.fail(error.InvalidState);
        if (self.frame_count == MAX_DEPTH) return self.fail(error.LimitExceeded);
        if (self.state == .start_tag) {
            try self.checkOpeningName();
            try self.writeByte('>');
        }
        const name_start = self.open_names.items.len;
        self.open_names.appendSlice(self.allocator, name) catch return self.fail(error.OutOfMemory);
        self.frames[self.frame_count] = .{
            .name_start = name_start,
            .name_len = name.len,
            .attribute_start = self.attribute_names.items.len,
            .binding_start = self.namespace_bindings.items.len,
            .namespace_bytes_start = self.namespace_bytes.items.len,
        };
        self.frame_count += 1;
        if (self.frame_count == 1) self.root_written = true;
        self.state = .start_tag;
        try self.writeByte('<');
        try self.writeBytes(name);
    }

    pub fn namespace(self: *Writer, prefix: ?[]const u8, uri: []const u8) WriterError!void {
        try self.check(.start_tag);
        try self.checkInput(prefix orelse "");
        try self.checkInput(uri);
        if (prefix) |value| {
            validateQName(value) catch |err| return self.fail(err);
            if (std.mem.indexOfScalar(u8, value, ':') != null or std.mem.eql(u8, value, "xmlns") or uri.len == 0)
                return self.fail(error.InvalidNamespace);
            if (std.mem.eql(u8, value, "xml") != std.mem.eql(u8, uri, XML_NAMESPACE)) return self.fail(error.InvalidNamespace);
        }
        if (std.mem.eql(u8, uri, XMLNS_NAMESPACE) or (prefix == null and std.mem.eql(u8, uri, XML_NAMESPACE)))
            return self.fail(error.InvalidNamespace);
        const frame = &self.frames[self.frame_count - 1];
        const actual_prefix = prefix orelse "";
        for (self.namespace_bindings.items[frame.binding_start..]) |binding| {
            if (std.mem.eql(u8, self.namespace_bytes.items[binding.prefix_start..][0..binding.prefix_len], actual_prefix))
                return self.fail(error.DuplicateAttribute);
        }
        const prefix_start = self.namespace_bytes.items.len;
        self.namespace_bytes.appendSlice(self.allocator, actual_prefix) catch return self.fail(error.OutOfMemory);
        const uri_start = self.namespace_bytes.items.len;
        self.namespace_bytes.appendSlice(self.allocator, uri) catch return self.fail(error.OutOfMemory);
        self.namespace_bindings.append(self.allocator, .{
            .prefix_start = prefix_start,
            .prefix_len = actual_prefix.len,
            .uri_start = uri_start,
            .uri_len = uri.len,
        }) catch return self.fail(error.OutOfMemory);
        try self.writeByte(' ');
        try self.writeBytes(if (prefix == null) "xmlns=\"" else "xmlns:");
        if (prefix) |value| {
            try self.writeBytes(value);
            try self.writeBytes("=\"");
        }
        try self.writeEscapedAttribute(uri);
        try self.writeByte('"');
    }

    // For an unprefixed name the mzML writer supplies from its own tables (cvParam's fields and
    // the like): a valid name, not caller memory, written before any caller-supplied attribute
    // of the element and once each. With record, a caller's later attribute of the same name is
    // a duplicate; without it the caller promises none follows. The value is checked and
    // escaped as always.
    pub fn attributeTrusted(self: *Writer, name: []const u8, value: []const u8, record: bool) WriterError!void {
        try self.check(.start_tag);
        try self.checkInput(value);
        try self.writeAttribute(name, value, record);
    }

    // Any prefix is resolved in the current namespace bindings.
    pub fn attribute(self: *Writer, name: []const u8, value: []const u8) WriterError!void {
        try self.check(.start_tag);
        try self.checkInput(name);
        try self.checkInput(value);
        validateQName(name) catch |err| return self.fail(err);
        if (std.mem.eql(u8, name, "xmlns") or std.mem.startsWith(u8, name, "xmlns:"))
            return self.fail(error.InvalidNamespace);
        const prefix_end = std.mem.indexOfScalar(u8, name, ':');
        if (prefix_end) |colon| {
            if (self.namespaceUri(name[0..colon]) == null) return self.fail(error.InvalidNamespace);
        }
        const frame = &self.frames[self.frame_count - 1];
        var position = frame.attribute_start;
        while (position < self.attribute_names.items.len) {
            const length = std.mem.bytesToValue(usize, self.attribute_names.items[position..][0..@sizeOf(usize)]);
            position += @sizeOf(usize);
            const end = position + length;
            const previous = self.attribute_names.items[position..end];
            if (std.mem.eql(u8, previous, name) or (prefix_end != null and self.sameAttribute(previous, name, prefix_end.?)))
                return self.fail(error.DuplicateAttribute);
            position = end;
        }
        try self.writeAttribute(name, value, true);
    }

    pub fn text(self: *Writer, value: []const u8) WriterError!void {
        try self.checkContent();
        try self.checkInput(value);
        try self.enterContent();
        try self.writeEscapedText(value);
    }

    pub fn binary(self: *Writer, wire: []const u8) WriterError!void {
        try self.binaryPart(wire);
        try self.binaryEnd();
    }

    // Base64 one piece at a time; binaryEnd closes it. Up to two bytes carry over between
    // pieces, so any split gives the text binary gives for the whole. While bytes carry,
    // startElement, text, and endElement fail with InvalidState.
    pub fn binaryPart(self: *Writer, wire: []const u8) WriterError!void {
        try self.checkAny();
        try self.checkInput(wire);
        try self.enterContent();
        var rest = wire;
        if (self.binary_carry_len != 0) {
            const take = @min(3 - self.binary_carry_len, rest.len);
            @memcpy(self.binary_carry[self.binary_carry_len..][0..take], rest[0..take]);
            self.binary_carry_len += take;
            rest = rest[take..];
            if (self.binary_carry_len < 3) return;
            try self.encodeBase64(&self.binary_carry);
            self.binary_carry_len = 0;
        }
        const whole = rest.len / 3 * 3;
        try self.encodeBase64(rest[0..whole]);
        @memcpy(self.binary_carry[0 .. rest.len - whole], rest[whole..]);
        self.binary_carry_len = rest.len - whole;
    }

    pub fn binaryEnd(self: *Writer) WriterError!void {
        try self.checkAny();
        const length = self.binary_carry_len;
        self.binary_carry_len = 0;
        try self.encodeBase64(self.binary_carry[0..length]);
    }

    pub fn endElement(self: *Writer) WriterError!void {
        try self.checkContent();
        if (self.state != .start_tag and self.state != .content) return self.fail(error.InvalidState);
        // Both states exist only while an element is open.
        std.debug.assert(self.frame_count != 0);
        const frame = self.frames[self.frame_count - 1];
        const name = self.open_names.items[frame.name_start..][0..frame.name_len];
        if (self.state == .start_tag) {
            try self.checkOpeningName();
            try self.writeBytes("/>");
        } else {
            try self.writeBytes("</");
            try self.writeBytes(name);
            try self.writeByte('>');
        }
        self.frame_count -= 1;
        self.open_names.items.len = frame.name_start;
        self.attribute_names.items.len = frame.attribute_start;
        self.namespace_bindings.items.len = frame.binding_start;
        self.namespace_bytes.items.len = frame.namespace_bytes_start;
        self.text_brackets = 0;
        self.state = if (self.frame_count == 0) .epilog else .content;
    }

    pub fn endDocument(self: *Writer) WriterError!void {
        try self.check(.epilog);
        if (!self.root_written) return self.fail(error.InvalidState);
        self.state = .done;
    }

    // "" for the default namespace when none is declared; null for an unbound prefix.
    pub fn namespaceUri(self: *const Writer, prefix: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, prefix, "xml")) return XML_NAMESPACE;
        var index = self.namespace_bindings.items.len;
        while (index != 0) {
            index -= 1;
            const binding = self.namespace_bindings.items[index];
            if (std.mem.eql(u8, self.namespace_bytes.items[binding.prefix_start..][0..binding.prefix_len], prefix))
                return self.namespace_bytes.items[binding.uri_start..][0..binding.uri_len];
        }
        return if (prefix.len == 0) "" else null;
    }

    // Caller bytes are copied into the sink's buffer, so they must not live there.
    fn checkInput(self: *Writer, bytes: []const u8) WriterError!void {
        if (self.overlapsOutput(bytes)) {
            @branchHint(.cold);
            return self.fail(error.OverlappingBuffers);
        }
    }

    // Base64 of whole groups, padded only for a final group shorter than three bytes.
    fn encodeBase64(self: *Writer, wire: []const u8) WriterError!void {
        var encoded: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < wire.len) {
            const available = self.sink.unusedCapacitySlice();
            const direct_length = @min(wire.len - offset, available.len / 4 * 3);
            if (direct_length != 0) {
                const required = base64.encodedSize(direct_length) catch return self.fail(error.LimitExceeded);
                const next = std.math.add(u64, self.logical_offset, @intCast(required)) catch return self.fail(error.LimitExceeded);
                const value = base64.encode(available, wire[offset..][0..direct_length]) catch return self.fail(error.LimitExceeded);
                self.sink.advance(value.len);
                self.logical_offset = next;
                offset += direct_length;
                continue;
            }
            const length = @min(wire.len - offset, encoded.len / 4 * 3);
            // The encoder emits ASCII without XML metacharacters.
            const value = base64.encode(&encoded, wire[offset..][0..length]) catch return self.fail(error.LimitExceeded);
            try self.writeBytes(value);
            offset += length;
        }
        if (wire.len != 0) self.text_brackets = 0;
    }

    fn check(self: *Writer, expected: WriterState) WriterError!void {
        try self.checkAny();
        if (self.state != expected) return self.fail(error.InvalidState);
    }

    fn checkAny(self: *Writer) WriterError!void {
        if (self.failure) |failure| return failure;
    }

    // Other content would split a Base64 group that binaryPart left open.
    fn checkContent(self: *Writer) WriterError!void {
        try self.checkAny();
        if (self.binary_carry_len != 0) return self.fail(error.InvalidState);
    }

    fn enterContent(self: *Writer) WriterError!void {
        if (self.state != .start_tag and self.state != .content) return self.fail(error.InvalidState);
        if (self.state != .start_tag) return;
        try self.checkOpeningName();
        try self.writeByte('>');
        self.state = .content;
    }

    fn checkOpeningName(self: *Writer) WriterError!void {
        const frame = self.frames[self.frame_count - 1];
        const name = self.open_names.items[frame.name_start..][0..frame.name_len];
        if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
            if (self.namespaceUri(name[0..colon]) == null) return self.fail(error.InvalidNamespace);
        }
    }

    fn writeAttribute(self: *Writer, name: []const u8, value: []const u8, record: bool) WriterError!void {
        if (record) {
            self.attribute_names.appendSlice(self.allocator, std.mem.asBytes(&name.len)) catch return self.fail(error.OutOfMemory);
            self.attribute_names.appendSlice(self.allocator, name) catch return self.fail(error.OutOfMemory);
        }
        try self.writeByte(' ');
        try self.writeBytes(name);
        try self.writeBytes("=\"");
        try self.writeEscapedAttribute(value);
        try self.writeByte('"');
    }

    fn sameAttribute(self: *const Writer, a: []const u8, b: []const u8, b_colon: usize) bool {
        const a_colon = std.mem.indexOfScalar(u8, a, ':') orelse return false;
        return std.mem.eql(u8, a[a_colon + 1 ..], b[b_colon + 1 ..]) and
            optionalSliceEql(self.namespaceUri(a[0..a_colon]), self.namespaceUri(b[0..b_colon]));
    }

    fn fail(self: *Writer, failure: WriterError) WriterError {
        if (self.failure == null) self.failure = failure;
        if (failure == error.WriteFailed) self.offset_valid = false;
        return failure;
    }

    fn writeBytes(self: *Writer, bytes: []const u8) WriterError!void {
        const next = std.math.add(u64, self.logical_offset, @intCast(bytes.len)) catch return self.fail(error.LimitExceeded);
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
            // Printable ASCII other than ", &, and < needs neither escaping nor decoding.
            const length = ordinaryAttributeRun(value[index..], '"');
            if (length != 0) {
                index += length;
                continue;
            }
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

const WriterState = enum {
    initial,
    start_tag,
    content,
    epilog,
    done,
};

const WriterFrame = struct {
    name_start: usize,
    name_len: usize,
    attribute_start: usize,
    binding_start: usize,
    namespace_bytes_start: usize,
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

// --- Tests ---

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
                    var writer = Writer.init(std.testing.allocator, &sink, .{});
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
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
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
    // The end of the document is reported once; reading past it is an error.
    try std.testing.expectError(error.UnexpectedEnd, cursor.advance(false));
}

test "[unit] - [mzML XML cursor]: a written fragment declares its scope once and nested elements their own" {
    const source = "<r xmlns='urn:d' xmlns:a='urn:a'><f xmlns:b='urn:b'><a:x b:y='1' a:y='2'>" ++
        "<c xmlns='' xmlns:a='urn:a2'><a:z/></c><d xmlns:b='urn:b'/></a:x></f></r>";
    var input = std.Io.Reader.fixed(source);
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
    defer cursor.deinit();
    try cursor.advanceFragment(false);
    try cursor.advanceFragment(false);
    var buffer: [512]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buffer);
    var output = Writer.init(std.testing.allocator, &sink, .{ .fragment = true });
    defer output.deinit();
    var remaining: usize = 100;
    try cursor.writeElement(&output, &remaining);
    // Redundant and inherited bindings are not repeated; shadowing and undeclaring are kept.
    try std.testing.expectEqualStrings("<f xmlns=\"urn:d\" xmlns:a=\"urn:a\" xmlns:b=\"urn:b\"><a:x b:y=\"1\" a:y=\"2\">" ++
        "<c xmlns=\"\" xmlns:a=\"urn:a2\"><a:z/></c><d/></a:x></f>", sink.buffered());
}

test "[property] - [mzML XML cursor]: decodes Latin-1 attributes, text, and CDATA across refills" {
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
        var cursor = try Cursor.init(std.testing.allocator, &input.interface, 64, 1024);
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
        var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
        defer cursor.deinit();
        try std.testing.expectError(case[1], cursor.advance(false));
    }
    const declaration = "<?xml version='1.0' encoding='ISO-8859-1'?><mzML/>";
    var bytes: [2 + declaration.len * 2]u8 = undefined;
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        std.mem.writeInt(u16, bytes[0..2], 0xfeff, endian);
        for (declaration, 0..) |byte, i| std.mem.writeInt(u16, bytes[2 + i * 2 ..][0..2], byte, endian);
        var input = std.Io.Reader.fixed(&bytes);
        var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
        defer cursor.deinit();
        try std.testing.expectError(error.InvalidEncoding, cursor.advance(false));
    }
}

test "[failure] - [mzML XML cursor]: rejects malformed names, namespace declarations, and XML targets" {
    const cases = .{
        .{ "<mzML xmlns='" ++ NAMESPACE ++ "'><p:1bad/></mzML>", 1 },
        .{ "<mzML xmlns='" ++ NAMESPACE ++ "' xmlns:p='one' xmlns:p='two'/>", 0 },
        .{ "<mzML xmlns='" ++ NAMESPACE ++ "'><?xml version='1.0'?><child/></mzML>", 1 },
    };
    inline for (cases) |case| {
        var input = std.Io.Reader.fixed(case[0]);
        var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
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
            var cursor = try Cursor.init(std.testing.allocator, &input.interface, 64, 1024);
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
                try std.testing.expectEqualStrings(item.local, name.expanded.local);
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
                    try std.testing.expectEqualStrings(
                        if (child == 1) "urn:inner" else "urn:outer",
                        attribute.name.expanded.namespace_uri.?,
                    );
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
                var cursor = try Cursor.init(std.testing.allocator, &input.interface, 64, 1024);
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
                        const expected = if (byte < 0x20 or byte >= 0x80 or byte == quote or byte == '&' or byte == '<')
                            position
                        else
                            length;
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
                var cursor = try Cursor.init(std.testing.allocator, &input, attributes, limit);
                defer cursor.deinit();
                var reference = try Cursor.init(std.testing.allocator, &reference_input, attributes, limit);
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
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
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
                    var cursor = try Cursor.init(std.testing.allocator, &input.interface, 64, limit);
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
                }
            }
        }
    }
}

test "[failure] - [mzML XML cursor]: enforces expanded names, document CDATA, text delimiters, and declaration order" {
    const cases = .{
        .{ "<mzML xmlns='" ++ NAMESPACE ++ "' xmlns:a='urn:test' xmlns:b='urn:test' a:x='1' b:x='2'/>", 0 },
        .{ "<![CDATA[outside]]><mzML xmlns='" ++ NAMESPACE ++ "'/>", 0 },
        .{ "<mzML xmlns='" ++ NAMESPACE ++ "'>]]></mzML>", 1 },
        .{ "<?xml encoding='UTF-8' version='1.0'?><mzML xmlns='" ++ NAMESPACE ++ "'/>", 0 },
        .{ "<?xml version='1.0'encoding='UTF-8'?><mzML xmlns='" ++ NAMESPACE ++ "'/>", 0 },
    };
    inline for (cases) |case| {
        var input = std.Io.Reader.fixed(case[0]);
        var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
        defer cursor.deinit();
        for (0..case[1]) |_| try cursor.advance(false);
        try std.testing.expectError(error.InvalidXml, cursor.advance(false));
    }

    const xml_attribute = "<mzML xmlns='" ++ NAMESPACE ++ "' xml:lang='en'/>";
    var input = std.Io.Reader.fixed(xml_attribute);
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
    defer cursor.deinit();
    try cursor.advance(false);
    try std.testing.expectEqualStrings(
        XML_NAMESPACE,
        cursor.current.?.data.start_element.attribute(XML_NAMESPACE, "lang").?.name.expanded.namespace_uri.?,
    );
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
                var cursor = try Cursor.init(std.testing.allocator, &input.interface, 64, 1024);
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
            var cursor = try Cursor.init(allocator, if (size == 0) &fixed else &chunks.interface, 64, 1024);
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
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
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
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
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
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
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
        const expected = try std.fmt.bufPrint(
            &expected_buffer,
            opening ++ ">]]{s}]]&gt;&lt;&amp;&#xD;\xc2\xb5]]&gt;</binary>",
            .{ordinary[0..length]},
        );
        for ([_]usize{ 0, length / 2, length, length + 1, length + 2, length + 3, value.len }) |split| {
            var sink = std.Io.Writer.fixed(&output);
            var writer = Writer.init(std.testing.allocator, &sink, .{});
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
                var writer = Writer.init(std.testing.allocator, &sink, .{});
                defer writer.deinit();
                try writer.startDocument();
                try writer.startElement("binary");
                try std.testing.expectError(error.InvalidCharacter, if (attribute) writer.attribute("id", bad) else writer.text(bad));
                const partial = try std.fmt.bufPrint(
                    &expected_buffer,
                    opening ++ "{s}{s}&amp;",
                    .{ if (attribute) " id=\"" else ">", ordinary[0..length] },
                );
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
    var writer = Writer.init(std.testing.allocator, &sink, .{});
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("mzML");
    try writer.namespace(null, NAMESPACE);
    try writer.attribute("id", "a&\"b\t\n\r\xc2\xb5\xe2\x82\xac\xf0\x9f\x98\x80");
    try writer.text("]]> &<\r");
    try writer.endElement();
    try writer.endDocument();
    try std.testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><mzML xmlns=\"" ++ NAMESPACE ++
            "\" id=\"a&amp;&quot;b&#x9;&#xA;&#xD;\xc2\xb5\xe2\x82\xac\xf0\x9f\x98\x80\">]]&gt; &amp;&lt;&#xD;</mzML>",
        sink.buffered(),
    );
    try std.testing.expectEqual(@as(?u64, sink.buffered().len), writer.byteOffset());
}

test "[failure] - [mzML XML writer]: keeps duplicate-attribute failures sticky" {
    var output: [128]u8 = undefined;
    var sink = std.Io.Writer.fixed(&output);
    var writer = Writer.init(std.testing.allocator, &sink, .{});
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
        var writer = Writer.init(std.testing.allocator, &sink, .{});
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

test "[failure] - [mzML XML writer]: rejects undeclared namespace names" {
    {
        var output: [256]u8 = undefined;
        var sink = std.Io.Writer.fixed(&output);
        var writer = Writer.init(std.testing.allocator, &sink, .{});
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("mzML");
        try writer.namespace(null, NAMESPACE);
        try std.testing.expectError(error.InvalidNamespace, writer.attribute("xsi:schemaLocation", "location"));
    }
    {
        var output: [256]u8 = undefined;
        var sink = std.Io.Writer.fixed(&output);
        var writer = Writer.init(std.testing.allocator, &sink, .{});
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("mzML");
        try writer.namespace(null, NAMESPACE);
        try writer.startElement("p:child");
        try std.testing.expectError(error.InvalidNamespace, writer.endElement());
    }
}

test "[failure] - [mzML XML cursor]: rejects a lone UTF-16 surrogate after the root" {
    const document = "<mzML xmlns='" ++ NAMESPACE ++ "'/>";
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var bytes: [2 + document.len * 2 + 2]u8 = undefined;
        std.mem.writeInt(u16, bytes[0..2], 0xfeff, endian);
        for (document, 0..) |byte, i| std.mem.writeInt(u16, bytes[2 + i * 2 ..][0..2], byte, endian);
        std.mem.writeInt(u16, bytes[bytes.len - 2 ..][0..2], 0xd800, endian);
        var input = std.Io.Reader.fixed(&bytes);
        var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
        defer cursor.deinit();
        const result: Error!void = while (true) {
            cursor.advance(false) catch |err| break err;
            if (cursor.current == null) break;
        };
        try std.testing.expectError(error.InvalidEncoding, result);
    }
}

test "[failure] - [mzML XML cursor]: reports the attribute limit when an entity overflows it" {
    // Names count against the same limit, so every limit size is tried to land on an entity.
    for ([_][]const u8{ "<mzML a='&amp;&amp;&amp;'/>", "<mzML a='&#65;&#x42;&#67;'/>" }) |source| {
        for (1..12) |limit| {
            var input = std.Io.Reader.fixed(source);
            var cursor = try Cursor.init(std.testing.allocator, &input, 64, limit);
            defer cursor.deinit();
            // A limit that fits the attribute reaches the missing namespace instead.
            cursor.advance(false) catch |err| switch (err) {
                error.LimitExceeded => try std.testing.expectEqual(
                    @as(@TypeOf(cursor.limit_failure), .attribute_bytes),
                    cursor.limit_failure,
                ),
                error.WrongNamespace => {},
                else => return err,
            };
        }
    }
}

test "[edge] - [mzML XML cursor]: decodes character references with many leading zeros" {
    const zeros = "0" ** 40;
    var input = std.Io.Reader.fixed(
        "<mzML a='&#" ++ zeros ++ "65;&#x" ++ zeros ++ "42;' xmlns='" ++ NAMESPACE ++ "'>&#" ++ zeros ++ "67;</mzML>",
    );
    var cursor = try Cursor.init(std.testing.allocator, &input, 64, 1024);
    defer cursor.deinit();
    try cursor.advance(true);
    try std.testing.expectEqualStrings("AB", cursor.current.?.data.start_element.attributes[0].value);
    try cursor.advance(true);
    try std.testing.expectEqualStrings("C", cursor.current.?.data.text.bytes);
}

test "[property] - [mzML XML writer]: Base64 in pieces equals Base64 of the whole, and needs its end" {
    var wire: [64]u8 = undefined;
    for (&wire, 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);
    var whole_bytes: [256]u8 = undefined;
    var whole_sink = std.Io.Writer.fixed(&whole_bytes);
    var whole = Writer.init(std.testing.allocator, &whole_sink, .{ .fragment = true });
    defer whole.deinit();
    try whole.startElement("binary");
    try whole.binary(&wire);
    try whole.endElement();
    for (1..8) |piece| {
        var bytes: [256]u8 = undefined;
        var sink = std.Io.Writer.fixed(&bytes);
        var writer = Writer.init(std.testing.allocator, &sink, .{ .fragment = true });
        defer writer.deinit();
        try writer.startElement("binary");
        var at: usize = 0;
        while (at < wire.len) : (at += piece) try writer.binaryPart(wire[at..@min(wire.len, at + piece)]);
        try writer.binaryEnd();
        try writer.endElement();
        try std.testing.expectEqualStrings(whole_sink.buffered(), sink.buffered());
    }
    var bytes: [256]u8 = undefined;
    var sink = std.Io.Writer.fixed(&bytes);
    var writer = Writer.init(std.testing.allocator, &sink, .{ .fragment = true });
    defer writer.deinit();
    try writer.startElement("binary");
    try writer.binaryPart(wire[0..4]);
    try std.testing.expectError(error.InvalidState, writer.endElement());
}
