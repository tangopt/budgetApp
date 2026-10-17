import GRDB
import Foundation

public enum RentPaymentOrigin: String, Codable, CaseIterable, Sendable {
    /// Found by `RentReceiptMatching.match`.
    case auto
    /// Linked by the user.
    case manual
}

/// A bank credit that paid (part of) a rent receipt (spec 2026-10-16 §2). One receipt may be
/// paid by several credits and one credit may pay several receipts (advance rent). Tenant
/// transfers can exceed the rent because they carry utility recharges: that part of the
/// credit is `otherMinorUnits`.
public struct RentReceiptPayment: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var rentReceiptId: Int64
    public var transactionId: Int64
    /// The part of the credit that is this receipt's rent.
    public var rentMinorUnits: Int
    /// The rest of the credit attributed alongside it (recharges, other).
    public var otherMinorUnits: Int
    public var origin: RentPaymentOrigin
    /// An auto link the user removed: kept so matching never makes it again.
    public var isDismissed: Bool

    public init(id: Int64? = nil, rentReceiptId: Int64, transactionId: Int64, rentMinorUnits: Int, otherMinorUnits: Int = 0,
                origin: RentPaymentOrigin, isDismissed: Bool = false) {
        self.id = id
        self.rentReceiptId = rentReceiptId
        self.transactionId = transactionId
        self.rentMinorUnits = rentMinorUnits
        self.otherMinorUnits = otherMinorUnits
        self.origin = origin
        self.isDismissed = isDismissed
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "rentReceiptPayment"

    /// Links that count (not dismissed).
    public static var active: QueryInterfaceRequest<RentReceiptPayment> {
        filter(Column("isDismissed") == false)
    }
}

public enum RentPaymentError: Error, Equatable {
    case receiptNotFound
    case transactionNotFound
    /// Only credits (positive amounts) pay rent.
    case notACredit
    case negativeAmount
    case nothingAllocated
    /// The credit's links would exceed its amount.
    case overAllocated
    /// The rent would exceed what the receipt received.
    case exceedsReceipt
    /// Cancelled receipts take no payments.
    case receiptCancelled
}

/// Links rent receipts to the bank credits that paid them.
public enum RentReceiptMatching {
    public struct Options: Equatable, Sendable {
        /// Which credits are rent: these categories; `nil` = the income categories of the
        /// property's category groups ("Rental income").
        public var categoryIds: [Int64]?
        /// Where rent arrives; `nil` = the property's accounts with role `current`.
        public var accountIds: [Int64]?
        /// Days either side of the rent period's month (and of the receipt date) a credit may fall.
        public var windowDays: Int
        /// The largest recharge/other part a matched credit may carry beyond the rent, as a
        /// fraction of the rent received (0.5: a €1,000 receipt takes a credit of up to €1,500).
        /// Larger credits stay unmatched for review.
        public var maxOtherFraction: Double

        public init(categoryIds: [Int64]? = nil, accountIds: [Int64]? = nil, windowDays: Int = 10, maxOtherFraction: Double = 0.5) {
            self.categoryIds = categoryIds
            self.accountIds = accountIds
            self.windowDays = windowDays
            self.maxOtherFraction = maxOtherFraction
        }

        /// Whether `excess` beyond `rent` is within `maxOtherFraction` of it.
        func allowsOther(_ excess: Int, rent: Int) -> Bool {
            Double(excess) <= Double(rent) * maxOtherFraction
        }
    }

    public struct Result: Equatable, Sendable {
        /// Links made by this run.
        public var created: [RentReceiptPayment]
        /// Issued receipts whose rent isn't fully covered by linked credits.
        public var unmatchedReceipts: [RentReceipt]
        /// Rent credits not linked to any receipt.
        public var unmatchedCredits: [Transaction]
    }

    // MARK: Matching

