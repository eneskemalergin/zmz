# Limits and safety

mzML files come from instruments, converters, collaborators, and the internet. Some are broken, a few are hostile, and a parser that trusts them can be made to allocate 50 GB or follow an offset into nowhere. zmz treats every input as untrusted. This page lists the bounds it enforces and the guarantees behind them.

## The guarantees

- **No undefined behavior from input or misuse**, in any build mode, ReleaseFast included. Calling the API out of order, calling back into a reader from its own callback, or passing overlapping buffers returns an error. Lengths, offsets, and counts are checked before use; arithmetic that could overflow is checked; a bad file returns a named error.
- **Bounded memory.** Every buffer that grows with the input has a limit, and memory for one record does not depend on the size of the file.
- **Bounded work.** Parameter-group expansion, vocabulary comparisons, and XML nesting have fixed budgets, so no small input can make zmz loop for minutes.
- **No network, no external files.** DTDs and external entities are rejected, never fetched. Vocabulary URIs in a file are never followed.

These are tested, not just intended. Fuzz targets cover reading at every input split, events, array text in arbitrary runs, mutated indexes, written arrays read back, and OBO parsing. Allocation-failure sweeps fail each allocation of an operation in turn and check that it returns `OutOfMemory` without leaking.

## The default limits

| Limit | Default | Set on |
|---|---:|---|
| `header_bytes` | 32 MiB | `StreamReader` |
| `record_bytes` | 256 MiB | `StreamReader` |
| `binary_text_bytes` | 256 MiB | `StreamReader` |
| `nodes` | 100,000 | `StreamReader` |
| `list_entries` | 100,000 | `StreamReader` |
| `attributes` | 64 | `StreamReader`, `Events` |
| `attribute_bytes` | 1 MiB | `StreamReader`, `Events` |
| `array_bytes` | 192 MiB | `DecodedArrays` |
| `record_array_bytes` | 512 MiB | `DecodedArrays` |
| `records` | 4,000,000 | `IndexedReader` |
| `index_bytes` | 256 MiB | `IndexedReader` |
| `record_span_bytes` | 256 MiB | `IndexedReader` |
| `tail_bytes` | 64 KiB | `IndexedReader` |
| `nodes` | 100,000 | `Writer` |
| `text_bytes` | 256 MiB | `Writer` |
| `bytes` | 256 MiB | `owned`, `Builder` |

Fixed bounds, not configurable:

| Bound | Value |
|---|---:|
| Nesting depth (`MAX_DEPTH`) | 64 |
| Group expansion work | 1,000,000 |
| XML text run | 64 KiB |
| OBO file for `parseObo` | 32 MiB |

What the configurable limits count:

- **`header_bytes`, `record_bytes`**: bytes of stored strings and nodes for the header, and for one record. Allocator bookkeeping and reused scratch space are not counted.
- **`binary_text_bytes`**: the Base64 text of one array, also when it is decoded as it streams and never stored.
- **`nodes`, `list_entries`**: elements stored for one header or record, and the children, parameters, or content runs of any one element.
- **`array_bytes`, `record_array_bytes`**: decoded bytes of one array, and of all arrays of one record together.
- **`records`, `index_bytes`**: entries and ID storage in an index.
- **`record_span_bytes`**: the size of one record's XML that a lookup reads.
- **`tail_bytes`**: how far from the end of the file to look for the embedded index's offset.
- **Writer `nodes`, `text_bytes`**: elements written by one call, and the size of one text such as an array's Base64.

## Changing a limit

Limits live in the options of the type that enforces them:

```zig
var reader = try mzml.StreamReader.init(allocator, &input.interface, .{
    .limits = .{ .record_bytes = 1024 * 1024 * 1024 },
});
var arrays = mzml.DecodedArrays.init(allocator, .{ .array_bytes = 1024 * 1024 * 1024 });
```

The defaults are sized for real instrument files, with room to spare. When a legitimate file needs more, the [diagnostic](Errors-and-diagnostics) names the limit and how much was needed, so you know which one to raise and by how much.

> [!TIP]
> For a server that reads files from strangers, go the other way: lower `record_bytes`, `binary_text_bytes`, and `array_bytes` to what your workload actually needs. A limit is the cheapest defense there is.

## What is out of scope

- **Validation.** zmz checks what it needs to read and write correctly, not whether a file follows every rule of the mzML schema and its vocabulary mapping. That is [mzValidate](https://github.com/eneskemalergin/mzValidate)'s job.
- **Your allocator.** zmz bounds what it asks for and handles `OutOfMemory` cleanly everywhere, but how much memory is really available is up to the allocator you pass.
- **Files that change underneath.** A forward reader reads whatever bytes arrive. An `IndexedReader` notices a changed file (`StaleSource`) but cannot protect a lookup from a file rewritten in place between its checks.

If you find an input that crashes zmz or makes it misbehave, that is a security bug: please report it as [SECURITY.md](https://github.com/eneskemalergin/zmz/blob/main/SECURITY.md) describes.
