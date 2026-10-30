import XCTest
import GRDB
@testable import BudgetCore
import BudgetDemo
@testable import MangoUI
import TestSupport

/// Property's view model and words (iPhone spec §3.7; plan step 4, Task 10). Every figure is `PropertyGlance`'s, which
/// reads the Mac's property calculators; these tests pin the states, the wording and the route's check.
@MainActor
final class PropertyTests: XCTestCase {
    nonisolated private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func emptyDatabase() throws -> DatabaseQueue {
        return try TestDatabase.migrated()
    }

    private func demoDatabase() throws -> DatabaseQueue {
        let queue = try emptyDatabase()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("PropertyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try TestDatabase.fillDemo(queue, evidenceRoot: evidence)
        return queue
    }

    private func glance(rent: PropertyGlance.RentStatus = .none, letSince: Date? = nil, contractTo: Date? = nil,
                        receipt: PropertyGlance.ReceiptStatus = .none, recharge: PropertyGlance.RechargeStatus? = nil,
                        mortgage: PropertyGlance.Mortgage? = nil, comingUp: [PropertyObligation] = []) -> PropertyGlance {
        PropertyGlance(property: Property(id: 1, name: "Flat A", country: "PT", currency: .eur), letSince: letSince,
                       contractTo: contractTo, rent: rent, rentMinorUnits: nil, receipt: receipt, lastRecharge: recharge,
                       lastRechargeMonth: recharge == nil ? nil : Self.day(2026, 9, 1), lastRechargeTotalMinorUnits: recharge == nil ? nil : 4_210,
                       mortgage: mortgage, comingUp: comingUp)
    }

    // MARK: Loading

    func testTheDemoLoadsItsOnePropertyAsPropertyGlanceReadsIt() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let model = PropertyViewModel(dbQueue: queue, today: { today })
        XCTAssertEqual(model.state, .idle)
        await model.load()
        guard case let .loaded(page) = model.state else { return XCTFail("not loaded: \(model.state)") }
        let expected = try await queue.read { db in try PropertyGlance.all(db: db, today: today) }
        XCTAssertEqual(page.glances, expected)
        XCTAssertEqual(page.single, expected.first)
        XCTAssertNotNil(page.single?.mortgage)
        let check = try PropertyViewModel.figuresCheck(dbQueue: queue, today: today, shown: page)
        XCTAssertTrue(check.matches, check.line)
    }

    func testAnEmptyDatabaseIsNoPropertySetUp() async throws {
        let model = PropertyViewModel(dbQueue: try emptyDatabase(), today: { Self.day(2026, 10, 15) })
        await model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertEqual(PropertyCopy.emptyTitle, "No property set up")
    }

    /// Two properties: a list, each row pushing its own glance; none is shown directly.
    func testSeveralPropertiesAreAList() async throws {
        let queue = try demoDatabase()
        let other = try await queue.write { db -> Int64 in
            var property = Property(name: "Another flat", country: "PT", currency: .eur)
            try Properties.save(db: db, &property)
            return property.id!
        }
        let today = DemoDatabase.defaultAsOf
        let model = PropertyViewModel(dbQueue: queue, today: { today })
        await model.load()
        let page = try XCTUnwrap(model.state.page)
        XCTAssertNil(page.single)
        XCTAssertEqual(page.glances.count, 2)
        XCTAssertEqual(model.glance(for: PropertyDestination(propertyId: other))?.property.name, "Another flat")
        XCTAssertNil(model.glance(for: PropertyDestination(propertyId: 9_999)))
    }

    func testAFailedReadKeepsThePageAndAFirstFailureShowsTheFixedSentence() async throws {
        let queue = try demoDatabase()
        let model = PropertyViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        await model.load()
        guard case .loaded = model.state else { return XCTFail("not loaded") }
        try await queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DROP TABLE tenancy")
        }
        await model.load()
        guard case .loaded = model.state else { return XCTFail("the page was dropped: \(model.state)") }
        XCTAssertEqual(model.errorMessage, PropertyViewModel.loadFailureMessage)

