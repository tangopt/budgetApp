import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// Step 7b Task 6: the widget's snapshot is Home's own figures for the device's viewer, kept in a store the widget
/// reads. Synthetic data only (the demo database; `SharingFixture`'s Person A and B).
final class WidgetSnapshotTests: XCTestCase {
    private static let admin = "_admin"
    private static let member = "_member"

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func sample(payday: Date = day(2026, 10, 24), lockScreen: Bool = false) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: Self.day(2026, 10, 15), netWorthMinorUnits: 1_234_500, leftToSpendMinorUnits: 45_600,
                       paydayDate: payday, showFiguresOnLockScreen: lockScreen)
    }

    // MARK: Home's figures

    func testSnapshotEqualsHomeSummaryForSameViewer() throws {
        let (manager, evidence) = try PhoneDemoFixture.build()
        defer { try? FileManager.default.removeItem(at: evidence) }
        let today = PhoneDemoFixture.today
        let (made, home) = try manager.dbQueue.read { db in
            let snapshot = try WidgetSnapshot.make(db: db, viewer: .demoAdmin, today: today, settings: PhoneOutputSettings())
            let input = try DashboardInput.load(db: db, today: today, actuals: try PhoneViewer.demoAdmin.actuals(db: db, today: today))
            return (snapshot, try HomeSummary.make(input, db: db))
        }
        let snapshot = try XCTUnwrap(made)
        XCTAssertNotNil(snapshot.netWorthMinorUnits)
        XCTAssertEqual(snapshot.netWorthMinorUnits, home.netWorth.currentNetWorthMinorUnits)
        XCTAssertEqual(snapshot.leftToSpendMinorUnits, home.leftToSpendMinorUnits)
        XCTAssertEqual(snapshot.paydayDate, home.paydayDate)
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.currencyCode, "GBP")
        XCTAssertEqual(snapshot.generatedAt, today)
    }

    func testMemberSnapshotExcludesAdminsPrivateAccounts() throws {
        let queue = try TestDatabase.migrated()
        let today = Self.day(2026, 9, 30)
        let names = try queue.write { db -> [String] in
            let f = try SharingFixture.build(db)
            try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = ? WHERE personId = ?", arguments: [Self.member, f.personB])
            try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = ? WHERE personId = ?", arguments: [Self.admin, f.personA])
            return try String.fetchAll(db, sql: "SELECT name FROM account")
        }
        func both(_ recordName: String) throws -> (WidgetSnapshot, HomeSummary) {
            try queue.read { db in
                let viewer = PhoneViewer.iCloudUser(recordName: recordName)
                let snapshot = try XCTUnwrap(WidgetSnapshot.make(db: db, viewer: viewer, today: today, settings: PhoneOutputSettings()))
                let input = try DashboardInput.load(db: db, today: today, actuals: try viewer.actuals(db: db, today: today))
                return (snapshot, try HomeSummary.make(input, db: db))
            }
        }
        let (hers, herHome) = try both(Self.member)
        let (his, _) = try both(Self.admin)
        XCTAssertEqual(hers.netWorthMinorUnits, herHome.netWorth.currentNetWorthMinorUnits)
        XCTAssertNotEqual(hers.netWorthMinorUnits, his.netWorthMinorUnits, "A's private accounts stay out of hers")

        let json = try XCTUnwrap(String(data: JSONEncoder().encode(hers), encoding: .utf8))
        for name in names { XCTAssertFalse(json.contains(name), "no account name: \(name)") }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "generatedAt", "netWorthMinorUnits", "currencyCode", "leftToSpendMinorUnits",
                                          "paydayDate", "showFiguresOnLockScreen", "monthSpend", "propertyMonths"],
                       "Home's figures and the two step 18 widgets' figures, nothing else")
    }

    // MARK: Settings

    func testSnapshotCarriesLockScreenSetting() throws {
        let (manager, evidence) = try PhoneDemoFixture.build()
        defer { try? FileManager.default.removeItem(at: evidence) }
        let (off, on) = try manager.dbQueue.read { db in
            (try WidgetSnapshot.make(db: db, viewer: .demoAdmin, today: PhoneDemoFixture.today, settings: PhoneOutputSettings()),
             try WidgetSnapshot.make(db: db, viewer: .demoAdmin, today: PhoneDemoFixture.today,
                                     settings: PhoneOutputSettings(showFiguresOnLockScreen: true)))
        }
        XCTAssertFalse(try XCTUnwrap(off).showFiguresOnLockScreen)
        XCTAssertTrue(try XCTUnwrap(on).showFiguresOnLockScreen)
    }

    func testEmptyDatabaseMakesNoSnapshot() throws {
        let queue = try TestDatabase.migrated()
        let made = try queue.read { db in
            try WidgetSnapshot.make(db: db, viewer: .iCloudUser(recordName: Self.admin), today: Self.day(2026, 9, 30), settings: PhoneOutputSettings())
        }
        XCTAssertNil(made, "Home's empty state: nothing synced yet")
        let isEmpty = try queue.read { db in
            try DashboardInput.load(db: db, today: Self.day(2026, 9, 30), actuals: try PhoneViewer.iCloudUser(recordName: Self.admin).actuals(db: db, today: Self.day(2026, 9, 30))).isEmpty
        }
        XCTAssertTrue(isEmpty)
    }

    func testSettingsDefaultOffAndAllNotificationsOn() throws {
        let settings = PhoneOutputSettings()
        XCTAssertFalse(settings.showFiguresOnLockScreen)
        XCTAssertEqual(settings.notifications, Set(NotificationKind.allCases))
        XCTAssertEqual(Set(NotificationKind.allCases), [.rentLate, .billDue, .taxDue, .noImport])

        let suite = "WidgetSnapshotTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PhoneOutputSettings.load(from: defaults), PhoneOutputSettings(), "nothing stored: the defaults")
        let changed = PhoneOutputSettings(showFiguresOnLockScreen: true, notifications: [.billDue])
        changed.save(to: defaults)
        XCTAssertNotNil(defaults.data(forKey: "phone.outputSettings"))
        XCTAssertEqual(PhoneOutputSettings.load(from: defaults), changed)
        // A field missing from what was stored keeps its default.
        defaults.set(Data(#"{"showFiguresOnLockScreen":true}"#.utf8), forKey: PhoneOutputSettings.defaultsKey)
        XCTAssertEqual(PhoneOutputSettings.load(from: defaults), PhoneOutputSettings(showFiguresOnLockScreen: true))
    }

    // MARK: Countdown

    func testDaysToPaydayCountsDownAndNeverNegative() {
        let snapshot = sample(payday: Self.day(2026, 10, 24))
        XCTAssertEqual(snapshot.daysToPayday(on: Self.day(2026, 10, 14)), 10)
        XCTAssertEqual(snapshot.daysToPayday(on: Self.day(2026, 10, 23).addingTimeInterval(20 * 3_600)), 1)
        XCTAssertEqual(snapshot.daysToPayday(on: Self.day(2026, 10, 24).addingTimeInterval(3_600)), 0)
        XCTAssertEqual(snapshot.daysToPayday(on: Self.day(2026, 10, 30)), 0)
    }

    // MARK: Store

    func testFileStoreRoundTripAndAtomicOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWidgetSnapshotStore(directory: directory)
        XCTAssertNil(store.read())
        try store.write(sample())
        XCTAssertEqual(store.read(), sample())
        XCTAssertEqual(store.fileURL.lastPathComponent, "widget-snapshot.json")
        try store.write(sample(lockScreen: true))
        XCTAssertEqual(store.read(), sample(lockScreen: true))
        #if os(iOS)
        let protection = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.protectionKey] as? FileProtectionType
        XCTAssertEqual(protection, .completeUntilFirstUserAuthentication, "readable by the widget while locked")
        #endif
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["widget-snapshot.json"], "the overwrite leaves no temporary file")

        let memory = InMemoryWidgetSnapshotStore()
        try memory.write(sample())
        XCTAssertEqual(memory.read(), sample())
    }

    func testClearRemovesTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWidgetSnapshotStore(directory: directory)
        try store.clear()
        try store.write(sample())
        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertNil(store.read())

        let memory = InMemoryWidgetSnapshotStore(sample())
        try memory.clear()
        XCTAssertNil(memory.read())
    }

    func testDemoAndSignOutClearTheSnapshot() {
        XCTAssertTrue(WidgetSnapshotPolicy.shouldClear(isDemo: true, viewerBound: true))
        XCTAssertTrue(WidgetSnapshotPolicy.shouldClear(isDemo: true, viewerBound: false))
        XCTAssertTrue(WidgetSnapshotPolicy.shouldClear(isDemo: false, viewerBound: false))
        XCTAssertFalse(WidgetSnapshotPolicy.shouldClear(isDemo: false, viewerBound: true))
    }

    // MARK: Link

    func testWidgetLinkRoundTrip() {
        XCTAssertEqual(WidgetLink.url(for: .home).absoluteString, "mango://home")
        XCTAssertEqual(WidgetLink.url(for: .month).absoluteString, "mango://month")
        for tab in PhoneTabLink.allCases {
            XCTAssertEqual(WidgetLink.tab(from: WidgetLink.url(for: tab)), tab)
        }
    }

    func testUnknownURLIsNil() {
        for string in ["mango://accounts", "https://home", "mango://", "other://month", "mango://home/extra"] {
            XCTAssertNil(WidgetLink.tab(from: URL(string: string)!), string)
        }
    }
}
