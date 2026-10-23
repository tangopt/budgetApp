import GRDB
import Foundation

// A person's UK income records for Self Assessment (spec 2026-10-16 §4 "Personal income";
// plan phase 4 Task 1): employments with their pay and tax (P60 / P45 / payslips), P11D
// benefits, other income and pension contributions (kept for later years), and payments to
// and refunds from HMRC. Amounts are GBP pence unless a record says otherwise; dates are
// calendar days at 00:00 UTC, like the other tax records. Documents link to the records
// (`EvidenceEntity.employment`, `.employmentIncome`, `.hmrcPayment`…).

public enum PersonalIncomeError: Error, Equatable, LocalizedError {
    case personNotFound
    case employmentNotFound
    case blankEmployer
    case negativeAmount
    /// An end date before the start date.
    case invalidDates
    /// A PAYE reference that isn't "123/AB456" (office number / reference).
    case invalidPAYEReference

    public var errorDescription: String? {
        switch self {
        case .personNotFound: return "That person no longer exists."
        case .employmentNotFound: return "That employment no longer exists."
        case .blankEmployer: return "Enter the employer's name."
        case .negativeAmount: return "Amounts can't be negative."
        case .invalidDates: return "The end date is before the start date."
        case .invalidPAYEReference: return "A PAYE reference looks like 123/AB456."
        }
    }
}

// MARK: - Employment

/// One employment of a person in a UK tax year (one P60 / P45 / P11D employer).
public struct Employment: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    /// The calendar year the UK tax year starts in (2024 = 2024/25).
    public var startYear: Int
    public var personId: Int64
    public var employerName: String
    /// "123/AB456", upper case, no spaces.
    public var payeReference: String?
    /// When the employment started in the year (`nil`: before 6 April).
    public var startDate: Date?
    /// The leaving date (P45), when it ended in the year.
    public var endDate: Date?
    public var notes: String?

    public init(id: Int64? = nil, startYear: Int, personId: Int64, employerName: String, payeReference: String? = nil,
                startDate: Date? = nil, endDate: Date? = nil, notes: String? = nil) {
        self.id = id
        self.startYear = startYear
        self.personId = personId
        self.employerName = employerName
        self.payeReference = payeReference
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "employment"

    public var ukTaxYear: UKTaxYear { UKTaxYear(startYear: startYear) }
}

/// Which form an employment's pay and tax were read from.
public enum EmploymentIncomeSource: String, Codable, CaseIterable, Sendable {
    case p60
    case p45
    case payslip
    case other
    /// Paid by the employer after the employee left (after the P45: holiday pay on code 0T, say).
    /// It adds to the P45's (or payslips') pay and tax; a P60 already includes it.
    case afterLeaving

    public var displayName: String {
        switch self {
        case .p60: return "P60"
        case .p45: return "P45"
        case .payslip: return "Payslip"
        case .other: return "Other"
        case .afterLeaving: return "Paid after leaving"
        }
    }

    /// The one the return uses when there are several: P60, then P45, then payslips, then other.
    var precedence: Int {
        switch self {
        case .p60: return 0
        case .p45: return 1
        case .payslip: return 2
        case .other: return 3
        case .afterLeaving: return 4
        }
    }
}

/// How a record's figures were entered.
public enum IncomeEntryMethod: String, Codable, CaseIterable, Sendable {
    /// Read from the PDF's text layer, then confirmed.
    case textLayer
    /// Read by text recognition (image-only PDFs, photos), then confirmed.
    case ocr
    /// Typed by the user (the document attached).
    case manual

    public var displayName: String {
        switch self {
        case .textLayer: return "Read from the PDF"
        case .ocr: return "Read by text recognition"
        case .manual: return "Entered by hand"
        }
    }
}

/// An employment's pay and UK tax for the year, from one form (SA102 boxes 1 and 2).
public struct EmploymentIncome: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var employmentId: Int64
    public var source: EmploymentIncomeSource
    /// Pay in this employment, pence.
    public var payMinorUnits: Int
    /// UK tax taken off in this employment, pence; negative when the form shows a refund ("R").
    public var taxDeductedMinorUnits: Int
    /// "1257L", "K475", "BR"…
    public var taxCode: String?
    /// The leaving date (P45) or the payslip's date; `nil` for a P60 (5 April).
    public var periodEnd: Date?
    public var entryMethod: IncomeEntryMethod
    public var notes: String?

    public init(id: Int64? = nil, employmentId: Int64, source: EmploymentIncomeSource, payMinorUnits: Int, taxDeductedMinorUnits: Int,
                taxCode: String? = nil, periodEnd: Date? = nil, entryMethod: IncomeEntryMethod = .manual, notes: String? = nil) {
        self.id = id
        self.employmentId = employmentId
        self.source = source
        self.payMinorUnits = payMinorUnits
        self.taxDeductedMinorUnits = taxDeductedMinorUnits
        self.taxCode = taxCode
        self.periodEnd = periodEnd
        self.entryMethod = entryMethod
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "employmentIncome"
}

