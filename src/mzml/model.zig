//! Preserves the mzML element hierarchy and source parameters without XML parser types.
//!
//! Slices borrow from their owner. Reader records and XML items expire on the next traversal call;
//! reader headers remain valid until reader deinitialization. Explicit owned copies remain valid
//! until their owner's deinit.

const std = @import("std");
const cv = @import("../cv/source.zig");
const encoding = @import("../binary/encoding.zig");
const arrays = @import("../binary/arrays.zig");

/// mzML element identities; cvParam, userParam, and group references live in Node.params.
pub const Kind = enum {
    mzml,
    cv_list,
    cv,
    file_description,
    file_content,
    source_file_list,
    source_file,
    contact,
    referenceable_param_group_list,
    referenceable_param_group,
    sample_list,
    sample,
    software_list,
    software,
    software_param,
    acquisition_settings_list,
    acquisition_settings,
    scan_settings_list,
    scan_settings,
    source_file_ref_list,
    source_file_ref,
    target_list,
    target,
    instrument_configuration_list,
    instrument_configuration,
    component_list,
    source,
    analyzer,
    detector,
    software_ref,
    data_processing_list,
    data_processing,
    processing_method,
    run,
    spectrum_list,
    spectrum,
    spectrum_description,
    acquisition_list,
    acquisition,
    scan_list,
    scan,
    scan_window_list,
    scan_window,
    precursor_list,
    precursor,
    isolation_window,
    selected_ion_list,
    selected_ion,
    activation,
    product_list,
    product,
    binary_data_array_list,
    binary_data_array,
    binary,
    chromatogram_list,
    chromatogram,
    indexed_mzml,
    index_list,
    index,
    offset,
    index_list_offset,
    file_checksum,

    /// Returns the exact case-sensitive element spelling in mzML XML.
    pub fn xmlName(self: Kind) []const u8 {
        return switch (self) {
            .mzml => "mzML",
            .indexed_mzml => "indexedmzML",
            inline else => |kind| comptime camelCase(@tagName(kind)),
        };
    }
};

pub const Attribute = cv.Attribute;

/// Forward items after the header, in source order. List attributes live with the header;
/// XML is self-contained UTF-8.
pub const Item = union(enum) {
    list_start: struct { kind: Kind, list: RecordList },
    record: Record,
    xml: []const u8,
    list_end,
    run_end,
};

/// Runs of parameters/children and self-contained UTF-8 XML, in source order. A null
/// `Node.content` means parameters precede children. Counts consume those slices consecutively;
/// callers changing their lengths must update the runs too (writing runs that do not match is
/// `InvalidStructure`).
pub const Content = struct {
    pub const Item = union(enum) { params: usize, children: usize, xml: []const u8 };

    items: []const Content.Item,
};

