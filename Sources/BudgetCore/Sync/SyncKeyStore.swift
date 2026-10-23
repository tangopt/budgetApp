import CryptoKit
import Foundation
import os

/// Where a zone's keys live (ruling R15, sync spec §9.1): never in CloudKit. The Mac and iOS apps keep them in
/// iCloud Keychain (`KeychainSyncKeyStore`, App target), so every device of the household's Apple Account
/// receives them end to end; tests use `InMemorySyncKeyStore`. Keys are kept by id (`DocumentCrypto.zoneKeyId`),
/// so a record or data key sealed under a retired key still opens. Which key is current is the zone's `zoneKey`
/// marker record's business; `key(zone:)` is only the newest one stored here (used to publish a marker again
/// after a zone reset). Per zone, so a shared zone can later receive its own key (steps 5–6).
public protocol SyncKeyStore: Sendable {
    /// The newest key stored for `zone`, or nil when this device holds none.
    func key(zone: String) throws -> SymmetricKey?
    /// Keeps `key` for `zone` under its id; a key already held changes nothing.
    func store(_ key: SymmetricKey, zone: String) throws
    /// Every key held for `zone` (current and retired), by id.
    func allKeys(zone: String) throws -> [String: SymmetricKey]
}

public enum SyncKeyError: Error, Equatable, Sendable {
    /// The zone's marker names a key this device doesn't hold yet (another device made it; iCloud Keychain hasn't
    /// delivered it): nothing is sealed or created here meanwhile.
    case waitingForHouseholdKey
    /// The zone's key marker couldn't be read or published now (offline, busy, or the server's marker is
    /// unreadable): tried again later; never replaced from here.
    case unavailable
}

/// A key store in memory: tests, the rehearsal tool. Two simulated devices share one to model iCloud Keychain.
public final class InMemorySyncKeyStore: SyncKeyStore, Sendable {
    private struct Held {
        var order: [String] = []
        var keys: [String: SymmetricKey] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: [String: Held]())

    public init() {}

    public func key(zone: String) throws -> SymmetricKey? {
        state.withLock { held in held[zone].flatMap { zone in zone.order.last.flatMap { zone.keys[$0] } } }
    }

    public func store(_ key: SymmetricKey, zone: String) throws {
        let id = DocumentCrypto.zoneKeyId(key)
        state.withLock { held in
            var keys = held[zone] ?? Held()
            guard keys.keys[id] == nil else { return }
            keys.order.append(id)
            keys.keys[id] = key
            held[zone] = keys
        }
    }

    public func allKeys(zone: String) throws -> [String: SymmetricKey] {
        state.withLock { $0[zone]?.keys ?? [:] }
    }
}
