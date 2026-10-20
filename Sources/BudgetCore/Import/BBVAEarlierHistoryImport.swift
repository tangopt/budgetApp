import Foundation
import GRDB

/// Imports BBVA Portugal statements from before the history already in the app (the 2023+
/// import, `BBVAHistoryImport` and `BBVAFundMortgageImport`), all in the caller's transaction:
///
/// - **Current account**: the statements' movements in a new batch on "BBVA", classified by the
///   plan's rules (the same kinds as the 2023+ import, plus a few) and per-row overrides, through
///   the normal import commit; an opening balance on the day before the first statement, so the
///   history runs continuously into the existing opening (which must equal the last closing).
/// - **Mortgage**: each instalment a transfer to "BBVA mortgage" with its linked leg, plus the
///   "Mortgage interest" row for its interest, fees and taxes (from the statement's settled
///   receipt); the loan's opening balance before the first instalment.
/// - **Fund**: each subscription a transfer to "BBVA retirement fund" with its linked leg, and a
///   Market movement at each month end so the fund's balance equals the statement's value; its
///   opening value the day before the first statement.
/// - **Tenant deposit**: credits (or parts of them, `depositSplits`) are transfers from "Tenant
///   deposit held", with the liability's (zero) opening before them.
/// - **Tax and property**: plan-listed insurers' / condomínio receipts kept "on their own" are
///   linked to the debits that paid them, manual items for costs now in the bank history are
///   removed or reduced, new categories added with their tax type, utility invoices linked to
///   their debits, and rent receipts matched to the credits.
///
/// Verified before anything is kept (`ImportError.verificationFailed` rolls back): every month end
/// equals the statement's closing on all three accounts, the existing openings meet the new
/// history, every account's balance today is unchanged, and no filed tax year's figure moves.
public enum BBVAEarlierHistoryImport {
    public static let bbvaAccountName = BBVAHistoryImport.accountName
    public static let fundAccountName = BBVAFundMortgageImport.fundAccountName
    public static let loanAccountName = BBVAFundMortgageImport.loanAccountName
    public static let depositAccountName = BBVAHistoryImport.depositAccountName
    public static let interestCategoryName = BBVAFundMortgageImport.interestCategoryName
    /// How far a fund movement's day and its subscription debit's may be apart.
    public static let fundPairingDays = 5

    // MARK: Plan

    /// The personal data the import needs (kept outside the repository).
    public struct Plan: Codable, Equatable, Sendable {
        /// The new batch's name ("BBVA extratos 2022-01 to 2022-12").
        public var batchName: String
        /// First match wins: a regular expression on the description → a kind or a category.
        public var rules: [Rule]
        /// Per-row classification, by booking date and amount (and optionally text).
        public var overrides: [Override]
        public var depositSplits: [DepositSplit]
        public var newCategories: [NewCategory]
        public var policyReceiptLinks: [PolicyReceiptLink]
        public var manualItems: [ManualItemChange]
        public var linkUtilityInvoices: Bool
        public var matchRentReceipts: Bool
        /// Receipts paid by credits automatic matching can't pair (outside its window), linked by hand.
        public var rentReceiptLinks: [RentReceiptLink]
        /// Figures of filed (or paid) years allowed to move, each scoped to a year (and person), with why.
        public var acceptFiledChanges: [AcceptedChange]
        /// What filed (or paid) returns say, per year and person: a changed figure must land on it.
        public var filedReturns: [FiledReturn]
        /// Employments of a year the app doesn't hold yet (from the filed return's SA102 pages).
        public var employments: [EmploymentEntry]
        /// Tenant credits (or what's left of them after rent) that were utility recharges of a
        /// tenancy without itemised statements: one paid statement per month, one line each.
        public var recharges: [RechargeEntry]
        /// Notes for tax years (both people), e.g. years disclosed outside Self Assessment.
        public var taxYearNotes: [TaxYearNote]
        /// The year set-up the tax data plan records (rates, owners, manual items, rules, receipts),
        /// applied after the rows in the same transaction.
        public var taxData: TaxDataPlan.Plan?
        /// The property the tax steps are for (by name); nil = the only one.
        public var property: String?

        public init(batchName: String, rules: [Rule], overrides: [Override] = [], depositSplits: [DepositSplit] = [], newCategories: [NewCategory] = [],
                    policyReceiptLinks: [PolicyReceiptLink] = [], manualItems: [ManualItemChange] = [], linkUtilityInvoices: Bool = false,
                    matchRentReceipts: Bool = false, rentReceiptLinks: [RentReceiptLink] = [], acceptFiledChanges: [AcceptedChange] = [], filedReturns: [FiledReturn] = [], employments: [EmploymentEntry] = [],
                    recharges: [RechargeEntry] = [], taxYearNotes: [TaxYearNote] = [], taxData: TaxDataPlan.Plan? = nil, property: String? = nil) {
            self.batchName = batchName
            self.rules = rules
            self.overrides = overrides
            self.depositSplits = depositSplits
            self.newCategories = newCategories
            self.policyReceiptLinks = policyReceiptLinks
            self.manualItems = manualItems
            self.linkUtilityInvoices = linkUtilityInvoices
            self.matchRentReceipts = matchRentReceipts
            self.rentReceiptLinks = rentReceiptLinks
            self.acceptFiledChanges = acceptFiledChanges
            self.filedReturns = filedReturns
            self.employments = employments
            self.recharges = recharges
            self.taxYearNotes = taxYearNotes
            self.taxData = taxData
            self.property = property
        }

        enum CodingKeys: String, CodingKey {
            case batchName, rules, overrides, depositSplits, newCategories, policyReceiptLinks, manualItems, linkUtilityInvoices, matchRentReceipts
            case rentReceiptLinks, acceptFiledChanges, filedReturns, employments, recharges, taxYearNotes, taxData, property
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            batchName = try c.decode(String.self, forKey: .batchName)
            rules = try c.decode([Rule].self, forKey: .rules)
            overrides = try c.decodeIfPresent([Override].self, forKey: .overrides) ?? []
            depositSplits = try c.decodeIfPresent([DepositSplit].self, forKey: .depositSplits) ?? []
            newCategories = try c.decodeIfPresent([NewCategory].self, forKey: .newCategories) ?? []
            policyReceiptLinks = try c.decodeIfPresent([PolicyReceiptLink].self, forKey: .policyReceiptLinks) ?? []
            manualItems = try c.decodeIfPresent([ManualItemChange].self, forKey: .manualItems) ?? []
            linkUtilityInvoices = try c.decodeIfPresent(Bool.self, forKey: .linkUtilityInvoices) ?? false
            matchRentReceipts = try c.decodeIfPresent(Bool.self, forKey: .matchRentReceipts) ?? false
            rentReceiptLinks = try c.decodeIfPresent([RentReceiptLink].self, forKey: .rentReceiptLinks) ?? []
            acceptFiledChanges = try c.decodeIfPresent([AcceptedChange].self, forKey: .acceptFiledChanges) ?? []
            filedReturns = try c.decodeIfPresent([FiledReturn].self, forKey: .filedReturns) ?? []
            employments = try c.decodeIfPresent([EmploymentEntry].self, forKey: .employments) ?? []
            recharges = try c.decodeIfPresent([RechargeEntry].self, forKey: .recharges) ?? []
            taxYearNotes = try c.decodeIfPresent([TaxYearNote].self, forKey: .taxYearNotes) ?? []
            taxData = try c.decodeIfPresent(TaxDataPlan.Plan.self, forKey: .taxData)
            property = try c.decodeIfPresent(String.self, forKey: .property)
        }
    }

    public struct Rule: Codable, Equatable, Sendable {
        public var pattern: String
        public var kind: String?
        public var category: String?
        /// Only rows at or below this amount ("-200.00": debits of €200 or more).
        public var maxAmount: String?

        public init(pattern: String, kind: String? = nil, category: String? = nil, maxAmount: String? = nil) {
            self.pattern = pattern
            self.kind = kind
            self.category = category
            self.maxAmount = maxAmount
        }
    }

    public struct Override: Codable, Equatable, Sendable {
        /// yyyy-MM-dd (booking).
        public var date: String
        /// Signed, "-120.95".
        public var amount: String
        public var contains: String?
        public var kind: String?
        public var category: String?
        public var note: String?

        public init(date: String, amount: String, contains: String? = nil, kind: String? = nil, category: String? = nil, note: String? = nil) {
            self.date = date
            self.amount = amount
            self.contains = contains
            self.kind = kind
            self.category = category
            self.note = note
        }
    }

    /// Of the credit booked `date`, `deposit` is the tenant's deposit (a transfer from the
    /// liability) and the rest rent.
    public struct DepositSplit: Codable, Equatable, Sendable {
        public var date: String
        public var deposit: String

        public init(date: String, deposit: String) {
            self.date = date
            self.deposit = deposit
        }
    }

    public struct NewCategory: Codable, Equatable, Sendable {
        public var name: String
        /// The group (by name) it goes in.
        public var group: String
        /// Its tax line (`TaxExpenseType` raw value).
        public var taxType: String

        public init(name: String, group: String, taxType: String) {
            self.name = name
            self.group = group
            self.taxType = taxType
        }
    }

    /// A receipt kept on its own (no transaction) that the bank history now shows paid.
    public struct PolicyReceiptLink: Codable, Equatable, Sendable {
        public var receiptDate: String
        public var amount: String
        /// The debit's booking date.
        public var transactionDate: String

        public init(receiptDate: String, amount: String, transactionDate: String) {
            self.receiptDate = receiptDate
            self.amount = amount
            self.transactionDate = transactionDate
        }
    }

