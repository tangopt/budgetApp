import Foundation
import os

/// A transport that records every save it passes on, by zone, and can open what went to `household` with a key
/// store (tests: `TwoPersonHousehold`). It lets a test assert, over every save of the test, that nothing placed
/// privately ever reached the household zone (sharing spec 2026-10-25 §5, anti-goal 1).
public final class ZoneAuditingTransport: SyncTransport, Sendable {
    private let inner: any SyncTransport
    private let keyStore: any SyncKeyStore
    private let saves = OSAllocatedUnfairLock(initialState: [String: [SyncWireRecord]]())
    /// Every save and delete, by zone, in order: a save as its record, a delete as its record name.
    private let events = OSAllocatedUnfairLock(initialState: [String: [Event]]())

    private enum Event {
        case saved(SyncWireRecord)
        case deleted(String)
    }

    /// `keyStore`: holds the household key (to open what went there).
    public init(wrapping inner: any SyncTransport, keyStore: any SyncKeyStore) {
        self.inner = inner
        self.keyStore = keyStore
    }

    /// Every record a save carried, by zone, in the order they were sent (refused ones too).
    public var savesByZone: [String: [SyncWireRecord]] { saves.withLock { $0 } }

    /// Every record name a delete named, by zone, in order.
    public var deletesByZone: [String: [String]] {
        events.withLock { events in
            events.mapValues { $0.compactMap { if case .deleted(let name) = $0 { return name } else { return nil } } }
        }
    }

    /// What is wrong with the household's saves, one line per finding (empty: nothing). Every household save must
    /// open with the household key and be a record type that syncs (never an `accountDetails` companion); a move
    /// marker carries nothing but where the record went; a document file must not be a private record's. For each
    /// record still on the household after its latest save (not deleted since), that save must not be one `router`
    /// (record UUID to its placement now; nil: unknown, not judged) places privately, unless it is a marker (the
    /// record left), nor carry a field the placement leaves out, nor name a private run; a document file still
    /// there must not be a private record's.
    public func householdViolations(router: (String) -> ZoneAssignment?) -> [String] {
        let history = events.withLock { $0[SyncZones.household] ?? [] }
        var standing: [String: SyncWireRecord] = [:]
        for event in history {
            switch event {
            case .saved(let wire): standing[wire.recordName] = wire
            case .deleted(let name): standing[name] = nil
            }
        }
        let household = savesByZone[SyncZones.household] ?? []
        let keys = (try? keyStore.allKeys(zone: SyncZones.household)) ?? [:]
        var findings: [String] = []
        var latest: [String: SyncPayload] = [:]
        var order: [String] = []
        for wire in household {
            switch wire.recordType {
            case TransportLeaseStore.recordType, SyncZoneKeys.recordType:
                continue
            case SyncDocumentFile.recordType:
                let owner = wire.recordName.components(separatedBy: ".file.").first ?? wire.recordName
                if standing[wire.recordName] != nil, let placement = router(owner), placement.isPrivate {
                    findings.append("documentFile \(wire.recordName): the file of a private record")
                }
                continue
            default:
                break
            }
            guard let payload = try? SyncLargePayload.payload(from: wire, keys: keys) else {
                findings.append("\(wire.recordType) \(wire.recordName): doesn't open with the household key")
                continue
            }
            if payload.recordType == SyncZoneRouter.companionRecordType || SyncSchema.table(payload.recordType) == nil {
                findings.append("\(payload.recordType) \(payload.recordName): not a household record type")
                continue
            }
            if payload.movedTo != nil, !payload.fields.isEmpty || payload.importRunUuid != nil {
                findings.append("\(payload.recordType) \(payload.recordName): a marker carrying fields")
            }
            if latest[payload.recordName] == nil { order.append(payload.recordName) }
            latest[payload.recordName] = payload
        }
        for name in order {
            guard standing[name] != nil, let payload = latest[name], payload.movedTo == nil, payload.mergedInto == nil,
                  let placement = router(name) else { continue }
            if placement.isPrivate {
                findings.append("\(payload.recordType) \(name): placed in a private zone, last saved in household")
                continue
            }
            for field in placement.omittedFields where payload.fields[field] != nil {
                findings.append("\(payload.recordType) \(name): carries \(field), which it leaves out")
            }
            if let run = payload.importRunUuid, let runPlacement = router(run), runPlacement.isPrivate {
                findings.append("\(payload.recordType) \(name): tagged with a private run")
            }
        }
        return findings
    }

    // MARK: SyncTransport

    public func operationLimits() async -> SyncOperationLimits { await inner.operationLimits() }

    public func createZone(_ zone: String) async throws { try await inner.createZone(zone) }

    public func save(_ records: [SyncWireRecord], ifUnchanged: [String: Data], atomic: Bool) async throws -> [SaveResult] {
        saves.withLock { saves in
            for record in records { saves[record.zone, default: []].append(record) }
        }
        events.withLock { events in
            for record in records { events[record.zone, default: []].append(.saved(record)) }
        }
        return try await inner.save(records, ifUnchanged: ifUnchanged, atomic: atomic)
    }

    public func changes(since token: Data?, zone: String) async throws -> SyncChanges { try await inner.changes(since: token, zone: zone) }

    public func delete(_ recordNames: [String], zone: String) async throws {
        try await inner.delete(recordNames, zone: zone)
        events.withLock { events in
            for name in recordNames { events[zone, default: []].append(.deleted(name)) }
        }
    }

    public func fetch(_ recordName: String, zone: String) async throws -> SyncServerRecord? { try await inner.fetch(recordName, zone: zone) }

    public func serverTime() async throws -> Date? { try await inner.serverTime() }
}
