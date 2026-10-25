import XCTest
import GRDB
import CryptoKit
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// The re-import rehearsal (`ImportRehearsal`) over the demo database and its evidence library:
/// runs end to end on a temporary copy, leaves the source database and library byte-identical,
/// and writes a report with every section.
final class ImportRehearsalTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportRehearsalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Every file under `root` (relative path → digest).
    private func tree(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))] = try digest(url)
        }
        return result
    }

    /// Planning is about 90 ms a document, so the full demo library (157 documents) takes 14 s to re-import. The
    /// assertions are about the rehearsal's bookkeeping (counts add up, statements excluded, filed figures
    /// unchanged, source untouched, every section in the report), none of which needs 157 documents: this
    /// keeps every statement and at most `perKind` documents of each other kind (the oldest by id), removed the way
    /// the Documents screen removes them, so every kind of the demo is still re-imported.
    private func trimLibrary(_ dbQueue: DatabaseQueue, evidence: URL, perKind: Int) throws {
        let library = EvidenceLibrary(root: evidence, database: dbQueue)
        let surplus: [Int64] = try dbQueue.read { db in
            var seen: [String: Int] = [:]
            var ids: [Int64] = []
            for document in try EvidenceDocument.order(Column("id")).fetchAll(db) {
                guard let id = document.id, document.kind != .bankStatement else { continue }
                let key = document.kind.rawValue + "/" + String(document.customKindId ?? 0)
                seen[key, default: 0] += 1
                if seen[key]! > perKind { ids.append(id) }
            }
            return ids
        }
        for id in surplus { try library.remove(id, force: true, guardingFiledYears: false) }
    }

    func testRehearsalOverTheDemoDatabaseAndLibrary() async throws {
        let databaseURL = folder.appendingPathComponent("demo.sqlite")
        let evidence = folder.appendingPathComponent("Evidence", isDirectory: true)
        let documentCount: Int
        let statementCount: Int
        do {
            let manager = try TestDatabase.demoManager(path: databaseURL.path, evidenceRoot: evidence)
            try trimLibrary(manager.dbQueue, evidence: evidence, perKind: 3)
            (documentCount, statementCount) = try await manager.dbQueue.read { db in
                (try EvidenceDocument.fetchCount(db),
                 try EvidenceDocument.filter(Column("kind") == DocumentKind.bankStatement.rawValue).fetchCount(db))
            }
            try manager.dbQueue.close()
        }
        XCTAssertGreaterThan(documentCount, statementCount, "the demo library holds documents besides statements")
        XCTAssertGreaterThan(statementCount, 0, "the demo library holds a statement to exclude")
        let databaseBefore = try digest(databaseURL)
        let libraryBefore = try tree(evidence)

        let report = try await ImportRehearsal.run(databasePath: databaseURL.path, libraryPath: evidence.path)

        XCTAssertEqual(report.deleted, documentCount - report.excluded.count, report.text)
        XCTAssertGreaterThanOrEqual(report.excluded.count, statementCount, report.text)
        XCTAssertGreaterThan(report.deleted, 0, report.text)
        XCTAssertEqual(report.deleted, report.cameBack + report.needsYou + report.duplicates + report.failed, report.text)
        XCTAssertGreaterThan(report.cameBack, 0, report.text)
        XCTAssertTrue(report.filedChanges.isEmpty, report.text)
        for heading in ["# Import rehearsal", "## Counts", "## Excluded (statements)", "## Filed returns",
                        "## Other tax-figure differences", "## Documents that came back", "## Documents that didn't come back"] {
            XCTAssertTrue(report.text.contains(heading), "\(heading) missing from\n\(report.text)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.workFolder.path), "the temporary copy is removed")

        XCTAssertEqual(try digest(databaseURL), databaseBefore, "the source database is only read")
        XCTAssertEqual(try tree(evidence), libraryBefore, "the source library is only read")
    }

    func testTheAppsDataIsRefusedWithoutPermission() throws {
        let database = folder.appendingPathComponent("x.sqlite")
        try Data().write(to: database)
        let library = folder.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        // A stand-in for the app's data, so the test needn't find the real one on this machine.
        let app = folder.appendingPathComponent("Application Support/Budget", isDirectory: true)
        let appLibrary = app.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: appLibrary, withIntermediateDirectories: true)
        let isAppData: (String) -> Bool = { TaxRegression.isAppDatabase($0, folders: [app]) }
        XCTAssertThrowsError(try ImportRehearsal.checkPaths(databasePath: database.path, libraryPath: appLibrary.path,
                                                            outPath: nil, allowAppData: false, isAppData: isAppData)) { error in
            XCTAssertEqual(error as? ImportRehearsal.PathError, .appData(appLibrary.standardizedFileURL.path))
        }
        XCTAssertNoThrow(try ImportRehearsal.checkPaths(databasePath: database.path, libraryPath: appLibrary.path,
                                                        outPath: nil, allowAppData: true, isAppData: isAppData))
        XCTAssertThrowsError(try ImportRehearsal.checkPaths(databasePath: database.path, libraryPath: library.path,
                                                            outPath: app.appendingPathComponent("out").path, allowAppData: true,
                                                            isAppData: isAppData),
                             "a report is never written into the app's data")
        // The default guard counts the app's real library as its data (paths only: nothing is opened).
        XCTAssertTrue(TaxRegression.isAppData(EvidenceLibrary.defaultRoot.path))
        XCTAssertThrowsError(try ImportRehearsal.checkPaths(databasePath: database.path, libraryPath: library.path,
                                                            outPath: EvidenceLibrary.defaultRoot.path, allowAppData: true),
                             "a report is never written into the app's data")
        XCTAssertNoThrow(try ImportRehearsal.checkPaths(databasePath: database.path, libraryPath: library.path,
                                                        outPath: folder.appendingPathComponent("out").path, allowAppData: false))
    }
}
