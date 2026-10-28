// App/Documents/MissingDocumentsViewModel.swift
import Foundation
import BudgetCore
import GRDB
import SwiftUI

/// The Missing documents centre (step 20): `MissingDocuments.read` kept current by observing the database while the
/// page shows, with the page's filters. Owned by ContentView, so the filters last while the app runs and the sidebar
/// badge counts without the page open.
@MainActor
final class MissingDocumentsViewModel: ObservableObject {
    /// The year filter: a UK tax year or a calendar year.
    enum YearChoice: Hashable {
        case any
        case taxYear(Int)
        case calendarYear(Int)
    }

    let dbQueue: DatabaseQueue
    @Published private(set) var result = MissingDocuments.Result(rows: [])
    @Published private(set) var sites: [SavedSite] = []
    @Published private(set) var isLoading = true
    @Published var area: MissingDocumentArea?
    @Published var year: YearChoice = .any
    @Published var timing: MissingDocumentFilter.Timing = .any
    @Published var queryText = ""
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?
    private var holders: Set<String> = []

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    var filter: MissingDocumentFilter {
        var filter = MissingDocumentFilter(area: area, timing: timing, text: queryText)
        switch year {
        case .any: break
        case .taxYear(let value): filter.taxYear = value
        case .calendarYear(let value): filter.calendarYear = value
        }
        return filter
    }

    /// The rows shown, in order.
    var shown: [MissingDocumentRow] { MissingDocuments.missing(result.rows, filter: filter, now: AppClock.now) }
    var notExpected: [MissingDocumentRow] { MissingDocuments.notExpected(result.rows, filter: .init(), now: AppClock.now) }
    var taxYears: [Int] { MissingDocuments.taxYears(result.rows) }
    var calendarYears: [Int] { MissingDocuments.calendarYears(result.rows) }
    func shown(in area: MissingDocumentArea) -> [MissingDocumentRow] { shown.filter { $0.area == area } }

    // MARK: Observing

    /// `holder` (the page, or the sidebar's badge) needs the live rows.
    func claim(_ holder: String) {
        holders.insert(holder)
        guard task == nil else { return }
        let values = ValueObservation
            .tracking { db -> Snapshot in
                Snapshot(result: try MissingDocuments.read(db: db, now: AppClock.now, earliest: try Self.earliest(db: db)),
                         sites: (try? GRDBSavedSiteStore.read(db: db)) ?? [])
            }
            .removeDuplicates()
            .values(in: dbQueue)
        task = Task { [weak self] in
            do {
                for try await snapshot in values {
                    guard let self, !Task.isCancelled else { return }
                    self.result = snapshot.result
                    self.sites = snapshot.sites
                    self.isLoading = false
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = "Couldn't read the missing documents: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    func release(_ holder: String) {
        holders.remove(holder)
        guard holders.isEmpty else { return }
        task?.cancel()
        task = nil
    }

    private struct Snapshot: Equatable, Sendable {
        var result: MissingDocuments.Result
        var sites: [SavedSite]
    }

    /// The first tax year read: 2023/24, or earlier when the transactions start earlier (as the per-year checklist offers).
    nonisolated private static func earliest(db: Database) throws -> UKTaxYear {
        let first = try Date.fetchOne(db, sql: "SELECT MIN(date) FROM transaction_")
        return min(UKTaxYear(startYear: 2023), first.map(UKTaxYear.containing) ?? UKTaxYear(startYear: 2023))
    }

    // MARK: Not expected

    /// Marks the row not expected (its waiver), off the main thread; `done` gets the refusal's text.
    func markNotExpected(_ row: MissingDocumentRow, reason: EvidenceWaiverReason, note: String?, done: @escaping (String?) -> Void) {
        let dbQueue = dbQueue
        Task {
            do {
                _ = try await dbQueue.write(.property) { db in try MissingDocuments.markNotExpected(db: db, row: row, reason: reason, note: note) }
                done(nil)
            } catch {
                done(error.localizedDescription)
            }
        }
    }

    /// Puts the row back among the missing ones.
    func restore(_ row: MissingDocumentRow) {
        let dbQueue = dbQueue
        Task {
            do {
                _ = try await dbQueue.write(.property) { db in try MissingDocuments.restore(db: db, row: row) }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