    /// Links unpaid issued receipts of the property to unlinked rent credits, in passes:
    /// 1. one credit of exactly the amount received; 2. one credit paying exactly a run of
    /// back-to-back receipts of a tenancy (each period starting the day after the previous one
    /// ends; a run stops at a receipt already paid) — advance rent; 3. one larger credit (the
    /// excess is recharge/other, at most `maxOtherFraction` of the rent); 4. two or three credits
    /// that together cover it (the same cap on the excess, which is other on the last). Within a pass, the credit closest to the receipt date (else period start) wins.
    /// Credits must fall within the period-start month ± `windowDays` or the receipt date ±
    /// `windowDays`. Existing and dismissed links are left alone, so re-running is idempotent.
    @discardableResult
    public static func match(db: Database, propertyId: Int64, options: Options = Options()) throws -> Result {
        // What utility recharge links already take of a credit isn't rent: match the rest.
        let recharged = try rechargedByCredit(db: db)
        let credits = try candidateCredits(db: db, propertyId: propertyId, options: options).compactMap { credit -> Transaction? in
            var rest = credit
            rest.amountMinorUnits -= recharged[credit.id!] ?? 0
            return rest.amountMinorUnits > 0 ? rest : nil
        }
        let active = try RentReceiptPayment.active.fetchAll(db)
        let linkedTransactionIds = Set(active.map(\.transactionId))
        let linkedReceiptIds = Set(active.map(\.rentReceiptId))
        let dismissed = Set(try RentReceiptPayment.filter(Column("isDismissed") == true).fetchAll(db)
            .map { [$0.rentReceiptId, $0.transactionId] })
        let issued = try issuedReceipts(db: db, propertyId: propertyId)
        let windows = Dictionary(uniqueKeysWithValues: issued.map { ($0.id!, Window($0, options)) })
        func allowed(_ receipt: RentReceipt, _ credit: Transaction) -> Bool {
            !dismissed.contains([receipt.id!, credit.id!]) && windows[receipt.id!]!.contains(credit.date)
        }
        var freeCredits = credits.filter { !linkedTransactionIds.contains($0.id!) }
        var freeReceipts = issued.filter { !linkedReceiptIds.contains($0.id!) }
        var created: [RentReceiptPayment] = []

        func take(_ receipts: [RentReceipt], _ creditsUsed: [Transaction]) throws {
            var remaining = creditsUsed.map { (credit: $0, left: $0.amountMinorUnits) }
            for receipt in receipts {
                var need = receipt.amountReceivedMinorUnits
                for index in remaining.indices where need > 0 && remaining[index].left > 0 {
                    let rent = min(need, remaining[index].left)
                    need -= rent
                    remaining[index].left -= rent
                    var link = RentReceiptPayment(rentReceiptId: receipt.id!, transactionId: remaining[index].credit.id!,
                                                  rentMinorUnits: rent, origin: .auto)
                    try link.insert(db)
                    created.append(link)
                }
            }
            // What's left of the credits is other (recharges) on the last receipt's links.
            for entry in remaining where entry.left > 0 {
                if let index = created.lastIndex(where: { $0.transactionId == entry.credit.id! }) {
                    created[index].otherMinorUnits += entry.left
                    try created[index].update(db)
                } else if let last = receipts.last {
                    var link = RentReceiptPayment(rentReceiptId: last.id!, transactionId: entry.credit.id!, rentMinorUnits: 0,
                                                  otherMinorUnits: entry.left, origin: .auto)
                    try link.insert(db)
                    created.append(link)
                }
            }
            let usedCredits = Set(creditsUsed.map(\.id!))
            let usedReceipts = Set(receipts.map(\.id!))
            freeCredits.removeAll { usedCredits.contains($0.id!) }
            freeReceipts.removeAll { usedReceipts.contains($0.id!) }
        }

        func pairs(_ accept: (RentReceipt, Transaction) -> Bool) -> [(receipt: RentReceipt, credit: Transaction, key: Int)] {
            var result: [(RentReceipt, Transaction, Int)] = []
            for receipt in freeReceipts {
                for credit in freeCredits where allowed(receipt, credit) && accept(receipt, credit) {
                    result.append((receipt, credit, distance(credit, receipt)))
                }
            }
            return result.map { (receipt: $0.0, credit: $0.1, key: $0.2) }
        }

        func greedy(_ candidates: [(receipt: RentReceipt, credit: Transaction, key: Int)]) throws {
            let ordered = candidates.sorted {
                ($0.key, $0.receipt.periodStart, $0.credit.id!) < ($1.key, $1.receipt.periodStart, $1.credit.id!)
            }
            var usedReceipts: Set<Int64> = []
            var usedCredits: Set<Int64> = []
            for candidate in ordered where !usedReceipts.contains(candidate.receipt.id!) && !usedCredits.contains(candidate.credit.id!) {
                usedReceipts.insert(candidate.receipt.id!)
                usedCredits.insert(candidate.credit.id!)
                try take([candidate.receipt], [candidate.credit])
            }
        }

        // 1. Exact amount.
        try greedy(pairs { $0.amountReceivedMinorUnits == $1.amountMinorUnits })

        // 2. One credit, a run of back-to-back receipts of one tenancy, exactly. Runs are laid
        // out over every issued receipt, so a gap or an already-paid receipt ends them.
        let byTenancy = Dictionary(grouping: issued, by: \.tenancyId).mapValues { $0.sorted { ($0.periodStart, $0.id!) < ($1.periodStart, $1.id!) } }
        for credit in freeCredits.sorted(by: { ($0.date, $0.id!) < ($1.date, $1.id!) }) {
            var done = false
            for tenancyId in byTenancy.keys.sorted() where !done {
                let receipts = byTenancy[tenancyId]!
                let free = Set(freeReceipts.map(\.id!))
                for start in receipts.indices where !done && free.contains(receipts[start].id!) && allowed(receipts[start], credit) {
                    var total = 0
                    for end in start..<min(receipts.count, start + 12) {
                        if end > start {
                            let previous = receipts[end - 1], next = receipts[end]
                            guard free.contains(next.id!), !dismissed.contains([next.id!, credit.id!]),
                                  next.periodStart == PropertyDates.nextDay(previous.periodEnd) else { break }
                        }
                        total += receipts[end].amountReceivedMinorUnits
                        if total > credit.amountMinorUnits { break }
                        if total == credit.amountMinorUnits && end > start {
                            try take(Array(receipts[start...end]), [credit])
                            done = true
                            break
                        }
                    }
                }
            }
        }

        // 3. One larger credit: smallest excess first, then closest.
        let larger = pairs {
            $1.amountMinorUnits > $0.amountReceivedMinorUnits
                && options.allowsOther($1.amountMinorUnits - $0.amountReceivedMinorUnits, rent: $0.amountReceivedMinorUnits)
        }.map {
            (receipt: $0.receipt, credit: $0.credit, key: ($0.credit.amountMinorUnits - $0.receipt.amountReceivedMinorUnits) * 1_000 + $0.key)
        }
        try greedy(larger)

        // 4. Two or three smaller credits that together cover the receipt.
        for receipt in freeReceipts.sorted(by: { $0.periodStart < $1.periodStart }) {
            let need = receipt.amountReceivedMinorUnits
            let window = freeCredits.filter { allowed(receipt, $0) && $0.amountMinorUnits < need }
                .sorted { ($0.date, $0.id!) < ($1.date, $1.id!) }
            var best: (credits: [Transaction], excess: Int, spread: Int)?
            func consider(_ combo: [Transaction]) {
                let sum = combo.reduce(0) { $0 + $1.amountMinorUnits }
                guard sum >= need else { return }
                let excess = sum - need
                guard options.allowsOther(excess, rent: need) else { return }
                let spread = combo.map { distance($0, receipt) }.reduce(0, +)
                if best.map({ (excess, spread) < ($0.excess, $0.spread) }) ?? true { best = (combo, excess, spread) }
            }
            for i in window.indices {
                for j in window.indices where j > i {
                    consider([window[i], window[j]])
                    for k in window.indices where k > j { consider([window[i], window[j], window[k]]) }
                }
            }
            if let best { try take([receipt], best.credits) }
        }

        return Result(created: created,
                      unmatchedReceipts: try unmatchedReceipts(db: db, propertyId: propertyId),
                      unmatchedCredits: try unmatchedCredits(db: db, propertyId: propertyId, options: options))
    }

