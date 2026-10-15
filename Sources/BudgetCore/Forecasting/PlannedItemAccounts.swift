import Foundation

/// Which account each planned item (`ForecastEntry`) belongs to (spec 2026-10-15 §2), and how
/// the plan splits by account for the Budget account filter (§3) and its net worth (§4).
///
/// An entry's **effective account** is its explicit `accountId`, else the account **inferred**
/// for its category: the account holding most of the category's budget-facing (confirmed)
/// transactions over the last 12 pay months (ties → the account of the most recent of those
/// transactions); none in that window → over all history; none at all → the **main account**
/// (`Account.isMain`, account-forecast spec §1); no main account → nil. Detected /
/// auto-forecast entries and reserves follow the same rule.
///
/// A planned item in a transfer category tied to an account (`Category.transferAccountId`,
/// "Transfer: Joint") moves money from its effective account (the paying account) to the tied
/// one. Under a filter the paying account shows the outgoing amount; the tied account shows the
/// incoming amount (sign flipped) under the paying account's own transfer category
/// ("Transfer: Current"), like an actual linked transfer; with both selected it counts once,
/// as sent.
public struct PlannedItemAccounts: Equatable, Sendable {
    /// The inference window, in pay months (the current one included).
    public static let windowPayMonths = 12

    /// The inferred account per category id (categories with no transaction are absent).
    public let inferredByCategory: [Int64: Int64]
    /// The account each tied transfer category moves money into.
    public let tiedAccountByCategory: [Int64: Int64]
    /// Each account's own transfer category ("Transfer: <account>").
    public let transferCategoryByAccount: [Int64: Int64]
    /// Where items with no account of their own and no category history go (nil = nowhere).
    public let mainAccountId: Int64?

    public init(inferredByCategory: [Int64: Int64], categories: [Category], mainAccountId: Int64? = nil) {
        self.inferredByCategory = inferredByCategory
        self.mainAccountId = mainAccountId
        var tied: [Int64: Int64] = [:]
        var byAccount: [Int64: Int64] = [:]
        for category in categories where category.type == .transfer {
            guard let id = category.id, let accountId = category.transferAccountId else { continue }
            tied[id] = accountId
            if byAccount[accountId] == nil { byAccount[accountId] = id }
        }
        tiedAccountByCategory = tied
        transferCategoryByAccount = byAccount
    }

    /// Inference over `budgetTransactions` (`TransferLinks.budgetFacing` over every account)
    /// with the window ending at `calendar`'s current pay month.
    public init(categories: [Category], budgetTransactions: [Transaction], calendar: PayCalendar, mainAccountId: Int64? = nil) {
        self.init(inferredByCategory: Self.inferAccounts(budgetTransactions: budgetTransactions, since: Self.windowStart(calendar: calendar)),
                  categories: categories, mainAccountId: mainAccountId)
    }

    /// The first day of the inference window: the start of the pay month eleven before the
    /// current one.
    public static func windowStart(calendar: PayCalendar) -> Date {
        var month = calendar.current
        for _ in 1..<windowPayMonths { month = month.previous }
        return calendar.range(of: month).start
    }

    /// The inferred account per category id from confirmed, categorised `budgetTransactions`:
    /// those dated on/after `since` decide; a category with none there falls back to all of
    /// its history.
    public static func inferAccounts(budgetTransactions: [Transaction], since: Date) -> [Int64: Int64] {
        let byCategory = Dictionary(grouping: budgetTransactions.filter { $0.categoryId != nil && $0.status == .confirmed }, by: { $0.categoryId! })
        var result: [Int64: Int64] = [:]
        for (categoryId, transactions) in byCategory {
            let recent = transactions.filter { $0.date >= since }
            if let account = majorityAccount(recent.isEmpty ? transactions : recent) { result[categoryId] = account }
        }
        return result
    }

    /// The account with the most transactions; ties → the account of the most recent
    /// transaction among the tied accounts (date, then id).
    static func majorityAccount(_ transactions: [Transaction]) -> Int64? {
        let counts = transactions.reduce(into: [Int64: Int]()) { $0[$1.accountId, default: 0] += 1 }
        guard let top = counts.values.max() else { return nil }
        let leaders = Set(counts.filter { $0.value == top }.keys)
        if leaders.count == 1 { return leaders.first }
        return transactions.filter { leaders.contains($0.accountId) }
            .max { ($0.date, $0.id ?? 0) < ($1.date, $1.id ?? 0) }?.accountId
    }

