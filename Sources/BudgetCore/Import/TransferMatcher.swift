import Foundation
import GRDB

/// One transaction as the matcher sees it. Staged import rows use negative ids.
public struct TransferLeg: Equatable, Sendable {
    public let id: Int64
    public let accountId: Int64
    public let date: Date
    /// Signed: < 0 sent, > 0 received.
    public let amountMinorUnits: Int
    /// A spreadsheet-history row (a monthly category total dated on payday, from a `.numbers`
    /// import): it matches by pay month and exact sums instead of by day.
    public let isHistorical: Bool
    /// Uncategorised or in a transfer category: only such received money can be part of a
    /// historical monthly total (an exact sum over salaries and refunds is a coincidence).
    public let isTransferLike: Bool

    public init(id: Int64, accountId: Int64, date: Date, amountMinorUnits: Int, isHistorical: Bool = false, isTransferLike: Bool = true) {
        self.id = id
        self.accountId = accountId
        self.date = date
        self.amountMinorUnits = amountMinorUnits
        self.isHistorical = isHistorical
        self.isTransferLike = isTransferLike
    }
}

public struct TransferPair: Hashable, Sendable {
    public let outId: Int64
    public let inId: Int64

    public init(outId: Int64, inId: Int64) {
        self.outId = outId
        self.inId = inId
    }
}

/// The other leg of a transfer a staged import row matches (the review's
/// "↔ Transfer from <account>, <date>" badge).
public struct StagedTransfer: Equatable, Sendable {
    public let otherTransactionId: Int64
    public let otherAccountName: String
    public let otherDate: Date
    public let otherAmountMinorUnits: Int
    public let otherCategoryId: Int64?
    /// The staged row receives the money ("from"); false when it sends it ("to").
    public let isIncoming: Bool

    public init(otherTransactionId: Int64, otherAccountName: String, otherDate: Date, otherAmountMinorUnits: Int, otherCategoryId: Int64?, isIncoming: Bool) {
        self.otherTransactionId = otherTransactionId
        self.otherAccountName = otherAccountName
        self.otherDate = otherDate
        self.otherAmountMinorUnits = otherAmountMinorUnits
        self.otherCategoryId = otherCategoryId
        self.isIncoming = isIncoming
    }
}

/// Auto-matching of transfers between the user's own accounts (spec §6).
///
/// - **Bank rows:** an outgoing transaction in account A and an incoming one in account B ≠ A,
///   dated within ±3 days; equal amounts in the same currency, within ±3% after conversion at
///   the stored exchange rate otherwise. The closest dates win; exact ties stay unmatched.
/// - **Historical rows** (spreadsheet monthly totals, out only): incoming transactions in one
///   other account within the same pay month — a single one of equal amount, or the smallest
///   set summing exactly to it; more than one such set stays unmatched. Only received money
///   that's uncategorised or in a transfer category takes part.
///
/// Each incoming transaction joins at most one link, a bank outgoing one at most one. Never
/// considered: transactions already in a link (active or dismissed), any in an
/// external-transfer category (`Category.isExternalTransfer`) on either leg, and money sent
/// that's filed under an income or expense category (a transfer is sent from a transfer
/// category, or not yet categorised — so a spreadsheet Groceries total never matches).
public enum TransferMatcher {
    public static let dayWindow: TimeInterval = 3 * 86_400
    public static let fxTolerance = 0.03

    // MARK: Database

    /// Links every new match (origin `auto`); returns how many. Idempotent: linked legs are
    /// never considered again. Runs inside an import's commit and once at launch.
    @discardableResult
    public static func match(db: Database, today: Date = Date()) throws -> Int {
        let context = try Context(db: db, today: today)
        let legs = try Transaction.fetchAll(db).compactMap(context.leg(for:))
        let found = pairs(legs: legs, currencies: context.currencies, eurToGbpRate: context.rate, calendar: context.calendar)
        for pair in found {
            var link = TransferLink(outTransactionId: pair.outId, inTransactionId: pair.inId, origin: .auto)
            try link.insert(db)
        }
        return found.count
    }

