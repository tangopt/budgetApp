// Sources/SyncRehearsal/main.swift
//
// The step 3 sync migration rehearsal (plan Task 8; `SyncRehearsal` in BudgetCore), on a copy:
// migrate (createSync) and backfill, compare every existing table with the original, generate the
// whole outgoing payload set offline (an in-memory cloud with CloudKit's limits — nothing is sent),
// check no value is outside the encrypted fields, and time applying it into an empty database
// through the checked pull. Prints the summary and writes a markdown report.
//
// Usage: swift run SyncRehearsal --db <copy of the database> [--library <evidence folder>]
//                                [--out <report folder>] [--keep]
//   --db       a copy of the database: the app's own database is refused. It is opened read-only
//              and copied again into a temporary folder; only those copies are written.
//   --library  the evidence library, to seal the documents' files (copied first, only read);
//              without it documents go without their files and the document totals are 0.
//   --out      where the report goes (default: the temporary directory); never the app's data.
//   --keep     keep the temporary working folder (its path is printed).
// Exit status: 0 when every check passed, 1 when one failed or the run failed, 2 for bad arguments.

import Foundation
import BudgetCore

func usage() -> Never {
    FileHandle.standardError.write(Data("Usage: SyncRehearsal --db <copy of the database> [--library <evidence folder>] [--out <report folder>] [--keep]\n".utf8))
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
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--keep": keep = true
    case "--db": databasePath = remaining.popFirst() ?? { usage() }()
    case "--library": libraryPath = remaining.popFirst() ?? { usage() }()
    case "--out": outPath = remaining.popFirst() ?? { usage() }()
    default: usage()
    }
}
guard let databasePath else { usage() }

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
        box.value = .success(try await SyncRehearsal.run(databasePath: paths.database, libraryPath: paths.library, keep: keep))
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
case .failure(let error): fail("failed: \(error)")
case nil: fail("failed: no result")
}
