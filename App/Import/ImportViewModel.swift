// App/Import/ImportViewModel.swift
import Foundation
import BudgetCore
import GRDB

struct ReviewRow: Identifiable {
    let staged: StagedTransaction
    var chosenCategoryId: Int64?
    var id: UUID { staged.id }
}

@MainActor
final class ImportViewModel: ObservableObject {
    @Published var stagedRows: [ReviewRow] = []
    /// Rows skipped as already imported — shown in a dismissible, expandable list and
    /// force-importable (spec: Error handling).
    @Published var duplicates: [ParsedTransaction] = []
    /// Statement lines that couldn't be parsed — shown as "couldn't auto-parse".
    @Published var unparsedLines: [String] = []
    /// True from a successful staging until commit/cancel, even if every row turned out
    /// to be a duplicate or unparsable (so those lists are still shown to the user).
    @Published var isReviewing = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    /// True while a CSV/PDF staging run is in flight (the on-device categorizer makes a
    /// real model call per unmatched row, so this can take a while). Guards the staging
    /// entry points against a second concurrent run, e.g. from a double-click.
    @Published private(set) var isStaging = false
    /// (categorized, total) for the categorization batch currently in flight — `nil`
    /// before the first batch reports in (e.g. during the initial parse/duplicate lookup)
    /// and reset to `nil` whenever a new staging run starts or the current one ends.
    @Published private(set) var stagingProgress: (current: Int, total: Int)?
    /// Verified Balance-column result for the file under review. `.notProvided` for PDFs,
    /// credit-card accounts, and files without a mapped Balance column.
    @Published private(set) var statementBalances: StatementBalanceResult = .notProvided
    /// When on, the statement balances are recorded once, on the first successful commit.
    @Published var recordStatementBalancesOnConfirm = true
    /// Set once the balances for the current review have been recorded.
    @Published private(set) var statementBalancesRecorded: StatementBalanceRecording?

    private let dbQueue: DatabaseQueue
    private let coordinator: ImportCoordinator
    private let profileStore: ImportProfileStore
    private var lastSourceFileName: String = ""
    private var lastAccountId: Int64 = 0
    private var lastAccountCurrency: Currency = .gbp

    private static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    init(dbQueue: DatabaseQueue, coordinator: ImportCoordinator, profileStore: ImportProfileStore) {
        self.dbQueue = dbQueue
        self.coordinator = coordinator
        self.profileStore = profileStore
    }

    var duplicateCount: Int { duplicates.count }

    func fail(_ message: String) {
        errorMessage = message
    }

