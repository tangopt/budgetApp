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

    private let dbQueue: DatabaseQueue
    private let coordinator: ImportCoordinator
    private let profileStore: ImportProfileStore
    private var lastSourceFileName: String = ""
    private var lastAccountId: Int64 = 0

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
        errorMessage = nil
        statusMessage = nil
        do {
            guard let accountId = account.id else { return fail("This account hasn't been saved yet.") }
            let csvText = try Self.readText(at: fileURL)
            guard let profile = try profileStore.find(accountId: accountId, format: .csv) else {
                return fail("No column mapping saved for this account yet. Run the mapping wizard first.")
            }
            let result = try await coordinator.stageCSVImport(csvText: csvText, profile: profile, accountId: accountId)
            apply(result, sourceFileName: fileURL.lastPathComponent, accountId: accountId)
        } catch {
            fail("Couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func stagePDF(lines: [String], config: PDFLayoutConfig, account: Account, sourceFileName: String) async {
        errorMessage = nil
        statusMessage = nil
        do {
            guard let accountId = account.id else { return fail("This account hasn't been saved yet.") }
            let result = try await coordinator.stagePDFImport(lines: lines, config: config, accountId: accountId)
            apply(result, sourceFileName: sourceFileName, accountId: accountId)
        } catch {
            fail("Couldn't stage \(sourceFileName): \(error.localizedDescription)")
        }
    }

    private func apply(_ result: StagedImport, sourceFileName: String, accountId: Int64) {
        lastSourceFileName = sourceFileName
        lastAccountId = accountId
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
        statusMessage = "Confirmed \(ready.count) transaction(s)."
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
        if stagedRows.isEmpty && duplicates.isEmpty && unparsedLines.isEmpty { isReviewing = false }
        return true
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
    }

    /// Reads a user-picked file, honouring security-scoped access if the app is ever
    /// sandboxed (a no-op otherwise).
    static func readText(at url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
