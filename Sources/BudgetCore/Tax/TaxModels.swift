import GRDB
import Foundation

// Records of the UK tax engine (spec 2026-10-16 §0, §2, §4; plan phase 3 Task 1). A tax year
// is a `UKTaxYear` (`startYear` 2024 = 2024/25) for one person. Amounts are minor units of
// their own currency; output in GBP uses the year's HMRC average rate (`HMRCRate`). Dates are
// calendar days at 00:00 UTC, like the property records.

/// Where a person's return for a year stands.
public enum TaxYearStatus: String, Codable, CaseIterable, Sendable {
    case preparing
    case ready
    case filed
    case paid

    public var displayName: String {
        switch self {
        case .preparing: return "Preparing"
        case .ready: return "Ready"
        case .filed: return "Filed"
        case .paid: return "Paid"
        }
    }
}

/// One person's UK tax year.
public struct TaxYear: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    /// The calendar year the UK tax year starts in (2024 = 2024/25).
    public var startYear: Int
    public var personId: Int64
    public var status: TaxYearStatus
    public var notes: String?
    /// The return entered the foreign tax paid in pounds and pence (2020/21 as filed), so the
    /// calculation takes it as it is; otherwise it's rounded up to whole pounds like the other
    /// tax paid (the SA100 notes, the later returns).
    public var foreignTaxInPence: Bool

    public init(id: Int64? = nil, startYear: Int, personId: Int64, status: TaxYearStatus = .preparing, notes: String? = nil,
                foreignTaxInPence: Bool = false) {
        self.id = id
        self.startYear = startYear
        self.personId = personId
        self.status = status
        self.notes = notes
        self.foreignTaxInPence = foreignTaxInPence
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "taxYear"

    public var ukTaxYear: UKTaxYear { UKTaxYear(startYear: startYear) }
}

/// The Self Assessment deadlines of a tax year (online filing).
public struct TaxYearDeadlines: Equatable, Sendable {
    /// 31 October after the year: paper returns.
    public var paperReturn: Date
    /// 31 January after the year: online return, balancing payment and first payment on account.
    public var onlineReturnAndBalancingPayment: Date
    /// 31 July after that: second payment on account.
    public var secondPaymentOnAccount: Date
}

extension UKTaxYear {
    public var deadlines: TaxYearDeadlines {
        let calendar = Self.utcCalendar
        func day(_ year: Int, _ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day))! }
        return TaxYearDeadlines(paperReturn: day(startYear + 1, 10, 31),
                                onlineReturnAndBalancingPayment: day(startYear + 2, 1, 31),
                                secondPaymentOnAccount: day(startYear + 2, 7, 31))
    }

    /// 1 April of `startYear` to 1 April of the next year: the twelve months April–March the
    /// month-based attribution rules (rent period, debit month, quota month, cover months) use,
    /// as the accountant's workbook does. `interval` (6 April – 5 April) is for by-date items.
    public var monthsInterval: DateInterval {
        let calendar = Self.utcCalendar
        return DateInterval(start: calendar.date(from: DateComponents(year: startYear, month: 4, day: 1))!,
                            end: calendar.date(from: DateComponents(year: startYear + 1, month: 4, day: 1))!)
    }
}

/// What a property's income or cost is for the UK return (the accountant's template lines).
public enum TaxExpenseType: String, Codable, CaseIterable, Sendable {
    case rentalIncome
    /// Mortgage interest and other finance costs: residential finance cost relief (basic-rate
    /// credit), reported apart from the expenses.
    case financeCost
    /// Condomínio quotas.
    case serviceCharge
    /// Building and contents insurance.
    case insurance
    /// IMI.
    case councilTax
    /// Letting agent's fees (finding a tenant, the contract).
    case lettingFees
    case accountancy
    case legalFees
    case repairs
    case utilities
    case otherExpense
    /// Portuguese IRS on the rent: the foreign tax credit relief input, not an expense.
    case foreignTax
    /// Not on the return (life insurance, other income); kept visible with its sources.
    case notDeductible

    public var displayName: String {
        switch self {
        case .rentalIncome: return "Rental income"
        case .financeCost: return "Mortgage interest"
        case .serviceCharge: return "Service charge"
        case .insurance: return "Insurance (building insurance)"
        case .councilTax: return "Council tax (if paid by landlord)"
        case .lettingFees: return "Letting fee"
        case .accountancy: return "Accountancy fee"
        case .legalFees: return "Legal fees"
        case .repairs: return "Repairs and maintenance"
        case .utilities: return "Utilities"
        case .otherExpense: return "Any other expense"
        case .foreignTax: return "Foreign tax paid (PT IRS)"
        case .notDeductible: return "Not deductible"
        }
    }

