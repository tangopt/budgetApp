import Foundation
import GRDB
import os

/// Inviting the household's member (step 7a): the gate before the share, the zone-wide share itself, binding her iCloud
/// user to her app user once she accepts, and removing her. The admin's Mac only.
///
/// The gate is the safety heart of the invite: the share goes only when ownership is confirmed, real sync is on and has
/// nothing left to upload, the placement sweep finds nothing out of place, and the household zone as the server holds
/// it, opened with the household key, has nothing in it that `SyncZoneGuard` (the push's second line of defence, which
/// never asks the router) refuses.
public enum HouseholdInvite {
    /// Why the invite can't go yet (`HouseholdCopy.blocker`).
    public enum Blocker: Equatable, Sendable {
        case ownershipNotConfirmed
        case syncNotOn
        case noMember
        /// Changes still to upload, and moves still to finish.
        case pendingUpload(Int)
        /// Records not where they go now (the sweep hasn't moved them yet).
        case misplaced(Int)
        /// Records the server's household holds that the guard refuses there.
        case householdAudit(Int)
        /// iCloud couldn't be reached (a passing error): nothing was checked or shared.
        case offline
    }

    public enum Result: Equatable, Sendable {
        case blocked([Blocker])
        case share(SyncZoneShare)
    }

    public enum Status: Equatable, Sendable {
        case notInvited, invited, joined
    }

    private static let log = Logger(subsystem: "com.personal.budget", category: "Household")

    /// The household's member: the app user who isn't an admin (step 7a has one).
    public static func member(db: Database) throws -> AppUser? {
        try AppUser.filter(Column("isAdmin") == false).order(Column("id")).fetchOne(db)
    }

    // MARK: The gate

    /// What this Mac knows that stops the invite, in the order the copy lists them.
    public static func localBlockers(db: Database) throws -> [Blocker] {
        var blockers: [Blocker] = []
        let confirmed = try SharingSetup.isConfirmed(db: db)
        if !confirmed { blockers.append(.ownershipNotConfirmed) }
        if try SyncTurnOn.stage(db: db) != .done { blockers.append(.syncNotOn) }
        if try member(db: db) == nil { blockers.append(.noMember) }
        let pending = try SyncChangeTracker.pending(db: db).count + SyncZoneMoves.unfinished(db: db).count
        if pending > 0 { blockers.append(.pendingUpload(pending)) }
        if confirmed {
            let admin = try AccessActor.admin(db: db)
            var zones: Set<String> = [SyncZones.household]
            if let adminUuid = try SyncRecordStore.existingUUID(table: "person", localId: admin.personId, db: db) {
                zones.insert(SyncZones.privateZone(personUuid: adminUuid))
            }
            let misplaced = try SyncPlacementSweep.unsettled(zones: zones, db: db).count
            if misplaced > 0 { blockers.append(.misplaced(misplaced)) }
        }
        return blockers
    }