    /// When a receipt's credit may fall: the period-start month ± `windowDays`, or the receipt
    /// date ± `windowDays` (both whole days, half-open ranges).
    struct Window {
        let ranges: [(from: Date, to: Date)]

        init(_ receipt: RentReceipt, _ options: Options) {
            let calendar = MonthRange.calendar
            let (year, month) = MonthRange.components(of: receipt.periodStart)
            let monthStart = MonthRange.of(year: year, month: month).start
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            var ranges = [(calendar.date(byAdding: .day, value: -options.windowDays, to: monthStart)!,
                           calendar.date(byAdding: .day, value: options.windowDays, to: monthEnd)!)]
            if let receiptDate = receipt.receiptDate {
                ranges.append((calendar.date(byAdding: .day, value: -options.windowDays, to: receiptDate)!,
                               calendar.date(byAdding: .day, value: options.windowDays + 1, to: receiptDate)!))
            }
            self.ranges = ranges.map { (from: $0.0, to: $0.1) }
        }

        func contains(_ date: Date) -> Bool {
            let day = PropertyDates.day(date)
            return ranges.contains { $0.from <= day && day < $0.to }
        }
    }

    /// Whether the credit's day falls in the receipt's window.
    static func inWindow(_ credit: Transaction, _ receipt: RentReceipt, _ options: Options) -> Bool {
        Window(receipt, options).contains(credit.date)
    }

