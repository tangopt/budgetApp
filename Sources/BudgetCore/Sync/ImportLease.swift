import Foundation

/// A device taking part in sync: a stable id (one per install) and the name other devices show
/// ("Importing on <name>").
public struct SyncDevice: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The household's one `importLease` record (sync spec §5.2): who may confirm an import or an Undo now.
public struct ImportLeaseRecord: Codable, Equatable, Sendable {
    public var holderId: String
    public var holderName: String
    public var takenAt: Date
    public var expiresAt: Date

    public init(holderId: String, holderName: String, takenAt: Date, expiresAt: Date) {
        self.holderId = holderId
        self.holderName = holderName
        self.takenAt = takenAt
        self.expiresAt = expiresAt
    }
}

/// The lease record as the store holds it, with its change tag (CloudKit's record change tag).
public struct StoredLease: Equatable, Sendable {
    public var record: ImportLeaseRecord
    public var tag: String

    public init(record: ImportLeaseRecord, tag: String) {
        self.record = record
        self.tag = tag
    }
}

public enum LeaseStoreError: Error, Equatable {
    /// A compare-and-set failed: the record isn't the one the write was made against.
    case changed
}

/// Where the lease lives: one record, written only by compare-and-set (`.ifServerRecordUnchanged`,
/// outside the sync engine). Task 5 adapts `SyncTransport` to it; `InMemoryLeaseStore` is for tests.
public protocol LeaseStore: Sendable {
    /// The lease record and its tag, or nil when there is none.
    func currentLease() async throws -> StoredLease?
    /// Writes `record` only if the stored one still has `tag` (nil: only if there is none), returning it
    /// with its new tag; otherwise throws `LeaseStoreError.changed`.
    func saveLease(_ record: ImportLeaseRecord, ifTag tag: String?) async throws -> StoredLease
    /// Removes the record only if it still has `tag`; otherwise throws `LeaseStoreError.changed`.
    func deleteLease(ifTag tag: String) async throws
}

/// A lease store in memory, with change tags, for tests and the in-memory cloud.
public actor InMemoryLeaseStore: LeaseStore {
    private var stored: StoredLease?
    private var counter = 0

    public init() {}

    public func currentLease() async throws -> StoredLease? { stored }

    public func saveLease(_ record: ImportLeaseRecord, ifTag tag: String?) async throws -> StoredLease {
        guard stored?.tag == tag else { throw LeaseStoreError.changed }
        counter += 1
        let saved = StoredLease(record: record, tag: "lease-tag-\(counter)")
        stored = saved
        return saved
    }

    public func deleteLease(ifTag tag: String) async throws {
        guard stored?.tag == tag else { throw LeaseStoreError.changed }
        stored = nil
    }
}

public enum ImportLeaseError: Error, Equatable, Sendable {
    /// Another device holds an unexpired lease.
    case heldBy(deviceName: String, until: Date)
    /// The lease expired and another device took it (or it was removed): stop the batch's upload.
    case lost

    public var message: String {
        switch self {
        case .heldBy(let name, _): return "Importing on \(name)"
        case .lost: return "Another device took over importing"
        }
    }
}

/// One import (or Undo) confirmed at a time per household (sync spec §5.2). The confirming device takes
/// the lease at Confirm and holds it until the batch is fully uploaded, renewing it on the way; it
/// expires 30 minutes after it was last taken or renewed. Reading and review need no lease.
public enum ImportLease {
    public static let duration: TimeInterval = 30 * 60

    /// A lease this device holds.
    public struct Lease: Equatable, Sendable {
        public var record: ImportLeaseRecord
        public var tag: String
    }

    /// Takes the lease, or throws `heldBy` while another device holds an unexpired one. The holder may
    /// take it again (after a relaunch). A write that loses a race is re-decided against what won.
    public static func acquire(device: SyncDevice, now: Date, transport: any LeaseStore) async throws -> Lease {
        for _ in 0..<4 {
            let current = try await transport.currentLease()
            if let held = current?.record, held.holderId != device.id, held.expiresAt > now {
                throw ImportLeaseError.heldBy(deviceName: held.holderName, until: held.expiresAt)
            }
            let record = ImportLeaseRecord(holderId: device.id, holderName: device.name, takenAt: now, expiresAt: now.addingTimeInterval(duration))
            do {
                let saved = try await transport.saveLease(record, ifTag: current?.tag)
                return Lease(record: saved.record, tag: saved.tag)
            } catch LeaseStoreError.changed {
                continue
            }
        }
        // Still changing under us: whoever is writing it holds it.
        if let held = try await transport.currentLease()?.record {
            throw ImportLeaseError.heldBy(deviceName: held.holderName, until: held.expiresAt)
        }
        throw ImportLeaseError.lost
    }

    /// Extends the lease to 30 minutes from `now`, or throws `lost` when it isn't this lease any more.
    public static func renew(_ lease: Lease, now: Date, transport: any LeaseStore) async throws -> Lease {
        var record = lease.record
        record.expiresAt = now.addingTimeInterval(duration)
        do {
            let saved = try await transport.saveLease(record, ifTag: lease.tag)
            return Lease(record: saved.record, tag: saved.tag)
        } catch LeaseStoreError.changed {
            throw ImportLeaseError.lost
        }
    }

    /// Gives the lease up. A lease another device took since is left alone.
    public static func release(_ lease: Lease, transport: any LeaseStore) async throws {
        do {
            try await transport.deleteLease(ifTag: lease.tag)
        } catch LeaseStoreError.changed {
            return
        }
    }

    /// Who holds the lease now (for "Importing on <device>"), or nil when nobody does.
    public static func holder(now: Date, transport: any LeaseStore) async throws -> ImportLeaseRecord? {
        guard let record = try await transport.currentLease()?.record, record.expiresAt > now else { return nil }
        return record
    }
}
