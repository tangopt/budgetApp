import GRDB
import Foundation

/// The property's records in the missing-evidence checklist (spec 2026-10-16 §7): one PDF per
/// issued rent receipt, one contract per tenancy (`EvidenceRequirementScope.recordsOfProperty`).
public enum PropertyEvidence {
    /// The record types `recordsOfProperty` covers.
    public static let recordTypes: Set<EvidenceEntityType> = [.tenancy, .rentReceipt]

    /// A record expecting a document.
    public struct Record: Equatable, Sendable {
        public var entity: EvidenceEntity
        public var title: String
        public var date: Date?
        public var amountMinorUnits: Int?
        public var currency: Currency?
        /// What the record covers, `[start, end)`.
        public var period: DateInterval?
    }

    /// The property's issued receipts whose rent period meets `period`, or its tenancies
    /// running in it; by date.
    public static func records(db: Database, propertyId: Int64, type: EvidenceEntityType, overlapping period: DateInterval) throws -> [Record] {
        guard let property = try Property.fetchOne(db, key: propertyId) else { return [] }
        let tenancies = Dictionary(uniqueKeysWithValues: try Tenancies.all(db: db, propertyId: propertyId).map { ($0.id!, $0) })
        switch type {
        case .rentReceipt:
            return try RentReceipts.receipts(db: db, propertyId: propertyId, overlapping: period).map { receipt in
                let label = tenancies[receipt.tenancyId]?.referenceLabel ?? ""
                return Record(entity: .rentReceipt(receipt.id!), title: "Rent receipt \(receipt.receiptNumber) · \(label)",
                              date: receipt.receiptDate, amountMinorUnits: receipt.amountMinorUnits, currency: property.currency,
                              period: DateInterval(start: receipt.periodStart, end: PropertyDates.nextDay(receipt.periodEnd)))
            }
        case .tenancy:
            return tenancies.values
                .filter { tenancy in
                    tenancy.startDate < period.end && (tenancy.endDate.map { PropertyDates.nextDay($0) > period.start } ?? true)
                }
                .sorted { ($0.startDate, $0.id!) < ($1.startDate, $1.id!) }
                .map { tenancy in
                    Record(entity: .tenancy(tenancy.id!), title: "Tenancy contract · \(tenancy.referenceLabel)", date: tenancy.startDate,
                           amountMinorUnits: nil, currency: nil,
                           period: DateInterval(start: tenancy.startDate, end: tenancy.endDate.map(PropertyDates.nextDay) ?? max(period.end, tenancy.startDate)))
                }
        default:
            return []
        }
    }

    /// The default rules for a property, unsaved (the app previews them): rent receipt PDFs
    /// from the Portal das Finanças, and the signed contract of each tenancy. A rule whose
    /// scope already exists is left out.
    public static func defaultRules(db: Database, propertyId: Int64) throws -> [EvidenceRequirement] {
        guard let property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        let existing = Set(try EvidenceRequirement.fetchAll(db).map(\.scope))
        let rules = [
            EvidenceRequirement(name: "\(property.name): rent receipts", scope: .recordsOfProperty(propertyId: propertyId, recordType: .rentReceipt),
                                kinds: [.rentReceipt], direction: .inflows, usualSource: "Portal das Finanças", notes: seededNote),
            EvidenceRequirement(name: "\(property.name): tenancy contracts", scope: .recordsOfProperty(propertyId: propertyId, recordType: .tenancy),
                                kinds: [.rentContract], direction: .inflows, usualSource: "Tenancy contract", notes: seededNote)
        ]
        return rules.filter { !existing.contains($0.scope) }
    }

    /// Saves `defaultRules` (idempotent); returns what was added.
    @discardableResult
    public static func seedRules(db: Database, propertyId: Int64) throws -> [EvidenceRequirement] {
        var saved: [EvidenceRequirement] = []
        for var rule in try defaultRules(db: db, propertyId: propertyId) {
            try EvidenceRequirements.save(db: db, &rule)
            saved.append(rule)
        }
        return saved
    }

    public static let seededNote = "Default rule (property)"
}

/// A deleted property takes its `recordsOfProperty` requirements with it (their waivers cascade).
func registerPropertyEvidenceRequirementMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addPropertyRecordRequirementTrigger") { db in
        try db.execute(sql: """
            CREATE TRIGGER evidenceRequirement_delete_propertyRecords AFTER DELETE ON property
            BEGIN DELETE FROM evidenceRequirement WHERE json_extract(scope, '$.recordsOfProperty.propertyId') = OLD.id; END
            """)
    }
}
