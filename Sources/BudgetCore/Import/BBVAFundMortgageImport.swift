import Foundation
import GRDB

/// One-off import of the BBVA Portugal retirement fund and mortgage (spec: the BBVA history
/// import's follow-up), from data extracted outside the app (the monthly statements, the
/// December 2022 consolidated statement and the mortgage instalment notices), all in the
/// caller's transaction:
///
/// - **Fund**: an investment account (EUR, counted in net worth) with its opening value; every
///   €50 subscription row on BBVA filed under its tied transfer category with a linked leg on the
///   fund (`ManualTransactions.addOtherSide`); each recorded value saved through Update balance
///   (`BalanceUpdates.save`: the difference becomes a Market movement).
/// - **Mortgage**: a credit account left out of net worth (`Account.includeInNetWorth` off) with
///   the amount owed as its opening balance; the "Mortgage" category renamed "Mortgage interest";
///   every instalment row on BBVA filed under the loan's tied transfer category with a linked
///   +total leg on the loan, plus one manual "Mortgage interest" expense on the loan for the
///   instalment's interest, fees and taxes — so the loan's balance falls by the capital only. An
///   instalment with no breakdown is estimated (outstanding × the last known TAN / 12). The
///   learned rule for the instalments moves to the transfer category.
///
/// Then verifies (`ImportError.verificationFailed` rolls everything back): the fund's balance
/// equals every recorded value, the loan's equals every statement's outstanding at month end
/// (bar instalments the statement counted at their value date in an earlier month), and BBVA's
/// own balance and every existing account's order are unchanged.
public enum BBVAFundMortgageImport {
    public static let bbvaAccountName = BBVAHistoryImport.accountName
    public static let bbvaBatchName = BBVAHistoryImport.sourceFileName
    public static let fundAccountName = "BBVA retirement fund"
    public static let loanAccountName = "BBVA mortgage"
    public static let oldInterestCategoryName = "Mortgage"
    public static let interestCategoryName = "Mortgage interest"
    public static let instalmentRulePattern = "COBR REC TOT"
    public static let estimateNote = "estimated — confirm with BBVA notice"

    // MARK: Input

    /// A dated amount (EUR minor units) and where it comes from.
    public struct Value: Equatable, Sendable {
        public let date: Date
        public let minorUnits: Int
        public let source: String

        public init(date: Date, minorUnits: Int, source: String) {
            self.date = date
            self.minorUnits = minorUnits
            self.source = source
        }
    }

    /// A statement's mortgage outstanding (EMPRÉSTIMOS, positive) at the end of its month.
    public struct Statement: Equatable, Sendable {
        public let year: Int
        public let month: Int
        public let outstandingMinorUnits: Int
        public let source: String

        public init(year: Int, month: Int, outstandingMinorUnits: Int, source: String) {
            self.year = year
            self.month = month
            self.outstandingMinorUnits = outstandingMinorUnits
            self.source = source
        }

        public var label: String { String(format: "%04d-%02d", year, month) }
    }

    /// An instalment's split (positive amounts), from a notice or a statement.
    public struct Breakdown: Equatable, Sendable {
        public let capitalMinorUnits: Int
        public let interestMinorUnits: Int
        public let feesMinorUnits: Int
        public let taxesMinorUnits: Int
        public let receipt: Int?
        /// The TAN (annual %) in force, when the source gives it.
        public let tan: Double?
        public let source: String

        public init(capitalMinorUnits: Int, interestMinorUnits: Int, feesMinorUnits: Int = 0, taxesMinorUnits: Int = 0, receipt: Int? = nil, tan: Double? = nil, source: String) {
            self.capitalMinorUnits = capitalMinorUnits
            self.interestMinorUnits = interestMinorUnits
            self.feesMinorUnits = feesMinorUnits
            self.taxesMinorUnits = taxesMinorUnits
            self.receipt = receipt
            self.tan = tan
            self.source = source
        }

        public var totalMinorUnits: Int { capitalMinorUnits + interestMinorUnits + feesMinorUnits + taxesMinorUnits }
    }

    /// One instalment row on BBVA: its booking `date` (the row's date), the bank's value date,
    /// the total paid (positive) and its split when known.
    public struct Instalment: Equatable, Sendable {
        public let date: Date
        public let valueDate: Date
        public let totalMinorUnits: Int
        public let breakdown: Breakdown?

