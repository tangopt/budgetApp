// App/Import/ImportViewModel.swift
import Foundation
import BudgetCore
import GRDB
import os

struct ReviewRow: Identifiable {
    let staged: StagedTransaction
    var chosenCategoryId: Int64?
    /// "Remember for <key>": whether a changed category also learns a rule on commit.
    /// `nil` until the category is set or the toggle is touched (spec §4).
    var learnRule: Bool?
    var id: UUID { staged.id }

    var decision: ImportDecision {
        ImportDecision(stagedId: staged.id, finalCategoryId: chosenCategoryId, learnRule: learnRule ?? false)
    }
}

typealias ReviewItemId = ReviewSelectionId<UUID>

/// The review list's sections, grouped by merchant key. Confirmed rows sit in their own
/// section until Finish import saves them.
struct ReviewSections {
    let needsAttention: [ReviewGroup<ReviewRow>]
    let ready: [ReviewGroup<ReviewRow>]
    let confirmed: [ReviewGroup<ReviewRow>]

    /// The unconfirmed sections — the ones whose lines can be selected and categorised.
    var all: [ReviewGroup<ReviewRow>] { needsAttention + ready }
    var needsAttentionCount: Int { needsAttention.reduce(0) { $0 + $1.rows.count } }
    var readyCount: Int { ready.reduce(0) { $0 + $1.rows.count } }
    var confirmedCount: Int { confirmed.reduce(0) { $0 + $1.rows.count } }
}

@MainActor
final class ImportViewModel: ObservableObject {
    @Published var stagedRows: [ReviewRow] = []
    /// Rows skipped as already imported — shown in a dismissible, expandable list and
    /// force-importable (spec: Error handling).
    @Published var duplicates: [ParsedTransaction] = []
    /// Statement lines that couldn't be parsed — shown as "couldn't auto-parse".
    @Published var unparsedLines: [String] = []
    /// Rows the user confirmed on the Review screen. Confirming only marks a row here;
    /// nothing is written until Finish import commits the whole review at once.
    @Published private(set) var confirmedIds: Set<UUID> = []
    /// True from a successful staging until Finish import/cancel, even if every row turned
    /// out to be a duplicate or unparsable (so those lists are still shown to the user).
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
    /// When on, Finish import records the statement balances with the transactions.
    @Published var recordStatementBalancesOnConfirm = true
    /// Category groups and recently used categories for the review rows' category picker.
    @Published private(set) var categoryGroups: [CategoryGroup] = []
    @Published private(set) var recentCategoryIds: [Int64] = []

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
        recordStatementBalancesOnConfirm = true
        confirmedIds = []
        stagedRows = result.staged.map { ReviewRow(staged: $0, chosenCategoryId: $0.suggestedCategoryId) }
        loadPickerContext()
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

    private static let logger = Logger(subsystem: "com.personal.budget", category: "Import")

    /// Loads what the category picker needs once per review. Failing here only costs the
    /// picker its group headings and Recent section, so it's logged rather than shown.
    private func loadPickerContext() {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        do {
            (categoryGroups, recentCategoryIds) = try dbQueue.read { db in
                (try CategoryGroup.fetchAll(db), try CategoryShortlist.recent(db: db, since: since, limit: 5))
            }
        } catch {
            Self.logger.error("Couldn't load category picker groups/recent: \(error.localizedDescription, privacy: .public)")
            categoryGroups = []
            recentCategoryIds = []
        }
    }

    func dismissDuplicates() { duplicates = [] }
    func dismissUnparsedLines() { unparsedLines = [] }

    var confirmedCount: Int { confirmedIds.count }
    var unconfirmedCount: Int { stagedRows.count - confirmedIds.count }

    /// Every section's rows, partitioned once. A confirmed row leaves its section for
    /// "Confirmed" and returns to it on Undo.
    private var partitionedRows: (ready: [ReviewRow], needsAttention: [ReviewRow], confirmed: [ReviewRow]) {
        let readyIds = Set(ReviewPartitioning.partition(stagedRows.map(\.staged)).ready.map(\.id))
        var ready: [ReviewRow] = []
        var needsAttention: [ReviewRow] = []
        var confirmed: [ReviewRow] = []
        for row in stagedRows {
            if confirmedIds.contains(row.id) {
                confirmed.append(row)
            } else if readyIds.contains(row.id) {
                ready.append(row)
            } else {
                needsAttention.append(row)
            }
        }
        return (ready, needsAttention, confirmed)
    }

    var readyRows: [ReviewRow] { partitionedRows.ready }

    /// Each section's rows grouped by merchant key (spec §4), computed together so a view
    /// can read it once per body.
    var reviewSections: ReviewSections {
        let (ready, needsAttention, confirmed) = partitionedRows
        return ReviewSections(
            needsAttention: ReviewGrouping.groups(needsAttention, scope: "attention", description: \.staged.parsed.rawDescription),
            ready: ReviewGrouping.groups(ready, scope: "ready", description: \.staged.parsed.rawDescription),
            confirmed: ReviewGrouping.groups(confirmed, scope: "confirmed", description: \.staged.parsed.rawDescription)
        )
    }