/// A P11D benefit or expense type, by the form's sections (A–N); each goes to an SA102 box.
public enum BenefitKind: String, Codable, CaseIterable, Sendable {
    case assetsTransferred
    case paymentsOnBehalf
    case vouchersAndCreditCards
    case livingAccommodation
    case mileageAllowance
    case car
    case carFuel
    case van
    case vanFuel
    case loans
    case medical
    case relocation
    case services
    case assetsAtDisposal
    case otherItems
    case expensesPayments
    case other

    public var displayName: String {
        switch self {
        case .assetsTransferred: return "Assets transferred"
        case .paymentsOnBehalf: return "Payments made on behalf of employee"
        case .vouchersAndCreditCards: return "Vouchers and credit cards"
        case .livingAccommodation: return "Living accommodation"
        case .mileageAllowance: return "Mileage allowance payments"
        case .car: return "Company car"
        case .carFuel: return "Car fuel"
        case .van: return "Van"
        case .vanFuel: return "Van fuel"
        case .loans: return "Interest-free and low interest loans"
        case .medical: return "Private medical treatment or insurance"
        case .relocation: return "Qualifying relocation expenses"
        case .services: return "Services supplied"
        case .assetsAtDisposal: return "Assets placed at the employee's disposal"
        case .otherItems: return "Other items"
        case .expensesPayments: return "Expenses payments"
        case .other: return "Other benefit"
        }
    }

    /// The SA102 ("Employment") box the cash equivalent goes in; the P11D numbers its boxes
    /// the same way: 9 cars and vans, 10 their fuel, 11 medical, 12 vouchers, credit cards and
    /// excess mileage, 13 goods and assets, 14 accommodation, 15 other benefits, 16 expenses.
    public var sa102Box: Int {
        switch self {
        case .car, .van: return 9
        case .carFuel, .vanFuel: return 10
        case .medical: return 11
        case .vouchersAndCreditCards, .mileageAllowance: return 12
        case .assetsTransferred, .assetsAtDisposal: return 13
        case .livingAccommodation: return 14
        case .paymentsOnBehalf, .loans, .relocation, .services, .otherItems, .other: return 15
        case .expensesPayments: return 16
        }
    }

    /// The P11D section letter ("I" for medical).
    public var p11dSection: String? {
        switch self {
        case .assetsTransferred: return "A"
        case .paymentsOnBehalf: return "B"
        case .vouchersAndCreditCards: return "C"
        case .livingAccommodation: return "D"
        case .mileageAllowance: return "E"
        case .car, .carFuel: return "F"
        case .van, .vanFuel: return "G"
        case .loans: return "H"
        case .medical: return "I"
        case .relocation: return "J"
        case .services: return "K"
        case .assetsAtDisposal: return "L"
        case .otherItems: return "M"
        case .expensesPayments: return "N"
        case .other: return nil
        }
    }

    /// The kind of a P11D section's box ("F", 10 → car fuel); `nil` for an unknown section.
    public static func kind(p11dSection section: String, box: Int?) -> BenefitKind? {
        switch section.uppercased() {
        case "A": return .assetsTransferred
        case "B": return .paymentsOnBehalf
        case "C": return .vouchersAndCreditCards
        case "D": return .livingAccommodation
        case "E": return .mileageAllowance
        case "F": return box == 10 ? .carFuel : .car
        case "G": return box == 10 ? .vanFuel : .van
        case "H": return .loans
        case "I": return .medical
        case "J": return .relocation
        case "K": return .services
        case "L": return .assetsAtDisposal
        case "M": return .otherItems
        case "N": return .expensesPayments
        default: return nil
        }
    }

    /// The kind a bare SA102 box number suggests (no section known).
    public static func kind(sa102Box box: Int) -> BenefitKind {
        switch box {
        case 9: return .car
        case 10: return .carFuel
        case 11: return .medical
        case 12: return .vouchersAndCreditCards
        case 13: return .assetsTransferred
        case 14: return .livingAccommodation
        case 16: return .expensesPayments
        default: return .other
        }
    }
}