    public func inferredAccount(categoryId: Int64) -> Int64? {
        inferredByCategory[categoryId]
    }

    /// The account an item of the category goes to without one of its own: the inferred
    /// account, else the main account (nil = none).
    public func automaticAccount(categoryId: Int64) -> Int64? {
        inferredByCategory[categoryId] ?? mainAccountId
    }

    /// Whether the category's automatic account is the main account (no history to infer from).
    public func isMainFallback(categoryId: Int64) -> Bool {
        inferredByCategory[categoryId] == nil && mainAccountId != nil
    }

    /// The entry's explicit account, else its category's automatic one (nil = none).
    public func effectiveAccount(of entry: ForecastEntry) -> Int64? {
        entry.accountId ?? automaticAccount(categoryId: entry.categoryId)
    }

    /// Whether an item filed under `categoryId` may be assigned to `accountId` (Assign to ▾,
    /// budget-totals spec §2): not a transfer tied to that same account (it would pay itself).
    public func canAssign(categoryId: Int64, to accountId: Int64) -> Bool {
        tiedAccountByCategory[categoryId] != accountId
    }

    /// A planned occurrence as one account sees it.
    public struct Leg: Equatable {
        public let accountId: Int64?
        public let occurrence: PlannedOccurrence
        /// The incoming side of a planned transfer into a tied account (amount flipped,
        /// filed under the paying account's transfer category).
        public let isIncomingTransfer: Bool
    }

    /// The occurrence's legs: the occurrence itself on the paying (effective) account and,
    /// when its (possibly re-filed) category is a transfer tied to another account, the
    /// incoming leg on that account. `entry` is the occurrence's series.
    public func legs(of occurrence: PlannedOccurrence, entry: ForecastEntry?) -> [Leg] {
        let paying = entry.flatMap(effectiveAccount(of:))
        var legs = [Leg(accountId: paying, occurrence: occurrence, isIncomingTransfer: false)]
        if let tied = tiedAccountByCategory[occurrence.categoryId], tied != paying {
            let category = paying.flatMap { transferCategoryByAccount[$0] } ?? occurrence.categoryId
            let incoming = PlannedOccurrence(entryId: occurrence.entryId, originalDate: occurrence.originalDate, date: occurrence.date,
                                             categoryId: category, amountMinorUnits: -occurrence.amountMinorUnits, isException: occurrence.isException)
            legs.append(Leg(accountId: tied, occurrence: incoming, isIncomingTransfer: true))
        }
        return legs
    }

    /// The legs `accountIds` see: an occurrence whose paying account is selected as it is
    /// (an item with no effective account is hidden); an incoming planned transfer into a
    /// selected account only when its paying account isn't selected (once, as sent).
    public func legs(_ occurrences: [PlannedOccurrence], entries: [ForecastEntry], accountIds: Set<Int64>) -> [Leg] {
        let byId = Dictionary(entries.compactMap { e in e.id.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        return occurrences.flatMap { occurrence -> [Leg] in
            let legs = legs(of: occurrence, entry: byId[occurrence.entryId])
            let payingSelected = legs[0].accountId.map(accountIds.contains) ?? false
            if payingSelected { return [legs[0]] }
            return legs.dropFirst().filter { $0.accountId.map(accountIds.contains) ?? false }
        }
    }

    /// `legs(_:entries:accountIds:)`'s occurrences.
    public func occurrences(_ occurrences: [PlannedOccurrence], entries: [ForecastEntry], accountIds: Set<Int64>) -> [PlannedOccurrence] {
        legs(occurrences, entries: entries, accountIds: accountIds).map(\.occurrence)
    }
}

/// The Budget account filter applied to the plan: the selected accounts and how planned
/// items map to accounts. Pass nil (All accounts) wherever a filter is optional.
public struct PlanAccountFilter: Equatable, Sendable {
    public let accountIds: Set<Int64>
    public let itemAccounts: PlannedItemAccounts

    public init(accountIds: Set<Int64>, itemAccounts: PlannedItemAccounts) {
        self.accountIds = accountIds
        self.itemAccounts = itemAccounts
    }
}