    /// A manual item for costs the imported rows now carry: removed (`newAmount` nil) or
    /// reduced to what's left (paid outside the bank history).
    public struct ManualItemChange: Codable, Equatable, Sendable {
        public var startYear: Int
        public var expenseType: String
        public var amount: String
        /// Debits (booking date, positive amount) that replace it.
        public var replacedBy: [Payment]
        public var newAmount: String?
        public var newLabel: String?

        public init(startYear: Int, expenseType: String, amount: String, replacedBy: [Payment], newAmount: String? = nil, newLabel: String? = nil) {
            self.startYear = startYear
            self.expenseType = expenseType
            self.amount = amount
            self.replacedBy = replacedBy
            self.newAmount = newAmount
            self.newLabel = newLabel
        }
    }

    /// A rent receipt (by tenancy reference, number and amount) and the credits (booking date,
    /// amount) that paid it, all rent.
    public struct RentReceiptLink: Codable, Equatable, Sendable {
        public var tenancy: String
        public var receiptNumber: String
        public var amount: String
        public var credits: [Payment]

        public init(tenancy: String, receiptNumber: String, amount: String, credits: [Payment]) {
            self.tenancy = tenancy
            self.receiptNumber = receiptNumber
            self.amount = amount
            self.credits = credits
        }
    }

    public struct AcceptedChange: Codable, Equatable, Sendable {
        /// The year (start year) it applies to: never a blanket acceptance.
        public var startYear: Int
        /// The person; nil = both.
        public var person: String?
        /// A regular expression on the field ("<property> · notDeductible · ").
        public var field: String
        public var reason: String

        public init(startYear: Int, person: String? = nil, field: String, reason: String) {
            self.startYear = startYear
            self.person = person
            self.field = field
            self.reason = reason
        }
    }

    /// A filed return's figures (field name → value: "540.59" in the field's unit, or a text).
    public struct FiledReturn: Codable, Equatable, Sendable {
        public var startYear: Int
        public var person: String
        public var source: String
        public var fields: [String: String]

        public init(startYear: Int, person: String, source: String, fields: [String: String]) {
            self.startYear = startYear
            self.person = person
            self.source = source
            self.fields = fields
        }
    }

    public struct RechargeEntry: Codable, Equatable, Sendable {
        /// The tenancy's reference label.
        public var tenancy: String
        /// "2022-01": the statement's month.
        public var month: String
        public var description: String
        /// The credits (booking date and the recharge part of each) that paid it.
        public var credits: [Payment]

        public init(tenancy: String, month: String, description: String, credits: [Payment]) {
            self.tenancy = tenancy
            self.month = month
            self.description = description
            self.credits = credits
        }
    }

    public struct TaxYearNote: Codable, Equatable, Sendable {
        public var startYear: Int
        public var note: String

        public init(startYear: Int, note: String) {
            self.startYear = startYear
            self.note = note
        }
    }

    public struct EmploymentEntry: Codable, Equatable, Sendable {
        public var startYear: Int
        public var person: String
        public var employer: String
        public var payeReference: String?
        /// "p60", "p45", "payslip", "other".
        public var source: String
        public var pay: String
        public var tax: String
        public var benefits: [Benefit]?
        public var notes: String?

        public init(startYear: Int, person: String, employer: String, payeReference: String? = nil, source: String, pay: String, tax: String,
                    benefits: [Benefit]? = nil, notes: String? = nil) {
            self.startYear = startYear
            self.person = person
            self.employer = employer
            self.payeReference = payeReference
            self.source = source
            self.pay = pay
            self.tax = tax
            self.benefits = benefits
            self.notes = notes
        }
    }

    public struct Benefit: Codable, Equatable, Sendable {
        /// A `BenefitKind` raw value ("medical").
        public var kind: String
        public var amount: String
        public var description: String?

        public init(kind: String, amount: String, description: String? = nil) {
            self.kind = kind
            self.amount = amount
            self.description = description
        }
    }

    public struct Payment: Codable, Equatable, Sendable {
        public var date: String
        public var amount: String
        /// On the mortgage account ("Mortgage interest" rows) instead of BBVA.
        public var onLoan: Bool?

        public init(date: String, amount: String, onLoan: Bool? = nil) {
            self.date = date
            self.amount = amount
            self.onLoan = onLoan
        }
    }

    /// Keys a plan may carry for people only (never read).
    public static let metadataKeys: Set<String> = ["generated", "note", "comment"]

    /// Decodes the plan strictly: a key the plan doesn't know (a typo would silently drop a step)
    /// is refused, except the top level's `metadataKeys`; a rule or override must name exactly
    /// one of a kind and a category.
    public static func decodePlan(_ data: Data) throws -> Plan {
        let plan = try JSONDecoder().decode(Plan.self, from: data)
        let raw = try JSONSerialization.jsonObject(with: data)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
        var unknown: [String] = []
        func walk(_ a: Any, _ b: Any?, _ path: String, top: Bool) {
            if let a = a as? [String: Any] {
                let b = b as? [String: Any] ?? [:]
                for (key, value) in a {
                    if top && metadataKeys.contains(key) { continue }
                    guard let other = b[key] else {
                        if !(value is NSNull) { unknown.append(path + key) }
                        continue
                    }
                    walk(value, other, path + key + ".", top: false)
                }
            } else if let a = a as? [Any] {
                let b = b as? [Any] ?? []
                for (index, value) in a.enumerated() { walk(value, index < b.count ? b[index] : nil, path + "\(index).", top: false) }
            }
        }
        walk(raw, encoded, "", top: true)
        guard unknown.isEmpty else { throw ImportError.badInput("unknown plan key(s): " + unknown.sorted().joined(separator: ", ")) }
        for (index, rule) in plan.rules.enumerated() where (rule.kind == nil) == (rule.category == nil) {
            throw ImportError.badInput("rule \(index + 1) (/\(rule.pattern)/) needs exactly one of kind and category")
        }
        for override in plan.overrides where (override.kind == nil) == (override.category == nil) {
            throw ImportError.badInput("the override for \(override.date) \(override.amount) needs exactly one of kind and category")
        }
        return plan
    }

    /// Whether the plan's batch is already in the database (a re-run: nothing to do).
    public static func isApplied(db: Database, plan: Plan) throws -> Bool {
        try ImportBatch.filter(Column("sourceFileName") == plan.batchName).fetchCount(db) > 0
    }

    // MARK: Errors