/// An mzML node from header metadata or one record, keeping parameter order and multiplicity.
/// Extra XML keeps its namespace bindings; prefixes, comments, and formatting may differ from
/// the source. Repeats of a singular metadata container stay in content as XML.
pub const Node = struct {
    kind: Kind,
    attributes: []const Attribute = &.{},
    params: []const cv.Entry = &.{},
    children: []const Node = &.{},
    content: ?*const Content = null,
    /// Null when text was deliberately skipped; retained empty text is an empty slice.
    text: ?[]const u8 = null,
    /// Physical offset of the element's `<`; zero for constructed nodes.
    start_offset: u64 = 0,
    /// Physical byte immediately after the opening tag, or zero for constructed nodes.
    content_offset: u64 = 0,
    /// Zero until the closing tag has been consumed, or for caller-constructed nodes.
    end_offset: u64 = 0,

    /// Looks up an attribute by unqualified name.
    pub fn attribute(self: Node, name: []const u8) ?[]const u8 {
        for (self.attributes) |attr| {
            if (attr.namespace_uri == null and std.mem.eql(u8, name, attr.name)) return attr.value;
        }
        return null;
    }

    /// Returns the first immediate child of this kind; repeats stay in children.
    pub fn child(self: Node, kind: Kind) ?Node {
        for (self.children) |node| if (node.kind == kind) return node;
        return null;
    }

    /// Reads the retained declared list count. The observed count is children.len.
    pub fn declaredCount(self: Node) cv.ValueError!?usize {
        const value = self.attribute("count") orelse return null;
        return try cv.parseInteger(usize, value);
    }

    /// Reads this cv element's declaration fields as written.
    pub fn cvDeclaration(self: Node) error{UnexpectedElement}!cv.Declaration {
        if (self.kind != .cv) return error.UnexpectedElement;
        return .{
            .id = self.attribute("id"),
            .full_name = self.attribute("fullName"),
            .uri = self.attribute("URI"),
            .version = self.attribute("version"),
        };
    }

    /// Returns the one parameter with this accession, looking through group references: null
    /// when absent, RepeatedParameter when there are several. Text borrows from node and groups.
    pub fn parameter(self: Node, groups: []const cv.Group, accession: cv.Accession) ParameterError!?cv.Param {
        return switch (try cv.findOne(self.params, groups, accession)) {
            .missing => null,
            .one => |param| param,
            .repeated => error.RepeatedParameter,
        };
    }

    /// Parses the unique parameter's value as a decimal integer. Null means the parameter is
    /// absent; a missing or malformed value is an error.
    pub fn integer(self: Node, comptime T: type, groups: []const cv.Group, accession: cv.Accession) (ParameterError || cv.ValueError)!?T {
        const param = try self.parameter(groups, accession) orelse return null;
        return try cv.parseInteger(T, param.value);
    }

    /// Parses the unique parameter's value as a float, returned with its source parameter.
    /// Units are not converted.
    pub fn number(self: Node, groups: []const cv.Group, accession: cv.Accession) (ParameterError || cv.ValueError)!?Number {
        const param = try self.parameter(groups, accession) orelse return null;
        return .{ .value = try cv.parseFloat(f64, param.value), .parameter = param };
    }

    /// Reads this scan's start time in its source units; null when absent.
    pub fn scanStartTime(self: Node, groups: []const cv.Group) FieldError!?Number {
        if (self.kind != .scan) return error.UnexpectedElement;
        return self.number(groups, Terms.SCAN_START_TIME);
    }

    /// Returns the selected ions of the first selectedIonList in source order; empty without one.
    pub fn selectedIons(self: Node) error{UnexpectedElement}![]const Node {
        if (self.kind != .precursor) return error.UnexpectedElement;
        return listItems(self, .selected_ion_list);
    }

    /// Parses this selected ion's fields; each absent one stays null. m/z falls back to the
    /// historical term; charge is a signed xs:int.
    pub fn selectedIonValues(self: Node, groups: []const cv.Group) FieldError!SelectedIon {
        if (self.kind != .selected_ion) return error.UnexpectedElement;
        return .{
            .mz = try self.number(groups, Terms.SELECTED_ION_MZ) orelse try self.number(groups, Terms.HISTORICAL_SELECTED_ION_MZ),
            .charge = try self.integer(i32, groups, Terms.CHARGE_STATE),
            .intensity = try self.number(groups, Terms.PEAK_INTENSITY),
        };
    }

    /// Parses this isolation window's target and offsets as written; each absent one stays null.
    pub fn isolationWindowValues(self: Node, groups: []const cv.Group) FieldError!IsolationWindow {
        if (self.kind != .isolation_window) return error.UnexpectedElement;
        return .{
            .target = try self.number(groups, Terms.ISOLATION_TARGET_MZ),
            .lower_offset = try self.number(groups, Terms.ISOLATION_LOWER_OFFSET),
            .upper_offset = try self.number(groups, Terms.ISOLATION_UPPER_OFFSET),
        };
    }
};

/// A repeated parameter or array is an error, never resolved to one of its copies.
pub const ParameterError = cv.ExpansionError || error{RepeatedParameter};
pub const LookupError = ParameterError || error{RepeatedArray};

/// A parsed number with its source spelling and optional unit fields.
pub const Number = struct { value: f64, parameter: cv.Param };

pub const FieldError = ParameterError || cv.ValueError || error{UnexpectedElement};
/// Scientific access failures, including contradictory flags; also the reader selection
/// callbacks' set, since a callback may look up arrays.
pub const MetadataError = FieldError || error{ ConflictingParameter, RepeatedArray };

/// Polarity as declared by the source.
pub const Polarity = enum { positive, negative };

/// Spectrum representation as declared by the source.
pub const Representation = enum { centroid, profile };

/// Selected-ion values as declared; each keeps its source parameter, and absent ones are null.
pub const SelectedIon = struct { mz: ?Number, charge: ?i32, intensity: ?Number };