        public init(date: Date, valueDate: Date, totalMinorUnits: Int, breakdown: Breakdown?) {
            self.date = date
            self.valueDate = valueDate
            self.totalMinorUnits = totalMinorUnits
            self.breakdown = breakdown
        }
    }

    public struct Input: Equatable, Sendable {
        public let fundOpening: Value
        /// How many subscription rows BBVA must hold.
        public let fundSubscriptionCount: Int
        /// The fund's recorded values, by date.
        public let fundValues: [Value]
        /// The amount owed (positive) at the end of the opening day.
        public let loanOpening: Value
        public let statements: [Statement]
        public let instalments: [Instalment]

        public init(fundOpening: Value, fundSubscriptionCount: Int, fundValues: [Value], loanOpening: Value, statements: [Statement], instalments: [Instalment]) {
            self.fundOpening = fundOpening
            self.fundSubscriptionCount = fundSubscriptionCount
            self.fundValues = fundValues.sorted { $0.date < $1.date }
            self.loanOpening = loanOpening
            self.statements = statements.sorted { ($0.year, $0.month) < ($1.year, $1.month) }
            self.instalments = instalments.sorted { $0.date < $1.date }
        }
    }

    public enum ImportError: Error, Equatable, LocalizedError {
        case alreadyApplied(String)
        case missing(String)
        case badInput(String)
        case verificationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyApplied(let detail): return "Already applied: \(detail)."
            case .missing(let detail): return "Missing: \(detail)."
            case .badInput(let detail): return "Bad input: \(detail)."
            case .verificationFailed(let report): return "Verification failed:\n\(report)"
            }
        }
    }

    // MARK: Parsing

    /// The JSON the extraction writes: `fund` {openingDate, opening, openingSource,
    /// subscriptionCount, values [{date, value, source}]} and `loan` {openingDate, opening,
    /// openingSource, statements [{month "yyyy-MM", outstanding, source}], instalments [{date,
    /// valueDate, total, capital?, interest?, fees?, taxes?, receipt?, tan?, source?}]}. Dates
    /// "yyyy-MM-dd", amounts "1234.56".
    public static func parseInput(json data: Data) throws -> Input {
        struct ValueJSON: Decodable { let date: String; let value: String; let source: String }
        struct FundJSON: Decodable { let openingDate: String; let opening: String; let openingSource: String; let subscriptionCount: Int; let values: [ValueJSON] }
        struct StatementJSON: Decodable { let month: String; let outstanding: String; let source: String }
        struct InstalmentJSON: Decodable {
            let date: String; let valueDate: String; let total: String
            let capital: String?; let interest: String?; let fees: String?; let taxes: String?; let receipt: Int?; let tan: String?; let source: String?
        }
        struct LoanJSON: Decodable { let openingDate: String; let opening: String; let openingSource: String; let statements: [StatementJSON]; let instalments: [InstalmentJSON] }
        struct File: Decodable { let fund: FundJSON; let loan: LoanJSON }

        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch { throw ImportError.badInput("unreadable JSON (\(error))") }
        func day(_ text: String) throws -> Date {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, let date = MonthRange.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
                throw ImportError.badInput("date “\(text)”")
            }
            return date
        }
        func amount(_ text: String) throws -> Int {
            guard let value = BBVAHistoryImport.minorUnits(text) else { throw ImportError.badInput("amount “\(text)”") }
            return value
        }
        let statements = try file.loan.statements.map { s -> Statement in
            let parts = s.month.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { throw ImportError.badInput("month “\(s.month)”") }
            return Statement(year: parts[0], month: parts[1], outstandingMinorUnits: try amount(s.outstanding), source: s.source)
        }
        let instalments = try file.loan.instalments.map { i -> Instalment in
            var breakdown: Breakdown?
            if let capital = i.capital, let interest = i.interest {
                breakdown = Breakdown(capitalMinorUnits: try amount(capital), interestMinorUnits: try amount(interest), feesMinorUnits: try i.fees.map(amount) ?? 0,
                                      taxesMinorUnits: try i.taxes.map(amount) ?? 0, receipt: i.receipt, tan: i.tan.flatMap(Double.init), source: i.source ?? "unknown source")
            }
            return Instalment(date: try day(i.date), valueDate: try day(i.valueDate), totalMinorUnits: try amount(i.total), breakdown: breakdown)
        }
        return Input(fundOpening: Value(date: try day(file.fund.openingDate), minorUnits: try amount(file.fund.opening), source: file.fund.openingSource),
                     fundSubscriptionCount: file.fund.subscriptionCount,
                     fundValues: try file.fund.values.map { Value(date: try day($0.date), minorUnits: try amount($0.value), source: $0.source) },
                     loanOpening: Value(date: try day(file.loan.openingDate), minorUnits: try amount(file.loan.opening), source: file.loan.openingSource),
                     statements: statements, instalments: instalments)
    }

    // MARK: Instalment split (pure)

    /// An instalment with its split settled.
    public struct ResolvedInstalment: Equatable, Sendable {
        public let instalment: Instalment
        public let capitalMinorUnits: Int
        public let interestMinorUnits: Int
        public let feesMinorUnits: Int
        public let taxesMinorUnits: Int
        public let isEstimated: Bool
        /// The TAN used for an estimate, or the source's.
        public let tan: Double?
        /// Owed before this instalment (positive).
        public let outstandingBeforeMinorUnits: Int
        public let receipt: Int?
        public let source: String

        /// What the loan account's expense row holds: interest, fees and taxes.
        public var chargesMinorUnits: Int { interestMinorUnits + feesMinorUnits + taxesMinorUnits }
    }

    /// Settles every instalment's split in date order from `openingOutstanding` (owed,
    /// positive): the given breakdown (it must add up to the total), else an estimate — interest
    /// = outstanding × the last known TAN / 12 (rounded to the cent), capital the rest. Throws
    /// when a breakdown doesn't add up, or an estimate has no TAN to go on.
    public static func resolve(_ instalments: [Instalment], openingOutstanding: Int) throws -> [ResolvedInstalment] {
        var outstanding = openingOutstanding
        var lastTAN: Double?
        var result: [ResolvedInstalment] = []
        for instalment in instalments.sorted(by: { $0.date < $1.date }) {
            if let breakdown = instalment.breakdown {
                guard breakdown.totalMinorUnits == instalment.totalMinorUnits else {
                    throw ImportError.badInput("instalment \(day(instalment.date)): capital + interest + fees + taxes \(eur(breakdown.totalMinorUnits)) ≠ total \(eur(instalment.totalMinorUnits))")
                }
                if let tan = breakdown.tan { lastTAN = tan }
                result.append(ResolvedInstalment(instalment: instalment, capitalMinorUnits: breakdown.capitalMinorUnits, interestMinorUnits: breakdown.interestMinorUnits,
                                                 feesMinorUnits: breakdown.feesMinorUnits, taxesMinorUnits: breakdown.taxesMinorUnits, isEstimated: false,
                                                 tan: breakdown.tan, outstandingBeforeMinorUnits: outstanding, receipt: breakdown.receipt, source: breakdown.source))
                outstanding -= breakdown.capitalMinorUnits
            } else {
                guard let tan = lastTAN else { throw ImportError.badInput("instalment \(day(instalment.date)) has no breakdown and no earlier TAN to estimate from") }
                let interest = Int((Double(outstanding) * tan / 100 / 12).rounded())
                result.append(ResolvedInstalment(instalment: instalment, capitalMinorUnits: instalment.totalMinorUnits - interest, interestMinorUnits: interest,
                                                 feesMinorUnits: 0, taxesMinorUnits: 0, isEstimated: true, tan: tan, outstandingBeforeMinorUnits: outstanding,
                                                 receipt: nil, source: "estimate"))
                outstanding -= instalment.totalMinorUnits - interest
            }
        }
        return result
    }

    /// The interest row's note: the split and its source.
    public static func note(for item: ResolvedInstalment) -> String {
        let receipt = item.receipt.map { "Instalment \($0), due" } ?? "Instalment due"
        let split = "capital \(eur(item.capitalMinorUnits)), interest \(eur(item.interestMinorUnits)), fees \(eur(item.feesMinorUnits)), taxes \(eur(item.taxesMinorUnits)) — total \(eur(item.instalment.totalMinorUnits))"
        if item.isEstimated {
            let tan = item.tan.map { String(format: "%.3f%%", $0) } ?? "?"
            return "\(receipt) \(day(item.instalment.valueDate)): \(split). Interest \(estimateNote) (\(eur(item.outstandingBeforeMinorUnits)) outstanding × TAN \(tan) / 12)."
        }
        let tan = item.tan.map { String(format: " (TAN %.3f%%)", $0) } ?? ""
        return "\(receipt) \(day(item.instalment.valueDate)): \(split). Source: \(item.source)\(tan)."
    }

    /// The UK tax year (6 April – 5 April) holding `date`, by its starting year.
    public static func ukTaxYear(of date: Date) -> Int {
        let parts = MonthRange.calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year!
        return (parts.month!, parts.day!) >= (4, 6) ? year : year - 1
    }

    // MARK: Report

    public struct FundRow: Equatable, Sendable {
        public let date: Date
        public let valueMinorUnits: Int
        public let marketMovementMinorUnits: Int
        public let balanceMinorUnits: Int?
        public let source: String
    }

    public struct LoanRow: Equatable, Sendable {
        public let label: String
        public let statementMinorUnits: Int
        /// Owed per the app (positive).
        public let appMinorUnits: Int?
        public let explanation: String?
        public var differenceMinorUnits: Int? { appMinorUnits.map { $0 - statementMinorUnits } }
    }

    public struct Report: Equatable, Sendable {
        public let fundAccountId: Int64
        public let loanAccountId: Int64
        public let fundTransferCategory: String
        public let loanTransferCategory: String
        public let fund: [FundRow]
        public let marketMovementByYear: [Int: Int]
        public let fundSubscriptions: Int
        public let loan: [LoanRow]
        public let instalments: [ResolvedInstalment]
        public let ruleChange: String
        public let netWorthBeforeGBP: Int
        public let netWorthAfterGBP: Int
        public let fundBalanceNowMinorUnits: Int
        public let loanBalanceNowMinorUnits: Int
        public let verification: [String]

        /// Interest + fees + taxes per UK tax year (by starting year), from the booking dates.
        public var chargesByTaxYear: [Int: (total: Int, estimated: Int, count: Int)] {
            var result: [Int: (total: Int, estimated: Int, count: Int)] = [:]
            for item in instalments {
                let year = ukTaxYear(of: item.instalment.date)
                var entry = result[year] ?? (0, 0, 0)
                entry.total += item.chargesMinorUnits
                if item.isEstimated { entry.estimated += item.chargesMinorUnits }
                entry.count += 1
                result[year] = entry
            }
            return result
        }

        public var text: String {
            var lines: [String] = []
            lines.append("Fund “\(fundAccountName)” (investment, EUR, in net worth) id \(fundAccountId); transfer category “\(fundTransferCategory)”; \(fundSubscriptions) subscriptions linked")
            lines.append("  Date        Value          Market movement  Balance")
            for row in fund {
                lines.append("  \(day(row.date))  \(pad(eur(row.valueMinorUnits), 13))  \(pad(eur(row.marketMovementMinorUnits), 15))  \(row.balanceMinorUnits.map(eur) ?? "—")   \(row.source)")
            }
            lines.append("  Market movement per year:")
            for year in marketMovementByYear.keys.sorted() { lines.append("    \(year): \(eur(marketMovementByYear[year]!))") }
            lines.append("Mortgage “\(loanAccountName)” (credit, EUR, not in net worth) id \(loanAccountId); transfer category “\(loanTransferCategory)”")
            lines.append("  Month    Statement      App            Difference")
            for row in loan {
                lines.append("  \(row.label)  \(pad(eur(row.statementMinorUnits), 13))  \(pad(row.appMinorUnits.map(eur) ?? "—", 13))  \(row.differenceMinorUnits.map(eur) ?? "—")\(row.explanation.map { "  (\($0))" } ?? "")")
            }
            lines.append("  Instalments: \(instalments.count) (\(instalments.filter(\.isEstimated).count) estimated)")
            for item in instalments where item.isEstimated {
                lines.append("    estimated \(day(item.instalment.date)) (value \(day(item.instalment.valueDate))): total \(eur(item.instalment.totalMinorUnits)) = capital \(eur(item.capitalMinorUnits)) + interest \(eur(item.interestMinorUnits)) at TAN \(item.tan.map { String(format: "%.3f%%", $0) } ?? "?")")
            }
            lines.append("  Interest + fees + taxes per UK tax year (booking date):")
            let byYear = chargesByTaxYear
            for year in byYear.keys.sorted() {
                let entry = byYear[year]!
                lines.append("    \(year)/\(String(format: "%02d", (year + 1) % 100)): \(eur(entry.total)) over \(entry.count) instalments\(entry.estimated != 0 ? " (\(eur(entry.estimated)) estimated)" : "")")
            }
            lines.append("  Rule: \(ruleChange)")
            lines.append("Balances now: fund \(eur(fundBalanceNowMinorUnits)), mortgage \(eur(loanBalanceNowMinorUnits)) (signed)")
            lines.append("Net worth today: \(Money.format(netWorthBeforeGBP, currency: .gbp)) → \(Money.format(netWorthAfterGBP, currency: .gbp)) (\(Money.format(netWorthAfterGBP - netWorthBeforeGBP, currency: .gbp)))")
            lines.append("Verification:")
            lines += verification.map { "  " + $0 }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: Apply

    /// Everything, in the caller's write transaction; throws (nothing to keep) on any refusal
    /// or failed verification.
    public static func apply(db: Database, input: Input) throws -> Report {
        // 1. Prerequisites.
        let accounts = try Account.fetchAll(db)
        for name in [fundAccountName, loanAccountName] where accounts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ImportError.alreadyApplied("account “\(name)” exists")
        }
        guard let bbva = accounts.first(where: { $0.name == bbvaAccountName }), let bbvaId = bbva.id else { throw ImportError.missing("account “\(bbvaAccountName)”") }
        guard let batch = try ImportBatch.filter(Column("accountId") == bbvaId && Column("sourceFileName") == bbvaBatchName).fetchOne(db), let batchId = batch.id else {
            throw ImportError.missing("BBVA's batch “\(bbvaBatchName)”")
        }
        let categories = try Category.fetchAll(db)
        guard var interestCategory = categories.first(where: { $0.name == oldInterestCategoryName && $0.type == .expense }), let interestCategoryId = interestCategory.id else {
            if categories.contains(where: { $0.name == interestCategoryName }) { throw ImportError.alreadyApplied("category “\(interestCategoryName)” exists") }
            throw ImportError.missing("expense category “\(oldInterestCategoryName)”")
        }
        guard !categories.contains(where: { $0.name.caseInsensitiveCompare(interestCategoryName) == .orderedSame }) else {
            throw ImportError.alreadyApplied("category “\(interestCategoryName)” exists")
        }
        guard !input.instalments.isEmpty, !input.fundValues.isEmpty, input.fundValues.allSatisfy({ $0.date > input.fundOpening.date }),
              input.instalments.allSatisfy({ $0.date > input.loanOpening.date }) else {
            throw ImportError.badInput("needs instalments and fund values, all after the opening days")
        }
        let resolved = try resolve(input.instalments, openingOutstanding: input.loanOpening.minorUnits)

        let rate = try ExchangeRateSetting.currentOrDefault(db: db)
        let sortOrdersBefore = Dictionary(accounts.compactMap { a in a.id.map { ($0, a.sortOrder) } }, uniquingKeysWith: { a, _ in a })
        let netWorthBefore = try netWorthNow(db: db, rate: rate)
        let bbvaBefore = try balance(db: db, accountId: bbvaId, at: nil)

        // 2. The rows on BBVA: every instalment (its category, date and total) and subscription.
        let bbvaRows = try Transaction.filter(Column("importBatchId") == batchId).order(Column("date"), Column("id")).fetchAll(db)
        var unclaimed = bbvaRows.filter { $0.categoryId == interestCategoryId }
        var instalmentRows: [Transaction] = []
        for item in resolved {
            guard let index = unclaimed.firstIndex(where: { $0.date == item.instalment.date && $0.amountMinorUnits == -item.instalment.totalMinorUnits }) else {
                throw ImportError.missing("BBVA instalment row \(day(item.instalment.date)) \(eur(-item.instalment.totalMinorUnits)) in “\(oldInterestCategoryName)”")
            }
            instalmentRows.append(unclaimed.remove(at: index))
        }
        guard unclaimed.isEmpty else {
            throw ImportError.badInput("\(unclaimed.count) BBVA row(s) in “\(oldInterestCategoryName)” have no instalment: \(unclaimed.map { "\(day($0.date)) \(eur($0.amountMinorUnits))" }.joined(separator: ", "))")
        }
        let subscriptionRows = bbvaRows.filter { isSubscription($0.rawDescription) && $0.amountMinorUnits < 0 }
        guard subscriptionRows.count == input.fundSubscriptionCount else {
            throw ImportError.badInput("\(subscriptionRows.count) subscription rows on BBVA, expected \(input.fundSubscriptionCount)")
        }
        guard subscriptionRows.allSatisfy({ $0.categoryId == nil }) else { throw ImportError.alreadyApplied("a subscription row is already categorised") }

        // 3. The accounts (opening balances on the opening days) and the category's new name.
        let fund = try AccountEditing.add(db: db, name: fundAccountName, currency: .eur, kind: .investment, openingBalanceEntered: input.fundOpening.minorUnits,
                                          asOf: input.fundOpening.date, details: AccountDetails(region: .europe))
        let loan = try AccountEditing.add(db: db, name: loanAccountName, currency: .eur, kind: .credit, openingBalanceEntered: input.loanOpening.minorUnits,
                                          asOf: input.loanOpening.date, details: AccountDetails(region: .europe), includeInNetWorth: false)
        let fundId = fund.id!, loanId = loan.id!
        try db.execute(sql: "UPDATE balanceSnapshot SET note = ? WHERE accountId = ?", arguments: ["Opening: \(input.fundOpening.source)", fundId])
        try db.execute(sql: "UPDATE balanceSnapshot SET note = ? WHERE accountId = ?", arguments: ["Opening: \(input.loanOpening.source)", loanId])
        guard let fundCategory = try TransferCategories.category(db: db, forAccountId: fundId), let fundCategoryId = fundCategory.id,
              let loanCategory = try TransferCategories.category(db: db, forAccountId: loanId), let loanCategoryId = loanCategory.id else {
            throw ImportError.missing("the new accounts' transfer categories")
        }
        // The loan's transfer category sits with the interest, in the Lisbon group.
        try Categories.move(db: db, ids: [loanCategoryId], toGroupId: interestCategory.groupId)
        try Categories.rename(db: db, id: interestCategoryId, name: interestCategoryName)
        interestCategory.name = interestCategoryName

        // 4. The instalments: BBVA's row a transfer to the loan, the other leg there, and the charges.
        for (item, row) in zip(resolved, instalmentRows) {
            try TransactionEditing.setCategory(db: db, ids: [row.id!], categoryId: loanCategoryId, remember: false)
            let leg = try ManualTransactions.addOtherSide(db: db, transactionId: row.id!, accountId: loanId)
            guard leg.amountMinorUnits == item.instalment.totalMinorUnits else { throw ImportError.badInput("loan leg \(eur(leg.amountMinorUnits)) for \(day(item.instalment.date))") }
            if item.chargesMinorUnits != 0 {
                let description = item.receipt.map { "\(interestCategoryName) (instalment \($0))" } ?? "\(interestCategoryName) (estimated)"
                try ManualTransactions.add(db: db, accountId: loanId, date: item.instalment.date, description: description, amountMinorUnits: -item.chargesMinorUnits,
                                           categoryId: interestCategoryId, note: note(for: item))
            }
        }

        // 5. The fund: each subscription a transfer to it, the other leg there; then its values.
        for row in subscriptionRows {
            try TransactionEditing.setCategory(db: db, ids: [row.id!], categoryId: fundCategoryId, remember: false)
            _ = try ManualTransactions.addOtherSide(db: db, transactionId: row.id!, accountId: fundId)
        }
        var fundRows: [FundRow] = []
        for value in input.fundValues {
            let outcome = try BalanceUpdates.save(db: db, entries: [BalanceUpdates.Entry(accountId: fundId, enteredMinorUnits: value.minorUnits, note: value.source)], asOf: value.date)
            fundRows.append(FundRow(date: value.date, valueMinorUnits: value.minorUnits, marketMovementMinorUnits: outcome.first?.differenceMinorUnits ?? 0,
                                    balanceMinorUnits: try balance(db: db, accountId: fundId, at: BalanceUpdates.endOfDay(value.date)), source: value.source))
        }

        // 6. The learned rule follows the instalments.
        // The rules filing the instalment rows into the interest category.
        var ruleChanges: [String] = []
        let descriptions = instalmentRows.map(\.rawDescription)
        for rule in try Rule.filter(Column("categoryId") == interestCategoryId).fetchAll(db) where descriptions.contains(where: { RuleMatcher.matches(rule, description: $0) }) {
            try Rules.update(db: db, id: rule.id!, pattern: rule.matchPattern, matchType: rule.matchType, categoryId: loanCategoryId, applyToUncategorised: false)
            ruleChanges.append("“\(rule.matchPattern)” (\(rule.matchType.rawValue)) → \(loanCategory.name)")
        }
        let ruleChange: String
        if !ruleChanges.isEmpty {
            ruleChange = ruleChanges.joined(separator: "; ")
        } else {
            try Rules.add(db: db, pattern: instalmentRulePattern, matchType: .contains, categoryId: loanCategoryId, applyToUncategorised: false)
            ruleChange = "added “\(instalmentRulePattern)” (contains) → \(loanCategory.name)"
        }

        // 7. Verification.
        var verification: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ line: String) {
            verification.append((ok ? "OK   " : "FAIL ") + line)
            if !ok { failures += 1 }
        }
        let valuesOK = fundRows.filter { $0.balanceMinorUnits != $0.valueMinorUnits }
        check(valuesOK.isEmpty, "fund balance equals all \(fundRows.count) recorded values" + valuesOK.map { " — \(day($0.date)): \($0.balanceMinorUnits.map(eur) ?? "—") vs \(eur($0.valueMinorUnits))" }.joined())
        check(try balance(db: db, accountId: fundId, at: BalanceUpdates.endOfDay(input.fundOpening.date)) == input.fundOpening.minorUnits, "fund opening \(eur(input.fundOpening.minorUnits)) on \(day(input.fundOpening.date))")
        check(try balance(db: db, accountId: loanId, at: BalanceUpdates.endOfDay(input.loanOpening.date)) == -input.loanOpening.minorUnits, "mortgage opening \(eur(-input.loanOpening.minorUnits)) on \(day(input.loanOpening.date))")

        let loanTransactions = try Transaction.filter(Column("accountId") == loanId).fetchAll(db)
        let loanSnapshots = try BalanceSnapshot.filter(Column("accountId") == loanId).fetchAll(db)
        var loanRows: [LoanRow] = []
        var unexplained = 0
        for statement in input.statements {
            let end = MonthRange.of(year: statement.year, month: statement.month).end
            let owed = NetWorthCalculator.balance(accountId: loanId, at: end, snapshots: loanSnapshots, transactions: loanTransactions).map { -$0.native }
            let difference = owed.map { $0 - statement.outstandingMinorUnits }
            var explanation: String?
            if let difference, abs(difference) > 1 {
                // The statement counted instalments value-dated this month but booked after it.
                let early = resolved.filter { $0.instalment.valueDate <= end && $0.instalment.date > end }
                if !early.isEmpty, abs(early.reduce(0) { $0 + $1.capitalMinorUnits } - difference) <= 1 {
                    explanation = "statement counts " + early.map { "the \(day($0.instalment.valueDate)) instalment (booked \(day($0.instalment.date)), capital \(eur($0.capitalMinorUnits)))" }.joined(separator: ", ")
                } else {
                    unexplained += 1
                }
            }
            loanRows.append(LoanRow(label: statement.label, statementMinorUnits: statement.outstandingMinorUnits, appMinorUnits: owed, explanation: explanation))
        }
        check(unexplained == 0 && loanRows.allSatisfy { $0.appMinorUnits != nil },
              "mortgage balance equals every statement's outstanding at month end (\(loanRows.count) months; cents rounding tolerated; \(loanRows.filter { $0.explanation != nil }.count) value-date timing)"
                + (unexplained > 0 ? " — \(unexplained) differ" : ""))
        let capitalPaid = resolved.reduce(0) { $0 + $1.capitalMinorUnits }
        let loanNow = try balance(db: db, accountId: loanId, at: nil)
        check(loanNow == -input.loanOpening.minorUnits + capitalPaid, "mortgage now \(eur(loanNow)) = opening − capital paid \(eur(capitalPaid))")

        let links = try TransferLink.active.fetchAll(db)
        let linked = Set(links.flatMap { [$0.outTransactionId, $0.inTransactionId] })
        let refreshed = Dictionary(try Transaction.filter(keys: bbvaRows.compactMap(\.id)).fetchAll(db).compactMap { t in t.id.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
        check(instalmentRows.allSatisfy { row in refreshed[row.id!].map { $0.categoryId == loanCategoryId && $0.status == .confirmed && linked.contains($0.id!) } ?? false },
              "all \(instalmentRows.count) instalment rows on BBVA in “\(loanCategory.name)”, confirmed and linked")
        check(subscriptionRows.allSatisfy { row in refreshed[row.id!].map { $0.categoryId == fundCategoryId && $0.status == .confirmed && linked.contains($0.id!) } ?? false },
              "all \(subscriptionRows.count) subscription rows on BBVA in “\(fundCategory.name)”, confirmed and linked")
        let interestRows = loanTransactions.filter { $0.categoryId == interestCategoryId }
        check(interestRows.count == resolved.filter { $0.chargesMinorUnits != 0 }.count, "\(interestRows.count) “\(interestCategoryName)” rows on the mortgage")
        let bbvaAfter = try balance(db: db, accountId: bbvaId, at: nil)
        check(bbvaAfter == bbvaBefore, "BBVA balance unchanged: \(eur(bbvaAfter))")
        let accountsAfter = try Account.fetchAll(db)
        check(accountsAfter.allSatisfy { a in a.id.map { sortOrdersBefore[$0].map { $0 == a.sortOrder } ?? (a.sortOrder == nil) } ?? false },
              "account order unchanged (new accounts unordered)")
        check(try Account.fetchOne(db, key: loanId)?.includeInNetWorth == false && (try Account.fetchOne(db, key: fundId)?.includeInNetWorth) == true,
              "the mortgage is left out of net worth, the fund counts")
        let netWorthAfter = try netWorthNow(db: db, rate: rate)
        let fundNow = try balance(db: db, accountId: fundId, at: nil)
        let fundGBP = NetWorthCalculator.gbp(fundNow, currency: .eur, eurToGbpRate: rate.eurToGbpRate)
        check(netWorthAfter - netWorthBefore == fundGBP, "net worth rises by the fund only: \(Money.format(netWorthAfter - netWorthBefore, currency: .gbp)) (fund \(eur(fundNow)) at \(rate.eurToGbpRate))")

        let marketByYear = Dictionary(grouping: fundRows) { MonthRange.calendar.component(.year, from: $0.date) }.mapValues { $0.reduce(0) { $0 + $1.marketMovementMinorUnits } }
        let report = Report(fundAccountId: fundId, loanAccountId: loanId, fundTransferCategory: fundCategory.name, loanTransferCategory: loanCategory.name, fund: fundRows,
                            marketMovementByYear: marketByYear, fundSubscriptions: subscriptionRows.count, loan: loanRows, instalments: resolved, ruleChange: ruleChange,
                            netWorthBeforeGBP: netWorthBefore, netWorthAfterGBP: netWorthAfter, fundBalanceNowMinorUnits: fundNow, loanBalanceNowMinorUnits: loanNow,
                            verification: verification)
        guard failures == 0 else { throw ImportError.verificationFailed(report.text) }
        return report
    }

    // MARK: Helpers

    /// "SUBSCRIÇÃO PERI <unit price>" / "Subscricao Peri": the fund's periodic subscription.
    public static func isSubscription(_ description: String) -> Bool {
        let folded = description.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_PT")).lowercased()
        return folded.contains("subscricao peri")
    }

    private static func balance(db: Database, accountId: Int64, at date: Date?) throws -> Int {
        let snapshots = try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db)
        let transactions = try Transaction.filter(Column("accountId") == accountId).fetchAll(db)
        return NetWorthCalculator.balance(accountId: accountId, at: date, snapshots: snapshots, transactions: transactions)?.native ?? 0
    }

    private static func netWorthNow(db: Database, rate: ExchangeRateSetting) throws -> Int {
        NetWorthCalculator.netWorth(balances: NetWorthCalculator.accountBalances(accounts: try Account.fetchAll(db), snapshots: try BalanceSnapshot.fetchAll(db),
                                                                                 transactions: try Transaction.fetchAll(db), rate: rate))
    }

    static func eur(_ minorUnits: Int) -> String { Money.format(minorUnits, currency: .eur) }

    static func day(_ date: Date) -> String {
        let parts = MonthRange.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
