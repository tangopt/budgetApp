// App/Property/InterestIndexAutoFetch.swift
import Foundation
import BudgetCore
import GRDB
import OSLog

/// Fetches the Euribor monthly averages the mortgages follow (`InterestIndexValues.fetchInUse`,
/// from the ECB Data Portal) in the background: after launch, and whenever a property page
/// opens. One run at a time; each index is asked for at most once a day (the attempts are kept
/// in `UserDefaults`); a manual value is never replaced. Failures are quiet — the rate keeps
/// the fixings stored until a later run gets the new month.
@MainActor
final class InterestIndexAutoFetch {
    private let dbQueue: DatabaseQueue
    private let fetcher: InterestIndexFetching
    private let log: InterestIndexFetchLog
    private var running: Task<Void, Never>?

    init(dbQueue: DatabaseQueue, fetcher: InterestIndexFetching = ECBEuriborFetcher(),
         log: InterestIndexFetchLog = InterestIndexFetchDefaultsLog()) {
        self.dbQueue = dbQueue
        self.fetcher = fetcher
        self.log = log
    }

    /// Starts a run unless one is under way. What it stores shows through the property page's
    /// database observation.
    func run() {
        // The snapshot harness never touches the network.
        guard running == nil, !SnapshotMode.isActive else { return }
        let dbQueue = dbQueue, fetcher = fetcher, log = log
        running = Task.detached(priority: .utility) { [weak self] in
            do {
                let outcome = try await InterestIndexValues.fetchInUse(db: dbQueue, today: AppClock.now, fetcher: fetcher, log: log)
                let stored = outcome.stored.filter { $0.value > 0 }.map { "\($0.key.displayName): \($0.value)" }.sorted().joined(separator: ", ")
                if !stored.isEmpty {
                    Logger(subsystem: "com.personal.budget", category: "Euribor").info("Stored Euribor months: \(stored, privacy: .public)")
                }
            } catch {
                Logger(subsystem: "com.personal.budget", category: "Euribor").error("Euribor fetch failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run { self?.running = nil }
        }
    }
}
