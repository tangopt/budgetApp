import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI
import struct BudgetCore.Transaction

/// Step 10 Task 15: Money: the months newest first, a transaction opening the panel with its documents, the figures table
/// equal to `PropertyFinance`, document links through the Documents writer (refused inline in a filed year), edits hidden
/// without Edit, and every Mac Money capability answered. Demo data.
@MainActor
final class PadMoneyModelTests: XCTestCase {
    private var db: DatabaseQueue!
    private let today = DemoDatabase.defaultAsOf

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pad-money-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("demo.sqlite").path
        try DemoDatabase.build(at: path, evidenceRoot: folder.appendingPathComponent("Evidence"))
        db = try DatabaseQueue(path: path)
    }

    private func tabs(canEdit: Bool = true) async -> PhoneTabsModel {
        let today = today
        let writer = DeviceWriter(db: db, viewer: { .demoAdmin }, afterWrite: {})
        let tabs = PhoneTabsModel(dbQueue: db, today: { today }, hasProperty: true, viewer: .demoAdmin, writer: writer)
        await tabs.padProperty.reload()
        await tabs.padDocumentWrite.refresh()
        await tabs.padMoney.reload()
        return tabs
    }

    /// The first transaction of the year with a document, expanded in its month: the month's start and the line.
    private func lineWithDocument(_ money: PadMoneyModel) async throws -> (month: Date, line: PadMoneyModel.Line) {
        for month in money.months {
            await money.toggle(month)
            let breakdown = try XCTUnwrap(money.breakdown(month))
            if let line = breakdown.groups.flatMap({ money.lines($0) }).first(where: { $0.documentCount > 0 }) { return (month.start, line) }
        }
        throw XCTSkip("the demo has no document-linked transaction in the year")
    }

    func testMoneyMonthListOrdersNewestFirst() async throws {
        let money = await tabs().padMoney
        let months = money.months
        XCTAssertGreaterThan(months.count, 1)
        XCTAssertEqual(months.map(\.start), months.map(\.start).sorted(by: >))
        XCTAssertEqual(months.map(\.start), (money.summary?.months ?? []).map(\.start).reversed())
        XCTAssertEqual(PadMoneyModel.monthTitle(months[0]), months[0].start.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).year()))
    }

    func testTransactionSelectionOpensPanelWithDocuments() async throws {
        let money = await tabs().padMoney
        let (month, line) = try await lineWithDocument(money)
        await money.select(line, month: month)
        let panel = try XCTUnwrap(money.panel)
        XCTAssertEqual(panel.line.transactionId, line.transactionId)
        let expected = try await db.read { db in
            try TransactionDocuments.documents(db: db, transactionId: line.transactionId, catalog: try DocumentKindCatalog.load(db: db))
        }
        XCTAssertEqual(panel.documents.map(\.id), expected.map(\.id))
        XCTAssertFalse(panel.documents.isEmpty)
        XCTAssertEqual(money.panelDocumentId, expected.first?.id, "the panel opens on the first document")
        XCTAssertNotNil(money.panelMonth, "opened from a month: its figures come with the panel")
        XCTAssertEqual(money.panelMonth?.netCashFlow, money.breakdown(try XCTUnwrap(money.months.first { $0.start == month }))?.netCashFlow)
        // A transaction without a document opens the panel with the Link document offer.
        let bare = money.months.lazy.compactMap { money.breakdown($0) }.flatMap { $0.groups.flatMap { money.lines($0) } }.first { $0.documentCount == 0 }
        if let bare {
            await money.select(bare)
            XCTAssertEqual(money.panel?.documents, [])
            XCTAssertNil(money.panelDocumentId)
            XCTAssertTrue(money.actions().contains(.linkDocument))
            XCTAssertFalse(money.actions().contains(.unlinkDocument))
        }
        money.closePanel()
        XCTAssertNil(money.panel)
    }

    func testFiguresTableAmountsMatchPropertyFinance() async throws {
        let money = await tabs().padMoney
        let propertyId = try XCTUnwrap(money.property.property?.id)
        let summary = try await db.read { db in
            try PropertyFinance.summary(db: db, propertyId: propertyId, period: .calendarYear(2026), today: DemoDatabase.defaultAsOf)
        }
        let t = summary.totals
        let rows = Dictionary(uniqueKeysWithValues: money.figureSections.flatMap(\.rows).map { ($0.id, $0.amount) })
        XCTAssertEqual(rows["perReceipts"], t.rentPerReceipts)
        XCTAssertEqual(rows["credits"], t.rentCredits)
        XCTAssertEqual(rows["received"], t.rentReceived)
        XCTAssertEqual(rows["income"], t.income)
        XCTAssertEqual(rows["costs"], t.costs)
        XCTAssertEqual(rows["interest"], t.mortgageInterest)
        XCTAssertEqual(rows["capital"], t.mortgageCapital)
        XCTAssertEqual(rows["net"], t.netCashFlow)
        XCTAssertEqual(rows["loan"], summary.outstandingLoan)
        XCTAssertEqual(rows["deposit"], summary.depositHeld)
        XCTAssertEqual(money.figureSections.map(\.title), ["Rent", "Income", "Costs", "Mortgage", "Cash flow", "Balances at the end"])
        // The tiles are the same figures; GBP is the other column of each.
        XCTAssertEqual(money.tiles.first { $0.id == "net" }?.amount, t.netCashFlow)
        XCTAssertEqual(money.shown(t.netCashFlow), t.netCashFlow.native)
        if money.offersGBP {
            money.showsGBP = true
            XCTAssertEqual(money.shown(t.netCashFlow), t.netCashFlow.gbp)
            XCTAssertEqual(money.displayCurrency, .gbp)
            XCTAssertNotNil(money.rateNote)
        }
        // A month's breakdown adds up to its bars.
        let month = try XCTUnwrap(money.months.first)
        await money.toggle(month)
        let breakdown = try XCTUnwrap(money.breakdown(month))
        XCTAssertEqual(breakdown.netCashFlow, month.figures.netCashFlow)
    }

    func testPeriodAndFigureTransactions() async throws {
        let money = await tabs().padMoney
        await money.choose(.taxYear(2025))
        XCTAssertEqual(money.summary?.period, .ukTaxYear(UKTaxYear(startYear: 2025)))
        XCTAssertEqual(money.periodTitle, "Tax 2025/26")
        await money.choose(.calendarYear(2026))
        let figure = try XCTUnwrap(money.figureSections.flatMap(\.rows).first { $0.id == "costs" })
        await money.show(figure)
        XCTAssertEqual(money.mode, .transactions)
        let propertyId = try XCTUnwrap(money.property.property?.id)
        let expected = try await db.read { db in
            try PropertyDrillTransactions.transactions(db: db, propertyId: propertyId, period: PropertyPeriod.calendarYear(2026).interval,
                                                       drillDown: .costs(categoryId: nil)).compactMap(\.id)
        }
        XCTAssertEqual(money.drillLines.map(\.transactionId), expected)
        XCTAssertEqual(money.drillLines.map(\.transaction.date), money.drillLines.map(\.transaction.date).sorted(), "oldest first")
        // A category chip lists that category's.
        if let chip = money.categoryChips.first {
            await money.show(chip)
            XCTAssertEqual(money.drill, chip)
            XCTAssertTrue(money.drillLines.allSatisfy { $0.categoryName == chip.title })
        }
        // A custom range that ends before it starts has no period.
        money.customFirstDay = DemoDatabase.defaultAsOf
        money.customLastDay = DemoDatabase.defaultAsOf.addingTimeInterval(-86_400 * 3)
        await money.choose(.custom)
        XCTAssertNil(money.period)
        XCTAssertNil(money.summary)
    }

    func testLinkAndUnlinkThroughTheDocumentsWriter() async throws {
        let tabs = await tabs()
        let money = tabs.padMoney
        var target: PadMoneyModel.Line?
        for month in money.months {
            await money.toggle(month)
            target = money.breakdown(month).flatMap { $0.groups.flatMap { money.lines($0) }.first { $0.documentCount == 0 } }
            if target != nil { break }
        }
        let line = try XCTUnwrap(target)
        await money.select(line)
        let choices = await money.documentChoices(for: line.transactionId)
        let document = try XCTUnwrap(choices.first, "the library has a document to link")
        let linked = await money.link(documentId: document.id)
        // The demo's transaction may sit in a filed year: then the refusal is inline and nothing is linked.
        if linked {
            XCTAssertEqual(money.panel?.documents.map(\.id), [document.id])
            XCTAssertEqual(money.panelDocumentId, document.id)
            XCTAssertTrue(money.actions().contains(.unlinkDocument))
            let unlinked = await money.unlink(documentId: document.id)
            XCTAssertTrue(unlinked)
            XCTAssertEqual(money.panel?.documents, [])
        } else {
            XCTAssertNotNil(tabs.padDocumentWrite.message(for: PadMoneyModel.transactionRow(line.transactionId)))
            XCTAssertEqual(money.panel?.documents, [])
        }
    }

    func testEditsHiddenWithoutDocumentsEdit() async throws {
        let tabs = PhoneTabsModel(dbQueue: db, today: { DemoDatabase.defaultAsOf }, hasProperty: true, viewer: .demoAdmin, writer: nil)
        await tabs.padProperty.reload()
        await tabs.padMoney.reload()
        let money = tabs.padMoney
        var found: PadMoneyModel.Line?
        for month in money.months where found == nil {
            await money.toggle(month)
            found = money.breakdown(month).flatMap { $0.groups.flatMap { money.lines($0) }.first }
        }
        await money.select(try XCTUnwrap(found))
        XCTAssertFalse(money.write.canEdit)
        XCTAssertTrue(money.actions().allSatisfy { !$0.edits }, "view-only: no link, no unlink")
        XCTAssertTrue(money.actions().contains(.transactionDetails))
        let refused = await money.link(documentId: 1)
        XCTAssertFalse(refused, "nothing is written without a writer")
    }

    func testRowActionsUseTheSharedVocabulary() {
        XCTAssertEqual(PadMoneyAction.linkDocument.rowAction, .linkDocument)
        XCTAssertEqual(PadMoneyAction.unlinkDocument.rowAction, .unlink)
        XCTAssertEqual(PadMoneyAction.viewDocument.rowAction, .view)
        XCTAssertEqual(PadMoneyAction.allCases.filter(\.edits), [.linkDocument, .unlinkDocument])
    }

    func testEveryMacMoneyAndCalendarCapabilityListed() {
        // The Mac's Money tab, by what it shows and does (PropertyMoneyTab, PropertyMonthPanel, PropertyFigurePanel).
        let moneyMac = ["Calendar year, tax year and custom range", "Summary · period", "Rate note: GBP at the Settings rate", "GBP column",
                        "Figures table", "Select a figure to list its transactions", "Costs by category", "A chevron for each category",
                        "Mortgage interest and capital", "Cash flow by month", "Click a month for its transactions", "Monthly figures table",
                        "Up and Down through the rows", "Documents of a transaction", "Link document", "Unlink document", "Edit transaction",
                        "Show in Search", "Show in Documents"]
        XCTAssertEqual(PadMoneyAction.macActions.map(\.mac), moneyMac)
        // Every action the screen offers answers something, and everything the Mac has is answered by an action of ours.
        XCTAssertEqual(Set(PadMoneyAction.allCases).subtracting(PadMoneyAction.macActions.map(\.pad)), [.view], "the By month / Transactions switch is ours")
        let calendarMac = ["The next twelve months", "A panel for each month", "Day, what, expected amount",
                           "≈ an estimate from the property's history", "A pill for a deadline without an amount",
                           "The month's expected total", "Nothing due: link the accounts in Profile"]
        XCTAssertEqual(PadCalendarAction.macActions.map(\.mac), calendarMac)
        XCTAssertTrue(Set(PadCalendarAction.macActions.map(\.pad)).isSubset(of: Set(PadCalendarAction.allCases)))
        // The iPad-only month grid, Upcoming/Past and the day filter are ours, beyond the Mac's.
        XCTAssertEqual(Set(PadCalendarAction.allCases).subtracting(PadCalendarAction.macActions.map(\.pad)), [.monthGrid, .upcomingOrPast, .filterByDay])
    }

    func testTenantNameNeverShownOnMoney() async throws {
        let money = await tabs().padMoney
        let names = money.property.tenancies.compactMap(\.tenantName).filter { !$0.isEmpty }
        XCTAssertFalse(names.isEmpty)
        var shown: [String] = money.tiles.flatMap { [$0.title, $0.caption ?? "", $0.text ?? ""] }
        shown += money.figureSections.flatMap { [$0.title] + $0.rows.flatMap { [$0.title, $0.detail ?? ""] } }
        shown += money.months.map(PadMoneyModel.monthTitle) + money.categoryChips.map(\.title)
        shown += PadMoneyAction.allCases.map(\.title)
        for name in names { XCTAssertFalse(shown.contains { $0.localizedCaseInsensitiveContains(name) }) }
    }
}
