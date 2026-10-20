import Foundation
import GRDB

/// The legs a BBVA Portugal "extrato global" adds beyond its current-account rows, shared by the
/// earlier-history import (`BBVAEarlierHistoryImport`) and the in-app statement reader:
///
/// - **Mortgage**: each instalment debit paired with the receipt the statement settled
///   (COBRANÇAS EFECTUADAS), then its leg on the loan (+total, the other side of the −total
///   debit) and the "Mortgage interest (instalment N)" row of −charges, so the loan moves by
///   +capital (capital = total − charges).
/// - **Fund**: each subscription debit paired with the fund movement of its amount (closest day
///   within `BBVAEarlierHistoryImport.fundPairingDays`), then its leg on the fund; and the Market
///   movement at the period end that makes the fund's balance equal the statement's value.
public enum BBVAStatementLegs {
    // MARK: Matching (pure)

    public struct InstalmentMatch: Equatable, Sendable {
        public let movementIndex: Int
        public let receipt: BBVAStatementParser.LoanReceipt

        public init(movementIndex: Int, receipt: BBVAStatementParser.LoanReceipt) {
            self.movementIndex = movementIndex
            self.receipt = receipt
        }
    }

    public struct FundPair: Equatable, Sendable {
        public let movementIndex: Int
        public let fundMovement: BBVAStatementParser.FundMovement

        public init(movementIndex: Int, fundMovement: BBVAStatementParser.FundMovement) {
            self.movementIndex = movementIndex
            self.fundMovement = fundMovement
        }
    }

    /// Whether a movement is a mortgage instalment: its description matches
    /// `BBVAFundMortgageImport.instalmentRulePattern` as that saved `.contains` rule does
    /// (`RuleMatcher`: the description or its merchant key, ignoring case), so
    /// "COBR. REC. TOT 000 00-000000-0" is one.
    public static func isInstalment(_ description: String) -> Bool {
        let pattern = BBVAFundMortgageImport.instalmentRulePattern
        return description.range(of: pattern, options: .caseInsensitive) != nil
            || MerchantKey.make(description).range(of: pattern, options: .caseInsensitive) != nil
    }

    /// Pairs the instalment movements with the receipts: by receipt number, each takes the first
    /// unclaimed instalment of its operation day and −total.
    public static func matchInstalments(movements: [BBVAStatementParser.Movement], receipts: [BBVAStatementParser.LoanReceipt])
        -> (matches: [InstalmentMatch], movementsWithoutReceipt: [Int], receiptsWithoutMovement: [BBVAStatementParser.LoanReceipt]) {
        matchInstalments(movements: movements, candidates: movements.indices.filter { isInstalment(movements[$0].description) }, receipts: receipts)
    }

    /// `matchInstalments` over the given candidate rows (the earlier-history import's are its
    /// plan's classification, not the description).
    static func matchInstalments(movements: [BBVAStatementParser.Movement], candidates: [Int], receipts: [BBVAStatementParser.LoanReceipt])
        -> (matches: [InstalmentMatch], movementsWithoutReceipt: [Int], receiptsWithoutMovement: [BBVAStatementParser.LoanReceipt]) {
        var unclaimed = candidates
        var matches: [InstalmentMatch] = []
        var orphans: [BBVAStatementParser.LoanReceipt] = []
        for receipt in receipts.sorted(by: { $0.number < $1.number }) {
            guard let position = unclaimed.firstIndex(where: { movements[$0].date == receipt.operationDate && movements[$0].amountMinorUnits == -receipt.totalMinorUnits }) else {
                orphans.append(receipt)
                continue
            }
            matches.append(InstalmentMatch(movementIndex: unclaimed.remove(at: position), receipt: receipt))
        }
        return (matches, unclaimed, orphans)
    }

