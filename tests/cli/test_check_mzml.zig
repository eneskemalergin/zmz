//! Checks the explicit-file checker's process status and output.

const std = @import("std");
const options = @import("check_test_options");

// One MS2 spectrum whose peak intensity (as in ProteoWizard's F114727) and lower isolation
// offset are malformed, beside a valid m/z, charge, and target.
const MALFORMED_FIELDS =
    "<?xml version='1.0' encoding='UTF-8'?><mzML xmlns='http://psi.hupo.org/ms/mzml' version='1.1.0'>" ++
    "<cvList count='1'><cv id='MS' fullName='PSI-MS' URI='urn:test'/></cvList>" ++
    "<fileDescription><fileContent/></fileDescription>" ++
    "<softwareList count='1'><software id='s' version='1'/></softwareList>" ++
    "<instrumentConfigurationList count='1'><instrumentConfiguration id='ic'/></instrumentConfigurationList>" ++
    "<dataProcessingList count='1'><dataProcessing id='dp'/></dataProcessingList>" ++
    "<run id='r' defaultInstrumentConfigurationRef='ic'><spectrumList count='1' defaultDataProcessingRef='dp'>" ++
    "<spectrum id='scan=1' index='0' defaultArrayLength='0'>" ++
    "<cvParam cvRef='MS' accession='MS:1000511' name='ms level' value='2'/>" ++
    "<precursorList count='1'><precursor><isolationWindow>" ++
    "<cvParam cvRef='MS' accession='MS:1000827' name='isolation window target m/z' value='445.3'/>" ++
    "<cvParam cvRef='MS' accession='MS:1000828' name='isolation window lower offset' value=''/>" ++
    "</isolationWindow><selectedIonList count='1'><selectedIon>" ++
    "<cvParam cvRef='MS' accession='MS:1000744' name='selected ion m/z' value='445.34'/>" ++
    "<cvParam cvRef='MS' accession='MS:1000041' name='charge state' value='2'/>" ++
    "<cvParam cvRef='MS' accession='MS:1000042' name='peak intensity' value='0 1+'/>" ++
    "</selectedIon></selectedIonList><activation/></precursor></precursorList>" ++
    "</spectrum></spectrumList></run></mzML>";

fn run(dir: std.Io.Dir, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(std.testing.allocator, std.testing.io, .{ .argv = argv, .cwd = .{ .dir = dir } });
}

test "[cli] - [check-mzml]: counts malformed precursor fields and checks the rest of the file" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = MALFORMED_FIELDS });
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, options.executable, std.testing.allocator);
    defer std.testing.allocator.free(executable);
    const result = try run(dir.dir, &.{ executable, "input.mzML" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqualStrings("input.mzML: records=1 arrays=0 values=0 lookups=1\n" ++
        "metadata: scans=0 precursors=1 selected_ions=1 products=0 quantities=2 unresolved_units=2" ++
        " disallowed_units=0 invalid_fields=2\n", result.stdout);
}

test "[cli] - [check-mzml]: stops at a file it cannot read, names it, and rejects a call without files" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "input.mzML", .data = MALFORMED_FIELDS });
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, options.executable, std.testing.allocator);
    defer std.testing.allocator.free(executable);
    const result = try run(dir.dir, &.{ executable, "missing.mzML", "input.mzML" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("missing.mzML: FileNotFound\n", result.stderr);
    const usage = try run(dir.dir, &.{executable});
    defer std.testing.allocator.free(usage.stdout);
    defer std.testing.allocator.free(usage.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, usage.term);
    try std.testing.expectEqualStrings("usage: zig build check-mzml -- FILE.mzML [FILE.mzML ...]\n", usage.stderr);
}
