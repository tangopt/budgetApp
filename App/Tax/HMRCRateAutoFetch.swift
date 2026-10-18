// App/Tax/HMRCRateAutoFetch.swift
import Foundation
import BudgetCore
import GRDB
import OSLog

/// Fetches HMRC's average rates the ended tax years are missing (`HMRCRates.fetchMissing`),
/// in the background: after launch, and when the Tax years screen first appears. One run at a
/// time; each year is asked for at most once a day (the attempts are kept in `UserDefaults`).
/// Failures are quiet — the year page keeps its "No HMRC EUR rate" warning and its manual
/// Fetch and override until a later run gets the rate.
@MainActor
final class HMRCRateAutoFetch {
    private let dbQueue: DatabaseQueue
    private let fetcher: HMRCRateFetching
    private let log: HMRCRateFetchLog
    private var running: Task<Void, Never>?

    init(dbQueue: DatabaseQueue, fetcher: HMRCRateFetching = HMRCTradeTariffRateFetcher(),
         log: HMRCRateFetchLog = HMRCRateFetchDefaultsLog()) {
        self.dbQueue = dbQueue
        self.fetcher = fetcher
        self.log = log
    }

    /// Starts a run unless one is under way. The rates stored show through the screens'
    /// database observation (the year page notes a rate fetched automatically).
    func run() {
        guard running == nil else { return }
        let dbQueue = dbQueue, fetcher = fetcher, log = log
        running = Task.detached(priority: .utility) { [weak self] in
            do {
                let outcome = try await HMRCRates.fetchMissing(db: dbQueue, today: Date(), fetcher: fetcher, log: log)
                if !outcome.fetched.isEmpty {
                    let stored = outcome.fetched.map { "\(UKTaxYear(startYear: $0.startYear).label) \($0.currencyCode)" }.joined(separator: ", ")
                    Logger(subsystem: "com.personal.budget", category: "HMRCRates").info("Fetched HMRC average rates: \(stored, privacy: .public)")
                }
            } catch {
                Logger(subsystem: "com.personal.budget", category: "HMRCRates").error("HMRC rate fetch failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run { self?.running = nil }
        }
    }
}
