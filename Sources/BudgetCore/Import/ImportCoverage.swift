import Foundation

/// How far each account's statement imports reach ("Imported up to …"): the latest date of a
/// transaction that came from an imported statement. Manual entries (and their "Manual
/// entries" batch), the built-in adjustment categories (Balance adjustment / Market movement,
/// including the converted ones) and the spreadsheet history (a ".numbers" batch) never count.
public enum ImportCoverage {
    /// The latest imported transaction date in `accountId`; nil when nothing was imported.
    public static func importedThrough(accountId: Int64, transactions: [Transaction], batches: [ImportBatch], categories: [Category]) -> Date? {
        importedThroughByAccount(transactions: transactions.filter { $0.accountId == accountId }, batches: batches, categories: categories)[accountId]
    }

    /// `importedThrough` for every account with at least one imported transaction.
    public static func importedThroughByAccount(transactions: [Transaction], batches: [ImportBatch], categories: [Category]) -> [Int64: Date] {
        let excludedBatchIds = Set(batches.lazy
            .filter { $0.sourceFileName == ManualTransactions.batchSourceFileName || TransferMatcher.isHistoricalSource($0) }
            .compactMap(\.id))
        let builtInCategoryIds = Set(categories.lazy.filter(\.isBuiltIn).compactMap(\.id))
        var result: [Int64: Date] = [:]
        for transaction in transactions {
            guard !transaction.isManual, !excludedBatchIds.contains(transaction.importBatchId),
                  !(transaction.categoryId.map(builtInCategoryIds.contains) ?? false) else { continue }
            if let current = result[transaction.accountId], current >= transaction.date { continue }
            result[transaction.accountId] = transaction.date
        }
        return result
    }
}