        let fresh = PropertyViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        await fresh.load()
        XCTAssertEqual(fresh.state, .failed(PropertyViewModel.loadFailureMessage))
    }

    func testAReloadWaitsForANewSync() async throws {
        let queue = try emptyDatabase()
        let model = PropertyViewModel(dbQueue: queue, today: { DemoDatabase.defaultAsOf })
        await model.reload(for: nil)
        XCTAssertEqual(model.state, .empty)
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("PropertyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        try TestDatabase.fillDemo(queue, evidenceRoot: evidence)
        await model.reload(for: nil)  // a sync running: keeps what is shown
        XCTAssertEqual(model.state, .empty)
        await model.reload(for: Self.day(2026, 10, 15))
        XCTAssertNotNil(model.state.page)
        XCTAssertNil(PropertyViewModel.reloadKey(.syncing(.pulling)))
        XCTAssertEqual(PropertyViewModel.reloadKey(.idle(lastSync: Self.day(2026, 10, 15))), Self.day(2026, 10, 15))
    }

    /// The route's check fails when a figure shown differs from the Mac's.
    func testTheCheckCatchesADifferentOutstandingBalance() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        var page = try XCTUnwrap(PropertyViewModel.readNow(queue, today: today).page)
        page.glances[0].mortgage?.outstandingMinorUnits += 1
        let check = try PropertyViewModel.figuresCheck(dbQueue: queue, today: today, shown: page)
        XCTAssertFalse(check.matches)
        XCTAssertTrue(check.line.contains("DIFFERENT"), check.line)
    }

    /// The `property-no_mortgage` route's copy: no mortgage card, the figures still the Mac's, the demo untouched.
    func testTheNoMortgageCopyHasNoMortgageAndLeavesTheDemoAlone() async throws {
        let queue = try demoDatabase()
        let today = DemoDatabase.defaultAsOf
        let copy = try PropertyRoutes.withoutMortgage(queue)
        let page = try XCTUnwrap(PropertyViewModel.readNow(copy, today: today).page)
        XCTAssertNil(page.single?.mortgage)
        XCTAssertNotNil(page.single?.rentMinorUnits)
        XCTAssertTrue(try PropertyViewModel.figuresCheck(dbQueue: copy, today: today, shown: page).matches)
        XCTAssertNotNil(PropertyViewModel.readNow(queue, today: today).page?.single?.mortgage)
    }

    // MARK: Words

    func testTheTenancyLine() {
        XCTAssertEqual(PropertyCopy.tenancyLine(glance(letSince: Self.day(2024, 8, 1), contractTo: Self.day(2027, 7, 31))),
                       "Let since 1 Aug 2024 · contract to 31 Jul 2027")
        XCTAssertEqual(PropertyCopy.tenancyLine(glance(letSince: Self.day(2024, 8, 1))), "Let since 1 Aug 2024 · no end date")
        XCTAssertEqual(PropertyCopy.tenancyLine(glance()), "Not let at the moment")
    }

    /// Received <date> / Expected / Late (iPhone spec §3.7).
    func testRentStatusWords() {
        XCTAssertEqual(PropertyCopy.rentStatus(.received(Self.day(2026, 10, 12))), "Received 12 Oct 2026")
        XCTAssertEqual(PropertyCopy.rentStatus(.expected(Self.day(2026, 11, 12))), "Expected 12 Nov 2026")
        XCTAssertEqual(PropertyCopy.rentStatus(.late(since: Self.day(2026, 11, 12))), "Late · due 12 Nov 2026")
        XCTAssertNil(PropertyCopy.rentStatus(.none))
        XCTAssertEqual(PropertyCopy.rentRole(.received(Self.day(2026, 10, 12))), .income)
        XCTAssertEqual(PropertyCopy.rentRole(.expected(Self.day(2026, 11, 12))), .neutral)
        XCTAssertEqual(PropertyCopy.rentRole(.late(since: Self.day(2026, 11, 12))), .neutral)
    }

    func testReceiptAndRechargeWords() {
        XCTAssertEqual(PropertyCopy.receipt(.issued), "Issued")
        XCTAssertEqual(PropertyCopy.receipt(.pending), "Not issued yet")
        XCTAssertNil(PropertyCopy.receipt(.none))
        XCTAssertEqual(PropertyCopy.recharge(.paid), "Paid")
        XCTAssertEqual(PropertyCopy.recharge(.sent), "Sent")
        XCTAssertEqual(PropertyCopy.recharge(.readyToSend), "Ready to send")
        XCTAssertEqual(PropertyCopy.recharge(.none), "Nothing to send")
        XCTAssertEqual(PropertyCopy.rechargeCaption(glance(recharge: .readyToSend)), "September 2026 · Ready to send")
        XCTAssertNil(PropertyCopy.rechargeCaption(glance()))
    }

    func testMortgageWords() {
        let progress = MortgageHistory.Progress(borrowedMinorUnits: 20_000_000, owedMinorUnits: 15_000_000, instalmentNumber: 26,
                                                totalInstalments: 360)
        XCTAssertEqual(PropertyCopy.repaid(progress), "25%")
        XCTAssertEqual(PropertyCopy.instalment(progress), "Instalment 26 of 360")
        var open = progress
        open.totalInstalments = nil
        XCTAssertEqual(PropertyCopy.instalment(open), "Instalment 26")
        open.instalmentNumber = nil
        XCTAssertNil(PropertyCopy.instalment(open))
        XCTAssertEqual(PropertyCopy.rate(3.125), MortgageRate.percent(3.125))
        XCTAssertEqual(PropertyCopy.spokenRepaid(progress), "25 percent repaid")
    }

    /// Estimates are marked "est." (and read as "estimated").
    func testComingUpCaptionsMarkEstimates() {
        let known = PropertyObligation(id: "a", date: Self.day(2026, 11, 1), kind: .mortgageInstalment, title: "Mortgage instalment",
                                       expectedMinorUnits: 70_000, currency: .eur, categoryId: nil, isEstimate: false)
        var estimate = known
        estimate.isEstimate = true
        XCTAssertEqual(PropertyCopy.comingUpCaption(known), "1 Nov 2026")
        XCTAssertEqual(PropertyCopy.comingUpCaption(estimate), "1 Nov 2026 · est.")
        XCTAssertEqual(PropertyCopy.comingUpSpoken(estimate, currency: .eur), "Mortgage instalment, 1 Nov 2026, estimated, due €700.00")
        var unknown = known
        unknown.expectedMinorUnits = nil
        XCTAssertEqual(PropertyCopy.comingUpSpoken(unknown, currency: .eur), "Mortgage instalment, 1 Nov 2026, amount not known")
        XCTAssertEqual(PropertyCopy.nothingComingUp, "Nothing due in the next 60 days.")
    }
}

