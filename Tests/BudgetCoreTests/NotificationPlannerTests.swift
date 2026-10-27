import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// Step 7b Task 8: the reminders are planned from Home's and Property's own read models, for the device's viewer only.
/// Synthetic data only (the demo database; `SharingFixture`'s Person A and B).
final class NotificationPlannerTests: XCTestCase {
    private var manager: DatabaseManager!
    private var evidence: URL!
    private var queue: DatabaseQueue { manager.dbQueue }

    private static let member = "_member"
    private static let admin = "_admin"

    override func setUpWithError() throws {
        (manager, evidence) = try PhoneDemoFixture.build()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: evidence)
    }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { DemoDatabase.date(y, m, d) }

    private static var london: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private let longAgo = Date(timeIntervalSince1970: 1_700_000_000)

    private func plan(_ viewer: PhoneViewer = .everyone, today: Date = PhoneDemoFixture.today, now: Date? = nil,
                      settings: PhoneOutputSettings = PhoneOutputSettings(), in queue: DatabaseQueue? = nil) throws -> [PlannedNotification] {
        try (queue ?? self.queue).read { db in
            try NotificationPlanner.plan(db: db, viewer: viewer, today: today, now: now ?? self.longAgo, settings: settings, calendar: Self.london)
        }
    }

    private func home(today: Date = PhoneDemoFixture.today) throws -> HomeSummary {
        try queue.read { db in try HomeSummary.make(try PhoneDemoFixture.input(db, today: today), db: db) }
    }

    /// A member (Person B, a new person) bound to `_member`, with the defaults; `levels` override areas.
    private func addMember(_ levels: [AccessArea: PermissionLevel] = [:]) throws {
        try queue.write { db in
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Person B')")
            var user = AppUser(personId: db.lastInsertedRowID, displayName: "B", isAdmin: false, createdAt: Self.day(2026, 1, 1))
            user.cloudKitUserRecordName = Self.member
            try user.insert(db)
            _ = try SyncRecordStore.uuid(for: "appUser", localId: user.id!, db: db)
            for personId in try Int64.fetchAll(db, sql: "SELECT id FROM person") { _ = try SyncRecordStore.uuid(for: "person", localId: personId, db: db) }
            try MemberPermissions.ensureDefaults(appUserId: user.id!, db: db)
            for (area, level) in levels {
                try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE appUserId = ? AND area = ?",
                               arguments: [level.rawValue, user.id!, area.storageKey])
            }
        }
    }

    private func makeUKTaxpayer() throws {
        try queue.write { db in try db.execute(sql: "UPDATE person SET ukUtr = '0000000000'") }
    }

    private func taxPersonAreas() throws -> [AccessArea] {
        try queue.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM person").map { try AccessArea.tax(ofPerson: $0, db: db) }
        }
    }

    private func nineAM(_ date: Date, minusDays days: Int) -> Date {
        let model = MonthRange.calendar
        let trigger = model.date(byAdding: .day, value: -days, to: model.startOfDay(for: date))!
        let parts = model.dateComponents([.year, .month, .day], from: trigger)
        return Self.london.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 9))!
    }

    // MARK: Rent

    func testRentLateNotifiesTenDaysAfterDue() throws {
        // November's rent is due on the 12th (the day October's came): late once the 10-day window has passed.
        let today = Self.day(2026, 11, 30)
        let now = Self.london.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 8))!
        let rent = try plan(today: today, now: now).filter { $0.kind == .rentLate }
        let item = try XCTUnwrap(rent.first)
        XCTAssertEqual(rent.count, 1)
        XCTAssertTrue(item.id.hasPrefix("rent/"))
        XCTAssertTrue(item.id.hasSuffix("/2026-11-12"))
        XCTAssertEqual(item.fireDate, now.addingTimeInterval(60), "found late: once, a minute from now")
        XCTAssertEqual(item.title, "Rent not seen")
        XCTAssertTrue(item.body.hasPrefix("Rent for \(DemoDatabase.propertyName) hasn't arrived 10 days after it was due"))
        XCTAssertEqual(item.link, .home)
    }

    func testRentArrivedNoNotification() throws {
        XCTAssertTrue(try plan().filter { $0.kind == .rentLate }.isEmpty, "October's rent came on the 12th")
        // Expected, inside the window: not yet.
        XCTAssertTrue(try plan(today: Self.day(2026, 11, 15)).filter { $0.kind == .rentLate }.isEmpty)
    }

    // MARK: Bills and tax

    func testBillDueThreeDaysBefore() throws {
        let bill = try XCTUnwrap(try home().upcoming.first { $0.source == .bill && $0.date > Self.day(2026, 10, 20) })
        let item = try XCTUnwrap(try plan().first { $0.id == bill.id })
        XCTAssertEqual(item.kind, .billDue)
        XCTAssertEqual(item.fireDate, nineAM(bill.date, minusDays: 3))
        XCTAssertEqual(item.title, "Bill due in 3 days")
        XCTAssertTrue(item.body.hasPrefix("\(bill.title) is due on "))
    }

    func testBillPastDueDropped() throws {
        let bill = try XCTUnwrap(try home().upcoming.first { $0.source == .bill })
        let after = MonthRange.calendar.date(byAdding: .day, value: 1, to: bill.date)!
        XCTAssertNotNil(try plan().first { $0.id == bill.id })
        XCTAssertNil(try plan(today: after).first { $0.id == bill.id })
        // Dated before today in the read model's list: still dropped.
        XCTAssertTrue(try plan(today: after).allSatisfy { $0.kind == .rentLate || $0.kind == .noImport || $0.fireDate >= self.longAgo })
    }

    func testBillDueTodayFiresAMinuteFromNow() throws {
        let bill = try XCTUnwrap(try home().upcoming.first { $0.source == .bill })
        let now = MonthRange.calendar.date(byAdding: .hour, value: -12, to: bill.date)!
        let item = try XCTUnwrap(try plan(today: bill.date, now: now).first { $0.id == bill.id })
        XCTAssertEqual(item.fireDate, now.addingTimeInterval(60))
    }

    func testTaxPaymentSevenDaysBefore() throws {
        try makeUKTaxpayer()
        let today = Self.day(2026, 12, 10)
        let sa = try XCTUnwrap(try home(today: today).upcoming.first { $0.obligationKind == .ukSelfAssessmentJanuary })
        let all = try plan(today: today)
        let item = try XCTUnwrap(all.first { $0.id == sa.id })
        XCTAssertEqual(item.kind, .taxDue)
        XCTAssertEqual(item.fireDate, nineAM(sa.date, minusDays: 7))
        XCTAssertEqual(item.title, "Tax payment due in 7 days")
        XCTAssertEqual(all.filter { $0.id == sa.id }.count, 1, "never also a bill")
        XCTAssertTrue(all.filter { $0.kind == .billDue }.allSatisfy { $0.id != sa.id })
    }

    func testHomeSummaryItemsKeepObligationKind() throws {
        try makeUKTaxpayer()
        let upcoming = try home(today: Self.day(2026, 12, 10)).upcoming
        XCTAssertTrue(upcoming.filter { $0.source == .bill }.allSatisfy { $0.obligationKind == nil })
        let obligations = upcoming.filter { $0.source == .propertyObligation }
        XCTAssertFalse(obligations.isEmpty)
        XCTAssertTrue(obligations.allSatisfy { $0.obligationKind != nil })
        XCTAssertTrue(obligations.contains { $0.obligationKind == .ukSelfAssessmentJanuary })
    }

    // MARK: Import

    func testNoImportAdminOnly() throws {
        try addMember()
        let dataThrough = try XCTUnwrap(try queue.read { try PhoneDemoFixture.input($0).dataThrough })
        let calendar = MonthRange.calendar
        func on(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: dataThrough))! }

        XCTAssertTrue(try plan(today: on(13)).filter { $0.kind == .noImport }.isEmpty)
        let now = Self.london.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))!
        let admin = try plan(today: on(14), now: now).filter { $0.kind == .noImport }
        let item = try XCTUnwrap(admin.first)
        XCTAssertEqual(admin.count, 1)
        XCTAssertTrue(item.id.hasPrefix("import/"))
        XCTAssertEqual(item.fireDate, now.addingTimeInterval(60))
        XCTAssertEqual(item.title, "No statement imported")
        XCTAssertEqual(item.body, "The last import was 14 days ago or more.")
        XCTAssertTrue(try plan(.iCloudUser(recordName: Self.member), today: on(30)).filter { $0.kind == .noImport }.isEmpty)
    }

    // MARK: Settings and areas

    func testSettingsSwitchEachKindOff() throws {
        try makeUKTaxpayer()
        let today = Self.day(2026, 12, 10)
        let all = try plan(today: today)
        for kind in NotificationKind.allCases {
            XCTAssertTrue(all.contains { $0.kind == kind } || kind == .rentLate || kind == .noImport, "\(kind) planned")
        }
        let lateRent = try plan(today: Self.day(2026, 11, 30))
        XCTAssertTrue(lateRent.contains { $0.kind == .rentLate })
        XCTAssertTrue(lateRent.contains { $0.kind == .noImport })
        for kind in NotificationKind.allCases {
            var settings = PhoneOutputSettings()
            settings.notifications.remove(kind)
            for (day, planned) in [(today, all), (Self.day(2026, 11, 30), lateRent)] {
                let got = try plan(today: day, settings: settings)
                XCTAssertTrue(got.allSatisfy { $0.kind != kind }, "\(kind) off")
                XCTAssertEqual(got, planned.filter { $0.kind != kind }, "the others stay")
            }
        }
        XCTAssertTrue(try plan(today: today, settings: PhoneOutputSettings(notifications: [])).isEmpty)
    }

    func testAreaNoneIsQuiet() throws {
        try makeUKTaxpayer()
        let member = PhoneViewer.iCloudUser(recordName: Self.member)
        let rentDay = Self.day(2026, 11, 30), taxDay = Self.day(2026, 12, 10)

        // Property None: no rent, no property bills, no tax; the forecast's bills stay.
        try addMember([.property: .none])
        let taxAreas = try taxPersonAreas()
        XCTAssertTrue(try plan(member, today: rentDay).filter { $0.kind == .rentLate }.isEmpty)
        let noProperty = try plan(member, today: taxDay)
        XCTAssertTrue(noProperty.filter { $0.kind == .taxDue }.isEmpty)
        XCTAssertTrue(noProperty.filter { $0.kind == .billDue }.allSatisfy { $0.id.hasPrefix("bill/") })
        XCTAssertFalse(noProperty.filter { $0.kind == .billDue }.isEmpty)

        // Forecast None: no planned bills; the property's obligations stay.
        try queue.write { db in
            try db.execute(sql: "UPDATE memberPermission SET level = 'view' WHERE area = 'property'")
            try db.execute(sql: "UPDATE memberPermission SET level = 'none' WHERE area = 'forecast'")
        }
        let noForecast = try plan(member, today: taxDay)
        XCTAssertTrue(noForecast.filter { $0.kind == .billDue }.allSatisfy { !$0.id.hasPrefix("bill/") })
        XCTAssertFalse(noForecast.filter { $0.kind == .taxDue }.isEmpty)
        XCTAssertFalse(try plan(member, today: rentDay).filter { $0.kind == .rentLate }.isEmpty, "View on Property is enough")

        // Tax None everywhere: no tax reminder, the rest stays.
        try queue.write { db in
            try db.execute(sql: "UPDATE memberPermission SET level = 'view' WHERE area = 'forecast'")
            for area in taxAreas { try db.execute(sql: "UPDATE memberPermission SET level = 'none' WHERE area = ?", arguments: [area.storageKey]) }
        }
        let noTax = try plan(member, today: taxDay)
        XCTAssertTrue(noTax.filter { $0.kind == .taxDue }.isEmpty)
        XCTAssertFalse(noTax.filter { $0.kind == .billDue }.isEmpty)
        // One person's tax at View brings it back.
        try queue.write { db in
            try db.execute(sql: "UPDATE memberPermission SET level = 'view' WHERE area = ?", arguments: [taxAreas[0].storageKey])
        }
        XCTAssertFalse(try plan(member, today: taxDay).filter { $0.kind == .taxDue }.isEmpty)
    }

    func testUnboundViewerPlansNothing() throws {
        try makeUKTaxpayer()
        XCTAssertTrue(try plan(.iCloudUser(recordName: nil), today: Self.day(2026, 11, 30)).isEmpty)
        XCTAssertTrue(try plan(.iCloudUser(recordName: "_nobody"), today: Self.day(2026, 11, 30)).isEmpty)
        XCTAssertFalse(try plan(.demoAdmin, today: Self.day(2026, 11, 30)).isEmpty)
    }

    func testMemberNeverGetsAdminsPrivateAccountsBills() throws {
        let fixture = try TestDatabase.migrated()
        let (propertyId, privateAccount, category) = try fixture.write { db -> (Int64, Int64, Int64) in
            let f = try SharingFixture.build(db)
            try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = ? WHERE personId = ?", arguments: [Self.member, f.personB])
            try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = ? WHERE personId = ?", arguments: [Self.admin, f.personA])
            return (f.propertyId, f.privateAccount, f.propertyCategory)
        }
        _ = (propertyId, category)
        let today = Self.day(2026, 9, 30)
        func titles(_ recordName: String) throws -> [String] {
            try plan(.iCloudUser(recordName: recordName), today: today, in: fixture).map(\.body)
        }
        // Whatever the admin may be told, the member's reminders hold no private account's name or figure.
        let account = try fixture.read { try String.fetchOne($0, sql: "SELECT name FROM account WHERE id = ?", arguments: [privateAccount]) }!
        for text in try titles(Self.member) { XCTAssertFalse(text.contains(account)) }
        let memberPlan = try plan(.iCloudUser(recordName: Self.member), today: today, settings: PhoneOutputSettings(showFiguresOnLockScreen: true), in: fixture)
        for item in memberPlan { XCTAssertFalse((item.title + item.body).contains(account)) }
        let adminIds = Set(try plan(.iCloudUser(recordName: Self.admin), today: today, in: fixture).map(\.id))
        XCTAssertTrue(Set(memberPlan.map(\.id)).isSubset(of: adminIds.union(memberPlan.map(\.id)).filter { !$0.hasPrefix("import/") }),
                      "and no admin-only reminder")
        XCTAssertTrue(memberPlan.allSatisfy { $0.kind != .noImport })
    }

    // MARK: Text

    func testTextHasNoAmountsUnlessLockScreenFiguresOn() throws {
        try makeUKTaxpayer()
        let today = Self.day(2026, 11, 30)
        let off = try plan(today: today)
        XCTAssertTrue(off.contains { $0.kind == .rentLate })
        for item in off {
            let text = item.title + " " + item.body
            XCTAssertFalse(text.contains("£") || text.contains("€") || text.contains("$"), text)
            XCTAssertFalse(text.contains("expected"), text)
        }
        let on = try plan(today: today, settings: PhoneOutputSettings(showFiguresOnLockScreen: true))
        let rent = try XCTUnwrap(on.first { $0.kind == .rentLate })
        let glance = try queue.read { try PropertyGlance.all(db: $0, today: today) }.first!
        let amount = Money.format(try XCTUnwrap(glance.rentMinorUnits), currency: glance.property.currency)
        XCTAssertTrue(rent.body.hasSuffix(" (\(amount) expected)."), rent.body)
        let bill = try XCTUnwrap(try home(today: PhoneDemoFixture.today).upcoming.first { $0.source == .bill })
        let billOn = try XCTUnwrap(try plan(settings: PhoneOutputSettings(showFiguresOnLockScreen: true)).first { $0.id == bill.id })
        XCTAssertTrue(billOn.body.hasSuffix(" " + Money.format(try XCTUnwrap(bill.amountMinorUnits), currency: bill.currency)), billOn.body)
        let billOff = try XCTUnwrap(try plan().first { $0.id == bill.id })
        XCTAssertFalse(billOff.body.contains("£"))
    }

    func testFiguresTurnedOffReplacesThePendingReminder() throws {
        let today = Self.day(2026, 11, 30)
        let on = try plan(today: today, settings: PhoneOutputSettings(showFiguresOnLockScreen: true))
        let pending = Dictionary(uniqueKeysWithValues: on.map { ($0.id, $0.content) })
        let off = try plan(today: today)
        let result = NotificationReconciler.reconcile(planned: off, pending: pending, ledger: Set(pending.keys))
        let rent = try XCTUnwrap(off.first { $0.kind == .rentLate })
        XCTAssertTrue(result.remove.contains(rent.id))
        let replaced = try XCTUnwrap(result.add.first { $0.id == rent.id })
        XCTAssertFalse(replaced.body.contains("expected"), replaced.body)
    }

    func testCopyWordsAreExact() {
        XCTAssertEqual(NotificationCopy.rentLate(property: "Flat", showFigures: false, amount: "€1.00").body,
                       "Rent for Flat hasn't arrived 10 days after it was due.")
        XCTAssertEqual(NotificationCopy.rentLate(property: "Flat", showFigures: true, amount: nil).body,
                       "Rent for Flat hasn't arrived 10 days after it was due.")
        XCTAssertEqual(NotificationCopy.rentLate(property: "Flat", showFigures: true, amount: "€1.00").body,
                       "Rent for Flat hasn't arrived 10 days after it was due (€1.00 expected).")
        let date = Self.day(2026, 11, 12)
        XCTAssertEqual(NotificationCopy.billDue(name: "Gas", date: date, showFigures: true, amount: "£5.00").body, "Gas is due on 12 Nov 2026. £5.00")
        XCTAssertEqual(NotificationCopy.taxDue(name: "SA", date: date, showFigures: false, amount: "£5.00").body, "SA is due on 12 Nov 2026.")
    }

    func testLongNamesTruncateInTheMiddle() {
        let long = String(repeating: "a", count: 30) + String(repeating: "z", count: 30)
        let cut = NotificationCopy.truncated(long)
        XCTAssertEqual(cut.count, 40)
        XCTAssertTrue(cut.hasPrefix("aaaa"))
        XCTAssertTrue(cut.hasSuffix("zzzz"))
        XCTAssertEqual(cut.filter { $0 == "…" }.count, 1)
        XCTAssertEqual(NotificationCopy.truncated(String(repeating: "b", count: 40)).count, 40)
        XCTAssertFalse(NotificationCopy.truncated(String(repeating: "b", count: 40)).contains("…"))
        XCTAssertTrue(NotificationCopy.billDue(name: long, date: Self.day(2026, 1, 1), showFigures: false, amount: nil).body.contains(cut))
        XCTAssertTrue(NotificationCopy.rentLate(property: long, showFigures: false, amount: nil).body.contains(cut))
    }

    func testFireDateIs0900LocalOrOneMinuteFromNow() throws {
        let bill = try XCTUnwrap(try home().upcoming.first { $0.source == .bill && $0.date > Self.day(2026, 10, 20) })
        let trigger = MonthRange.calendar.date(byAdding: .day, value: -3, to: bill.date)!
        let parts = MonthRange.calendar.dateComponents([.year, .month, .day], from: trigger)
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let expected = tokyo.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 9))!
        let early = try queue.read { db in
            try NotificationPlanner.plan(db: db, viewer: .everyone, today: PhoneDemoFixture.today, now: self.longAgo,
                                         settings: PhoneOutputSettings(), calendar: tokyo)
        }
        XCTAssertEqual(try XCTUnwrap(early.first { $0.id == bill.id }).fireDate, expected)
        // After 09:00 that day: a minute from now.
        let late = expected.addingTimeInterval(3_600)
        let after = try queue.read { db in
            try NotificationPlanner.plan(db: db, viewer: .everyone, today: PhoneDemoFixture.today, now: late,
                                         settings: PhoneOutputSettings(), calendar: tokyo)
        }
        XCTAssertEqual(try XCTUnwrap(after.first { $0.id == bill.id }).fireDate, late.addingTimeInterval(60))
    }

    // MARK: Reconciler

    private func note(_ id: String) -> PlannedNotification {
        PlannedNotification(id: id, kind: .billDue, fireDate: longAgo, title: "t", body: "b", link: .home)
    }

    func testReconcileRemovesPendingNoLongerPlanned() {
        let result = NotificationReconciler.reconcile(planned: [note("a")], pending: ["a": "t\nb", "b": "t\nb", "c": "t\nb"], ledger: ["a", "b", "c"])
        XCTAssertEqual(result.remove, ["b", "c"])
        XCTAssertTrue(result.add.isEmpty)
    }

    func testReconcileNeverReschedulesALedgeredId() {
        let result = NotificationReconciler.reconcile(planned: [note("fired"), note("new")], pending: [:], ledger: ["fired"])
        XCTAssertEqual(result.add.map(\.id), ["new"])
        XCTAssertTrue(result.remove.isEmpty)
    }

    func testReconcileKeepsPendingStillPlanned() {
        let result = NotificationReconciler.reconcile(planned: [note("a")], pending: ["a": "t\nb"], ledger: [])
        XCTAssertEqual(result, NotificationReconciliation(add: [], remove: []))
    }

    func testReconcileReplacesPendingWhoseWordsChanged() {
        // Pending with an amount; the lock-screen figures went off, so the plan's words have none. Already in the
        // ledger (it was handed over), yet it never fired: replaced.
        let result = NotificationReconciler.reconcile(planned: [note("a"), note("b")], pending: ["a": "t\nb £5.00", "b": "t\nb"],
                                                      ledger: ["a", "b"])
        XCTAssertEqual(result.remove, ["a"])
        XCTAssertEqual(result.add.map(\.id), ["a"])
    }
}
