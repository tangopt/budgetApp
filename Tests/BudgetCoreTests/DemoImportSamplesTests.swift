import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

/// The demo's import samples (`DemoImportSamples`, the Imports snapshot routes' files): read by
/// the real pipeline over the demo database, they fill Ready (four: a BBVA statement and a new
/// utility invoice among them), Duplicates (two) and Needs you (three: one held by a filed return, a UK CSV with no account).
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
        XCTAssertEqual(samples.count, 9)

        let library = EvidenceLibrary(root: evidence, database: manager.dbQueue)
        let pipeline = ImportPipeline(dbQueue: manager.dbQueue, library: library,
                                      categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        let plan = try await pipeline.plan(samples)
        let described = plan.items.map { "\($0.file.fileName): \($0.section) \($0.needsYouReasons) \($0.duplicate?.of ?? "")" }
            .joined(separator: "\n")

        XCTAssertEqual(plan.items(in: .ready).count, 4, described)
        XCTAssertEqual(plan.items(in: .duplicates).count, 2, described)
        XCTAssertEqual(plan.items(in: .needsYou).count, 3, described)
        XCTAssertTrue(plan.items(in: .needsYou).contains { $0.issues.contains { if case .filedYear = $0.kind { true } else { false } } },
                      described)
        // Each sample where it is meant to be: the receipt and the insurance receipt linked,
        // the copy and the re-issued invoice skipped, the P60 held, the letter unknown.
        XCTAssertTrue(plan.items(in: .ready).filter { ![.bbvaStatement, .utilityInvoice].contains($0.recognition.kind) }
                          .allSatisfy { !$0.links.isEmpty }, described)
        // Example Water's next invoice: recorded (a new number), no debit to link yet.
        let invoice = try XCTUnwrap(plan.items(in: .ready).first { $0.recognition.kind == .utilityInvoice }, described)
        guard case .utilityInvoice(let recorded) = invoice.effect else { return XCTFail(described) }
        XCTAssertNil(recorded.transactionId, described)
        XCTAssertTrue(invoice.notes.contains("Not linked: no matching debit yet"), described)
        XCTAssertEqual(Set(plan.items(in: .duplicates).compactMap { $0.duplicate?.level }), Set<ImportDuplicate.Level>([.file, .document]), described)
        XCTAssertTrue(plan.items(in: .needsYou).contains { $0.file.fileName == "Letter.pdf" && $0.recognition.kind == .unknown }, described)
        // The corrected P60 (the stored employer, pay £1,000 more) is not taken for a copy: it is
        // possibly a corrected version, and the filed 2024/25 return holds it.
        let p60 = try XCTUnwrap(plan.items.first { $0.recognition.kind == .payrollForm(.p60) }, described)
        XCTAssertNil(p60.duplicate, described)
        XCTAssertTrue(p60.issues.contains { $0.id == ImportDuplicates.correctedVersionIssueId && $0.reason.hasSuffix("Pay £39,840.00 → £40,840.00") },
                      described)
        XCTAssertTrue(p60.issues.contains(where: ImportResolutions.isFiledYearHold), described)
        // The BBVA statement of Euro Current: Ready, its instalment paired with its receipt on the
        // Property Mortgage, no fund, its closing and the loan's capital owed matching.
        let bbva = try XCTUnwrap(plan.items.first { $0.recognition.kind == .bbvaStatement && $0.parentId == nil }, described)
        XCTAssertEqual(bbva.section, .ready, described)
        guard case .bbvaStatement(let effect) = bbva.effect else { return XCTFail(described) }
        XCTAssertEqual(effect.instalments.count, 1, described)
        XCTAssertNil(effect.fundAccountId, described)
        XCTAssertNotNil(effect.loanAccountId, described)
        XCTAssertEqual(effect.staged.count, 3, described)
        // The UK CSV: no account's profile reads it, its account to choose (GBP current accounts first).
        let csv = try XCTUnwrap(plan.items.first { $0.recognition.kind == .bankStatementCSV }, described)
        XCTAssertEqual(csv.section, .needsYou, described)
        XCTAssertTrue(csv.issues.contains { $0.kind == .statement(.unknownAccount) && !$0.offers.isEmpty }, described)
        // Written again (MakeDemoDatabase --force), the folder holds the same nine.
        XCTAssertEqual(try DemoImportSamples.write(into: folder.appendingPathComponent("ImportSamples", isDirectory: true),
                                                   dbQueue: manager.dbQueue).map(\.lastPathComponent),
                       samples.map(\.lastPathComponent))
    }
}