/// The Flat tab's checklist progress (design review §4).
final class FlatChecklistTests: XCTestCase {
    private func step(_ id: ThisMonthChecklist.StepID, _ state: ThisMonthChecklist.StepState, detail: String? = nil) -> ThisMonthChecklist.Step {
        ThisMonthChecklist.Step(id: id, state: state, headline: id.rawValue, detail: detail, actions: [])
    }

    private func checklist(_ states: [ThisMonthChecklist.StepState]) -> ThisMonthChecklist {
        ThisMonthChecklist(tenancyId: 1, tenancyName: "Tenancy 2", month: Date(timeIntervalSince1970: 0),
                           steps: zip(ThisMonthChecklist.StepID.allCases, states).map { step($0, $1, detail: "detail \($0.rawValue)") },
                           side: [], evidenceCount: 0, downloadsWaiting: 0, lastStatementId: nil, statementId: nil)
    }

    func testProgressCountsDoneAndNotNeededSteps() {
        let shown = FlatChecklistPresentation(checklist([.done, .notApplicable, .needsYou, .waiting]))
        XCTAssertEqual(shown.progressText, "2 of 4 done")
        XCTAssertEqual((0..<4).map(shown.isFilled), [true, true, false, false])
    }

    func testOnlyTheCurrentStepKeepsItsLineAndEveryStepIsAPillNeverAnAction() {
        let shown = FlatChecklistPresentation(checklist([.done, .needsYou, .waiting, .waiting]))
        XCTAssertEqual(shown.steps.map(\.marker), [.done, .current, .later, .later])
        XCTAssertEqual(shown.steps.map(\.statusLine), [nil, "detail billsIn", nil, nil])
        XCTAssertEqual(shown.steps.map(\.pillText), ["Done", "To do", "Waiting", "Waiting"])
    }
}
