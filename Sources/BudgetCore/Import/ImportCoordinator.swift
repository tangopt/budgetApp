import Foundation
import GRDB

public struct StagedTransaction: Equatable, Identifiable {
    public let id: UUID
    public let parsed: ParsedTransaction
    public let suggestedCategoryId: Int64?
    public let source: CategorizedBy
    public let confidence: Double
    /// Assigned at staging time, including the within-file occurrence index (see
    /// `TransactionFingerprint.compute(occurrence:)`), and persisted as-is on commit.
    public let fingerprint: String
    /// For `.history` suggestions, how many past transactions back it (see
    /// `CategorizationResult.historyCount`); `nil` for every other source.
    public let historyCount: Int?
    /// The saved transaction this row is the other leg of a transfer with (spec §6), when the
    /// matcher would link them; the suggestion is then that leg's category (source `.transfer`).
    public let transfer: StagedTransfer?
    /// The manual entry this row replaces on Finish import (spec §3) — "Replaces your manual
    /// entry (<date>)"; the suggestion is then that entry's category (source `.manual`).
    public let replacesManual: StagedManualReplacement?

    public init(id: UUID = UUID(), parsed: ParsedTransaction, suggestedCategoryId: Int64?, source: CategorizedBy, confidence: Double, fingerprint: String, historyCount: Int? = nil, transfer: StagedTransfer? = nil, replacesManual: StagedManualReplacement? = nil) {
        self.id = id
        self.parsed = parsed
        self.suggestedCategoryId = suggestedCategoryId
        self.source = source
        self.confidence = confidence
        self.fingerprint = fingerprint
        self.historyCount = historyCount
        self.transfer = transfer
        self.replacesManual = replacesManual
    }
}

public struct StagedImport {
    public let staged: [StagedTransaction]
    /// Rows already imported for this account (matched by fingerprint), surfaced for
    /// review and force-importable via `ImportCoordinator.stageForcedDuplicates`.
    public let duplicates: [ParsedTransaction]
    /// Statement lines that couldn't be parsed — "couldn't auto-parse, enter manually".
    public let unparsedLines: [String]
    /// Verified Balance-column result for the whole file (including rows later skipped as
    /// duplicates). `.notProvided` for PDFs and for CSV profiles without a balance column.
    public let statementBalances: StatementBalanceResult
    /// CSV rows left out because their status column says they aren't completed (pending,
    /// reverted…). 0 for PDFs and profiles without a status column.
    public let skippedRowCount: Int

    public var duplicateCount: Int { duplicates.count }

    public init(staged: [StagedTransaction], duplicates: [ParsedTransaction], unparsedLines: [String], statementBalances: StatementBalanceResult = .notProvided,
                skippedRowCount: Int = 0) {
        self.staged = staged
        self.duplicates = duplicates
        self.unparsedLines = unparsedLines
        self.statementBalances = statementBalances
        self.skippedRowCount = skippedRowCount
    }
}

public struct ImportDecision {
    public let stagedId: UUID
    public let finalCategoryId: Int64?
    /// Whether the final category should also be learned as a rule on commit (when it
    /// overrides the suggestion or the suggestion wasn't a rule's).
    public let learnRule: Bool
    /// The row's note, saved with the transaction (trimmed; blank means none).
    public let note: String?

    public init(stagedId: UUID, finalCategoryId: Int64?, learnRule: Bool = true, note: String? = nil) {
        self.stagedId = stagedId
        self.finalCategoryId = finalCategoryId
        self.learnRule = learnRule
        self.note = note
    }
}

public final class ImportCoordinator {
    private let dbQueue: DatabaseQueue
    private let categorizationService: CategorizationService
    /// Descriptions per `CategorizationService.categorizeBatch` call. Large enough to cut
    /// a few hundred sequential on-device model calls down to a handful; small enough to
    /// keep each individual prompt/response manageable and keep the chance of a
    /// batch-count mismatch (see `OnDeviceCategorizer.suggestCategories`) low.
    private static let categorizationBatchSize = 25

