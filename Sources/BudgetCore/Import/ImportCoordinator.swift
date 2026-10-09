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

    public init(id: UUID = UUID(), parsed: ParsedTransaction, suggestedCategoryId: Int64?, source: CategorizedBy, confidence: Double, fingerprint: String, historyCount: Int? = nil) {
        self.id = id
        self.parsed = parsed
        self.suggestedCategoryId = suggestedCategoryId
        self.source = source
        self.confidence = confidence
        self.fingerprint = fingerprint
        self.historyCount = historyCount
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

    public var duplicateCount: Int { duplicates.count }

    public init(staged: [StagedTransaction], duplicates: [ParsedTransaction], unparsedLines: [String], statementBalances: StatementBalanceResult = .notProvided) {
        self.staged = staged
        self.duplicates = duplicates
        self.unparsedLines = unparsedLines
        self.statementBalances = statementBalances
    }
}

public struct ImportDecision {
    public let stagedId: UUID
    public let finalCategoryId: Int64?
    /// Whether an overridden category should also be learned as a rule on commit.
    public let learnRule: Bool

    public init(stagedId: UUID, finalCategoryId: Int64?, learnRule: Bool = true) {
        self.stagedId = stagedId
        self.finalCategoryId = finalCategoryId
        self.learnRule = learnRule
    }
}

public struct StatementBalanceRecording: Equatable {
    public let added: Int
    public let updated: Int

    public init(added: Int, updated: Int) {
        self.added = added
        self.updated = updated
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
            statementBalances: StatementBalanceExtractor.extract(from: parseResult.transactions)
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
        return StagedImport(staged: staged, duplicates: duplicates, unparsedLines: unparsedLines)
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
        return result
    }

    /// Persists every staged row in one transaction, then refreshes the auto-generated
    /// forecast from the updated actuals. Rows left without a category are saved with
    /// `categoryId: nil` / `.pendingReview` ("Uncategorized", awaiting manual
    /// assignment) — never dropped, since they still move the account's balance.
    /// `statementBalancePoints` are recorded in the same transaction (see
    /// `recordStatementBalances`), so a failed commit leaves no balances behind either.
    @discardableResult
    public func commit(accountId: Int64, sourceFileName: String, staged: [StagedTransaction], decisions: [ImportDecision], statementBalancePoints: [StatementBalancePoint] = []) throws -> StatementBalanceRecording {
        let decisionById = Dictionary(decisions.map { ($0.stagedId, $0.finalCategoryId) }, uniquingKeysWith: { _, last in last })
        let learnById = Dictionary(decisions.map { ($0.stagedId, $0.learnRule) }, uniquingKeysWith: { _, last in last })
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
                    fingerprint: stagedTransaction.fingerprint
                )
                try transaction.insert(db)
                if wasOverridden, learnById[stagedTransaction.id] ?? true, let finalCategoryId {
                    try RuleLearner.learn(description: stagedTransaction.parsed.rawDescription, categoryId: finalCategoryId, db: db)
                }
            }
            try AutoForecastGenerator.refresh(db: db)
            return try Self.upsertStatementBalances(accountId: accountId, sourceFileName: sourceFileName, points: statementBalancePoints, db: db)
        }
    }

    /// Records statement-derived balances as `BalanceSnapshot`s, upserting by exact
    /// `(accountId, date)`: a snapshot already on that date is updated, otherwise one is
    /// inserted. Re-recording the same points is therefore idempotent. Balances typed on the
    /// Accounts screen are dated 00:00 UTC on the picked day too, so a statement balance for
    /// that same day deliberately replaces the typed one (the bank's figure wins). Legacy
    /// typed snapshots that carry a time of day never match a statement date and are left alone.
    public func recordStatementBalances(accountId: Int64, sourceFileName: String, points: [StatementBalancePoint]) throws -> StatementBalanceRecording {
        try dbQueue.write { db in
            try Self.upsertStatementBalances(accountId: accountId, sourceFileName: sourceFileName, points: points, db: db)
        }
    }

    private static func upsertStatementBalances(accountId: Int64, sourceFileName: String, points: [StatementBalancePoint], db: Database) throws -> StatementBalanceRecording {
        let note = "Statement balance — \(sourceFileName)"
        var added = 0
        var updated = 0
        for point in points {
            if var existing = try BalanceSnapshot
                .filter(Column("accountId") == accountId && Column("date") == point.date)
                .order(Column("id").desc)
                .fetchOne(db) {
                existing.balanceMinorUnits = point.balanceMinorUnits
                existing.note = note
                try existing.update(db)
                updated += 1
            } else {
                var snapshot = BalanceSnapshot(accountId: accountId, date: point.date, balanceMinorUnits: point.balanceMinorUnits, note: note)
                try snapshot.insert(db)
                added += 1
            }
        }
        return StatementBalanceRecording(added: added, updated: updated)
    }
}
