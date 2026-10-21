import XCTest
import GRDB
@testable import BudgetCore

/// A P11D's benefit rows corrected in the review, the stored-NI-number check and the tax code fact.
final class ImportPayrollBenefitsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var personId: Int64!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        try db.write { db in
            var person = Person(name: "Person A", ukNino: "QQ 12 34 56 C")
            try People.save(db: db, &person)
            personId = person.id!
        }
    }

    private func item(_ extraction: PayrollFormExtraction, intent: ImportIntent = .none) throws -> ImportItem {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p11d-\(UUID().uuidString).pdf")
        let file = ImportFile(url: url, fileName: "P11D.pdf", sha256: UUID().uuidString, byteCount: 10, fileExtension: "pdf",
                              text: "P11D", textStatus: .text, usedOCR: false, payrollExtraction: extraction)
        let recognition = ImportRecognition(kind: .payrollForm(extraction.kind ?? .p11d), confidence: .certain, reason: "test")
        let context = try db.read { try ImportContext.load(db: $0, intent: intent, now: Date()) }
        return try XCTUnwrap(try db.read { try PayrollFormImportReader().propose([(file, recognition)], context: context, db: $0) }.first)
    }

    private func p11d(method: IncomeEntryMethod = .textLayer, nino: String? = "QQ123456C") -> PayrollFormExtraction {
        PayrollFormExtraction(kind: .p11d, entryMethod: method, startYear: 2025, employerName: "Example Ltd", payeReference: "123/AB456",
                              nationalInsuranceNumber: nino, taxCode: "1257L",
                              benefits: [.init(kind: .medical, cashEquivalentMinorUnits: 121_000), .init(kind: .carFuel, cashEquivalentMinorUnits: 0)])
    }

    private func benefits(_ item: ImportItem) -> [PayrollFormExtraction.Benefit] {
        guard case .payrollForm(let confirmed) = item.effect else { return [] }
        return confirmed.benefits
    }

    func testEditingARowsAmountUpdatesTheEffectAndTotal() throws {
        let start = try item(p11d())
        var rows = benefits(start)
        rows[0].cashEquivalentMinorUnits = 150_000
        let edited = try XCTUnwrap(try ImportResolutions.apply(.setBenefits(rows), to: start))
        XCTAssertEqual(benefits(edited).map(\.cashEquivalentMinorUnits), [150_000, 0])
        XCTAssertEqual(edited.facts.first { $0.field == .amount }?.value, .money(150_000, .gbp))
        XCTAssertEqual(edited.facts.first { $0.field == .amount }?.source, .user)
    }

    func testAddingAndRemovingRows() throws {
        let start = try item(p11d())
        var rows = benefits(start)
        rows.append(.init(kind: .relocation, cashEquivalentMinorUnits: 40_000))
        rows.remove(at: 1)
        let edited = try XCTUnwrap(try ImportResolutions.apply(.setBenefits(rows), to: start))
        XCTAssertEqual(benefits(edited).map(\.kind), [.medical, .relocation])
        XCTAssertEqual(edited.facts.first { $0.field == .amount }?.value, .money(161_000, .gbp))
        let none = try XCTUnwrap(try ImportResolutions.apply(.setBenefits([]), to: edited))
        XCTAssertEqual(benefits(none), [])
        XCTAssertNil(none.facts.first { $0.field == .amount })
    }

    func testOCRRowsNeedReviewUntilEditedOrTicked() throws {
        let scanned = try item(p11d(method: .ocr))
        XCTAssertEqual(scanned.facts.first { $0.field == .amount }?.confidence, .needsReview)
        XCTAssertEqual(scanned.section, .needsYou)
        let edited = try XCTUnwrap(try ImportResolutions.apply(.setBenefits(benefits(scanned)), to: scanned))
        XCTAssertEqual(edited.facts.first { $0.field == .amount }?.confidence, .certain)
        let ticked = try ImportChecks.marked(.figure(.amount), on: scanned)
        XCTAssertEqual(ticked.facts.first { $0.field == .amount }?.confidence, .certain)
    }

    func testBenefitsAddedToAFormWithNoneClearTheNoBenefitsProblem() throws {
        var empty = p11d()
        empty.benefits = []
        empty.warnings = ["No benefits found: check the form for cash equivalents."]
        let start = try item(empty)
        XCTAssertTrue(start.issues.contains { $0.reason.hasPrefix("No benefits found") })
        let edited = try XCTUnwrap(try ImportResolutions.apply(.setBenefits([.init(kind: .medical, cashEquivalentMinorUnits: 5_000)]), to: start))
        XCTAssertFalse(edited.issues.contains { $0.reason.hasPrefix("No benefits found") })
    }

    func testBenefitsRefusedOnAP60AndNegativeAmounts() throws {
        let p60 = try item(PayrollFormExtraction(kind: .p60, entryMethod: .textLayer, startYear: 2025, employerName: "Example Ltd",
                                                 payeReference: "123/AB456", nationalInsuranceNumber: "QQ123456C",
                                                 payMinorUnits: 100, taxDeductedMinorUnits: 10))
        XCTAssertThrowsError(try ImportResolutions.apply(.setBenefits([]), to: p60))
        XCTAssertThrowsError(try ImportResolutions.apply(.setBenefits([.init(kind: .car, cashEquivalentMinorUnits: -1)]), to: try item(p11d())))
    }

    func testStoredNINOMismatchIsAProblemToAcknowledge() throws {
        let other = try item(p11d(nino: "QQ999999A"), intent: ImportIntent(personId: personId))
        let issue = try XCTUnwrap(other.issues.first { $0.reason == "The form's National Insurance number isn't the one stored for Person A" })
        XCTAssertEqual(other.section, .needsYou)
        let answered = try XCTUnwrap(try ImportResolutions.apply(.acknowledge, to: other, issueId: issue.id))
        XCTAssertFalse(answered.issues.contains { $0.reason.contains("isn't the one stored") })
        // The stored number matching: no problem.
        let same = try item(p11d(), intent: ImportIntent(personId: personId))
        XCTAssertFalse(same.issues.contains { $0.reason.contains("isn't the one stored") })
    }

    func testEditedBenefitsFileTheDocumentWithTheEditedTotal() throws {
        let start = try item(p11d())
        XCTAssertEqual(start.placement?.metadata.amountMinorUnits, 121_000)
        var rows = benefits(start)
        rows[0].cashEquivalentMinorUnits = 150_000
        let edited = try XCTUnwrap(try ImportResolutions.apply(.setBenefits(rows), to: start))
        XCTAssertEqual(edited.placement?.metadata.amountMinorUnits, 150_000)
        XCTAssertEqual(edited.placement?.metadata.persons, start.placement?.metadata.persons)
    }

    func testEditedBenefitsHaveTheirOwnReasonSoACheckOfTheTotalIsNoLongerUndoable() throws {
        let scanned = try item(p11d(method: .ocr))
        let prior = try XCTUnwrap(scanned.facts.first { $0.field == .amount })
        let ticked = try ImportChecks.marked(.figure(.amount), on: scanned)
        let record = ImportCheckRecord(before: scanned, after: ticked, priorFact: prior, priorRecognition: nil, removedIssues: [], addedDrafts: [])
        XCTAssertTrue(ImportChecks.isStillChecked(record, .figure(.amount), on: ticked))
        // The same total from other rows: the benefits are the user's now, not the tick's.
        let edited = try XCTUnwrap(try ImportResolutions.apply(.setBenefits([.init(kind: .medical, cashEquivalentMinorUnits: 121_000)]), to: ticked))
        XCTAssertEqual(edited.facts.first { $0.field == .amount }?.reason, ImportResolutions.benefitsReason)
        XCTAssertFalse(ImportChecks.isStillChecked(record, .figure(.amount), on: edited))
    }

    func testRemovingEveryBenefitWarnsThatTheEarlierBenefitsGo() throws {
        let start = try item(p11d())
        let none = try XCTUnwrap(try ImportResolutions.apply(.setBenefits([]), to: start))
        let issue = try XCTUnwrap(none.issues.first { $0.reason == "No benefits: the earlier benefits for this employment will be removed" })
        XCTAssertEqual(none.section, .needsYou)
        let answered = try XCTUnwrap(try ImportResolutions.apply(.acknowledge, to: none, issueId: issue.id))
        XCTAssertFalse(answered.issues.contains { $0.id == issue.id })
        // Benefits put back: the warning goes.
        let back = try XCTUnwrap(try ImportResolutions.apply(.setBenefits([.init(kind: .medical, cashEquivalentMinorUnits: 5_000)]), to: none))
        XCTAssertFalse(back.issues.contains { $0.id == issue.id })
    }

    func testTaxCodeIsAFactAndTheEffectFollowsIt() throws {
        let start = try item(p11d())
        XCTAssertEqual(start.facts.first { $0.field == .taxCode }?.value, .text("1257L"))
        guard case .payrollForm(let confirmed) = start.effect else { return XCTFail("effect") }
        XCTAssertEqual(confirmed.taxCode, "1257L")
    }
}
