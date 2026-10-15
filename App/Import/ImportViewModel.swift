// App/Import/ImportViewModel.swift
import Foundation
import BudgetCore
import GRDB
import os
import struct BudgetCore.Category

struct ReviewRow: Identifiable {
    let staged: StagedTransaction
    var chosenCategoryId: Int64?
    /// "Remember for <key>": whether a changed category also learns a rule on commit.
    /// `nil` until the category is set or the toggle is touched (spec §4); an unset row
    /// follows its group's default (`ReviewGrouping.remembers`), resolved for the decision
    /// by `ImportViewModel`.
    var learnRule: Bool?
    /// Saved with the transaction on commit (spec §5).
    var note: String?
    var id: UUID { staged.id }

    /// The commit decision, with `learnRule` already resolved to what the checkbox shows.
    func decision(learnRule resolved: Bool) -> ImportDecision {
        ImportDecision(stagedId: staged.id, finalCategoryId: chosenCategoryId, learnRule: resolved, note: note)
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

    /// The groups one review tab lists (spec §7).
    func groups(in tab: ReviewTab) -> [ReviewGroup<ReviewRow>] {
        switch tab {
        case .needsAttention: return needsAttention
        case .ready: return ready
        case .confirmed: return confirmed
        }
    }

    /// Each tab's row count, for its title and `ReviewTab.settled`.
    var rowCounts: [ReviewTab: Int] {
        [.needsAttention: needsAttentionCount, .ready: readyCount, .confirmed: confirmedCount]
    }
}

@MainActor
final class ImportViewModel: ObservableObject {
    @Published var stagedRows: [ReviewRow] = [] {
        didSet {
            refreshReviewKeysIfNeeded()
            refreshStatementCheckIfNeeded()
        }
    }
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
    /// The statement's closing balance against the account's computed balance with every
    /// staged row saved (spec 2026-10-14 §2) — nil without a verified closing balance or
    /// when the check couldn't be read. Recomputed when the rows change (`stagedRowIdsChecked`).
    @Published private(set) var statementCheck: StatementCheckResult?
    /// "Add a balance adjustment of £X…": unticked by default and best avoided; when ticked,
    /// Finish import adds the difference on the closing date in the same write.
    @Published var addStatementAdjustment = false
    /// A recorded balance on or after the closing day, which rules the adjustment out.
    @Published private(set) var statementAdjustmentBlockedBy: Date?
    /// Categories, category groups and recently used categories for the review rows'
    /// category picker. "New category…" adds to `categories`.
    @Published private(set) var categories: [Category] = []
    @Published private(set) var categoryGroups: [CategoryGroup] = []
    @Published private(set) var recentCategoryIds: [Int64] = []

