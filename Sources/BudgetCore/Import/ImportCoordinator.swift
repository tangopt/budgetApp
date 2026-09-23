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

    public init(id: UUID = UUID(), parsed: ParsedTransaction, suggestedCategoryId: Int64?, source: CategorizedBy, confidence: Double, fingerprint: String) {
        self.id = id
        self.parsed = parsed
        self.suggestedCategoryId = suggestedCategoryId
        self.source = source
        self.confidence = confidence
        self.fingerprint = fingerprint
    }
}

public struct StagedImport {
    public let staged: [StagedTransaction]
    /// Rows already imported for this account (matched by fingerprint), surfaced for
    /// review and force-importable via `ImportCoordinator.stageForcedDuplicates`.
    public let duplicates: [ParsedTransaction]
    /// Statement lines that couldn't be parsed — "couldn't auto-parse, enter manually".
    public let unparsedLines: [String]

    public var duplicateCount: Int { duplicates.count }

    public init(staged: [StagedTransaction], duplicates: [ParsedTransaction], unparsedLines: [String]) {
        self.staged = staged
        self.duplicates = duplicates
        self.unparsedLines = unparsedLines
    }
}

public struct ImportDecision {
    public let stagedId: UUID
    public let finalCategoryId: Int64?

    public init(stagedId: UUID, finalCategoryId: Int64?) {
        self.stagedId = stagedId
        self.finalCategoryId = finalCategoryId
    }
}

public final class ImportCoordinator {
    private let dbQueue: DatabaseQueue
    private let categorizationService: CategorizationService

    public init(dbQueue: DatabaseQueue, categorizationService: CategorizationService) {
        self.dbQueue = dbQueue
        self.categorizationService = categorizationService
    }

    public func stageCSVImport(csvText: String, profile: ImportProfile, accountId: Int64) async throws -> StagedImport {
        let parseResult = CSVStatementParser.parse(csvText: csvText, profile: profile)
        return try await stage(parsed: parseResult.transactions, unparsedLines: parseResult.unparsedLines, accountId: accountId)
    }

    public func stagePDFImport(lines: [String], config: PDFLayoutConfig, accountId: Int64) async throws -> StagedImport {
        let parseResult = PDFLineParser.parse(lines: lines, config: config)
        return try await stage(parsed: parseResult.transactions, unparsedLines: parseResult.unparsedLines, accountId: accountId)
    }

    /// Shared staging for every statement format: fingerprint (with a within-file
    /// occurrence index so identical-looking rows in one statement don't collide on the
    /// `[accountId, fingerprint]` unique key), split off duplicates of already-imported
    /// rows, and categorize the rest.
    private func stage(parsed: [ParsedTransaction], unparsedLines: [String], accountId: Int64) async throws -> StagedImport {
        let (existingFingerprints, categories, rules) = try await dbQueue.read { db in
            (
                try Set(String.fetchAll(db, sql: "SELECT fingerprint FROM transaction_ WHERE accountId = ?", arguments: [accountId])),
                try Category.fetchAll(db),
                try Rule.fetchAll(db)
            )
        }

        var staged: [StagedTransaction] = []
        var duplicates: [ParsedTransaction] = []
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
            let result = await categorizationService.categorize(description: parsedTransaction.rawDescription, rules: rules, categories: categories)
            staged.append(StagedTransaction(parsed: parsedTransaction, suggestedCategoryId: result.categoryId, source: result.source, confidence: result.confidence, fingerprint: fingerprint))
        }
        return StagedImport(staged: staged, duplicates: duplicates, unparsedLines: unparsedLines)
    }

    /// Force-imports rows that staging flagged as duplicates (a genuine legitimate
    /// collision, per spec). Each gets the lowest occurrence index whose fingerprint is
    /// free in both the database and `alreadyStaged`, so it can be committed alongside
    /// them without violating the unique key.
    public func stageForcedDuplicates(_ duplicates: [ParsedTransaction], accountId: Int64, alreadyStaged: [StagedTransaction]) async throws -> [StagedTransaction] {
        let (existingFingerprints, categories, rules) = try await dbQueue.read { db in
            (
                try Set(String.fetchAll(db, sql: "SELECT fingerprint FROM transaction_ WHERE accountId = ?", arguments: [accountId])),
                try Category.fetchAll(db),
                try Rule.fetchAll(db)
            )
        }
        var taken = existingFingerprints.union(alreadyStaged.map(\.fingerprint))
        var result: [StagedTransaction] = []
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
            let categorization = await categorizationService.categorize(description: parsedTransaction.rawDescription, rules: rules, categories: categories)
            result.append(StagedTransaction(parsed: parsedTransaction, suggestedCategoryId: categorization.categoryId, source: categorization.source, confidence: categorization.confidence, fingerprint: fingerprint))
        }
        return result
    }

    /// Persists every staged row in one transaction, then refreshes the auto-generated
    /// forecast from the updated actuals. Rows left without a category are saved with
    /// `categoryId: nil` / `.pendingReview` ("Uncategorized", awaiting manual
    /// assignment) — never dropped, since they still move the account's balance.
    public func commit(accountId: Int64, sourceFileName: String, staged: [StagedTransaction], decisions: [ImportDecision]) throws {
        let decisionById = Dictionary(decisions.map { ($0.stagedId, $0.finalCategoryId) }, uniquingKeysWith: { _, last in last })
        try dbQueue.write { db in
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
                if wasOverridden, let finalCategoryId {
                    try RuleLearner.learnFromCorrection(description: stagedTransaction.parsed.rawDescription, categoryId: finalCategoryId, db: db)
                }
            }
            try AutoForecastGenerator.refresh(db: db)
        }
    }
}
