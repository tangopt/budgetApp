// Sources/ImportExistingEvidence/main.swift
//
// One-off initial evidence import (plan 2026-10-16 phase 1, Task 6; EvidenceInitialImport):
// registers the Lisboa, Tax and IRS UK folders as evidence sources, scans them, copies the
// evidence-relevant documents into the library — linking each to its transaction when the
// match is confident (on or after --min-date), marking recent unmatched or ambiguous ones
// "needs review" — seeds the Lisbon missing-evidence rules, and reports. The source folders
// are only read. The move maps in Tax/_app-import supply canonical names when present.
//
// Usage: swift run ImportExistingEvidence <db-path> --library <evidence-dir> [--dry-run]
//          [--min-date 2023-01-01] [--folder <dir>]... [--move-map <csv>]... [--review-limit N]
//   --dry-run   runs everything on a temporary copy of the database and a temporary library,
//               prints the report and deletes both: neither <db-path> nor --library is touched.
//   --folder    replaces the default folders (repeatable).
//   --move-map  replaces the default move maps (repeatable).

import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: ImportExistingEvidence <db-path> --library <evidence-dir> [--dry-run] [--min-date YYYY-MM-DD]
                 [--folder <dir>]... [--move-map <csv>]... [--review-limit N]

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let defaultFolders = [
    "\(home)/Documents/Personal/Casa/Lisboa",
    "\(home)/Documents/Personal/Documentos/Tax",
    "\(home)/Downloads/IRS UK"
]
let defaultMoveMaps = [
    "\(home)/Documents/Personal/Documentos/Tax/_app-import/lisboa_move_map.csv",
    "\(home)/Documents/Personal/Documentos/Tax/_app-import/tax_move_map.csv"
]

var dryRun = false
var libraryPath: String?
var minDateText = "2023-01-01"
var folders: [String] = []
var moveMaps: [String] = []
var reviewLimit = 40
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--dry-run": dryRun = true
    case "--library": libraryPath = remaining.popFirst() ?? { usage() }()
    case "--min-date": minDateText = remaining.popFirst() ?? { usage() }()
    case "--folder": folders.append(remaining.popFirst() ?? { usage() }())
    case "--move-map": moveMaps.append(remaining.popFirst() ?? { usage() }())
    case "--review-limit": reviewLimit = Int(remaining.popFirst() ?? { usage() }()) ?? { usage() }()
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let libraryPath else { usage() }
let dbPath = paths[0]
guard FileManager.default.fileExists(atPath: dbPath) else { fail("No database at \(dbPath)") }
if folders.isEmpty { folders = defaultFolders }
if moveMaps.isEmpty { moveMaps = defaultMoveMaps.filter { FileManager.default.fileExists(atPath: $0) } }

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
let dayFormatter = DateFormatter()
dayFormatter.calendar = calendar
dayFormatter.timeZone = calendar.timeZone
dayFormatter.locale = Locale(identifier: "en_US_POSIX")
dayFormatter.dateFormat = "yyyy-MM-dd"
guard let minDate = dayFormatter.date(from: minDateText) else { fail("Bad --min-date \(minDateText)") }

let now = Date()
let current = UKTaxYear.containing(now)
let taxYears = Array(Set([2023, 2024, 2025].map(UKTaxYear.init(startYear:)) + [current])).sorted()

var canonicalNames: [String: String] = [:]
for path in moveMaps {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("Can't read move map \(path)") }
    canonicalNames.merge(EvidenceInitialImport.canonicalNames(fromMoveMap: text)) { first, _ in first }
}

let fileManager = FileManager.default
var temporary: URL?
defer { if let temporary { try? fileManager.removeItem(at: temporary) } }

do {
    var workingDB = dbPath
    var workingLibrary = URL(fileURLWithPath: libraryPath, isDirectory: true)
    if dryRun {
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("ImportExistingEvidence-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        temporary = scratch
        workingDB = scratch.appendingPathComponent("copy.sqlite").path
        let source = try DatabaseQueue(path: dbPath, configuration: { var c = Configuration(); c.readonly = true; return c }())
        let copy = try DatabaseQueue(path: workingDB)
        try source.backup(to: copy)
        workingLibrary = scratch.appendingPathComponent("Evidence", isDirectory: true)
    }
    let manager = try DatabaseManager(path: workingDB)
    try manager.migrate()
    let library = EvidenceLibrary(root: workingLibrary, database: manager.dbQueue)
    let urls = folders.map { URL(fileURLWithPath: $0, isDirectory: true) }

    print("Database: \(dbPath)\(dryRun ? " (dry run on a temporary copy — nothing is kept)" : "")")
    print("Library: \(dryRun ? workingLibrary.path + " (temporary)" : workingLibrary.path)")
    print("Minimum transaction date: \(minDateText); review window \(minDateText) … \(dayFormatter.string(from: now))")
    print("Move-map names: \(canonicalNames.count) from \(moveMaps.count) map(s)")
    let options = EvidenceInitialImport.Options(minimumTransactionDate: minDate, reviewWindow: DateInterval(start: minDate, end: now),
                                                canonicalNames: canonicalNames, taxYears: taxYears)
    let report = try EvidenceInitialImport.run(library: library, folderURLs: urls, options: options, now: now) { print($0) }
    print(report.text(reviewLimit: reviewLimit))
    print(dryRun ? "Dry run: temporary copy discarded." : "Done.")
} catch {
    if let temporary { try? fileManager.removeItem(at: temporary) }
    fail("Failed: \(error)")
}