    func stageCSV(fileURL: URL, account: Account) async {
        // Check-and-set happens synchronously on the main actor before any `await`, so
        // two calls can't both get past this guard.
        guard !isStaging else { return }
        isStaging = true
        stagingProgress = nil
        defer { isStaging = false; stagingProgress = nil }
        errorMessage = nil
        statusMessage = nil
        do {
            guard let accountId = account.id else { return fail("This account hasn't been saved yet.") }
            let csvText = try Self.readText(at: fileURL)
            guard let profile = try profileStore.find(accountId: accountId, format: .csv) else {
                return fail("No column mapping saved for this account yet. Run the mapping wizard first.")
            }
            let result = try await coordinator.stageCSVImport(csvText: csvText, profile: profile, accountId: accountId, onProgress: makeProgressHandler())
            apply(result, sourceFileName: fileURL.lastPathComponent, account: account)
        } catch {
            fail("Couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Progress callbacks arrive from `ImportCoordinator`, which isn't main-actor-isolated,
    /// so each one hops back via its own `Task` rather than requiring the whole closure
    /// (and its caller) to be main-actor-isolated. Fine at this call frequency — once per
    /// categorization batch, not once per row.
    private func makeProgressHandler() -> @Sendable (Int, Int) -> Void {
        { [weak self] current, total in
            Task { @MainActor in self?.stagingProgress = (current, total) }
        }
    }

    func stagePDF(lines: [String], config: PDFLayoutConfig, account: Account, sourceFileName: String) async {
        guard !isStaging else { return }
        isStaging = true
        stagingProgress = nil
        defer { isStaging = false; stagingProgress = nil }
        errorMessage = nil
        statusMessage = nil
        do {
            guard let accountId = account.id else { return fail("This account hasn't been saved yet.") }
            let result = try await coordinator.stagePDFImport(lines: lines, config: config, accountId: accountId, onProgress: makeProgressHandler())
            apply(result, sourceFileName: sourceFileName, account: account)
        } catch {
            fail("Couldn't stage \(sourceFileName): \(error.localizedDescription)")
        }
    }

    private func apply(_ result: StagedImport, sourceFileName: String, account: Account) {
        lastSourceFileName = sourceFileName
        lastAccountId = account.id ?? 0
        lastAccountCurrency = account.currency
        // Credit-card statements show balances with bank-specific sign conventions, so the
        // feature is off for them (see the spec's non-goals).
        statementBalances = account.kind == .credit ? .notProvided : result.statementBalances
        statementBalancesRecorded = nil
        recordStatementBalancesOnConfirm = true
        stagedRows = result.staged.map { ReviewRow(staged: $0, chosenCategoryId: $0.suggestedCategoryId) }
        duplicates = result.duplicates
        unparsedLines = result.unparsedLines
        isReviewing = true
        if result.staged.isEmpty && result.duplicates.isEmpty && result.unparsedLines.isEmpty {
            isReviewing = false
            fail("No transactions were found in \(sourceFileName).")
        }
    }

    /// Moves every listed duplicate into the review table with a fresh, non-colliding
    /// fingerprint, for a genuine legitimate collision.
    func forceImportDuplicates() async {
        guard !duplicates.isEmpty else { return }
        do {
            let forced = try await coordinator.stageForcedDuplicates(duplicates, accountId: lastAccountId, alreadyStaged: stagedRows.map(\.staged))
            stagedRows += forced.map { ReviewRow(staged: $0, chosenCategoryId: $0.suggestedCategoryId) }
            duplicates = []
        } catch {
            fail("Couldn't stage the duplicates: \(error.localizedDescription)")
        }
    }

    func dismissDuplicates() { duplicates = [] }
    func dismissUnparsedLines() { unparsedLines = [] }

    var readyRows: [ReviewRow] {
        let readyIds = Set(ReviewPartitioning.partition(stagedRows.map(\.staged)).ready.map(\.id))
        return stagedRows.filter { readyIds.contains($0.id) }
    }

    var needsAttentionRows: [ReviewRow] {
        let readyIds = Set(ReviewPartitioning.partition(stagedRows.map(\.staged)).ready.map(\.id))
        return stagedRows.filter { !readyIds.contains($0.id) }
    }

    /// Commits only the "ready" rows, leaving "needs attention" rows still staged for
    /// further review. Each partial confirm creates its own `ImportBatch` row (a minor,
    /// harmless duplication of what used to always be exactly one batch per file — nothing
    /// else in the app depends on "one batch per import").
    @discardableResult
    func confirmReady() -> Bool {
        errorMessage = nil
        let ready = readyRows
        guard !ready.isEmpty else { return true }
        let decisions = ready.map { ImportDecision(stagedId: $0.staged.id, finalCategoryId: $0.chosenCategoryId) }
        do {
            try coordinator.commit(accountId: lastAccountId, sourceFileName: lastSourceFileName, staged: ready.map(\.staged), decisions: decisions)
        } catch {
            fail("Couldn't confirm the ready transactions: \(error.localizedDescription)")
            return false
        }
        let readyIds = Set(ready.map(\.id))
        stagedRows.removeAll { readyIds.contains($0.id) }
        let recordedNote = recordBalancesAfterCommitIfWanted()
        statusMessage = "Confirmed \(ready.count) transaction(s)." + (recordedNote.map { " " + $0 } ?? "")
        if stagedRows.isEmpty && duplicates.isEmpty && unparsedLines.isEmpty { isReviewing = false }
        return true
    }

    /// Commits a single row (used by both the needs-attention section's inline confirm
    /// button and Return-to-confirm-and-advance keyboard handling in Task 7).
    @discardableResult
    func confirmRow(_ row: ReviewRow) -> Bool {
        errorMessage = nil
        let decisions = [ImportDecision(stagedId: row.staged.id, finalCategoryId: row.chosenCategoryId)]
        do {
            try coordinator.commit(accountId: lastAccountId, sourceFileName: lastSourceFileName, staged: [row.staged], decisions: decisions)
        } catch {
            fail("Couldn't confirm this transaction: \(error.localizedDescription)")
            return false
        }
        stagedRows.removeAll { $0.id == row.id }
        _ = recordBalancesAfterCommitIfWanted()
        if stagedRows.isEmpty && duplicates.isEmpty && unparsedLines.isEmpty { isReviewing = false }
        return true
    }

    /// Commits every remaining staged row (whatever categories are or aren't chosen) — the
    /// escape hatch for rows Confirm/Confirm-ready can't reach (no category picked at all).
    /// Rows without a category are saved as Uncategorized (`.pendingReview`) by
    /// `ImportCoordinator.commit`; rows with one keep it. Mirrors the old single-shot
    /// commit()'s behavior, scoped to whatever's left after confirmReady/confirmRow.
    @discardableResult
    func saveRemainingAsUncategorized() -> Bool {
        errorMessage = nil
        let remaining = stagedRows
        guard !remaining.isEmpty else { return true }
        let decisions = remaining.map { ImportDecision(stagedId: $0.staged.id, finalCategoryId: $0.chosenCategoryId) }
        do {
            try coordinator.commit(accountId: lastAccountId, sourceFileName: lastSourceFileName, staged: remaining.map(\.staged), decisions: decisions)
        } catch {
            fail("Couldn't save the remaining transactions: \(error.localizedDescription)")
            return false
        }
        let savedIds = Set(remaining.map(\.id))
        stagedRows.removeAll { savedIds.contains($0.id) }
        let recordedNote = recordBalancesAfterCommitIfWanted()
        statusMessage = "Saved \(remaining.count) transaction(s) — assign categories from Uncategorized." + (recordedNote.map { " " + $0 } ?? "")
        if stagedRows.isEmpty && duplicates.isEmpty && unparsedLines.isEmpty { isReviewing = false }
        return true
    }

    /// "8 balances from the statement, closing £27,596.28 on 29 Sep 2026" — `nil` unless
    /// there is a verified result.
    var statementBalanceSummary: String? {
        guard case .available(let points) = statementBalances, let closing = points.last else { return nil }
        let day = Self.utcDayFormatter.string(from: closing.date)
        let count = points.count == 1 ? "1 balance" : "\(points.count) balances"
        return "\(count) from the statement, closing \(Money.format(closing.balanceMinorUnits, currency: lastAccountCurrency)) on \(day)"
    }

    /// Records the verified balances now (the panel's "Record now" button). A no-op when
    /// there is nothing to record or it was already recorded.
    @discardableResult
    func recordStatementBalancesNow() -> Bool {
        errorMessage = nil
        return recordStatementBalances(failurePrefix: "Couldn't save the statement balances")
    }

    /// Called after every successful commit. Records at most once per review, and only if
    /// the user left the toggle on. Returns a short note for the status line when it
    /// recorded something. A failure here never undoes the commit that already succeeded.
    private func recordBalancesAfterCommitIfWanted() -> String? {
        guard recordStatementBalancesOnConfirm, statementBalancesRecorded == nil, case .available = statementBalances else { return nil }
        guard recordStatementBalances(failurePrefix: "Transactions were confirmed, but the statement balances couldn't be saved"),
              let recorded = statementBalancesRecorded else { return nil }
        return "Recorded \(recorded.added + recorded.updated) balance snapshot(s)."
    }

    private func recordStatementBalances(failurePrefix: String) -> Bool {
        guard statementBalancesRecorded == nil, case .available(let points) = statementBalances else { return true }
        do {
            statementBalancesRecorded = try coordinator.recordStatementBalances(accountId: lastAccountId, sourceFileName: lastSourceFileName, points: points)
            return true
        } catch {
            fail("\(failurePrefix): \(error.localizedDescription)")
            return false
        }
    }

    func cancel() {
        errorMessage = nil
        reset()
    }

    private func reset() {
        stagedRows = []
        duplicates = []
        unparsedLines = []
        isReviewing = false
        statementBalances = .notProvided
        statementBalancesRecorded = nil
    }

    /// Reads a user-picked file, honouring security-scoped access if the app is ever
    /// sandboxed (a no-op otherwise).
    static func readText(at url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
