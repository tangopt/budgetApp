import XCTest
import GRDB
import CryptoKit
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// The dry-run tool's core (`ImportDryRun`) over the demo database and its import samples:
/// the report's sections and Needs-you lines, and neither the database nor the files written.
final class ImportDryRunTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportDryRunTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func testDryRunOverTheDemoDatabase() async throws {
        let databaseURL = folder.appendingPathComponent("demo.sqlite")
        let samples: [URL]
        do {
            let evidence = folder.appendingPathComponent("Evidence", isDirectory: true)
            let manager = try TestDatabase.demoManager(path: databaseURL.path, evidenceRoot: evidence)
            samples = try DemoImportSamples.write(into: folder.appendingPathComponent("ImportSamples", isDirectory: true), dbQueue: manager.dbQueue)
            try manager.dbQueue.close()
        }
        let before = try digest(databaseURL)
        let sampleDigests = try samples.map(digest)

        let report = try await ImportDryRun.run(databasePath: databaseURL.path, files: [folder.appendingPathComponent("ImportSamples", isDirectory: true)])

        XCTAssertEqual(report.sections[.ready], 8, report.text)
        XCTAssertEqual(report.sections[.duplicates], 2, report.text)
        XCTAssertEqual(report.sections[.needsYou], 5, report.text)
        XCTAssertEqual(report.needsYou.count, 5, report.text)
        XCTAssertTrue(report.needsYou.contains { $0.hasPrefix("Letter.pdf") }, report.text)
        for heading in ["== Baseline drift", "== Timings ==", "filed-year guard", "== Sections ==", "Needs you: 5", "== Needs you =="] {
            XCTAssertTrue(report.text.contains(heading), "\(heading) missing from\n\(report.text)")
        }
        XCTAssertEqual(try digest(databaseURL), before, "the source database is only read")
        XCTAssertEqual(try samples.map(digest), sampleDigests, "the files are only read")
    }
}
