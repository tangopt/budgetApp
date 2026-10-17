import GRDB
import Foundation

// Records of the property area (spec 2026-10-16 §1, §2). Dates are calendar days: stored as
// 00:00 UTC (`MonthRange.calendar`), and every range end (`toDate`, `endDate`, `periodEnd`)
// is INCLUSIVE — a tenancy ending 30 Sep covers 30 Sep. Amounts are minor units of the
// property's currency.
//
// UI: a date picker's value is local midnight (BST/WEST midnight is 23:00 UTC the day
// before), so convert picked days with `PayCalendar.utcDay(sameDayAs:in:)` before saving, and
// back with `PayCalendar.localDay(sameDayAs:in:)` for display. The APIs only truncate to the
// UTC day, which would shift a local-midnight value one day early.
//
// `propertyOwner` rows are replaced wholesale by `Properties.setOwners`, so nothing may
// reference `propertyOwner.id`.

/// Someone who owns a property or files a tax return. Tax identifiers stay on this device.
public struct Person: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    /// Unique, case-insensitively.
    public var name: String
    /// How the person is shown in tight places ("A").
    public var shortName: String?
    /// UK Unique Taxpayer Reference.
    public var ukUtr: String?
    /// UK National Insurance number.
    public var ukNino: String?
    /// Portuguese tax number (NIF).
    public var ptNif: String?
    public var notes: String?

    public init(id: Int64? = nil, name: String, shortName: String? = nil, ukUtr: String? = nil, ukNino: String? = nil,
                ptNif: String? = nil, notes: String? = nil) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.ukUtr = ukUtr
        self.ukNino = ukNino
        self.ptNif = ptNif
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "person"

    public var displayShortName: String { shortName ?? name }
}

/// A property the user owns and may let (Lisbon today).
public struct Property: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    /// Unique, case-insensitively.
    public var name: String
    /// ISO 3166-1 alpha-2 code, upper case ("PT").
    public var country: String
    /// The currency rents and the purchase price are in.
    public var currency: Currency
    /// The land registry ("artigo matricial") reference.
    public var matrixArticle: String?
    public var purchasePriceMinorUnits: Int?
    public var purchaseDate: Date?
    public var notes: String?

    public init(id: Int64? = nil, name: String, country: String, currency: Currency = .eur, matrixArticle: String? = nil,
                purchasePriceMinorUnits: Int? = nil, purchaseDate: Date? = nil, notes: String? = nil) {
        self.id = id
        self.name = name
        self.country = country
        self.currency = currency
        self.matrixArticle = matrixArticle
        self.purchasePriceMinorUnits = purchasePriceMinorUnits
        self.purchaseDate = purchaseDate
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "property"
}

/// One person's share of a property over a date range. At any date, the shares of a
/// property's owners sum to 100% (or there are none: before purchase, after sale).
public struct PropertyOwner: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var propertyId: Int64
    public var personId: Int64
    /// Hundredths of a percent: 10 000 = 100%, 5 000 = 50%.
    public var shareBasisPoints: Int
    /// First day owned; `nil` = since always.
    public var fromDate: Date?
    /// Last day owned (inclusive); `nil` = still owned.
    public var toDate: Date?

    public init(id: Int64? = nil, propertyId: Int64, personId: Int64, shareBasisPoints: Int, fromDate: Date? = nil, toDate: Date? = nil) {
        self.id = id
        self.propertyId = propertyId
        self.personId = personId
        self.shareBasisPoints = shareBasisPoints
        self.fromDate = fromDate
        self.toDate = toDate
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "propertyOwner"

    public static let wholeShare = 10_000

    /// Whether the range covers `day` (a normalised day).
    func covers(_ day: Date) -> Bool {
        (fromDate.map { $0 <= day } ?? true) && (toDate.map { day <= $0 } ?? true)
    }
}

/// What an account is to a property.
public enum PropertyAccountRole: String, Codable, CaseIterable, Sendable {
    /// Where rent arrives and costs are paid from.
    case current
    case mortgage
    /// Holds the tenant's deposit (caução).
    case deposit
    case other
}

/// An account that belongs to a property's finances.
public struct PropertyAccount: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var propertyId: Int64
    public var accountId: Int64
    public var role: PropertyAccountRole

    public init(id: Int64? = nil, propertyId: Int64, accountId: Int64, role: PropertyAccountRole) {
        self.id = id
        self.propertyId = propertyId
        self.accountId = accountId
        self.role = role
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "propertyAccount"
}

