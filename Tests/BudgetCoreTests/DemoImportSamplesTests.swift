import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

/// The demo's import samples (`DemoImportSamples`, the Imports snapshot routes' files): read by
/// the real pipeline over the demo database, they fill Ready, Duplicates and Needs you — two
/// each, one of them held by a filed return.
final class DemoImportSamplesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DemoImportSamples-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testDemoSamplesProduceEachSection() async throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let evidence = folder.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try DemoDatabase.build(dbQueue: manager.dbQueue, evidenceRoot: evidence)
        let samples = try DemoImportSamples.write(into: folder.appendingPathComponent("ImportSamples", isDirectory: true),
                                                  dbQueue: manager.dbQueue)
        XCTAssertEqual(samples.count, 6)

        let library = EvidenceLibrary(root: evidence, database: manager.dbQueue)
        let pipeline = ImportPipeline(dbQueue: manager.dbQueue, library: library,
                                      categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let plan = try await pipeline.plan(samples)
        let described = plan.items.map { "\($0.file.fileName): \($0.section) \($0.needsYouReasons) \($0.duplicate?.of ?? "")" }
            .joined(separator: "\n")

        XCTAssertEqual(plan.items(in: .ready).count, 2, described)
        XCTAssertEqual(plan.items(in: .duplicates).count, 2, described)
        XCTAssertEqual(plan.items(in: .needsYou).count, 2, described)
        XCTAssertTrue(plan.items(in: .needsYou).contains { $0.issues.contains { if case .filedYear = $0.kind { true } else { false } } },
                      described)
        // Each sample where it is meant to be: the receipt and the insurance receipt linked,
        // the copy and the re-issued invoice skipped, the P60 held, the letter unknown.
        XCTAssertTrue(plan.items(in: .ready).allSatisfy { !$0.links.isEmpty }, described)
        XCTAssertEqual(Set(plan.items(in: .duplicates).compactMap { $0.duplicate?.level }), Set<ImportDuplicate.Level>([.file, .document]), described)
        XCTAssertTrue(plan.items(in: .needsYou).contains { $0.file.fileName == "Letter.pdf" && $0.recognition.kind == .unknown }, described)
        // The corrected P60 (the stored employer, pay £1,000 more) is not taken for a copy: it is
        // possibly a corrected version, and the filed 2024/25 return holds it.
        let p60 = try XCTUnwrap(plan.items.first { $0.recognition.kind == .payrollForm(.p60) }, described)
        XCTAssertNil(p60.duplicate, described)
        XCTAssertTrue(p60.issues.contains { $0.id == ImportDuplicates.correctedVersionIssueId && $0.reason.hasSuffix("Pay £39,840.00 → £40,840.00") },
                      described)
        XCTAssertTrue(p60.issues.contains(where: ImportResolutions.isFiledYearHold), described)
        // Written again (MakeDemoDatabase --force), the folder holds the same six.
        XCTAssertEqual(try DemoImportSamples.write(into: folder.appendingPathComponent("ImportSamples", isDirectory: true),
                                                   dbQueue: manager.dbQueue).map(\.lastPathComponent),
                       samples.map(\.lastPathComponent))
    }
}
