import Foundation
import os
import BudgetCore

/// A transport for tests that can lose the reply of a save (the server keeps what it took, the caller gets
/// `networkUnavailable`, as after a crash or a dropped connection) or fail the saves of one record in one zone.
public final class LossyTransport: SyncTransport, Sendable {
    private struct State {
        var loseReply: (name: String, zone: String)?
        var fail: (name: String, zone: String)?
        var loseDeleteReply: String?
    }

    private let inner: any SyncTransport
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(_ inner: any SyncTransport) {
        self.inner = inner
    }

    /// The next save operation carrying `name` in `zone` is taken by the server, but its reply is lost.
    public func loseReply(to name: String, in zone: String) { state.withLock { $0.loseReply = (name, zone) } }

    /// Every save of `name` in `zone` fails (a passing failure) until `restore()`.
    public func failSaves(of name: String, in zone: String) { state.withLock { $0.fail = (name, zone) } }

    /// The next delete in `zone` is taken by the server, but its reply is lost.
    public func loseDeleteReply(in zone: String) { state.withLock { $0.loseDeleteReply = zone } }

    public func restore() { state.withLock { $0 = State() } }

    public func operationLimits() async -> SyncOperationLimits { await inner.operationLimits() }
    public func createZone(_ zone: String) async throws { try await inner.createZone(zone) }

    public func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        let now = state.withLock { $0 }
        if let fail = now.fail, records.contains(where: { $0.recordName == fail.name && $0.zone == fail.zone }) {
            let rest = records.filter { !($0.recordName == fail.name && $0.zone == fail.zone) }
            var results = rest.isEmpty ? [] : try await inner.save(rest, ifUnchanged: ifUnchanged, atomic: atomic)
            results.append(SaveResult(recordName: fail.name, outcome: .failed("test")))
            return results
        }
        let results = try await inner.save(records, ifUnchanged: ifUnchanged, atomic: atomic)
        if let lose = now.loseReply, records.contains(where: { $0.recordName == lose.name && $0.zone == lose.zone }) {
            state.withLock { $0.loseReply = nil }
            throw SyncTransportError.networkUnavailable
        }
        return results
    }

    public func changes(since token: Data?, zone: String) async throws -> SyncChanges { try await inner.changes(since: token, zone: zone) }
    public func delete(_ recordNames: [String], zone: String) async throws {
        try await inner.delete(recordNames, zone: zone)
        let lost = state.withLock { state -> Bool in
            guard !recordNames.isEmpty, state.loseDeleteReply == zone else { return false }
            state.loseDeleteReply = nil
            return true
        }
        if lost { throw SyncTransportError.networkUnavailable }
    }
    public func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? { try await inner.fetch(recordName, zone: zone) }
    public func serverTime() async throws -> Date? { try await inner.serverTime() }
}

/// Sharing calls go to the wrapped transport (step 7a).
extension LossyTransport: SyncShareTransport {
    private var sharing: any SyncShareTransport {
        get throws {
            guard let sharing = inner as? any SyncShareTransport else { throw SyncShareNotSupported() }
            return sharing
        }
    }

    public func currentUserRecordName() async throws -> String { try await sharing.currentUserRecordName() }
    public func zoneShare(_ zone: String) async throws -> SyncZoneShare? { try await sharing.zoneShare(zone) }
    public func makeZoneShare(_ zone: String, title: String) async throws -> SyncZoneShare {
        try await sharing.makeZoneShare(zone, title: title)
    }
    public func removeParticipant(userRecordName: String, zone: String) async throws {
        try await sharing.removeParticipant(userRecordName: userRecordName, zone: zone)
    }
    public func removeAllParticipants(zone: String) async throws -> [String] {
        try await sharing.removeAllParticipants(zone: zone)
    }
}
