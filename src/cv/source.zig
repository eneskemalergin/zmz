//! Defines source vocabulary identities, ordered parameters, and lexical values.

const std = @import("std");

/// Attribute text after XML normalization. Names may include a source prefix;
/// namespace_uri identifies its namespace. Declarations use the XMLNS URI.
pub const Attribute = struct {
    name: []const u8,
    namespace_uri: ?[]const u8 = null,
    value: []const u8,
};

/// Extra attributes, namespace declarations, and ordered parameter content.
/// Text is normalized UTF-8; XML parts include their namespace bindings.
/// All slices borrow from the parameter owner.
pub const ParameterXml = struct {
    attributes: []const Attribute,
    content: []const Part = &.{},
    pub const Part = union(enum) { text: []const u8, xml: []const u8 };
};

/// An exact accession spelling borrowed from caller-owned text.
pub const Accession = struct {
    raw: []const u8,

    /// Splits at the first colon without trimming or normalizing either component.
    pub fn curie(self: Accession) ?Curie {
        const colon = std.mem.indexOfScalar(u8, self.raw, ':') orelse return null;
        if (colon == 0 or colon + 1 == self.raw.len) return null;
        return .{ .prefix = self.raw[0..colon], .local = self.raw[colon + 1 ..] };
    }

    /// Compares exact case-sensitive accession bytes.
    pub fn eql(self: Accession, other: Accession) bool {
        return std.mem.eql(u8, self.raw, other.raw);
    }
};

/// Borrowed components of an accession; the local part need not be numeric.
pub const Curie = struct {
    prefix: []const u8,
    local: []const u8,

    /// Returns null for a nondecimal local part and Overflow for an oversized integer.
    pub fn numericLocal(self: Curie, comptime T: type) error{Overflow}!?T {
        if (@typeInfo(T) != .int or @typeInfo(T).int.signedness != .unsigned)
            @compileError("numericLocal requires an unsigned integer type");
        if (self.local.len == 0) return null;
        for (self.local) |byte| if (byte < '0' or byte > '9') return null;
        return std.fmt.parseInt(T, self.local, 10) catch return error.Overflow;
    }
};

