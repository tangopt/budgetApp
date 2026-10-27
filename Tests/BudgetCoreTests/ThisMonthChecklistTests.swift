import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The iPad's This-month checklist (step 10 Task 9), computed from the read models: one synthetic EUR property, a
/// tenancy "Room A" from January 2025 at €1,000 a month, three providers; today is 20 October 2026, so last month's
/// recharge is September's.
final class ThisMonthChecklistTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var ids: [String: Int64] = [:]
    private static let tenantName = "Synthetic Tenant Person"

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private static let today = date(2026, 10, 20)
    private static let september = date(2026, 9, 1)
    private static let october = date(2026, 10, 1)

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            var property = Property(name: "Property A", country: "PT")
            try Properties.save(db: db, &property)
            let p = property.id!
            ids["property"] = p
            var account = Account(name: "Bank A", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bank.csv", importedAt: Date())
            try batch.insert(db)
            ids["bank"] = account.id!
            ids["batch"] = batch.id!
            try Properties.setAccount(db: db, propertyId: p, accountId: account.id!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            try Properties.addCategoryGroup(db: db, propertyId: p, categoryGroupId: group.id!)
            var utilities = Category(name: "Utilities", type: .expense, groupId: group.id)
            try utilities.insert(db)
            var rent = Category(name: "Rental income", type: .income, groupId: group.id)
            try rent.insert(db)
            var condominium = Category(name: "Condomínio", type: .expense, groupId: group.id)
            try condominium.insert(db)
            ids["utilities"] = utilities.id!
            ids["rent"] = rent.id!
            ids["condominium"] = condominium.id!
            try TaxExpenseTypeMap.seed(db: db, propertyId: p)
            ids["tenancy"] = try tenancy(db, "Room A", from: Self.date(2025, 1, 1))
            for (key, name, kind) in [("power", "Example Power", UtilityKind.electricity), ("water", "Sample Aguas", .water),
                                      ("gas", "Demo Gas", .gas), ("heat", "Old Heat", .other)] {
                var provider = UtilityProvider(propertyId: p, name: name, kind: kind, bankDescriptionPattern: name.uppercased())
                try Recharges.saveProvider(db: db, &provider)
                ids[key] = provider.id!
            }
        }
    }

    private func tenancy(_ db: Database, _ label: String, from start: Date) throws -> Int64 {
        var tenancy = Tenancy(propertyId: ids["property"]!, referenceLabel: label, contractNumber: label, tenantName: Self.tenantName,
                              startDate: start)
        try Tenancies.save(db: db, &tenancy)
        try Tenancies.setRent(db: db, tenancyId: tenancy.id!, from: start, monthlyAmountMinorUnits: 100_000)
        return tenancy.id!
    }

    @discardableResult
    private func movement(_ date: Date, _ amount: Int, _ text: String = "MOVEMENT", category: String? = nil) throws -> Int64 {
        try db.write { db in
            var t = Transaction(importBatchId: ids["batch"]!, accountId: ids["bank"]!, date: date, rawDescription: text, amountMinorUnits: amount,
                                categoryId: category.flatMap { ids[$0] }, status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try t.insert(db)
            return t.id!
        }
    }

    /// A tenant credit (rent income).
    @discardableResult
    private func credit(_ date: Date, _ amount: Int) throws -> Int64 { try movement(date, amount, "TRANSFER FROM TENANT", category: "rent") }

    @discardableResult
    private func invoice(_ provider: String, issued: Date, amount: Int = 5_000, paidBy: Int64? = nil) throws -> Int64 {
        try db.write { db in
            var invoice = UtilityInvoice(providerId: ids[provider]!, issueDate: issued, amountMinorUnits: amount, transactionId: paidBy)
            try Recharges.saveInvoice(db: db, &invoice)
            return invoice.id!
        }
    }

    @discardableResult
    private func statement(_ month: Date, total: Int, status: RechargeStatementStatus, sentAt: Date? = nil,
                           tenancy: String = "tenancy") throws -> Int64 {
        try db.write { db in
            var statement = RechargeStatement(tenancyId: ids[tenancy]!, month: month, totalMinorUnits: total, status: status, sentAt: sentAt)
            try statement.insert(db)
            return statement.id!
        }
    }

    private func build(tenancy: String = "tenancy", today: Date = ThisMonthChecklistTests.today, trayCount: Int = 0,
                       trayItems: [TrayItem] = [], viewer: AccessActor? = nil) throws -> ThisMonthChecklist {
        try db.read { db in
            try ThisMonthChecklist.build(db: db, tenancyId: ids[tenancy]!, today: today, trayCount: trayCount, trayItems: trayItems, viewer: viewer)
        }
    }

    private func step(_ id: ThisMonthChecklist.StepID, _ checklist: ThisMonthChecklist) throws -> ThisMonthChecklist.Step {
        try XCTUnwrap(checklist.step(id))
    }

    /// Monthly bills of a provider in August and September (so it's expected in October).
    private func billedMonthly(_ provider: String) throws {
        try invoice(provider, issued: Self.date(2026, 8, 10))
        try invoice(provider, issued: Self.date(2026, 9, 10))
    }

    private func trayItem(_ name: String, host: String? = nil) -> TrayItem {
        TrayItem(id: UUID(), fileName: name, sha256: String(repeating: "a", count: 64), byteCount: 1_000, receivedAt: Self.today, sourceHost: host)
    }

    // MARK: Step 1

    func testNewTenancyFirstMonthStepOneNotApplicable() throws {
        try db.write { db in ids["roomB"] = try tenancy(db, "Room B", from: Self.date(2026, 10, 5)) }
        let checklist = try build(tenancy: "roomB")
        let first = try step(.lastRechargePaid, checklist)
        XCTAssertEqual(first.state, .notApplicable)
        XCTAssertEqual(first.detail, ThisMonthCopy.firstMonth)
        XCTAssertEqual(checklist.steps.map(\.id), ThisMonthChecklist.StepID.allCases)
        // A tenancy not started yet: every step says so.
        let later = try build(tenancy: "roomB", today: Self.date(2026, 9, 20))
        XCTAssertEqual(later.steps.map(\.state), [.notApplicable, .notApplicable, .notApplicable, .notApplicable])
        XCTAssertEqual(later.steps.first?.detail, ThisMonthCopy.notStarted)
    }

    func testExactTransferMarksStepOneDone() throws {
        try statement(Self.september, total: 8_000, status: .sent, sentAt: Self.date(2026, 10, 1))
        // Rent and the recharge in one transfer, no rent receipt linked yet: the month's rent is taken first.
        try credit(Self.date(2026, 10, 5), 108_000)
        let first = try step(.lastRechargePaid, try build())
        XCTAssertEqual(first.state, .done)
        XCTAssertEqual(first.headline, ThisMonthCopy.rechargePaidTitle(Self.september))
        XCTAssertEqual(first.detail, "Tenant transfer of \(Money.format(8_000, currency: .eur)) on 5 Oct 2026")
        XCTAssertEqual(first.actions, [])
    }

    func testTwoTransfersSummingToRechargeCountAsPaid() throws {
        try statement(Self.september, total: 8_000, status: .sent, sentAt: Self.date(2026, 10, 1))
        try credit(Self.date(2026, 10, 5), 105_000)
        try credit(Self.date(2026, 10, 8), 3_000)
        let first = try step(.lastRechargePaid, try build())
        XCTAssertEqual(first.state, .done)
        XCTAssertTrue(first.detail?.hasPrefix("Tenant transfers of ") ?? false, first.detail ?? "")

        // Both linked on the Mac: the statement is paid.
        let id = try statement(Self.date(2026, 8, 1), total: 1_000, status: .sent, sentAt: Self.date(2026, 9, 1))
        let a = try credit(Self.date(2026, 9, 3), 600)
        let b = try credit(Self.date(2026, 9, 4), 400)
        try db.write { db in
            try Recharges.linkPayment(db: db, statementId: id, transactionId: a)
            try Recharges.linkPayment(db: db, statementId: id, transactionId: b)
        }
        let september = try step(.lastRechargePaid, try build(today: Self.date(2026, 9, 20)))
        XCTAssertEqual(september.state, .done)
        XCTAssertEqual(september.detail, ThisMonthCopy.paid)
    }

    func testInexactTransferNeedsConfirmation() throws {
        try statement(Self.september, total: 8_000, status: .sent, sentAt: Self.date(2026, 10, 1))
        let id = try credit(Self.date(2026, 10, 5), 107_950)
        let first = try step(.lastRechargePaid, try build())
        XCTAssertEqual(first.state, .needsYou)
        XCTAssertEqual(first.actions, [.confirmMatch(transactionId: id)])
        XCTAssertTrue(first.detail?.contains(Money.format(7_950, currency: .eur)) ?? false)
    }

    func testNoTransferYetWaiting() throws {
        // Not sent yet: send it first.
        let draft = try statement(Self.september, total: 8_000, status: .draft)
        var first = try step(.lastRechargePaid, try build())
        XCTAssertEqual(first.state, .needsYou)
        XCTAssertEqual(first.actions, [.prepareEmail(statementId: draft)])

        // Sent, and the bank's movements stop before it was: fetch the bank statement.
        try db.write { db in
            try db.execute(sql: "UPDATE rechargeStatement SET status = 'sent', sentAt = ? WHERE id = ?", arguments: [Self.date(2026, 10, 1), draft])
        }
        try movement(Self.date(2026, 9, 28), -2_000)
        first = try step(.lastRechargePaid, try build())
        XCTAssertEqual(first.state, .waiting)
        XCTAssertEqual(first.actions, [.fetchStatement(.bank)])
        XCTAssertFalse(first.isWaitingForMac)

        // Movements since, but no transfer yet.
        try movement(Self.date(2026, 10, 10), -2_000)
        first = try step(.lastRechargePaid, try build())
        XCTAssertEqual(first.state, .waiting)
        XCTAssertEqual(first.detail, ThisMonthCopy.waitingForTransfer)

        // A statement sent from the iPad, not imported yet: waiting for the Mac.
        try db.write { db in
            var file = ImportWaitingFile(sha256: String(repeating: "b", count: 64), originalFileName: "statement.pdf", byteCount: 10,
                                         storedRelativePath: "\(String(repeating: "b", count: 64))/statement.pdf", text: nil, textStatus: .unknown,
                                         reason: CheckAndLinkCopy.sentReason, recognisedAs: "BBVA statement", keptAt: Self.today)
            try file.insert(db)
        }
        first = try step(.lastRechargePaid, try build())
        XCTAssertEqual(first.state, .waiting)
        XCTAssertTrue(first.isWaitingForMac)
        XCTAssertEqual(first.detail, ThisMonthCopy.waitingForMac)
        XCTAssertEqual(first.actions, [])
    }

    func testBankPastTheWindowWithNoTransferOffersMarkReceived() throws {
        // Sent on 2 September: the payment window runs 45 days, to 17 October.
        try statement(Self.september, total: 8_000, status: .sent, sentAt: Self.date(2026, 9, 2))
        try movement(Self.date(2026, 10, 10), -2_000)
        XCTAssertEqual(try step(.lastRechargePaid, try build()).state, .waiting)
        // The bank's movements go past the window and no transfer came: received another way?
        try movement(Self.date(2026, 10, 18), -2_000)
        let past = try step(.lastRechargePaid, try build())
        XCTAssertEqual(past.state, .needsYou)
        XCTAssertEqual(past.actions, [.markReceived])
        XCTAssertEqual(past.detail, ThisMonthCopy.noTransferSeen(Money.format(8_000, currency: .eur)))
    }

    // MARK: Steps 2 and 3

    func testPerProviderStatesFromGrid() throws {
        try billedMonthly("power")
        try billedMonthly("water")
        try billedMonthly("gas")
        // Old Heat stopped in March: not expected any more.
        for month in 1...3 { try invoice("heat", issued: Self.date(2026, month, 10)) }
        try invoice("power", issued: Self.date(2026, 10, 9))
        let download = trayItem("SampleAguas_2026-10.pdf")
        let unrelated = trayItem("other.pdf", host: "bank.example")
        let checklist = try build(trayCount: 2, trayItems: [download, unrelated])
        let bills = try step(.billsIn, checklist)
        XCTAssertEqual(bills.state, .needsYou)
        let states = Dictionary(uniqueKeysWithValues: bills.providers.map { ($0.name, $0.state) })
        XCTAssertEqual(states, ["Example Power": .checked, "Sample Aguas": .fetched, "Demo Gas": .missing])
        XCTAssertEqual(bills.providers.first { $0.name == "Sample Aguas" }?.trayItemIds, [download.id])
        XCTAssertEqual(Set(bills.actions), [.check(trayItemId: download.id), .openSite(providerId: ids["gas"]!)])
        XCTAssertEqual(bills.detail, "1 of 3 checked · 1 downloaded, to check · 1 to fetch")
        XCTAssertEqual(checklist.downloadsWaiting, 2)

        // A download from the provider's site counts too.
        let fromSite = trayItem("fatura.pdf", host: "www.demogas.example")
        let again = try step(.billsIn, try build(trayItems: [fromSite]))
        XCTAssertEqual(again.providers.first { $0.name == "Demo Gas" }?.state, .fetched)
    }

    func testNothingExpectedStepTwoNotApplicable() throws {
        // One bill only, months ago: no steady gap, nothing this month.
        try invoice("power", issued: Self.date(2026, 6, 10))
        let checklist = try build()
        XCTAssertEqual(try step(.billsIn, checklist).state, .notApplicable)
        XCTAssertEqual(try step(.billsIn, checklist).detail, ThisMonthCopy.noBillsExpected)
        XCTAssertEqual(try step(.chargesInGrid, checklist).state, .notApplicable)
        XCTAssertEqual(try step(.lastRechargePaid, checklist).state, .notApplicable)
        XCTAssertEqual(try step(.emailTenant, checklist).state, .notApplicable)
        XCTAssertEqual(try step(.emailTenant, checklist).detail, ThisMonthCopy.nothingToRecharge)
    }

    func testStepThreeFollowsStepTwo() throws {
        try billedMonthly("power")
        var checklist = try build()
        XCTAssertEqual(try step(.billsIn, checklist).state, .needsYou)
        XCTAssertEqual(try step(.chargesInGrid, checklist).state, .waiting)
        // A payment seen without its invoice is still missing.
        let debit = try movement(Self.date(2026, 10, 9), -5_000, "EXAMPLE POWER DD", category: "utilities")
        checklist = try build()
        XCTAssertEqual(try step(.billsIn, checklist).providers.map(\.stage), [.missingInvoice])
        XCTAssertEqual(try step(.billsIn, checklist).providers.map(\.state), [.missing])
        XCTAssertEqual(try step(.chargesInGrid, checklist).state, .waiting)

        try invoice("power", issued: Self.date(2026, 10, 7), paidBy: debit)
        checklist = try build()
        XCTAssertEqual(try step(.billsIn, checklist).state, .done)
        XCTAssertEqual(try step(.chargesInGrid, checklist).state, .done)
        XCTAssertEqual(try step(.chargesInGrid, checklist).actions, [])
    }

    // MARK: Step 4

    func testEmailStepFollowsStatementState() throws {
        try billedMonthly("power")
        try statement(Self.september, total: 8_000, status: .paid, sentAt: Self.date(2026, 10, 1))
        let draft = try statement(Self.october, total: 5_000, status: .draft)
        // Bills not checked yet: waiting.
        var email = try step(.emailTenant, try build())
        XCTAssertEqual(email.state, .waiting)
        XCTAssertEqual(email.detail, ThisMonthCopy.afterSteps)
        XCTAssertEqual(email.actions, [])

        try invoice("power", issued: Self.date(2026, 10, 9))
        let checklist = try build()
        XCTAssertEqual(checklist.steps.map(\.state), [.done, .done, .done, .needsYou])
        email = try step(.emailTenant, checklist)
        XCTAssertEqual(email.actions, [.prepareEmail(statementId: draft)])
        XCTAssertEqual(email.detail, ThisMonthCopy.readyToSend(Money.format(5_000, currency: .eur)))
        XCTAssertEqual(checklist.statementId, draft)

        // Last month's recharge not paid yet: this month's email is not held back.
        try db.write { db in try db.execute(sql: "UPDATE rechargeStatement SET status = 'sent' WHERE month = ?", arguments: [Self.september]) }
        let unpaid = try build()
        XCTAssertNotEqual(try step(.lastRechargePaid, unpaid).state, .done)
        XCTAssertEqual(try step(.emailTenant, unpaid).state, .needsYou)
        XCTAssertEqual(try step(.emailTenant, unpaid).actions, [.prepareEmail(statementId: draft)])
    }

    func testSentStatementIsDone() throws {
        try billedMonthly("power")
        try statement(Self.october, total: 5_000, status: .sent, sentAt: Self.date(2026, 10, 18))
        let email = try step(.emailTenant, try build())
        XCTAssertEqual(email.state, .done)
        XCTAssertEqual(email.detail, ThisMonthCopy.sentOn(Self.date(2026, 10, 18)))
    }

    // MARK: Side column, privacy, scope

    func testSideItemsAndCounts() throws {
        // Condomínio paid monthly on the 8th; October's not yet.
        for month in 7...9 { try movement(Self.date(2026, month, 8), -9_000, "CONDOMINIO", category: "condominium") }
        try db.write { db in _ = try PropertyEvidence.seedRules(db: db, propertyId: ids["property"]!) }
        var checklist = try build(trayCount: 3)
        XCTAssertEqual(checklist.side.map(\.kind), [.rentReceipt, .condominium])
        XCTAssertEqual(checklist.side[0].state, .needsYou)
        XCTAssertEqual(checklist.side[0].actions, [.fetchStatement(.tax)])
        XCTAssertEqual(checklist.side[1].state, .needsYou)
        XCTAssertEqual(checklist.side[1].date, Self.date(2026, 10, 8))
        XCTAssertEqual(checklist.side[1].amountMinorUnits, 9_000)
        XCTAssertEqual(checklist.downloadsWaiting, 3)
        let expected = try db.read { db in
            MissingEvidence.progress(MissingEvidence.affectingTaxFigures(try MissingEvidence.items(db: db, taxYear: UKTaxYear.containing(Self.today)))).missing
        }
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(checklist.evidenceCount, expected)

        // The receipt issued and the condomínio paid.
        try db.write { db in
            var receipt = RentReceipt(tenancyId: ids["tenancy"]!, receiptNumber: "77", periodStart: Self.october, periodEnd: Self.date(2026, 10, 31),
                                      receiptDate: Self.date(2026, 10, 2), amountMinorUnits: 100_000)
            try RentReceipts.save(db: db, &receipt)
        }
        try movement(Self.date(2026, 10, 8), -9_000, "CONDOMINIO", category: "condominium")
        checklist = try build(trayCount: 3)
        XCTAssertEqual(checklist.side.map(\.state), [.done, .done])
        XCTAssertEqual(checklist.side[1].headline, ThisMonthCopy.condominiumPaid(Self.date(2026, 10, 8)))
    }

    func testBuildWritesNothing() throws {
        try billedMonthly("power")
        try statement(Self.september, total: 8_000, status: .sent, sentAt: Self.date(2026, 10, 1))
        try credit(Self.date(2026, 10, 5), 108_000)
        try statement(Self.october, total: 5_000, status: .draft)
        // `build` runs in a read-only transaction (a write would throw), and changes no row.
        let before = try db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM rechargeStatement ORDER BY id") + Row.fetchAll(db, sql: "SELECT * FROM rechargePayment") }
        let changes = try db.write { db -> Int in
            let start = db.totalChangesCount
            _ = try ThisMonthChecklist.build(db: db, tenancyId: ids["tenancy"]!, today: Self.today, trayCount: 0)
            return db.totalChangesCount - start
        }
        XCTAssertEqual(changes, 0)
        XCTAssertNoThrow(try build())
        let after = try db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM rechargeStatement ORDER BY id") + Row.fetchAll(db, sql: "SELECT * FROM rechargePayment") }
        XCTAssertEqual(before, after)
    }

    func testSelectedTenancyOnly() throws {
        try db.write { db in ids["roomB"] = try tenancy(db, "Room B", from: Self.date(2025, 1, 1)) }
        try statement(Self.september, total: 9_000, status: .sent, sentAt: Self.date(2026, 10, 1), tenancy: "roomB")
        let draftB = try statement(Self.october, total: 4_000, status: .draft, tenancy: "roomB")
        let a = try build()
        XCTAssertEqual(a.tenancyName, "Room A")
        XCTAssertEqual(try step(.lastRechargePaid, a).state, .notApplicable)
        XCTAssertNil(a.statementId)
        let b = try build(tenancy: "roomB")
        XCTAssertEqual(b.tenancyName, "Room B")
        XCTAssertEqual(b.tenancyId, ids["roomB"])
        XCTAssertEqual(try step(.lastRechargePaid, b).state, .waiting)
        XCTAssertEqual(b.statementId, draftB)
    }

    func testMemberWithoutExpenseVisibilityHidden() throws {
        try db.write { db in _ = try PropertyEvidence.seedRules(db: db, propertyId: ids["property"]!) }
        let (admin, member) = try db.write { db -> (AccessActor, AccessActor) in
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Admin')")
            var adminUser = AppUser(personId: db.lastInsertedRowID, displayName: "Admin", isAdmin: true, createdAt: Self.today)
            try adminUser.insert(db)
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Member')")
            var memberUser = AppUser(personId: db.lastInsertedRowID, displayName: "Member", isAdmin: false, createdAt: Self.today)
            try memberUser.insert(db)
            return (try AccessActor.load(appUserId: adminUser.id!, db: db), try AccessActor.load(appUserId: memberUser.id!, db: db))
        }
        func setLevel(_ area: AccessArea, _ level: PermissionLevel) throws {
            try db.write { db in
                try db.execute(sql: """
                    INSERT INTO memberPermission(appUserId, area, level) VALUES (?, ?, ?)
                    ON CONFLICT(appUserId, area) DO UPDATE SET level = excluded.level
                    """, arguments: [member.appUserId, area.storageKey, level.rawValue])
            }
        }
        let full = try build(trayCount: 2, viewer: admin)
        XCTAssertFalse(full.isHidden)
        XCTAssertEqual(full, try build(trayCount: 2))
        XCTAssertEqual(try build(trayCount: 2, viewer: member), full)

        try setLevel(.documents, .none)
        let noDocuments = try build(trayCount: 2, viewer: member)
        XCTAssertFalse(noDocuments.isHidden)
        XCTAssertEqual(noDocuments.evidenceCount, 0)
        XCTAssertGreaterThan(full.evidenceCount, 0)

        try setLevel(.property, .none)
        let hidden = try build(trayCount: 2, viewer: member)
        XCTAssertTrue(hidden.isHidden)
        XCTAssertEqual(hidden.side, [])
        XCTAssertEqual(hidden.evidenceCount, 0)
        XCTAssertEqual(hidden.downloadsWaiting, 0)
        XCTAssertNil(hidden.statementId)
    }

    func testNoTenantPersonalNameInCopy() throws {
        try billedMonthly("power")
        try statement(Self.september, total: 8_000, status: .sent, sentAt: Self.date(2026, 10, 1))
        try statement(Self.october, total: 5_000, status: .draft)
        for month in 7...9 { try movement(Self.date(2026, month, 8), -9_000, "CONDOMINIO", category: "condominium") }
        var texts: [String] = []
        for checklist in [try build(), try build(trayItems: [trayItem("example-power.pdf")])] {
            texts += checklist.steps.flatMap { [$0.headline, $0.detail ?? ""] } + checklist.side.map(\.headline) + [checklist.tenancyName]
        }
        try credit(Self.date(2026, 10, 5), 108_000)
        try invoice("power", issued: Self.date(2026, 10, 9))
        let done = try build()
        texts += done.steps.flatMap { [$0.headline, $0.detail ?? ""] }
        for text in texts {
            XCTAssertFalse(text.contains("Synthetic Tenant"), text)
            XCTAssertFalse(text.contains("Person"), text)
        }
        XCTAssertEqual(try step(.emailTenant, done).headline, ThisMonthCopy.emailTitle("Room A"))
        XCTAssertTrue(try step(.emailTenant, done).headline.contains("Room A"))
    }
}
