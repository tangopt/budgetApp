import CloudKit
import Foundation
import BudgetCore

/// A member device accepting the household's zone share (step 7a). The share is the admin's `household` zone; accepting
/// makes the zone appear in this device's shared database. Compile-checked only: the real accept is the controller's
/// side-by-side run.
public enum CloudKitShareAcceptance {
    public struct Invitation: Equatable, Sendable {
        /// The household owner's iCloud user record name: the zone's owner in this device's shared database.
        public let ownerRecordName: String
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// Another container, another zone, or no owner: not the household invitation.
        case notTheHousehold
    }

    /// The household invitation in `metadata`, or why it isn't one. Only this app's container and the `household` zone.
    public static func invitation(_ metadata: CKShare.Metadata) throws -> Invitation {
        guard metadata.containerIdentifier == CloudKitTransport.containerIdentifier,
              metadata.share.recordID.zoneID.zoneName == SyncZones.household,
              case let zoneOwner = metadata.share.recordID.zoneID.ownerName,
              case let owner = zoneOwner == CKCurrentUserDefaultName ? (metadata.ownerIdentity.userRecordID?.recordName ?? "") : zoneOwner,
              !owner.isEmpty, owner != CKCurrentUserDefaultName else { throw Refusal.notTheHousehold }
        // The zone's owner name is what the shared database addresses it by; the owner identity is the fallback.
        return Invitation(ownerRecordName: owner)
    }

    /// Accepts the share in iCloud (`CKAcceptSharesOperation` under the async API).
    public static func accept(_ metadata: CKShare.Metadata) async throws {
        let container = CKContainer(identifier: CloudKitTransport.containerIdentifier)
        _ = try await container.accept(metadata)
    }
}