    public enum ImportError: Error, Equatable, LocalizedError {
        case alreadyApplied(String)
        case missing(String)
        case badInput(String)
        case overlap(String)
        case verificationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyApplied(let what): return "Already applied: \(what). Nothing written."
            case .missing(let what): return "Missing: \(what)."
            case .badInput(let reason): return "Bad input: \(reason)"
            case .overlap(let reason): return "Overlap with the history already imported: \(reason)"
            case .verificationFailed(let report): return "Verification failed (rolled back):\n\(report)"
            }
        }
    }

    // MARK: Classification (pure)

    public enum Target: Equatable, Sendable {
        case category(String)
        case uncategorised
        case loanTransfer
        case fundTransfer
        case depositTransfer
    }

    /// Where a kind goes: the 2023+ import's kinds (`BBVAHistoryImport.mapping`), the
    /// instalments and subscriptions as transfers to the loan and the fund, and the kinds the
    /// earlier statements add. Nil for an unknown kind.
    public static func target(forKind kind: String) -> Target? {
        switch kind {
        case "mortgage_instalment": return .loanTransfer
        case "investment_subscription": return .fundTransfer
        case "tenant_deposit_received", "tenant_deposit_return": return .depositTransfer
        case "repairs": return .category("Repairs")
        case "contents_insurance": return .category("Contents insurance")
        case "property_other": return .category("Other")
        case "letting_fees": return .category("Letting fees")
        case "card_purchase": return .uncategorised
        default:
            switch BBVAHistoryImport.mapping(forKind: kind) {
            case .category(let name)?: return .category(name)
            case .uncategorised?: return .uncategorised
            case .depositTransfer?: return .depositTransfer
            // The 2023+ import named no account for these: left for review.
            case .ownAccountTransfer?: return .uncategorised
            case nil: return nil
            }
        }
    }

    public struct Classified: Equatable, Sendable {
        public let movement: BBVAStatementParser.Movement
        public let statement: String
        /// The kind (or "category" for a rule naming a category).
        public let kind: String
        public let target: Target
        /// What decided: "rule /…/", "override", "no rule".
        public let reason: String
        public let note: String?
    }

    /// Classifies every movement: an override for its day and amount first, else the first
    /// rule whose pattern matches (and whose amount limit allows it), else "other". Throws on an
    /// unknown kind, a bad pattern, or an override matching no row or several.
    public static func classify(_ statements: [BBVAStatementParser.Statement], plan: Plan) throws -> [Classified] {
        let rules = try plan.rules.map { rule -> (Rule, NSRegularExpression) in
            (rule, try NSRegularExpression(pattern: rule.pattern))
        }
        let kinds = plan.rules.compactMap(\.kind) + plan.overrides.compactMap(\.kind)
        if let unknown = kinds.first(where: { target(forKind: $0) == nil }) { throw ImportError.badInput("unknown kind “\(unknown)”") }
        var overrideHits = Array(repeating: 0, count: plan.overrides.count)
        var result: [Classified] = []
        for statement in statements {
            for movement in statement.movements {
                func resolve(kind: String?, category: String?) throws -> (String, Target) {
                    if let category { return ("category", .category(category)) }
                    guard let kind, let target = target(forKind: kind) else { throw ImportError.badInput("unknown kind “\(kind ?? "")”") }
                    return (kind, target)
                }
                let overrides = plan.overrides.indices.filter { index in
                    let o = plan.overrides[index]
                    return day(o.date) == movement.date && amount(o.amount) == movement.amountMinorUnits
                        && (o.contains.map { movement.description.range(of: $0, options: .caseInsensitive) != nil } ?? true)
                }
                if overrides.count > 1 { throw ImportError.badInput("several overrides for \(dayText(movement.date)) \(movement.description)") }
                if let index = overrides.first {
                    overrideHits[index] += 1
                    let o = plan.overrides[index]
                    let (kind, target) = try resolve(kind: o.kind, category: o.category)
                    result.append(Classified(movement: movement, statement: statement.label, kind: kind, target: target, reason: "override", note: o.note))
                    continue
                }
                let range = NSRange(movement.description.startIndex..., in: movement.description)
                if let (rule, _) = rules.first(where: { rule, regex in
                    regex.firstMatch(in: movement.description, range: range) != nil
                        && (rule.maxAmount.flatMap(amount).map { movement.amountMinorUnits <= $0 } ?? true)
                }) {
                    let (kind, target) = try resolve(kind: rule.kind, category: rule.category)
                    result.append(Classified(movement: movement, statement: statement.label, kind: kind, target: target, reason: "rule /\(rule.pattern)/", note: nil))
                } else {
                    result.append(Classified(movement: movement, statement: statement.label, kind: "other", target: .uncategorised, reason: "no rule", note: nil))
                }
            }
        }
        if let unused = overrideHits.firstIndex(where: { $0 != 1 }) {
            let o = plan.overrides[unused]
            throw ImportError.badInput("the override for \(o.date) \(o.amount) matches \(overrideHits[unused]) rows (needs exactly 1)")
        }
        return result
    }

    // MARK: Statement checks (pure)

    /// Contiguous months, each opening the previous closing, every printed balance the running
    /// one, every booking inside its period, the summary's deposits the closing, the fund's
    /// movements its units, and the loan's receipts chained (owed after = owed before − capital).
    public static func checkStatements(_ statements: [BBVAStatementParser.Statement]) throws -> [String] {
        guard let first = statements.first else { throw ImportError.badInput("no statements") }
        var lines: [String] = []
        for (previous, next) in zip(statements, statements.dropFirst()) {
            guard MonthRange.calendar.date(byAdding: .day, value: 1, to: previous.periodEnd) == next.periodStart else {
                throw ImportError.badInput("statements not contiguous: \(previous.label) → \(next.label)")
            }
            guard next.openingMinorUnits == previous.closingMinorUnits else {
                throw ImportError.badInput("\(next.label) opening \(eur(next.openingMinorUnits)) ≠ \(previous.label) closing \(eur(previous.closingMinorUnits))")
            }
            if let a = previous.fund, let b = next.fund, a.closingUnits != b.openingUnits {
                throw ImportError.badInput("fund units: \(next.label) opens with \(b.openingUnits), \(previous.label) closed with \(a.closingUnits)")
            }
        }
        for statement in statements {
            guard statement.unreadLines.isEmpty else { throw ImportError.badInput("\(statement.label): unread lines \(statement.unreadLines)") }
            var balance = statement.openingMinorUnits
            for movement in statement.movements {
                balance += movement.amountMinorUnits
                if let printed = movement.balanceAfterMinorUnits, printed != balance {
                    throw ImportError.badInput("\(statement.label): balance breaks at \(dayText(movement.date)) \(movement.description) (printed \(eur(printed)), running \(eur(balance)))")
                }
                guard movement.date >= statement.periodStart && movement.date <= statement.periodEnd else {
                    throw ImportError.badInput("\(statement.label): \(dayText(movement.date)) \(movement.description) booked outside the period")
                }
            }
            guard balance == statement.closingMinorUnits else {
                throw ImportError.badInput("\(statement.label): movements end at \(eur(balance)), closing \(eur(statement.closingMinorUnits))")
            }
            if let deposits = statement.summary["DEPÓSITOS À ORDEM"], deposits != statement.closingMinorUnits {
                throw ImportError.badInput("\(statement.label): DEPÓSITOS À ORDEM \(eur(deposits)) ≠ closing \(eur(statement.closingMinorUnits))")
            }
            if let fund = statement.fund {
                let units = fund.movements.reduce(fund.openingUnits) { $0 + $1.units }
                guard units == fund.closingUnits else { throw ImportError.badInput("\(statement.label): fund units \(units) ≠ closing \(fund.closingUnits)") }
                if let savings = statement.savingsMinorUnits, savings != fund.closingMinorUnits {
                    throw ImportError.badInput("\(statement.label): PRODUTOS DE POUPANÇA \(eur(savings)) ≠ fund closing \(eur(fund.closingMinorUnits))")
                }
            }
            lines.append("\(statement.label): opening \(eur(statement.openingMinorUnits)) + \(statement.movements.count) movements = closing \(eur(statement.closingMinorUnits))"
                         + (statement.fund.map { "; fund \(eur($0.openingMinorUnits)) → \(eur($0.closingMinorUnits)) (\($0.movements.count) subscription\($0.movements.count == 1 ? "" : "s"))" } ?? "")
                         + (statement.loanOutstandingMinorUnits.map { "; loan owed \(eur($0))" } ?? ""))
        }
        let receipts = statements.flatMap(\.loanReceipts).sorted { $0.number < $1.number }
        for (previous, next) in zip(receipts, receipts.dropFirst()) {
            guard next.number == previous.number + 1 else { throw ImportError.badInput("loan receipts not consecutive: \(previous.number) → \(next.number)") }
            guard previous.outstandingAfterMinorUnits - next.capitalMinorUnits == next.outstandingAfterMinorUnits else {
                throw ImportError.badInput("receipt \(next.number): \(eur(previous.outstandingAfterMinorUnits)) − capital \(eur(next.capitalMinorUnits)) ≠ \(eur(next.outstandingAfterMinorUnits))")
            }
        }
        for receipt in receipts {
            let parts = receipt.capitalMinorUnits + receipt.interestMinorUnits + receipt.feesMinorUnits + receipt.lateInterestMinorUnits + receipt.taxesMinorUnits
            guard parts == receipt.totalMinorUnits else { throw ImportError.badInput("receipt \(receipt.number): parts \(eur(parts)) ≠ total \(eur(receipt.totalMinorUnits))") }
        }
        _ = first
        return lines
    }

    // MARK: Report

    public struct RowReport: Equatable, Sendable {
        public let date: Date
        public let description: String
        public let amountMinorUnits: Int
        public let category: String?
        public let reason: String
    }

    public struct MonthCheck: Equatable, Sendable {
        public let label: String
        public let account: String
        public let statementMinorUnits: Int
        public let appMinorUnits: Int?
        public var ok: Bool { appMinorUnits == statementMinorUnits }
    }

    public struct InstalmentReport: Equatable, Sendable {
        public let receipt: Int
        public let date: Date
        public let valueDate: Date
        public let totalMinorUnits: Int
        public let capitalMinorUnits: Int
        public let chargesMinorUnits: Int
        public let tan: Double?
        public let owedAfterMinorUnits: Int
    }

    public struct Report: Equatable, Sendable {
        public var statementLines: [String] = []
        public var openings: [String] = []
        /// Rows added per account (statement rows, legs, interest, market movements).
        public var accountCounts: [String] = []
        public var rows: [RowReport] = []
        public var byCategory: [(name: String, count: Int, total: Int)] = []
        public var transferLinks: [String] = []
        public var instalments: [InstalmentReport] = []
        public var fundMovements: [String] = []
        public var deposit: [String] = []
        public var monthChecks: [MonthCheck] = []
        public var categoriesCreated: [String] = []
        public var policyReceipts: [String] = []
        public var manualItems: [String] = []
        public var invoices: [String] = []
        public var invoicesUnmatched: [String] = []
        public var rentLinks: [String] = []
        public var rentUnmatchedReceipts: [String] = []
        public var rentUnmatchedCredits: [String] = []
        /// Links matching proposed between rows already in the app: not made (another step's job).
        public var rentLeftAlone: [String] = []
        public var recharges: [String] = []
        public var taxYearNotes: [String] = []
        /// Employments recorded, and the year set-up (`TaxDataPlan`) changes.
        public var employments: [String] = []
        public var taxData: [String] = []
        /// Filed returns' figures against the app after the import.
        public var filedComparison: [String] = []
        public var mortgageHistory: [String] = []
        public var taxChanges: [TaxFigures.Change] = []
        /// Filed-year changes the plan accepts, with the reason.
        public var acceptedFiledChanges: [(change: TaxFigures.Change, reason: String)] = []
        public var unexplainedFiledChanges: [TaxFigures.Change] = []
        public var taxBefore = TaxFigures.Snapshot()
        public var taxAfter = TaxFigures.Snapshot()
        public var verification: [String] = []

        public static func == (lhs: Report, rhs: Report) -> Bool {
            lhs.rows == rhs.rows && lhs.verification == rhs.verification && lhs.taxChanges == rhs.taxChanges
        }

        public var failures: [String] { verification.filter { $0.hasPrefix("FAIL") } }
    }

    // MARK: Apply

    /// Everything, in the caller's write transaction; throws on a refusal or a failed check.
    public static func apply(db: Database, statements: [BBVAStatementParser.Statement], plan: Plan) throws -> Report {
        var report = Report()
        let statements = statements.sorted { $0.periodStart < $1.periodStart }
        report.statementLines = try checkStatements(statements)
        let classified = try classify(statements, plan: plan)
        guard let firstStatement = statements.first, let lastStatement = statements.last else { throw ImportError.badInput("no statements") }
        let calendar = MonthRange.calendar
        let openingDay = calendar.date(byAdding: .day, value: -1, to: firstStatement.periodStart)!

        // 1. Prerequisites: the accounts, not applied yet, and the history meeting the existing one.
        let accounts = try Account.fetchAll(db)
        func account(_ name: String) throws -> Account {
            guard let account = accounts.first(where: { $0.name == name }), account.id != nil else { throw ImportError.missing("account “\(name)”") }
            return account
        }
        let bbva = try account(bbvaAccountName), fund = try account(fundAccountName), loan = try account(loanAccountName), deposit = try account(depositAccountName)
        let bbvaId = bbva.id!, fundId = fund.id!, loanId = loan.id!, depositId = deposit.id!
        if try ImportBatch.filter(Column("sourceFileName") == plan.batchName).fetchCount(db) > 0 {
            throw ImportError.alreadyApplied("batch “\(plan.batchName)” exists")
        }
        for (name, id) in [(bbvaAccountName, bbvaId), (fundAccountName, fundId), (loanAccountName, loanId), (depositAccountName, depositId)] {
            guard let earliest = try BalanceSnapshot.filter(Column("accountId") == id).order(Column("date")).fetchOne(db) else {
                throw ImportError.missing("an opening balance on “\(name)”")
            }
            guard earliest.date > lastStatement.periodEnd || (name != bbvaAccountName && earliest.date == lastStatement.periodEnd) else {
                throw ImportError.overlap("“\(name)” already has a balance dated \(dayText(earliest.date)), within the statements")
            }
        }
        // No existing row within the statements' months (none can be duplicated).
        let existingEarly = try Transaction.filter([bbvaId, fundId, loanId].contains(Column("accountId")) && Column("date") <= lastStatement.periodEnd).fetchAll(db)
        if !existingEarly.isEmpty {
            let keys = Set(classified.map { "\(dayText($0.movement.date)) \($0.movement.amountMinorUnits) \($0.movement.description)" })
            let duplicates = existingEarly.filter { keys.contains("\(dayText($0.date)) \($0.amountMinorUnits) \($0.rawDescription)") }
            throw ImportError.overlap("\(existingEarly.count) existing row(s) dated on or before \(dayText(lastStatement.periodEnd))"
                                      + (duplicates.isEmpty ? "" : ", \(duplicates.count) identical to statement rows"))
        }
        // Where the new history must arrive: the existing openings.
        let bbvaOpening = try BalanceSnapshot.filter(Column("accountId") == bbvaId).order(Column("date")).fetchOne(db)!
        guard bbvaOpening.balanceMinorUnits == lastStatement.closingMinorUnits else {
            throw ImportError.badInput("the last statement closes at \(eur(lastStatement.closingMinorUnits)); BBVA's opening (\(dayText(bbvaOpening.date))) is \(eur(bbvaOpening.balanceMinorUnits))")
        }
        let firstExisting = try Transaction.filter(Column("accountId") == bbvaId).order(Column("date")).fetchOne(db)
        report.openings.append("BBVA: existing opening \(eur(bbvaOpening.balanceMinorUnits)) on \(dayText(bbvaOpening.date)) = \(lastStatement.label) closing; first existing row \(firstExisting.map { "\(dayText($0.date)) \($0.rawDescription) \(eur($0.amountMinorUnits))" } ?? "none")")

        let property = try plan.property.map { name in try Property.filter(Column("name") == name).fetchOne(db) }
            ?? (try Property.fetchAll(db).count == 1 ? try Property.fetchOne(db) : nil)
        guard let propertyId = property?.id else { throw ImportError.missing("the property \(plan.property ?? "")") }

        let balancesBefore = try balancesNow(db: db)
        report.taxBefore = try TaxFigures.snapshot(db: db)
        let historyBefore = try mortgageHistoryLine(db: db, propertyId: propertyId)

        // 2. New categories.
        for item in plan.newCategories {
            guard let type = TaxExpenseType(rawValue: item.taxType) else { throw ImportError.badInput("unknown tax type \(item.taxType)") }
            guard try Category.filter(Column("name") == item.name).fetchCount(db) == 0 else { throw ImportError.badInput("category “\(item.name)” already exists") }
            guard let group = try CategoryGroup.filter(Column("name") == item.group).fetchOne(db) else { throw ImportError.missing("group “\(item.group)”") }
            let category = try Categories.create(db: db, name: item.name, type: .expense, groupId: group.id)
            try TaxExpenseTypeMap.set(db: db, categoryId: category.id!, expenseType: type)
            report.categoriesCreated.append("“\(item.name)” in \(item.group), tax line \(type.displayName)")
        }

        // 3. Category ids per target.
        let categories = try Category.fetchAll(db)
        func categoryId(_ name: String) throws -> Int64 {
            guard let id = categories.first(where: { $0.name == name })?.id else { throw ImportError.missing("category “\(name)”") }
            return id
        }
        guard let loanCategory = try TransferCategories.category(db: db, forAccountId: loanId)?.id,
              let fundCategory = try TransferCategories.category(db: db, forAccountId: fundId)?.id,
              let depositCategory = try TransferCategories.category(db: db, forAccountId: depositId)?.id else {
            throw ImportError.missing("the loan's, fund's or deposit's transfer category")
        }
        let interestCategory = try categoryId(interestCategoryName)
        func categoryId(for target: Target) throws -> Int64? {
            switch target {
            case .category(let name): return try categoryId(name)
            case .uncategorised: return nil
            case .loanTransfer: return loanCategory
            case .fundTransfer: return fundCategory
            case .depositTransfer: return depositCategory
            }
        }

        // 4. The rows (deposit splits as two), through the import commit.
        struct Item {
            let classified: Classified
            let amount: Int
            let target: Target
            let note: String?
        }
        var splitByIndex: [Int: Int] = [:]
        for split in plan.depositSplits {
            let matches = classified.indices.filter { classified[$0].movement.date == day(split.date) && classified[$0].movement.amountMinorUnits > 0
                && classified[$0].target == .category("Rental income") }
            guard matches.count == 1, let amount = amount(split.deposit), amount > 0, amount < classified[matches[0]].movement.amountMinorUnits else {
                throw ImportError.badInput("deposit split \(split.date): \(matches.count) rent credit(s) that day, or a bad amount")
            }
            splitByIndex[matches[0]] = amount
        }
        var items: [Item] = []
        for (index, row) in classified.enumerated() {
            if let depositPart = splitByIndex[index] {
                let total = eur(row.movement.amountMinorUnits)
                items.append(Item(classified: row, amount: row.movement.amountMinorUnits - depositPart, target: row.target, note: "Rent part of a \(total) credit (rest: deposit)"))
                items.append(Item(classified: row, amount: depositPart, target: .depositTransfer, note: "Deposit part of a \(total) credit"))
            } else {
                items.append(Item(classified: row, amount: row.movement.amountMinorUnits, target: row.target, note: row.note))
            }
        }
        let parsed = items.map { ParsedTransaction(date: $0.classified.movement.date, rawDescription: $0.classified.movement.description, amountMinorUnits: $0.amount) }
        let fingerprints = TransactionFingerprint.computeAll(accountId: bbvaId, transactions: parsed)
        var staged: [StagedTransaction] = []
        var decisions: [ImportDecision] = []
        for (index, item) in items.enumerated() {
            let category = try categoryId(for: item.target)
            let row = StagedTransaction(parsed: parsed[index], suggestedCategoryId: category, source: category == nil ? .none : .manual, confidence: 1, fingerprint: fingerprints[index])
            staged.append(row)
            decisions.append(ImportDecision(stagedId: row.id, finalCategoryId: category, learnRule: false, note: item.note))
        }
        try ImportCoordinator.commit(db: db, accountId: bbvaId, sourceFileName: plan.batchName, staged: staged, decisions: decisions)
        guard let batchId = try ImportBatch.filter(Column("sourceFileName") == plan.batchName).fetchOne(db)?.id else { throw ImportError.missing("the new batch") }
        let saved = try Transaction.filter(Column("importBatchId") == batchId).fetchAll(db)
        let byFingerprint = Dictionary(saved.map { ($0.fingerprint, $0) }, uniquingKeysWith: { a, _ in a })
        let savedRows: [Transaction] = try fingerprints.map { print in
            guard let row = byFingerprint[print] else { throw ImportError.missing("a saved row") }
            return row
        }

        // 5. Openings the day before the first statement.
        func addSnapshot(_ accountId: Int64, signed: Int, note: String) throws {
            var snapshot = BalanceSnapshot(accountId: accountId, date: openingDay, balanceMinorUnits: signed, note: note)
            try snapshot.insert(db)
        }
        try addSnapshot(bbvaId, signed: firstStatement.openingMinorUnits, note: "Opening balance (statement \(firstStatement.label))")
        report.openings.append("BBVA: opening \(eur(firstStatement.openingMinorUnits)) on \(dayText(openingDay)) (statement \(firstStatement.label))")

        // 6. Mortgage: each instalment a transfer to the loan, the leg there, and the interest.
        let receipts = statements.flatMap(\.loanReceipts).sorted { $0.number < $1.number }
        let instalmentRows = items.indices.filter { items[$0].target == .loanTransfer }
        guard instalmentRows.count == receipts.count else {
            throw ImportError.badInput("\(instalmentRows.count) instalment rows, \(receipts.count) settled receipts in the statements")
        }
        if let firstReceipt = receipts.first {
            let owedBefore = firstReceipt.outstandingAfterMinorUnits + firstReceipt.capitalMinorUnits
            try addSnapshot(loanId, signed: -owedBefore, note: "Opening: owed before instalment \(firstReceipt.number) (statement \(firstStatement.label))")
            report.openings.append("BBVA mortgage: opening \(eur(-owedBefore)) on \(dayText(openingDay)) (owed before instalment \(firstReceipt.number))")
        }
        // The saved rows as statement movements (the pairing reads their day and amount).
        let savedMovements = savedRows.map { BBVAStatementParser.Movement(date: $0.date, valueDate: $0.date, description: $0.rawDescription, amountMinorUnits: $0.amountMinorUnits, balanceAfterMinorUnits: nil) }
        let instalments = BBVAStatementLegs.matchInstalments(movements: savedMovements, candidates: instalmentRows, receipts: receipts)
        if let receipt = instalments.receiptsWithoutMovement.first {
            throw ImportError.missing("the instalment row of receipt \(receipt.number) (\(dayText(receipt.operationDate)) \(eur(-receipt.totalMinorUnits)))")
        }
        for match in instalments.matches {
            let receipt = match.receipt
            try BBVAStatementLegs.addInstalment(db: db, instalmentRowId: savedRows[match.movementIndex].id!, receipt: receipt, loanAccountId: loanId, interestCategoryId: interestCategory)
            report.instalments.append(InstalmentReport(receipt: receipt.number, date: receipt.operationDate, valueDate: receipt.valueDate, totalMinorUnits: receipt.totalMinorUnits,
                                                       capitalMinorUnits: receipt.capitalMinorUnits, chargesMinorUnits: BBVAStatementLegs.charges(receipt), tan: receipt.tan,
                                                       owedAfterMinorUnits: receipt.outstandingAfterMinorUnits))
        }

        // 7. Fund: each subscription a transfer to it, then each month's value.
        let subscriptionRows = items.indices.filter { items[$0].target == .fundTransfer }
        // Each fund movement pairs with one subscription debit of its amount within a few days.
        let fundMovements = statements.compactMap(\.fund).flatMap(\.movements)
        let fundPairs = BBVAStatementLegs.pairFundMovements(movements: savedMovements, candidates: subscriptionRows, fundMovements: fundMovements, pairingDays: fundPairingDays)
        if let movement = fundPairs.unpairedFundMovements.first {
            throw ImportError.badInput("the fund movement of \(dayText(movement.date)) \(eur(movement.amountMinorUnits)) has no subscription debit within \(fundPairingDays) days")
        }
        guard fundPairs.unpairedSubscriptions.isEmpty else {
            throw ImportError.badInput("subscription debits with no fund movement: " + fundPairs.unpairedSubscriptions.map { "\(dayText(savedRows[$0].date)) \(eur(savedRows[$0].amountMinorUnits))" }.joined(separator: ", "))
        }
        for pair in fundPairs.pairs { try BBVAStatementLegs.addFundSubscription(db: db, subscriptionRowId: savedRows[pair.movementIndex].id!, fundAccountId: fundId) }
        if let firstFund = firstStatement.fund {
            try addSnapshot(fundId, signed: firstFund.openingMinorUnits, note: "Opening: \(firstFund.openingUnits) units at \(firstFund.openingPrice) (statement \(firstStatement.label))")
            report.openings.append("BBVA retirement fund: opening \(eur(firstFund.openingMinorUnits)) on \(dayText(openingDay)) (\(firstFund.openingUnits) units at \(firstFund.openingPrice))")
            for statement in statements {
                guard let value = statement.fund else { continue }
                let movement = try BBVAStatementLegs.marketMovement(db: db, fundAccountId: fundId, statement: statement, since: openingDay, openingMinorUnits: firstFund.openingMinorUnits)?.amountMinorUnits ?? 0
                report.fundMovements.append("\(statement.label): value \(eur(value.closingMinorUnits)) (\(value.closingUnits) × \(value.closingPrice)); market movement \(eur(movement))")
            }
        }

        // 8. The tenant deposit: the liability's opening (nothing held) and the legs.
        let depositRows = items.indices.filter { items[$0].target == .depositTransfer }
        if !depositRows.isEmpty {
            try addSnapshot(depositId, signed: 0, note: "Opening: no deposit held (statement \(firstStatement.label))")
            for index in depositRows {
                let leg = try ManualTransactions.addOtherSide(db: db, transactionId: savedRows[index].id!, accountId: depositId)
                report.deposit.append("\(dayText(leg.date)) \(savedRows[index].rawDescription) \(eur(savedRows[index].amountMinorUnits)) → leg \(eur(leg.amountMinorUnits))")
            }
        }

        // 9. Receipts kept on their own, now paid in the history.
        let receiptsOnTheirOwn = try TaxPolicyReceipt.filter(Column("propertyId") == propertyId && Column("transactionId") == nil).fetchAll(db)
        let typeByCategory = Dictionary(try TaxExpenseTypeMap.entries(db: db, propertyId: propertyId).map { ($0.category.id!, $0.expenseType) }, uniquingKeysWith: { a, _ in a })
        for link in plan.policyReceiptLinks {
            guard let amount = amount(link.amount) else { throw ImportError.badInput("receipt amount \(link.amount)") }
            let matches = receiptsOnTheirOwn.filter { $0.date == day(link.receiptDate) && $0.amountMinorUnits == amount }
            guard matches.count == 1, var receipt = matches.first else {
                throw ImportError.missing("one receipt on its own of \(link.receiptDate) \(link.amount) (found \(matches.count))")
            }
            let rows = savedRows.filter { $0.date == day(link.transactionDate) && $0.amountMinorUnits == -amount }
            guard rows.count == 1, let row = rows.first else { throw ImportError.missing("one debit of \(link.transactionDate) \(link.amount) (found \(rows.count))") }
            guard let category = row.categoryId, typeByCategory[category] == receipt.expenseType else {
                throw ImportError.badInput("the debit of \(link.transactionDate) \(link.amount) isn't in a \(receipt.expenseType.displayName) category")
            }
            receipt.transactionId = row.id
            try TaxPolicyReceipts.save(db: db, &receipt)
            report.policyReceipts.append("\(receipt.expenseType.displayName) receipt \(link.receiptDate) \(eur(amount)) (\(receipt.label)) → debit \(link.transactionDate) “\(row.rawDescription)”")
        }

        // 10. Manual items for costs now in the history.
        let loanRows = try Transaction.filter(Column("accountId") == loanId && Column("categoryId") == interestCategory && Column("date") <= lastStatement.periodEnd).fetchAll(db)
        for change in plan.manualItems {
            guard let type = TaxExpenseType(rawValue: change.expenseType), let amount = amount(change.amount) else { throw ImportError.badInput("manual item \(change.expenseType) \(change.amount)") }
            let matches = try TaxManualItem.filter(Column("startYear") == change.startYear && Column("propertyId") == propertyId
                                                   && Column("expenseType") == type.rawValue && Column("amountMinorUnits") == amount).fetchAll(db)
            guard matches.count == 1, var item = matches.first else { throw ImportError.missing("one \(change.startYear) \(type.displayName) manual item of \(change.amount) (found \(matches.count))") }
            var replaced = 0
            var described: [String] = []
            for payment in change.replacedBy {
                guard let paid = self.amount(payment.amount) else { throw ImportError.badInput("payment \(payment.amount)") }
                let pool = payment.onLoan == true ? loanRows : savedRows
                let rows = pool.filter { $0.date == day(payment.date) && $0.amountMinorUnits == -paid }
                guard rows.count == 1, let row = rows.first, let category = row.categoryId, typeByCategory[category] == type || (type == .financeCost && category == interestCategory) else {
                    throw ImportError.badInput("manual item \(item.label): no single \(type.displayName) row of \(payment.date) \(payment.amount)")
                }
                replaced += paid
                described.append("\(payment.date) “\(row.rawDescription)” \(eur(paid))")
            }
            let left = try change.newAmount.map { text -> Int in
                guard let value = self.amount(text) else { throw ImportError.badInput("new amount \(text)") }
                return value
            } ?? 0
            guard replaced + left == item.amountMinorUnits else {
                throw ImportError.badInput("manual item \(item.label): replaced \(eur(replaced)) + left \(eur(left)) ≠ \(eur(item.amountMinorUnits))")
            }
            let old = "\(change.startYear) \(type.displayName) “\(item.label)” \(Money.format(item.amountMinorUnits, currency: item.currency))"
            if left == 0 {
                _ = try TaxManualItems.delete(db: db, id: item.id!)
                report.manualItems.append("removed \(old) — now the rows " + described.joined(separator: ", "))
            } else {
                item.amountMinorUnits = left
                if let label = change.newLabel { item.label = label }
                try TaxManualItems.save(db: db, &item)
                report.manualItems.append("reduced \(old) to \(eur(left)) (“\(item.label)”) — the rest now the rows " + described.joined(separator: ", "))
            }
        }

        // 11. Utility invoices of the period, linked to the debits that paid them.
        if plan.linkUtilityInvoices {
            let providers = try Recharges.providers(db: db, propertyId: propertyId)
            let windowStart = calendar.date(byAdding: .day, value: -UtilityInvoiceIntake.daysAfter, to: firstStatement.periodStart)!
            let invoices = try UtilityInvoice.filter(Column("transactionId") == nil && Column("issueDate") >= windowStart && Column("issueDate") <= lastStatement.periodEnd)
                .order(Column("issueDate"), Column("id")).fetchAll(db)
                .filter { invoice in providers.contains { $0.id == invoice.providerId } }
            let ids = Set(savedRows.compactMap(\.id))
            for var invoice in invoices {
                let provider = providers.first { $0.id == invoice.providerId }
                let best = try UtilityInvoiceIntake.bestPayment(db: db, propertyId: propertyId, provider: provider, amountMinorUnits: invoice.amountMinorUnits,
                                                                issueDate: invoice.issueDate, excludingInvoice: invoice.id)
                let label = "invoice \(invoice.id!) \(provider?.name ?? "?") issued \(dayText(invoice.issueDate)) \(eur(invoice.amountMinorUnits))"
                guard let best, ids.contains(best.id!) else {
                    report.invoicesUnmatched.append(label)
                    continue
                }
                invoice.transactionId = best.id
                try UtilityInvoiceIntake.record(db: db, &invoice)
                report.invoices.append("\(label) → \(dayText(best.date)) “\(best.rawDescription)”")
            }
        }

        // 12. Rent receipts and the credits that paid them.
        let tenancies = Dictionary(try Tenancy.fetchAll(db).map { ($0.id!, $0) }, uniquingKeysWith: { a, _ in a })
        // Recharges of a tenancy without itemised statements: a paid statement per month.
        let rentCategory = try? categoryId("Rental income")
        for entry in plan.recharges {
            guard let tenancy = tenancies.values.first(where: { $0.referenceLabel == entry.tenancy && $0.propertyId == propertyId }),
                  let monthStart = day(entry.month + "-01") else { throw ImportError.missing("tenancy \(entry.tenancy) or month \(entry.month)") }
            guard try RechargeStatement.filter(Column("tenancyId") == tenancy.id! && Column("month") == monthStart).fetchCount(db) == 0 else {
                throw ImportError.badInput("\(entry.tenancy) already has a recharge statement for \(entry.month)")
            }
            var rows: [(Transaction, Int)] = []
            for credit in entry.credits {
                guard let part = amount(credit.amount), part > 0 else { throw ImportError.badInput("recharge \(credit.amount)") }
                let taken = Set(rows.compactMap { $0.0.id })
                let sameDay = savedRows.filter { $0.date == day(credit.date) && $0.categoryId != nil && $0.categoryId == rentCategory && !taken.contains($0.id!) }
                // The credit of exactly that amount, else the one larger credit (its rent part linked elsewhere).
                let exact = sameDay.filter { $0.amountMinorUnits == part }
                let matches = exact.isEmpty ? sameDay.filter { $0.amountMinorUnits > part } : exact
                guard matches.count == 1, let row = matches.first else { throw ImportError.missing("one tenant credit of \(credit.date) for a recharge of \(credit.amount) (found \(matches.count))") }
                rows.append((row, part))
            }
            let total = rows.reduce(0) { $0 + $1.1 }
            let statement = try Recharges.draftStatement(db: db, tenancyId: tenancy.id!, month: monthStart, addPending: false)
            _ = try Recharges.saveManualLine(db: db, statementId: statement.id!, description: entry.description, amountMinorUnits: total)
            _ = try Recharges.markSent(db: db, statementId: statement.id!, at: monthStart)
            for (row, part) in rows { _ = try Recharges.linkPayment(db: db, statementId: statement.id!, transactionId: row.id!, amountMinorUnits: part) }
            let status = try RechargeStatement.fetchOne(db, key: statement.id!)?.status.rawValue ?? "?"
            report.recharges.append("\(entry.tenancy) \(entry.month): \(eur(total)) (\(status)) ← " + rows.map { "\(dayText($0.0.date)) “\($0.0.rawDescription)” \(eur($0.1))\($0.1 < $0.0.amountMinorUnits ? " of \(eur($0.0.amountMinorUnits))" : "")" }.joined(separator: " + "))
        }
        for link in plan.rentReceiptLinks {
            guard let tenancy = tenancies.values.first(where: { $0.referenceLabel == link.tenancy && $0.propertyId == propertyId }),
                  let amount = amount(link.amount),
                  let receipt = try RentReceipt.filter(Column("tenancyId") == tenancy.id! && Column("receiptNumber") == link.receiptNumber).fetchOne(db),
                  receipt.amountMinorUnits == amount else {
                throw ImportError.missing("rent receipt \(link.receiptNumber) of \(link.tenancy) for \(link.amount)")
            }
            let paidTotal = link.credits.compactMap { self.amount($0.amount) }.reduce(0, +)
            guard link.credits.count == link.credits.compactMap({ self.amount($0.amount) }).count, paidTotal == amount else {
                throw ImportError.badInput("rent receipt \(link.receiptNumber) of \(link.tenancy): the credits add up to \(eur(paidTotal)), not \(link.amount)")
            }
            var parts: [String] = []
            for credit in link.credits {
                guard let paid = self.amount(credit.amount) else { throw ImportError.badInput("credit \(credit.amount)") }
                let rows = savedRows.filter { $0.date == day(credit.date) && $0.amountMinorUnits == paid }
                guard rows.count == 1, let row = rows.first else { throw ImportError.missing("one credit of \(credit.date) \(credit.amount) (found \(rows.count))") }
                try RentReceiptMatching.link(db: db, receiptId: receipt.id!, transactionId: row.id!, rentMinorUnits: paid)
                parts.append("\(credit.date) “\(row.rawDescription)” \(eur(paid))")
            }
            report.rentLinks.append("\(link.tenancy) receipt \(receipt.receiptNumber) (\(dayText(receipt.periodStart)) – \(dayText(receipt.periodEnd)), \(eur(receipt.amountMinorUnits))) ← "
                                    + parts.joined(separator: " + ") + " (linked by the plan)")
        }
        if plan.matchRentReceipts {
            var result = try RentReceiptMatching.match(db: db, propertyId: propertyId)
            // Only the new rows: links matching made between rows already in the app are undone
            // (made in this transaction, so removed outright, not dismissed).
            let newIds = Set(savedRows.compactMap(\.id))
            for link in result.created where !newIds.contains(link.transactionId) {
                _ = try RentReceiptPayment.deleteOne(db, key: link.id!)
                report.rentLeftAlone.append("receipt #\(link.rentReceiptId) ↔ transaction #\(link.transactionId)")
            }
            result.created = result.created.filter { newIds.contains($0.transactionId) }
            let receipts = Dictionary(try RentReceipt.fetchAll(db).map { ($0.id!, $0) }, uniquingKeysWith: { a, _ in a })
            for link in result.created {
                guard let receipt = receipts[link.rentReceiptId], let credit = try Transaction.fetchOne(db, key: link.transactionId) else { continue }
                report.rentLinks.append("\(tenancies[receipt.tenancyId]?.referenceLabel ?? "tenancy \(receipt.tenancyId)") receipt \(receipt.receiptNumber) "
                                        + "(\(dayText(receipt.periodStart)) – \(dayText(receipt.periodEnd)), \(eur(receipt.amountMinorUnits))) ← \(dayText(credit.date)) “\(credit.rawDescription)” "
                                        + "rent \(eur(link.rentMinorUnits))\(link.otherMinorUnits != 0 ? " + other \(eur(link.otherMinorUnits))" : "")")
            }
            report.rentUnmatchedReceipts = result.unmatchedReceipts.filter { $0.periodStart <= lastStatement.periodEnd && $0.periodEnd >= firstStatement.periodStart }.map { receipt in
                "\(tenancies[receipt.tenancyId]?.referenceLabel ?? "tenancy \(receipt.tenancyId)") receipt \(receipt.receiptNumber) (\(dayText(receipt.periodStart)) – \(dayText(receipt.periodEnd)), \(eur(receipt.amountMinorUnits)))"
            }
            report.rentUnmatchedCredits = result.unmatchedCredits.filter { $0.date <= lastStatement.periodEnd && $0.date >= firstStatement.periodStart }.map { "\(dayText($0.date)) “\($0.rawDescription)” \(eur($0.amountMinorUnits))" }
        }

        // 13. The year set-up: employments from the filed return, then the tax data plan.
        for entry in plan.employments {
            guard let person = try Person.filter(Column("name") == entry.person).fetchOne(db), let personId = person.id else { throw ImportError.missing("person “\(entry.person)”") }
            guard let source = EmploymentIncomeSource(rawValue: entry.source), let pay = amount(entry.pay), let tax = amount(entry.tax) else {
                throw ImportError.badInput("employment \(entry.employer): source, pay or tax")
            }
            let existing = try Employments.employments(db: db, startYear: entry.startYear, personId: personId)
            guard !existing.contains(where: { $0.employerName.caseInsensitiveCompare(entry.employer) == .orderedSame
                || ($0.payeReference != nil && $0.payeReference == (try? Employments.normalizedPAYEReference(entry.payeReference))) }) else {
                throw ImportError.badInput("\(entry.person) already has the \(entry.startYear) employment \(entry.employer)")
            }
            var employment = Employment(startYear: entry.startYear, personId: personId, employerName: entry.employer,
                                        payeReference: try Employments.normalizedPAYEReference(entry.payeReference), notes: entry.notes)
            try Employments.save(db: db, &employment)
            var income = EmploymentIncome(employmentId: employment.id!, source: source, payMinorUnits: pay, taxDeductedMinorUnits: tax, entryMethod: .manual, notes: entry.notes)
            try Employments.save(db: db, &income)
            var line = "\(UKTaxYear(startYear: entry.startYear).label) \(entry.person): \(entry.employer) (\(employment.payeReference ?? "no PAYE ref")) pay \(Money.format(pay, currency: .gbp)), tax \(Money.format(tax, currency: .gbp))"
            for benefit in entry.benefits ?? [] {
                guard let kind = BenefitKind(rawValue: benefit.kind), let value = amount(benefit.amount) else { throw ImportError.badInput("benefit \(benefit.kind) \(benefit.amount)") }
                var row = BenefitInKind(employmentId: employment.id!, kind: kind, description: benefit.description, cashEquivalentMinorUnits: value, entryMethod: .manual, notes: entry.notes)
                try Employments.save(db: db, &row)
                line += ", benefit \(kind.displayName) \(Money.format(value, currency: .gbp))"
            }
            report.employments.append(line)
        }
        for entry in plan.taxYearNotes {
            let years = try TaxYear.filter(Column("startYear") == entry.startYear).fetchAll(db)
            guard !years.isEmpty else { throw ImportError.missing("tax year \(entry.startYear)") }
            for var year in years where year.notes != entry.note {
                year.notes = entry.note
                try TaxYears.save(db: db, &year)
            }
            report.taxYearNotes.append("\(UKTaxYear(startYear: entry.startYear).label): \(entry.note)")
        }
        if let taxData = plan.taxData {
            do {
                let outcome = try TaxDataPlan.apply(db: db, plan: taxData)
                report.taxData = outcome.changes.map { "\($0.section): \($0.kind) \($0.text)" }
            } catch let error as TaxDataPlan.PlanError {
                throw ImportError.badInput("tax data plan: \(error)")
            }
        }

        // 14. Verification.
        func check(_ ok: Bool, _ line: String) { report.verification.append((ok ? "OK   " : "FAIL ") + line) }
        let all = try Transaction.fetchAll(db)
        let snapshots = try BalanceSnapshot.fetchAll(db)
        func balance(_ accountId: Int64, at date: Date?) -> Int? {
            NetWorthCalculator.balance(accountId: accountId, at: date.map { calendar.date(byAdding: .day, value: 1, to: $0)!.addingTimeInterval(-1) },
                                       snapshots: snapshots, transactions: all)?.native
        }
        for (name, id) in [(bbvaAccountName, bbvaId), (loanAccountName, loanId), (fundAccountName, fundId), (depositAccountName, depositId)] {
            let added = all.filter { $0.accountId == id && $0.date > openingDay && $0.date <= lastStatement.periodEnd }
            let byCategory = Dictionary(grouping: added) { $0.categoryId.flatMap { id in categories.first { $0.id == id }?.name } ?? (id == bbvaId ? "(uncategorised)" : "other") }
                .map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
            report.accountCounts.append("\(name): \(added.count) rows, total \(eur(added.reduce(0) { $0 + $1.amountMinorUnits })) (\(byCategory))")
        }
        check(savedRows.count == items.count, "rows saved: \(savedRows.count) (\(classified.count) statement rows, \(splitByIndex.count) split)")
        for statement in statements {
            report.monthChecks.append(MonthCheck(label: statement.label, account: bbvaAccountName, statementMinorUnits: statement.closingMinorUnits, appMinorUnits: balance(bbvaId, at: statement.periodEnd)))
            if let value = statement.fund {
                report.monthChecks.append(MonthCheck(label: statement.label, account: fundAccountName, statementMinorUnits: value.closingMinorUnits, appMinorUnits: balance(fundId, at: statement.periodEnd)))
            }
            if let owed = statement.loanOutstandingMinorUnits {
                report.monthChecks.append(MonthCheck(label: statement.label, account: loanAccountName, statementMinorUnits: -owed, appMinorUnits: balance(loanId, at: statement.periodEnd)))
            }
        }
        for name in [bbvaAccountName, fundAccountName, loanAccountName] {
            let checks = report.monthChecks.filter { $0.account == name }
            check(checks.allSatisfy(\.ok), "\(name): every month end equals the statement (\(checks.filter(\.ok).count) of \(checks.count))")
        }
        // The new history meets the existing openings: the running sum up to them equals them.
        for (name, id, opening) in [(bbvaAccountName, bbvaId, firstStatement.openingMinorUnits),
                                     (fundAccountName, fundId, firstStatement.fund?.openingMinorUnits ?? 0),
                                     (loanAccountName, loanId, -(receipts.first.map { $0.outstandingAfterMinorUnits + $0.capitalMinorUnits } ?? 0)),
                                     (depositAccountName, depositId, 0)] {
            guard let existing = snapshots.filter({ $0.accountId == id && $0.date > openingDay }).min(by: { $0.date < $1.date }) else { continue }
            let running = opening + all.filter { $0.accountId == id && $0.date > openingDay && $0.date <= existing.date }.reduce(0) { $0 + $1.amountMinorUnits }
            check(running == existing.balanceMinorUnits || (id == depositId && depositRows.isEmpty),
                  "\(name): opening \(eur(opening)) + the new rows = \(eur(running)), the existing balance of \(dayText(existing.date)) \(eur(existing.balanceMinorUnits))")
        }
        let balancesAfter = try balancesNow(db: db)
        let moved = balancesAfter.filter { balancesBefore[$0.key] != $0.value }
        check(moved.isEmpty, "every account's balance today unchanged" + (moved.isEmpty ? "" : ": " + moved.keys.sorted().joined(separator: ", ")))
        let links = try TransferLink.active.fetchAll(db)
        let linked = Set(links.flatMap { [$0.outTransactionId, $0.inTransactionId] })
        let transferRows = items.indices.filter { [.loanTransfer, .fundTransfer, .depositTransfer].contains(items[$0].target) }
        check(transferRows.allSatisfy { linked.contains(savedRows[$0].id!) }, "all \(transferRows.count) loan, fund and deposit transfers linked to their legs")
        let accountNames = Dictionary(accounts.compactMap { a in a.id.map { ($0, a.displayName) } }, uniquingKeysWith: { a, _ in a })
        let newIds = Set(savedRows.compactMap(\.id))
        for link in links where newIds.contains(link.outTransactionId) || newIds.contains(link.inTransactionId) {
            let mine = newIds.contains(link.outTransactionId) ? link.outTransactionId : link.inTransactionId
            let otherId = mine == link.outTransactionId ? link.inTransactionId : link.outTransactionId
            guard let row = all.first(where: { $0.id == mine }), let other = all.first(where: { $0.id == otherId }),
                  ![loanId, fundId, depositId].contains(other.accountId) else { continue }
            report.transferLinks.append("\(dayText(row.date)) \(row.rawDescription) \(eur(row.amountMinorUnits)) ↔ \(accountNames[other.accountId] ?? "?") \(dayText(other.date)) \(other.rawDescription)")
        }

        report.mortgageHistory = [historyBefore.map { "before: " + $0 } ?? "before: no estimate", (try mortgageHistoryLine(db: db, propertyId: propertyId)).map { "after: " + $0 } ?? "after: no estimate"]
        report.taxAfter = try TaxFigures.snapshot(db: db)
        report.taxChanges = TaxFigures.changes(from: report.taxBefore, to: report.taxAfter)
        // Filed and paid years: a figure that moves must land on the filed return's, or be accepted
        // for that year (and person) with a reason; anything else fails.
        let accepted = try plan.acceptFiledChanges.map { ($0, try NSRegularExpression(pattern: $0.field)) }
        func expected(_ key: TaxFigures.Key) -> String? {
            plan.filedReturns.first(where: { $0.startYear == key.startYear && $0.person == key.person })?.fields[key.field]
        }
        var unexplained: [TaxFigures.Change] = []
        var landed = 0
        for change in report.taxChanges where TaxFigures.isFiled(report.taxBefore, startYear: change.key.startYear, includePaid: true) {
            let field = change.key.field
            if let text = expected(change.key) {
                if Self.matches(change.after, filed: text) { landed += 1 } else { unexplained.append(change) }
                continue
            }
            if let (rule, _) = accepted.first(where: { rule, regex in
                rule.startYear == change.key.startYear && (rule.person == nil || rule.person == change.key.person)
                    && regex.firstMatch(in: field, range: NSRange(field.startIndex..., in: field)) != nil }) {
                report.acceptedFiledChanges.append((change, rule.reason))
            } else {
                unexplained.append(change)
            }
        }
        report.unexplainedFiledChanges = unexplained
        for filed in plan.filedReturns.sorted(by: { ($0.startYear, $0.person) < ($1.startYear, $1.person) }) {
            for (field, text) in filed.fields.sorted(by: { $0.key < $1.key }) {
                let key = TaxFigures.Key(startYear: filed.startYear, person: filed.person, field: field)
                let app = report.taxAfter.values[key]
                report.filedComparison.append("\(Self.matches(app, filed: text) ? "MATCH   " : "DIFFERS ") \(UKTaxYear(startYear: filed.startYear).label) \(filed.person) \(field): filed \(text), app \(app?.description ?? "—")"
                                              + (report.taxBefore.values[key] == app ? " (unchanged by the import)" : ""))
            }
        }
        check(unexplained.isEmpty, "filed and paid tax years: no figure moves except onto the filed return (\(landed)) or as accepted for that year (\(report.acceptedFiledChanges.count))"
              + (unexplained.isEmpty ? "" : ": \(unexplained.count) figure(s) differ unexplained"))

        // Rows by category, as saved.
        let names = Dictionary(try Category.fetchAll(db).compactMap { c in c.id.map { ($0, c.name) } }, uniquingKeysWith: { a, _ in a })
        let refreshed = Dictionary(try Transaction.filter(keys: Array(newIds)).fetchAll(db).map { ($0.id!, $0) }, uniquingKeysWith: { a, _ in a })
        for (index, item) in items.enumerated() {
            let row = refreshed[savedRows[index].id!] ?? savedRows[index]
            report.rows.append(RowReport(date: row.date, description: row.rawDescription, amountMinorUnits: row.amountMinorUnits,
                                         category: row.categoryId.flatMap { names[$0] }, reason: item.classified.reason + (item.note.map { "; \($0)" } ?? "")))
        }
        let grouped = Dictionary(grouping: report.rows) { $0.category ?? "(uncategorised)" }
        report.byCategory = grouped.map { ($0.key, $0.value.count, $0.value.reduce(0) { $0 + $1.amountMinorUnits }) }.sorted { $0.name < $1.name }

        if !report.failures.isEmpty { throw ImportError.verificationFailed(text(report)) }
        return report
    }

    // MARK: Helpers

    /// Whether the app's figure is the filed one: an amount ("540.59" = 54059 minor units), a
    /// count ("2"), or a text.
    static func matches(_ value: TaxFigures.Value?, filed text: String) -> Bool {
        switch value {
        case .amount(let number)?: return amount(text) == number || Int(text) == number
        case .text(let string)?: return string == text
        default: return false
        }
    }

    static func balancesNow(db: Database) throws -> [String: Int] {
        let snapshots = try BalanceSnapshot.fetchAll(db)
        let transactions = try Transaction.fetchAll(db)
        var result: [String: Int] = [:]
        for account in try Account.fetchAll(db) {
            result[account.displayName] = NetWorthCalculator.balance(accountId: account.id, at: nil, snapshots: snapshots, transactions: transactions)?.native ?? 0
        }
        return result
    }

    static func sumSince(db: Database, accountId: Int64, after: Date, through: Date) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(amountMinorUnits), 0) FROM transaction_ WHERE accountId = ? AND date > ? AND date <= ?",
                         arguments: [accountId, after, through]) ?? 0
    }

    static func mortgageHistoryLine(db: Database, propertyId: Int64) throws -> String? {
        guard let estimate = try MortgageHistory.estimate(db: db, propertyId: propertyId) else { return nil }
        let anchor = estimate.anchor
        return "anchor instalment \(anchor.number) due \(dayText(anchor.due)), paid \(dayText(anchor.paidOn)), owed before it \(eur(anchor.owedBeforeMinorUnits)); "
            + "estimate \(eur(estimate.estimatedOwedBeforeMinorUnits)); gap \(eur(estimate.gapMinorUnits))"
            + (estimate.isLargeGap ? " (large)" : "") + (estimate.suggestedPrincipalMinorUnits.map { "; suggested amount borrowed \(eur($0))" } ?? "")
    }

    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return BBVAStatementParser.date(parts[0], parts[1], parts[2])
    }

    static func amount(_ text: String) -> Int? { BBVAHistoryImport.minorUnits(text) }

    public static func dayText(_ date: Date) -> String { BBVAFundMortgageImport.day(date) }

    static func eur(_ minorUnits: Int) -> String { Money.format(minorUnits, currency: .eur) }

    // MARK: Text

    public static func text(_ report: Report) -> String {
        var out: [String] = []
        func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }
        func lpad(_ text: String, _ width: Int) -> String { text.count >= width ? text : String(repeating: " ", count: width - text.count) + text }
        out.append("== Statements ==")
        out += report.statementLines.map { "  " + $0 }
        out.append("== Openings ==")
        out += report.openings.map { "  " + $0 }
        out.append("== Rows added per account ==")
        out += report.accountCounts.map { "  " + $0 }
        out.append("== Month ends: statement vs app ==")
        for check in report.monthChecks {
            out.append("  \(check.label) \(pad(check.account, 22)) \(lpad(eur(check.statementMinorUnits), 14)) \(lpad(check.appMinorUnits.map(eur) ?? "—", 14)) \(check.ok ? "OK" : "DIFFERS")")
        }
        out.append("== Rows by category (count, total) ==")
        for entry in report.byCategory { out.append("  \(pad(entry.name, 34)) \(lpad(String(entry.count), 4)) \(lpad(eur(entry.total), 14))") }
        out.append("== Every row ==")
        for row in report.rows {
            out.append("  \(dayText(row.date)) \(pad(row.description, 34)) \(lpad(eur(row.amountMinorUnits), 12))  \(pad(row.category ?? "(uncategorised)", 30)) \(row.reason)")
        }
        let uncategorised = report.rows.filter { $0.category == nil }
        out.append("== Uncategorised (\(uncategorised.count), left for review) ==")
        for row in uncategorised { out.append("  \(dayText(row.date)) \(pad(row.description, 34)) \(lpad(eur(row.amountMinorUnits), 12))") }
        out.append("== Transfer links with other accounts ==")
        out += report.transferLinks.isEmpty ? ["  none"] : report.transferLinks.map { "  " + $0 }
        out.append("== Mortgage instalments ==")
        for item in report.instalments {
            out.append("  receipt \(item.receipt) paid \(dayText(item.date)) (due \(dayText(item.valueDate))): \(eur(item.totalMinorUnits)) = capital \(eur(item.capitalMinorUnits)) + interest \(eur(item.chargesMinorUnits))"
                       + (item.tan.map { String(format: " at TAN %.3f%%", $0) } ?? "") + "; owed after \(eur(item.owedAfterMinorUnits))")
        }
        let byTaxYear = Dictionary(grouping: report.instalments) { BBVAFundMortgageImport.ukTaxYear(of: $0.date) }
        for year in byTaxYear.keys.sorted() {
            let rows = byTaxYear[year]!
            out.append("  interest \(year)/\(String(format: "%02d", (year + 1) % 100)) (payment date): \(eur(rows.reduce(0) { $0 + $1.chargesMinorUnits })) over \(rows.count) instalments")
        }
        out.append("  history estimate " + report.mortgageHistory.joined(separator: "\n  history estimate "))
        out.append("== Fund ==")
        out += report.fundMovements.map { "  " + $0 }
        out.append("== Tenant deposit ==")
        out += report.deposit.isEmpty ? ["  none"] : report.deposit.map { "  " + $0 }
        out.append("== Categories created ==")
        out += report.categoriesCreated.isEmpty ? ["  none"] : report.categoriesCreated.map { "  " + $0 }
        out.append("== Receipts kept on their own, now linked ==")
        out += report.policyReceipts.isEmpty ? ["  none"] : report.policyReceipts.map { "  " + $0 }
        out.append("== Manual items replaced by the rows ==")
        out += report.manualItems.isEmpty ? ["  none"] : report.manualItems.map { "  " + $0 }
        out.append("== Utility invoices linked to their debits ==")
        out += report.invoices.isEmpty ? ["  none"] : report.invoices.map { "  " + $0 }
        if !report.invoicesUnmatched.isEmpty {
            out.append("  no debit found in these statements:")
            out += report.invoicesUnmatched.map { "    " + $0 }
        }
        out.append("== Rent receipts matched ==")
        out += report.rentLinks.isEmpty ? ["  none"] : report.rentLinks.map { "  " + $0 }
        if !report.rentUnmatchedReceipts.isEmpty {
            out.append("  receipts up to the last statement still unmatched:")
            out += report.rentUnmatchedReceipts.map { "    " + $0 }
        }
        if !report.rentUnmatchedCredits.isEmpty {
            out.append("  rent credits up to the last statement matching no receipt:")
            out += report.rentUnmatchedCredits.map { "    " + $0 }
        }
        if !report.rentLeftAlone.isEmpty {
            out.append("  matches between rows already in the app, not made (another step's): " + report.rentLeftAlone.joined(separator: ", "))
        }
        out.append("== Recharges of a tenancy without itemised statements ==")
        out += report.recharges.isEmpty ? ["  none"] : report.recharges.map { "  " + $0 }
        out.append("== Tax-year notes ==")
        out += report.taxYearNotes.isEmpty ? ["  none"] : report.taxYearNotes.map { "  " + $0 }
        out.append("== Employments recorded (from the filed returns) ==")
        out += report.employments.isEmpty ? ["  none"] : report.employments.map { "  " + $0 }
        out.append("== Year set-up (tax data plan) ==")
        out += report.taxData.isEmpty ? ["  none"] : report.taxData.map { "  " + $0 }
        out.append("== Tax figures that change (before → after) ==")
        if report.taxChanges.isEmpty { out.append("  none") }
        let years = Set(report.taxChanges.map(\.key.startYear)).sorted()
        for year in years {
            let statuses = (report.taxBefore.statuses[year] ?? [:]).map { "\($0.key) \($0.value.rawValue)" }.sorted().joined(separator: ", ")
            out.append("  \(year)/\(String(format: "%02d", (year + 1) % 100)) [\(statuses.isEmpty ? "no tax year" : statuses)]")
            for change in report.taxChanges where change.key.startYear == year {
                let before = change.before?.description ?? "—", after = change.after?.description ?? "—"
                var delta = ""
                if case .amount(let a)? = change.before, case .amount(let b)? = change.after { delta = " (\(b - a > 0 ? "+" : "")\(b - a))" }
                out.append("    \(pad(change.key.person, 9)) \(pad(change.key.field, 70)) \(lpad(before, 10)) → \(lpad(after, 10))\(delta)")
            }
        }
        out.append("== Filed returns against the app after the import ==")
        out += report.filedComparison.isEmpty ? ["  none given"] : report.filedComparison.map { "  " + $0 }
        out.append("== Filed or paid figures that move unexplained ==")
        out += report.unexplainedFiledChanges.isEmpty ? ["  none"] : report.unexplainedFiledChanges.map {
            "  \($0.key.startYear)/\(String(format: "%02d", ($0.key.startYear + 1) % 100)) \($0.key.person) \($0.key.field): \($0.before?.description ?? "—") → \($0.after?.description ?? "—")"
        }
        out.append("== Filed-year changes the plan accepts (why) ==")
        if report.acceptedFiledChanges.isEmpty { out.append("  none") }
        var reasons: [String] = []
        for (_, reason) in report.acceptedFiledChanges where !reasons.contains(reason) { reasons.append(reason) }
        for reason in reasons {
            let changes = report.acceptedFiledChanges.filter { $0.reason == reason }.map(\.change)
            out.append("  \(reason)")
            for change in changes {
                out.append("    \(change.key.startYear)/\(String(format: "%02d", (change.key.startYear + 1) % 100)) \(pad(change.key.person, 9)) \(change.key.field): \(change.before?.description ?? "—") → \(change.after?.description ?? "—")")
            }
        }
        out.append("== Verification ==")
        out += report.verification.map { "  " + $0 }
        return out.joined(separator: "\n")
    }
}
