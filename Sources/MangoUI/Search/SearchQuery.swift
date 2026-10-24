import Foundation
import BudgetCore

/// A period token (iPhone spec §3.4 "period"): one of `TransactionSearch`'s relative date filters.
public enum SearchPeriod: String, CaseIterable, Hashable, Sendable {
    case thisMonth, thisYear, last12Months

    public var title: String {
        switch self {
        case .thisMonth: "This month"
        case .thisYear: "This year"
        case .last12Months: "Last 12 months"
        }
    }

    public var filter: TransactionSearch.DateFilter {
        switch self {
        case .thisMonth: .thisMonth
        case .thisYear: .thisYear
        case .last12Months: .last12Months
        }
    }
}

/// A filter token in the search field (iPhone spec §3.4: Uncategorised · account · period).
public enum SearchToken: Hashable, Identifiable, Sendable {
    case uncategorised
    case account(id: Int64, name: String)
    case period(SearchPeriod)

    public var id: String {
        switch self {
        case .uncategorised: "uncategorised"
        case .account(let id, _): "account-\(id)"
        case .period(let period): "period-\(period.rawValue)"
        }
    }

    public var title: String {
        switch self {
        case .uncategorised: "Uncategorised"
        case .account(_, let name): name
        case .period(let period): period.title
        }
    }

    public var symbol: String {
        switch self {
        case .uncategorised: "questionmark.circle"
        case .account: "building.columns"
        case .period: "calendar"
        }
    }

    var isPeriod: Bool {
        if case .period = self { true } else { false }
    }
}

/// What the search field and its tokens mean, as `TransactionSearch.Criteria` (iPhone spec §3.4). Words match the
/// description, note and category name; a word that reads as an amount ("24.99") also matches that exact amount, as
/// `TransactionSearch` does on the Mac. A comparison (">100", ">= 100", "<£50", "≤12.50") bounds the absolute
/// amount: ">" and "<" are strict, in pence. Pure: no figure is computed here.
public enum SearchQuery {
    private static let comparators: [(prefix: String, kind: Bound)] = [
        (">=", .atLeast), ("<=", .atMost), ("≥", .atLeast), ("≤", .atMost), (">", .moreThan), ("<", .lessThan),
    ]

    private enum Bound {
        case moreThan, atLeast, lessThan, atMost
    }

    public static func criteria(text: String, tokens: [SearchToken]) -> TransactionSearch.Criteria {
        var criteria = TransactionSearch.Criteria()
        var words: [String] = []
        var pending = text.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        while let word = pending.popFirst() {
            guard let (prefix, kind) = comparators.first(where: { word.hasPrefix($0.prefix) }) else {
                words.append(word)
                continue
            }
            var amountText = String(word.dropFirst(prefix.count))
            if amountText.isEmpty {
                // "> 100": the amount is the next word; a comparison with nothing after it is dropped.
                guard let next = pending.first, TransactionSearch.amountToken(next) != nil else { continue }
                amountText = next
                pending.removeFirst()
            }
            guard let amount = TransactionSearch.amountToken(amountText) else {
                words.append(word)
                continue
            }
            switch kind {
            case .moreThan: criteria.minAmountMinorUnits = max(criteria.minAmountMinorUnits ?? 0, amount + 1)
            case .atLeast: criteria.minAmountMinorUnits = max(criteria.minAmountMinorUnits ?? 0, amount)
            case .lessThan: criteria.maxAmountMinorUnits = min(criteria.maxAmountMinorUnits ?? .max, max(amount - 1, 0))
            case .atMost: criteria.maxAmountMinorUnits = min(criteria.maxAmountMinorUnits ?? .max, amount)
            }
        }
        criteria.text = words.joined(separator: " ")
        for token in tokens {
            switch token {
            case .uncategorised: criteria.includesUncategorised = true
            case .account(let id, _): criteria.accountIds.insert(id)
            case .period(let period): criteria.date = period.filter
            }
        }
        return criteria
    }

    /// The tokens the field offers: Uncategorised, the periods, then `accounts` (in the order given), leaving out
    /// what's already chosen, and every period once one is.
    public static func suggestions(accounts: [SearchToken], chosen: [SearchToken]) -> [SearchToken] {
        let hasPeriod = chosen.contains(where: \.isPeriod)
        let all: [SearchToken] = [.uncategorised] + SearchPeriod.allCases.map(SearchToken.period) + accounts
        return all.filter { token in
            !chosen.contains(token) && !(hasPeriod && token.isPeriod)
        }
    }
}