/// A P11D item: a benefit's cash equivalent (or an expenses payment) for the year.
public struct BenefitInKind: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var employmentId: Int64
    public var kind: BenefitKind
    /// The SA102 box (defaults to the kind's).
    public var sa102Box: Int
    public var description: String?
    /// Cash equivalent, pence.
    public var cashEquivalentMinorUnits: Int
    public var entryMethod: IncomeEntryMethod
    /// Saved by a P11D import (`PayrollFormImport`): a re-import replaces these rows and
    /// keeps the ones typed in by hand.
    public var isFromP11DImport: Bool
    public var notes: String?

    public init(id: Int64? = nil, employmentId: Int64, kind: BenefitKind, sa102Box: Int? = nil, description: String? = nil,
                cashEquivalentMinorUnits: Int, entryMethod: IncomeEntryMethod = .manual, isFromP11DImport: Bool = false, notes: String? = nil) {
        self.id = id
        self.employmentId = employmentId
        self.kind = kind
        self.sa102Box = sa102Box ?? kind.sa102Box
        self.description = description
        self.cashEquivalentMinorUnits = cashEquivalentMinorUnits
        self.entryMethod = entryMethod
        self.isFromP11DImport = isFromP11DImport
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "benefitInKind"
}

// MARK: - Other income and pensions (later years)

public enum OtherIncomeKind: String, Codable, CaseIterable, Sendable {
    /// UK bank and building society interest (SA100 box 1 of "UK interest").
    case ukInterest
    case ukDividends
    case foreignInterest
    case foreignDividends
    case other

    public var displayName: String {
        switch self {
        case .ukInterest: return "UK interest"
        case .ukDividends: return "UK dividends"
        case .foreignInterest: return "Foreign interest"
        case .foreignDividends: return "Foreign dividends"
        case .other: return "Other income"
        }
    }
}

/// Income other than employment and property (not used by the 2023/24–2025/26 returns; kept
/// so later years can add it).
public struct OtherIncome: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var startYear: Int
    public var personId: Int64
    public var kind: OtherIncomeKind
    /// The bank, company or fund.
    public var payer: String?
    /// The amount received before any tax taken off, in `currency`.
    public var amountMinorUnits: Int
    /// Tax taken off at source (UK or foreign), in `currency`.
    public var taxDeductedMinorUnits: Int
    public var currency: Currency
    public var date: Date?
    public var notes: String?

    public init(id: Int64? = nil, startYear: Int, personId: Int64, kind: OtherIncomeKind, payer: String? = nil, amountMinorUnits: Int,
                taxDeductedMinorUnits: Int = 0, currency: Currency = .gbp, date: Date? = nil, notes: String? = nil) {
        self.id = id
        self.startYear = startYear
        self.personId = personId
        self.kind = kind
        self.payer = payer
        self.amountMinorUnits = amountMinorUnits
        self.taxDeductedMinorUnits = taxDeductedMinorUnits
        self.currency = currency
        self.date = date
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "otherIncome"
}

public enum PensionContributionKind: String, Codable, CaseIterable, Sendable {
    /// Paid from taxed income; the provider claims basic-rate relief (SA100 "relief at source").
    case reliefAtSource
    /// Taken from pay before tax by the employer: already relieved, not on the return.
    case netPay
    /// Retirement annuity contracts and others where the person claims all relief.
    case noReliefAtSource
    case overseas

    public var displayName: String {
        switch self {
        case .reliefAtSource: return "Relief at source"
        case .netPay: return "Net pay arrangement"
        case .noReliefAtSource: return "No relief at source"
        case .overseas: return "Overseas pension scheme"
        }
    }
}

/// A pension contribution (kept for later years).
public struct PensionContribution: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var startYear: Int
    public var personId: Int64
    public var kind: PensionContributionKind
    public var provider: String?
    /// What the person paid, pence (for relief at source: before the provider adds the relief).
    public var paidMinorUnits: Int
    public var date: Date?
    public var notes: String?

    public init(id: Int64? = nil, startYear: Int, personId: Int64, kind: PensionContributionKind, provider: String? = nil,
                paidMinorUnits: Int, date: Date? = nil, notes: String? = nil) {
        self.id = id
        self.startYear = startYear
        self.personId = personId
        self.kind = kind
        self.provider = provider
        self.paidMinorUnits = paidMinorUnits
        self.date = date
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "pensionContribution"
}

// MARK: - HMRC payments

public enum HMRCPaymentKind: String, Codable, CaseIterable, Sendable {
    /// 31 January after the year: what's left of the year's liability.
    case balancingPayment
    /// 31 January in the year after: half of the year's liability, towards the next year.
    case firstPaymentOnAccount
    /// 31 July after that.
    case secondPaymentOnAccount
    /// Money HMRC paid back.
    case refund
    case other

    public var displayName: String {
        switch self {
        case .balancingPayment: return "Balancing payment"
        case .firstPaymentOnAccount: return "1st payment on account"
        case .secondPaymentOnAccount: return "2nd payment on account"
        case .refund: return "Refund"
        case .other: return "Other payment"
        }
    }
}