    /// Every record the server's household zone holds (every page, from the start), opened with the household key and
    /// judged by `SyncZoneGuard` as if this Mac were about to send it there. A record that doesn't open counts too, and so
    /// does a document file whose document isn't a live household record there (flagged, a marker, or gone: an orphan
    /// file fails closed). Throws the transport's errors.
    public static func auditServer(transport: any SyncTransport, keys: any SyncKeyStore, db: any DatabaseReader) async throws
        -> [SyncZoneGuard.Violation] {
        let zone = SyncZones.household
        var records: [SyncServerRecord] = []
        var token: Data?
        while true {
            let page = try await transport.changes(since: token, zone: zone)
            records += page.records
            token = page.token
            if !page.moreComing { break }
        }
        let keyring = try keys.allKeys(zone: zone)
        var payloads: [SyncPayload] = []
        var violations: [SyncZoneGuard.Violation] = []
        var files: [(recordName: String, owner: String)] = []
        for record in records {
            let type = record.wire.recordType
            if type == SyncDocumentFile.recordType {
                let owner = record.wire.recordName.components(separatedBy: ".file.").first ?? record.wire.recordName
                files.append((record.wire.recordName, owner))
                continue
            }
            guard !SyncEngineCore.reservedRecordTypes.contains(type) else { continue }
            do {
                var payload = try SyncLargePayload.payload(from: record, keys: keyring)
                // Judged where it is, whatever zone it names inside.
                payload.zone = zone
                payloads.append(payload)
            } catch {
                violations.append(SyncZoneGuard.Violation(recordType: type, recordName: record.wire.recordName, expected: "none",
                                                          actual: zone, reason: "doesn't open with the household key"))
            }
        }
        let live = Set(payloads.filter { $0.movedTo == nil && $0.mergedInto == nil && !$0.isDeletionMarker }.map(\.recordName))
        let found = try await db.read { db -> [SyncZoneGuard.Violation] in
            var found = try SyncZoneGuard(db: db).review(payloads).violations
            let flagged = Set(found.map(\.recordName))
            for file in files where flagged.contains(file.owner) || !live.contains(file.owner) {
                let ownerZone = try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [file.owner])
                found.append(SyncZoneGuard.Violation(recordType: SyncDocumentFile.recordType, recordName: file.recordName,
                                                     expected: ownerZone ?? "none", actual: zone,
                                                     reason: "the file of a record that isn't the household's"))
            }
            return found
        }
        violations += found
        for violation in violations {
            log.error("Household audit: \(violation.recordType, privacy: .public) \(violation.recordName, privacy: .public) \(violation.reason, privacy: .public)")
        }
        return violations
    }

    /// The invite: the local gate, then the household's orphan files cleaned (`HouseholdOrphanFiles`), the server audit, then the household's zone-wide share (made once: a second
    /// invite gets the same share back; step 8: read-write, and an existing read-only share is upgraded). Nothing is shared while anything blocks. A passing transport error (offline,
    /// busy) is `.offline`.
    public static func invite(transport: any SyncTransport & SyncShareTransport, keys: any SyncKeyStore, db: any DatabaseWriter,
                              title: String) async throws -> Result {
        do {
            let result = try await gated(transport: transport, keys: keys, db: db) {
                try await transport.makeZoneShare(SyncZones.household, title: title)
            }
            if case .share = result {
                // Inviting again: whoever was removed before may be bound once they accept this invitation.
                try await db.write { db in try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [removedKey]) }
            }
            return result
        } catch let error as SyncTransportError where error.isPassing {
            return .blocked([.offline])
        }
    }

    // MARK: Letting her make changes (step 8)

    /// Whether someone who has accepted the household's share can only read it (a 7a share, read-only then): the Mac
    /// offers "Let … make changes" (`allowMemberEdits`) until the share is upgraded.
    public static func needsEditUpgrade(_ share: SyncZoneShare?) -> Bool {
        share?.participants.contains { $0.status == .accepted && !$0.canWrite } ?? false
    }

    /// The admin's press of "Let … make changes": the invite's gate (local blockers, orphan files, the server audit,
    /// local again), then `makeZoneShare`, which upgrades the existing share in place (no public access, every
    /// participant read-write). Nothing is changed while anything blocks, and when nobody on the share is read-only it
    /// returns the share as it is, without a save. Never automatic: only this call upgrades a live share. A passing
    /// transport error is `.offline`. Unlike `invite`, it leaves the record of who was removed as it is.
    public static func allowMemberEdits(transport: any SyncTransport & SyncShareTransport, keys: any SyncKeyStore,
                                        db: any DatabaseWriter, title: String) async throws -> Result {
        do {
            if let current = try await transport.zoneShare(SyncZones.household), !current.participants.contains(where: { !$0.canWrite }) {
                return .share(current)
            }
            return try await gated(transport: transport, keys: keys, db: db) {
                let share = try await transport.makeZoneShare(SyncZones.household, title: title)
                log.notice("Household: share upgraded, \(share.participants.count, privacy: .public) participant(s) read-write")
                return share
            }
        } catch let error as SyncTransportError where error.isPassing {
            return .blocked([.offline])
        }
    }

    /// The gate both the invite and the upgrade go through: local blockers, the household's orphan files cleaned, the
    /// server audit, local blockers again, then `share`. Nothing reaches `share` while anything blocks.
    private static func gated(transport: any SyncTransport & SyncShareTransport, keys: any SyncKeyStore, db: any DatabaseWriter,
                              share: () async throws -> SyncZoneShare) async throws -> Result {
        let local = try await db.read { db in try localBlockers(db: db) }
        guard local.isEmpty else { return .blocked(local) }
        // Final review I-1: files left by household document deletes before deletes took them go first.
        try await HouseholdOrphanFiles.clean(transport: transport, keys: keys, db: db)
        let violations = try await auditServer(transport: transport, keys: keys, db: db)
        guard violations.isEmpty else { return .blocked([.householdAudit(violations.count)]) }
        // Nothing changed here while the server was read.
        let again = try await db.read { db in try localBlockers(db: db) }
        guard again.isEmpty else { return .blocked(again) }
        return .share(try await share())
    }

    // MARK: After the invite

    /// What `bindAcceptedParticipant` did.
    public enum BindOutcome: Equatable, Sendable {
        /// The member's iCloud user is now the one accepted participant.
        case bound
        /// Nothing to bind: no member, she is bound already, or no unknown participant has accepted.
        case nothing
        /// More than one unknown participant accepted: nobody is bound (`HouseholdCopy.ambiguousParticipants`). The
        /// admin removes the invitation and invites again; Task 8's side-by-side code is the person check.
        case ambiguous(Int)
    }

    /// Once she accepts: the one accepted participant no app user holds yet (and not removed since,
    /// `remove`) becomes the member's iCloud user (written as the admin). Two or more such participants bind nobody
    /// (logged, `.ambiguous`).
    @discardableResult
    public static func bindAcceptedParticipant(share: SyncZoneShare, db: Database) throws -> BindOutcome {
        guard share.zone == SyncZones.household, let member = try member(db: db), member.cloudKitUserRecordName == nil else { return .nothing }
        let known = Set(try String.fetchAll(db, sql: "SELECT cloudKitUserRecordName FROM appUser WHERE cloudKitUserRecordName IS NOT NULL"))
            .union(try removed(db: db))
        let unknown = share.participants.filter { $0.status == .accepted && !known.contains($0.userRecordName) && $0.userRecordName != share.ownerRecordName }
        guard unknown.count == 1 else {
            guard unknown.count > 1 else { return .nothing }
            log.error("Household: \(unknown.count, privacy: .public) unknown participants accepted; nobody bound")
            return .ambiguous(unknown.count)
        }
        let admin = try AccessActor.admin(db: db)
        try ActorWrite.perform(admin, area: .householdSettings, db: db) {
            try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = ? WHERE id = ?", arguments: [unknown[0].userRecordName, member.id])
        }
        return .bound
    }

    /// Where the member stands: no share yet, shared (she hasn't joined), or joined (her bound iCloud user has accepted).
    public static func status(share: SyncZoneShare?, member: AppUser?) -> Status {
        guard let share, let member else { return .notInvited }
        if let name = member.cloudKitUserRecordName,
           share.participants.contains(where: { $0.userRecordName == name && $0.status == .accepted }) {
            return .joined
        }
        return .invited
    }

    /// Takes her off the household's share: her devices find the zone gone and drop its data
    /// (`SyncPullReport.leftHousehold`). This Mac keeps everything. Before her iCloud user is bound (invited, or accepted
    /// but not bound yet), everyone but the owner comes off the share, so no pending invitation stays live. The record
    /// names taken off are recorded here (local), so a late acceptance from one of them is never bound; the next
    /// successful invite clears the record.
    public static func remove(transport: any SyncShareTransport, member: AppUser, db: any DatabaseWriter) async throws {
        let removedNames: [String]
        if let name = member.cloudKitUserRecordName {
            try await transport.removeParticipant(userRecordName: name, zone: SyncZones.household)
            removedNames = [name]
        } else {
            removedNames = try await transport.removeAllParticipants(zone: SyncZones.household)
        }
        try await db.write { db in
            let all = Array(Set(try removed(db: db)).union(removedNames)).sorted()
            try SyncImportGate.setState(try JSONEncoder().encode(all), key: removedKey, db: db, now: Date())
        }
        log.notice("Household: \(removedNames.count, privacy: .public) participant(s) removed from the share")
    }

    /// `syncState` (local): the record names `remove` took off the share since the last invite.
    static let removedKey = "householdRemovedParticipants"

    /// Whether the admin removed the member (`remove`) and has not invited again since.
    public static func wasRemoved(db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE key = ?", arguments: [removedKey]) == 1
    }

    /// The record names taken off the household's share since the last invite (`remove`).
    public static func removed(db: Database) throws -> [String] {
        try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [removedKey])
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }
}