    public init(dbQueue: DatabaseQueue, categorizationService: CategorizationService) {
        self.dbQueue = dbQueue
        self.categorizationService = categorizationService
    }

    public func stageCSVImport(csvText: String, profile: ImportProfile, accountId: Int64, onProgress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> StagedImport {
        let parseResult = CSVStatementParser.parse(csvText: csvText, profile: profile)
        let staged = try await stage(parsed: parseResult.transactions, unparsedLines: parseResult.unparsedLines, accountId: accountId, onProgress: onProgress)
        return StagedImport(
            staged: staged.staged, duplicates: staged.duplicates, unparsedLines: staged.unparsedLines,
            statementBalances: StatementBalanceExtractor.extract(from: parseResult.transactions),
            skippedRowCount: parseResult.skippedRows
        )
    }

    public func stagePDFImport(lines: [String], config: PDFLayoutConfig, accountId: Int64, onProgress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> StagedImport {
        let parseResult = PDFLineParser.parse(lines: lines, config: config)
        return try await stage(parsed: parseResult.transactions, unparsedLines: parseResult.unparsedLines, accountId: accountId, onProgress: onProgress)
    }

    /// Shared staging for every statement format: fingerprint (with a within-file
    /// occurrence index so identical-looking rows in one statement don't collide on the
    /// `[accountId, fingerprint]` unique key), split off duplicates of already-imported
    /// rows, then categorize the rest in batches (see `categorizationBatchSize`).
    /// `onProgress(categorized, totalToCategorize)` fires after each batch — the total is
    /// the count of non-duplicate rows (the actual categorization workload), not the raw
    /// row count in the file, since duplicates are already known and skipped before this
    /// count is reported.
    private func stage(parsed: [ParsedTransaction], unparsedLines: [String], accountId: Int64, onProgress: @Sendable (Int, Int) -> Void) async throws -> StagedImport {
        let (existingFingerprints, categories, rules, history) = try await dbQueue.read { db in
            (
                try Set(String.fetchAll(db, sql: "SELECT fingerprint FROM transaction_ WHERE accountId = ?", arguments: [accountId])),
                try Category.fetchAll(db).filter(\.isAssignable),
                try Rule.fetchAll(db),
                try HistoryCategorizer.load(db: db)
            )
        }

        var duplicates: [ParsedTransaction] = []
        var nonDuplicates: [(parsed: ParsedTransaction, fingerprint: String)] = []
        var occurrencesSeen: [String: Int] = [:]
        for parsedTransaction in parsed {
            let baseFingerprint = TransactionFingerprint.compute(
                accountId: accountId, date: parsedTransaction.date,
                amountMinorUnits: parsedTransaction.amountMinorUnits, description: parsedTransaction.rawDescription
            )
            let occurrence = occurrencesSeen[baseFingerprint, default: 0]
            occurrencesSeen[baseFingerprint] = occurrence + 1
            let fingerprint = TransactionFingerprint.compute(
                accountId: accountId, date: parsedTransaction.date,
                amountMinorUnits: parsedTransaction.amountMinorUnits, description: parsedTransaction.rawDescription,
                occurrence: occurrence
            )
            if existingFingerprints.contains(fingerprint) {
                duplicates.append(parsedTransaction)
                continue
            }
            nonDuplicates.append((parsedTransaction, fingerprint))
        }

        var staged: [StagedTransaction] = []
        staged.reserveCapacity(nonDuplicates.count)
        var categorizedCount = 0
        for batchStart in stride(from: 0, to: nonDuplicates.count, by: Self.categorizationBatchSize) {
            let batch = nonDuplicates[batchStart..<min(batchStart + Self.categorizationBatchSize, nonDuplicates.count)]
            let results = await categorizationService.categorizeBatch(descriptions: batch.map(\.parsed.rawDescription), rules: rules, categories: categories, history: history)
            for (item, result) in zip(batch, results) {
                staged.append(StagedTransaction(parsed: item.parsed, suggestedCategoryId: result.categoryId, source: result.source, confidence: result.confidence, fingerprint: item.fingerprint, historyCount: result.historyCount))
            }
            categorizedCount += batch.count
            onProgress(categorizedCount, nonDuplicates.count)
        }
        let withReplacements = try await withManualReplacements(staged, accountId: accountId)
        return StagedImport(staged: try await withTransfers(withReplacements, accountId: accountId), duplicates: duplicates, unparsedLines: unparsedLines)
    }

    /// Marks the rows that replace a manual entry of the account
    /// (`ManualTransactions.stagedReplacements`): each takes that entry's category (source
    /// `.manual`, Ready when categorised) and carries its note for the review to pre-fill.
    /// `alreadyStaged` rows keep the entries they claimed.
    private func withManualReplacements(_ rows: [StagedTransaction], accountId: Int64, alreadyStaged: [StagedTransaction] = []) async throws -> [StagedTransaction] {
        guard !rows.isEmpty else { return rows }
        let claimed = Set(alreadyStaged.compactMap(\.replacesManual?.transactionId))
        let replacements = try await dbQueue.read { db in
            try ManualTransactions.stagedReplacements(db: db, accountId: accountId,
                                                      staged: rows.map { ($0.parsed.date, $0.parsed.amountMinorUnits) }, excluding: claimed)
        }
        guard !replacements.isEmpty else { return rows }
        return rows.enumerated().map { index, row in
            guard let replacement = replacements[index] else { return row }
            return StagedTransaction(id: row.id, parsed: row.parsed, suggestedCategoryId: replacement.categoryId,
                                     source: replacement.categoryId == nil ? .none : .manual, confidence: 1,
                                     fingerprint: row.fingerprint, replacesManual: replacement)
        }
    }

    /// Marks the rows that are the other leg of a saved transfer (`TransferMatcher.stagedMatches`):
    /// each gets the "↔ Transfer" badge and the other leg's account's transfer category
    /// (`TransferCategories`; source `.transfer`, Ready) — commit links them and files the saved
    /// leg under this account's. When that account has none, the other leg's own category is
    /// taken instead if it keeps the pair linkable: money received may take any of the sending
    /// leg's categories (always uncategorised or a transfer one); money sent only takes a
    /// non-external transfer category — otherwise (say the receiving leg is filed as Salary) it
    /// keeps its own suggestion, which the match already found linkable, so commit still links.
    private func withTransfers(_ staged: [StagedTransaction], accountId: Int64) async throws -> [StagedTransaction] {
        // A row replacing a manual entry keeps that entry's category and takes over its links
        // on commit (the matcher looks at it then if there are none), so it's left out here and
        // can't claim a saved leg another row would match.
        let matchable = staged.indices.filter { staged[$0].replacesManual == nil }
        guard !matchable.isEmpty else { return staged }
        let (matchesByPosition, linkableSentCategoryIds, accountCategoryIds) = try await dbQueue.read { db in
            (try TransferMatcher.stagedMatches(db: db, accountId: accountId,
                                               staged: matchable.map { (staged[$0].parsed.date, staged[$0].parsed.amountMinorUnits, staged[$0].suggestedCategoryId) }),
             Set(try Int64.fetchAll(db, sql: "SELECT id FROM category WHERE type = ? AND isExternalTransfer = 0",
                                    arguments: [CategoryType.transfer.rawValue])),
             try TransferCategories.categoryIdsByAccount(db: db))
        }
        guard !matchesByPosition.isEmpty else { return staged }
        let matches = Dictionary(uniqueKeysWithValues: matchesByPosition.map { (matchable[$0.key], $0.value) })
        return staged.enumerated().map { index, row in
            guard let match = matches[index] else { return row }
            guard let categoryId = accountCategoryIds[match.otherAccountId] ?? match.otherCategoryId, match.isIncoming || linkableSentCategoryIds.contains(categoryId) else {
                return StagedTransaction(id: row.id, parsed: row.parsed, suggestedCategoryId: row.suggestedCategoryId, source: row.source,
                                         confidence: row.confidence, fingerprint: row.fingerprint, historyCount: row.historyCount, transfer: match)
            }
            return StagedTransaction(id: row.id, parsed: row.parsed, suggestedCategoryId: categoryId, source: .transfer,
                                     confidence: 1, fingerprint: row.fingerprint, transfer: match)
        }
    }

    /// Force-imports rows that staging flagged as duplicates (a genuine legitimate
    /// collision, per spec). Each gets the lowest occurrence index whose fingerprint is
    /// free in both the database and `alreadyStaged`, so it can be committed alongside
    /// them without violating the unique key. Categorizes in the same batches as `stage`.
    public func stageForcedDuplicates(_ duplicates: [ParsedTransaction], accountId: Int64, alreadyStaged: [StagedTransaction], onProgress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [StagedTransaction] {
        let (existingFingerprints, categories, rules, history) = try await dbQueue.read { db in
            (
                try Set(String.fetchAll(db, sql: "SELECT fingerprint FROM transaction_ WHERE accountId = ?", arguments: [accountId])),
                try Category.fetchAll(db).filter(\.isAssignable),
                try Rule.fetchAll(db),
                try HistoryCategorizer.load(db: db)
            )
        }
        var taken = existingFingerprints.union(alreadyStaged.map(\.fingerprint))
        var items: [(parsed: ParsedTransaction, fingerprint: String)] = []
        for parsedTransaction in duplicates {
            var occurrence = 0
            var fingerprint: String
            repeat {
                fingerprint = TransactionFingerprint.compute(
                    accountId: accountId, date: parsedTransaction.date,
                    amountMinorUnits: parsedTransaction.amountMinorUnits, description: parsedTransaction.rawDescription,
                    occurrence: occurrence
                )
                occurrence += 1
            } while taken.contains(fingerprint)
            taken.insert(fingerprint)
            items.append((parsedTransaction, fingerprint))
        }

        var result: [StagedTransaction] = []
        result.reserveCapacity(items.count)
        var categorizedCount = 0
        for batchStart in stride(from: 0, to: items.count, by: Self.categorizationBatchSize) {
            let batch = items[batchStart..<min(batchStart + Self.categorizationBatchSize, items.count)]
            let results = await categorizationService.categorizeBatch(descriptions: batch.map(\.parsed.rawDescription), rules: rules, categories: categories, history: history)
            for (item, categorization) in zip(batch, results) {
                result.append(StagedTransaction(parsed: item.parsed, suggestedCategoryId: categorization.categoryId, source: categorization.source, confidence: categorization.confidence, fingerprint: item.fingerprint, historyCount: categorization.historyCount))
            }
            categorizedCount += batch.count
            onProgress(categorizedCount, items.count)
        }
        let replacing = try await withManualReplacements(result, accountId: accountId, alreadyStaged: alreadyStaged)
        // Matched alongside the rows already staged, so a saved leg isn't offered to both.
        let annotated = try await withTransfers(alreadyStaged + replacing, accountId: accountId)
        return Array(annotated.suffix(result.count))
    }

    /// Persists every staged row in one transaction (a row replacing a manual entry takes over
    /// its transfer links, and the entry is deleted — `ManualTransactions.replace`), links transfers between the user's
    /// accounts (`TransferMatcher.match`), then refreshes the auto-generated forecast from the
    /// updated actuals. Rows left without a category are saved with
    /// `categoryId: nil` / `.pendingReview` ("Uncategorized", awaiting manual
    /// assignment) — never dropped, since they still move the account's balance.
    /// With a `statement`, its closing balance is checked against what's then saved — and the
    /// adjustment added when ticked — in the same transaction (`StatementCheck.finish`), so a
    /// failed commit leaves neither an adjustment nor a recorded mismatch behind. Returns that
    /// check's outcome (nil without a statement). Either way the account's flagged mismatch is
    /// re-checked (`StatementCheck.recheckStoredMismatch`).
    @discardableResult
    public func commit(accountId: Int64, sourceFileName: String, staged: [StagedTransaction], decisions: [ImportDecision], statement: StatementFinish? = nil) throws -> StatementFinishOutcome? {
        let decisionById = Dictionary(decisions.map { ($0.stagedId, $0.finalCategoryId) }, uniquingKeysWith: { _, last in last })
        let learnById = Dictionary(decisions.map { ($0.stagedId, $0.learnRule) }, uniquingKeysWith: { _, last in last })
        let noteById = Dictionary(decisions.map { ($0.stagedId, $0.note) }, uniquingKeysWith: { _, last in last })
        return try dbQueue.write { db in
            var batch = ImportBatch(accountId: accountId, sourceFileName: sourceFileName, importedAt: Date())
            try batch.insert(db)
            for stagedTransaction in staged {
                let finalCategoryId: Int64? = decisionById[stagedTransaction.id] ?? stagedTransaction.suggestedCategoryId
                let wasOverridden = finalCategoryId != stagedTransaction.suggestedCategoryId
                let categorizedBy: CategorizedBy
                if finalCategoryId == nil {
                    categorizedBy = .none
                } else {
                    categorizedBy = wasOverridden ? .manual : stagedTransaction.source
                }
                var transaction = Transaction(
                    importBatchId: batch.id!, accountId: accountId, date: stagedTransaction.parsed.date,
                    rawDescription: stagedTransaction.parsed.rawDescription, amountMinorUnits: stagedTransaction.parsed.amountMinorUnits,
                    categoryId: finalCategoryId, status: finalCategoryId == nil ? .pendingReview : .confirmed,
                    categorizedBy: categorizedBy,
                    fingerprint: stagedTransaction.fingerprint,
                    note: Transaction.normalizedNote(noteById[stagedTransaction.id] ?? stagedTransaction.replacesManual?.note)
                )
                try transaction.insert(db)
                if let replacement = stagedTransaction.replacesManual {
                    try ManualTransactions.replace(db: db, manualId: replacement.transactionId, with: transaction.id!)
                }
                // Learn what the user confirmed with Remember on: a correction, or a model or
                // history guess they accepted (so the next import needn't guess). A rule's own
                // unchanged suggestion already has its rule; a transfer's comes from its other leg.
                if learnById[stagedTransaction.id] ?? true, let finalCategoryId,
                   wasOverridden || (stagedTransaction.source != .rule && stagedTransaction.source != .transfer && stagedTransaction.replacesManual == nil) {
                    try RuleLearner.learn(description: stagedTransaction.parsed.rawDescription, categoryId: finalCategoryId, db: db)
                }
            }
            // Link transfers first, so the forecast refresh counts each one once.
            try TransferMatcher.match(db: db)
            let outcome = try statement.map { try StatementCheck.finish(db: db, accountId: accountId, sourceFileName: sourceFileName, statement: $0) }
            if statement == nil { try StatementCheck.recheckStoredMismatch(db: db, accountId: accountId) }
            try AutoForecastGenerator.refresh(db: db)
            return outcome
        }
    }

    /// Finish import with no rows to save: the statement's closing balance is still checked
    /// (and adjusted when ticked) on its own — never an empty batch.
    @discardableResult
    public func finishStatement(accountId: Int64, sourceFileName: String, statement: StatementFinish) throws -> StatementFinishOutcome {
        try dbQueue.write { db in
            let outcome = try StatementCheck.finish(db: db, accountId: accountId, sourceFileName: sourceFileName, statement: statement)
            if outcome.adjustmentTransactionId != nil { try AutoForecastGenerator.refresh(db: db) }
            return outcome
        }
    }
}