    private let dbQueue: DatabaseQueue
    private let coordinator: ImportCoordinator
    private let profileStore: ImportProfileStore
    private var lastSourceFileName: String = ""
    private var lastAccountId: Int64 = 0
    private var lastAccountCurrency: Currency = .gbp
    /// Every row's review key (`ReviewKey.groupKeys`), computed over the whole review so
    /// partitioning and every section group alike. Recomputed only when the rows themselves
    /// change (`reviewKeyRowIds`), not when a category or note is set.
    private var reviewKeys: [UUID: String] = [:]
    private var reviewKeyRowIds: [UUID] = []
    private var statementCheckRowIds: [UUID]?

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
        addStatementAdjustment = false
        statementCheckRowIds = nil
        statementAdjustmentBlockedBy = statementClosing.flatMap { closing in
            try? dbQueue.read { db in try StatementCheck.adjustmentBlockedBy(db: db, accountId: lastAccountId, closingDate: closing.date) }
        }
        confirmedIds = []
        stagedRows = result.staged.map { ReviewRow(staged: $0, chosenCategoryId: $0.suggestedCategoryId, note: $0.replacesManual?.note) }
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
            stagedRows += forced.map { ReviewRow(staged: $0, chosenCategoryId: $0.suggestedCategoryId, note: $0.replacesManual?.note) }
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
            (categories, categoryGroups, recentCategoryIds) = try dbQueue.read { db in
                (try Category.fetchAll(db), try CategoryGroup.fetchAll(db), try CategoryShortlist.recent(db: db, since: since, limit: 5))
            }
        } catch {
            Self.logger.error("Couldn't load category picker context: \(error.localizedDescription, privacy: .public)")
            categories = []
            categoryGroups = []
            recentCategoryIds = []
        }
    }

    /// The picker's "New category…" (spec §4): creates the category and adds it to the list.
    func createCategory(name: String, type: CategoryType, groupId: Int64?) throws -> Category {
        let category = try dbQueue.write { db in try Categories.create(db: db, name: name, type: type, groupId: groupId) }
        categories.append(category)
        return category
    }

    func dismissDuplicates() { duplicates = [] }
    func dismissUnparsedLines() { unparsedLines = [] }

    var confirmedCount: Int { confirmedIds.count }
    var unconfirmedCount: Int { stagedRows.count - confirmedIds.count }

    private func refreshReviewKeysIfNeeded() {
        let ids = stagedRows.map(\.id)
        guard ids != reviewKeyRowIds else { return }
        reviewKeyRowIds = ids
        let keys = ReviewKey.groupKeys(descriptions: stagedRows.map(\.staged.parsed.rawDescription))
        reviewKeys = Dictionary(zip(ids, keys), uniquingKeysWith: { first, _ in first })
    }

    /// The statement's closing balance (`StatementBalancePoint.isClosing`), when verified.
    var statementClosing: StatementClosing? {
        guard case .available(let points) = statementBalances, let closing = points.last(where: \.isClosing) ?? points.last else { return nil }
        return StatementClosing(date: closing.date, balanceMinorUnits: closing.balanceMinorUnits)
    }

    private func refreshStatementCheckIfNeeded() {
        let ids = stagedRows.map(\.id)
        guard ids != statementCheckRowIds else { return }
        statementCheckRowIds = ids
        statementCheck = computeStatementCheck(for: stagedRows)
    }

    /// The check for the rows Finish import would save with `unconfirmed` — what the finish
    /// dialog repeats (leaving rows out changes the computed balance).
    func finishStatementCheck(unconfirmed: UnconfirmedRowsChoice) -> StatementCheckResult? {
        computeStatementCheck(for: stagedRows.filter { unconfirmed == .saveAsUncategorized || confirmedIds.contains($0.id) })
    }

    /// Saved transactions plus `rows` (the manual entries they replace left out) against the
    /// closing balance; nil without one, or when the read fails (logged — the review then
    /// just doesn't show the check).
    private func computeStatementCheck(for rows: [ReviewRow]) -> StatementCheckResult? {
        guard let closing = statementClosing else { return nil }
        let accountId = lastAccountId
        do {
            return try dbQueue.read { db in
                try StatementCheck.compare(db: db, accountId: accountId, closing: closing,
                                           stagedRows: rows.map { ($0.staged.parsed.date, $0.staged.parsed.amountMinorUnits) },
                                           excludingTransactionIds: Set(rows.compactMap(\.staged.replacesManual?.transactionId)))
            }
        } catch {
            Self.logger.error("Couldn't check the statement balance: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Every section's rows, partitioned once (by review group). A confirmed row leaves its
    /// section for "Confirmed" and returns to it on Undo.
    private func partitionedRows(keys: [UUID: String]) -> (ready: [ReviewRow], needsAttention: [ReviewRow], confirmed: [ReviewRow]) {
        let staged = stagedRows.map(\.staged)
        let readyIds = Set(ReviewPartitioning.partition(staged, groupKeys: staged.map { keys[$0.id] ?? "" }).ready.map(\.id))
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

    var readyRows: [ReviewRow] { partitionedRows(keys: reviewKeys).ready }

    /// Each section's rows grouped by merchant key (spec §4), computed together so a view
    /// can read it once per body.
    var reviewSections: ReviewSections {
        let keys = reviewKeys
        let (ready, needsAttention, confirmed) = partitionedRows(keys: keys)
        let key: (ReviewRow) -> String = { keys[$0.id] ?? "" }
        return ReviewSections(
            needsAttention: ReviewGrouping.groups(needsAttention, scope: "attention", key: key),
            ready: ReviewGrouping.groups(ready, scope: "ready", key: key),
            confirmed: ReviewGrouping.groups(confirmed, scope: "confirmed", key: key)
        )
    }

    /// Sets the category of every listed row, recording whether each should learn a rule
    /// (`nil`: its group default). Edits a copy and assigns once, so `stagedRows`' didSet
    /// (and SwiftUI) see one change however many rows are set.
    func setCategory(_ categoryId: Int64?, forRowIds ids: [UUID], learnRule: Bool?) {
        let idSet = Set(ids)
        var rows = stagedRows
        for index in rows.indices where idSet.contains(rows[index].id) {
            rows[index].chosenCategoryId = categoryId
            rows[index].learnRule = learnRule
        }
        stagedRows = rows
    }

    /// Set category…'s Remember default for these rows: off for one processor group's
    /// purchases, otherwise on.
    func setCategoryRememberDefault(for rows: [ReviewRow]) -> Bool {
        let keys = Set(rows.map { reviewKeys[$0.id] ?? "" })
        let isProcessorGroup = keys.count == 1 && keys.first.map(ReviewKey.isProcessorGroup) == true
        return ReviewGrouping.rememberDefault(rowCount: rows.count, isProcessorGroup: isProcessorGroup)
    }

    func setNote(_ note: String?, forRowId id: UUID) {
        guard let index = stagedRows.firstIndex(where: { $0.id == id }) else { return }
        stagedRows[index].note = Transaction.normalizedNote(note)
    }

    /// The group picker: sets every row in the group, each keeping the Remember value its
    /// group checkbox currently shows for it (so a mixed checkbox stays mixed).
    func setCategory(_ categoryId: Int64?, for group: ReviewGroup<ReviewRow>) {
        let remember = Dictionary(uniqueKeysWithValues: group.rows.map { ($0.id, remembers($0, in: group)) })
        var rows = stagedRows
        for index in rows.indices {
            guard let learnRule = remember[rows[index].id] else { continue }
            rows[index].chosenCategoryId = categoryId
            rows[index].learnRule = learnRule
        }
        stagedRows = rows
    }

    /// Whether this row of a group is ticked in the group's Remember checkbox: its own
    /// choice, or the group default (on, unless a processor group) until one is made.
    func remembers(_ row: ReviewRow, in group: ReviewGroup<ReviewRow>) -> Bool {
        ReviewGrouping.remembers(choice: row.learnRule, groupRowCount: group.rows.count, isProcessorGroup: group.isProcessorGroup)
    }

    /// Each unconfirmed row's Remember value as its checkbox currently shows it, keyed by
    /// row id (confirmed rows were resolved when confirmed — see `confirmRows`).
    private var displayedRemember: [UUID: Bool] {
        var result: [UUID: Bool] = [:]
        for group in reviewSections.all {
            for row in group.rows { result[row.id] = remembers(row, in: group) }
        }
        return result
    }

    func setRemember(_ remember: Bool, forRowIds ids: [UUID]) {
        let idSet = Set(ids)
        var rows = stagedRows
        for index in rows.indices where idSet.contains(rows[index].id) {
            rows[index].learnRule = remember
        }
        stagedRows = rows
    }

    /// Confirm all on the Ready tab: marks every "ready" row confirmed (in memory only —
    /// see `finish`).
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
        let ids = Set(rows.map(\.id))
        // Freeze Remember as shown right now: the Confirmed section groups rows
        // differently, so an unset row's group default could otherwise change.
        let remember = displayedRemember
        var rows = stagedRows
        var confirmed = confirmedIds
        for index in rows.indices where ids.contains(rows[index].id) && !confirmed.contains(rows[index].id) {
            if rows[index].learnRule == nil { rows[index].learnRule = remember[rows[index].id] }
            confirmed.insert(rows[index].id)
        }
        stagedRows = rows
        confirmedIds = confirmed
    }

    /// Undo: returns confirmed rows to their unconfirmed section, categories kept.
    func unconfirmRows(_ rows: [ReviewRow]) {
        confirmedIds.subtract(rows.map(\.id))
    }

    /// Finish import: saves the confirmed rows — plus, by `unconfirmed`, the rest as
    /// Uncategorized (or with the category chosen for them) — in ONE commit, so one
    /// `ImportBatch`. A verified closing balance is checked in the same write (the account
    /// keeps any mismatch; the adjustment is added only when ticked); with no rows to save
    /// it's checked on its own (never an empty batch). Rules
    /// are learned only by this commit, per each row's `learnRule`. Ends the review on
    /// success; on failure keeps it unchanged with the error shown.
    @discardableResult
    func finish(unconfirmed: UnconfirmedRowsChoice) -> Bool {
        errorMessage = nil
        let remember = displayedRemember
        let plan = ImportFinishPlan.make(
            rows: stagedRows.map { row in
                // Confirmed rows carry the value frozen at confirm; the rest use what their
                // checkbox shows now. Every row is one or the other, so `false` is unreachable.
                let learnRule = row.learnRule ?? remember[row.id] ?? false
                return ImportFinishPlan.Row(staged: row.staged, decision: row.decision(learnRule: learnRule))
            },
            confirmedIds: confirmedIds, unconfirmed: unconfirmed
        )
        let statement = statementClosing.map {
            StatementFinish(closing: $0, addAdjustment: addStatementAdjustment && statementAdjustmentBlockedBy == nil)
        }
        let outcome: StatementFinishOutcome?
        do {
            if plan.isEmpty {
                outcome = try statement.map { try coordinator.finishStatement(accountId: lastAccountId, sourceFileName: lastSourceFileName, statement: $0) }
            } else {
                outcome = try coordinator.commit(
                    accountId: lastAccountId, sourceFileName: lastSourceFileName,
                    staged: plan.staged, decisions: plan.decisions, statement: statement
                )
            }
        } catch {
            fail("Couldn't finish the import: \(error.localizedDescription)")
            return false
        }
        let pendingCount = plan.decisions.filter { $0.finalCategoryId == nil }.count
        var parts = [plan.isEmpty ? "No new transactions to save from \(lastSourceFileName)."
                                  : "Saved \(plan.staged.count) transaction(s) from \(lastSourceFileName)."]
        if pendingCount > 0 { parts.append("\(pendingCount) to assign from Uncategorized.") }
        if let outcome { parts.append(Self.summary(of: outcome, currency: lastAccountCurrency)) }
        reset()
        statusMessage = parts.joined(separator: " ")
        return true
    }

    /// Finish import's statement line for the status message.
    static func summary(of outcome: StatementFinishOutcome, currency: Currency) -> String {
        switch outcome.check {
        case .matches(let closing):
            return "Matches the statement closing balance \(Money.format(closing.balanceMinorUnits, currency: currency)) on \(day(closing.date))."
        case .mismatch(let mismatch):
            let difference = AccountsFormat.signedMoney(mismatch.differenceMinorUnits, currency: currency)
            if outcome.adjustmentTransactionId != nil {
                return "Added a balance adjustment of \(difference) on \(day(mismatch.date)) to match the statement."
            }
            return "The balance doesn't match the statement on \(day(mismatch.date)) (difference \(difference)) — flagged on the Accounts screen."
        case .cannotCheck(let closing):
            return "The statement's closing balance on \(day(closing.date)) couldn't be checked — it's before the account's opening balance."
        }
    }

    static func day(_ date: Date) -> String { utcDayFormatter.string(from: date) }

    var currency: Currency { lastAccountCurrency }

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
        statementCheck = nil
        statementCheckRowIds = nil
        addStatementAdjustment = false
        statementAdjustmentBlockedBy = nil
    }

    /// Reads a user-picked file, honouring security-scoped access if the app is ever
    /// sandboxed (a no-op otherwise).
    static func readText(at url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