/// A category group whose categories are the property's costs and income ("Lisbon").
public struct PropertyCategoryGroup: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var propertyId: Int64
    public var categoryGroupId: Int64

    public init(id: Int64? = nil, propertyId: Int64, categoryGroupId: Int64) {
        self.id = id
        self.propertyId = propertyId
        self.categoryGroupId = categoryGroupId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "propertyCategoryGroup"
}

/// A letting of the property under one contract.
public struct Tenancy: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var propertyId: Int64
    /// The portal's reference ("Referência"), e.g. "Room Contract AB".
    public var referenceLabel: String
    /// The portal's contract number ("Nº de Contrato"); unique per property.
    public var contractNumber: String?
    public var tenantName: String?
    public var startDate: Date
    /// Last day of the tenancy (inclusive); `nil` = ongoing.
    public var endDate: Date?
    /// Months of rent paid in advance and held.
    public var advanceRentMonths: Int
    /// Months of rent held as deposit (caução).
    public var depositMonths: Int
    public var notes: String?
    /// Where the monthly utility recharge statement is emailed (several separated by commas).
    public var tenantEmail: String?

    public init(id: Int64? = nil, propertyId: Int64, referenceLabel: String, contractNumber: String? = nil, tenantName: String? = nil,
                startDate: Date, endDate: Date? = nil, advanceRentMonths: Int = 0, depositMonths: Int = 0, notes: String? = nil,
                tenantEmail: String? = nil) {
        self.tenantEmail = tenantEmail
        self.id = id
        self.propertyId = propertyId
        self.referenceLabel = referenceLabel
        self.contractNumber = contractNumber
        self.tenantName = tenantName
        self.startDate = startDate
        self.endDate = endDate
        self.advanceRentMonths = advanceRentMonths
        self.depositMonths = depositMonths
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "tenancy"

    /// Whether the tenancy runs on `day` (a normalised day).
    public func covers(_ day: Date) -> Bool {
        startDate <= day && (endDate.map { day <= $0 } ?? true)
    }
}

/// The monthly rent of a tenancy from a date on (rent history: 1,000 → 1,100).
public struct TenancyRent: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var tenancyId: Int64
    public var fromDate: Date
    public var monthlyAmountMinorUnits: Int

    public init(id: Int64? = nil, tenancyId: Int64, fromDate: Date, monthlyAmountMinorUnits: Int) {
        self.id = id
        self.tenancyId = tenancyId
        self.fromDate = fromDate
        self.monthlyAmountMinorUnits = monthlyAmountMinorUnits
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "tenancyRent"
}

public enum RentReceiptStatus: String, Codable, CaseIterable, Sendable {
    case issued
    case cancelled
}

/// A rent receipt issued on the Portal das Finanças ("recibo de renda eletrónico").
public struct RentReceipt: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var tenancyId: Int64
    /// "Nº de Recibo"; unique per tenancy.
    public var receiptNumber: String
    /// The rent period covered, both days inclusive.
    public var periodStart: Date
    public var periodEnd: Date
    /// "Data de Rec." — when the rent was received; the portal leaves it blank on some receipts.
    public var receiptDate: Date?
    /// "Valor": the rent.
    public var amountMinorUnits: Int
    /// "Retenção IRS": tax withheld by the tenant.
    public var withholdingMinorUnits: Int
    /// "Importância recebida": what the landlord received.
    public var amountReceivedMinorUnits: Int
    public var status: RentReceiptStatus

    /// `amountReceivedMinorUnits` defaults to the rent less withholding.
    public init(id: Int64? = nil, tenancyId: Int64, receiptNumber: String, periodStart: Date, periodEnd: Date, receiptDate: Date?,
                amountMinorUnits: Int, withholdingMinorUnits: Int = 0, amountReceivedMinorUnits: Int? = nil,
                status: RentReceiptStatus = .issued) {
        self.id = id
        self.tenancyId = tenancyId
        self.receiptNumber = receiptNumber
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.receiptDate = receiptDate
        self.amountMinorUnits = amountMinorUnits
        self.withholdingMinorUnits = withholdingMinorUnits
        self.amountReceivedMinorUnits = amountReceivedMinorUnits ?? amountMinorUnits - withholdingMinorUnits
        self.status = status
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "rentReceipt"
}

