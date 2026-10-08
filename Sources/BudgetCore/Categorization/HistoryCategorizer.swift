import Foundation
import GRDB

public struct HistoryEntry: Sendable, Equatable {
    public let merchantKey: String
    public let categoryId: Int64

    public init(merchantKey: String, categoryId: Int64) {
        self.merchantKey = merchantKey
        self.categoryId = categoryId
    }
}

/// History pre-grouped by merchant key, so each lookup is a dictionary hit rather than a
/// scan of every past transaction.
public struct HistoryIndex: Sendable {
    let countsByKey: [String: [Int64: Int]]

    public init(_ history: [HistoryEntry]) {
        var grouped: [String: [Int64: Int]] = [:]
        for entry in history { grouped[entry.merchantKey, default: [:]][entry.categoryId, default: 0] += 1 }
        countsByKey = grouped
    }

    public var isEmpty: Bool { countsByKey.isEmpty }

    public func suggest(merchantKey: String) -> (categoryId: Int64, count: Int, share: Double)? {
        guard let counts = countsByKey[merchantKey] else { return nil }
        let total = counts.values.reduce(0, +)
        guard total >= HistoryCategorizer.minimumCount,
              let top = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        let share = Double(top.value) / Double(total)
        guard share >= HistoryCategorizer.minimumShare else { return nil }
        return (top.key, top.value, share)
    }
}

public enum HistoryCategorizer {
    /// A category must cover at least this share of a merchant's categorised transactions.
    static let minimumShare = 0.7
    static let minimumCount = 2

    /// Confirmed, categorised transactions of every account, reduced to merchant key + category.
    public static func load(db: Database) throws -> [HistoryEntry] {
        let rows = try Row.fetchAll(db, sql: "SELECT rawDescription, categoryId FROM transaction_ WHERE status = ? AND categoryId IS NOT NULL", arguments: [TransactionStatus.confirmed.rawValue])
        return rows.map { HistoryEntry(merchantKey: MerchantKey.make($0["rawDescription"]), categoryId: $0["categoryId"]) }
    }

    /// The most used category for `merchantKey` when it covers at least 70% of that key's
    /// history and there are at least 2 transactions; `nil` otherwise.
    public static func suggest(merchantKey: String, history: [HistoryEntry]) -> (categoryId: Int64, count: Int, share: Double)? {
        HistoryIndex(history).suggest(merchantKey: merchantKey)
    }
}
