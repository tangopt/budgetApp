import Foundation

/// A record of the container's public database, as `SyncPublicBoard` carries it. The public database has no
/// encrypted fields, so `fields` are plain: only values that aren't secret ever go here (the key exchange's request:
/// a request id, a commitment, a public key and a nonce).
public struct SyncPublicRecord: Equatable, Sendable {
    public var recordType: String
    public var recordName: String
    public var fields: [String: Data]
    /// The iCloud user record name the server says wrote this version (`lastModifiedUserRecordID`); ignored on a post.
    public var lastModifiedBy: String?
    /// The server's time of this version; ignored on a post.
    public var modifiedAt: Date?

    public init(recordType: String, recordName: String, fields: [String: Data], lastModifiedBy: String? = nil, modifiedAt: Date? = nil) {
        self.recordType = recordType
        self.recordName = recordName
        self.fields = fields
        self.lastModifiedBy = lastModifiedBy
        self.modifiedAt = modifiedAt
    }
}

/// The container's public database (step 7a Task 8), for the one write a read-only member makes: her device's key
/// request (`SyncKeyExchange`). CloudKit's default security roles hold: any signed-in user creates, everyone reads,
/// only a record's creator changes or deletes it. `FakeCloud` models it in tests; `CloudKitPublicBoard` (`MangoSync`)
/// over `CKContainer.publicCloudDatabase`.
public protocol SyncPublicBoard: Sendable {
    /// Creates the record, or replaces it when the current user created it; anyone else's: a permission failure.
    func postPublic(_ record: SyncPublicRecord) async throws
    /// The record, with the server's writer and time, or nil when there is none by that name.
    func fetchPublic(_ recordName: String) async throws -> SyncPublicRecord?
    /// Deletes the record (its creator only); one already gone is fine.
    func deletePublic(_ recordName: String) async throws
}