/// A payment to HMRC (or a refund from it) for a person's tax year, with its proof linked.
public struct HMRCPayment: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var personId: Int64
    /// The tax year the payment is for (a payment on account is for the year it counts towards).
    public var startYear: Int
    public var date: Date
    /// Positive, pence; a refund is positive too (`kind` says which way it went).
    public var amountMinorUnits: Int
    public var kind: HMRCPaymentKind
    /// The payment reference (UTR + "K").
    public var reference: String?
    public var notes: String?

    public init(id: Int64? = nil, personId: Int64, startYear: Int, date: Date, amountMinorUnits: Int, kind: HMRCPaymentKind,
                reference: String? = nil, notes: String? = nil) {
        self.id = id
        self.personId = personId
        self.startYear = startYear
        self.date = date
        self.amountMinorUnits = amountMinorUnits
        self.kind = kind
        self.reference = reference
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "hmrcPayment"

    /// Money paid to HMRC is positive, a refund negative.
    public var signedMinorUnits: Int { kind == .refund ? -amountMinorUnits : amountMinorUnits }
}

public extension EvidenceEntity {
    static func employment(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .employment, id: id) }
    static func employmentIncome(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .employmentIncome, id: id) }
    static func hmrcPayment(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .hmrcPayment, id: id) }
    static func otherIncome(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .otherIncome, id: id) }
    static func pensionContribution(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .pensionContribution, id: id) }
}

// MARK: - Reading and editing

public enum Employments {
    /// "123/ab 456" → "123/AB456"; `nil` for blank; throws for anything else.
    public static func normalizedPAYEReference(_ reference: String?) throws -> String? {
        guard let trimmed = Transaction.normalizedNote(reference) else { return nil }
        let compact = trimmed.uppercased().filter { !$0.isWhitespace }
        guard compact.range(of: #"^[0-9]{3}/[A-Z0-9]{1,10}$"#, options: .regularExpression) != nil else {
            throw PersonalIncomeError.invalidPAYEReference
        }
        return compact
    }

    /// Inserts or updates the employment (trimmed name, normalised reference, day dates).
    public static func save(db: Database, _ employment: inout Employment) throws {
        employment.employerName = employment.employerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !employment.employerName.isEmpty else { throw PersonalIncomeError.blankEmployer }
        guard try Person.exists(db, key: employment.personId) else { throw PersonalIncomeError.personNotFound }
        employment.payeReference = try normalizedPAYEReference(employment.payeReference)
        employment.startDate = employment.startDate.map(PropertyDates.day)
        employment.endDate = employment.endDate.map(PropertyDates.day)
        if let start = employment.startDate, let end = employment.endDate, end < start { throw PersonalIncomeError.invalidDates }
        employment.notes = Transaction.normalizedNote(employment.notes)
        try employment.save(db)
    }

    /// The person's employments in the year, by employer name then id.
    public static func employments(db: Database, startYear: Int, personId: Int64) throws -> [Employment] {
        try Employment.filter(Column("startYear") == startYear && Column("personId") == personId)
            .order(Column("employerName").collating(.localizedCaseInsensitiveCompare), Column("id"))
            .fetchAll(db)
    }

    /// The person's employment in the year with that PAYE reference, else (no reference
    /// given, or none matches) the one with that employer name (case-insensitive) and no
    /// conflicting reference.
    public static func find(db: Database, startYear: Int, personId: Int64, payeReference: String?, employerName: String?) throws -> Employment? {
        let all = try employments(db: db, startYear: startYear, personId: personId)
        let reference = try? normalizedPAYEReference(payeReference)
        if let reference = reference ?? nil, let match = all.first(where: { $0.payeReference == reference }) { return match }
        guard let name = Transaction.normalizedNote(employerName) else { return nil }
        let folded = fold(name)
        return all.first { fold($0.employerName) == folded && ($0.payeReference == nil || reference == nil || $0.payeReference == reference) }
    }

    /// Deletes the employment, its income rows and benefits (and their document links).
    @discardableResult
    public static func delete(db: Database, id: Int64) throws -> Bool {
        try Employment.deleteOne(db, key: id)
    }

    // MARK: Pay and tax

    /// Inserts or updates the row (day-normalised date, normalised tax code).
    public static func save(db: Database, _ income: inout EmploymentIncome) throws {
        guard try Employment.exists(db, key: income.employmentId) else { throw PersonalIncomeError.employmentNotFound }
        guard income.payMinorUnits >= 0 else { throw PersonalIncomeError.negativeAmount }
        income.taxCode = Transaction.normalizedNote(income.taxCode).map { $0.uppercased().filter { !$0.isWhitespace } }
        income.periodEnd = income.periodEnd.map(PropertyDates.day)
        income.notes = Transaction.normalizedNote(income.notes)
        try income.save(db)
    }

