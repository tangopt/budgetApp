import Foundation
import GRDB
import os

/// Sealed file records in the household whose record isn't a live household record there (final review I-1): left by
/// household document deletes before deletes took their files (the step 6 hard delete, the first deletion markers).
/// They block the invite's audit (`HouseholdInvite.auditServer`), and the member could open them. Deleted once on the
/// first push after install (`SyncEngineCore`, `doneKey`) and before every invite's audit. Idempotent.
///
/// Judged from what the server holds, read from the start with the household key: a file is an orphan when its record
/// (the UUID its name starts with) is there as a deletion, move or merge marker, or isn't there at all. Never deleted:
/// the file of a record that is live there, of one that doesn't open (nothing is judged without the key), or of one
/// this device is still working on (a change or a move waiting to go up, or a live household row here: its upload may
/// be under way, file first).
public enum HouseholdOrphanFiles {
    /// `syncState` (local): the first push after install has cleaned the household's orphan files.
    public static let doneKey = "householdOrphanFilesCleaned"

    private static let log = Logger(subsystem: "com.personal.budget", category: "Household")

    /// Deletes the household's orphan file records; returns how many. Throws the transport's errors (nothing is
    /// recorded here, so a retry judges again from the server).
    @discardableResult
    public static func clean(transport: any SyncTransport, keys: any SyncKeyStore, db: any DatabaseReader) async throws -> Int {
        guard try !keys.allKeys(zone: SyncZones.household).isEmpty else { return 0 }
        let records = try await HouseholdInvite.serverRecords(transport: transport)
        return try await clean(records: records, transport: transport, keys: keys, db: db).count
    }

    /// `clean` over the household as already read from the start (`HouseholdInvite.serverRecords`): the invite reads it
    /// once for the clean and the audit. Returns the names of the file records deleted.
    static func clean(records: [SyncServerRecord], transport: any SyncTransport, keys: any SyncKeyStore,
                      db: any DatabaseReader) async throws -> Set<String> {
        let zone = SyncZones.household
        let keyring = try keys.allKeys(zone: zone)
        guard !keyring.isEmpty else { return [] }
        var live: Set<String> = []
        var unjudged: Set<String> = []
        var files: [(recordName: String, owner: String)] = []
        for record in records {
            let name = record.wire.recordName
            let type = record.wire.recordType
            if type == SyncDocumentFile.recordType {
                let parts = name.components(separatedBy: ".file.")
                // A name not of the form `<uuid>.file.<suffix>` isn't judged.
                guard parts.count == 2, !parts[0].isEmpty else { continue }
                files.append((name, parts[0]))
                continue
            }
            guard !SyncEngineCore.reservedRecordTypes.contains(type) else { continue }
            guard let payload = try? SyncLargePayload.payload(from: record, keys: keyring) else {
                unjudged.insert(name)
                continue
            }
            if payload.movedTo == nil && payload.mergedInto == nil && !payload.isDeletionMarker {
                live.insert(name)
                live.insert(payload.recordName)
            }
        }
        let candidates = files.filter { !live.contains($0.owner) && !unjudged.contains($0.owner) }
        guard !candidates.isEmpty else { return [] }
        // Read after the server: an upload that finished meanwhile shows here as a live household row.
        let busy = try await db.read { db in
            try Set(candidates.map(\.owner).filter { try isBusyHere(uuid: $0, db: db) })
        }
        let orphans = candidates.filter { !busy.contains($0.owner) }.map(\.recordName)
        guard !orphans.isEmpty else { return [] }
        let chunk = max(1, await transport.operationLimits().maxRecords)
        for start in stride(from: 0, to: orphans.count, by: chunk) {
            try await transport.delete(Array(orphans[start..<min(start + chunk, orphans.count)]), zone: zone)
        }
        log.notice("Household: \(orphans.count, privacy: .public) orphan file record(s) deleted")
        return Set(orphans)
    }

    /// Whether this device still has work for `uuid` that its household file may belong to.
    static func isBusyHere(uuid: String, db: Database) throws -> Bool {
        if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncPending WHERE uuid = ? AND kind <> 'delete')", arguments: [uuid]) == true {
            return true
        }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncZoneMove WHERE uuid = ?)", arguments: [uuid]) == true,
           try SyncZoneMoves.unfinished(db: db).contains(where: { $0.uuid == uuid }) {
            return true
        }
        guard let row = try Row.fetchOne(db, sql: "SELECT tableName, localId, zone FROM syncRecord WHERE uuid = ?", arguments: [uuid]),
              (row["zone"] as String) == SyncZones.household,
              let table = SyncSchema.table(row["tableName"]), try db.tableExists(table.name) else { return false }
        let localId: Int64 = row["localId"]
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM \(SyncChangeTracker.quoted(table.name)) WHERE \(SyncChangeTracker.quoted(table.localIdColumn)) = ?)
            """, arguments: [localId]) == true
    }

    /// Whether the first push after install has cleaned (`doneKey`).
    static func isDone(db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncState WHERE key = ?)", arguments: [doneKey]) ?? false
    }
}