    /// Days between the credit and the receipt date (else the period start).
    static func distance(_ credit: Transaction, _ receipt: RentReceipt) -> Int {
        let expected = receipt.receiptDate ?? receipt.periodStart
        return abs(MonthRange.calendar.dateComponents([.day], from: expected, to: PropertyDates.day(credit.date)).day ?? 0)
    }

    // MARK: Reading

    /// The credits that count as rent for the property, oldest first: only on accounts in the
    /// property's currency (receipts are in it).
    public static func candidateCredits(db: Database, propertyId: Int64, options: Options = Options()) throws -> [Transaction] {
        guard let property = try Property.fetchOne(db, key: propertyId) else { return [] }
        let requested = try options.accountIds
            ?? Properties.accounts(db: db, propertyId: propertyId, role: .current).map(\.accountId)
        let sameCurrency = Set(try Account.filter(requested.contains(Column("id")) && Column("currency") == property.currency.rawValue)
            .fetchAll(db).compactMap(\.id))
        let accountIds = requested.filter(sameCurrency.contains)
        let categoryIds = try options.categoryIds ?? Int64.fetchAll(db, sql: """
            SELECT category.id FROM category JOIN propertyCategoryGroup ON propertyCategoryGroup.categoryGroupId = category.groupId
            WHERE propertyCategoryGroup.propertyId = ? AND category.type = ?
            """, arguments: [propertyId, CategoryType.income.rawValue])
        guard !accountIds.isEmpty, !categoryIds.isEmpty else { return [] }
        return try Transaction
            .filter(accountIds.contains(Column("accountId")) && categoryIds.contains(Column("categoryId")) && Column("amountMinorUnits") > 0)
            .order(Column("date"), Column("id"))
            .fetchAll(db)
    }

    private static func issuedReceipts(db: Database, propertyId: Int64) throws -> [RentReceipt] {
        try RentReceipt.fetchAll(db, sql: """
            SELECT rentReceipt.* FROM rentReceipt JOIN tenancy ON tenancy.id = rentReceipt.tenancyId
            WHERE tenancy.propertyId = ? AND rentReceipt.status = ?
            ORDER BY rentReceipt.periodStart, rentReceipt.id
            """, arguments: [propertyId, RentReceiptStatus.issued.rawValue])
    }

