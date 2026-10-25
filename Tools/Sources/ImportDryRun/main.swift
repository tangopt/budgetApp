// Sources/ImportDryRun/main.swift
//
// The document importer's plan worked out over a copy of a database, for checking it on real
// data (`ImportDryRun` in BudgetCore): prints the filed or paid figures that re-running the
// follow-on matching would change (baseline drift), how long each planning phase took, how
// many items each section of the review holds, and each Needs-you item's title with its first
// reason. Nothing is applied.
//
// Usage: swift run --package-path Tools ImportDryRun --db <path> [--allow-app-data] <files or folders…>
//   The database is opened read-only and copied to a temporary folder; only the copy is used
//   (migrated, planned against) and it is deleted afterwards. The evidence library is an empty
//   temporary folder. The files are only read.
//   --allow-app-data  lets the tool read the app's own database (the user's go); without it a
//                     database inside the app's data folder is refused — pass a copy.

import Foundation
import BudgetCore

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: swift run --package-path Tools ImportDryRun --db <path> [--allow-app-data] <files or folders…>

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var allowAppData = false
var databasePath: String?
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--allow-app-data": allowAppData = true
    case "--db": databasePath = remaining.popFirst() ?? { usage() }()
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard let databasePath, !paths.isEmpty else { usage() }

/// `~` expanded and the path standardised, so the guard sees what is opened.
func normalized(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}
let sourcePath = normalized(databasePath)
guard FileManager.default.fileExists(atPath: sourcePath) else { fail("No database at \(sourcePath)") }
if TaxRegression.isAppData(sourcePath), !allowAppData {
    fail("Refusing to open the app's own database (\(sourcePath)): pass a copy, or --allow-app-data (it is only read and copied).")
}
let files = paths.map { URL(fileURLWithPath: normalized($0)) }
for file in files where !FileManager.default.fileExists(atPath: file.path) { fail("No file or folder at \(file.path)") }

/// Holds the async run's result for the synchronous tool.
final class ResultBox: @unchecked Sendable {
    var value: Result<ImportDryRun.Report, Error>?
}
let box = ResultBox()
let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    do {
        box.value = .success(try await ImportDryRun.run(databasePath: sourcePath, files: files))
    } catch {
        box.value = .failure(error)
    }
    semaphore.signal()
}
semaphore.wait()
switch box.value {
case .success(let report): print(report.text)
case .failure(let error): fail("Failed: \(error)")
case nil: fail("Failed: no result")
}
