import Foundation
import BudgetCore
import BudgetDemo

// Builds the synthetic demo database (`DemoDatabase`): every screen with invented data, for
// the UI snapshot harness (`scripts/render-snapshots.sh`) and manual testing.
//
//   MakeDemoDatabase <out.sqlite> [--evidence <dir>] [--force] [--long-tenancy <receipts>]
//
// The evidence PDFs go to `<dir>` (default: `Evidence` beside the database, where the app
// looks), the document importer's samples (`DemoImportSamples`) to `ImportSamples` beside the
// database. Refuses the app's own data folder. With `--force` it replaces an earlier demo: a
// database carrying the demo id (`DemoMarker`), and evidence and samples folders holding the
// demo's marker files (or empty) — never anything else.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("MakeDemoDatabase: \(message)\n".utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var evidencePath: String?
var force = false
/// "Tenancy L"'s receipts (the snapshot harness's `--perf` timing): 0, none.
var longTenancyReceipts = 0
var positional: [String] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--evidence":
        guard !arguments.isEmpty else { fail("--evidence needs a folder") }
        evidencePath = arguments.removeFirst()
    case "--force": force = true
    case "--long-tenancy":
        guard let value = arguments.first.flatMap(Int.init), (1...240).contains(value) else { fail("--long-tenancy takes 1–240 receipts") }
        arguments.removeFirst()
        longTenancyReceipts = value
    case "-h", "--help":
        print("usage: MakeDemoDatabase <out.sqlite> [--evidence <dir>] [--force] [--long-tenancy <receipts>]")
        exit(0)
    default: positional.append(argument)
    }
}
guard positional.count == 1 else { fail("usage: MakeDemoDatabase <out.sqlite> [--evidence <dir>] [--force]", code: 2) }
let manager = FileManager.default
let output = URL(fileURLWithPath: TaxRegression.resolvedPath(positional[0]))
let evidence = URL(fileURLWithPath: TaxRegression.resolvedPath(evidencePath ?? output.deletingLastPathComponent()
    .appendingPathComponent("Evidence", isDirectory: true).path), isDirectory: true)
let samples = output.deletingLastPathComponent().appendingPathComponent("ImportSamples", isDirectory: true)
if TaxRegression.isAppData(output.path) || TaxRegression.isAppData(evidence.path) || TaxRegression.isAppData(samples.path) {
    fail("refusing to write into the app's own data folder", code: 2)
}

// Both are checked before either is removed, so a refusal leaves everything as it was.
var replacesDatabase = false
if manager.fileExists(atPath: output.path) {
    guard force else { fail("\(output.path) exists (pass --force to replace an earlier demo database)") }
    guard DemoMarker.isDemoDatabase(atPath: output.path) else {
        fail("\(output.path) isn't a demo database: not replacing it", code: 2)
    }
    replacesDatabase = true
}
var replacesEvidence = false
var isDirectory: ObjCBool = false
if manager.fileExists(atPath: evidence.path, isDirectory: &isDirectory) {
    guard isDirectory.boolValue else { fail("\(evidence.path) is a file, not an evidence folder", code: 2) }
    let contents = (try? manager.contentsOfDirectory(atPath: evidence.path)) ?? []
    if !contents.isEmpty {
        guard force, contents.contains(DemoMarker.evidenceFileName) else {
            fail("\(evidence.path) holds files that aren't the demo's evidence: not replacing it", code: 2)
        }
        replacesEvidence = true
    }
}
if manager.fileExists(atPath: samples.path, isDirectory: &isDirectory) {
    guard isDirectory.boolValue else { fail("\(samples.path) is a file, not an import samples folder", code: 2) }
    let contents = (try? manager.contentsOfDirectory(atPath: samples.path)) ?? []
    if !contents.isEmpty {
        guard force, contents.contains(DemoImportSamples.markerFileName) else {
            fail("\(samples.path) holds files that aren't the demo's import samples: not replacing it", code: 2)
        }
    }
}
if replacesDatabase {
    for suffix in ["", "-wal", "-shm", "-journal"] { try? manager.removeItem(atPath: output.path + suffix) }
}
if replacesEvidence {
    try? manager.removeItem(at: evidence)
}
do {
    try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let report = try DemoDatabase.build(at: output.path, evidenceRoot: evidence, longTenancyReceipts: longTenancyReceipts)
    print("Demo database: \(output.path)")
    print("Evidence: \(evidence.path)")
    // The samples are made from the finished database; `write` replaces an earlier set.
    let written = try DemoImportSamples.write(into: samples, databasePath: output.path)
    print("Import samples: \(samples.path) (\(written.count) files)")
    print(report.summary)
} catch {
    fail("\(error)")
}
