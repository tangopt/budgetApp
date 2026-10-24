import Foundation
import GRDB

public final class DatabaseManager {
    public let dbQueue: DatabaseQueue

    public init(path: String?) throws {
        var configuration = Configuration()
        // A row that `REPLACE` removes fires delete triggers (sync tombstones) only with this on.
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA recursive_triggers = ON") }
        if let path {
            dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        } else {
            dbQueue = try DatabaseQueue(configuration: configuration)
        }
    }

    /// Tests only: runs migrations up to and including `target`.
    func migrate(upTo target: String) throws {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        try migrator.migrate(dbQueue, upTo: target)
        try refreshSyncTriggers()
    }

    public func migrate() throws {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        try migrator.migrate(dbQueue)
        try refreshSyncTriggers()
    }

    /// The sync change-tracking triggers, matched to `SyncSchema` after every migration (so a column a
    /// later migration adds is tracked), once the sync tables exist.
    private func refreshSyncTriggers() throws {
        try dbQueue.write { db in
            guard try db.tableExists("syncPending") else { return }
            try SyncChangeTracker.refreshSyncTriggers(db: db)
            // Records staged by an older build (an unknown record type, say) get another chance: on the next pull,
            // through the filed-year check (sync spec §5.4), never applied unchecked here.
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncStaging") ?? 0 > 0 {
                try SyncEngineCore.requestStagedRetry(db: db)
            }
        }
    }

    /// The migrations this build has that the database hasn't run yet, and those the database
    /// ran that this build doesn't know (a newer build wrote it). A one-off tool's real run
    /// wants both empty: the installed app already migrated the database at this version.
    public func migrationStatus() throws -> (pending: [String], unknown: [String]) {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        let applied = try dbQueue.read { db in try migrator.appliedIdentifiers(db) }
        let known = migrator.migrations
        return (known.filter { !applied.contains($0) }, applied.filter { !known.contains($0) }.sorted())
    }

    /// Whether this build has migrations the database hasn't run yet.
    public func hasPendingMigrations() throws -> Bool {
        try !migrationStatus().pending.isEmpty
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
        registerScenarioMigration(&migrator)
        registerImportProfileNegateAmountsMigration(&migrator)
        registerTransactionNoteMigration(&migrator)
        registerTransferLinkMigration(&migrator)
        registerCategoryExternalTransferMigration(&migrator)
        registerAccountDetailsMigration(&migrator)
        registerAccountSortOrderMigration(&migrator)
        registerCategoryIconMigration(&migrator)
        registerTransactionIsManualMigration(&migrator)
        registerCategoryBuiltInRoleMigration(&migrator)
        registerAccountStatementMismatchMigration(&migrator)
        registerBalanceSnapshotArchiveMigration(&migrator)
        registerAccountBalanceConfirmedAtMigration(&migrator)
        registerCategoryTransferAccountMigration(&migrator)
        registerImportProfileFeeStatusColumnsMigration(&migrator)
        registerAccountBankRegionMigration(&migrator)
        registerImportProfileAccountColumnsMigration(&migrator)
        registerForecastEntryAccountMigration(&migrator)
        registerAccountIsMainMigration(&migrator)
        registerCategoryGroupTypeMigration(&migrator)
        registerAccountIncludeInNetWorthMigration(&migrator)
        registerEvidenceLibraryMigration(&migrator)
        registerEvidenceSourceFilesMigration(&migrator)
        registerEvidenceRequirementMigration(&migrator)
        registerPropertyMigration(&migrator)
        registerRentReceiptPaymentMigration(&migrator)
        registerPropertyEvidenceRequirementMigration(&migrator)
        registerTaxMigration(&migrator)
        registerPersonalIncomeMigration(&migrator)
        registerRechargeMigration(&migrator)
        registerUtilityInvoiceRulesMigration(&migrator)
        registerRechargeEmailMigration(&migrator)
        registerTaxPolicyReceiptMigration(&migrator)
        registerForeignTaxApportionedMigration(&migrator)
        registerPropertyMortgageTermsMigration(&migrator)
        registerRechargeLineKindMigration(&migrator)
        registerInterestIndexAndMortgageRulesMigration(&migrator)
        registerMortgageAmountBorrowedMigration(&migrator)
        registerRentCreditEvidenceMigration(&migrator)
        registerTaxNotClaimedMigration(&migrator)
        registerTaxYearForeignTaxInPenceMigration(&migrator)
        registerTaxAttributionRuleWindowShiftMigration(&migrator)
        // Registered with the other tax migrations (before the app-user and sync ones), so a
        // database migrated up to those has the table too; an already migrated database runs
        // it as the one migration it lacks.
        registerTaxFiledBoxMigration(&migrator)
        registerTaxPolicyReceiptItemsMigration(&migrator)
        // Like the filed boxes: before the app-user and sync ones (2026-10-24).
        registerPropertyCheckDecisionMigration(&migrator)
        registerImportRunMigration(&migrator)
        registerImportRuleMigration(&migrator)
        registerAppUserMigration(&migrator)
        registerSyncMigration(&migrator)
    }
}
