import Foundation
import GRDB
import OSLog
import BudgetCore

/// The phone's shared state: its database and its clock. It mirrors the Mac's `AppEnvironment.load` minus every
/// writer and every hub job (plan step 4 Global Constraints): no `CategorySeeder`, `TransferCategories.ensure`,
/// `TransferMatcher`, `AutoForecastGenerator`, exchange-rate, HMRC or Euribor fetch. The Mac is the hub; the
/// phone only reads what sync brings.
@MainActor
final class PhoneEnvironment: ObservableObject {
    let dbQueue: DatabaseQueue
    let databasePath: String
    /// Today as the app sees it (the snapshot harness fixes it later; demo data fixes it to the demo's day).
    let today: () -> Date
    /// The demo database ("Try with demo data", `PhoneDemoData`), not the household's.
    let isDemo: Bool
    /// Whether the database holds the household's data (`PhoneDemoMode.hasRealData`); false for demo data.
    let hasRealData: Bool

    private init(dbQueue: DatabaseQueue, databasePath: String, today: @escaping () -> Date, isDemo: Bool, hasRealData: Bool) {
        self.dbQueue = dbQueue
        self.databasePath = databasePath
        self.today = today
        self.isDemo = isDemo
        self.hasRealData = hasRealData
    }

    /// Opens and migrates the database off the main thread. Throws on any setup failure; the root view shows it.
    static func load() async throws -> PhoneEnvironment {
        Logger(subsystem: "ubberninja.mango.ios", category: "Launch").info("Loading the phone environment")
        let (dbQueue, path, hasRealData) = try await Task.detached(priority: .userInitiated) {
            let location = try PhoneDatabase.location()
            let queue = try PhoneDatabase.open(location)
            // Unreadable: counted as real data, so nothing offers to cover it with the demo.
            let real = (try? queue.read { db in try PhoneDemoMode.hasRealData(db: db) }) ?? true
            return (queue, location.path, real)
        }.value
        return PhoneEnvironment(dbQueue: dbQueue, databasePath: path, today: { Date() }, isDemo: false, hasRealData: hasRealData)
    }

    /// The demo database (`PhoneDemoData`), built if needed and opened read-only, off the main thread.
    static func loadDemo() async throws -> PhoneEnvironment {
        Logger(subsystem: "ubberninja.mango.ios", category: "Launch").info("Loading the demo data")
        let (dbQueue, path) = try await Task.detached(priority: .userInitiated) { try PhoneDemoData.open() }.value
        let today = PhoneDemoData.today
        return PhoneEnvironment(dbQueue: dbQueue, databasePath: path, today: { today }, isDemo: true, hasRealData: false)
    }
}