    /// The employment's income rows, by the precedence of their source then id.
    public static func incomes(db: Database, employmentId: Int64) throws -> [EmploymentIncome] {
        try EmploymentIncome.filter(Column("employmentId") == employmentId).fetchAll(db)
            .sorted { ($0.source.precedence, $0.id ?? 0) < ($1.source.precedence, $1.id ?? 0) }
    }

    /// The pay and tax the return uses for the employment: the P60's, else the P45's (the
    /// latest), else the payslips' summed, else the other rows' summed; `nil` without any.
    /// Except under a P60 (which already includes everything), the "paid after leaving" rows are
    /// added on top (and on their own, they sum).
    public static func effectiveIncome(db: Database, employmentId: Int64) throws -> EffectiveIncome? {
        effectiveIncome(try incomes(db: db, employmentId: employmentId))
    }

    /// The figures `effectiveIncome` gives. `source` is the base source (never `.afterLeaving`
    /// unless those rows are all there is); `afterLeavingMinorUnits` is the pay already added in
    /// from "paid after leaving" rows (0 under a P60 or without any).
    public struct EffectiveIncome: Equatable, Sendable {
        public var payMinorUnits: Int
        public var taxDeductedMinorUnits: Int
        public var source: EmploymentIncomeSource
        public var afterLeavingMinorUnits: Int
        public var afterLeavingCount: Int
    }

    /// `effectiveIncome(db:employmentId:)` of rows already read, in `incomes(db:employmentId:)`'s
    /// order (the Income tab's figures, from `SelfAssessmentOverview.EmploymentRow.incomes`).
    public static func effectiveIncome(_ rows: [EmploymentIncome]) -> EffectiveIncome? {
        guard let best = rows.first?.source else { return nil }
        let extras = rows.filter { $0.source == .afterLeaving }
        let extraPay = extras.reduce(0) { $0 + $1.payMinorUnits }
        let extraTax = extras.reduce(0) { $0 + $1.taxDeductedMinorUnits }
        let chosen = rows.filter { $0.source == best }
        switch best {
        case .p60:
            let row = chosen.max { ($0.periodEnd ?? .distantFuture, $0.id ?? 0) < ($1.periodEnd ?? .distantFuture, $1.id ?? 0) }!
            return EffectiveIncome(payMinorUnits: row.payMinorUnits, taxDeductedMinorUnits: row.taxDeductedMinorUnits, source: best,
                                   afterLeavingMinorUnits: 0, afterLeavingCount: 0)
        case .p45:
            let row = chosen.max { ($0.periodEnd ?? .distantFuture, $0.id ?? 0) < ($1.periodEnd ?? .distantFuture, $1.id ?? 0) }!
            return EffectiveIncome(payMinorUnits: row.payMinorUnits + extraPay, taxDeductedMinorUnits: row.taxDeductedMinorUnits + extraTax, source: best,
                                   afterLeavingMinorUnits: extraPay, afterLeavingCount: extras.count)
        case .payslip, .other:
            return EffectiveIncome(payMinorUnits: chosen.reduce(0) { $0 + $1.payMinorUnits } + extraPay,
                                   taxDeductedMinorUnits: chosen.reduce(0) { $0 + $1.taxDeductedMinorUnits } + extraTax, source: best,
                                   afterLeavingMinorUnits: extraPay, afterLeavingCount: extras.count)
        case .afterLeaving:
            return EffectiveIncome(payMinorUnits: extraPay, taxDeductedMinorUnits: extraTax, source: best,
                                   afterLeavingMinorUnits: 0, afterLeavingCount: 0)
        }
    }

    @discardableResult
    public static func deleteIncome(db: Database, id: Int64) throws -> Bool {
        try EmploymentIncome.deleteOne(db, key: id)
    }

    // MARK: Benefits

    public static func save(db: Database, _ benefit: inout BenefitInKind) throws {
        guard try Employment.exists(db, key: benefit.employmentId) else { throw PersonalIncomeError.employmentNotFound }
        guard benefit.cashEquivalentMinorUnits >= 0 else { throw PersonalIncomeError.negativeAmount }
        benefit.description = Transaction.normalizedNote(benefit.description)
        benefit.notes = Transaction.normalizedNote(benefit.notes)
        try benefit.save(db)
    }

    /// The employment's benefits by SA102 box, then id.
    public static func benefits(db: Database, employmentId: Int64) throws -> [BenefitInKind] {
        try BenefitInKind.filter(Column("employmentId") == employmentId).order(Column("sa102Box"), Column("id")).fetchAll(db)
    }

