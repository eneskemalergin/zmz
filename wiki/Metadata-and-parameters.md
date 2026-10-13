# Metadata and parameters

A record in zmz is a tree of nodes that mirrors the XML, plus helpers for the scientific fields most programs want. This page covers both, and the parameter rules underneath them.

## Nodes

Every element zmz models (a spectrum, a scan, a precursor, an array) is a `model.Node`:

- `kind`: which element it is, such as `.spectrum`, `.scan`, or `.binary_data_array`.
- `attributes`: its XML attributes in source order. `node.attribute("id")` looks one up.
- `params`: its `cvParam`, `userParam`, and group references, in source order, repeats included.
- `children`: the modeled child elements. `node.child(.scan_list)` returns the first of a kind.
- `content`: the interleaving of parameters, children, and unmodeled XML, when it differs from "parameters first, then children". This is what lets a copy keep everything in its original order.
- `text`: the binary text of an array, when it was kept.
- `start_offset`, `content_offset`, `end_offset`: byte positions in the source.

A `model.Record` is a spectrum or chromatogram node with `id`, `index`, and `default_array_length` already parsed out of its attributes. These are copies for reading convenience: to change what gets written, change the node.

## The scientific fields

These helpers read the common fields straight from a record, looking through parameter groups:

```zig
fn describe(record: mzml.model.Record, groups: []const mzml.cv.Group) !void {
    if (try record.msLevel(groups)) |level| std.debug.print("MS{d}", .{level});
    for (record.scans()) |scan| {
        if (try scan.scanStartTime(groups)) |time|
            std.debug.print(" at {d} {s}", .{ time.value, time.parameter.unit.name orelse "(no unit)" });
    }
    for (record.precursors()) |precursor| {
        for (try precursor.selectedIons()) |ion| {
            const values = try ion.selectedIonValues(groups);
            if (values.mz) |mz| std.debug.print(", precursor m/z {d}", .{mz.value});
            if (values.charge) |charge| std.debug.print(" charge {d}", .{charge});
        }
    }
    std.debug.print("\n", .{});
}
```

```text
MS1 at 0 minute
MS2 at 0.0051 minute, precursor m/z 1014.91664 charge 3
```

What is there:

- **On the record:** `msLevel`, `polarity`, `representation` (centroid or profile), `scans`, `precursors`, `products`, `binaryArrays`, `arrays` (typed descriptors), and `arrayByRole`.
- **On a scan:** `scanStartTime`.
- **On a precursor:** `selectedIons`, then on each ion `selectedIonValues` (m/z, charge, intensity).
- **On an isolation window:** `isolationWindowValues` (target and the two offsets).
- **On any node:** `parameter(groups, accession)`, `integer(T, groups, accession)`, and `number(groups, accession)` for anything else.

Numbers come back as a `model.Number`: the value as `f64`, and the `parameter` it came from, unit included.

> [!IMPORTANT]
> Units are never converted. A scan time of `0.0051` minutes stays `0.0051` with the unit "minute"; zmz does not turn it into 0.306 seconds. Check `parameter.unit` yourself, or ask the [resolver](Vocabulary#numbers-with-units).

### The rules behind the helpers

These are strict on purpose. Ambiguous metadata is an error, not a coin toss.

- **Absent is null.** A spectrum without an MS level gives `null`, not 1. A selected ion without a charge has `charge == null`, not 0.
- **Repeated is an error.** Two MS level parameters on one spectrum return `RepeatedParameter`, even when they agree; zmz does not pick one.
- **Contradictions are an error.** A spectrum marked both positive and negative returns `ConflictingParameter`.
- **Malformed is an error.** `value="abc"` where a number belongs returns `InvalidValue`; a missing value attribute returns `MissingValue`; an empty one, `EmptyValue`.
- **Wrong place is an error.** `msLevel` on a chromatogram returns `UnexpectedElement`.

When one bad field should not cost you the others, the `...Fields` variants (`selectedIonFields`, `isolationWindowFields`) return each field as its own error union.

Historical files get a little help: the selected-ion m/z falls back to the obsolete term `MS:1000040` that older writers used, and polarity and centroid/profile flags are also found in an mzML 1.0 spectrum description.

## Parameters as written

Each entry in `node.params` is a `cv.Entry`:

- **`.cv`**, a `cv.Param`: `cv_ref`, `accession`, `name`, `value`, and `unit` (with its own `cv_ref`, `accession`, `name`).
- **`.user`**, a `cv.UserParam`: `name`, `value`, `value_type`, and `unit`.
- **`.group_ref`**, a reference to a `referenceableParamGroup` in the header.

Every field is optional, and an absent attribute (`null`) is different from an empty one (`""`). Everything is kept exactly as written: an outdated name, a misspelled unit, an accession that does not exist. That is deliberate. zmz reports what the file says; whether the file is right is a separate question, which the [vocabulary](Vocabulary) answers.

## Parameter groups

A file can define a group of parameters once in the header and refer to it from many records:

```xml
<referenceableParamGroup id="mz_params">
  <cvParam cvRef="MS" accession="MS:1000523" name="64-bit float"/>
  <cvParam cvRef="MS" accession="MS:1000574" name="zlib compression"/>
</referenceableParamGroup>
...
<binaryDataArray encodedLength="5404">
  <referenceableParamGroupRef ref="mz_params"/>
  <cvParam cvRef="MS" accession="MS:1000514" name="m/z array"/>
```

zmz keeps the reference as a reference. The helpers above look through it, which is why they take `header.groups`. To walk every effective parameter with the groups expanded in place:

```zig
fn listParameters(record: mzml.model.Record, groups: []const mzml.cv.Group) !void {
    var parameters: mzml.cv.EffectiveIterator = .{ .entries = record.node.params, .groups = groups };
    while (try parameters.next()) |entry| switch (entry) {
        .cv => |param| std.debug.print("{s} {?s} = {?s}\n", .{ if (param.accession) |a| a.raw else "(none)", param.name, param.value }),
        .user => |param| std.debug.print("user {?s} = {?s}\n", .{ param.name, param.value }),
        .group_ref => unreachable, // expanded by the iterator
    };
}
```

A reference to a group that does not exist is `MissingGroup`, two groups with one ID are `DuplicateGroup`, and a group that refers to another group is `NestedGroup`, which mzML does not allow. Expansion has a fixed work budget (`cv.EXPANSION_WORK`), so a file with a million references to a huge group cannot stall a reader.

> [!TIP]
> Keep the header alive while you use a record's parameters. A record's group references point into `header.groups`, and `owned.Record` does not copy them; keep an `owned.Header` beside it.

## Unmodeled XML

mzML files carry things zmz does not model: vendor extensions, elements from other namespaces, a second copy of a container that should appear once. None of it is dropped. It sits in `node.content` as self-contained XML, in its original position, and writing the node writes it back. The helpers ignore it, so it never changes what `msLevel` or `scans` return.
