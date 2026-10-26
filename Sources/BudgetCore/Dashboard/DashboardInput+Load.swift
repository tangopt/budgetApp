import Foundation
import GRDB

extension DashboardInput {
    /// The dashboard's one batched read: everything `DashboardCalculator` needs, as the Mac's
    /// Dashboard and the iPhone's Home load it (the local ledger's actuals, the budget plan,
    /// manual pay-month closes and transfer links). `actuals` gives the transactions and balance snapshots: the
    /// local ledger's, or the viewer's with summaries for the accounts they can't see in full and without the other
    /// person's Hidden ones (`SharedActualsSource`).
    public static func load(db: Database, today: Date, actuals: any ActualsSource = .local) throws -> DashboardInput {
        DashboardInput(
            today: today,
            accounts: try actuals.accounts(db),
            snapshots: try actuals.balanceSnapshots(db),
            transactions: try actuals.transactions(db),
            categories: try Category.fetchAll(db),
            categoryGroups: try CategoryGroup.fetchAll(db),
            forecastEntries: try ForecastEntry.budget(db),
            forecastGroups: try ForecastGroup.fetchAll(db),
            exceptions: try PlannedOccurrenceException.fetchAll(db),
            importBatches: try ImportBatch.fetchAll(db),
            rate: try ExchangeRateSetting.currentOrDefault(db: db),
            manualCloses: try PayMonthClose.fetchAll(db),
            transferLinks: try TransferLink.fetchAll(db),
            publishedCloses: try actuals.publishedCloses(db)
        )
    }
}
