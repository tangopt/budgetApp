import Foundation

/// The Categories screen's Distribution panel (spec 2026-10-16 §C): where a pay year's money
/// went and came from, on the Budget grid's actuals basis — confirmed, categorised,
/// budget-facing transactions (a linked transfer counts once, `TransferLinks.budgetFacing`),
/// transfers and adjustments left out. Amounts are positive (expenses as outflows); a slice
/// that nets to zero or the other way (refunds beyond spending) is left out.
public struct CategoryDistribution: Equatable, Sendable {
    public struct Slice: Equatable, Identifiable, Sendable {
        /// "g-<group id>", "g-ungrouped" or "c-<category id>".
        public let id: String
        public let name: String
        public let amountMinorUnits: Int
        /// The group (a group slice, or a category's group); nil = Ungrouped.
        public let groupId: Int64?
        /// Set on category slices.
        public let categoryId: Int64?
    }

    /// Expense groups (and Ungrouped), largest first.
    public let expensesByGroup: [Slice]
    /// Each expense group's categories (key nil = Ungrouped), largest first.
    public let expensesByCategory: [Int64?: [Slice]]
    /// Income categories, largest first.
    public let incomeByCategory: [Slice]

    public var expenseTotal: Int { expensesByGroup.reduce(0) { $0 + $1.amountMinorUnits } }
    public var incomeTotal: Int { incomeByCategory.reduce(0) { $0 + $1.amountMinorUnits } }

    /// The expense categories of `groupId` (nil = Ungrouped), largest first.
    public func expenseCategories(inGroup groupId: Int64?) -> [Slice] { expensesByCategory[groupId] ?? [] }

    /// - Parameters:
    ///   - year: the pay year (`PayCalendar.month(containing:)`); nil = all years.
    ///   - links: the transfer links, for `TransferLinks.budgetFacing` (pass none when
    ///     `transactions` are budget-facing already).
    public static func compute(year: Int?, transactions: [Transaction], links: [TransferLink] = [],
                               categories: [Category], groups: [CategoryGroup], calendar: PayCalendar) -> CategoryDistribution {
        let categoryById = Dictionary(categories.compactMap { c in c.id.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        let groupNames = Dictionary(groups.compactMap { g in g.id.map { ($0, g.name) } }, uniquingKeysWith: { a, _ in a })
        var totals: [Int64: Int] = [:]
        for transaction in TransferLinks.budgetFacing(transactions, links: links) {
            guard transaction.status == .confirmed, let categoryId = transaction.categoryId,
                  let type = categoryById[categoryId]?.type, type.isFlow else { continue }
            if let year, calendar.month(containing: transaction.date).year != year { continue }
            totals[categoryId, default: 0] += transaction.amountMinorUnits
        }

        var groupTotals: [Int64?: Int] = [:]
        var byGroup: [Int64?: [Slice]] = [:]
        var income: [Slice] = []
        for (categoryId, total) in totals {
            guard let category = categoryById[categoryId] else { continue }
            let groupId = category.groupId.flatMap { groupNames[$0] == nil ? nil : $0 }
            switch category.type {
            case .expense:
                groupTotals[groupId, default: 0] -= total
                if total < 0 {
                    byGroup[groupId, default: []].append(Slice(id: "c-\(categoryId)", name: category.name, amountMinorUnits: -total,
                                                               groupId: groupId, categoryId: categoryId))
                }
            case .income:
                if total > 0 {
                    income.append(Slice(id: "c-\(categoryId)", name: category.name, amountMinorUnits: total, groupId: groupId, categoryId: categoryId))
                }
            case .transfer, .adjustment:
                break
            }
        }
        let expenseGroups = groupTotals.compactMap { groupId, amount -> Slice? in
            guard amount > 0 else { return nil }
            return Slice(id: groupId.map { "g-\($0)" } ?? "g-ungrouped", name: groupId.flatMap { groupNames[$0] } ?? "Ungrouped",
                         amountMinorUnits: amount, groupId: groupId, categoryId: nil)
        }
        return CategoryDistribution(expensesByGroup: sorted(expenseGroups),
                                    expensesByCategory: byGroup.mapValues(sorted),
                                    incomeByCategory: sorted(income))
    }

    /// Largest first; ties by name.
    private static func sorted(_ slices: [Slice]) -> [Slice] {
        slices.sorted {
            $0.amountMinorUnits != $1.amountMinorUnits ? $0.amountMinorUnits > $1.amountMinorUnits
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
