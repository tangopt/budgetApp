import Foundation
import GRDB

public enum SyncImportGateError: Error, Equatable, Sendable {
    /// Sync is on and this device doesn't hold the import lease.
    case leaseRequired

    public var message: String { "Confirming needs a moment online to take the import lease: try again when connected" }
}

/// The lease this device holds, as BudgetCore checks it at Confirm and Undo. `used`: a batch was confirmed
/// under it, so it is renewed while that batch uploads and released once the batch's close is uploaded.
public struct HeldImportLease: Codable, Equatable, Sendable {
    public var record: ImportLeaseRecord
    public var tag: String
    public var used: Bool

    public init(record: ImportLeaseRecord, tag: String, used: Bool = false) {
        self.record = record
        self.tag = tag
        self.used = used
    }
}

/// One import (or Undo) confirmed at a time per household (sync spec §5.2), enforced in BudgetCore: once
/// this device takes part in sync, `ImportApplier` and `ImportUndo` refuse without a lease it holds.
public enum SyncImportGate {
    static let syncOnKey = "syncOn"
    static let leaseKey = "importLease"

    public static func isSyncOn(db: Database) throws -> Bool {
        guard try db.tableExists("syncState") else { return false }
        return try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [syncOnKey]) == Data([1])
    }

    public static func setSyncOn(_ on: Bool, db: Database, now: Date = Date()) throws {
        guard try isSyncOn(db: db) != on else { return }
        try setState(Data([on ? 1 : 0]), key: syncOnKey, db: db, now: now)
    }

    public static func heldLease(db: Database) throws -> HeldImportLease? {
        guard try db.tableExists("syncState"),
              let data = try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [leaseKey]) else { return nil }
        return try? JSONDecoder().decode(HeldImportLease.self, from: data)
    }

    static func setHeldLease(_ lease: HeldImportLease?, db: Database, now: Date) throws {
        if let lease {
            try setState(try JSONEncoder().encode(lease), key: leaseKey, db: db, now: now)
        } else {
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [leaseKey])
        }
    }

    /// Throws `leaseRequired` when sync is on and this device holds no unexpired lease.
    public static func check(db: Database, now: Date = Date()) throws {
        guard try isSyncOn(db: db) else { return }
        guard let held = try heldLease(db: db), held.record.expiresAt > now else { throw SyncImportGateError.leaseRequired }
    }

    /// `check`, inside the transaction that confirms (or undoes): the lease is then marked used.
    public static func require(db: Database, now: Date = Date()) throws {
        try check(db: db, now: now)
        guard var held = try heldLease(db: db), !held.used else { return }
        held.used = true
        try setHeldLease(held, db: db, now: now)
    }

    static func setState(_ value: Data, key: String, db: Database, now: Date) throws {
        try db.execute(sql: """
            INSERT INTO syncState(key, value, updatedAt) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
            """, arguments: [key, value, now])
    }
}
