//! Preserves the mzML element hierarchy and source parameters without XML parser types.
//!
//! Slices borrow from their owner. Reader records expire on the next record request;
//! reader headers remain valid until reader deinitialization. Explicit owned copies
//! remain valid until their owner's deinit.

const std = @import("std");
const encoding = @import("../binary/encoding.zig");
const cv = @import("../cv/source.zig");
const arrays = @import("../binary/arrays.zig");

// --- Source hierarchy ---

/// Stable mzML 1.1 element identities; parameter entries are represented separately.
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
            .cv_list => "cvList",
            .cv => "cv",
            .file_description => "fileDescription",
            .file_content => "fileContent",
            .source_file_list => "sourceFileList",
            .source_file => "sourceFile",
            .contact => "contact",
            .referenceable_param_group_list => "referenceableParamGroupList",
            .referenceable_param_group => "referenceableParamGroup",
            .sample_list => "sampleList",
            .sample => "sample",
            .software_list => "softwareList",
            .software => "software",
            .scan_settings_list => "scanSettingsList",
            .scan_settings => "scanSettings",
            .source_file_ref_list => "sourceFileRefList",
            .source_file_ref => "sourceFileRef",
            .target_list => "targetList",
            .target => "target",
            .instrument_configuration_list => "instrumentConfigurationList",
            .instrument_configuration => "instrumentConfiguration",
            .component_list => "componentList",
            .source => "source",
            .analyzer => "analyzer",
            .detector => "detector",
            .software_ref => "softwareRef",
            .data_processing_list => "dataProcessingList",
            .data_processing => "dataProcessing",
            .processing_method => "processingMethod",
            .run => "run",
            .spectrum_list => "spectrumList",
            .spectrum => "spectrum",
            .scan_list => "scanList",
            .scan => "scan",
            .scan_window_list => "scanWindowList",
            .scan_window => "scanWindow",
            .precursor_list => "precursorList",
            .precursor => "precursor",
            .isolation_window => "isolationWindow",
            .selected_ion_list => "selectedIonList",
            .selected_ion => "selectedIon",
            .activation => "activation",
            .product_list => "productList",
            .product => "product",
            .binary_data_array_list => "binaryDataArrayList",
            .binary_data_array => "binaryDataArray",
            .binary => "binary",
            .chromatogram_list => "chromatogramList",
            .chromatogram => "chromatogram",
            .indexed_mzml => "indexedmzML",
            .index_list => "indexList",
            .index => "index",
            .offset => "offset",
            .index_list_offset => "indexListOffset",
            .file_checksum => "fileChecksum",
        };
    }
};

/// Source attribute text after XML entity and whitespace normalization.
pub const Attribute = struct {
    name: []const u8,
    namespace_uri: ?[]const u8 = null,
    value: []const u8,
};

