import GRDB
import Foundation

// Tenant utility recharges (spec 2026-10-16 §6.4, §8; plan phase 5 Task 1). The landlord pays
// the utility invoices (BBVA debits); each month the open invoices go on a statement that is
// emailed to the tenant, who adds its total to the next rent transfer. That credit is then
// split: rent (its rent receipt links) + recharge (its statement links). Dates are calendar
// days at 00:00 UTC (as the other property records); ranges are inclusive.

public enum UtilityKind: String, Codable, CaseIterable, Sendable {
    case electricity
    case gas
    case water
    case other

    public var displayName: String {
        switch self {
        case .electricity: return "Electricity"
        case .gas: return "Gas"
        case .water: return "Water"
        case .other: return "Other"
        }
    }
}

/// A utility supplier of a property ("Example Power", electricity).
public struct UtilityProvider: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var propertyId: Int64
    /// Unique per property, case-insensitively.
    public var name: String
    public var kind: UtilityKind
    /// The customer account or contract reference on its invoices.
    public var accountReference: String?
    /// Text the provider's bank debits contain (case-insensitive; alternatives separated by `|`).
    public var bankDescriptionPattern: String?
    public var notes: String?
    /// How to read its invoices; `nil` = `UtilityInvoiceRules.generic`.
    public var invoiceRules: UtilityInvoiceRules?

    public init(id: Int64? = nil, propertyId: Int64, name: String, kind: UtilityKind, accountReference: String? = nil,
                bankDescriptionPattern: String? = nil, notes: String? = nil, invoiceRules: UtilityInvoiceRules? = nil) {
        self.invoiceRules = invoiceRules
        self.id = id
        self.propertyId = propertyId
        self.name = name
        self.kind = kind
        self.accountReference = accountReference
        self.bankDescriptionPattern = bankDescriptionPattern
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "utilityProvider"
}

/// One utility invoice (or credit note: a negative amount) the landlord pays.
public struct UtilityInvoice: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var providerId: Int64
    /// Unique per provider when present.
    public var invoiceNumber: String?
    /// The consumption period, both days inclusive (both or neither).
    public var periodStart: Date?
    public var periodEnd: Date?
    public var issueDate: Date
    /// What the invoice charges; negative for a refund or credit note.
    public var amountMinorUnits: Int
    /// The invoice in the evidence library.
    public var documentId: Int64?
    /// The bank debit (or refund credit) that settled it.
    public var transactionId: Int64?
    public var notes: String?

    public init(id: Int64? = nil, providerId: Int64, invoiceNumber: String? = nil, periodStart: Date? = nil, periodEnd: Date? = nil,
                issueDate: Date, amountMinorUnits: Int, documentId: Int64? = nil, transactionId: Int64? = nil, notes: String? = nil) {
        self.id = id
        self.providerId = providerId
        self.invoiceNumber = invoiceNumber
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.issueDate = issueDate
        self.amountMinorUnits = amountMinorUnits
        self.documentId = documentId
        self.transactionId = transactionId
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "utilityInvoice"
}

public enum RechargeStatementStatus: String, Codable, CaseIterable, Sendable {
    /// Being prepared: lines can change.
    case draft
    /// Emailed to the tenant: lines are fixed.
    case sent
    /// Its total is covered by tenant credits.
    case paid
}

/// The utilities recharged to a tenancy's tenant for one month: the invoices issued (or
/// debited) since the previous statement.
public struct RechargeStatement: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var tenancyId: Int64
    /// The first day of the month the statement is for; unique per tenancy.
    public var month: Date
    /// The sum of its lines (kept by `Recharges`).
    public var totalMinorUnits: Int
    public var status: RechargeStatementStatus
    public var sentAt: Date?
    public var notes: String?

    public init(id: Int64? = nil, tenancyId: Int64, month: Date, totalMinorUnits: Int = 0, status: RechargeStatementStatus = .draft,
                sentAt: Date? = nil, notes: String? = nil) {
        self.id = id
        self.tenancyId = tenancyId
        self.month = month
        self.totalMinorUnits = totalMinorUnits
        self.status = status
        self.sentAt = sentAt
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "rechargeStatement"
}