    /// Expenses deducted from the rent (finance costs are relieved separately).
    public var isDeductibleExpense: Bool {
        switch self {
        case .serviceCharge, .insurance, .councilTax, .lettingFees, .accountancy, .legalFees, .repairs, .utilities, .otherExpense: return true
        case .rentalIncome, .financeCost, .foreignTax, .notDeductible: return false
        }
    }

    /// The deductible expenses in the template's order.
    public static let expenseLines: [TaxExpenseType] = [.serviceCharge, .insurance, .councilTax, .lettingFees, .accountancy, .legalFees,
                                                         .repairs, .utilities, .otherExpense]
}

/// How an expense type's transactions are attributed to a tax year (spec §4).
public enum TaxAttributionRuleKind: String, Codable, CaseIterable, Sendable {
    /// Rent receipts by their rent period, spread by days over the months April–March.
    case byRentPeriod
    /// By the month of the debit (mortgage instalments), months April–March.
    case byDebitMonth
    /// By the quota months the payment covers (condomínio), apportioned by month.
    case byQuotaMonth
    /// Apportioned by the months of cover (insurance): each receipt's cover period (its
    /// policy receipt, the note or a linked document), else the default cover months.
    case apportionByCover
    /// The policy year's premium (every receipt of that year) spread evenly over its calendar
    /// months, January–December, whatever the instalment dates: April–December to the UK
    /// year starting in it, January–March to the one before.
    case apportionPolicyYear
    /// The payment is the previous calendar year's (IMI, PT IRS): a payment in calendar year
    /// Y is for Y − 1 and goes, whole, to the UK year starting in Y − 1.
    case previousCalendarYear
    /// Foreign tax charged for a calendar year, time-apportioned by days to the UK years the
    /// calendar year straddles (HMRC INTM161220): 270/365 of year Y's tax and 95/365 of
    /// year Y + 1's go to UK year Y/Y+1. The liability year is found as for
    /// `previousCalendarYear` (a payment in Y is for Y − 1 unless the note or a document says).
    case apportionCalendarYear
    /// By the transaction's date, 6 April – 5 April.
    case byDate

    /// The rules that apportion months to the April–March window (quota, cover and policy
    /// months): a year's override of one can move its window (`TaxAttributionRule.windowShiftMonths`).
    public var supportsWindowShift: Bool {
        switch self {
        case .byQuotaMonth, .apportionByCover, .apportionPolicyYear: return true
        case .byRentPeriod, .byDebitMonth, .previousCalendarYear, .apportionCalendarYear, .byDate: return false
        }
    }

    public var displayName: String {
        switch self {
        case .byRentPeriod: return "By rent period"
        case .byDebitMonth: return "By debit month"
        case .byQuotaMonth: return "By quota month"
        case .apportionByCover: return "Apportioned by months of cover"
        case .apportionPolicyYear: return "Apportioned by policy year"
        case .previousCalendarYear: return "Previous calendar year"
        case .apportionCalendarYear: return "Calendar year, time-apportioned"
        case .byDate: return "By date"
        }
    }
}

/// An expense type's attribution rule: the default (`startYear` nil) or one year's override.
public struct TaxAttributionRule: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var expenseType: TaxExpenseType
    /// `nil` = every year without an override.
    public var startYear: Int?
    public var rule: TaxAttributionRuleKind
    /// For `apportionByCover` without a period on the documents or note: the cover months
    /// assumed, starting the month after the debit. `nil` = 12.
    public var defaultCoverMonths: Int?
    /// One year's window moved by this many months (a filed year whose workbook counted the
    /// cover or quota months October–September, say): the April–March months of the
    /// month-based rules (`TaxAttributionRuleKind.supportsWindowShift`) start this many months
    /// later (earlier when negative). Only on a year's override; `nil` = April–March.
    public var windowShiftMonths: Int?
    public var notes: String?

    public init(id: Int64? = nil, expenseType: TaxExpenseType, startYear: Int? = nil, rule: TaxAttributionRuleKind,
                defaultCoverMonths: Int? = nil, windowShiftMonths: Int? = nil, notes: String? = nil) {
        self.id = id
        self.expenseType = expenseType
        self.startYear = startYear
        self.rule = rule
        self.defaultCoverMonths = defaultCoverMonths
        self.windowShiftMonths = windowShiftMonths
        self.notes = notes
    }

    /// The shift in effect: a non-zero one on a year's override of a rule that has months.
    public var effectiveWindowShift: Int {
        guard startYear != nil, rule.supportsWindowShift, let windowShiftMonths else { return 0 }
        return windowShiftMonths
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "taxAttributionRule"
}

