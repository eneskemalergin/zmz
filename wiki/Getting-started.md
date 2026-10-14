# Getting started

This page takes you from an empty project to a program that reads an mzML file. It assumes you know Zig; it does not assume you know mzML (that is [mzML in brief](mzML-in-brief)).

## Requirements

- Zig 0.16.0.
- A little-endian target. zmz is tested on x86_64 and aarch64 Linux and on aarch64 macOS; big-endian targets are refused at build time.

Nothing else: no C library, no system packages. zlib support comes from [zipir](https://github.com/eneskemalergin/zipir), a Zig package that `zig fetch` pins by hash.

## Add zmz to a project

From your project's directory:

```sh
zig fetch --save git+https://github.com/eneskemalergin/zmz#v0.1.0
```

This adds zmz 0.1.0 to your `build.zig.zon` with a content hash. Then import its module in `build.zig`:

```zig
const zmz = b.dependency("zmz", .{ .target = target, .optimize = optimize });
executable.root_module.addImport("zmz", zmz.module("zmz"));
```

> [!TIP]
> Always fetch a release tag, as above. Without one, `zig fetch` takes whatever the default branch holds that day. To upgrade, run the same command with the newer tag. A program can read `zmz.version` to report which one it was built with.

## Your first program

This prints each record's ID, its MS level, and how many arrays it holds:

```zig
const std = @import("std");
const mzml = @import("zmz").mzml;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    var buffer: [64 * 1024]u8 = undefined;
    var input = file.reader(init.io, &buffer);

    var reader = try mzml.StreamReader.init(init.gpa, &input.interface, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var arrays = mzml.DecodedArrays.init(init.gpa, .{});
    defer arrays.deinit();

    while (try reader.nextDecodedRecord(&arrays)) |record| {
        const level = if (record.node.kind == .spectrum) try record.msLevel(header.groups) else null;
        std.debug.print("{s} ms_level={?d} arrays={d}\n", .{ record.id, level, arrays.len() });
    }
}
```

Build it with `zig build -Doptimize=ReleaseFast` and run it on a file:

```text
$ zig-out/bin/read-mzml run.mzML
scan=1 ms_level=1 arrays=2
scan=2 ms_level=2 arrays=2
scan=3 ms_level=2 arrays=2
```

What happens here, in order:

1. `StreamReader.init` takes an allocator and a `std.Io.Reader`. It reads nothing yet.
2. `readHeader` reads everything before the first spectrum: vocabulary declarations, instruments, software, processing, and the parameter groups that records refer to (`header.groups`).
3. `nextDecodedRecord` reads one spectrum or chromatogram and decodes its arrays into `arrays`. It returns null at the end of the file.
4. `record` and the numbers in `arrays` are valid until the next call. That one rule matters a lot; [Ownership and lifetimes](Ownership-and-lifetimes) explains it.

> [!NOTE]
> zmz never guesses. A missing MS level is `null`, not 1; a missing unit stays missing; a malformed number is an error, not zero. Expect optionals and error unions, and handle them.

## Where to go next

- Read only some arrays, copy files, or walk raw XML: [Reading](Reading).
- Look up a spectrum by its ID: [Indexed access](Indexed-access).
- Write mzML: [Writing](Writing).
- The repository has [complete example programs](https://github.com/eneskemalergin/zmz/blob/main/examples/README.md) for each of these, built and tested with the library.