    /// What `match` would link each staged row (of `accountId`, not yet saved) to, among the
    /// saved transactions; keyed by the row's index in `staged`. `categoryId` is the row's
    /// suggested or chosen category (an external-transfer one is never matched).
    public static func stagedMatches(db: Database, accountId: Int64, staged: [(date: Date, amountMinorUnits: Int, categoryId: Int64?)], today: Date = Date()) throws -> [Int: StagedTransfer] {
        let context = try Context(db: db, today: today)
        let saved = try Transaction.fetchAll(db)
        var legs = saved.compactMap(context.leg(for:))
        for (index, row) in staged.enumerated() where row.amountMinorUnits != 0 && context.canMatch(amount: row.amountMinorUnits, categoryId: row.categoryId) {
            legs.append(TransferLeg(id: -Int64(index) - 1, accountId: accountId, date: row.date, amountMinorUnits: row.amountMinorUnits,
                                    isTransferLike: context.isTransferLike(row.categoryId)))
        }
        let byId = Dictionary(saved.compactMap { t in t.id.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
        let accountNames = Dictionary(try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a.displayName) } }, uniquingKeysWith: { a, _ in a })
        var result: [Int: StagedTransfer] = [:]
        for pair in pairs(legs: legs, currencies: context.currencies, eurToGbpRate: context.rate, calendar: context.calendar) {
            let stagedId = pair.outId < 0 ? pair.outId : pair.inId
            let otherId = pair.outId < 0 ? pair.inId : pair.outId
            guard stagedId < 0, otherId > 0, let other = byId[otherId] else { continue }
            let index = Int(-stagedId - 1)
            guard result[index] == nil else { continue }
            result[index] = StagedTransfer(otherTransactionId: otherId, otherAccountName: accountNames[other.accountId] ?? "another account",
                                           otherDate: other.date, otherAmountMinorUnits: other.amountMinorUnits,
                                           otherCategoryId: other.categoryId, isIncoming: pair.inId == stagedId)
        }
        return result
    }

    /// What the matcher reads besides the transactions.
    struct Context {
        let currencies: [Int64: Currency]
        let rate: Double
        let calendar: PayCalendar
        let externalCategoryIds: Set<Int64>
        let transferCategoryIds: Set<Int64>
        let historicalBatchIds: Set<Int64>
        let linkedIds: Set<Int64>

        init(db: Database, today: Date) throws {
            currencies = Dictionary(try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a.currency) } }, uniquingKeysWith: { a, _ in a })
            rate = try ExchangeRateSetting.currentOrDefault(db: db).eurToGbpRate
            calendar = try PayCalendar.load(db: db, today: today)
            externalCategoryIds = Set(try Int64.fetchAll(db, sql: "SELECT id FROM category WHERE isExternalTransfer = 1"))
            transferCategoryIds = Set(try Int64.fetchAll(db, sql: "SELECT id FROM category WHERE type = ?", arguments: [CategoryType.transfer.rawValue]))
            historicalBatchIds = Set(try ImportBatch.fetchAll(db).filter(TransferMatcher.isHistoricalSource).compactMap(\.id))
            let links = try TransferLink.fetchAll(db)
            linkedIds = Set(links.flatMap { [$0.outTransactionId, $0.inTransactionId] })
        }

        /// Not external; and money sent is uncategorised or in a transfer category.
        func canMatch(amount: Int, categoryId: Int64?) -> Bool {
            guard let categoryId else { return true }
            if externalCategoryIds.contains(categoryId) { return false }
            return amount > 0 || transferCategoryIds.contains(categoryId)
        }

        func isTransferLike(_ categoryId: Int64?) -> Bool {
            categoryId.map(transferCategoryIds.contains) ?? true
        }

        /// The transaction as a leg, or nil when it can't be matched.
        func leg(for transaction: Transaction) -> TransferLeg? {
            guard let id = transaction.id, transaction.amountMinorUnits != 0, !linkedIds.contains(id),
                  canMatch(amount: transaction.amountMinorUnits, categoryId: transaction.categoryId) else { return nil }
            return TransferLeg(id: id, accountId: transaction.accountId, date: transaction.date, amountMinorUnits: transaction.amountMinorUnits,
                               isHistorical: historicalBatchIds.contains(transaction.importBatchId),
                               isTransferLike: isTransferLike(transaction.categoryId))
        }
    }

    /// Spreadsheet history: the batch's source file is a Numbers document.
    public static func isHistoricalSource(_ batch: ImportBatch) -> Bool {
        batch.sourceFileName.lowercased().hasSuffix(".numbers")
    }

    // MARK: Matching

    /// Every match among `legs` (all eligible: unlinked, not external). Pure.
    public static func pairs(legs: [TransferLeg], currencies: [Int64: Currency], eurToGbpRate: Double, calendar: PayCalendar) -> [TransferPair] {
        let legs = legs.filter { currencies[$0.accountId] != nil }
        let ins = legs.filter { $0.amountMinorUnits > 0 && !$0.isHistorical }.sorted { $0.date < $1.date }
        let bankOuts = legs.filter { $0.amountMinorUnits < 0 && !$0.isHistorical }
        var result = bankPairs(outs: bankOuts, ins: ins, currencies: currencies, rate: eurToGbpRate)
        var used = Set(result.map(\.inId))
        let historicalOuts = legs.filter { $0.amountMinorUnits < 0 && $0.isHistorical }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        for out in historicalOuts {
            let found = historicalSet(for: out, ins: ins.filter { !used.contains($0.id) }, currencies: currencies, calendar: calendar)
            for inLeg in found {
                result.append(TransferPair(outId: out.id, inId: inLeg.id))
                used.insert(inLeg.id)
            }
        }
        return result
    }

    /// Whether `inAmount` received is `outAmount` sent, across currencies within `fxTolerance`.
    static func amountsMatch(_ outAmount: Int, _ outCurrency: Currency, _ inAmount: Int, _ inCurrency: Currency, rate: Double) -> Bool {
        let sent = abs(outAmount), received = abs(inAmount)
        if outCurrency == inCurrency { return sent == received }
        let converted = convert(Double(sent), from: outCurrency, to: inCurrency, rate: rate)
        return abs(Double(received) - converted) <= converted * fxTolerance
    }

    static func convert(_ amount: Double, from: Currency, to: Currency, rate: Double) -> Double {
        switch (from, to) {
        case (.eur, .gbp): return amount * rate
        case (.gbp, .eur): return rate == 0 ? amount : amount / rate
        default: return amount
        }
    }

    /// Bank pairs, closest dates first: at each distance, an edge links when both its legs
    /// have no other edge at that distance; legs with several are ties and stay unmatched.
    private static func bankPairs(outs: [TransferLeg], ins: [TransferLeg], currencies: [Int64: Currency], rate: Double) -> [TransferPair] {
        var edges: [(out: Int64, in: Int64, distance: TimeInterval)] = []
        let inDates = ins.map(\.date)
        for out in outs {
            let outCurrency = currencies[out.accountId]!
            var index = lowerBound(inDates, out.date.addingTimeInterval(-dayWindow))
            while index < ins.count, ins[index].date <= out.date.addingTimeInterval(dayWindow) {
                let candidate = ins[index]
                index += 1
                guard candidate.accountId != out.accountId,
                      amountsMatch(out.amountMinorUnits, outCurrency, candidate.amountMinorUnits, currencies[candidate.accountId]!, rate: rate) else { continue }
                edges.append((out.id, candidate.id, abs(candidate.date.timeIntervalSince(out.date))))
            }
        }
        var assigned = Set<Int64>(), blocked = Set<Int64>()
        var result: [TransferPair] = []
        let byDistance = Dictionary(grouping: edges, by: \.distance)
        for distance in byDistance.keys.sorted() {
            let open = byDistance[distance]!.filter { edge in
                ![edge.out, edge.in].contains { assigned.contains($0) || blocked.contains($0) }
            }
            var outCounts: [Int64: Int] = [:], inCounts: [Int64: Int] = [:]
            for edge in open { outCounts[edge.out, default: 0] += 1; inCounts[edge.in, default: 0] += 1 }
            for edge in open {
                if outCounts[edge.out] == 1 && inCounts[edge.in] == 1 {
                    result.append(TransferPair(outId: edge.out, inId: edge.in))
                    assigned.formUnion([edge.out, edge.in])
                } else {
                    blocked.formUnion([edge.out, edge.in])
                }
            }
        }
        return result.sorted { ($0.outId, $0.inId) < ($1.outId, $1.inId) }
    }

    private static func lowerBound(_ dates: [Date], _ date: Date) -> Int {
        var low = 0, high = dates.count
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] < date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The incoming legs a historical monthly total is: in one other account of the same
    /// currency, within its pay month, the smallest set summing exactly to it — only when
    /// exactly one set of that size exists across every account.
    private static func historicalSet(for out: TransferLeg, ins: [TransferLeg], currencies: [Int64: Currency], calendar: PayCalendar) -> [TransferLeg] {
        let target = -out.amountMinorUnits
        let range = calendar.range(of: calendar.month(containing: out.date))
        let currency = currencies[out.accountId]
        let candidates = ins.filter {
            $0.isTransferLike && $0.accountId != out.accountId && currencies[$0.accountId] == currency
                && $0.date >= range.start && $0.date <= range.end && $0.amountMinorUnits <= target
        }
        var best: (size: Int, count: Int, legs: [TransferLeg])?
        for (_, legs) in Dictionary(grouping: candidates, by: \.accountId) {
            guard let found = smallestExactSum(legs.map(\.amountMinorUnits), target: target) else { continue }
            if best == nil || found.size < best!.size {
                best = (found.size, found.count, found.indices.map { legs[$0] })
            } else if found.size == best!.size {
                best!.count += found.count
            }
        }
        guard let best, best.count == 1 else { return [] }
        return best.legs
    }

    /// Beyond this many steps (amounts × target) a search is skipped, leaving the row unmatched,
    /// so a launch never stalls on a huge month.
    static let maximumSumWork = 40_000_000

    /// The fewest of `amounts` summing to `target` (amounts ≤ 0 or above it never take part),
    /// how many distinct subsets of that size do (capped at 2), and one of them as indices into
    /// `amounts` (the only one when `count` is 1). Nil when none does (or the search is too big).
    static func smallestExactSum(_ amounts: [Int], target: Int) -> (size: Int, count: Int, indices: [Int])? {
        let items = amounts.indices.filter { amounts[$0] > 0 && amounts[$0] <= target }
        guard target > 0, !items.isEmpty, items.reduce(0, { $0 + amounts[$1] }) >= target,
              items.count.multipliedReportingOverflow(by: target + 1).partialValue <= maximumSumWork else { return nil }
        // Per reachable sum: the fewest items (255 = unreachable) and subsets with that many (≤ 2).
        let unreachable: UInt8 = .max
        let width = target + 1
        var size = [UInt8](repeating: unreachable, count: width)
        var count = [UInt8](repeating: 0, count: width)
        // took[item][sum]: the item is in the best subset for `sum` once it's been considered
        // (bit set), for rebuilding the subset backwards. Bounded by `maximumSumWork` bits.
        var took = [UInt64](repeating: 0, count: (items.count * width + 63) / 64)
        size[0] = 0
        count[0] = 1
        for (position, item) in items.enumerated() {
            let amount = amounts[item]
            var sum = target
            while sum >= amount {
                let from = size[sum - amount]
                if from < unreachable - 1 {
                    let candidate = from + 1
                    if candidate < size[sum] {
                        size[sum] = candidate
                        count[sum] = count[sum - amount]
                        let bit = position * width + sum
                        took[bit / 64] |= 1 << UInt64(bit % 64)
                    } else if candidate == size[sum] {
                        count[sum] = min(2, count[sum] + count[sum - amount])
                    }
                }
                sum -= 1
            }
        }
        guard size[target] != unreachable else { return nil }
        var indices: [Int] = []
        var sum = target
        for position in items.indices.reversed() where sum > 0 {
            let bit = position * width + sum
            if took[bit / 64] & (1 << UInt64(bit % 64)) != 0 {
                indices.append(items[position])
                sum -= amounts[items[position]]
            }
        }
        return (Int(size[target]), Int(count[target]), indices.reversed())
    }
}