/// A person's share of one expense type (or, with `expenseType` nil, of every type) of a
/// property for one tax year, when it differs from the ownership.
public struct TaxYearSplit: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var startYear: Int
    public var personId: Int64
    public var propertyId: Int64
    /// `nil` = every type without its own split.
    public var expenseType: TaxExpenseType?
    /// Hundredths of a percent (5 000 = 50%).
    public var shareBasisPoints: Int

    public init(id: Int64? = nil, startYear: Int, personId: Int64, propertyId: Int64, expenseType: TaxExpenseType?, shareBasisPoints: Int) {
        self.id = id
        self.startYear = startYear
        self.personId = personId
        self.propertyId = propertyId
        self.expenseType = expenseType
        self.shareBasisPoints = shareBasisPoints
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "taxYearSplit"
}

/// Something for the return that isn't a bank movement (UK accountant invoice in GBP,
/// postage), entered with its documents (`EvidenceEntity.taxManualItem`).
public struct TaxManualItem: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var startYear: Int
    public var personId: Int64
    /// The property the item is for; `nil` = not property-related.
    public var propertyId: Int64?
    public var expenseType: TaxExpenseType
    /// "UK accountant", "Postage"…
    public var label: String
    /// Positive, in `currency`.
    public var amountMinorUnits: Int
    public var currency: Currency
    public var date: Date?
    /// `false`: the amount is the person's own; `true`: it's the whole property's, and the
    /// person's split applies.
    public var isWholeProperty: Bool
    public var notes: String?

    public init(id: Int64? = nil, startYear: Int, personId: Int64, propertyId: Int64?, expenseType: TaxExpenseType, label: String,
                amountMinorUnits: Int, currency: Currency, date: Date? = nil, isWholeProperty: Bool = false, notes: String? = nil) {
        self.id = id
        self.startYear = startYear
        self.personId = personId
        self.propertyId = propertyId
        self.expenseType = expenseType
        self.label = label
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.date = date
        self.isWholeProperty = isWholeProperty
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "taxManualItem"
}

/// Which expense type a property category's transactions are (configurable; seeded from the
/// category names by `TaxExpenseTypeMap.suggestedType`).
public struct TaxExpenseTypeMapping: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var categoryId: Int64
    public var expenseType: TaxExpenseType

    public init(id: Int64? = nil, categoryId: Int64, expenseType: TaxExpenseType) {
        self.id = id
        self.categoryId = categoryId
        self.expenseType = expenseType
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "taxExpenseTypeMap"
}

/// Where an HMRC rate came from.
public enum HMRCRateSource: String, Codable, CaseIterable, Sendable {
    /// Implied by a filed return (past years).
    case filedReturn
    /// HMRC's published average for the year to 31 March.
    case hmrcPublished
    /// Entered by the user; never replaced by a fetch.
    case manual
}

/// HMRC's average exchange rate of a currency for a UK tax year.
public struct HMRCRate: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var startYear: Int
    /// ISO 4217, upper case ("EUR", "USD").
    public var currencyCode: String
    /// Pounds per unit of the currency (0.84 for EUR): GBP = amount × rate.
    public var gbpPerUnit: Double
    /// HMRC's published form, currency units per £1 (1.19), when known.
    public var unitsPerPound: Double?
    public var source: HMRCRateSource
    public var fetchedAt: Date?
    public var notes: String?

    public init(id: Int64? = nil, startYear: Int, currencyCode: String, gbpPerUnit: Double, unitsPerPound: Double? = nil,
                source: HMRCRateSource, fetchedAt: Date? = nil, notes: String? = nil) {
        self.id = id
        self.startYear = startYear
        self.currencyCode = currencyCode
        self.gbpPerUnit = gbpPerUnit
        self.unitsPerPound = unitsPerPound
        self.source = source
        self.fetchedAt = fetchedAt
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "hmrcRate"
}

public extension EvidenceEntity {
    static func taxYear(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .taxYear, id: id) }
    static func taxManualItem(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .taxManualItem, id: id) }
}

public enum TaxError: Error, Equatable {
    case personNotFound
    case propertyNotFound
    case categoryNotFound
    case taxYearNotFound
    /// A share outside 0–100%.
    case invalidShare
    case blankLabel
    case negativeAmount
    case invalidRate
    case invalidCurrencyCode
    /// Cover months must be 1 or more.
    case invalidCoverMonths
    case transactionNotFound
    /// An instalment number outside 1…count.
    case invalidInstalment
    /// A cover period that ends before it starts.
    case invalidCoverPeriod
    /// A window shift on an every-year rule, on a rule without months, or of a year or more.
    case invalidWindowShift
    /// A payment's itemised receipts add up to more than the payment.
    case itemsExceedPayment
    /// The person doesn't own the property the payment is for (on its date).
    case notAnOwner
    /// Only a cost of a deductible line (an expense or the finance costs) can be marked
    /// "deductible, not claimed".
    case notClaimable
    /// The manual item or receipt is gone.
    case sourceNotFound
    /// The source feeds none of the year's rental-account lines.
    case notASourceOfTheYear
}

func registerTaxMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createTax") { db in
        try db.create(table: "taxYear") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startYear", .integer).notNull()
            t.column("personId", .integer).notNull().indexed().references("person", onDelete: .cascade)
            t.column("status", .text).notNull().defaults(to: TaxYearStatus.preparing.rawValue)
            t.column("notes", .text)
            t.uniqueKey(["startYear", "personId"])
        }
        try db.create(table: "taxAttributionRule") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("expenseType", .text).notNull()
            t.column("startYear", .integer)
            t.column("rule", .text).notNull()
            t.column("defaultCoverMonths", .integer)
            t.column("notes", .text)
        }
        // NULLs don't collide in a unique key, so the defaults get their own index.
        try db.execute(sql: "CREATE UNIQUE INDEX taxAttributionRule_type_year ON taxAttributionRule(expenseType, IFNULL(startYear, -1))")
        try db.create(table: "taxYearSplit") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startYear", .integer).notNull()
            t.column("personId", .integer).notNull().indexed().references("person", onDelete: .cascade)
            t.column("propertyId", .integer).notNull().indexed().references("property", onDelete: .cascade)
            t.column("expenseType", .text)
            t.column("shareBasisPoints", .integer).notNull()
        }
        try db.execute(sql: """
            CREATE UNIQUE INDEX taxYearSplit_key ON taxYearSplit(startYear, personId, propertyId, IFNULL(expenseType, ''))
            """)
        try db.create(table: "taxManualItem") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startYear", .integer).notNull()
            t.column("personId", .integer).notNull().indexed().references("person", onDelete: .cascade)
            t.column("propertyId", .integer).indexed().references("property", onDelete: .cascade)
            t.column("expenseType", .text).notNull()
            t.column("label", .text).notNull()
            t.column("amountMinorUnits", .integer).notNull()
            t.column("currency", .text).notNull()
            t.column("date", .datetime)
            t.column("isWholeProperty", .boolean).notNull().defaults(to: false)
            t.column("notes", .text)
        }
        try db.create(table: "taxExpenseTypeMap") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("categoryId", .integer).notNull().unique().references("category", onDelete: .cascade)
            t.column("expenseType", .text).notNull()
        }
        try db.create(table: "hmrcRate") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startYear", .integer).notNull()
            t.column("currencyCode", .text).notNull()
            t.column("gbpPerUnit", .double).notNull()
            t.column("unitsPerPound", .double)
            t.column("source", .text).notNull()
            t.column("fetchedAt", .datetime)
            t.column("notes", .text)
            t.uniqueKey(["startYear", "currencyCode"])
        }

        // As for the property records: a deleted tax year or manual item drops its document
        // links, waivers and the requirements scoped to it (also when removed by a cascade).
        for (table, type) in [("taxYear", EvidenceEntityType.taxYear), ("taxManualItem", .taxManualItem)] {
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

/// HMRC (INTM161220): foreign tax charged for a calendar year is time-apportioned to the UK
/// years it straddles. The seeded default for foreign tax (the whole previous calendar year)
/// moves to the apportioned basis; a default the user chose and every year override stay.
func registerForeignTaxApportionedMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("foreignTaxTimeApportionedByDefault") { db in
        try db.execute(sql: """
            UPDATE taxAttributionRule SET rule = ?
            WHERE expenseType = ? AND startYear IS NULL AND rule = ? AND notes = ?
            """, arguments: [TaxAttributionRuleKind.apportionCalendarYear.rawValue, TaxExpenseType.foreignTax.rawValue,
                             TaxAttributionRuleKind.previousCalendarYear.rawValue, TaxAttributionRules.seededNote])
    }
}

/// A return that entered the foreign tax in pounds and pence (`TaxYear.foreignTaxInPence`).
func registerTaxYearForeignTaxInPenceMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addTaxYearForeignTaxInPence") { db in
        try db.alter(table: "taxYear") { t in
            t.add(column: "foreignTaxInPence", .boolean).notNull().defaults(to: false)
        }
    }
}

/// One year's attribution window moved by whole months (`TaxAttributionRule.windowShiftMonths`).
func registerTaxAttributionRuleWindowShiftMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addTaxAttributionRuleWindowShift") { db in
        try db.alter(table: "taxAttributionRule") { t in
            t.add(column: "windowShiftMonths", .integer)
        }
    }
}