    /// Issued receipts of the property whose active links cover less rent than they received.
    public static func unmatchedReceipts(db: Database, propertyId: Int64) throws -> [RentReceipt] {
        let covered = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
            SELECT rentReceiptId, SUM(rentMinorUnits) FROM rentReceiptPayment WHERE isDismissed = 0 GROUP BY rentReceiptId
            """).map { ($0[0] as Int64, $0[1] as Int) })
        return try issuedReceipts(db: db, propertyId: propertyId).filter { (covered[$0.id!] ?? 0) < $0.amountReceivedMinorUnits }
    }

    /// Rent credits of the property with no active link, oldest first (credits wholly taken by
    /// utility recharge links aren't rent).
    public static func unmatchedCredits(db: Database, propertyId: Int64, options: Options = Options()) throws -> [Transaction] {
        let linked = Set(try Int64.fetchAll(db, sql: "SELECT transactionId FROM rentReceiptPayment WHERE isDismissed = 0"))
        let recharged = try rechargedByCredit(db: db)
        return try candidateCredits(db: db, propertyId: propertyId, options: options)
            .filter { !linked.contains($0.id!) && (recharged[$0.id!] ?? 0) < $0.amountMinorUnits }
    }

    /// The recharge statement links' total per credit.
    static func rechargedByCredit(db: Database) throws -> [Int64: Int] {
        Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
            SELECT transactionId, SUM(amountMinorUnits) FROM rechargePayment WHERE isDismissed = 0 GROUP BY transactionId
            """).map { ($0[0] as Int64, $0[1] as Int) })
    }

    /// The receipt's active payment links, oldest credit first.
    public static func payments(db: Database, receiptId: Int64) throws -> [RentReceiptPayment] {
        try RentReceiptPayment.fetchAll(db, sql: """
            SELECT p.* FROM rentReceiptPayment p JOIN transaction_ t ON t.id = p.transactionId
            WHERE p.rentReceiptId = ? AND p.isDismissed = 0 ORDER BY t.date, p.id
            """, arguments: [receiptId])
    }

    /// The credit's active payment links, by rent period.
    public static func payments(db: Database, transactionId: Int64) throws -> [RentReceiptPayment] {
        try RentReceiptPayment.fetchAll(db, sql: """
            SELECT p.* FROM rentReceiptPayment p JOIN rentReceipt r ON r.id = p.rentReceiptId
            WHERE p.transactionId = ? AND p.isDismissed = 0 ORDER BY r.periodStart, p.id
            """, arguments: [transactionId])
    }

    // MARK: Editing

    /// Links a credit to a receipt by hand (or replaces the amounts of an existing link,
    /// reviving a dismissed one as manual). The credit's links can't exceed its amount; `rent`
    /// defaults to what the receipt still needs, capped by what's left of the credit, and
    /// `other` to nothing.
    @discardableResult
    public static func link(db: Database, receiptId: Int64, transactionId: Int64, rentMinorUnits: Int? = nil,
                            otherMinorUnits: Int = 0) throws -> RentReceiptPayment {
        guard let receipt = try RentReceipt.fetchOne(db, key: receiptId) else { throw RentPaymentError.receiptNotFound }
        guard receipt.status == .issued else { throw RentPaymentError.receiptCancelled }
        guard let credit = try Transaction.fetchOne(db, key: transactionId) else { throw RentPaymentError.transactionNotFound }
        guard credit.amountMinorUnits > 0 else { throw RentPaymentError.notACredit }
        let existing = try RentReceiptPayment.filter(Column("rentReceiptId") == receiptId && Column("transactionId") == transactionId).fetchOne(db)
        let othersOnCredit = try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(rentMinorUnits + otherMinorUnits), 0) FROM rentReceiptPayment
            WHERE transactionId = ? AND isDismissed = 0 AND rentReceiptId != ?
            """, arguments: [transactionId, receiptId]) ?? 0
        let coveredOnReceipt = try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(rentMinorUnits), 0) FROM rentReceiptPayment
            WHERE rentReceiptId = ? AND isDismissed = 0 AND transactionId != ?
            """, arguments: [receiptId, transactionId]) ?? 0
        let rechargedOnCredit = try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amountMinorUnits), 0) FROM rechargePayment WHERE transactionId = ? AND isDismissed = 0
            """, arguments: [transactionId]) ?? 0
        let creditLeft = credit.amountMinorUnits - othersOnCredit - rechargedOnCredit
        let rent = rentMinorUnits ?? max(0, min(receipt.amountReceivedMinorUnits - coveredOnReceipt, creditLeft - otherMinorUnits))
        guard rent >= 0, otherMinorUnits >= 0 else { throw RentPaymentError.negativeAmount }
        guard rent + otherMinorUnits > 0 else { throw RentPaymentError.nothingAllocated }
        guard rent + otherMinorUnits <= creditLeft else { throw RentPaymentError.overAllocated }
        guard rent <= receipt.amountReceivedMinorUnits - coveredOnReceipt else { throw RentPaymentError.exceedsReceipt }
        var link = existing ?? RentReceiptPayment(rentReceiptId: receiptId, transactionId: transactionId, rentMinorUnits: rent, origin: .manual)
        link.rentMinorUnits = rent
        link.otherMinorUnits = otherMinorUnits
        link.origin = .manual
        link.isDismissed = false
        try link.save(db)
        return link
    }

    /// Removes the link; an auto link is kept dismissed so matching doesn't make it again.
    /// `false` when there was no active link.
    @discardableResult
    public static func unlink(db: Database, receiptId: Int64, transactionId: Int64) throws -> Bool {
        guard var link = try RentReceiptPayment.active
            .filter(Column("rentReceiptId") == receiptId && Column("transactionId") == transactionId).fetchOne(db) else { return false }
        if link.origin == .auto {
            link.isDismissed = true
            try link.update(db)
        } else {
            try link.delete(db)
        }
        return true
    }

    /// Drops the auto links of a receipt (it was cancelled); manual and dismissed ones stay.
    /// Returns how many went.
    @discardableResult
    static func removeAutoLinks(db: Database, receiptId: Int64) throws -> Int {
        try RentReceiptPayment.filter(Column("rentReceiptId") == receiptId && Column("origin") == RentPaymentOrigin.auto.rawValue
                                      && Column("isDismissed") == false).deleteAll(db)
    }
}

func registerRentReceiptPaymentMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createRentReceiptPayment") { db in
        try db.create(table: "rentReceiptPayment") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("rentReceiptId", .integer).notNull().references("rentReceipt", onDelete: .cascade)
            t.column("transactionId", .integer).notNull().indexed().references("transaction_", onDelete: .cascade)
            t.column("rentMinorUnits", .integer).notNull()
            t.column("otherMinorUnits", .integer).notNull().defaults(to: 0)
            t.column("origin", .text).notNull()
            t.column("isDismissed", .boolean).notNull().defaults(to: false)
            t.uniqueKey(["rentReceiptId", "transactionId"])
        }
    }
}
