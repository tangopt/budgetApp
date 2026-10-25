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

    /// Where records belong at the moment they are saved (`judge(with:)`), and what was wrong with every household
    /// save so judged: append-only, so a household copy that is later overwritten or deleted still counts.
    private let judge = OSAllocatedUnfairLock<(@Sendable (String) -> ZoneAssignment?)?>(initialState: nil)
    private let findings = OSAllocatedUnfairLock(initialState: [String]())

    /// `keyStore`: holds the household key (to open what went there).
    public init(wrapping inner: any SyncTransport, keyStore: any SyncKeyStore) {
        self.inner = inner
        self.keyStore = keyStore
    }

    /// Every record a save carried, by zone, in the order they were sent (refused ones too).
    public var savesByZone: [String: [SyncWireRecord]] { saves.withLock { $0 } }

    /// From now on, every household save is judged as it is made against `placement` (record UUID to where it belongs
    /// now; nil: unknown, not judged); what is wrong is kept for `householdViolations`.
    public func judge(with placement: @escaping @Sendable (String) -> ZoneAssignment?) {
        judge.withLock { $0 = placement }
    }

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
    ///
    /// Also every finding made as a household save happened (`judge(with:)`): a save of a record placed privately at
    /// that moment (not a marker), carrying a field its placement leaves out or naming a private run, or a document
    /// file of a private record.
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
        var all = self.findings.withLock { $0 }
        for finding in findings where !all.contains(finding) { all.append(finding) }
        return all
    }

    /// What is wrong with one household save, judged by where its record belongs now.
    private func judged(_ wire: SyncWireRecord, placement: (String) -> ZoneAssignment?) -> [String] {
        switch wire.recordType {
        case TransportLeaseStore.recordType, SyncZoneKeys.recordType:
            return []
        case SyncDocumentFile.recordType:
            let owner = wire.recordName.components(separatedBy: ".file.").first ?? wire.recordName
            if let placed = placement(owner), placed.isPrivate { return ["documentFile \(wire.recordName): saved to household as the file of a private record"] }
            return []
        default:
            break
        }
        let keys = (try? keyStore.allKeys(zone: SyncZones.household)) ?? [:]
        guard let payload = try? SyncLargePayload.payload(from: wire, keys: keys) else {
            return ["\(wire.recordType) \(wire.recordName): saved to household, doesn't open with the household key"]
        }
        guard payload.movedTo == nil, payload.mergedInto == nil else { return [] }
        if payload.recordType == SyncZoneRouter.companionRecordType {
            return ["\(payload.recordType) \(payload.recordName): a companion saved to household"]
        }
        guard let placed = placement(payload.recordName) else { return [] }
        var problems: [String] = []
        if placed.isPrivate { problems.append("\(payload.recordType) \(payload.recordName): saved to household while placed privately") }
        for field in placed.omittedFields where payload.fields[field] != nil {
            problems.append("\(payload.recordType) \(payload.recordName): saved to household carrying \(field), which it leaves out")
        }
        if let run = payload.importRunUuid, let runPlacement = placement(run), runPlacement.isPrivate {
            problems.append("\(payload.recordType) \(payload.recordName): saved to household tagged with a private run")
        }
        return problems
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
        if let placement = judge.withLock({ $0 }) {
            let found = records.filter { $0.zone == SyncZones.household }.flatMap { judged($0, placement: placement) }
            if !found.isEmpty { findings.withLock { $0 += found } }
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