/// Source attributes borrow text; null and an empty string remain distinct.
pub const Declaration = struct {
    id: ?[]const u8 = null,
    full_name: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

/// Independently optional source unit attributes, including incomplete triplets.
pub const Unit = struct {
    cv_ref: ?[]const u8 = null,
    accession: ?Accession = null,
    name: ?[]const u8 = null,

    /// Reports whether no unit attributes were supplied.
    pub fn isAbsent(self: Unit) bool {
        return self.cv_ref == null and self.accession == null and self.name == null;
    }

    /// Reports attribute presence, not vocabulary validity or nonempty values.
    pub fn isComplete(self: Unit) bool {
        return self.cv_ref != null and self.accession != null and self.name != null;
    }
};

/// A controlled parameter with source labels, lexical value, and borrowed text.
pub const Param = struct {
    cv_ref: ?[]const u8 = null,
    accession: ?Accession = null,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    unit: Unit = .{},
    xml: ?*const ParameterXml = null,
};

/// A user parameter whose declared type and lexical value remain unchanged.
pub const UserParam = struct {
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    value_type: ?[]const u8 = null,
    unit: Unit = .{},
    xml: ?*const ParameterXml = null,
};

pub const GroupRef = struct {
    ref: ?[]const u8 = null,
    xml: ?*const ParameterXml = null,
};

/// A source entry; sequences preserve ordering, repetition, and group references.
pub const Entry = union(enum) {
    group_ref: GroupRef,
    cv: Param,
    user: UserParam,
};

/// A borrowed group definition. EffectiveIterator rejects nested references when expanded.
pub const Group = struct {
    id: []const u8,
    entries: []const Entry,
};

/// Failures of bounded reference expansion, distinct from an absent parameter.
pub const ExpansionError = error{
    MissingGroup,
    DuplicateGroup,
    NestedGroup,
    ExpansionLimit,
};

/// Expands references in place without overriding local or repeated parameters.
/// All inputs must remain alive and unchanged until iteration ends.
/// ID/IDREF comparison collapses surrounding XML whitespace without changing source strings.
pub const EffectiveIterator = struct {
    entries: []const Entry,
    groups: []const Group,
    /// Bounds entry visits and group comparisons, including repeated references.
    remaining_work: usize = 1_000_000,
    position: usize = 0,
    expanded: []const Entry = &.{},
    expanded_position: usize = 0,
    failed: ?ExpansionError = null,

    /// Returns the next effective parameter; failures are sticky.
    pub fn next(self: *EffectiveIterator) ExpansionError!?Entry {
        if (self.failed) |failure| return failure;
        return self.advance() catch |failure| {
            self.failed = failure;
            return failure;
        };
    }

    fn charge(self: *EffectiveIterator) ExpansionError!void {
        if (self.remaining_work == 0) return error.ExpansionLimit;
        self.remaining_work -= 1;
    }

    fn advance(self: *EffectiveIterator) ExpansionError!?Entry {
        while (true) {
            if (self.expanded_position < self.expanded.len) {
                try self.charge();
                const entry = self.expanded[self.expanded_position];
                self.expanded_position += 1;
                if (entry == .group_ref) return error.NestedGroup;
                return entry;
            }
            if (self.position == self.entries.len) return null;
            try self.charge();
            const entry = self.entries[self.position];
            self.position += 1;
            if (entry != .group_ref) return entry;
            const id = std.mem.trim(u8, entry.group_ref.ref orelse return error.MissingGroup, " \t\r\n");
            var found: ?[]const Entry = null;
            for (self.groups) |group| {
                try self.charge();
                if (std.mem.eql(u8, id, std.mem.trim(u8, group.id, " \t\r\n"))) {
                    if (found != null) return error.DuplicateGroup;
                    found = group.entries;
                }
            }
            self.expanded = found orelse return error.MissingGroup;
            self.expanded_position = 0;
        }
    }
};

/// The result of asking for exactly one accession without discarding multiplicity.
pub const Match = union(enum) { missing, one: Param, repeated };

/// Searches an effective sequence by exact accession bytes with bounded expansion.
pub fn findOne(entries: []const Entry, groups: []const Group, accession: Accession) ExpansionError!Match {
    var iterator: EffectiveIterator = .{ .entries = entries, .groups = groups };
    var result: Match = .missing;
    while (try iterator.next()) |entry| {
        if (entry != .cv) continue;
        const candidate = entry.cv.accession orelse continue;
        if (!candidate.eql(accession)) continue;
        result = if (result == .missing) .{ .one = entry.cv } else .repeated;
    }
    return result;
}

/// Lexical failures preserve the distinction between missing, empty, invalid, and oversized values.
pub const ValueError = error{ MissingValue, EmptyValue, InvalidValue, Overflow };

/// Parses XML Schema boolean spellings after XML whitespace collapse.
pub fn parseBoolean(value: ?[]const u8) ValueError!bool {
    const bytes = try lexical(value);
    if (std.mem.eql(u8, bytes, "true") or std.mem.eql(u8, bytes, "1")) return true;
    if (std.mem.eql(u8, bytes, "false") or std.mem.eql(u8, bytes, "0")) return false;
    return error.InvalidValue;
}

/// Parses a decimal integer with range checks and no change to the source text.
pub fn parseInteger(comptime T: type, value: ?[]const u8) ValueError!T {
    const bytes = try lexical(value);
    const digits = if (bytes[0] == '+' or bytes[0] == '-') bytes[1..] else bytes;
    if (digits.len == 0) return error.InvalidValue;
    for (digits) |byte| if (byte < '0' or byte > '9') return error.InvalidValue;
    return std.fmt.parseInt(T, bytes, 10) catch |failure| switch (failure) {
        error.Overflow => error.Overflow,
        error.InvalidCharacter => error.InvalidValue,
    };
}

/// Parses XML Schema float/double lexical forms, including INF, -INF, and NaN.
/// Finite spellings that overflow return Overflow; underflow rounds normally.
/// Source text and the sign of zero are preserved. No unit or domain checks are applied.
pub fn parseFloat(comptime T: type, value: ?[]const u8) ValueError!T {
    if (T != f32 and T != f64) @compileError("parseFloat requires f32 or f64");
    const bytes = try lexical(value);
    if (std.mem.eql(u8, bytes, "INF")) return std.math.inf(T);
    if (std.mem.eql(u8, bytes, "-INF")) return -std.math.inf(T);
    if (std.mem.eql(u8, bytes, "NaN")) return std.math.nan(T);
    var position: usize = 0;
    if (bytes[0] == '+' or bytes[0] == '-') position += 1;
    var digits: usize = 0;
    while (position < bytes.len and std.ascii.isDigit(bytes[position])) : (position += 1)
        digits += 1;
    if (position < bytes.len and bytes[position] == '.') {
        position += 1;
        while (position < bytes.len and std.ascii.isDigit(bytes[position])) : (position += 1)
            digits += 1;
    }
    if (digits == 0) return error.InvalidValue;
    if (position < bytes.len and (bytes[position] == 'e' or bytes[position] == 'E')) {
        position += 1;
        if (position < bytes.len and (bytes[position] == '+' or bytes[position] == '-'))
            position += 1;
        const start = position;
        while (position < bytes.len and std.ascii.isDigit(bytes[position])) : (position += 1) {}
        if (position == start) return error.InvalidValue;
    }
    if (position != bytes.len) return error.InvalidValue;
    const result = std.fmt.parseFloat(T, bytes) catch return error.InvalidValue;
    if (!std.math.isFinite(result)) return error.Overflow;
    return result;
}

fn lexical(value: ?[]const u8) ValueError![]const u8 {
    const bytes = std.mem.trim(u8, value orelse return error.MissingValue, " \t\r\n");
    if (bytes.len == 0) return error.EmptyValue;
    return bytes;
}
