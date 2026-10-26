import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 6 Task 13: `--sync-demo --seed-schema`'s placeholders (`SyncSchemaSeed`): one record of every type the engine
/// can save, each shaped exactly as the engine sends it (R15), so the Development schema deployed to Production has
/// every record type and field the first real upload needs. FakeCloud only.
final class SyncSchemaSeedTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncSchemaSeedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Every record type (and every field of it) the engine sends from the demo, the household and the admin's private
    /// zone, documents with their files, is in the seed; each seed record has exactly the shape of its type.
    func testSchemaSeedCoversEveryRecordType() async throws {
        let keys = InMemorySyncKeyStore()
        let seed = try SyncSchemaSeed.records(keys: keys)

        // What the engine actually sends: the demo's first upload from the admin's Mac.
        let evidence = folder.appendingPathComponent("Evidence", isDirectory: true)
        let manager = try TestDatabase.demoManager(path: folder.appendingPathComponent("demo.sqlite").path, evidenceRoot: evidence)
        let queue = manager.dbQueue
        let cloud = FakeCloud()
        let engineKeys = InMemorySyncKeyStore()
        let role = try await queue.read { db in try SyncTurnOn.macEngineRole(signedIn: try AccessActor.admin(db: db), db: db) }
        let engine = SyncEngineCore(db: queue, transport: ZoneAuditingTransport(wrapping: cloud, keyStore: engineKeys),
                                    device: SyncDevice(id: "admin-mac", name: "Mac"), keyStore: engineKeys,
                                    documents: SyncDocumentFiles(root: evidence, policy: .eager),
                                    viewer: role.viewer, revalidatesAccess: role.revalidatesAccess)
        _ = try await engine.syncNow()
        let sent = await cloud.storedRecords()
        XCTAssertGreaterThan(sent.count, 1_000)
        let sentTypes = Set(sent.map(\.recordType))
        XCTAssertTrue(sentTypes.isSuperset(of: [SyncZoneRouter.companionRecordType, SyncZoneKeys.recordType, SyncDocumentFile.recordType]),
                      "the demo upload sends companions, markers and files: \(sentTypes.sorted())")
        XCTAssertGreaterThan(Set(sent.map(\.zone)).count, 1, "the demo upload uses the household and a private zone")

        let seedTypes = seed.map(\.recordType)
        XCTAssertEqual(seedTypes.count, Set(seedTypes).count, "one record per type")
        XCTAssertEqual(Set(seed.map(\.recordName)).count, seed.count)
        XCTAssertTrue(Set(seedTypes).isSuperset(of: sentTypes), "missing: \(sentTypes.subtracting(seedTypes).sorted())")
        XCTAssertEqual(Set(seedTypes), Set(SyncSchema.tables.map(\.name)).union([
            SyncZoneRouter.companionRecordType, SyncZoneKeys.recordType, SyncDocumentFile.recordType, TransportLeaseStore.recordType,
        ]))
        XCTAssertEqual(Set(seedTypes), Set(SyncSchemaSeed.recordTypes))

        // Every field name and asset name the engine sent for a type, the seed's record of that type has too.
        let seedByType = Dictionary(uniqueKeysWithValues: seed.map { ($0.recordType, $0) })
        for wire in sent {
            guard let placeholder = seedByType[wire.recordType] else { continue }
            XCTAssertTrue(Set(placeholder.encryptedFields.keys).isSuperset(of: wire.encryptedFields.keys), wire.recordType)
            XCTAssertTrue(Set(placeholder.assets.keys).isSuperset(of: wire.assets.keys), wire.recordType)
        }

        // Each placeholder: exactly the marker, exactly the file, or exactly sealed + keyId (with the packed payload),
        // in the scratch zone, opening with the seed's key, holding no fields.
        let held = try keys.allKeys(zone: SyncSchemaSeed.zone)
        XCTAssertEqual(held.count, 1)
        for wire in seed {
            XCTAssertEqual(wire.zone, SyncSchemaSeed.zone)
            XCTAssertTrue(wire.unencryptedFields.isEmpty)
            switch wire.recordType {
            case SyncZoneKeys.recordType:
                XCTAssertEqual(try SyncZoneKeys.marker(from: wire).keyId, held.keys.first)
            case SyncDocumentFile.recordType:
                XCTAssertTrue(wire.encryptedFields.isEmpty)
                XCTAssertEqual(Set(wire.assets.keys), [SyncDocumentFile.assetField])
            default:
                XCTAssertEqual(Set(wire.encryptedFields.keys), [FieldSealing.sealedField, FieldSealing.keyIdField], wire.recordType)
                XCTAssertEqual(Set(wire.assets.keys), [SyncLargePayload.assetField], wire.recordType)
                let payload = try SyncLargePayload.payload(from: wire, keys: held)
                XCTAssertEqual(payload.recordType, wire.recordType)
                XCTAssertTrue(payload.fields.isEmpty, "a placeholder holds no data")
            }
        }
        XCTAssertEqual(try SyncRehearsal.sealingFindings(in: seed, keys: keys), [])
        // A second build reuses the key it was given.
        _ = try SyncSchemaSeed.records(keys: keys)
        XCTAssertEqual(try keys.allKeys(zone: SyncSchemaSeed.zone).count, 1)
    }

    /// The run makes the scratch zone, saves every placeholder there and deletes the zone again: nothing stays, and no
    /// other zone is touched.
    func testSeedRunSavesEveryTypeThenDeletesTheZone() async throws {
        let cloud = FakeCloud()
        let before = Box()
        let saved = try await SyncSchemaSeed.run(transport: cloud, keys: InMemorySyncKeyStore(), deleteZone: { zone in
            before.set(await cloud.storedRecords())
            await cloud.deleteZone(zone)
        })
        XCTAssertEqual(saved, SyncSchemaSeed.recordTypes.count)
        // Saved, every type once, all in the scratch zone; then the zone went with them.
        XCTAssertEqual(Set(before.records.map(\.recordType)), Set(SyncSchemaSeed.recordTypes))
        XCTAssertEqual(Set(before.records.map(\.zone)), [SyncSchemaSeed.zone])
        let stored = await cloud.storedRecords()
        XCTAssertEqual(stored.count, 0, "the zone is deleted with its records")
        let calls = await cloud.calls
        XCTAssertEqual(calls.first, .createZone(SyncSchemaSeed.zone))
        XCTAssertEqual(calls.filter { if case .createZone = $0 { true } else { false } }.count, 1, "no other zone is made")
    }

    /// A refused save names the types, still deletes the zone.
    func testARefusedSeedNamesTheTypesAndStillDeletesTheZone() async throws {
        let cloud = FakeCloud()
        await cloud.failSaves(of: ["schema-seed-" + SyncZoneRouter.companionRecordType], times: 1)
        let deleted = Box()
        do {
            try await SyncSchemaSeed.run(transport: cloud, keys: InMemorySyncKeyStore(), deleteZone: { zone in
                await cloud.deleteZone(zone)
                deleted.set([])
            })
            XCTFail("expected a refusal")
        } catch let error as SyncSchemaSeed.SeedError {
            XCTAssertEqual(error, .notSaved([SyncZoneRouter.companionRecordType]))
        }
        XCTAssertTrue(deleted.called)
        let stored = await cloud.storedRecords()
        XCTAssertEqual(stored.count, 0)
    }

    /// `--seed-schema` runs only with `--sync-demo` and its yes, alone (never with the reset or the key print).
    func testSeedArgumentNeedsTheDemoLaunch() {
        let yes = SyncActivation.Decision(allowed: true, reason: nil)
        let no = SyncActivation.Decision(allowed: false, reason: "not the demo")
        XCTAssertNil(SyncDemoReset.refusal(arguments: ["--sync-demo", "--seed-schema"], decision: yes))
        XCTAssertEqual(SyncDemoReset.refusal(arguments: ["--sync-demo", "--seed-schema"], decision: no), "not the demo")
        XCTAssertEqual(SyncDemoReset.refusal(arguments: ["--seed-schema"], decision: yes),
                       "--seed-schema works only together with --sync-demo, on the demo database.")
        XCTAssertEqual(SyncDemoReset.refusal(arguments: ["--sync-demo", "--sync-demo-reset", "--seed-schema"], decision: yes),
                       "--sync-demo-reset and --seed-schema are separate launches.")
        XCTAssertEqual(SyncDemoReset.refusal(arguments: ["--sync-demo", "--sync-demo-reset", "--print-demo-key"], decision: yes),
                       "--sync-demo-reset and --print-demo-key are separate launches.")
    }
}

/// What a `@Sendable` closure saw.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [SyncWireRecord] = []
    private var wasCalled = false
    func set(_ records: [SyncWireRecord]) { lock.withLock { held = records; wasCalled = true } }
    var records: [SyncWireRecord] { lock.withLock { held } }
    var called: Bool { lock.withLock { wasCalled } }
}
