import Foundation

/// A member device's transport: the `household` zone goes to `household` (the admin's zone, through her shared
/// database), every other zone to `others` (her own private database). Routed by zone name.
public struct SyncZoneSplitTransport: SyncTransport {
    private let household: any SyncTransport
    private let others: any SyncTransport

    public init(household: any SyncTransport, others: any SyncTransport) {
        self.household = household
        self.others = others
    }

    private func side(_ zone: String) -> any SyncTransport {
        zone == SyncZones.household ? household : others
    }

    /// The smaller of the two sides' limits, so one batch fits either.
    public func operationLimits() async -> SyncOperationLimits {
        let first = await household.operationLimits()
        let second = await others.operationLimits()
        return SyncOperationLimits(maxRecords: min(first.maxRecords, second.maxRecords), maxBytes: min(first.maxBytes, second.maxBytes))
    }

    /// Her own zones are made in her private database. `household` is the admin's, reached through her shared
    /// database where no zone can be made: nothing is done (a household she can't reach shows as `zoneNotFound`).
    public func createZone(_ zone: String) async throws {
        guard zone != SyncZones.household else { return }
        try await others.createZone(zone)
    }

    /// A save naming both sides is split into one per side (each keeps `atomic` within itself); results come back in
    /// the order of `records`.
    public func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        let toHousehold = records.filter { $0.zone == SyncZones.household }
        let toOthers = records.filter { $0.zone != SyncZones.household }
        var results: [SaveResult] = []
        if !toHousehold.isEmpty { results += try await household.save(toHousehold, ifUnchanged: ifUnchanged, atomic: atomic) }
        if !toOthers.isEmpty { results += try await others.save(toOthers, ifUnchanged: ifUnchanged, atomic: atomic) }
        guard !toHousehold.isEmpty, !toOthers.isEmpty else { return results }
        var byName: [String: [SaveResult]] = Dictionary(grouping: results, by: \.recordName)
        return records.compactMap { record in
            guard var queue = byName[record.recordName], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            byName[record.recordName] = queue
            return first
        }
    }

    public func changes(since token: Data?, zone: String) async throws -> SyncChanges {
        try await side(zone).changes(since: token, zone: zone)
    }

    public func delete(_ recordNames: [String], zone: String) async throws { try await side(zone).delete(recordNames, zone: zone) }

    public func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? {
        try await side(zone).fetch(recordName, zone: zone)
    }

    /// The private database's clock (the member's own server time).
    public func serverTime() async throws -> Date? { try await others.serverTime() }
}
