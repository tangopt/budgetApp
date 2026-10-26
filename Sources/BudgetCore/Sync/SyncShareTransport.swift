import Foundation

/// Someone a zone is shared with, as the zone's share lists them (CloudKit: a `CKShare.Participant` other than the
/// owner).
public struct SyncShareParticipant: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Added to the share, not accepted yet: the zone is not reachable for them.
        case invited
        /// Accepted: the zone is in their shared database.
        case accepted
    }

    /// The participant's iCloud user record name.
    public var userRecordName: String
    public var status: Status
    public var canWrite: Bool

    public init(userRecordName: String, status: Status, canWrite: Bool) {
        self.userRecordName = userRecordName
        self.status = status
        self.canWrite = canWrite
    }
}

/// A zone-wide share (CloudKit: `CKShare(recordZoneID:)`): its link, its owner, and who else it lists.
public struct SyncZoneShare: Equatable, Sendable {
    public var zone: String
    public var url: URL?
    /// The owner's iCloud user record name.
    public var ownerRecordName: String
    /// Everyone but the owner.
    public var participants: [SyncShareParticipant]

    public init(zone: String, url: URL?, ownerRecordName: String, participants: [SyncShareParticipant]) {
        self.zone = zone
        self.url = url
        self.ownerRecordName = ownerRecordName
        self.participants = participants
    }
}

/// Sharing a zone with another iCloud user, beside `SyncTransport`: `FakeCloud` (per-user sessions) in tests,
/// `CloudKitTransport` over CloudKit. Accepting a share is the system's (the share sheet and the link), not this.
public protocol SyncShareTransport: Sendable {
    /// The iCloud user record name this transport acts as.
    func currentUserRecordName() async throws -> String
    /// The zone's share, or nil when it has none.
    func zoneShare(_ zone: String) async throws -> SyncZoneShare?
    /// Shares the zone (owner only, no public access): returns the existing share when there is one.
    func makeZoneShare(_ zone: String, title: String) async throws -> SyncZoneShare
    /// Takes the participant off the zone's share: the zone stops being reachable for them.
    func removeParticipant(userRecordName: String, zone: String) async throws
}

/// A wrapping transport (`ZoneAuditingTransport`, a test's lossy one) was asked to share, but what it wraps can't.
public struct SyncShareNotSupported: Error, Equatable {
    public init() {}
}
