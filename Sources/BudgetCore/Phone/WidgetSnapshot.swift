import Foundation
import GRDB

/// The App Group the iPhone app and its widget share: the snapshot's folder and the output settings' suite.
public enum PhoneAppGroup {
    public static let identifier = "group.ubberninja.mango"
}

/// What the widget shows, written by the app for the device's viewer (`PhoneViewer`): Home's own net worth, left to
/// spend and payday, nothing else (no account, name or balance), so a widget never holds what the viewer can't see.
/// Nothing here computes a figure: `make` is the call Home makes.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// The format; a widget ignores a snapshot it doesn't know.
    public var version: Int
    public var generatedAt: Date
    /// Home's net worth for the viewer; nil without balances.
    public var netWorthMinorUnits: Int?
    public var currencyCode: String
    /// Home's "left to spend" this pay month (positive).
    public var leftToSpendMinorUnits: Int
    /// The current pay month's close day.
    public var paydayDate: Date
    /// The figures show on the lock screen only when turned on in Settings.
    public var showFiguresOnLockScreen: Bool

    public static let currentVersion = 1

    public init(version: Int = WidgetSnapshot.currentVersion, generatedAt: Date, netWorthMinorUnits: Int?, currencyCode: String = "GBP",
                leftToSpendMinorUnits: Int, paydayDate: Date, showFiguresOnLockScreen: Bool) {
        self.version = version
        self.generatedAt = generatedAt
        self.netWorthMinorUnits = netWorthMinorUnits
        self.currencyCode = currencyCode
        self.leftToSpendMinorUnits = leftToSpendMinorUnits
        self.paydayDate = paydayDate
        self.showFiguresOnLockScreen = showFiguresOnLockScreen
    }

    /// The snapshot on `today` for `viewer`: `DashboardInput.load` with the viewer's actuals, then `HomeSummary.make`,
    /// as Home reads it. Nil when Home would show its empty state (nothing synced yet): the writer clears the snapshot.
    public static func make(db: Database, viewer: PhoneViewer, today: Date, settings: PhoneOutputSettings) throws -> WidgetSnapshot? {
        let input = try DashboardInput.load(db: db, today: today, actuals: try viewer.actuals(db: db, today: today))
        guard !input.isEmpty else { return nil }
        let home = try HomeSummary.make(input, db: db)
        return WidgetSnapshot(generatedAt: today, netWorthMinorUnits: home.netWorth.currentNetWorthMinorUnits,
                              leftToSpendMinorUnits: home.leftToSpendMinorUnits, paydayDate: home.paydayDate,
                              showFiguresOnLockScreen: settings.showFiguresOnLockScreen)
    }

    /// Days from `day` to payday (0 on and after it), so the widget counts down by itself between refreshes.
    public func daysToPayday(on day: Date) -> Int {
        let calendar = MonthRange.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: paydayDate)).day ?? 0
        return max(0, days)
    }
}

/// When the widget's snapshot goes: demo data shows (made-up figures never reach the widget), or no iCloud user is
/// bound to this device (signed out, changed, or removed from the household).
public enum WidgetSnapshotPolicy {
    public static func shouldClear(isDemo: Bool, viewerBound: Bool) -> Bool {
        isDemo || !viewerBound
    }
}

/// Where the snapshot is kept: the App Group's folder in the app (`FileWidgetSnapshotStore`), memory in tests.
public protocol WidgetSnapshotStore: Sendable {
    func write(_ snapshot: WidgetSnapshot) throws
    func read() -> WidgetSnapshot?
    func clear() throws
}

/// The snapshot as `widget-snapshot.json` in `directory` (the App Group container), replaced atomically, so the
/// widget never reads half a file.
public struct FileWidgetSnapshotStore: WidgetSnapshotStore {
    public static let fileName = "widget-snapshot.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Readable while the device is locked (a lock-screen widget), once it has been unlocked since boot.
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The stored snapshot; nil when there is none, it is unreadable, or of a version this build doesn't know.
    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// The snapshot in memory (tests).
public final class InMemoryWidgetSnapshotStore: WidgetSnapshotStore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: WidgetSnapshot?

    public init(_ snapshot: WidgetSnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        lock.withLock { self.snapshot = snapshot }
    }

    public func read() -> WidgetSnapshot? {
        lock.withLock { snapshot }
    }

    public func clear() throws {
        lock.withLock { snapshot = nil }
    }
}

/// The app screens a widget opens.
public enum PhoneTabLink: String, CaseIterable, Sendable {
    case home, month
}

/// The widget's link into the app: `mango://home`, `mango://month`.
public enum WidgetLink {
    public static let scheme = "mango"

    public static func url(for tab: PhoneTabLink) -> URL {
        URL(string: "\(scheme)://\(tab.rawValue)")!
    }

    /// The tab a link opens; nil for any other URL.
    public static func tab(from url: URL) -> PhoneTabLink? {
        guard url.scheme?.lowercased() == scheme, let host = url.host()?.lowercased(),
              url.path().isEmpty || url.path() == "/" else { return nil }
        return PhoneTabLink(rawValue: host)
    }
}