/// A faithful mzML node, bounded to header metadata or one record, never a complete run.
/// Parameter order and multiplicity are preserved. Prefixes, comments, and formatting are not.
pub const Node = struct {
    kind: Kind,
    attributes: []const Attribute = &.{},
    params: []const cv.Entry = &.{},
    children: []const Node = &.{},
    /// Null when text was deliberately skipped; retained empty text is an empty slice.
    text: ?[]const u8 = null,
    /// Physical source byte offsets covering the element, including its tags.
    start_offset: u64 = 0,
    /// Physical byte immediately after the opening tag, or zero for constructed nodes.
    content_offset: u64 = 0,
    /// Zero until the closing tag has been consumed, or for caller-constructed nodes.
    end_offset: u64 = 0,

    /// Looks up an unqualified attribute without changing its source spelling.
    pub fn attribute(self: Node, name: []const u8) ?[]const u8 {
        for (self.attributes) |attr| {
            if (attr.namespace_uri == null and std.mem.eql(u8, name, attr.name)) return attr.value;
        }
        return null;
    }

    /// Returns the first immediate child with this schema identity.
    /// Repeated children remain available through children; this helper does not assert uniqueness.
    pub fn child(self: Node, kind: Kind) ?Node {
        for (self.children) |node| if (node.kind == kind) return node;
        return null;
    }

    /// Reads the retained declared list count. The observed count is children.len.
    pub fn declaredCount(self: Node) cv.ValueError!?usize {
        const value = self.attribute("count") orelse return null;
        return try cv.parseInteger(usize, value);
    }

    /// Returns one effective parameter, null when absent, or RepeatedParameter.
    /// Group expansion errors propagate; returned text borrows from this node and groups.
    pub fn parameter(self: Node, groups: []const cv.Group, accession: cv.Accession) LookupError!?cv.Param {
        return switch (try cv.findOne(self.params, groups, accession)) {
            .missing => null,
            .one => |param| param,
            .repeated => error.RepeatedParameter,
        };
    }

    /// Parses a unique parameter's decimal integer without changing its source fields.
    /// Null means the parameter is absent, not that its value is missing or malformed.
    pub fn integer(self: Node, comptime T: type, groups: []const cv.Group, accession: cv.Accession) (LookupError || cv.ValueError)!?T {
        const param = try self.parameter(groups, accession) orelse return null;
        return try cv.parseInteger(T, param.value);
    }

    /// Parses a unique floating parameter and retains its complete source parameter.
    /// Units remain unresolved and unconverted.
    pub fn number(self: Node, groups: []const cv.Group, accession: cv.Accession) (LookupError || cv.ValueError)!?Number {
        const param = try self.parameter(groups, accession) orelse return null;
        return .{ .value = try cv.parseFloat(f64, param.value), .parameter = param };
    }

    /// Reads this scan's start time without choosing a scan or converting its units.
    /// Other node kinds return UnexpectedElement; null means no start-time parameter.
    pub fn scanStartTime(self: Node, groups: []const cv.Group) MetadataError!?Number {
        if (self.kind != .scan) return error.UnexpectedElement;
        return self.number(groups, Terms.SCAN_START_TIME);
    }

    /// Returns every selected ion of this precursor in source order, without copying.
    /// Other node kinds return UnexpectedElement; an absent list returns an empty slice.
    pub fn selectedIons(self: Node) error{UnexpectedElement}![]const Node {
        if (self.kind != .precursor) return error.UnexpectedElement;
        return listItems(self, .selected_ion_list);
    }

    /// Parses this selected ion's independent fields; no missing field is inferred.
    /// Charge uses signed xs:int range. Source parameters remain available on this node.
    pub fn selectedIonValues(self: Node, groups: []const cv.Group) MetadataError!SelectedIon {
        if (self.kind != .selected_ion) return error.UnexpectedElement;
        return .{
            .mz = try self.number(groups, Terms.SELECTED_ION_MZ),
            .charge = try self.integer(i32, groups, Terms.CHARGE_STATE),
            .intensity = try self.number(groups, Terms.PEAK_INTENSITY),
        };
    }

    /// Parses this isolation window without computing boundaries or assuming symmetry.
    /// Other node kinds return UnexpectedElement; each absent parameter remains null.
    pub fn isolationWindowValues(self: Node, groups: []const cv.Group) MetadataError!IsolationWindow {
        if (self.kind != .isolation_window) return error.UnexpectedElement;
        return .{
            .target = try self.number(groups, Terms.ISOLATION_TARGET_MZ),
            .lower_offset = try self.number(groups, Terms.ISOLATION_LOWER_OFFSET),
            .upper_offset = try self.number(groups, Terms.ISOLATION_UPPER_OFFSET),
        };
    }
};

/// Lookup failures never collapse repeated parameters into a first or last value.
pub const LookupError = cv.ExpansionError || error{ RepeatedParameter, RepeatedArray };

/// A parsed number with borrowed source spelling and independently optional unit fields.
pub const Number = struct { value: f64, parameter: cv.Param };

/// Scientific access failures, including wrong node kinds and contradictory flags.
pub const MetadataError = LookupError || cv.ValueError || error{ UnexpectedElement, ConflictingParameter };