    /// Pairs each fund movement (in order) with the unpaired subscription debit of its amount
    /// within `pairingDays`, the closest day winning (the earlier row on a tie).
    public static func pairFundMovements(movements: [BBVAStatementParser.Movement], fund: BBVAStatementParser.Fund?,
                                         pairingDays: Int = BBVAEarlierHistoryImport.fundPairingDays)
        -> (pairs: [FundPair], unpairedSubscriptions: [Int], unpairedFundMovements: [BBVAStatementParser.FundMovement]) {
        let candidates = movements.indices.filter { BBVAFundMortgageImport.isSubscription(movements[$0].description) && movements[$0].amountMinorUnits < 0 }
        return pairFundMovements(movements: movements, candidates: candidates, fundMovements: fund?.movements ?? [], pairingDays: pairingDays)
    }

    /// `pairFundMovements` over the given candidate rows and fund movements.
    static func pairFundMovements(movements: [BBVAStatementParser.Movement], candidates: [Int], fundMovements: [BBVAStatementParser.FundMovement], pairingDays: Int)
        -> (pairs: [FundPair], unpairedSubscriptions: [Int], unpairedFundMovements: [BBVAStatementParser.FundMovement]) {
        var unpaired = candidates
        var pairs: [FundPair] = []
        var orphans: [BBVAStatementParser.FundMovement] = []
        let window: TimeInterval = Double(pairingDays) * 86_400
        for fundMovement in fundMovements {
            func distance(_ index: Int) -> TimeInterval { abs(movements[index].date.timeIntervalSince(fundMovement.date)) }
            let options = unpaired.filter { movements[$0].amountMinorUnits == -fundMovement.amountMinorUnits && distance($0) <= window }
            guard let best = options.min(by: { distance($0) < distance($1) }) else {
                orphans.append(fundMovement)
                continue
            }
            unpaired.removeAll { $0 == best }
            pairs.append(FundPair(movementIndex: best, fundMovement: fundMovement))
        }
        return (pairs, unpaired, orphans)
    }

    /// What an instalment costs beyond capital: interest + fees + late interest + taxes.
    public static func charges(_ receipt: BBVAStatementParser.LoanReceipt) -> Int {
        receipt.interestMinorUnits + receipt.feesMinorUnits + receipt.lateInterestMinorUnits + receipt.taxesMinorUnits
    }

    // MARK: Writes

    /// The instalment's leg on the loan (the other side of its debit) and, when it has charges,
    /// the "Mortgage interest (instalment N)" row of −charges in `interestCategoryId`, with the
    /// split as its note (`BBVAFundMortgageImport.note(for:)`).
    @discardableResult
    public static func addInstalment(db: Database, instalmentRowId: Int64, receipt: BBVAStatementParser.LoanReceipt, loanAccountId: Int64,
                                     interestCategoryId: Int64) throws -> (leg: Transaction, interest: Transaction?) {
        let leg = try ManualTransactions.addOtherSide(db: db, transactionId: instalmentRowId, accountId: loanAccountId)
        let charges = charges(receipt)
        guard charges != 0 else { return (leg, nil) }
        let interest = try ManualTransactions.add(db: db, accountId: loanAccountId, date: receipt.operationDate,
                                                  description: "\(BBVAFundMortgageImport.interestCategoryName) (instalment \(receipt.number))",
                                                  amountMinorUnits: -charges, categoryId: interestCategoryId, note: BBVAFundMortgageImport.note(for: resolved(receipt)))
        return (leg, interest)
    }

    /// The expense category the instalments' interest rows go to (`BBVAFundMortgageImport.interestCategoryName`).
    public static func interestCategoryId(db: Database) throws -> Int64? {
        try Category.filter(Column("name") == BBVAFundMortgageImport.interestCategoryName).order(Column("id")).fetchOne(db)?.id
    }

