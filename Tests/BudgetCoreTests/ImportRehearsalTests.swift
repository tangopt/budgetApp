import XCTest
import GRDB
import CryptoKit
@testable import BudgetCore
@testable import BudgetDemo

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

    func testRehearsalOverTheDemoDatabaseAndLibrary() async throws {
        let databaseURL = folder.appendingPathComponent("demo.sqlite")
        let evidence = folder.appendingPathComponent("Evidence", isDirectory: true)
        let documentCount: Int
        let statementCount: Int
        do {
            let manager = try DatabaseManager(path: databaseURL.path)
            try manager.migrate()
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try DemoDatabase.build(dbQueue: manager.dbQueue, evidenceRoot: evidence)
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