    @discardableResult
    public static func deleteBenefit(db: Database, id: Int64) throws -> Bool {
        try BenefitInKind.deleteOne(db, key: id)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}

public enum OtherIncomes {
    public static func save(db: Database, _ income: inout OtherIncome) throws {
        guard try Person.exists(db, key: income.personId) else { throw PersonalIncomeError.personNotFound }
        guard income.amountMinorUnits >= 0, income.taxDeductedMinorUnits >= 0 else { throw PersonalIncomeError.negativeAmount }
        income.payer = Transaction.normalizedNote(income.payer)
        income.date = income.date.map(PropertyDates.day)
        income.notes = Transaction.normalizedNote(income.notes)
        try income.save(db)
    }

    /// The person's other income for the year, by kind then date (undated last) then id.
    public static func incomes(db: Database, startYear: Int, personId: Int64) throws -> [OtherIncome] {
        try OtherIncome.filter(Column("startYear") == startYear && Column("personId") == personId)
            .order(Column("kind"), Column("date") == nil, Column("date"), Column("id")).fetchAll(db)
    }

    @discardableResult
    public static func delete(db: Database, id: Int64) throws -> Bool {
        try OtherIncome.deleteOne(db, key: id)
    }
}

public enum PensionContributions {
    public static func save(db: Database, _ contribution: inout PensionContribution) throws {
        guard try Person.exists(db, key: contribution.personId) else { throw PersonalIncomeError.personNotFound }
        guard contribution.paidMinorUnits >= 0 else { throw PersonalIncomeError.negativeAmount }
        contribution.provider = Transaction.normalizedNote(contribution.provider)
        contribution.date = contribution.date.map(PropertyDates.day)
        contribution.notes = Transaction.normalizedNote(contribution.notes)
        try contribution.save(db)
    }

    public static func contributions(db: Database, startYear: Int, personId: Int64) throws -> [PensionContribution] {
        try PensionContribution.filter(Column("startYear") == startYear && Column("personId") == personId)
            .order(Column("date") == nil, Column("date"), Column("id")).fetchAll(db)
    }

    @discardableResult
    public static func delete(db: Database, id: Int64) throws -> Bool {
        try PensionContribution.deleteOne(db, key: id)
    }
}

public enum HMRCPayments {
    public static func save(db: Database, _ payment: inout HMRCPayment) throws {
        guard try Person.exists(db, key: payment.personId) else { throw PersonalIncomeError.personNotFound }
        guard payment.amountMinorUnits >= 0 else { throw PersonalIncomeError.negativeAmount }
        payment.date = PropertyDates.day(payment.date)
        payment.reference = Transaction.normalizedNote(payment.reference)
        payment.notes = Transaction.normalizedNote(payment.notes)
        try payment.save(db)
    }

    /// The person's payments for the tax year (all years when `startYear` is nil), by date then id.
    public static func payments(db: Database, personId: Int64, startYear: Int? = nil) throws -> [HMRCPayment] {
        var request = HMRCPayment.filter(Column("personId") == personId)
        if let startYear { request = request.filter(Column("startYear") == startYear) }
        return try request.order(Column("date"), Column("id")).fetchAll(db)
    }

    /// Paid minus refunded for the year, pence.
    public static func netPaid(db: Database, personId: Int64, startYear: Int) throws -> Int {
        try payments(db: db, personId: personId, startYear: startYear).reduce(0) { $0 + $1.signedMinorUnits }
    }

    @discardableResult
    public static func delete(db: Database, id: Int64) throws -> Bool {
        try HMRCPayment.deleteOne(db, key: id)
    }
}

// MARK: - Evidence titles

public enum PersonalIncomeEvidence {
    /// "Example Ltd · 2024/25 · A", "P60 · Example Ltd · 2024/25 · A", "Balancing payment ·
    /// 2024/25 · A"…; `nil` when the record is gone or the entity isn't one of these.
    public static func title(db: Database, entity: EvidenceEntity) throws -> String? {
        func person(_ id: Int64) throws -> String? { try Person.fetchOne(db, key: id)?.displayShortName }
        func year(_ startYear: Int) -> String { UKTaxYear(startYear: startYear).label }
        switch entity.type {
        case .employment:
            guard let employment = try Employment.fetchOne(db, key: entity.id) else { return nil }
            return [employment.employerName, year(employment.startYear), try person(employment.personId)].compactMap { $0 }.joined(separator: " · ")
        case .employmentIncome:
            guard let income = try EmploymentIncome.fetchOne(db, key: entity.id),
                  let employment = try Employment.fetchOne(db, key: income.employmentId) else { return nil }
            return [income.source.displayName, employment.employerName, year(employment.startYear), try person(employment.personId)]
                .compactMap { $0 }.joined(separator: " · ")
        case .hmrcPayment:
            guard let payment = try HMRCPayment.fetchOne(db, key: entity.id) else { return nil }
            return [payment.kind.displayName, year(payment.startYear), try person(payment.personId)].compactMap { $0 }.joined(separator: " · ")
        case .otherIncome:
            guard let income = try OtherIncome.fetchOne(db, key: entity.id) else { return nil }
            return [income.payer ?? income.kind.displayName, year(income.startYear), try person(income.personId)].compactMap { $0 }.joined(separator: " · ")
        case .pensionContribution:
            guard let contribution = try PensionContribution.fetchOne(db, key: entity.id) else { return nil }
            return [contribution.provider ?? contribution.kind.displayName, year(contribution.startYear), try person(contribution.personId)]
                .compactMap { $0 }.joined(separator: " · ")
        default:
            return nil
        }
    }
}

// MARK: - Missing evidence

/// The personal-income records a `.personalIncomeRecords` requirement covers.
public enum PersonalIncomeRecordKind: String, Codable, CaseIterable, Sendable {
    /// Each employment held to the end of its tax year: its P60.
    case p60
    /// Each employment that ended in its tax year: its P45.
    case p45
    /// Each employment with benefits: its P11D.
    case p11d
    /// Each HMRC payment or refund: its proof.
    case hmrcPaymentProof

