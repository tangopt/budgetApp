import CryptoKit
import Foundation
import GRDB
import os

/// The full re-placement sweep (step 7a, spec 2026-10-26 goal 1): any record whose placement changed for any reason (a
/// document later linked only to a private record, or no longer linked at all, a pin lost, a property category moved,
/// a level or owner changed) leaves the household on the next push, through the step 6 moves (`SyncZoneMoves`: the new
/// copy first, then the marker over the old one, its file sealed again; durable and resumed).
///
/// Before every push the engine works out a fingerprint of what placement reads (`fingerprint`); only when it differs
/// from the one stored (`fingerprintKey`) does the sweep route every record and queue those that aren't where they
/// go now (`misplaced`). Unchanged inputs cost one query and no routing.
public enum SyncPlacementSweep {
    /// `syncState` key of the fingerprint of the placement inputs this device last swept by.
    public static let fingerprintKey = "placementInputs"

    static let outsideZonesMessage = SyncTranslator.needsAttention + "placed in a zone this device doesn't sync; not moved here"

    /// How many sweeps routed records (tests: unchanged inputs route nothing).
    static let routings = OSAllocatedUnfairLock(initialState: 0)

    /// SHA-256 over every input of placement, each in a fixed order: the accounts' owners and levels
    /// (`SyncZoneMoves.currentFacts`), document links and every other reference to a document, the transactions the
    /// pinning tables name, categories' groups, the property category groups, import batches' runs and accounts,
    /// documents' kinds, custom kinds' areas, and app users' people (an unlinked document's inserter, the admin).
    /// One query.
    public static func fingerprint(db: Database) throws -> Data {
        var parts: [String] = [
            """
            SELECT 'facts' AS tag, s.uuid AS a, p.uuid AS b, a.sharingLevel AS c, NULL AS d FROM account a
            JOIN syncRecord s ON s.tableName = 'account' AND s.localId = a.id
            LEFT JOIN syncRecord p ON p.tableName = 'person' AND p.localId = a.ownerPersonId
            """,
            "SELECT 'documentLink', documentId, entityType, entityId, NULL FROM documentLink",
            "SELECT 'category', id, groupId, NULL, NULL FROM category",
            "SELECT 'propertyCategoryGroup', propertyId, categoryGroupId, NULL, NULL FROM propertyCategoryGroup",
            "SELECT 'importBatch', id, importRunId, accountId, NULL FROM importBatch",
            "SELECT 'document', id, kind, customKindId, NULL FROM document",
            "SELECT 'customDocumentKind', id, area, NULL, NULL FROM customDocumentKind",
            "SELECT 'appUser', id, personId, isAdmin, NULL FROM appUser",
        ]
        for table in SyncZoneRouter.pinningTables {
            parts.append("SELECT \(literal(table)), transactionId, NULL, NULL, NULL FROM \(SyncChangeTracker.quoted(table))")
        }
        for referrer in SyncZoneRouter.documentReferrers where referrer.table != "documentLink" {
            parts.append("""
                SELECT \(literal(referrer.table + "." + referrer.column)), id, \(SyncChangeTracker.quoted(referrer.column)), NULL, NULL
                FROM \(SyncChangeTracker.quoted(referrer.table))
                """)
        }
        let sql = parts.joined(separator: "\nUNION ALL\n") + "\nORDER BY 1, 2, 3, 4, 5"
        var hasher = SHA256()
        let cursor = try Row.fetchCursor(db.cachedStatement(sql: sql))
        while let row = try cursor.next() {
            for index in 0..<5 {
                switch (row[index] as DatabaseValue).storage {
                case .null: hasher.update(data: [0])
                case .int64(let value): hasher.update(data: Data("i\(value)".utf8) + [0])
                case .double(let value): hasher.update(data: Data("d\(value)".utf8) + [0])
                case .string(let value): hasher.update(data: Data("s\(value.utf8.count):\(value)".utf8))
                case .blob(let value): hasher.update(data: Data("b\(value.count):".utf8) + value)
                }
            }
        }
        return Data(hasher.finalize())
    }

    private static func literal(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    /// Every tracked record (summaries aside: their owner's device rebuilds them) that the server holds and whose
    /// placement now isn't where it is, as `SyncZoneMoves.reconcile` decides it with nothing stored: its zone here, or
    /// on the server as far as this device knows, isn't where it goes now, or it goes in a reduced form (a stub,
    /// property money) whose last sent form can't be told here. A record the router can't place is left alone. Records
    /// placed in a zone outside `zones` are returned too.
    static func misplaced(zones: Set<String>, db: Database) throws -> [SyncZoneMoves.PlacementChange] {
        let router = try SyncZoneRouter(db: db)
        var changes: [SyncZoneMoves.PlacementChange] = []
        for row in try Row.fetchAll(db, sql: "SELECT uuid, tableName, localId, zone FROM syncRecord WHERE zone <> ? ORDER BY rowid",
                                    arguments: [SyncZoneSet.deviceOnlyZone]) {
            let table: String = row["tableName"]
            let id: Int64 = row["localId"]
            let uuid: String = row["uuid"]
            guard SyncZoneRouter.rules[table] != nil, !AccessAreaMap.summaryTables.contains(table),
                  let placed = try? router.assignment(table: table, localId: id) else { continue }
            let presence = try SyncPresence.zones(uuid: uuid, db: db)
            let reduced = !placed.omittedFields.isEmpty || placed.companion != nil
            guard !presence.isEmpty, row["zone"] != placed.zone || !presence.contains(placed.zone) || reduced else { continue }
            let result: SyncZoneMoves.PlacementChange.Placed = .success(placed)
            changes.append(SyncZoneMoves.PlacementChange(uuid: uuid, tableName: table, localId: id, before: result, after: result))
        }
        return changes
    }

    /// Before a push: when the placement inputs changed since the last sweep (or none ran yet, as after an upgrade),
    /// queues every misplaced record placed in one of `zones` (the push moves it) and stores the new fingerprint, in
    /// the caller's transaction. One placed in a zone this device doesn't sync (another person's) is logged for
    /// attention and left to that person's devices: never queued, so never sent to the household instead. Unchanged
    /// inputs: one query, no routing. Returns how many records were queued.
    @discardableResult
    public static func run(zones: Set<String>, db: Database, now: Date) throws -> Int {
        guard try SharingSetup.isConfirmed(db: db) else { return 0 }
        let current = try fingerprint(db: db)
        let stored = try Data.fetchOne(db.cachedStatement(sql: "SELECT value FROM syncState WHERE key = ?"), arguments: [fingerprintKey])
        if stored == current { return 0 }
        routings.withLock { $0 += 1 }
        var queued: [SyncZoneMoves.PlacementChange] = []
        for change in try misplaced(zones: zones, db: db) {
            guard case .success(let placed) = change.after else { continue }
            if zones.contains(placed.zone) {
                queued.append(change)
            } else {
                try SyncMerge.logConflict(table: change.tableName, uuid: change.uuid, field: "*", losing: .string(outsideZonesMessage),
                                          winner: nil, loser: nil, db: db, now: now)
            }
        }
        try SyncZoneMoves.queue(queued, db: db)
        try SyncImportGate.setState(current, key: fingerprintKey, db: db, now: now)
        return queued.count
    }
}
