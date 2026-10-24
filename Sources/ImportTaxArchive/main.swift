// Sources/ImportTaxArchive/main.swift
//
// Brings a folder of earlier tax years' paperwork into Mango (`TaxArchiveImport`): P60s, P45s
// and P11Ds become employment records where a year has none (never overwriting what a filed
// return recorded), every other document goes through the importer (Ready items applied,
// Needs-you items listed for the app's review, duplicates skipped), UK tax documents are
// linked to the person's tax year, and a `TaxDataPlan` can set years up first. Every filed
// figure of the settings must come out equal to the return as filed or unchanged — else the
// run is refused.
//
// Always rehearsed on copies first: the database is copied (the source opened read-only) and
// the library folder copied beside it; the report comes from that run. With --apply, and only
// when the rehearsal passed, the same run is made on the real database and library (a backup
// of the database is written first).
//
// The settings, the plan and the archive are personal data kept outside the repository.
//
// Usage: swift run ImportTaxArchive <db> --library <evidence folder> --folder <archive folder>
//          [--filed <sa_settings.json>] [--plan <tax_data_plan.json>] [--report <out.md>]
//          [--work <folder>] [--apply] [--allow-app-data] [--force-running] [--no-ocr]
//   --work            where the rehearsal's copies go, in a fresh subfolder per run (kept; default: a temporary
//                     folder, deleted). Never the library's or the database's own folder.
//   --apply           after a passing rehearsal, run on <db> and --library themselves. Needs this build merged,
//                     installed and opened once first (the database must already be at this build's migrations:
//                     the tool never migrates the real database). If the real run's own guard refuses, the
//                     database backup is restored and the files the run added to the library are removed.
//   --allow-app-data  lets --apply write the app's own database and library (the user's go).
//   --force-running   lets --apply go ahead while Mango is running (else refused: quit it first).
//   --no-ocr          don't read scans by text recognition (quicker rehearsals).

