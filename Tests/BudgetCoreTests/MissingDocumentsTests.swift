import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The Missing documents centre (step 20): one list over evidence rules, tenancy utility bills and waiting documents. Synthetic household: person A (admin) and person B (member), each with an
/// employment in 2025/26, an HMRC payment and a pension contribution of A's, and one EUR property with IMI, utility and
/// rent-receipt rules.
final class MissingDocumentsTests: XCTestCase {
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
        try db.write { db in
            try Properties.setAccount(db: db, propertyId: ids["property"]!, accountId: ids["bank"]!, role: .current)
            var tenancy = Tenancy(propertyId: ids["property"]!, referenceLabel: "Room A", contractNumber: "1", tenantName: "Zed Tenant",
                                  startDate: Self.date(2025, 4, 6))
            try Tenancies.save(db: db, &tenancy)
            ids["tenancy"] = tenancy.id!
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

    private let now = MissingDocumentsTests.date(2026, 3, 10)

    private func read(viewer: String? = nil) throws -> MissingDocuments.Result {
        try db.read { db in
            let actor = try viewer.map { try AccessActor.load(appUserId: ids[$0]!, db: db) }
            return try MissingDocuments.read(db: db, now: now, viewer: actor, earliest: UKTaxYear(startYear: 2024))
        }
    }

    func testAreasAndSources() throws {
        let rows = try read().rows
        XCTAssertEqual(Set(rows.map(\.area)), [.tax, .tenancy, .property])
        XCTAssertTrue(rows.contains { $0.area == .tax && $0.item?.expectedKinds == [.p60] })
        XCTAssertTrue(rows.contains { $0.area == .property && $0.item?.expectedKinds.contains(.imiNotice) == true })
        XCTAssertTrue(rows.contains { $0.area == .tenancy && $0.source == .evidence && $0.item?.target.entity.type == .tenancy })
        let bills = rows.filter { $0.source == .utilityBill }
        XCTAssertEqual(bills.map(\.area), [.tenancy, .tenancy], "the two utility payments in the tenancy")
        XCTAssertTrue(bills.allSatisfy { $0.context == "Room A" && !$0.canAttach })
        XCTAssertTrue(rows.filter { $0.source == .utilityBill }.allSatisfy { $0.state == .missing })
    }

    func testTenantNameNeverShown() throws {
        for row in try read().rows {
            let text = [row.title, row.detail ?? "", row.context ?? "", row.usualSource ?? ""].joined(separator: " ")
            XCTAssertFalse(text.contains("Zed"), text)
        }
        XCTAssertTrue(try read().rows.contains { $0.context == "Room A" })
        let found = MissingDocuments.missing(try read().rows, filter: .init(text: "zed"), now: now)
        XCTAssertTrue(found.isEmpty, "search never reaches the tenant's name")
    }

    func testSortOldestDueFirst() throws {
        let missing = try read().missing
        XCTAssertEqual(missing.map(\.due), missing.map(\.due).sorted())
        XCTAssertTrue(missing.count > 3)
    }

    func testFiltersAreaYearTimingText() throws {
        let rows = try read().rows
        let tax = MissingDocuments.missing(rows, filter: .init(area: .tax), now: now)
        XCTAssertTrue(!tax.isEmpty && tax.allSatisfy { $0.area == .tax })
        let y2024 = MissingDocuments.missing(rows, filter: .init(taxYear: 2024), now: now)
        let y2025 = MissingDocuments.missing(rows, filter: .init(taxYear: 2025), now: now)
        XCTAssertTrue(y2025.contains { $0.item?.expectedKinds == [.p60] })
        XCTAssertFalse(y2024.contains { $0.source == .utilityBill })
        XCTAssertTrue(y2025.contains { $0.source == .utilityBill })
        let overdue = MissingDocuments.missing(rows, filter: .init(timing: .overdue), now: now)
        XCTAssertTrue(overdue.allSatisfy { $0.due < now })
        let soon = MissingDocuments.missing(rows, filter: .init(timing: .dueSoon), now: now)
        XCTAssertTrue(soon.allSatisfy { $0.due >= now && $0.due < now.addingTimeInterval(30 * 86_400) })
        XCTAssertTrue(soon.contains { $0.due == year.lastDay }, "5 April is 26 days after 10 March")
    }

    func testNotExpectedIsReversible() throws {
        let before = try read()
        let row = try XCTUnwrap(before.missing.first { $0.item?.expectedKinds == [.p60] })
        XCTAssertTrue(row.canMarkNotExpected)
        try db.write { db in XCTAssertTrue(try MissingDocuments.markNotExpected(db: db, row: row, reason: .other, note: "Not employed")) }
        let after = try read()
        XCTAssertEqual(after.missingCount, before.missingCount - 1)
        let waived = try XCTUnwrap(after.notExpected.first { $0.id == row.id })
        XCTAssertFalse(after.missing.contains { $0.id == row.id })
        try db.write { db in XCTAssertTrue(try MissingDocuments.restore(db: db, row: waived)) }
        let restored = try read()
        XCTAssertEqual(restored.missingCount, before.missingCount)
        XCTAssertTrue(restored.notExpected.isEmpty)
    }

    func testAccessAreasRespected() throws {
        let admin = try read()
        XCTAssertEqual(try read(viewer: "member").rows.map(\.id), admin.rows.map(\.id), "member defaults see everything")
        try setMember(.property, .none)
        let noProperty = try read(viewer: "member").rows
        XCTAssertFalse(noProperty.contains { $0.area != .tax })
        XCTAssertTrue(noProperty.contains { $0.area == .tax })
        try setMember(.documents, .none)
        XCTAssertEqual(try read(viewer: "member").rows, [])
        try setMember(.documents, .view)
        try setMember(.property, .view)
        let readOnly = try read(viewer: "member").rows.filter { $0.source == .evidence }
        XCTAssertTrue(readOnly.allSatisfy { !$0.canAttach && !$0.canMarkNotExpected })
    }

    func testFiledYearIsReadOnly() throws {
        try movement(Self.date(2025, 1, 10), -30_000, "IMI 2024 PRESTACAO", category: "IMI")
        try db.write { db in
            try TaxOverview.setStatus(db: db, startYear: 2024, personId: ids["a"]!, status: .filed)
        }
        let rows = try read().rows
        let filed = rows.filter { $0.taxYears == [2024] && $0.source == .evidence }
        XCTAssertTrue(!filed.isEmpty)
        XCTAssertTrue(filed.allSatisfy { $0.isFiledYear && !$0.canAttach && !$0.canMarkNotExpected })
        let open = rows.filter { $0.taxYears == [2025] && $0.source == .evidence }
        XCTAssertTrue(open.contains { !$0.isFiledYear && $0.canAttach })
    }

    func testWaitingDocumentAppearsUntilPaid() throws {
        let documentId = try db.write { db -> Int64 in
            var document = EvidenceDocument(sha256: "w", storedRelativePath: "w/w.pdf", originalFileName: "water-bill.pdf", byteCount: 1,
                                            kind: .repairInvoice, docDate: Self.date(2026, 2, 10), amountMinorUnits: 7_500, currency: .eur,
                                            addedAt: Self.date(2026, 2, 12))
            try document.insert(db)
            return document.id!
        }
        let waiting = try read().rows.filter { $0.source == .waitingPayment }
        XCTAssertEqual(waiting.map(\.documentId), [documentId])
        XCTAssertEqual(waiting.first?.amountMinorUnits, 7_500)
        let debit = try movement(Self.date(2026, 2, 14), -7_500, "WATER BILL", category: "Repairs")
        try db.write { db in try EvidenceLinks.link(db: db, documentId: documentId, to: .transaction(debit)) }
        XCTAssertTrue(try read().rows.filter { $0.source == .waitingPayment }.isEmpty)
    }
}
