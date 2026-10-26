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

    public enum InviteError: Error, Equatable {
        /// Removing a member whose iCloud user isn't known yet (she never accepted).
        case memberNotJoined
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
    /// judged by `SyncZoneGuard` as if this Mac were about to send it there. A record that doesn't open, and a document
    /// file whose document this Mac keeps in a private zone, count too. Throws the transport's errors.
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
            for file in files {
                let ownerZone = try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [file.owner])
                let ownerIsPrivate = ownerZone.map { $0 != SyncZones.household && $0 != SyncZoneSet.deviceOnlyZone } ?? false
                if flagged.contains(file.owner) || (!live.contains(file.owner) && ownerIsPrivate) {
                    found.append(SyncZoneGuard.Violation(recordType: SyncDocumentFile.recordType, recordName: file.recordName,
                                                         expected: ownerZone ?? "private", actual: zone,
                                                         reason: "the file of a record that isn't the household's"))
                }
            }
            return found
        }
        violations += found
        for violation in violations {
            log.error("Household audit: \(violation.recordType, privacy: .public) \(violation.recordName, privacy: .public) \(violation.reason, privacy: .public)")
        }
        return violations
    }

    /// The invite: the local gate, then the server audit, then the household's zone-wide share (made once: a second
    /// invite gets the same share back). Nothing is shared while anything blocks. A passing transport error (offline,
    /// busy) is `.offline`.
    public static func invite(transport: any SyncTransport & SyncShareTransport, keys: any SyncKeyStore, db: any DatabaseWriter,
                              title: String) async throws -> Result {
        let local = try await db.read { db in try localBlockers(db: db) }
        guard local.isEmpty else { return .blocked(local) }
        do {
            let violations = try await auditServer(transport: transport, keys: keys, db: db)
            guard violations.isEmpty else { return .blocked([.householdAudit(violations.count)]) }
            // Nothing changed here while the server was read.
            let again = try await db.read { db in try localBlockers(db: db) }
            guard again.isEmpty else { return .blocked(again) }
            return .share(try await transport.makeZoneShare(SyncZones.household, title: title))
        } catch let error as SyncTransportError where error.isPassing {
            return .blocked([.offline])
        }
    }

    // MARK: After the invite

    /// Once she accepts: the one accepted participant no app user holds yet becomes the member's iCloud user (written
    /// as the admin). Two or more unknown participants bind nobody (logged). False when nothing was written (no
    /// member, she already has a record name, no one or more than one to bind).
    @discardableResult
    public static func bindAcceptedParticipant(share: SyncZoneShare, db: Database) throws -> Bool {
        guard share.zone == SyncZones.household, let member = try member(db: db), member.cloudKitUserRecordName == nil else { return false }
        let known = Set(try String.fetchAll(db, sql: "SELECT cloudKitUserRecordName FROM appUser WHERE cloudKitUserRecordName IS NOT NULL"))
        let unknown = share.participants.filter { $0.status == .accepted && !known.contains($0.userRecordName) && $0.userRecordName != share.ownerRecordName }
        guard unknown.count == 1 else {
            if unknown.count > 1 { log.error("Household: \(unknown.count, privacy: .public) unknown participants accepted; nobody bound") }
            return false
        }
        let admin = try AccessActor.admin(db: db)
        try ActorWrite.perform(admin, area: .householdSettings, db: db) {
            try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = ? WHERE id = ?", arguments: [unknown[0].userRecordName, member.id])
        }
        return true
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
    /// (`SyncPullReport.leftHousehold`). This Mac keeps everything.
    public static func remove(transport: any SyncShareTransport, member: AppUser) async throws {
        guard let name = member.cloudKitUserRecordName else { throw InviteError.memberNotJoined }
        try await transport.removeParticipant(userRecordName: name, zone: SyncZones.household)
    }
}
