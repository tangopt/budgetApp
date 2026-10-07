import Foundation
import GRDB

public final class DatabaseManager {
    public let dbQueue: DatabaseQueue

    public init(path: String?) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
    }

    /// Tests only: runs migrations up to and including `target`.
    func migrate(upTo target: String) throws {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        try migrator.migrate(dbQueue, upTo: target)
    }

    public func migrate() throws {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        try migrator.migrate(dbQueue)
    }

    /// Individual model files append their own migration in an extension
    /// on this function via `registerMigrations(_:)` overloads is not
    /// possible in Swift, so each model file defines a free function
    /// `register<Model>Migration(_ migrator: inout DatabaseMigrator)`
    /// and this function calls them all in order.
    private func registerMigrations(_ migrator: inout DatabaseMigrator) {
        registerCategoryMigration(&migrator)
        registerCategoryGroupMigration(&migrator)
        registerCategoryGroupIdMigration(&migrator)
        registerCategoryCatchAllMigration(&migrator)
        registerAccountMigration(&migrator)
        registerImportProfileMigration(&migrator)
        registerImportProfileCreditColumnMigration(&migrator)
        registerImportProfileBalanceColumnMigration(&migrator)
        registerImportBatchMigration(&migrator)
        registerTransactionMigration(&migrator)
        registerRuleMigration(&migrator)
        registerPayPeriodMigration(&migrator)
        registerForecastGroupMigration(&migrator)
        registerForecastEntryMigration(&migrator)
        registerBalanceSnapshotMigration(&migrator)
        registerExchangeRateSettingMigration(&migrator)
        registerCategoryReservedMigration(&migrator)
        registerCategoryDropCatchAllMigration(&migrator)
        registerPayMonthCloseMigration(&migrator)
        registerPlannedOccurrenceExceptionMigration(&migrator)
        registerForecastEntryAnchorDayMigration(&migrator)
    }
}