import AppKit
import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: ImportTaxArchive <db> --library <evidence folder> --folder <archive folder> [--filed <json>] [--plan <json>]
                 [--report <out.md>] [--work <folder>] [--apply] [--allow-app-data] [--force-running] [--no-ocr]

        """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var apply = false, allowAppData = false, forceRunning = false, ocr = true
var libraryPath: String?, folderPath: String?, filedPath: String?, planPath: String?, reportPath: String?, workPath: String?
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--apply": apply = true
    case "--allow-app-data": allowAppData = true
    case "--force-running": forceRunning = true
    case "--no-ocr": ocr = false
    case "--library": libraryPath = remaining.popFirst() ?? { usage() }()
    case "--folder": folderPath = remaining.popFirst() ?? { usage() }()
    case "--filed": filedPath = remaining.popFirst() ?? { usage() }()
    case "--plan": planPath = remaining.popFirst() ?? { usage() }()
    case "--report": reportPath = remaining.popFirst() ?? { usage() }()
    case "--work": workPath = remaining.popFirst() ?? { usage() }()
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let libraryPath, let folderPath else { usage() }

func normalized(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}
let fileManager = FileManager.default
let dbPath = normalized(paths[0])
let library = normalized(libraryPath)
let archive = normalized(folderPath)
guard fileManager.fileExists(atPath: dbPath) else { fail("No database at \(dbPath)") }
var isFolder: ObjCBool = false
guard fileManager.fileExists(atPath: library, isDirectory: &isFolder), isFolder.boolValue else { fail("No library folder at \(library)") }
guard fileManager.fileExists(atPath: archive, isDirectory: &isFolder), isFolder.boolValue else { fail("No archive folder at \(archive)") }

/// Every path written is checked against the app's data folder.
func guardWrite(_ path: String, _ what: String) {
    if let refusal = TaxDataPlan.writeRefusal(path: path, what: what, allowAppData: allowAppData) { fail(refusal) }
}
if apply {
    guardWrite(dbPath, "the database")
    guardWrite(library, "the library")
    do { if let refusal = try TaxDataPlan.migrationRefusal(path: dbPath) { fail(refusal) } } catch { fail("Can't read the database: \(error)") }
    if !forceRunning && AppIdentity.macBundleIdentifiers.contains(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
        fail("Mango is running: quit it before --apply (or pass --force-running).")
    }
}
if let reportPath {
    guardWrite(normalized(reportPath), "the report")
    if TaxRegression.isSameFile(normalized(reportPath), dbPath) { fail("The report path is the database: pick another file.") }
}
func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path.lowercased() }
func isInside(_ path: String, _ folder: String) -> Bool { resolved(path) == resolved(folder) || resolved(path).hasPrefix(resolved(folder) + "/") }
if let workPath {
    let work = normalized(workPath)
    if TaxRegression.isAppData(work) { fail("The work folder is inside the app's data: pick another.") }
    if isInside(work, library) || isInside(library, work) { fail("The work folder must be apart from the library (\(library)).") }
    if isInside(work, (dbPath as NSString).deletingLastPathComponent) || isInside(dbPath, work) { fail("The work folder must be apart from the database's folder.") }
    if isInside(work, archive) || isInside(archive, work) { fail("The work folder must be apart from the archive folder.") }
}
if isInside(archive, library) { fail("The archive folder is the library itself.") }

/// Puts the database back from `backup` and removes every library file not in `filesBefore`.
func restore(backup: String, filesBefore: Set<String>, libraryFiles: () -> Set<String>) throws {
    try DatabaseQueue(path: backup).backup(to: DatabaseQueue(path: dbPath))
    for relative in libraryFiles().subtracting(filesBefore).sorted(by: { $0.count > $1.count }) {
        let path = (library as NSString).appendingPathComponent(relative)
        var isFolder: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue { try? fileManager.removeItem(atPath: path) }
    }
}

final class Box<T>: @unchecked Sendable { var value: T? }
func awaitResult<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = Box<Result<T, Error>>()
    Task.detached {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.value!.get()
}

do {
    var options = TaxArchiveImport.Options(folder: URL(fileURLWithPath: archive, isDirectory: true))
    options.allowOCR = ocr
    if let filedPath {
        options.filed = try JSONDecoder().decode(SelfAssessmentRegression.Settings.self, from: Data(contentsOf: URL(fileURLWithPath: normalized(filedPath))))
    }
    if let planPath {
        options.plan = try TaxDataPlan.decodePlan(Data(contentsOf: URL(fileURLWithPath: normalized(planPath))))
    }
    let runOptions = options

    // The rehearsal on copies, in a fresh subfolder: nothing that exists is ever removed.
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let parent = URL(fileURLWithPath: workPath.map(normalized) ?? fileManager.temporaryDirectory.appendingPathComponent("ImportTaxArchive").path, isDirectory: true)
    let work = parent.appendingPathComponent("rehearsal-\(stamp.string(from: Date()))-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
    let copyPath = work.appendingPathComponent("copy.sqlite").path
    let copyLibrary = work.appendingPathComponent("Evidence", isDirectory: true)
    do {
        var readOnly = Configuration()
        readOnly.readonly = true
        let source = try DatabaseQueue(path: dbPath, configuration: readOnly)
        let target = try DatabaseQueue(path: copyPath)
        try source.backup(to: target)
        try source.close()
        try target.close()
    }
    // A clone (APFS) when the volume allows, else a plain copy.
    if copyfile(library, copyLibrary.path, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)) != 0 {
        try? fileManager.removeItem(at: copyLibrary)
        try fileManager.copyItem(at: URL(fileURLWithPath: library, isDirectory: true), to: copyLibrary)
    }
    print("Rehearsal on copies in \(work.path)")
    let rehearsal: TaxArchiveImport.Report = try {
        let manager = try DatabaseManager(path: copyPath)
        try manager.migrate()
        let evidence = EvidenceLibrary(root: copyLibrary, database: manager.dbQueue)
        defer { try? manager.dbQueue.close() }
        return try awaitResult { try await TaxArchiveImport.run(dbQueue: manager.dbQueue, library: evidence, options: runOptions) { print("  \($0)") } }
    }()
    var text = rehearsal.text
    if !apply {
        print(text)
        if workPath == nil { try? fileManager.removeItem(at: work) } else { print("Copies kept in \(work.path)") }
    } else if !rehearsal.passed {
        print(text)
        fail("The rehearsal was refused: nothing written to \(dbPath).")
    } else {
        // The real run, exactly as rehearsed.
        let backupPath = dbPath + ".pre-tax-archive-backup-" + stamp.string(from: Date())
        guardWrite(backupPath, "the backup")
        try DatabaseQueue(path: dbPath).backup(to: DatabaseQueue(path: backupPath))
        print("Backup: \(backupPath)")
        /// Every file in the library before the run, so what the run adds can be taken back.
        func libraryFiles() -> Set<String> {
            Set((fileManager.enumerator(atPath: library)?.allObjects as? [String]) ?? [])
        }
        let filesBefore = libraryFiles()
        let manager = try DatabaseManager(path: dbPath)
        try manager.migrate()
        let evidence = EvidenceLibrary(root: URL(fileURLWithPath: library, isDirectory: true), database: manager.dbQueue)
        let real: TaxArchiveImport.Report
        do {
            real = try awaitResult { try await TaxArchiveImport.run(dbQueue: manager.dbQueue, library: evidence, options: runOptions) { print("  \($0)") } }
        } catch {
            try? manager.dbQueue.close()
            try restore(backup: backupPath, filesBefore: filesBefore, libraryFiles: libraryFiles)
            fail("The real run failed (\(error)): the database was restored from \(backupPath) and the files it had added to the library removed.")
        }
        text = "# Rehearsal\n\n" + rehearsal.text + "\n\n# Real run\n\n" + real.text
        print(real.text)
        if !real.passed {
            try? manager.dbQueue.close()
            try restore(backup: backupPath, filesBefore: filesBefore, libraryFiles: libraryFiles)
            let note = "REFUSED by the real run's own guard: the database was restored from \(backupPath) and the files the run had added to the library were removed. Nothing changed."
            text += "\n\n" + note + "\n"
            print(note)
        }
        if workPath == nil { try? fileManager.removeItem(at: work) }
    }
    if let reportPath { try text.write(toFile: normalized(reportPath), atomically: true, encoding: .utf8) }
} catch {
    fail("Failed: \(error)")
}
