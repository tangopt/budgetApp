import XCTest
import GRDB
@testable import BudgetCore

/// The one-off pass that files the repair bills and stamp-duty notes filed as `other` under their
/// own kinds, and narrows the Repairs rule. Synthetic database only (invented names and amounts).
final class NewKindsReclassificationTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }

    static let repairText = "Exemplo Canalizações Lda\nFatura FT 2026/12\nReparação de autoclismo\nTotal 60,00 EUR"
    static let stampDutyText = "Autoridade Tributária e Aduaneira\nDOCUMENTO DE COBRANÇA\nImposto do Selo\nVerba 2 Arrendamento\nValor a pagar 95,00 €"

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
    }

    private static func day(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)!
    }

    @discardableResult
    private func document(_ name: String, kind: DocumentKind = .other, text: String?, date: String? = "2026-03-14", amount: Int? = 6_000,
                          canonical: String? = nil) throws -> Int64 {
        try db.write { db in
            var document = EvidenceDocument(sha256: "sha-\(name)", storedRelativePath: "sh/sha-\(name).pdf", originalFileName: name, byteCount: 1,
                                            canonicalName: canonical, kind: kind, docDate: date.map(Self.day), amountMinorUnits: amount,
                                            currency: amount == nil ? nil : .eur, textStatus: text == nil ? .image : .glyph, extractedText: text,
                                            addedAt: Self.day("2026-10-01"))
            try document.insert(db)
            return document.id!
        }
    }

    private func category(_ name: String) throws -> Int64 {
        try db.write { db in
            var category = Category(name: name, type: .expense)
            try category.insert(db)
            return category.id!
        }
    }

    private func requirement(_ name: String, scope: EvidenceRequirementScope, kinds: [DocumentKind]) throws -> Int64 {
        try db.write { db in
            var requirement = EvidenceRequirement(name: name, scope: scope, kinds: kinds)
            try EvidenceRequirements.save(db: db, &requirement)
            return requirement.id!
        }
    }

    func testOtherDocumentsReadAsRepairBillsAreReclassified() throws {
        let repair = try document("scan-1.pdf", text: Self.repairText,
                                  canonical: "20260314 - Other - Document - Exemplo Canalizações - €60.00")
        let stamp = try document("scan-2.pdf", text: Self.stampDutyText, amount: 9_500)
        let byName = try document("20260401 - Reparação esquentador.pdf", text: nil, date: nil, amount: nil)
        try document("notes.pdf", text: "Lista de compras\nPão\nLeite")

        let plan = try db.read { try NewKindsReclassification.plan(db: $0, repairsRuleKinds: nil) }
        XCTAssertEqual(plan.documents.map(\.documentId), [repair, stamp, byName])
        XCTAssertEqual(plan.documents.map(\.newKind), [.repairInvoice, .stampDuty, .repairInvoice])
        XCTAssertEqual(plan.documents.map(\.reason), [.text, .text, .fileName])
        XCTAssertEqual(plan.documents.map(\.newCanonicalName), [
            "20260314 - Property - Repair bill - Exemplo Canalizações - €60.00",
            "20260314 - Tax PT - Stamp duty - €95.00",
            "20260401 - Property - Repair bill"
        ])
        XCTAssertEqual(plan.documents.first?.oldCanonicalName, "20260314 - Other - Document - Exemplo Canalizações - €60.00")

        try manager.dbQueue.write { db in try db.execute(sql: "DELETE FROM syncPending") }
        try db.write { try NewKindsReclassification.applyIfCurrent(plan, db: $0, repairsRuleKinds: nil) }
        try db.read { db in
            let saved = try XCTUnwrap(try EvidenceDocument.fetchOne(db, key: repair))
            XCTAssertEqual(saved.kind, .repairInvoice)
            XCTAssertEqual(saved.canonicalName, "20260314 - Property - Repair bill - Exemplo Canalizações - €60.00")
            XCTAssertEqual(try EvidenceDocument.fetchOne(db, key: stamp)?.kind, .stampDuty)
            let pending = try SyncChangeTracker.pending(db: db)
            for id in [repair, stamp, byName] {
                XCTAssertTrue(pending.contains { $0.table == EvidenceDocument.databaseTableName && $0.localId == id }, "\(pending)")
            }
        }
        // Idempotent: a second run has nothing to do.
        XCTAssertTrue(try db.read { try NewKindsReclassification.plan(db: $0, repairsRuleKinds: nil) }.isEmpty)
    }

    func testDocumentsOfOtherKindsAreLeftAlone() throws {
        // An insurer's receipt for a claim's repair keeps its kind, as does any non-`other` document.
        try document("insurance.pdf", kind: .insuranceReceipt, text: Self.repairText)
        try document("notice.pdf", kind: .mortgageNotice, text: Self.stampDutyText)
        try document("Reparação.pdf", kind: .utilityInvoice, text: nil)
        let plan = try db.read { try NewKindsReclassification.plan(db: $0, repairsRuleKinds: [.repairInvoice, .other]) }
        XCTAssertEqual(plan.documents, [])
    }

    func testRepairsRuleChangesOnlyWhenKindsAreGiven() throws {
        let repairs = try category("Lisbon: Repairs")
        let other = try category("Lisbon: Other")
        let rule = try requirement("Lisbon: Repairs", scope: .transactionsInCategory(categoryId: repairs), kinds: [])
        _ = try requirement("Lisbon: Other", scope: .transactionsInCategory(categoryId: other), kinds: [])
        _ = try requirement("Repairs, chosen", scope: .transactionsInCategory(categoryId: repairs), kinds: [.other])

        XCTAssertEqual(try db.read { try NewKindsReclassification.plan(db: $0, repairsRuleKinds: nil) }.requirements, [])
        let plan = try db.read { try NewKindsReclassification.plan(db: $0, repairsRuleKinds: [.repairInvoice, .other]) }
        XCTAssertEqual(plan.requirements, [NewKindsReclassification.RequirementChange(requirementId: rule, name: "Lisbon: Repairs",
                                                                                       oldKinds: [], newKinds: [.repairInvoice, .other])])
        try db.write { try NewKindsReclassification.applyIfCurrent(plan, db: $0, repairsRuleKinds: [.repairInvoice, .other]) }
        XCTAssertEqual(try db.read { try EvidenceRequirement.fetchOne($0, key: rule)?.kinds }, [.repairInvoice, .other])
        XCTAssertTrue(try db.read { try NewKindsReclassification.plan(db: $0, repairsRuleKinds: [.repairInvoice, .other]) }.isEmpty)
    }

    func testApplyRefusesADocumentChangedSincePlanning() throws {
        let repair = try document("scan-1.pdf", text: Self.repairText)
        let plan = try db.read { try NewKindsReclassification.plan(db: $0, repairsRuleKinds: nil) }
        try db.write { db in
            var document = try XCTUnwrap(try EvidenceDocument.fetchOne(db, key: repair))
            document.canonicalName = "20260314 - Renamed meanwhile"
            try document.update(db)
        }
        XCTAssertThrowsError(try db.write { try NewKindsReclassification.apply(plan, db: $0) }) { error in
            XCTAssertEqual(error as? NewKindsReclassification.Failure, .documentChanged(repair))
        }
        XCTAssertEqual(try db.read { try EvidenceDocument.fetchOne($0, key: repair)?.kind }, .other)
    }

    func testApplyRefusesWhenSomethingNewAppearedSincePlanning() throws {
        try document("scan-1.pdf", text: Self.repairText)
        let plan = try db.read { try NewKindsReclassification.plan(db: $0, repairsRuleKinds: nil) }
        try document("scan-2.pdf", text: Self.stampDutyText)
        XCTAssertThrowsError(try db.write { try NewKindsReclassification.applyIfCurrent(plan, db: $0, repairsRuleKinds: nil) }) { error in
            XCTAssertEqual(error as? NewKindsReclassification.Failure, .planOutOfDate)
        }
        XCTAssertEqual(try db.read { try EvidenceDocument.filter(Column("kind") == DocumentKind.other.rawValue).fetchCount($0) }, 2)
    }

    /// A filed year with a Repairs cost evidenced by an `other` bill: reclassifying the bill and
    /// narrowing the rule leaves every tax figure and status as it was.
    func testFiledYearFiguresAreUnchanged() throws {
        let repairs = try db.write { db -> Int64 in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            var year = TaxYear(startYear: 2024, personId: person.id!, status: .filed)
            try year.insert(db)
            var property = Property(name: "Property A", country: "PT", currency: .gbp)
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [
                PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)
            ])
            var account = Account(name: "Bank A", currency: .gbp, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "a.csv", importedAt: Date())
            try batch.insert(db)
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            var rent = Category(name: "Rental income", type: .income, groupId: group.id)
            try rent.insert(db)
            var repairs = Category(name: "Repairs", type: .expense, groupId: group.id)
            try repairs.insert(db)
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            for (date, amount, category) in [(Self.day("2024-06-01"), 100_000, rent.id!), (Self.day("2025-01-10"), -6_000, repairs.id!)] {
                var transaction = Transaction(importBatchId: batch.id!, accountId: account.id!, date: date, rawDescription: "Synthetic",
                                              amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual,
                                              fingerprint: UUID().uuidString)
                try transaction.insert(db)
                if category == repairs.id! {
                    var bill = EvidenceDocument(sha256: "sha-bill", storedRelativePath: "sh/sha-bill.pdf", originalFileName: "bill.pdf",
                                                byteCount: 1, kind: .other, docDate: Self.day("2025-01-08"), amountMinorUnits: 6_000,
                                                currency: .gbp, textStatus: .glyph, extractedText: Self.repairText, addedAt: Date())
                    try bill.insert(db)
                    try EvidenceLinks.link(db: db, documentId: bill.id!, to: .transaction(transaction.id!))
                }
            }
            return repairs.id!
        }
        _ = try requirement("Repairs", scope: .transactionsInCategory(categoryId: repairs), kinds: [])
        let before = try db.read { try TaxFigures.snapshot(db: $0) }
        XCTAssertFalse(before.values.isEmpty)
        XCTAssertEqual(before.statuses[2024]?["Person A"], .filed)

        let plan = try db.read { try NewKindsReclassification.plan(db: $0, repairsRuleKinds: [.repairInvoice, .other]) }
        XCTAssertEqual(plan.documents.count, 1)
        XCTAssertEqual(plan.requirements.count, 1)
        try db.write { db in
            let raw = try TaxFigures.snapshot(db: db)
            try NewKindsReclassification.applyIfCurrent(plan, db: db, repairsRuleKinds: [.repairInvoice, .other])
            XCTAssertEqual(try FiledYearGuard.filedChanges(db: db, from: raw), [])
        }
        XCTAssertEqual(try db.read { try TaxFigures.snapshot(db: $0) }, before)
    }
}