    /// Sets the category of every listed row, recording whether each should learn a rule.
    func setCategory(_ categoryId: Int64?, forRowIds ids: [UUID], learnRule: Bool) {
        let idSet = Set(ids)
        for index in stagedRows.indices where idSet.contains(stagedRows[index].id) {
            stagedRows[index].chosenCategoryId = categoryId
            stagedRows[index].learnRule = learnRule
        }
    }

    /// The group picker: sets every row in the group, each keeping the Remember value its
    /// group checkbox currently shows for it (so a mixed checkbox stays mixed).
    func setCategory(_ categoryId: Int64?, for group: ReviewGroup<ReviewRow>) {
        let remember = Dictionary(uniqueKeysWithValues: group.rows.map { ($0.id, remembers($0, in: group)) })
        for index in stagedRows.indices {
            guard let learnRule = remember[stagedRows[index].id] else { continue }
            stagedRows[index].chosenCategoryId = categoryId
            stagedRows[index].learnRule = learnRule
        }
    }

    /// Whether this row of a group is ticked in the group's Remember checkbox: its own
    /// choice, or the group default (on for 2+ rows) until one is made.
    func remembers(_ row: ReviewRow, in group: ReviewGroup<ReviewRow>) -> Bool {
        row.learnRule ?? ReviewGrouping.rememberDefault(rowCount: group.rows.count)
    }

    func setRemember(_ remember: Bool, forRowIds ids: [UUID]) {
        let idSet = Set(ids)
        for index in stagedRows.indices where idSet.contains(stagedRows[index].id) {
            stagedRows[index].learnRule = remember
        }
    }

    /// Marks every "ready" row confirmed (in memory only — see `finish`).
    func confirmReady() {
        confirmRows(readyRows)
    }

    /// Marks a single row confirmed (the inline Confirm button and Return-to-confirm).
    func confirmRow(_ row: ReviewRow) {
        confirmRows([row])
    }

    /// Marks the given rows confirmed — a single row, or every row of a group. Nothing is
    /// saved until Finish import, so Cancel import still leaves no trace.
    func confirmRows(_ rows: [ReviewRow]) {
        errorMessage = nil
        let stagedIds = Set(stagedRows.map(\.id))
        confirmedIds.formUnion(rows.map(\.id).filter { stagedIds.contains($0) })
    }

    /// Undo: returns confirmed rows to their unconfirmed section, categories kept.
    func unconfirmRows(_ rows: [ReviewRow]) {
        confirmedIds.subtract(rows.map(\.id))
    }

    /// Finish import: saves the confirmed rows — plus, by `unconfirmed`, the rest as
    /// Uncategorized (or with the category chosen for them) — in ONE commit, so one
    /// `ImportBatch`. Statement balances, when wanted, are recorded in the same write;
    /// with no rows to save they're recorded on their own (never an empty batch). Rules
    /// are learned only by this commit, per each row's `learnRule`. Ends the review on
    /// success; on failure keeps it unchanged with the error shown.
    @discardableResult
    func finish(unconfirmed: UnconfirmedRowsChoice) -> Bool {
        errorMessage = nil
        let plan = ImportFinishPlan.make(
            rows: stagedRows.map { ImportFinishPlan.Row(staged: $0.staged, decision: $0.decision) },
            confirmedIds: confirmedIds, unconfirmed: unconfirmed
        )
        var points: [StatementBalancePoint] = []
        if recordStatementBalancesOnConfirm, case .available(let available) = statementBalances { points = available }
        let recorded: StatementBalanceRecording
        do {
            if plan.isEmpty {
                recorded = points.isEmpty ? StatementBalanceRecording(added: 0, updated: 0)
                    : try coordinator.recordStatementBalances(accountId: lastAccountId, sourceFileName: lastSourceFileName, points: points)
            } else {
                recorded = try coordinator.commit(
                    accountId: lastAccountId, sourceFileName: lastSourceFileName,
                    staged: plan.staged, decisions: plan.decisions, statementBalancePoints: points
                )
            }
        } catch {
            fail("Couldn't finish the import: \(error.localizedDescription)")
            return false
        }
        let pendingCount = plan.decisions.filter { $0.finalCategoryId == nil }.count
        var parts = ["Saved \(plan.staged.count) transaction(s) from \(lastSourceFileName)."]
        if pendingCount > 0 { parts.append("\(pendingCount) to assign from Uncategorized.") }
        let snapshotCount = recorded.added + recorded.updated
        if snapshotCount > 0 { parts.append("Recorded \(snapshotCount) balance snapshot(s).") }
        reset()
        statusMessage = parts.joined(separator: " ")
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

    /// Discards the whole review, confirmed rows included. Nothing was written before
    /// Finish import, so this leaves no batch, transactions, balances or rules behind.
    func cancel() {
        errorMessage = nil
        statusMessage = nil
        reset()
    }

    private func reset() {
        stagedRows = []
        confirmedIds = []
        duplicates = []
        unparsedLines = []
        isReviewing = false
        statementBalances = .notProvided
    }

    /// Reads a user-picked file, honouring security-scoped access if the app is ever
    /// sandboxed (a no-op otherwise).
    static func readText(at url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
