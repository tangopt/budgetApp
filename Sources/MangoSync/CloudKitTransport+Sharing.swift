import CloudKit
import Foundation
import BudgetCore

/// `SyncShareTransport` over CloudKit (step 7a): a zone-wide `CKShare` (`CKShare(recordZoneID:)`, fetched as the
/// zone's `CKRecordNameZoneWideShare` record), with no public access and read-write participants (step 8); participants are added through the system
/// share sheet and accept through the link. Participants are matched by `userIdentity.userRecordID.recordName`;
/// CloudKit names the current user `CKCurrentUserDefaultName`, which becomes `currentUserRecordName()`.
extension CloudKitTransport: SyncShareTransport {
    public func currentUserRecordName() async throws -> String { try await currentUser() }

    /// The zone's `CKShare` itself and its container, for the system share sheet (`NSItemProvider.registerCKShare`).
    public func shareForSheet(_ zone: String) async throws -> (share: CKShare, container: CKContainer)? {
        guard let share = try await fetchZoneShare(zone) else { return nil }
        return (share, container)
    }

    public func zoneShare(_ zone: String) async throws -> SyncZoneShare? {
        guard let share = try await fetchZoneShare(zone) else { return nil }
        return Self.syncShare(share, zone: zone, currentUser: try await currentUser())
    }

    public func makeZoneShare(_ zone: String, title: String) async throws -> SyncZoneShare {
        if let existing = try await fetchZoneShare(zone) {
            return try await upgrade(existing, zone: zone, retry: true)
        }
        let share = CKShare(recordZoneID: zoneID(zone))
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        share.publicPermission = .none
        do {
            let saved = try await saveShare(share, zone: zone)
            return Self.syncShare(saved, zone: zone, currentUser: try await currentUser())
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Made meanwhile (another device, or a reply lost after it saved): that share is the one, upgraded as needed.
            if let existing = try await fetchZoneShare(zone) { return try await upgrade(existing, zone: zone, retry: false) }
            throw CloudKitRecordMapping.operationError(error, zone: zone)
        }
    }

    /// The existing share made read-write in place (step 8): no public access, and every read-only participant (not the
    /// owner, not removed) `.readWrite`; nothing else about it changes. Saved against the version fetched; when the server's
    /// share changed meanwhile, it is fetched again and tried once more.
    private func upgrade(_ share: CKShare, zone: String, retry: Bool) async throws -> SyncZoneShare {
        let readOnly = share.participants.filter {
            $0.role != .owner && $0.acceptanceStatus != .removed && $0.permission == .readOnly
        }
        guard !readOnly.isEmpty || share.publicPermission != .none else {
            return Self.syncShare(share, zone: zone, currentUser: try await currentUser())
        }
        share.publicPermission = .none
        for participant in readOnly { participant.permission = .readWrite }
        do {
            let saved = try await saveShare(share, zone: zone)
            return Self.syncShare(saved, zone: zone, currentUser: try await currentUser())
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard retry, let fresh = try await fetchZoneShare(zone) else { throw CloudKitRecordMapping.operationError(error, zone: zone) }
            return try await upgrade(fresh, zone: zone, retry: false)
        }
    }

    public func removeParticipant(userRecordName: String, zone: String) async throws {
        guard let share = try await fetchZoneShare(zone) else { return }
        let me = try await currentUser()
        let matching = share.participants.filter {
            $0.role != .owner && Self.recordName(of: $0, currentUser: me) == userRecordName
        }
        guard !matching.isEmpty else { return }
        for participant in matching { share.removeParticipant(participant) }
        _ = try await saveShare(share, zone: zone)
    }

    public func removeAllParticipants(zone: String) async throws -> [String] {
        guard let share = try await fetchZoneShare(zone) else { return [] }
        let me = try await currentUser()
        let others = share.participants.filter { $0.role != .owner }
        guard !others.isEmpty else { return [] }
        let names = others.compactMap { Self.recordName(of: $0, currentUser: me) }
        for participant in others { share.removeParticipant(participant) }
        _ = try await saveShare(share, zone: zone)
        return names
    }

    // MARK: Helpers

    private func fetchZoneShare(_ zone: String) async throws -> CKShare? {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(zone))
        do {
            let record = try await database.record(for: id)
            return record as? CKShare
        } catch where CloudKitRecordMapping.isMissingRecord(error) {
            return nil
        } catch {
            throw CloudKitRecordMapping.operationError(error, zone: zone)
        }
    }

    /// Saves the share against the version it was fetched at (a new one: create only). A `serverRecordChanged`
    /// refusal is thrown as it is, for the caller to read the server's share.
    private func saveShare(_ share: CKShare, zone: String) async throws -> CKShare {
        let results: [CKRecord.ID: Result<CKRecord, Error>]
        do {
            results = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged,
                                                       atomically: true).saveResults
        } catch {
            throw CloudKitRecordMapping.operationError(error, zone: zone)
        }
        guard let result = results[share.recordID] else { throw SyncTransportError.unavailable(retryAfter: nil) }
        switch result {
        case .success(let record):
            guard let saved = record as? CKShare else { throw SyncTransportError.unreadableRecord(share.recordID.recordName) }
            return saved
        case .failure(let error as CKError) where error.code == .serverRecordChanged:
            throw error
        case .failure(let error):
            throw CloudKitRecordMapping.operationError(error, zone: zone)
        }
    }

    private static func recordName(of participant: CKShare.Participant, currentUser: String) -> String? {
        guard let name = participant.userIdentity.userRecordID?.recordName else { return nil }
        return name == CKCurrentUserDefaultName ? currentUser : name
    }

    /// The share as the protocol's: everyone but the owner who hasn't been removed and has a known record name.
    private static func syncShare(_ share: CKShare, zone: String, currentUser: String) -> SyncZoneShare {
        let owner = recordName(of: share.owner, currentUser: currentUser) ?? currentUser
        let participants = share.participants.compactMap { participant -> SyncShareParticipant? in
            guard participant.role != .owner, participant.acceptanceStatus != .removed,
                  let name = recordName(of: participant, currentUser: currentUser) else { return nil }
            return SyncShareParticipant(userRecordName: name, status: participant.acceptanceStatus == .accepted ? .accepted : .invited,
                                        canWrite: participant.permission == .readWrite)
        }
        return SyncZoneShare(zone: zone, url: share.url, ownerRecordName: owner, participants: participants)
    }
}