public extension EvidenceEntity {
    static func property(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .property, id: id) }
    static func person(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .person, id: id) }
    static func tenancy(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .tenancy, id: id) }
    static func rentReceipt(_ id: Int64) -> EvidenceEntity { EvidenceEntity(type: .rentReceipt, id: id) }
}

func registerPropertyMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createProperty") { db in
        try db.create(table: "person") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique().collate(.nocase)
            t.column("shortName", .text)
            t.column("ukUtr", .text)
            t.column("ukNino", .text)
            t.column("ptNif", .text)
            t.column("notes", .text)
        }
        try db.create(table: "property") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique().collate(.nocase)
            t.column("country", .text).notNull()
            t.column("currency", .text).notNull().defaults(to: Currency.eur.rawValue)
            t.column("matrixArticle", .text)
            t.column("purchasePriceMinorUnits", .integer)
            t.column("purchaseDate", .datetime)
            t.column("notes", .text)
        }
        try db.create(table: "propertyOwner") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("propertyId", .integer).notNull().indexed().references("property", onDelete: .cascade)
            t.column("personId", .integer).notNull().indexed().references("person", onDelete: .restrict)
            t.column("shareBasisPoints", .integer).notNull()
            t.column("fromDate", .datetime)
            t.column("toDate", .datetime)
        }
        try db.create(table: "propertyAccount") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("propertyId", .integer).notNull().references("property", onDelete: .cascade)
            t.column("accountId", .integer).notNull().indexed().references("account", onDelete: .cascade)
            t.column("role", .text).notNull()
            t.uniqueKey(["propertyId", "accountId"])
        }
        try db.create(table: "propertyCategoryGroup") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("propertyId", .integer).notNull().references("property", onDelete: .cascade)
            t.column("categoryGroupId", .integer).notNull().indexed().references("categoryGroup", onDelete: .cascade)
            t.uniqueKey(["propertyId", "categoryGroupId"])
        }
        try db.create(table: "tenancy") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("propertyId", .integer).notNull().references("property", onDelete: .cascade)
            t.column("referenceLabel", .text).notNull()
            t.column("contractNumber", .text)
            t.column("tenantName", .text)
            t.column("startDate", .datetime).notNull()
            t.column("endDate", .datetime)
            t.column("advanceRentMonths", .integer).notNull().defaults(to: 0)
            t.column("depositMonths", .integer).notNull().defaults(to: 0)
            t.column("notes", .text)
            // NULL contract numbers don't collide (SQLite), so several unnumbered tenancies are fine.
            t.uniqueKey(["propertyId", "contractNumber"])
        }
        try db.create(table: "tenancyRent") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("tenancyId", .integer).notNull().references("tenancy", onDelete: .cascade)
            t.column("fromDate", .datetime).notNull()
            t.column("monthlyAmountMinorUnits", .integer).notNull()
            t.uniqueKey(["tenancyId", "fromDate"])
        }
        try db.create(table: "rentReceipt") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("tenancyId", .integer).notNull().references("tenancy", onDelete: .cascade)
            t.column("receiptNumber", .text).notNull()
            t.column("periodStart", .datetime).notNull()
            t.column("periodEnd", .datetime).notNull()
            t.column("receiptDate", .datetime)
            t.column("amountMinorUnits", .integer).notNull()
            t.column("withholdingMinorUnits", .integer).notNull().defaults(to: 0)
            t.column("amountReceivedMinorUnits", .integer).notNull()
            t.column("status", .text).notNull().defaults(to: RentReceiptStatus.issued.rawValue)
            t.uniqueKey(["tenancyId", "receiptNumber"])
        }
        try db.create(index: "rentReceipt_period", on: "rentReceipt", columns: ["periodStart", "periodEnd"])

        // Evidence points at records by type and id (no foreign key): a deleted record drops
        // its document links, its waivers, and the requirements scoped to it alone (periodic or
        // single). These also fire for rows removed by a cascade (property → tenancies → receipts).
        for (table, type) in [("person", EvidenceEntityType.person), ("property", .property),
                              ("tenancy", .tenancy), ("rentReceipt", .rentReceipt)] {
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
