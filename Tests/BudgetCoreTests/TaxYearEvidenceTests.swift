import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The iPad's Evidence (step 10, Task 14): the whole tax year's evidence grouped by area, utility bills never in it, and a
/// member seeing only what her permissions show. Synthetic household: person A (admin) and person B (member), each with an
/// employment in 2025/26, an HMRC payment and a pension contribution of A's, and one EUR property with IMI, utility and
/// rent-receipt rules.
final class TaxYearEvidenceTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]
    private let year = UKTaxYear(startYear: 2025)

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            var a = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            ids["a"] = a.id!
            ids["b"] = b.id!
            var admin = AppUser(personId: a.id!, displayName: "A", isAdmin: true, createdAt: Self.date(2025, 1, 1))
            try admin.insert(db)
            var member = AppUser(personId: b.id!, displayName: "B", isAdmin: false, createdAt: Self.date(2025, 1, 1))
            try member.insert(db)
            ids["admin"] = admin.id!
            ids["member"] = member.id!
            try MemberPermissions.ensureDefaults(appUserId: member.id!, db: db)

            var property = Property(name: "Example flat", country: "PT")
            try Properties.save(db: db, &property)
            ids["property"] = property.id!
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            ids["bank"] = account.id!
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
            ids["batch"] = batch.id!
            var group = CategoryGroup(name: "Example flat")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            for name in ["IMI", "Utilities", "Electricity", "Repairs"] {
                var category = Category(name: name, type: .expense, groupId: group.id)
                try category.insert(db)
                ids[name] = category.id!
            }
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            try EvidenceRequirementDefaults.seedPropertyRules(db: db, categoryGroupId: group.id!)
            _ = try PropertyEvidence.seedRules(db: db, propertyId: property.id!)
            try PersonalIncomeEvidence.seedRules(db: db)

            for (person, employer) in [(a.id!, "Example Ltd"), (b.id!, "Sample plc")] {
                var employment = Employment(startYear: 2025, personId: person, employerName: employer)
                try Employments.save(db: db, &employment)
                ids["employment-\(person)"] = employment.id!
            }
            var payment = HMRCPayment(personId: a.id!, startYear: 2024, date: Self.date(2026, 1, 31), amountMinorUnits: 120_000,
                                      kind: .balancingPayment)
            try HMRCPayments.save(db: db, &payment)
            var pension = PensionContribution(startYear: 2025, personId: a.id!, kind: .reliefAtSource, provider: "Example Pensions",
                                              paidMinorUnits: 50_000)
            try PensionContributions.save(db: db, &pension)
            var rule = EvidenceRequirement(name: "Pension statement", scope: .single(entity: .pensionContribution(pension.id!)),
                                           kinds: [.other], usualSource: "Pension provider",
                                           activeFrom: year.start, activeTo: year.end)
            try EvidenceRequirements.save(db: db, &rule)
        }
        try movement(Self.date(2025, 9, 10), -30_000, "IMI 1A PRESTACAO", category: "IMI")
        try movement(Self.date(2025, 10, 3), -6_000, "EDP COMERCIAL", category: "Electricity")
        try movement(Self.date(2025, 11, 3), -4_000, "UTILITIES", category: "Utilities")
        try movement(Self.date(2026, 5, 12), -20_000, "PLUMBER", category: "Repairs")
    }

    @discardableResult
    private func movement(_ date: Date, _ amount: Int, _ text: String, category: String, account: Int64? = nil) throws -> Int64 {
        try db.write { db in
            var t = Transaction(importBatchId: ids["batch"]!, accountId: account ?? ids["bank"]!, date: date, rawDescription: text,
                                amountMinorUnits: amount, categoryId: ids[category], status: .confirmed, categorizedBy: .manual,
                                fingerprint: UUID().uuidString)
            try t.insert(db)
            return t.id!
        }
    }

    private func areas(_ year: UKTaxYear? = nil, viewer: String? = nil) throws -> [EvidenceArea] {
        try db.read { db in
            let actor = try viewer.map { try AccessActor.load(appUserId: ids[$0]!, db: db) }
            return try TaxYearEvidence.areas(db: db, taxYear: year ?? self.year, viewer: actor)
        }
    }

    private func setMember(_ area: AccessArea, _ level: PermissionLevel) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO memberPermission(appUserId, area, level) VALUES (?, ?, ?)
                ON CONFLICT(appUserId, area) DO UPDATE SET level = excluded.level
                """, arguments: [ids["member"]!, area.storageKey, level.rawValue])
        }
    }

    private func taxArea(_ person: String) throws -> AccessArea {
        try db.read { db in try AccessArea.tax(ofPerson: ids[person]!, db: db) }
    }

    // MARK: Tests

    func testGroupedByAreaInOrder() throws {
        let areas = try areas()
        XCTAssertEqual(areas.map(\.area), [.employmentIncome, .ukTax, .pensionGifts, .lisbonFlat])
        XCTAssertEqual(areas.map(\.title), ["Employment & income", "UK tax", "Pension & gifts", "Example flat"])
        let employment = try XCTUnwrap(areas.first { $0.area == .employmentIncome })
        XCTAssertEqual(employment.items.count, 2, "a P60 for each person's employment")
        XCTAssertTrue(employment.items.allSatisfy { $0.item.expectedKinds == [.p60] })
        XCTAssertEqual(areas[1].items.map(\.item.expectedKinds), [[.hmrcPaymentProof]])
        XCTAssertEqual(areas[2].items.map(\.item.target.entity.type), [.pensionContribution])
        let flat = areas[3].items
        XCTAssertTrue(flat.contains { $0.item.expectedKinds.contains(.imiNotice) })
        XCTAssertFalse(flat.contains { $0.item.title == "PLUMBER" }, "May 2026 is 2026/27's")
        // Missing items come first in each area.
        try db.write { db in
            var document = EvidenceDocument(sha256: "imi", storedRelativePath: "i/imi.pdf", originalFileName: "imi.pdf", byteCount: 1,
                                            kind: .imiNotice, docDate: Self.date(2025, 9, 1), addedAt: Date())
            try document.insert(db)
            let imi = try XCTUnwrap(try Transaction.filter(Column("rawDescription") == "IMI 1A PRESTACAO").fetchOne(db))
            try EvidenceLinks.link(db: db, documentId: document.id!, to: .transaction(imi.id!))
        }
        let after = try XCTUnwrap(try self.areas().first { $0.area == .lisbonFlat }).items
        XCTAssertEqual(after.last?.state, .have)
        XCTAssertTrue(after.dropLast().allSatisfy { $0.state == .missing })
        XCTAssertEqual(TaxYearEvidence.progress(try self.areas()).done, 1)
    }

    func testUtilityBillsNeverAppear() throws {
        let items = try areas().flatMap(\.items)
        XCTAssertFalse(items.isEmpty)
        XCTAssertFalse(items.contains { $0.item.expectedKinds.contains(.utilityInvoice) })
        XCTAssertFalse(items.contains { ["EDP COMERCIAL", "UTILITIES"].contains($0.item.title) })
        // Even mapped as a claimable cost, a utility category's bills stay out: they belong to Bills & recharges.
        try db.write { db in
            try db.execute(sql: "UPDATE taxExpenseTypeMap SET expenseType = 'repairs' WHERE categoryId IN (?, ?)",
                           arguments: [ids["Utilities"]!, ids["Electricity"]!])
        }
        let checklist = try db.read { db in try MissingEvidence.checklist(db: db, period: year.interval, taxFiguresOnly: true) }
        XCTAssertTrue(checklist.contains { $0.title == "EDP COMERCIAL" }, "the checklist itself has it once it changes figures")
        XCTAssertFalse(try areas().flatMap(\.items).contains { ["EDP COMERCIAL", "UTILITIES"].contains($0.item.title) })
        XCTAssertEqual(TaxYearEvidence.utilityPointer, "Utility bills are tracked in Bills & recharges.")
    }

    func testSwitchingTaxYearChangesItems() throws {
        let current = try areas().flatMap(\.items)
        let next = try areas(year.next).flatMap(\.items)
        XCTAssertTrue(current.contains { $0.item.title == "IMI 1A PRESTACAO" })
        XCTAssertFalse(next.contains { $0.item.title == "IMI 1A PRESTACAO" })
        XCTAssertTrue(next.contains { $0.item.title == "PLUMBER" }, "May 2026 is 2026/27's")
        XCTAssertFalse(current.contains { $0.item.title == "PLUMBER" })
        XCTAssertFalse(next.contains { $0.item.expectedKinds == [.p60] }, "no employment in 2026/27")
        XCTAssertNotEqual(Set(current.map(\.id)), Set(next.map(\.id)))
    }

    func testEachItemHasWhy() throws {
        let items = try areas().flatMap(\.items)
        XCTAssertEqual(items.count, 5, "two P60s, an HMRC payment, a pension, the IMI")
        for item in items {
            XCTAssertFalse(item.why.isEmpty, item.item.title)
            XCTAssertTrue(item.why.hasSuffix("."), item.why)
        }
        let p60 = try XCTUnwrap(items.first { $0.item.expectedKinds == [.p60] })
        XCTAssertTrue(p60.why.contains("employer"), p60.why)
        XCTAssertEqual(p60.source, "Employer")
        XCTAssertEqual(p60.suggestedSiteKind, .other)
        let imi = try XCTUnwrap(items.first { $0.item.expectedKinds.contains(.imiNotice) })
        XCTAssertEqual(imi.why, "Property tax is a cost of the flat; the notice is the proof.")
        XCTAssertEqual(imi.source, "Portal das Finanças")
        XCTAssertEqual(imi.suggestedSiteKind, .tax)
        XCTAssertEqual(items.first { $0.item.expectedKinds == [.hmrcPaymentProof] }?.suggestedSiteKind, .tax)
        XCTAssertTrue(items.allSatisfy(\.canLink), "the admin links")
    }

    /// A member sees her own personal items and the other person's only while she has View on his Tax and he shares his
    /// tax and income; the property's with Property; nothing of an account he keeps from her; nothing without Documents.
    func testOnlyViewerVisibleAreasShown() throws {
        let everything = try areas()
        let asMember = try areas(viewer: "member")
        XCTAssertEqual(asMember.map(\.area), everything.map(\.area), "member defaults: View on every Tax, Property, Documents")
        XCTAssertEqual(asMember.flatMap(\.items).map(\.id), everything.flatMap(\.items).map(\.id))
        XCTAssertFalse(asMember.flatMap(\.items).contains { $0.canLink } == false, "Documents Edit by default")

        // A's tax: None for her. His P60, HMRC payment and pension go; hers stays.
        try setMember(try taxArea("a"), .none)
        var shown = try areas(viewer: "member")
        XCTAssertEqual(shown.map(\.area), [.employmentIncome, .ukTax, .pensionGifts, .lisbonFlat], "her own Tax still shows")
        XCTAssertEqual(shown.first { $0.area == .employmentIncome }?.items.count, 1)
        XCTAssertEqual(shown.first { $0.area == .ukTax }?.items, [])
        XCTAssertEqual(shown.first { $0.area == .pensionGifts }?.items, [])
        let p60 = try XCTUnwrap(shown.first { $0.area == .employmentIncome }?.items.first)
        XCTAssertEqual(p60.item.target.entity, .employment(ids["employment-\(ids["b"]!)"]!))
        XCTAssertEqual(try areas().flatMap(\.items).count, everything.flatMap(\.items).count, "the admin still sees all")

        // View on his Tax again, but he hides his tax and income: hidden all the same.
        try setMember(try taxArea("a"), .view)
        try db.write { db in
            var sharing = PersonSharing(personId: ids["a"]!, taxIncomeLevel: .hidden)
            try sharing.insert(db)
        }
        shown = try areas(viewer: "member")
        XCTAssertEqual(shown.first { $0.area == .ukTax }?.items, [])

        // No Tax at all for her: the personal areas go.
        try setMember(try taxArea("b"), .none)
        try setMember(try taxArea("a"), .none)
        XCTAssertEqual(try areas(viewer: "member").map(\.area), [.lisbonFlat])

        // A private account of his: its items are hidden from her.
        let privateAccount = try db.write { db -> Int64 in
            var account = Account(name: "Private A", currency: .eur, kind: .cash, trackingMode: .imported, ownerPersonId: ids["a"]!,
                                  sharingLevel: .balanceOnly)
            try account.insert(db)
            return account.id!
        }
        try movement(Self.date(2025, 12, 1), -15_000, "PRIVATE REPAIR", category: "Repairs", account: privateAccount)
        XCTAssertTrue(try areas().flatMap(\.items).contains { $0.item.title == "PRIVATE REPAIR" })
        XCTAssertFalse(try areas(viewer: "member").flatMap(\.items).contains { $0.item.title == "PRIVATE REPAIR" })

        // No Property: the property's area goes. No Documents: nothing.
        try setMember(.property, .none)
        XCTAssertEqual(try areas(viewer: "member").map(\.area), [])
        try setMember(.property, .view)
        try setMember(.documents, .view)
        let viewOnly = try areas(viewer: "member")
        XCTAssertEqual(viewOnly.map(\.area), [.lisbonFlat])
        XCTAssertTrue(viewOnly.flatMap(\.items).allSatisfy { !$0.canLink }, "View on Documents: nothing to link")
        try setMember(.documents, .none)
        XCTAssertEqual(try areas(viewer: "member"), [])
    }
}
