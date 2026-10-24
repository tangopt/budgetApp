import Foundation
import GRDB
import OSLog

/// The phone's shared state: its database and its clock. It mirrors the Mac's `AppEnvironment.load` minus every
/// writer and every hub job (plan step 4 Global Constraints): no `CategorySeeder`, `TransferCategories.ensure`,
/// `TransferMatcher`, `AutoForecastGenerator`, exchange-rate, HMRC or Euribor fetch. The Mac is the hub; the
/// phone only reads what sync brings.
@MainActor
final class PhoneEnvironment: ObservableObject {
    let dbQueue: DatabaseQueue
    let databasePath: String
    /// Today as the app sees it (the snapshot harness fixes it later).
    let today: () -> Date

    private init(dbQueue: DatabaseQueue, databasePath: String, today: @escaping () -> Date) {
        self.dbQueue = dbQueue
        self.databasePath = databasePath
        self.today = today
    }

    /// Opens and migrates the database off the main thread. Throws on any setup failure; the root view shows it.
    static func load() async throws -> PhoneEnvironment {
        Logger(subsystem: "ubberninja.mango.ios", category: "Launch").info("Loading the phone environment")
        let (dbQueue, path) = try await Task.detached(priority: .userInitiated) {
            let path = try PhoneDatabase.path()
            let queue = try PhoneDatabase.open(at: path)
            return (queue, path)
        }.value
        return PhoneEnvironment(dbQueue: dbQueue, databasePath: path, today: { Date() })
    }
}