    /// Replaces an estimated interest row ("Mortgage interest (derived)", `BBVAFundMortgageImport`)
    /// with the receipt's split: the "Mortgage interest (instalment N)" row of −charges with the
    /// receipt's note, same day and category (removed when the receipt has no charges).
    public static func replaceEstimate(db: Database, transactionId: Int64, receipt: BBVAStatementParser.LoanReceipt) throws {
        guard let row = try Transaction.fetchOne(db, key: transactionId) else { throw ManualTransactionError.transactionNotFound }
        let charges = charges(receipt)
        guard charges != 0 else {
            try ManualTransactions.delete(db: db, id: transactionId)
            return
        }
        try ManualTransactions.update(db: db, id: transactionId, date: receipt.operationDate,
                                      description: "\(BBVAFundMortgageImport.interestCategoryName) (instalment \(receipt.number))",
                                      amountMinorUnits: -charges, accountId: row.accountId, categoryId: row.categoryId,
                                      note: BBVAFundMortgageImport.note(for: resolved(receipt)))
    }

    /// The receipt as the fund/mortgage import's resolved instalment (for its note).
    static func resolved(_ receipt: BBVAStatementParser.LoanReceipt) -> BBVAFundMortgageImport.ResolvedInstalment {
        BBVAFundMortgageImport.ResolvedInstalment(
            instalment: BBVAFundMortgageImport.Instalment(date: receipt.operationDate, valueDate: receipt.valueDate, totalMinorUnits: receipt.totalMinorUnits, breakdown: nil),
            capitalMinorUnits: receipt.capitalMinorUnits, interestMinorUnits: receipt.interestMinorUnits + receipt.lateInterestMinorUnits,
            feesMinorUnits: receipt.feesMinorUnits, taxesMinorUnits: receipt.taxesMinorUnits, isEstimated: false, tan: receipt.tan,
            outstandingBeforeMinorUnits: receipt.outstandingAfterMinorUnits + receipt.capitalMinorUnits, receipt: receipt.number,
            source: "BBVA statement (COBRANÇAS EFECTUADAS)", remainingPayments: nil, residualMinorUnits: 0)
    }

    /// The subscription's leg on the fund (the other side of its debit).
    @discardableResult
    public static func addFundSubscription(db: Database, subscriptionRowId: Int64, fundAccountId: Int64) throws -> Transaction {
        try ManualTransactions.addOtherSide(db: db, transactionId: subscriptionRowId, accountId: fundAccountId)
    }

    /// The Market movement on the statement's `periodEnd` that makes the fund's balance equal the
    /// statement's value. The balance held is `openingMinorUnits` plus the fund's rows after
    /// `openingDay` through the period end when both are given, else the app's balance at the
    /// period end. Nil when the statement has no fund, the balance already equals the value, or
    /// a Market movement already exists on that account and day.
    public static func marketMovement(db: Database, fundAccountId: Int64, statement: BBVAStatementParser.Statement,
                                      since openingDay: Date?, openingMinorUnits: Int?) throws -> Transaction? {
        guard let value = statement.fund else { return nil }
        let market = try BuiltInCategories.category(db: db, role: .marketMovement)
        let existing = try Transaction.filter(Column("accountId") == fundAccountId && Column("date") == statement.periodEnd && Column("categoryId") == market.id).fetchCount(db)
        guard existing == 0 else { return nil }
        let held: Int
        if let openingDay, let openingMinorUnits {
            held = try BBVAEarlierHistoryImport.sumSince(db: db, accountId: fundAccountId, after: openingDay, through: statement.periodEnd) + openingMinorUnits
        } else {
            let snapshots = try BalanceSnapshot.filter(Column("accountId") == fundAccountId).fetchAll(db)
            let transactions = try Transaction.filter(Column("accountId") == fundAccountId).fetchAll(db)
            held = NetWorthCalculator.balance(accountId: fundAccountId, at: statement.periodEnd, snapshots: snapshots, transactions: transactions)?.native ?? 0
        }
        let movement = value.closingMinorUnits - held
        guard movement != 0 else { return nil }
        return try ManualTransactions.add(db: db, accountId: fundAccountId, date: statement.periodEnd, description: market.name, amountMinorUnits: movement,
                                          categoryId: market.id,
                                          note: "Statement \(statement.label): \(value.closingUnits) units at \(value.closingPrice) = \(BBVAEarlierHistoryImport.eur(value.closingMinorUnits))",
                                          allowBuiltIn: true)
    }
}