/// Recognized source polarity, never inferred from an ion's charge state.
pub const Polarity = enum { positive, negative };

/// Recognized spectrum representation, never inferred from binary values.
pub const Representation = enum { centroid, profile };

/// Independent selected-ion values; numeric quantities retain their source parameters.
/// Missing charge stays null rather than becoming zero. No charge or intensity is inferred.
pub const SelectedIon = struct { mz: ?Number, charge: ?i32, intensity: ?Number };

/// Source target and offsets with independent presence and unchanged units.
/// Offsets are extents below and above the target, not absolute bounds.
pub const IsolationWindow = struct { target: ?Number, lower_offset: ?Number, upper_offset: ?Number };

/// Exact common PSI-MS accessions, not an ontology or an exhaustive list of valid terms.
pub const Terms = struct {
    pub const MS_LEVEL: cv.Accession = .{ .raw = "MS:1000511" };
    /// Positive scan polarity, also used on chromatograms.
    pub const POSITIVE_SCAN: cv.Accession = .{ .raw = "MS:1000130" };
    /// Negative scan polarity, also used on chromatograms.
    pub const NEGATIVE_SCAN: cv.Accession = .{ .raw = "MS:1000129" };
    /// Discrete peak-coordinate representation.
    pub const CENTROID_SPECTRUM: cv.Accession = .{ .raw = "MS:1000127" };
    /// Distributed signal representation across each peak's coordinate range.
    pub const PROFILE_SPECTRUM: cv.Accession = .{ .raw = "MS:1000128" };
    /// Scan start time; source units may be seconds or minutes.
    pub const SCAN_START_TIME: cv.Accession = .{ .raw = "MS:1000016" };
    /// Selected ion mass-to-charge ratio.
    pub const SELECTED_ION_MZ: cv.Accession = .{ .raw = "MS:1000744" };
    /// Signed charge state.
    pub const CHARGE_STATE: cv.Accession = .{ .raw = "MS:1000041" };
    /// Selected peak intensity; source units are not inferred.
    pub const PEAK_INTENSITY: cv.Accession = .{ .raw = "MS:1000042" };
    /// Isolation window target mass-to-charge ratio.
    pub const ISOLATION_TARGET_MZ: cv.Accession = .{ .raw = "MS:1000827" };
    /// Isolation window lower offset from the target.
    pub const ISOLATION_LOWER_OFFSET: cv.Accession = .{ .raw = "MS:1000828" };
    /// Isolation window upper offset from the target.
    pub const ISOLATION_UPPER_OFFSET: cv.Accession = .{ .raw = "MS:1000829" };
    /// Mass-to-charge array role.
    pub const MZ_ARRAY: cv.Accession = .{ .raw = "MS:1000514" };
    /// Intensity array role.
    pub const INTENSITY_ARRAY: cv.Accession = .{ .raw = "MS:1000515" };
    /// Time array role; source units are not inferred.
    pub const TIME_ARRAY: cv.Accession = .{ .raw = "MS:1000595" };
};

/// Header metadata stays alive independently of the reusable record storage.
pub const Header = struct {
    document: Node,
    run: Node,
    groups: []const cv.Group = &.{},
    /// An indexed wrapper was observed; its index and checksum have not been verified.
    indexed: bool = false,
    /// List descriptors become available when their opening tag is reached.
    spectrum_list: ?RecordList = null,
    chromatogram_list: ?RecordList = null,
};

/// Preserves the source count without comparing it to traversed records.
/// observed_count increases as records are consumed, independently of declared_count.
pub const RecordList = struct {
    attributes: []const Attribute,
    declared_count: usize,
    observed_count: usize = 0,
};