/// Isolation target and offsets as declared, each optional, in source units. Offsets are
/// distances below and above the target, not absolute bounds.
pub const IsolationWindow = struct { target: ?Number, lower_offset: ?Number, upper_offset: ?Number };

/// Common PSI-MS accessions used by the helpers; other terms are equally valid.
pub const Terms = struct {
    pub const MS_LEVEL: cv.Accession = .{ .raw = "MS:1000511" };
    /// Positive scan polarity, also used on chromatograms.
    pub const POSITIVE_SCAN: cv.Accession = .{ .raw = "MS:1000130" };
    /// Negative scan polarity, also used on chromatograms.
    pub const NEGATIVE_SCAN: cv.Accession = .{ .raw = "MS:1000129" };
    pub const CENTROID_SPECTRUM: cv.Accession = .{ .raw = "MS:1000127" };
    pub const PROFILE_SPECTRUM: cv.Accession = .{ .raw = "MS:1000128" };
    /// Source units may be seconds or minutes.
    pub const SCAN_START_TIME: cv.Accession = .{ .raw = "MS:1000016" };
    pub const SELECTED_ION_MZ: cv.Accession = .{ .raw = "MS:1000744" };
    /// Obsolete m/z term that historical files use for the selected ion.
    pub const HISTORICAL_SELECTED_ION_MZ: cv.Accession = .{ .raw = "MS:1000040" };
    pub const CHARGE_STATE: cv.Accession = .{ .raw = "MS:1000041" };
    pub const PEAK_INTENSITY: cv.Accession = .{ .raw = "MS:1000042" };
    pub const ISOLATION_TARGET_MZ: cv.Accession = .{ .raw = "MS:1000827" };
    pub const ISOLATION_LOWER_OFFSET: cv.Accession = .{ .raw = "MS:1000828" };
    pub const ISOLATION_UPPER_OFFSET: cv.Accession = .{ .raw = "MS:1000829" };
    pub const MZ_ARRAY: cv.Accession = .{ .raw = "MS:1000514" };
    pub const INTENSITY_ARRAY: cv.Accession = .{ .raw = "MS:1000515" };
    pub const TIME_ARRAY: cv.Accession = .{ .raw = "MS:1000595" };
};

pub const Header = struct {
    document: Node,
    run: Node,
    /// Source namespace, independent of the document's version attribute.
    namespace_uri: []const u8 = "http://psi.hupo.org/ms/mzml",
    /// Definitions from the first group list; extra lists remain uninterpreted XML.
    groups: []const cv.Group = &.{},
    /// An indexed wrapper was seen; its index and checksum are not verified.
    indexed: bool = false,
    /// List descriptors become available when their opening tag is reached.
    spectrum_list: ?RecordList = null,
    chromatogram_list: ?RecordList = null,

    /// Returns the cvList declarations in order, for `cv.Resolver.init`. The caller frees the
    /// slice.
    pub fn cvDeclarations(
        self: Header,
        allocator: std.mem.Allocator,
    ) (std.mem.Allocator.Error || error{UnexpectedElement})![]cv.Declaration {
        const nodes = if (self.document.child(.cv_list)) |list| list.children else &.{};
        const declarations = try allocator.alloc(cv.Declaration, nodes.len);
        errdefer allocator.free(declarations);
        for (declarations, nodes) |*declaration, node| declaration.* = try node.cvDeclaration();
        return declarations;
    }
};

/// declared_count is the source count attribute (null when absent); observed_count counts the
/// records consumed so far. The two are not compared.
pub const RecordList = struct {
    attributes: []const Attribute,
    declared_count: ?usize,
    observed_count: usize = 0,
};