/// One invoice (or its part for the tenancy) on a statement, or a manual line (a one-off
/// charge or refund: `invoiceId` nil, a description, optionally a document and the bank
/// movement it stands for). Manual lines the app writes itself to settle a transfer's cents
/// are rounding lines (`isRounding`): a rebuild replaces those, but keeps the other manual
/// lines (the user's one-offs).
public struct RechargeLine: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var statementId: Int64
    /// `nil` for a manual line.
    public var invoiceId: Int64?
    /// What a manual line is ("Dishwasher repair refund").
    public var lineDescription: String?
    /// The part recharged: the whole invoice, the tenancy's days of its period, or a manual
    /// amount (negative for a refund).
    public var amountMinorUnits: Int
    /// How the amount was found ("42 of 60 days in the tenancy").
    public var note: String?
    /// A manual line's document in the evidence library.
    public var documentId: Int64?
    /// A prorated invoice: the tenancy's days of its period, and the period's days.
    public var daysInTenancy: Int?
    public var daysInPeriod: Int?
    /// A manual line written to settle a transfer's cents (more or less than the lines).
    public var isRounding: Bool
    /// A manual line's bank movement (a debit whose invoice isn't recorded yet, a refund).
    public var transactionId: Int64?

    public init(id: Int64? = nil, statementId: Int64, invoiceId: Int64?, lineDescription: String? = nil, amountMinorUnits: Int,
                note: String? = nil, documentId: Int64? = nil, isRounding: Bool = false, transactionId: Int64? = nil) {
        self.isRounding = isRounding
        self.transactionId = transactionId
        self.id = id
        self.statementId = statementId
        self.invoiceId = invoiceId
        self.lineDescription = lineDescription
        self.amountMinorUnits = amountMinorUnits
        self.note = note
        self.documentId = documentId
    }

    public var isManual: Bool { invoiceId == nil }

    /// A manual line that isn't a rounding line: the user's one-off, kept by rebuilds.
    public var isOneOff: Bool { isManual && !isRounding }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "rechargeLine"
}

/// The part of a tenant credit that pays a statement (the rest of the credit is rent, through
/// its rent receipt links). One credit may pay several statements and one statement may be
/// paid by several credits.
public struct RechargePayment: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var statementId: Int64
    public var transactionId: Int64
    public var amountMinorUnits: Int
    public var origin: RentPaymentOrigin
    /// An auto link the user removed: kept so matching never makes it again; counts for nothing.
    public var isDismissed: Bool

    public init(id: Int64? = nil, statementId: Int64, transactionId: Int64, amountMinorUnits: Int, origin: RentPaymentOrigin,
                isDismissed: Bool = false) {
        self.isDismissed = isDismissed
        self.id = id
        self.statementId = statementId
        self.transactionId = transactionId
        self.amountMinorUnits = amountMinorUnits
        self.origin = origin
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "rechargePayment"
}

/// How utilities and the recharges received for them reach the rental accounts of a year.
public enum RechargeNettingMode: String, Codable, CaseIterable, Sendable {
    /// Utilities are deductible only for the part not recharged: utilities paid − recharges
    /// received, floored at zero, on the Utilities line.
    case netOfRecharges
    /// Every utility cost is left out of the return (fully recharged), as before phase 5.
    case notDeductible
}

/// The netting mode for every year (`startYear` nil) or one year. Without a stored mode the
/// engine decides (`RechargeNetting`): filed years not deductible, else net when the year has
/// recharges received, else each category on its own line.
public struct RechargeNettingRule: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var startYear: Int?
    public var mode: RechargeNettingMode
    public var notes: String?

    public init(id: Int64? = nil, startYear: Int? = nil, mode: RechargeNettingMode, notes: String? = nil) {
        self.id = id
        self.startYear = startYear
        self.mode = mode
        self.notes = notes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "rechargeNettingRule"
}

func registerRechargeMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createRecharges") { db in
        try db.create(table: "utilityProvider") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("propertyId", .integer).notNull().references("property", onDelete: .cascade)
            t.column("name", .text).notNull().collate(.nocase)
            t.column("kind", .text).notNull()
            t.column("accountReference", .text)
            t.column("bankDescriptionPattern", .text)
            t.column("notes", .text)
            t.uniqueKey(["propertyId", "name"])
        }
        try db.create(table: "utilityInvoice") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("providerId", .integer).notNull().references("utilityProvider", onDelete: .cascade)
            t.column("invoiceNumber", .text)
            t.column("periodStart", .datetime)
            t.column("periodEnd", .datetime)
            t.column("issueDate", .datetime).notNull()
            t.column("amountMinorUnits", .integer).notNull()
            t.column("documentId", .integer).indexed().references("document", onDelete: .setNull)
            t.column("transactionId", .integer).indexed().references("transaction_", onDelete: .setNull)
            t.column("notes", .text)
            // NULL invoice numbers don't collide.
            t.uniqueKey(["providerId", "invoiceNumber"])
        }
        try db.create(index: "utilityInvoice_issueDate", on: "utilityInvoice", columns: ["issueDate"])
        try db.create(table: "rechargeStatement") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("tenancyId", .integer).notNull().references("tenancy", onDelete: .cascade)
            t.column("month", .datetime).notNull()
            t.column("totalMinorUnits", .integer).notNull().defaults(to: 0)
            t.column("status", .text).notNull().defaults(to: RechargeStatementStatus.draft.rawValue)
            t.column("sentAt", .datetime)
            t.column("notes", .text)
            t.uniqueKey(["tenancyId", "month"])
        }
        try db.create(table: "rechargeLine") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("statementId", .integer).notNull().references("rechargeStatement", onDelete: .cascade)
            // Cascade, so deleting a property (→ providers → invoices) works; `Recharges` refuses
            // to delete an invoice or provider on a statement.
            t.column("invoiceId", .integer).indexed().references("utilityInvoice", onDelete: .cascade)
            t.column("lineDescription", .text)
            t.column("amountMinorUnits", .integer).notNull()
            t.column("note", .text)
            t.column("documentId", .integer).indexed().references("document", onDelete: .setNull)
            t.column("daysInTenancy", .integer)
            t.column("daysInPeriod", .integer)
            t.uniqueKey(["statementId", "invoiceId"])
        }
        try db.create(table: "rechargePayment") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("statementId", .integer).notNull().references("rechargeStatement", onDelete: .cascade)
            t.column("transactionId", .integer).notNull().indexed().references("transaction_", onDelete: .cascade)
            t.column("amountMinorUnits", .integer).notNull()
            t.column("origin", .text).notNull()
            t.column("isDismissed", .boolean).notNull().defaults(to: false)
            t.uniqueKey(["statementId", "transactionId"])
        }
        try db.create(table: "rechargeNettingRule") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startYear", .integer)
            t.column("mode", .text).notNull()
            t.column("notes", .text)
        }
        try db.execute(sql: "CREATE UNIQUE INDEX rechargeNettingRule_year ON rechargeNettingRule(IFNULL(startYear, -1))")
        // A payment link that goes (unlinked, or its credit deleted) un-pays its statement.
        try db.execute(sql: """
            CREATE TRIGGER rechargePayment_unpay AFTER DELETE ON rechargePayment
            BEGIN UPDATE rechargeStatement SET status = 'sent'
                WHERE id = OLD.statementId AND status = 'paid' AND totalMinorUnits > 0
                AND totalMinorUnits > (SELECT COALESCE(SUM(amountMinorUnits), 0) FROM rechargePayment
                                       WHERE statementId = OLD.statementId AND isDismissed = 0);
            END
            """)
    }
}

/// Rounding lines are told apart from the user's one-off manual lines (rebuilds keep the
/// latter), and a manual line can name the bank movement it stands for.
func registerRechargeLineKindMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addRechargeLineRoundingAndTransaction") { db in
        try db.alter(table: "rechargeLine") { t in
            t.add(column: "isRounding", .boolean).notNull().defaults(to: false)
            t.add(column: "transactionId", .integer).references("transaction_", onDelete: .setNull)
        }
        // The backfill's rounding lines so far.
        try db.execute(sql: "UPDATE rechargeLine SET isRounding = 1 WHERE invoiceId IS NULL AND lineDescription LIKE 'Rounding:%'")
    }
}