/// A spectrum or chromatogram with exact source identity and its complete child hierarchy.
pub const Record = struct {
    node: Node,
    id: []const u8,
    index: usize,
    default_array_length: usize,

    /// Parses the spectrum's MS level in xs:int range without imposing an analysis policy.
    /// Null means absent. Chromatograms and other node kinds return UnexpectedElement.
    pub fn msLevel(self: Record, groups: []const cv.Group) MetadataError!?i32 {
        if (self.node.kind != .spectrum) return error.UnexpectedElement;
        return self.node.integer(i32, groups, Terms.MS_LEVEL);
    }

    /// Reads recognized polarity flags on this spectrum or chromatogram only.
    /// Absence of both flags returns null; repeats and opposing flags return distinct errors.
    pub fn polarity(self: Record, groups: []const cv.Group) MetadataError!?Polarity {
        if (self.node.kind != .spectrum and self.node.kind != .chromatogram)
            return error.UnexpectedElement;
        const positive = try exclusiveFlags(self.node, groups, Terms.POSITIVE_SCAN, Terms.NEGATIVE_SCAN) orelse return null;
        return if (positive) .positive else .negative;
    }

    /// Reads centroid/profile flags without interpreting their absent or empty values.
    /// Unknown terms stay in node.params.
    pub fn representation(self: Record, groups: []const cv.Group) MetadataError!?Representation {
        if (self.node.kind != .spectrum) return error.UnexpectedElement;
        const centroid = try exclusiveFlags(self.node, groups, Terms.CENTROID_SPECTRUM, Terms.PROFILE_SPECTRUM) orelse return null;
        return if (centroid) .centroid else .profile;
    }

    /// Returns all scans in source order. Chromatograms have no scan list.
    /// Like binaryArrays, list access borrows a structurally valid record hierarchy.
    pub fn scans(self: Record) []const Node {
        return listItems(self.node, .scan_list);
    }

    /// Returns all spectrum precursors or the optional direct chromatogram precursor.
    /// No first-precursor selection, copying, or parameter interpretation occurs.
    pub fn precursors(self: Record) []const Node {
        return recordChildren(self.node, .precursor_list, .precursor);
    }

    /// Returns all spectrum products or the optional direct chromatogram product.
    pub fn products(self: Record) []const Node {
        return recordChildren(self.node, .product_list, .product);
    }

    /// Returns all binary array descriptors, including auxiliary arrays and unknown roles.
    pub fn binaryArrays(self: Record) []const Node {
        const list = self.node.child(.binary_data_array_list) orelse return &.{};
        return list.children;
    }

    /// Returns typed array descriptors in source order without allocating.
    /// Classification and array-length parsing happen once when each item is read.
    /// Unknown roles remain available; unknown primitive or compression terms return an error.
    /// The record nodes and groups must remain valid until iteration ends.
    pub fn arrays(self: Record, groups: []const cv.Group) BinaryArrayIterator {
        return .{
            .nodes = self.binaryArrays(),
            .groups = groups,
            .default_length = self.default_array_length,
        };
    }

    /// Finds a unique array by exact role accession, including caller-defined roles.
    /// Repeated role parameters or matching arrays fail rather than discarding multiplicity.
    /// Other roles and unknown metadata remain available through binaryArrays.
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

// --- Binary arrays ---

/// Reviewed primitive identities, separate from an array's scientific role.
pub const Primitive = encoding.Primitive;

/// Established primitive and codec declaration pair.
pub const Encoding = encoding.Descriptor;

/// Failures in declaration classification, before payload decoding.
pub const EncodingError = encoding.Error;

/// A source-preserving binary array with its reviewed wire descriptor and value count.
/// The node and all of its slices remain borrowed from the current record or owned copy.
pub const BinaryArray = struct {
    node: Node,
    encoding: Encoding,
    length: usize,

    /// Classifies one binary array and reads its explicit or record-default value count.
    pub fn init(
        node: Node,
        default_length: usize,
        groups: []const cv.Group,
    ) (EncodingError || cv.ValueError)!BinaryArray {
        return initWithEncoding(node, default_length, try arrayEncoding(node, groups));
    }

    /// Decodes the declared values into an exact-size caller-owned typed buffer.
    /// Ordinary arrays require the declared primitive. Numpress arrays decode into f64 because
    /// Numpress does not carry a primitive-width wire representation.
    pub fn decode(
        self: BinaryArray,
        comptime T: type,
        output: []T,
        scratch: arrays.Scratch,
        limits: arrays.Limits,
    ) (EncodingError || arrays.Error)!void {
        if (encoding.isNumpress(self.encoding.pipeline)) {
            if (T != f64) return error.TypeMismatch;
        } else if (self.encoding.primitive != primitiveFor(T)) return error.TypeMismatch;
        if (self.length != output.len) return error.DecodedSizeMismatch;
        const binary = self.node.child(.binary) orelse return error.PayloadNotRetained;
        const text = binary.text orelse return error.PayloadNotRetained;
        // Some producers omit the zlib stream for an empty array. Nonempty streams
        // still pass through the codec, including its checksum and truncation checks.
        if (self.length == 0 and self.encoding.pipeline == .zlib and std.mem.trim(u8, text, " \t\r\n").len == 0) {
            try arrays.decode(T, output, text, .none, scratch, limits);
            return;
        }
        try arrays.decode(T, output, text, self.encoding.pipeline, scratch, limits);
    }
};

/// Iterates borrowed record arrays as typed descriptors without retaining new storage.
/// The source nodes and groups must remain valid until iteration ends.
pub const BinaryArrayIterator = struct {
    nodes: []const Node,
    groups: []const cv.Group,
    default_length: usize,
    position: usize = 0,
    failed: ?BinaryArrayError = null,

    /// Returns the next descriptor or null at the end. The first classification failure is sticky.
    pub fn next(self: *BinaryArrayIterator) BinaryArrayError!?BinaryArray {
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

const BinaryArrayError = EncodingError || cv.ValueError;

/// Classifies reviewed wire terms without guessing defaults or resolving an ontology.
pub fn arrayEncoding(node: Node, groups: []const cv.Group) EncodingError!Encoding {
    if (node.kind != .binary_data_array) return error.NotBinaryArray;
    return encoding.classify(node.params, groups);
}

/// Decodes one current record array into an exact-size caller buffer without allocation.
/// Unknown roles do not block decoding. No primitive conversion or unit conversion is performed.
pub fn decodeArray(
    comptime T: type,
    output: []T,
    node: Node,
    default_length: usize,
    groups: []const cv.Group,
    scratch: arrays.Scratch,
    limits: arrays.Limits,
) (EncodingError || cv.ValueError || arrays.Error)!void {
    const declared_encoding = try arrayEncoding(node, groups);
    if (encoding.isNumpress(declared_encoding.pipeline)) {
        if (T != f64) return error.TypeMismatch;
    } else if (declared_encoding.primitive != primitiveFor(T)) return error.TypeMismatch;
    const array = try initWithEncoding(node, default_length, declared_encoding);
    try array.decode(T, output, scratch, limits);
}

fn initWithEncoding(node: Node, default_length: usize, descriptor: Encoding) cv.ValueError!BinaryArray {
    const length = if (node.attribute("arrayLength")) |value|
        try cv.parseInteger(usize, value)
    else
        default_length;
    return .{ .node = node, .encoding = descriptor, .length = length };
}

fn primitiveFor(comptime T: type) Primitive {
    return switch (T) {
        f32 => .float32,
        f64 => .float64,
        i32 => .int32,
        i64 => .int64,
        else => @compileError("array destination must be f32, f64, i32, or i64"),
    };
}

fn listItems(node: Node, kind: Kind) []const Node {
    const list = node.child(kind) orelse return &.{};
    return list.children;
}

fn recordChildren(node: Node, list_kind: Kind, item_kind: Kind) []const Node {
    if (node.kind != .chromatogram) return listItems(node, list_kind);
    for (node.children, 0..) |item, i|
        if (item.kind == item_kind) return node.children[i .. i + 1];
    return &.{};
}

fn exclusiveFlags(node: Node, groups: []const cv.Group, first: cv.Accession, second: cv.Accession) MetadataError!?bool {
    const a = try node.parameter(groups, first);
    const b = try node.parameter(groups, second);
    if (a != null and b != null) return error.ConflictingParameter;
    return if (a != null) true else if (b != null) false else null;
}
