//! Verifies exact vocabulary identities, lexical interpretation, and bounded group expansion.

const std = @import("std");
const cv = @import("z_mzml").cv;

test "[unit] - [CV identity]: keeps exact accessions and optional numeric local parts" {
    const accession: cv.Accession = .{ .raw = "MS:00123" };
    const curie = accession.curie().?;
    try std.testing.expectEqualStrings("MS", curie.prefix);
    try std.testing.expectEqualStrings("00123", curie.local);
    try std.testing.expectEqual(@as(?u16, 123), try curie.numericLocal(u16));
    try std.testing.expect(!accession.eql(.{ .raw = "MS:123" }));
    try std.testing.expect(!accession.eql(.{ .raw = "ms:00123" }));
    for ([_][]const u8{ "", "MS", ":1", "MS:" }) |raw|
        try std.testing.expectEqual(null, (cv.Accession{ .raw = raw }).curie());
    try std.testing.expectEqual(
        @as(?u8, null),
        try (cv.Accession{ .raw = "X:abc" }).curie().?.numericLocal(u8),
    );
    try std.testing.expectError(
        error.Overflow,
        (cv.Accession{ .raw = "X:256" }).curie().?.numericLocal(u8),
    );
}

test "[unit] - [CV lookup]: expands at the reference position without overriding repetition" {
    const accession: cv.Accession = .{ .raw = "MS:1" };
    const group_entries = [_]cv.Entry{.{ .cv = .{ .accession = accession, .value = "group" } }};
    const groups = [_]cv.Group{.{ .id = "g", .entries = &group_entries }};
    const entries = [_]cv.Entry{
        .{ .user = .{ .name = "before", .value = "" } },
        .{ .group_ref = "g" },
        .{ .cv = .{ .accession = accession, .value = "local" } },
        .{ .group_ref = "g" },
    };
    var iterator: cv.EffectiveIterator = .{ .entries = &entries, .groups = &groups };
    try std.testing.expectEqualStrings("before", (try iterator.next()).?.user.name.?);
    try std.testing.expectEqualStrings("group", (try iterator.next()).?.cv.value.?);
    try std.testing.expectEqualStrings("local", (try iterator.next()).?.cv.value.?);
    try std.testing.expectEqualStrings("group", (try iterator.next()).?.cv.value.?);
    try std.testing.expectEqual(null, try iterator.next());
    try std.testing.expectEqual(null, try iterator.next());
    try std.testing.expectEqual(.repeated, try cv.findOne(&entries, &groups, accession));
    try std.testing.expectEqual(
        .missing,
        try cv.findOne(&entries, &groups, .{ .raw = "X:absent" }),
    );
    const unique = try cv.findOne(&group_entries, &.{}, accession);
    try std.testing.expectEqualStrings("group", unique.one.value.?);
}

test "[failure] - [CV expansion]: bounds missing duplicate and nested references" {
    const entries = [_]cv.Entry{.{ .group_ref = "g" }};
    const group: cv.Group = .{ .id = "g", .entries = &.{} };
    try std.testing.expectError(error.MissingGroup, cv.findOne(&entries, &.{}, .{ .raw = "MS:1" }));
    try std.testing.expectError(
        error.DuplicateGroup,
        cv.findOne(&entries, &.{ group, group }, .{ .raw = "MS:1" }),
    );
    const nested: cv.Group = .{ .id = "g", .entries = &entries };
    try std.testing.expectError(
        error.NestedGroup,
        cv.findOne(&entries, &.{nested}, .{ .raw = "MS:1" }),
    );
    var iterator: cv.EffectiveIterator = .{
        .entries = &entries,
        .groups = &.{group},
        .remaining_work = 1,
    };
    try std.testing.expectError(error.ExpansionLimit, iterator.next());
    try std.testing.expectError(error.ExpansionLimit, iterator.next());
}

test "[edge] - [CV lexical values]: distinguishes absence empty invalid and overflow" {
    try std.testing.expect(try cv.parseBoolean(" \ttrue\r\n"));
    try std.testing.expect(!(try cv.parseBoolean("0")));
    try std.testing.expectError(error.MissingValue, cv.parseBoolean(null));
    try std.testing.expectError(error.EmptyValue, cv.parseBoolean(" \t"));
    try std.testing.expectError(error.InvalidValue, cv.parseBoolean("TRUE"));
    try std.testing.expectError(error.InvalidValue, cv.parseBoolean("t rue"));
    try std.testing.expectEqual(@as(i8, -128), try cv.parseInteger(i8, " -128 "));
    try std.testing.expectEqual(@as(u8, 255), try cv.parseInteger(u8, "+255"));
    try std.testing.expectError(error.Overflow, cv.parseInteger(i8, "128"));
    for ([_][]const u8{ "+", "1_0", "0xff", "1.0", "1 0" }) |lexical|
        try std.testing.expectError(error.InvalidValue, cv.parseInteger(i32, lexical));
}