/// A spectrum or chromatogram with its complete child hierarchy. id, index, and
/// default_array_length are parsed copies of node attributes (null when absent): writers use
/// node, so edit node to change output and keep these fields consistent when reading the
/// edited record. Helpers read modeled children, not extra containers kept in Node.content.
pub const Record = struct {
    node: Node,
    id: []const u8,
    index: ?usize,
    default_array_length: ?usize,

    /// Parses the spectrum's MS level (xs:int range); null when absent. Chromatograms return
    /// UnexpectedElement.
    pub fn msLevel(self: Record, groups: []const cv.Group) FieldError!?i32 {
        if (self.node.kind != .spectrum) return error.UnexpectedElement;
        return self.node.integer(i32, groups, Terms.MS_LEVEL);
    }

    /// Reads record polarity, or the single scan's polarity in an mzML 1.0 description.
    /// Absence of both flags returns null; repeats and opposing flags return distinct errors.
    pub fn polarity(self: Record, groups: []const cv.Group) (FieldError || error{ConflictingParameter})!?Polarity {
        if (self.node.kind != .spectrum and self.node.kind != .chromatogram)
            return error.UnexpectedElement;
        const node = if (self.node.child(.spectrum_description)) |description| description.child(.scan) orelse return null else self.node;
        const positive = try exclusiveFlags(node, groups, Terms.POSITIVE_SCAN, Terms.NEGATIVE_SCAN) orelse return null;
        return if (positive) .positive else .negative;
    }

    /// Reads centroid/profile flags from the record or its mzML 1.0 description.
    pub fn representation(self: Record, groups: []const cv.Group) (FieldError || error{ConflictingParameter})!?Representation {
        if (self.node.kind != .spectrum) return error.UnexpectedElement;
        const node = self.node.child(.spectrum_description) orelse self.node;
        const centroid = try exclusiveFlags(node, groups, Terms.CENTROID_SPECTRUM, Terms.PROFILE_SPECTRUM) orelse return null;
        return if (centroid) .centroid else .profile;
    }

    /// Returns modeled scans in source order; empty for chromatograms.
    pub fn scans(self: Record) []const Node {
        if (self.node.child(.spectrum_description)) |description| return firstChild(description, .scan);
        return listItems(self.node, .scan_list);
    }

    /// Returns modeled spectrum precursors or the first direct chromatogram precursor.
    pub fn precursors(self: Record) []const Node {
        return recordChildren(self.node.child(.spectrum_description) orelse self.node, .precursor_list, .precursor);
    }

    /// Returns modeled spectrum products or the first direct chromatogram product.
    pub fn products(self: Record) []const Node {
        return recordChildren(self.node, .product_list, .product);
    }

    /// Returns descriptors from the first array list, including auxiliary arrays and unknown roles.
    pub fn binaryArrays(self: Record) []const Node {
        const list = self.node.child(.binary_data_array_list) orelse return &.{};
        return list.children;
    }

    /// Iterates typed array descriptors in source order without allocating. Unknown roles are
    /// returned; unknown primitive or compression terms are errors.
    pub fn arrays(self: Record, groups: []const cv.Group) BinaryArrayIterator {
        return .{
            .nodes = self.binaryArrays(),
            .groups = groups,
            .default_length = self.default_array_length,
        };
    }

    /// Finds the one array with this role accession, including caller-defined roles; several
    /// matches are an error.
    pub fn arrayByRole(self: Record, groups: []const cv.Group, role: cv.Accession) LookupError!?Node {
        var result: ?Node = null;
        for (self.binaryArrays()) |node| {
            if (try node.parameter(groups, role) == null) continue;
            if (result != null) return error.RepeatedArray;
            result = node;
        }
        return result;
    }
};

pub const Primitive = encoding.Primitive;
pub const Encoding = encoding.Descriptor;
pub const EncodingTerm = encoding.Declared;
pub const encodingTerm = encoding.declared;
/// What an array holds, from its array-type term.
pub const ArrayRole = enum { mz, intensity, time, other };

pub const EncodingError = encoding.Error || error{UnexpectedElement};

/// A binary array node with its classified encoding and value count.
pub const BinaryArray = struct {
    node: Node,
    encoding: Encoding,
    length: usize,

    /// Classifies one binary array and reads its explicit or record-default value count.
    /// MissingAttribute means neither arrayLength nor a default length was supplied.
    pub fn init(
        node: Node,
        default_length: ?usize,
        groups: []const cv.Group,
    ) (EncodingError || cv.ValueError || error{MissingAttribute})!BinaryArray {
        const descriptor = try arrayEncoding(node, groups);
        const length = if (node.attribute("arrayLength")) |value|
            try cv.parseInteger(usize, value)
        else
            default_length orelse return error.MissingAttribute;
        return .{ .node = node, .encoding = descriptor, .length = length };
    }

    /// Decodes the declared values into the start of a caller-owned typed buffer and returns
    /// them; a buffer shorter than length is OutputTooSmall. Ordinary arrays require the
    /// declared primitive. Numpress arrays decode into f64 because Numpress does not carry a
    /// primitive-width wire representation.
    pub fn decode(
        self: BinaryArray,
        comptime T: type,
        output: []T,
        scratch: arrays.Scratch,
    ) (arrays.DecodeError || error{PayloadNotRetained})![]T {
        if (self.encoding.decodedPrimitive() != Primitive.of(T)) return error.TypeMismatch;
        if (output.len < self.length) return error.OutputTooSmall;
        const values = output[0..self.length];
        const binary = self.node.child(.binary) orelse return error.PayloadNotRetained;
        const text = binary.text orelse return error.PayloadNotRetained;
        const pipeline = self.encoding.payloadPipeline(self.length, std.mem.trim(u8, text, cv.XML_WHITESPACE).len == 0);
        try arrays.decode(T, values, text, pipeline, scratch);
        return values;
    }
};

