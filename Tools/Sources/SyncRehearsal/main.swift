// Sources/SyncRehearsal/main.swift
//
// The sync rehearsal (`SyncRehearsal` in BudgetCore), on a copy: step 3's migration (createSync) and backfill,
// every existing table compared with the original; step 6's turn-on on the copy (timestamped backup, the ownership
// sheet saved with the choices given, the upload begun as the admin); the whole outgoing payload set generated
// offline by the admin's Mac's engine (an in-memory cloud with CloudKit's limits — nothing is sent), every save
// audited per zone (nothing below Everything may ever reach the household zone); no value outside the encrypted
// fields; then applied into the admin's other device (both zones) and a member stand-in (household only).
// Prints counts only, never a value or a name, and writes a markdown report.
//
// Usage: swift run --package-path Tools SyncRehearsal --db <copy of the database> [--library <evidence folder>]
//                                [--ownership <choices.json>] [--joint <account id>]… [--level <account id>=<level>]…
//                                [--out <report folder>] [--keep]
//   --db         a copy of the database: the app's own database is refused. It is opened read-only
//                and copied again into a temporary folder; only those copies are written.
//   --library    the evidence library, to seal the documents' files (copied first, only read);
//                without it documents go without their files and the document totals are 0.
//   --ownership  the ownership choices as JSON (never committed):
//                {"joint": [12], "levels": {"7": "everything", "9": "balanceOnly"}}
//   --joint      an account that is joint (at Everything); repeatable.
//   --level      an account's level: everything, categoryTotals, balanceOnly or hidden; repeatable.
//                Accounts not named take the ownership sheet's defaults (the admin's; personal ones at
//                Balance only, property ones at Everything). A copy whose owners are already confirmed
//                keeps them, and refuses choices.
//   --out        where the report goes (default: the temporary directory); never the app's data.
//   --keep       keep the temporary working folder (its path is printed).
// Exit status: 0 when every check passed, 1 when one failed or the run failed, 2 for bad arguments.

import Foundation
import BudgetCore

let usageText = """
    Usage: swift run --package-path Tools SyncRehearsal --db <copy of the database> [--library <evidence folder>]
                     [--ownership <choices.json>] [--joint <account id>]... [--level <account id>=<level>]...
                     [--out <report folder>] [--keep]
      --db         a copy of the database (never the app's own)
      --library    the evidence library (copied, only read)
      --ownership  ownership choices as JSON: {"joint": [12], "levels": {"7": "everything", "9": "balanceOnly"}}
      --joint      an account that is joint (at Everything); repeatable
      --level      <account id>=<everything|categoryTotals|balanceOnly|hidden>; repeatable
      --out        the report folder (default: the temporary directory)
      --keep       keep the temporary working folder

    """

func usage() -> Never {
    FileHandle.standardError.write(Data(usageText.utf8))
    exit(2)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("SyncRehearsal: \(message)\n".utf8))
    exit(code)
}

var keep = false
var databasePath: String?
var libraryPath: String?
var outPath: String?
var ownershipPath: String?
var choices = RehearsalOwnership()
var remaining = Array(CommandLine.arguments.dropFirst())[...]
do {
    while let argument = remaining.popFirst() {
        switch argument {
        case "--help", "-h":
            print(usageText, terminator: "")
            exit(0)
        case "--keep": keep = true
        case "--db": databasePath = remaining.popFirst() ?? { usage() }()
        case "--library": libraryPath = remaining.popFirst() ?? { usage() }()
        case "--out": outPath = remaining.popFirst() ?? { usage() }()
        case "--ownership": ownershipPath = remaining.popFirst() ?? { usage() }()
        case "--joint": try choices.addJoint(remaining.popFirst() ?? { usage() }())
        case "--level": try choices.addLevel(remaining.popFirst() ?? { usage() }())
        default: usage()
        }
    }
} catch {
    fail(error.localizedDescription, code: 2)
}
guard let databasePath else { usage() }
var ownership = RehearsalOwnership()
if let ownershipPath {
    do {
        ownership = try RehearsalOwnership.load(from: URL(fileURLWithPath: SyncRehearsal.normalized(ownershipPath)))
    } catch {
        fail("couldn't read the ownership choices at \(ownershipPath): \(error.localizedDescription)", code: 2)
    }
}
ownership.joint.formUnion(choices.joint)
ownership.levels.merge(choices.levels) { _, flag in flag }
let chosenOwnership = ownership

let paths: (database: String, library: String?)
do {
    paths = try SyncRehearsal.checkPaths(databasePath: databasePath, libraryPath: libraryPath)
} catch {
    fail(error.localizedDescription, code: 2)
}
let outFolder = URL(fileURLWithPath: outPath.map(SyncRehearsal.normalized)
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("SyncRehearsalReports").path, isDirectory: true)
if TaxRegression.isAppData(outFolder.path) { fail("the report never goes into the app's data folder: \(outFolder.path)", code: 2) }

/// Holds the async run's result for the synchronous tool.
final class ResultBox: @unchecked Sendable {
    var value: Result<SyncRehearsal.Report, Error>?
}
let box = ResultBox()
let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    do {
        box.value = .success(try await SyncRehearsal.run(databasePath: paths.database, libraryPath: paths.library, keep: keep, ownership: chosenOwnership))
    } catch {
        box.value = .failure(error)
    }
    semaphore.signal()
}
semaphore.wait()
switch box.value {
case .success(let report):
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let file = outFolder.appendingPathComponent("sync-rehearsal-\(formatter.string(from: Date())).md")
    print(report.text)
    do {
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        try report.text.write(to: file, atomically: true, encoding: .utf8)
        print("Report: \(file.path)")
    } catch {
        FileHandle.standardError.write(Data("SyncRehearsal: couldn't write the report at \(file.path): \(error)\n".utf8))
    }
    if keep { print("Working copy: \(report.workFolder.path)") }
    exit(report.passed ? 0 : 1)
case .failure(let error):
    // Counts and kinds only (`SyncRehearsal.failure`): never an error's own text, which may quote a value.
    let failure = SyncRehearsal.failure(error)
    fail("failed: \(failure.message)", code: failure.exitCode)
case nil: fail("failed: no result")
}
