//! Exposes the XML events every zmz reader is built on, for callers that need exact source
//! positions or their own interpretation of the document.

const std = @import("std");
const xml = @import("../xml/mzml_adapter.zig");
const Diagnostic = @import("diagnostic.zig");
const model = @import("model.zig");
const schema = @import("schema.zig");

/// Reads start, end, and text events from a forward byte stream it borrows until deinit;
/// copy neither the input nor the reader. It checks XML well-formedness (names, quoting,
/// nesting, entities and references, characters, namespace bindings, the declaration) and
/// nothing about mzML: any root element, any structure. Input in UTF-8, UTF-16, or declared
/// ISO-8859-1 is returned as UTF-8; spans count source bytes. Comments, processing
/// instructions, and the XML declaration produce no events. Each event's slices last until
/// the next call. The first failure sets diagnostic() and later calls return FailedState; a
/// call made while another runs, as from the input reader or the allocator, returns
/// InvalidState and leaves it unharmed.
const Events = @This();

pub const Name = xml.Name;
pub const ExpandedName = xml.ExpandedName;
pub const Attribute = xml.Attribute;
pub const StartElement = xml.StartElement;
pub const EndElement = xml.EndElement;
pub const Text = xml.Text;
pub const Namespace = xml.Cursor.Namespace;
pub const Rule = xml.Rule;
pub const Error = xml.Error || error{FailedState};

/// An element's start or end, or a run of its text. Start spans run from `<` through `>`
/// (an empty element also yields an end event with an empty span just after its `>`); text arrives in
/// runs of at most 64 KiB of UTF-8, several per element when it is longer, so long payloads
/// stream. Character and entity references are resolved and line ends normalized; CDATA
/// content arrives as text. Text outside the root element must be whitespace and produces no
/// event.
pub const Event = struct {
    span: struct { start: u64, end: u64 },
    data: union(enum) {
        start_element: StartElement,
        end_element: EndElement,
        text: Text,
    },
};

pub const Options = struct {
    /// Attributes on one element, namespace declarations included.
    attributes: usize = 64,
    /// Bytes of one start tag's names and values after decoding.
    attribute_bytes: usize = 1024 * 1024,
};

cursor: xml.Cursor,
active: bool = false,
done: bool = false,
failure: ?Diagnostic = null,

/// Allocates parser state without consuming input. Streaming input needs buffer capacity for
/// peekGreedy(1), otherwise InvalidOptions.
pub fn init(allocator: std.mem.Allocator, input: *std.Io.Reader, options: Options) Error!Events {
    return .{ .cursor = try xml.Cursor.init(allocator, input, options.attributes, options.attribute_bytes) };
}

/// Leaves the input open.
pub fn deinit(self: *Events) void {
    self.cursor.deinit();
    self.* = undefined;
}

/// Returns the next event, or null (again on every later call) after the root element closed
/// and only whitespace, comments, and processing instructions followed it.
pub fn next(self: *Events) Error!?Event {
    if (self.active) return error.InvalidState;
    if (self.failure != null) return error.FailedState;
    if (self.done) return null;
    self.active = true;
    defer self.active = false;
    self.cursor.advanceFragment(true) catch |err| {
        var report = Diagnostic.init(err, .read_event, .xml, Diagnostic.xmlDetail(&self.cursor));
        report.location = .{ .input_event = self.cursor.offset };
        self.failure = report;
        return err;
    };
    const event = self.cursor.current orelse {
        self.done = true;
        return null;
    };
    return .{ .span = .{ .start = event.span.start, .end = event.span.end }, .data = switch (event.data) {
        .start_element => |start| .{ .start_element = start },
        .end_element => |end| .{ .end_element = end },
        .text => |text| .{ .text = text },
        .document_start, .document_end => return null,
    } };
}

/// The modeled kind of an element in either mzML namespace (1.1 or 1.0), from the table the
/// readers use; null for other namespaces and for elements zmz does not model.
pub fn kindOf(name: Name) ?model.Kind {
    const uri = name.expanded.namespace_uri orelse return null;
    if (!std.mem.eql(u8, uri, xml.NAMESPACE) and !std.mem.eql(u8, uri, xml.NAMESPACE_1_0)) return null;
    return schema.kindOf(name.expanded.local);
}

/// Iterates the namespace bindings in scope at the current event, outermost first, skipping
/// shadowed ones. Start from 0; views last until the next call.
pub fn namespaceAt(self: *const Events, position: *usize) ?Namespace {
    return self.cursor.namespaceAt(position);
}

/// Returns a copy of the first failure: the error, its input offset (the offending byte for
/// broken XML rules and encodings, otherwise the failing event), and the broken XML rule or
/// exceeded limit when known.
pub fn diagnostic(self: *const Events) ?Diagnostic {
    return self.failure;
}
