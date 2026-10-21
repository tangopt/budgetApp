// Sources/ImportRehearsal/main.swift
//
// Rehearses "delete every imported document (not the statements) and import them again" on a
// copy (`ImportRehearsal` in BudgetCore), and writes a before/after report.
//
// Usage: swift run ImportRehearsal --db <path> --library <evidence library folder>
//                                  [--allow-app-data] [--out <report folder>] [--keep]
//   The database is opened read-only and copied (backup) into a temporary folder; the library
//   folder is copied there too. Only the copies are written; the temporary folder is deleted
//   afterwards unless --keep. Nothing of the source database or library is ever written.
//   --allow-app-data  lets the tool read the app's own database and library (the user's go);
//                     without it either inside the app's data folder is refused — pass copies.
//   --out             where the markdown report goes (never inside the app's data or the
//                     library); default: the temporary directory. Its path is printed.

import Foundation
import BudgetCore

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: ImportRehearsal --db <path> --library <evidence library folder> [--allow-app-data] [--out <report folder>] [--keep]

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var allowAppData = false
var keep = false
var databasePath: String?
var libraryPath: String?
var outPath: String?
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--allow-app-data": allowAppData = true
    case "--keep": keep = true
    case "--db": databasePath = remaining.popFirst() ?? { usage() }()
    case "--library": libraryPath = remaining.popFirst() ?? { usage() }()
    case "--out": outPath = remaining.popFirst() ?? { usage() }()
    default: usage()
    }
}
guard let databasePath, let libraryPath else { usage() }

let paths: (database: String, library: String, out: String?)
do {
    paths = try ImportRehearsal.checkPaths(databasePath: databasePath, libraryPath: libraryPath, outPath: outPath, allowAppData: allowAppData)
} catch {
    fail(error.localizedDescription)
}
let outFolder = URL(fileURLWithPath: paths.out ?? FileManager.default.temporaryDirectory.appendingPathComponent("ImportRehearsalReports").path,
                    isDirectory: true)

/// Holds the async run's result for the synchronous tool.
final class ResultBox: @unchecked Sendable {
    var value: Result<ImportRehearsal.Report, Error>?
}
let box = ResultBox()
let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    do {
        box.value = .success(try await ImportRehearsal.run(databasePath: paths.database, libraryPath: paths.library, keep: keep))
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
    let file = outFolder.appendingPathComponent("import-rehearsal-\(formatter.string(from: Date())).md")
    do {
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        try report.text.write(to: file, atomically: true, encoding: .utf8)
    } catch {
        print(report.text)
        fail("Couldn't write the report at \(file.path): \(error)")
    }
    print("Deleted \(report.deleted) · came back \(report.cameBack) · needs you \(report.needsYou) · duplicates \(report.duplicates) · failed \(report.failed) · filed-return changes \(report.filedChanges.count)")
    print("Report: \(file.path)")
    if keep { print("Working copy: \(report.workFolder.path)") }
case .failure(let error): fail("Failed: \(error)")
case nil: fail("Failed: no result")
}
