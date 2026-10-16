// App/AppEnvironment.swift
import Foundation
import BudgetCore
import GRDB
import OSLog

@MainActor
final class AppEnvironment: ObservableObject {
    let dbQueue: DatabaseQueue
    /// Where the evidence library keeps its copies: beside the database.
    let evidenceRoot: URL
    /// Set once, right after launch, only if the fetched rate actually differs from the
    /// last saved one at 2 decimal places. `AccountsView` displays and dismisses it.
    @Published var exchangeRateBanner: String?

    private init(dbQueue: DatabaseQueue, evidenceRoot: URL) {
        self.dbQueue = dbQueue
        self.evidenceRoot = evidenceRoot

        Task { [weak self] in
            await self?.refreshExchangeRate()
        }
    }

    /// Opens, migrates and seeds the database off the main thread so the window can show
    /// `LaunchView` straight away instead of blocking launch. Throws on any setup failure;
    /// `LaunchView` shows the error instead of crashing.
    static func load() async throws -> AppEnvironment {
        let (dbQueue, dbPath) = try await Task.detached(priority: .userInitiated) {
            let dbPath: String
            if let override = ProcessInfo.processInfo.environment["BUDGET_DB_PATH"], !override.isEmpty {
                // Lets the app run against a copy of the database for safe manual testing.
                dbPath = override
            } else {
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Budget", isDirectory: true)
                try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
                dbPath = appSupport.appendingPathComponent("budget.sqlite").path
            }

            let manager = try DatabaseManager(path: dbPath)
            try manager.migrate()
            try manager.dbQueue.write { db in
                try CategorySeeder.seedDefaults(db)
            }
            // Gives every account its transfer category (spec 2026-10-14 §4), then links
            // transfers between accounts already imported, filing their legs under those
            // (idempotent; spec §6). A failure only leaves them as they were until the next
            // import or launch — never blocks launch.
            do {
                _ = try manager.dbQueue.write { db in
                    try TransferCategories.ensure(db: db)
                    return try TransferMatcher.match(db: db)
                }
            } catch {
                Logger(subsystem: "com.personal.budget", category: "Transfers").error("Transfer matching at launch failed: \(error.localizedDescription, privacy: .public)")
            }
            return (manager.dbQueue, dbPath)
        }.value
        // `Evidence` next to the database: `Application Support/Budget/Evidence` normally, and
        // beside a `BUDGET_DB_PATH` copy when testing against one.
        let evidenceRoot = URL(fileURLWithPath: dbPath).deletingLastPathComponent().appendingPathComponent("Evidence", isDirectory: true)
        let environment = AppEnvironment(dbQueue: dbQueue, evidenceRoot: evidenceRoot)
        AppEnvironment.Current.shared.environment = environment
        // Every transaction's paperclip count, kept current from here on.
        TransactionDocumentCounts.shared.start(dbQueue: dbQueue)
        return environment
    }

    /// The most recently loaded environment, for scenes without a main window of their own
    /// (Settings ▸ Evidence). `nil` until the main window has opened the database.
    final class Current: ObservableObject {
        static let shared = Current()
        @Published var environment: AppEnvironment?
    }

    /// The evidence library next to the database (`Application Support/Budget/Evidence`).
    var evidenceLibrary: EvidenceLibrary {
        EvidenceLibrary(root: evidenceRoot, database: dbQueue)
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
