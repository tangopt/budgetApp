import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI
import struct BudgetCore.Transaction

/// Step 10 Task 16: Checks — the check lines in the Mac's words, "Not expected any more" with its Undo (no list of costs
/// not expected), hidden without Edit on Property, refused inline when it would move a filed return; and every Mac Checks
/// and Profile action answered. Demo data.
@MainActor
final class PadChecksModelTests: XCTestCase {
    private var db: DatabaseQueue!
    private let today = DemoDatabase.defaultAsOf

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        try DemoDatabase.build(at: path, evidenceRoot: folder.appendingPathComponent("Evidence"))
        db = try DatabaseQueue(path: path)
    }

    private func tabs(_ viewer: PhoneViewer = .demoAdmin) async -> PhoneTabsModel {
        let today = today
        let writer = DeviceWriter(db: db, viewer: { viewer }, afterWrite: {})
        let tabs = PhoneTabsModel(dbQueue: db, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: writer)
        await tabs.padProperty.reload()
        await tabs.padWrite.refresh()
        await tabs.padChecks.reload()
        return tabs
    }

    /// A recurring cost in one of the property's categories (not the mortgage's instalments).
    private func categoryCost(_ model: PadChecksModel) throws -> PadChecksModel.RecurringCost {
        try XCTUnwrap(model.recurringCosts.first { $0.pattern.categoryId != nil })
    }

    func testCheckLinesInTheMacsWords() async throws {
        let model = await tabs().padChecks
        let lines = model.lines
        XCTAssertEqual(lines.map(\.check), PadChecksModel.Check.allCases)
        let report = try XCTUnwrap(model.snapshot.report)
        XCTAssertEqual(model.headline, report.issueCount == 0 ? "Nothing to look at" : "\(report.issueCount) thing\(report.issueCount == 1 ? "" : "s") to look at")
        for line in lines where line.check == .months {
            XCTAssertEqual(line.state, report.monthsWithoutReceipt.isEmpty ? .ok : .issue)
            if report.monthsWithoutReceipt.isEmpty { XCTAssertEqual(line.text, "Every month the tenancy ran has a receipt") }
        }
        if let deposit = report.deposit {
            let line = try XCTUnwrap(lines.first { $0.check == .deposit })
            XCTAssertEqual(line.text, deposit.matches ? "The deposit account matches the terms"
                           : "The deposit account is \(PadChecksModel.depositOff(deposit, currency: model.currency))")
            XCTAssertEqual(PadChecksModel.depositLines(deposit).first?.amountMinorUnits, deposit.heldMinorUnits)
        }
        // The deposit's words, short and long.
        let short = PropertyCheckReport.DepositCheck(date: today, heldMinorUnits: 230_000, expectedDepositMinorUnits: 230_000,
                                                     expectedWithAdvanceMinorUnits: 345_000)
        XCTAssertEqual(PadChecksModel.depositPill(short, currency: .eur), "Matches the deposit")
        let off = PropertyCheckReport.DepositCheck(date: today, heldMinorUnits: 335_000, expectedDepositMinorUnits: 230_000,
                                                   expectedWithAdvanceMinorUnits: 345_000)
        XCTAssertEqual(PadChecksModel.depositOff(off, currency: .eur), "€100.00 short of the deposit and advance rent")
        XCTAssertEqual(PadChecksModel.depositLines(off).last?.title, "Short by")
    }

    func testNotExpectedThenUndoRestoresTheCost() async throws {
        let tabs = await tabs()
        let model = tabs.padChecks
        let cost = try categoryCost(model)
        XCTAssertEqual(model.actions(for: cost), [.notExpected])
        XCTAssertEqual(PadChecksAction.notExpected.rowAction?.systemImage, "bell.slash", "the shared vocabulary's icon")
        let stopped = await model.stopExpecting(cost)
        XCTAssertTrue(stopped)
        XCTAssertFalse(model.recurringCosts.contains { $0.id == cost.id }, "it leaves the list")
        XCTAssertEqual(model.toast?.message, "\(cost.pattern.title) is no longer expected.")
        XCTAssertTrue(model.toast?.canUndo == true)
        let decisions = try await db.read { try PropertyCheckDecision.fetchCount($0) }
        XCTAssertEqual(decisions, 1)
        // Undo: the series is expected again and comes back, in the same place.
        let undone = await model.undo()
        XCTAssertTrue(undone)
        XCTAssertTrue(model.recurringCosts.contains { $0.id == cost.id })
        XCTAssertEqual(model.toast?.message, "\(cost.pattern.title) is expected again.")
        XCTAssertFalse(model.toast?.canUndo ?? true, "nothing more to undo")
        let latest = try await db.read { [propertyId = tabs.padProperty.property!.id!] db in
            try PropertyCheckDecisions.latest(db: db, propertyId: propertyId)[cost.pattern.series]?.decision
        }
        XCTAssertEqual(latest, .expected)
    }

    func testNotExpectedHiddenWithoutPropertyEdit() async throws {
        let member = try await db.write { db -> String in
            var person = Person(name: "Person V", shortName: "V")
            try People.save(db: db, &person)
            var user = AppUser(personId: person.id!, displayName: "V", cloudKitUserRecordName: "_viewer", isAdmin: false,
                               createdAt: Date(timeIntervalSince1970: 0))
            try user.insert(db)
            _ = try SyncRecordStore.uuid(for: "appUser", localId: user.id!, db: db)
            try MemberPermissions.ensureDefaults(appUserId: user.id!, db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE appUserId = ? AND area = ?",
                           arguments: [PermissionLevel.view.rawValue, user.id!, AccessArea.property.storageKey])
            return "_viewer"
        }
        let tabs = await tabs(.iCloudUser(recordName: member))
        let model = tabs.padChecks
        XCTAssertFalse(tabs.padWrite.canEdit)
        XCTAssertFalse(model.recurringCosts.isEmpty, "the costs are still shown")
        for cost in model.recurringCosts { XCTAssertEqual(model.actions(for: cost), [], "hidden, not disabled") }
        XCTAssertEqual(model.screenActions().filter(\.edits), [])
        XCTAssertFalse(model.offersMatchCredits)
        // Nothing is written even if asked.
        let stopped = await model.stopExpecting(try categoryCost(model))
        XCTAssertFalse(stopped)
        XCTAssertNil(model.toast)
        let decisions = try await db.read { try PropertyCheckDecision.fetchCount($0) }
        XCTAssertEqual(decisions, 0)
    }

    func testNotExpectedInFiledYearRefusedInline() async throws {
        // A trigger stands in for a decision that moves a 2024/25 cost (decisions feed no return today): refused under the
        // cost's row, nothing saved, no toast.
        let cost = try await filedYearCostId()
        try await db.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER decisionMovesFiledYear AFTER INSERT ON propertyCheckDecision
                BEGIN UPDATE transaction_ SET amountMinorUnits = amountMinorUnits - 50000 WHERE id = \(cost); END
                """)
        }
        let tabs = await tabs()
        let model = tabs.padChecks
        let recurring = try categoryCost(model)
        let stopped = await model.stopExpecting(recurring)
        XCTAssertFalse(stopped)
        XCTAssertEqual(tabs.padWrite.message(for: recurring.rowId), DeviceWriteCopy.filedYear(years: ["2024/25"]))
        XCTAssertNil(model.toast)
        XCTAssertTrue(model.recurringCosts.contains { $0.id == recurring.id }, "still expected")
        let decisions = try await db.read { try PropertyCheckDecision.fetchCount($0) }
        XCTAssertEqual(decisions, 0)
    }

    func testEveryMacChecksAndProfileActionListed() {
        // The Mac's Checks tab, by name: each answered here, and nothing here unanswered.
        XCTAssertEqual(PadChecksAction.macActions.map(\.mac), [
            "Period", "Missing evidence for the property", "Add evidence rules", "Match credits", "Show the transaction",
            "Not expected any more", "Expect again",
        ])
        XCTAssertEqual(Set(PadChecksAction.macActions.map(\.pad)), Set(PadChecksAction.allCases))
        // The Mac's Profile tab (its panels, sheets and the map), by name.
        XCTAssertEqual(PadProfileAction.macActions.map(\.mac), [
            "Edit details", "Edit…", "Delete property…", "Edit address", "Find on map", "Several places match: pick one",
            "Place on map", "Adjust location", "Save location", "Edit owners…", "Edit person: name and tax identifiers",
            "New person…", "Link account…", "Role", "Unlink account", "Edit mortgage terms", "Add group", "Remove group",
            "Add document…", "Open document", "Unlink document",
        ])
        XCTAssertEqual(Set(PadProfileAction.macActions.compactMap(\.pad)), Set(PadProfileAction.allCases))
        // Only people stay on the Mac (their tax identifiers are kept there).
        XCTAssertEqual(PadProfileAction.macActions.filter { $0.pad == nil }.map(\.mac),
                       ["Edit person: name and tax identifiers", "New person…"])
        // Row actions use the shared vocabulary.
        XCTAssertEqual(PadProfileAction.unlinkDocument.rowAction, .unlink)
        XCTAssertEqual(PadChecksAction.showCredit.rowAction, .view)
    }

    func testTenantNameOffChecksAndProfile() async throws {
        let tabs = await tabs()
        await tabs.padProfile.reload()
        let names = tabs.padProperty.tenancies.compactMap(\.tenantName).filter { !$0.isEmpty }
        XCTAssertFalse(names.isEmpty)
        let checks = tabs.padChecks
        var words = checks.lines.map(\.text) + checks.recurringCosts.flatMap { [$0.pattern.title, $0.status] }
        let report = try XCTUnwrap(checks.snapshot.report)
        words += report.monthsWithoutReceipt.flatMap { [checks.monthLine($0).month, checks.monthLine($0).tenancy] }
        words += report.creditsWithoutReceipt.map(checks.creditTitle)
        let profile = tabs.padProfile
        words += [profile.mortgage.rate, profile.mortgage.nextRevision] + profile.snapshot.documents.map(\.displayName)
        for name in names {
            XCTAssertFalse(words.contains { $0.localizedCaseInsensitiveContains(name) }, "\(name) appears on Checks or Profile")
        }
    }

    /// A cost in one of the property's expense categories dated in the filed 2024/25 tax year.
    private func filedYearCostId() async throws -> Int64 {
        try await db.read { db in
            let propertyId = try XCTUnwrap(Property.order(Column("name")).fetchOne(db)?.id)
            let groups = try Properties.categoryGroupIds(db: db, propertyId: propertyId)
            let categories = try Category.filter(groups.contains(Column("groupId")) && Column("type") == CategoryType.expense.rawValue)
                .fetchAll(db).compactMap(\.id)
            let cost = try Transaction.filter(categories.contains(Column("categoryId")) && Column("date") >= Self.day(2024, 6, 1)
                                              && Column("date") < Self.day(2025, 3, 1)).fetchOne(db)
            return try XCTUnwrap(cost?.id)
        }
    }

    private nonisolated static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