/// Keep the source nodes and groups alive while iterating.
pub const BinaryArrayIterator = struct {
    nodes: []const Node,
    groups: []const cv.Group,
    default_length: ?usize,
    position: usize = 0,
    failed: ?(EncodingError || cv.ValueError || error{MissingAttribute}) = null,

    /// Returns the next descriptor or null at the end. The first classification failure is sticky.
    pub fn next(self: *BinaryArrayIterator) (EncodingError || cv.ValueError || error{MissingAttribute})!?BinaryArray {
        if (self.failed) |failure| return failure;
        if (self.position == self.nodes.len) return null;
        const node = self.nodes[self.position];
        self.position += 1;
        return BinaryArray.init(node, self.default_length, self.groups) catch |failure| {
            self.failed = failure;
            return failure;
        };
    }
};

/// Returns the role of a binary array node: m/z, intensity, or time by their terms (also through
/// groups, checked in that order, a repeated term counting once), otherwise other.
pub fn arrayRole(node: Node, groups: []const cv.Group) cv.ExpansionError!ArrayRole {
    const roles = .{
        .{ Terms.MZ_ARRAY, ArrayRole.mz },
        .{ Terms.INTENSITY_ARRAY, ArrayRole.intensity },
        .{ Terms.TIME_ARRAY, ArrayRole.time },
    };
    inline for (roles) |role| if (try cv.findOne(node.params, groups, role[0]) != .missing) return role[1];
    return .other;
}

/// Classifies a binary array's primitive and compression terms; a missing term is an error.
pub fn arrayEncoding(node: Node, groups: []const cv.Group) EncodingError!Encoding {
    if (node.kind != .binary_data_array) return error.UnexpectedElement;
    return encoding.classify(node.params, groups);
}

/// Decodes one array into the start of a caller buffer without allocating, whatever its role,
/// and returns the values, as BinaryArray.decode does.
/// Values keep their declared primitive and units.
pub fn decodeArray(
    comptime T: type,
    output: []T,
    node: Node,
    default_length: ?usize,
    groups: []const cv.Group,
    scratch: arrays.Scratch,
) (EncodingError || cv.ValueError || arrays.DecodeError || error{ MissingAttribute, PayloadNotRetained })![]T {
    return (try BinaryArray.init(node, default_length, groups)).decode(T, output, scratch);
}

fn camelCase(comptime snake: []const u8) []const u8 {
    @setEvalBranchQuota(10_000);
    var result: []const u8 = "";
    var upper = false;
    for (snake) |byte| {
        if (byte == '_') {
            upper = true;
            continue;
        }
        result = result ++ &[_]u8{if (upper) std.ascii.toUpper(byte) else byte};
        upper = false;
    }
    return result;
}

fn listItems(node: Node, kind: Kind) []const Node {
    const list = node.child(kind) orelse return &.{};
    return list.children;
}

fn recordChildren(node: Node, list_kind: Kind, item_kind: Kind) []const Node {
    if (node.kind != .chromatogram) return listItems(node, list_kind);
    return firstChild(node, item_kind);
}

fn firstChild(node: Node, kind: Kind) []const Node {
    for (node.children, 0..) |child, i|
        if (child.kind == kind) return node.children[i .. i + 1];
    return &.{};
}

fn exclusiveFlags(
    node: Node,
    groups: []const cv.Group,
    first: cv.Accession,
    second: cv.Accession,
) (FieldError || error{ConflictingParameter})!?bool {
    const a = try node.parameter(groups, first);
    const b = try node.parameter(groups, second);
    if (a != null and b != null) return error.ConflictingParameter;
    return if (a != null) true else if (b != null) false else null;
}