    public var documentKind: DocumentKind {
        switch self {
        case .p60: return .p60
        case .p45: return .p45
        case .p11d: return .p11d
        case .hmrcPaymentProof: return .hmrcPaymentProof
        }
    }

    /// "One P60 per employment held to the year's end"…
    public var ruleDescription: String {
        switch self {
        case .p60: return "One P60 per employment held to the year's end"
        case .p45: return "One P45 per employment that ended"
        case .p11d: return "One P11D per employment with benefits"
        case .hmrcPaymentProof: return "One proof per HMRC payment"
        }
    }

    var ruleName: String {
        switch self {
        case .p60: return "P60 for each employment"
        case .p45: return "P45 for each employment that ended"
        case .p11d: return "P11D for each employment with benefits"
        case .hmrcPaymentProof: return "Proof of each HMRC payment"
        }
    }

    var usualSource: String { self == .hmrcPaymentProof ? "HMRC / bank" : "Employer" }
}

extension PersonalIncomeEvidence {
    /// A record expecting a document.
    public struct Record: Equatable, Sendable {
        public var entity: EvidenceEntity
        /// Where a satisfying document may be linked: the record and, for an employment, its
        /// pay-and-tax rows (an imported P60 or P45 links there).
        public var documentEntities: [EvidenceEntity]
        public var title: String
        public var date: Date?
        /// GBP pence.
        public var amountMinorUnits: Int?
        public var period: DateInterval?
    }

    /// The records of `kind` in `period`: employments whose tax year meets it, payments dated in it.
    public static func records(db: Database, kind: PersonalIncomeRecordKind, overlapping period: DateInterval) throws -> [Record] {
        let people = Dictionary(uniqueKeysWithValues: try Person.fetchAll(db).map { ($0.id!, $0.displayShortName) })
        if kind == .hmrcPaymentProof {
            return try HMRCPayment.filter(Column("date") >= period.start && Column("date") < period.end).order(Column("date"), Column("id")).fetchAll(db)
                .map { payment in
                    Record(entity: .hmrcPayment(payment.id!), documentEntities: [.hmrcPayment(payment.id!)],
                           title: [payment.kind.displayName, UKTaxYear(startYear: payment.startYear).label, people[payment.personId]]
                               .compactMap { $0 }.joined(separator: " · "),
                           date: payment.date, amountMinorUnits: payment.amountMinorUnits, period: nil)
                }
        }
        let employments = try Employment.order(Column("startYear"), Column("personId"), Column("employerName"), Column("id")).fetchAll(db)
            .filter { $0.ukTaxYear.start < period.end && $0.ukTaxYear.end > period.start }
        let withBenefits = Set(try BenefitInKind.filter(Column("cashEquivalentMinorUnits") > 0).fetchAll(db).map(\.employmentId))
        let incomes = Dictionary(grouping: try EmploymentIncome.fetchAll(db), by: \.employmentId)
        return employments.compactMap { employment in
            let year = employment.ukTaxYear
            let ended = employment.endDate.map { $0 < year.lastDay } ?? false
            switch kind {
            case .p60: guard !ended else { return nil }
            case .p45: guard ended else { return nil }
            case .p11d: guard withBenefits.contains(employment.id!) else { return nil }
            case .hmrcPaymentProof: return nil
            }
            let entities = [EvidenceEntity.employment(employment.id!)] + (incomes[employment.id!] ?? []).map { .employmentIncome($0.id!) }
            return Record(entity: .employment(employment.id!), documentEntities: entities,
                          title: [kind.documentKind.displayName, employment.employerName, year.label, people[employment.personId]]
                              .compactMap { $0 }.joined(separator: " · "),
                          date: kind == .p45 ? employment.endDate : nil, amountMinorUnits: nil, period: year.interval)
        }
    }

