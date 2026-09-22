import Foundation
import GRDB

public struct StagedTransaction: Equatable, Identifiable {
    public let id: UUID
    public let parsed: ParsedTransaction
    public let suggestedCategoryId: Int64?
    public let source: CategorizedBy
    public let confidence: Double

    public init(id: UUID = UUID(), parsed: ParsedTransaction, suggestedCategoryId: Int64?, source: CategorizedBy, confidence: Double) {
        self.id = id
        self.parsed = parsed
        self.suggestedCategoryId = suggestedCategoryId
        self.source = source
        self.confidence = confidence
    }
}

public struct StagedImport {
    public let staged: [StagedTransaction]
    public let duplicateCount: Int
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
        let existingFingerprints = try await dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT fingerprint FROM transaction_ WHERE accountId = ?", arguments: [accountId]))
        }
        let categories = try await dbQueue.read { db in try Category.fetchAll(db) }
        let rules = try await dbQueue.read { db in try Rule.fetchAll(db) }

        var staged: [StagedTransaction] = []
        var duplicateCount = 0
        for parsedTransaction in parseResult.transactions {
            let fingerprint = TransactionFingerprint.compute(
                accountId: accountId, date: parsedTransaction.date,
                amountMinorUnits: parsedTransaction.amountMinorUnits, description: parsedTransaction.rawDescription
            )
            if existingFingerprints.contains(fingerprint) {
                duplicateCount += 1
                continue
            }
            let result = await categorizationService.categorize(description: parsedTransaction.rawDescription, rules: rules, categories: categories)
            staged.append(StagedTransaction(parsed: parsedTransaction, suggestedCategoryId: result.categoryId, source: result.source, confidence: result.confidence))
        }
        return StagedImport(staged: staged, duplicateCount: duplicateCount)
    }

    public func commit(accountId: Int64, sourceFileName: String, staged: [StagedTransaction], decisions: [ImportDecision]) throws {
        let decisionById = Dictionary(uniqueKeysWithValues: decisions.map { ($0.stagedId, $0.finalCategoryId) })
        try dbQueue.write { db in
            var batch = ImportBatch(accountId: accountId, sourceFileName: sourceFileName, importedAt: Date())
            try batch.insert(db)
            for stagedTransaction in staged {
                guard let finalCategoryId = decisionById[stagedTransaction.id] ?? nil else { continue }
                let fingerprint = TransactionFingerprint.compute(
                    accountId: accountId, date: stagedTransaction.parsed.date,
                    amountMinorUnits: stagedTransaction.parsed.amountMinorUnits, description: stagedTransaction.parsed.rawDescription
                )
                let wasOverridden = finalCategoryId != stagedTransaction.suggestedCategoryId
                var transaction = Transaction(
                    importBatchId: batch.id!, accountId: accountId, date: stagedTransaction.parsed.date,
                    rawDescription: stagedTransaction.parsed.rawDescription, amountMinorUnits: stagedTransaction.parsed.amountMinorUnits,
                    categoryId: finalCategoryId, status: .confirmed,
                    categorizedBy: wasOverridden ? .manual : stagedTransaction.source,
                    fingerprint: fingerprint
                )
                try transaction.insert(db)
                if wasOverridden {
                    try RuleLearner.learnFromCorrection(description: stagedTransaction.parsed.rawDescription, categoryId: finalCategoryId, db: db)
                }
            }
        }
    }
}
