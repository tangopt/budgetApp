// App/AppEnvironment.swift
import Foundation
import BudgetCore
import GRDB

@MainActor
final class AppEnvironment: ObservableObject {
    let dbQueue: DatabaseQueue
    /// Set once, right after launch, only if the fetched rate actually differs from the
    /// last saved one at 2 decimal places. `NetWorthView` displays and dismisses it.
    @Published var exchangeRateBanner: String?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Budget", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("budget.sqlite").path

        let manager = try! DatabaseManager(path: dbPath)
        try! manager.migrate()
        try! manager.dbQueue.write { db in
            try CategorySeeder.seedDefaults(db)
        }
        self.dbQueue = manager.dbQueue

        Task { [weak self] in
            await self?.refreshExchangeRate()
        }
    }

    /// Never blocks launch (it's kicked off from `init` as a detached `Task`) and never
    /// throws outward — any failure (offline, bad response) just leaves the last saved
    /// rate in place, silently, exactly as if this never ran.
    private func refreshExchangeRate() async {
        let source = FrankfurterExchangeRateSource()
        guard let fetchedRate = await source.fetchEURToGBPRate() else { return }
        do {
            let (previousRate, accounts, snapshots, transactions) = try await dbQueue.read { db -> (ExchangeRateSetting, [Account], [BalanceSnapshot], [Transaction]) in
                (try ExchangeRateSetting.currentOrDefault(db: db), try Account.fetchAll(db), try BalanceSnapshot.fetchAll(db), try Transaction.fetchAll(db))
            }
            guard ExchangeRateFetcher.hasChanged(fetchedRate: fetchedRate, previousRate: previousRate.eurToGbpRate) else { return }

            let newRate = ExchangeRateSetting(eurToGbpRate: fetchedRate, updatedAt: Date())
            let impact = ExchangeRateFetcher.netWorthImpact(accounts: accounts, snapshots: snapshots, transactions: transactions, oldRate: previousRate, newRate: newRate)

            try await dbQueue.write { db in
                var setting = newRate
                try setting.insert(db)
            }

            let sign = impact >= 0 ? "+" : ""
            exchangeRateBanner = "EUR rate updated to \(String(format: "%.2f", fetchedRate)) (was \(String(format: "%.2f", previousRate.eurToGbpRate))) — net worth changed by \(sign)\(Money.format(impact, currency: .gbp))."
        } catch {
            // Swallowed on purpose — same "fall back silently" contract as a failed fetch.
        }
    }
}
