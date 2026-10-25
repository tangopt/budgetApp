import Foundation
import GRDB

/// The last check before a save reaches the transport (sharing spec 2026-10-25 §5, anti-goal 1): every
/// payload is routed again, and the save is refused on the first disagreement, so nothing below Everything
/// reaches `household`, even in a retried batch.
public enum SyncZoneGuard {
    /// What was wrong with one payload. It names the record, zones, tables and columns only, never a value.
    public struct Violation: Error, Equatable {
        public var recordType: String
        public var recordName: String
        /// The zone the router gives the record ("none" when it can't be routed).
        public var expected: String
        /// The payload's zone.
        public var actual: String
        public var reason: String

        public init(recordType: String, recordName: String, expected: String, actual: String, reason: String) {
            self.recordType = recordType
            self.recordName = recordName
            self.expected = expected
            self.actual = actual
            self.reason = reason
        }
    }

    /// Throws the first `Violation`: a payload whose zone isn't the router's; a household payload carrying a
    /// field the router leaves out; a household payload referencing (foreign key, logical, polymorphic or
    /// JSON reference, or its import batch tag) a record the router places in a private zone; a record that
    /// can't be routed. An `accountDetails` companion must be in the zone and carry only the columns its
    /// account's assignment names.
    public static func check(_ payloads: [SyncPayload], router: SyncZoneRouter, db: Database) throws {
        for payload in payloads {
            try check(payload, router: router, db: db)
        }
    }

    private static func check(_ payload: SyncPayload, router: SyncZoneRouter, db: Database) throws {
        func violation(_ expected: String, _ reason: String) -> Violation {
            Violation(recordType: payload.recordType, recordName: payload.recordName, expected: expected, actual: payload.zone, reason: reason)
        }

        if payload.recordType == SyncZoneRouter.companionRecordType {
            guard let accountId = try SyncRecordStore.localId(table: "account", uuid: payload.recordName, db: db) else {
                throw violation("none", "no account for these details")
            }
            guard let companion = try router.assignment(table: "account", localId: accountId).companion else {
                throw violation("none", "the account has no details record")
            }
            guard payload.zone == companion.zone else { throw violation(companion.zone, "account details outside the owner's zone") }
            if let extra = payload.fields.keys.sorted().first(where: { !companion.fields.contains($0) }) {
                throw violation(companion.zone, "account details carry \(extra)")
            }
            return
        }

        guard SyncSchema.table(payload.recordType) != nil else { throw violation("none", "not a synced record type") }

        if let target = payload.mergedInto {
            // A redirect has no fields; in household it must not lead to a private record.
            guard let targetId = try SyncRecordStore.localId(table: payload.recordType, uuid: target, db: db) else {
                throw violation("none", "redirect to an unknown record")
            }
            let zone = try router.assignment(table: payload.recordType, localId: targetId).zone
            if payload.zone == SyncZones.household, SyncZones.isPrivate(zone) {
                throw violation(zone, "household redirect to a private \(payload.recordType) record")
            }
            return
        }

        guard let localId = try SyncRecordStore.localId(table: payload.recordType, uuid: payload.recordName, db: db) else {
            throw violation("none", "no local row")
        }
        let assignment = try router.assignment(table: payload.recordType, localId: localId)
        guard payload.zone == assignment.zone else { throw violation(assignment.zone, "zone differs from its routing") }
        guard payload.zone == SyncZones.household else { return }

        if let carried = assignment.omittedFields.first(where: { payload.fields[$0] != nil }) {
            throw violation(assignment.zone, "carries \(carried), which stays private")
        }

        var references = try SyncRowReferences.list(table: payload.recordType, fields: payload.fields, form: .uuid)
        if let run = payload.importRunUuid {
            references.append(SyncRowReference(column: "importRunUuid", table: "importRun", key: .uuid(run)))
        }
        for reference in references {
            guard case .uuid(let uuid) = reference.key else { continue }
            let zone: String?
            if let id = try SyncRecordStore.localId(table: reference.table, uuid: uuid, db: db) {
                zone = try router.privateZone(ofReferenced: reference.table, localId: id)
            } else if let gone = try String.fetchOne(db, sql: "SELECT zone FROM syncTombstone WHERE uuid = ?", arguments: [uuid]) {
                zone = SyncZones.isPrivate(gone) ? gone : nil
            } else {
                throw violation(assignment.zone, "\(reference.column) names an unknown \(reference.table) record")
            }
            if zone != nil {
                throw violation(assignment.zone, "\(reference.column) references a private \(reference.table) record")
            }
        }
    }
}
