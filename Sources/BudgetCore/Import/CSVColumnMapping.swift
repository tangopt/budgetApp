import Foundation

public enum CSVColumnRole: String, CaseIterable, Sendable {
    case date, description, amount, moneyOut, moneyIn, balance, ignore
}

/// Pure model of the import mapping screen: one role per CSV column, convertible to and
/// from an `ImportProfile`. Each role (other than `.ignore`) is held by at most one
/// column, and a single `.amount` column excludes the split `.moneyOut`/`.moneyIn` pair.
public struct CSVColumnMapping: Equatable, Sendable {
    public private(set) var roles: [CSVColumnRole]

    public init(columnCount: Int) {
        roles = Array(repeating: .ignore, count: max(0, columnCount))
    }

    public init(columnCount: Int, suggestion: CSVColumnSuggestion) {
        self.init(columnCount: columnCount)
        if let c = suggestion.dateColumn { assign(.date, toColumn: c) }
        if let c = suggestion.descriptionColumn { assign(.description, toColumn: c) }
        if let amount = suggestion.amountColumn {
            if let credit = suggestion.creditColumn {
                assign(.moneyOut, toColumn: amount)
                assign(.moneyIn, toColumn: credit)
            } else {
                assign(.amount, toColumn: amount)
            }
        }
        if let c = suggestion.balanceColumn { assign(.balance, toColumn: c) }
    }

    public init(columnCount: Int, profile: ImportProfile) {
        self.init(columnCount: columnCount)
        if let c = profile.csvDateColumnIndex { assign(.date, toColumn: c) }
        if let c = profile.csvDescriptionColumnIndex { assign(.description, toColumn: c) }
        if let amount = profile.csvAmountColumnIndex {
            if let credit = profile.csvCreditAmountColumnIndex {
                assign(.moneyOut, toColumn: amount)
                assign(.moneyIn, toColumn: credit)
            } else {
                assign(.amount, toColumn: amount)
            }
        }
        if let c = profile.csvBalanceColumnIndex { assign(.balance, toColumn: c) }
    }

    /// Applies the exclusivity rules: the role moves to `index` (any other column holding
    /// it becomes `.ignore`), and `.amount` and `.moneyOut`/`.moneyIn` clear each other.
    /// Out-of-range indices are ignored.
    public mutating func assign(_ role: CSVColumnRole, toColumn index: Int) {
        guard roles.indices.contains(index) else { return }
        if role != .ignore {
            let conflicting: Set<CSVColumnRole>
            switch role {
            case .amount: conflicting = [.amount, .moneyOut, .moneyIn]
            case .moneyOut, .moneyIn: conflicting = [role, .amount]
            default: conflicting = [role]
            }
            for i in roles.indices where conflicting.contains(roles[i]) { roles[i] = .ignore }
        }
        roles[index] = role
    }

    /// Roles still needed before a profile can be built: date, description, then either
    /// an amount or whichever half of the money out/in pair is absent.
    public var missingRoles: [CSVColumnRole] {
        var missing: [CSVColumnRole] = []
        if column(of: .date) == nil { missing.append(.date) }
        if column(of: .description) == nil { missing.append(.description) }
        let hasOut = column(of: .moneyOut) != nil
        let hasIn = column(of: .moneyIn) != nil
        if column(of: .amount) == nil {
            if !hasOut && !hasIn { missing.append(.amount) }
            else if !hasOut { missing.append(.moneyOut) }
            else if !hasIn { missing.append(.moneyIn) }
        }
        return missing
    }

    /// `nil` while `missingRoles` is non-empty. Split statements store the money out
    /// column in `csvAmountColumnIndex` and money in in `csvCreditAmountColumnIndex`.
    public func profile(accountId: Int64, dateFormat: String, negateAmounts: Bool, allowBalance: Bool) -> ImportProfile? {
        guard missingRoles.isEmpty, let date = column(of: .date), let description = column(of: .description) else { return nil }
        let split = column(of: .amount) == nil
        return ImportProfile(
            accountId: accountId,
            format: .csv,
            csvDateColumnIndex: date,
            csvDescriptionColumnIndex: description,
            csvAmountColumnIndex: split ? column(of: .moneyOut) : column(of: .amount),
            csvCreditAmountColumnIndex: split ? column(of: .moneyIn) : nil,
            csvBalanceColumnIndex: allowBalance ? column(of: .balance) : nil,
            csvDateFormat: dateFormat,
            csvNegateAmounts: negateAmounts
        )
    }

    private func column(of role: CSVColumnRole) -> Int? { roles.firstIndex(of: role) }
}