    public static let seededNote = "Default rule (personal income)"

    /// The four default rules, unsaved (the app previews them); those already stored left out.
    public static func defaultRules(db: Database) throws -> [EvidenceRequirement] {
        let existing = Set(try EvidenceRequirement.fetchAll(db).map(\.scope))
        return PersonalIncomeRecordKind.allCases
            .map { EvidenceRequirement(name: $0.ruleName, scope: .personalIncomeRecords(record: $0), kinds: [$0.documentKind],
                                       direction: .any, usualSource: $0.usualSource, notes: seededNote) }
            .filter { !existing.contains($0.scope) }
    }

    /// Saves `defaultRules` (idempotent); returns what was added.
    @discardableResult
    public static func seedRules(db: Database) throws -> [EvidenceRequirement] {
        var saved: [EvidenceRequirement] = []
        for var rule in try defaultRules(db: db) {
            try EvidenceRequirements.save(db: db, &rule)
            saved.append(rule)
        }
        return saved
    }
}

// MARK: - Migration

func registerPersonalIncomeMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createPersonalIncome") { db in
        try db.create(table: "employment") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startYear", .integer).notNull()
            t.column("personId", .integer).notNull().indexed().references("person", onDelete: .cascade)
            t.column("employerName", .text).notNull()
            t.column("payeReference", .text)
            t.column("startDate", .datetime)
            t.column("endDate", .datetime)
            t.column("notes", .text)
        }
        try db.create(table: "employmentIncome") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("employmentId", .integer).notNull().indexed().references("employment", onDelete: .cascade)
            t.column("source", .text).notNull()
            t.column("payMinorUnits", .integer).notNull()
            t.column("taxDeductedMinorUnits", .integer).notNull()
            t.column("taxCode", .text)
            t.column("periodEnd", .datetime)
            t.column("entryMethod", .text).notNull()
            t.column("notes", .text)
        }
        try db.create(table: "benefitInKind") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("employmentId", .integer).notNull().indexed().references("employment", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("sa102Box", .integer).notNull()
            t.column("description", .text)
            t.column("cashEquivalentMinorUnits", .integer).notNull()
            t.column("entryMethod", .text).notNull()
            t.column("isFromP11DImport", .boolean).notNull().defaults(to: false)
            t.column("notes", .text)
        }
        try db.create(table: "otherIncome") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startYear", .integer).notNull()
            t.column("personId", .integer).notNull().indexed().references("person", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("payer", .text)
            t.column("amountMinorUnits", .integer).notNull()
            t.column("taxDeductedMinorUnits", .integer).notNull().defaults(to: 0)
            t.column("currency", .text).notNull()
            t.column("date", .datetime)
            t.column("notes", .text)
        }
        try db.create(table: "pensionContribution") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startYear", .integer).notNull()
            t.column("personId", .integer).notNull().indexed().references("person", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("provider", .text)
            t.column("paidMinorUnits", .integer).notNull()
            t.column("date", .datetime)
            t.column("notes", .text)
        }
        try db.create(table: "hmrcPayment") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("personId", .integer).notNull().indexed().references("person", onDelete: .cascade)
            t.column("startYear", .integer).notNull()
            t.column("date", .datetime).notNull()
            t.column("amountMinorUnits", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("reference", .text)
            t.column("notes", .text)
        }

        // As for the other records: a deleted record (also by a cascade) drops its document
        // links, waivers and the requirements scoped to it.
        let tables: [(String, EvidenceEntityType)] = [
            ("employment", .employment), ("employmentIncome", .employmentIncome), ("hmrcPayment", .hmrcPayment),
            ("otherIncome", .otherIncome), ("pensionContribution", .pensionContribution)
        ]
        for (table, type) in tables {
            let value = type.rawValue
            try db.execute(sql: """
                CREATE TRIGGER documentLink_delete_\(value) AFTER DELETE ON \(table)
                BEGIN DELETE FROM documentLink WHERE entityType = '\(value)' AND entityId = OLD.id; END
                """)
            try db.execute(sql: """
                CREATE TRIGGER evidenceWaiver_delete_\(value) AFTER DELETE ON \(table)
                BEGIN DELETE FROM evidenceWaiver WHERE entityType = '\(value)' AND entityId = OLD.id; END
                """)
            try db.execute(sql: """
                CREATE TRIGGER evidenceRequirement_delete_\(value) AFTER DELETE ON \(table)
                BEGIN DELETE FROM evidenceRequirement WHERE
                    (json_extract(scope, '$.periodic.entity.type') = '\(value)' AND json_extract(scope, '$.periodic.entity.id') = OLD.id)
                    OR (json_extract(scope, '$.single.entity.type') = '\(value)' AND json_extract(scope, '$.single.entity.id') = OLD.id);
                END
                """)
        }
    }
}

