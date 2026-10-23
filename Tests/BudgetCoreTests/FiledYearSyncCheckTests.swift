import XCTest
import GRDB
@testable import BudgetCore

/// Plan step 3 Task 6 (sync spec §5.4, Review Focus 5): after applying a pull, the filed and paid years'
/// figures are taken again; an incoming change that would move one is held, not written. Two devices over a
/// `FakeCloud`; A writes straight to its database (as a tool, or a device without the import guard, would),
/// so only B's check stands between the change and B's filed return. Synthetic data: Person A, a filed
/// 2024/25, Property A let out with its rent and a repair in that year.
final class FiledYearSyncCheckTests: XCTestCase {
    private var cloud: FakeCloud!
    private var keys: InMemorySyncKeyStore!
    private var a: SyncEngineTestDevice!
    private var b: SyncEngineTestDevice!
    private var ids: [String: Int64] = [:]

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        MonthRange.calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUp() async throws {
        cloud = FakeCloud()
        keys = InMemorySyncKeyStore()
        a = try SyncEngineTestDevice("user-a", name: "Mac", cloud: cloud, keys: keys)
        b = try SyncEngineTestDevice("user-b", name: "iPad", cloud: cloud, keys: keys)
        ids = try a.write { db in try Self.fixture(db) }
        try await a.engine.syncNow()
        try await b.engine.syncNow()
    }

    /// Person A filed 2024/25; Property A (wholly A's) has rent and a repair that year on its bank account,
    /// and the bank account has an uncategorised coffee in 2026.
    static func fixture(_ db: Database) throws -> [String: Int64] {
        var ids: [String: Int64] = [:]
        var person = Person(name: "Person A", shortName: "A")
        try People.save(db: db, &person)
        var year = TaxYear(startYear: 2024, personId: person.id!, status: .filed)
        try year.insert(db)
        var property = Property(name: "Property A", country: "PT", currency: .gbp)
        try Properties.save(db: db, &property)
        _ = try Properties.setOwners(db: db, propertyId: property.id!, [
            PropertyOwner(propertyId: property.id!, personId: person.id!, shareBasisPoints: 10_000)
        ])
        var account = Account(name: "Bank A", currency: .gbp, kind: .cash, trackingMode: .imported)
        try account.insert(db)
        ids["bank"] = account.id!
        var batch = ImportBatch(accountId: account.id!, sourceFileName: "earlier.csv", importedAt: date(2025, 1, 1))
        try batch.insert(db)
        ids["batch"] = batch.id!
        try Properties.setAccount(db: db, propertyId: property.id!, accountId: account.id!, role: .current)
        var group = CategoryGroup(name: "Property A")
        try group.insert(db)
        try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
        for (key, name, type) in [("rent", "Rental income", CategoryType.income), ("repairs", "Repairs", .expense)] {
            var category = Category(name: name, type: type, groupId: group.id)
            try category.insert(db)
            ids[key] = category.id!
        }
        try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
        for (key, day, description, amount, category) in [
            ("rentRow", date(2024, 6, 1), "TENANT RENT", 500_000, ids["rent"]),
            ("plumber", date(2024, 7, 1), "PLUMBER", -10_000, ids["repairs"]),
            ("coffee", date(2026, 3, 1), "COFFEE", -300, nil)
        ] {
            var t = Transaction(importBatchId: batch.id!, accountId: account.id!, date: day, rawDescription: description,
                                amountMinorUnits: amount, categoryId: category, status: .confirmed,
                                categorizedBy: category == nil ? .none : .manual, fingerprint: "fp-\(description)")
            try t.insert(db)
            ids[key] = t.id!
        }
        return ids
    }

    // MARK: Helpers

    private func figures(_ device: SyncEngineTestDevice) throws -> TaxFigures.Snapshot {
        try device.read { db in try TaxFigures.snapshot(db: db) }
    }

    private func returnFigures(_ device: SyncEngineTestDevice) throws -> [TaxFigures.Key: TaxFigures.Value] {
        try figures(device).values.filter { $0.key.startYear == 2024 && $0.key.field.hasPrefix("SA ") }
    }

    private func amount(_ device: SyncEngineTestDevice, _ uuid: String) throws -> Int? {
        guard let id = try device.localId("transaction_", uuid) else { return nil }
        return try device.read { db in try Int.fetchOne(db, sql: "SELECT amountMinorUnits FROM transaction_ WHERE id = ?", arguments: [id]) }
    }

    private func held(_ device: SyncEngineTestDevice) throws -> [SyncStagingRow] {
        try device.read { db in try FiledYearSyncCheck.held(db: db) }
    }

    // MARK: The fixture

    func testTheFixturesFiledFiguresArriveAndARepairMovesThem() throws {
        XCTAssertEqual(try figures(b), try figures(a), "B holds A's filed figures")
        XCTAssertFalse(try returnFigures(b).isEmpty)
        XCTAssertEqual(try b.read { db in try FiledYearGuard.filedYears(db: db) }, [2024])
        // Changing the repair here (rolled back) moves the filed return.
        let moved = try b.write { db -> [FiledYearImpact] in
            let plumber = try XCTUnwrap(SyncRecordStore.localId(table: "transaction_", uuid: try a.uuid("transaction_", ids["plumber"]!), db: db))
            var impacts: [FiledYearImpact] = []
            try db.inSavepoint {
                let raw = try TaxFigures.snapshot(db: db)
                try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [plumber])
                impacts = try FiledYearGuard.filedChanges(db: db, from: raw)
                return .rollback
            }
            return impacts
        }
        XCTAssertEqual(moved.first?.startYear, 2024)
    }

    // MARK: Plan tests (Review Focus 5)

    func testIncomingChangeToFiledYearRaisesAlertAndWritesNothing() async throws {
        let plumber = try a.uuid("transaction_", ids["plumber"]!)
        let before = try figures(b)
        let content = try b.content()
        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [ids["plumber"]!]) }
        try await a.engine.syncNow()

        let report = try await b.engine.pull()
        let alert = try XCTUnwrap(report.filedYearAlert, "the pull reports the alert")
        XCTAssertEqual(alert.records.map(\.recordName), [plumber], "it names the record")
        XCTAssertEqual(alert.records.first?.recordType, "transaction_")
        XCTAssertEqual(alert.records.first?.writer, "user-a", "and who wrote it")
        XCTAssertEqual(alert.records.first?.isDelete, false)
        XCTAssertEqual(alert.impacts.map(\.startYear), [2024])
        XCTAssertEqual(alert.impacts.first?.headline, "Would change the filed 2024/25 return of Person A")
        XCTAssertFalse(alert.impacts.first?.returnChanges.isEmpty ?? true)
        XCTAssertEqual(report.held, 1)

        XCTAssertEqual(try figures(b), before, "the filed figures are unchanged")
        XCTAssertEqual(try amount(b, plumber), -10_000)
        XCTAssertEqual(try b.content(), content, "nothing else is written")
        XCTAssertTrue(try b.read { db in try SyncChangeTracker.pending(db: db) }.isEmpty, "nothing queued to go back up")
        let rows = try held(b)
        XCTAssertEqual(rows.map(\.uuid), [plumber], "the record waits, held")
        XCTAssertEqual(rows.first?.reason, FiledYearSyncCheck.heldReason)
        XCTAssertTrue(rows.first?.reason.hasPrefix("needs attention: ") ?? false)
        XCTAssertTrue(try b.read { db in try SyncTranslator.stagingAttention(db: db) }.map(\.uuid).contains(plumber))

        // Held: a later pull doesn't apply it either.
        try await b.engine.syncNow()
        XCTAssertEqual(try amount(b, plumber), -10_000)
        XCTAssertEqual(try figures(b), before)
    }

    func testIncomingRecategorisationInAFiledYearIsHeld() async throws {
        let plumber = try a.uuid("transaction_", ids["plumber"]!)
        let before = try figures(b)
        try a.write { db in
            try db.execute(sql: "UPDATE transaction_ SET categoryId = NULL, categorizedBy = 'none' WHERE id = ?", arguments: [ids["plumber"]!])
        }
        try await a.engine.syncNow()
        let report = try await b.engine.pull()
        XCTAssertEqual(report.filedYearAlert?.records.map(\.recordName), [plumber])
        XCTAssertEqual(try figures(b), before)
        let local = try b.localId("transaction_", plumber)
        let categoryId = try b.read { db in try Int64.fetchOne(db, sql: "SELECT categoryId FROM transaction_ WHERE id = ?", arguments: [local]) }
        XCTAssertNotNil(categoryId, "still in Repairs here")
    }

    func testNonFiledChangeAppliesNormally() async throws {
        let coffee = try a.uuid("transaction_", ids["coffee"]!)
        let before = try figures(b)
        try a.write { db in
            try db.execute(sql: "UPDATE transaction_ SET note = 'Flat white', amountMinorUnits = -350 WHERE id = ?", arguments: [ids["coffee"]!])
            var t = Transaction(importBatchId: ids["batch"]!, accountId: ids["bank"]!, date: Self.date(2026, 3, 2), rawDescription: "BAKERY",
                                amountMinorUnits: -500, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "fp-BAKERY")
            try t.insert(db)
            // An edit in the filed year that no figure reads: the note.
            try db.execute(sql: "UPDATE transaction_ SET note = 'Kitchen tap' WHERE id = ?", arguments: [ids["plumber"]!])
        }
        try await a.engine.syncNow()
        let report = try await b.engine.pull()
        XCTAssertNil(report.filedYearAlert)
        XCTAssertEqual(report.held, 0)
        XCTAssertEqual(try amount(b, coffee), -350)
        XCTAssertTrue(try b.descriptions().contains("BAKERY"))
        XCTAssertEqual(try figures(b), before)
        XCTAssertTrue(try held(b).isEmpty)
        XCTAssertEqual(try a.content(), try b.content())
    }

    // MARK: Isolation

    func testOnlyTheRecordsThatWouldMoveAFiledFigureAreHeld() async throws {
        let plumber = try a.uuid("transaction_", ids["plumber"]!)
        let coffee = try a.uuid("transaction_", ids["coffee"]!)
        let before = try figures(b)
        let electrician = try a.write { db -> Int64 in
            try db.execute(sql: "UPDATE transaction_ SET note = 'Flat white' WHERE id = ?", arguments: [ids["coffee"]!])
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [ids["plumber"]!])
            for i in 0..<12 {
                var t = Transaction(importBatchId: ids["batch"]!, accountId: ids["bank"]!, date: Self.date(2026, 4, 1 + i), rawDescription: "SHOP \(i)",
                                    amountMinorUnits: -100 - i, categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "fp-SHOP-\(i)")
                try t.insert(db)
            }
            // A new repair in the filed year.
            var electrician = Transaction(importBatchId: ids["batch"]!, accountId: ids["bank"]!, date: Self.date(2024, 9, 1),
                                          rawDescription: "ELECTRICIAN", amountMinorUnits: -3_000, categoryId: ids["repairs"]!, status: .confirmed,
                                          categorizedBy: .manual, fingerprint: "fp-ELECTRICIAN")
            try electrician.insert(db)
            return electrician.id!
        }
        let electricianUuid = try a.uuid("transaction_", electrician)
        try await a.engine.syncNow()
        let report = try await b.engine.pull()
        let alert = try XCTUnwrap(report.filedYearAlert)
        XCTAssertEqual(Set(alert.records.map(\.recordName)), [plumber, electricianUuid], "both filed-year changes, and nothing else")
        XCTAssertEqual(report.held, 2)
        XCTAssertEqual(try figures(b), before)
        XCTAssertEqual(try amount(b, plumber), -10_000)
        XCTAssertNil(try b.localId("transaction_", electricianUuid), "the new repair isn't written")
        let local = try b.localId("transaction_", coffee)
        let note = try b.read { db in try String.fetchOne(db, sql: "SELECT note FROM transaction_ WHERE id = ?", arguments: [local]) }
        XCTAssertEqual(note, "Flat white", "the rest of the pull applies")
        XCTAssertEqual(try b.descriptions().filter { $0.hasPrefix("SHOP") }.count, 12)
        XCTAssertEqual(Set(try held(b).map(\.uuid)), [plumber, electricianUuid])
    }

    func testAnIncomingDeleteOfAFiledYearRowIsHeld() async throws {
        let plumber = try a.uuid("transaction_", ids["plumber"]!)
        let before = try figures(b)
        try a.write { db in try db.execute(sql: "DELETE FROM transaction_ WHERE id = ?", arguments: [ids["plumber"]!]) }
        try await a.engine.syncNow()
        let report = try await b.engine.pull()
        let alert = try XCTUnwrap(report.filedYearAlert)
        XCTAssertEqual(alert.records.map(\.recordName), [plumber])
        XCTAssertEqual(alert.records.first?.isDelete, true)
        XCTAssertEqual(try amount(b, plumber), -10_000, "the row is still here")
        XCTAssertEqual(try figures(b), before)
        XCTAssertEqual(try held(b).first?.reason, FiledYearSyncCheck.heldDeleteReason)
    }

    func testAHeldRecordsLaterVersionIsCheckedAgainAndAppliesWhenItMovesNothing() async throws {
        let plumber = try a.uuid("transaction_", ids["plumber"]!)
        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [ids["plumber"]!]) }
        try await a.engine.syncNow()
        _ = try await b.engine.pull()
        XCTAssertEqual(try held(b).count, 1)
        // A puts the amount back and adds a note: that version moves nothing here.
        try a.write { db in
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -10000, note = 'Kitchen tap' WHERE id = ?", arguments: [ids["plumber"]!])
        }
        try await a.engine.syncNow()
        let report = try await b.engine.pull()
        XCTAssertNil(report.filedYearAlert)
        XCTAssertTrue(try held(b).isEmpty)
        let local = try b.localId("transaction_", plumber)
        let note = try b.read { db in try String.fetchOne(db, sql: "SELECT note FROM transaction_ WHERE id = ?", arguments: [local]) }
        XCTAssertEqual(note, "Kitchen tap")
        XCTAssertEqual(try a.content(), try b.content())
    }

    /// A confirmed import on A, written as `ImportApplier` writes one: three rows, the second a repair in the
    /// filed 2024/25. Returns that row's id.
    @discardableResult
    private func importWithAFiledYearRow(extraRows: Int = 0) async throws -> Int64 {
        try await a.engine.acquireImportLease()
        return try a.write { db -> Int64 in
            var filed: Int64 = 0
            try SyncImportGate.require(db: db)
            let mark = try SyncBatch.mark(db: db)
            var run = ImportRun(confirmedAt: Self.date(2026, 5, 1), entryPoint: "Import…", summary: "")
            try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            var batch = ImportBatch(accountId: ids["bank"]!, sourceFileName: "statement.csv", importedAt: Self.date(2026, 5, 1), importRunId: run.id)
            try batch.insert(db)
            let extra: [(Date, Int, Int64?)] = (0..<extraRows).map { (Self.date(2026, 6, 1 + $0 % 28), -10 - $0, nil) }
            for (i, (day, amount, category)) in ([(Self.date(2026, 4, 2), -700, nil), (Self.date(2024, 8, 3), -5_000, ids["repairs"]),
                                                  (Self.date(2026, 4, 4), -900, nil)] + extra).enumerated() {
                var t = Transaction(importBatchId: batch.id!, accountId: ids["bank"]!, date: day, rawDescription: "ROW \(i)",
                                    amountMinorUnits: amount, categoryId: category, status: .confirmed,
                                    categorizedBy: category == nil ? .none : .rule, fingerprint: "fp-row-\(i)")
                try t.insert(db)
                if category != nil { filed = t.id! }
            }
            _ = try ImportChangeCapture.finish(db: db, runId: run.id!)
            var file = ImportRunFile(runId: run.id!, fileName: "statement.csv", sha256: "sha-1", outcome: .transactions, detail: "")
            try file.insert(db)
            try SyncBatch.open(runId: run.id!, since: mark, db: db)
            return filed
        }
    }

    /// The zone's changes B hasn't fetched yet, as the engine would apply them.
    private func unfetched(_ device: SyncEngineTestDevice) async throws -> [SyncIncomingChange] {
        var token = try device.read { db in try SyncEngineCore.token(zone: SyncRecordStore.householdZone, db: db) }
        var changes: [SyncIncomingChange] = []
        while true {
            let page = try await cloud.changes(since: token, zone: SyncRecordStore.householdZone)
            for change in page.changes {
                switch change {
                case .record(let record):
                    guard !SyncEngineCore.reservedRecordTypes.contains(record.wire.recordType) else { continue }
                    changes.append(.save(try SyncLargePayload.payload(from: record.wire, keys: try device.keys.allKeys(zone: record.wire.zone))))
                case .deletion(let deletion):
                    changes.append(.delete(recordName: deletion.recordName, recordType: deletion.recordType))
                }
            }
            token = page.token
            if !page.moreComing { return changes }
        }
    }

    func testAnImportBatchWithAFiledYearRecordIsHeldWhole() async throws {
        let before = try figures(b)
        let counts = try b.count("transaction_")
        try await importWithAFiledYearRow()
        try await a.engine.syncNow()
        let report = try await b.engine.pull()
        let alert = try XCTUnwrap(report.filedYearAlert)
        XCTAssertGreaterThanOrEqual(alert.records.count, 5, "the run, its batch and its three rows: \(alert.records.map(\.recordType))")
        XCTAssertTrue(alert.records.contains { $0.recordType == "importRun" })
        XCTAssertEqual(try b.count("transaction_"), counts, "none of the batch applies")
        XCTAssertEqual(try figures(b), before)
        // Caught up: the closed batch still doesn't apply on its own, and what comes next applies without it.
        try await a.engine.syncNow()
        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'Flat white' WHERE id = ?", arguments: [ids["coffee"]!]) }
        try await a.engine.syncNow()
        let next = try await b.engine.pull()
        XCTAssertNil(next.filedYearAlert, "the held batch doesn't come back on later pulls")
        let coffee = try b.localId("transaction_", try a.uuid("transaction_", ids["coffee"]!))
        XCTAssertEqual(try b.read { db in try String.fetchOne(db, sql: "SELECT note FROM transaction_ WHERE id = ?", arguments: [coffee]) },
                       "Flat white")
        XCTAssertEqual(try b.count("transaction_"), counts)
        XCTAssertEqual(try b.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM importRun")! }, 0)
    }

    func testAHeldBatchWhoseOtherMembersWaitedEarlierNeverAppliesPartly() async throws {
        // The batch's other members (and its closed run) arrived in an earlier pull and wait; the filed-year
        // row comes in a later one, with an unrelated edit.
        let before = try figures(b)
        let counts = try b.count("transaction_")
        let filedRow = try a.uuid("transaction_", try await importWithAFiledYearRow())
        try await a.engine.syncNow()
        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'Flat white' WHERE id = ?", arguments: [ids["coffee"]!]) }
        try await a.engine.syncNow()
        let coffee = try a.uuid("transaction_", ids["coffee"]!)
        let feed = try await unfetched(b)
        let later = feed.filter { $0.recordName == filedRow || $0.recordName == coffee }
        XCTAssertEqual(later.count, 2)
        let user = b.user
        let outcome = try b.write { db -> FiledYearSyncCheck.Outcome in
            try SyncTranslator.apply(feed.filter { $0.recordName != filedRow && $0.recordName != coffee }, db: db, deviceUser: user)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncBatch WHERE state = 'closed'"), 1, "the closed batch waits")
            let baseline = try FiledYearSyncCheck.baseline(db: db)
            return try FiledYearSyncCheck.apply(later, baseline: baseline, db: db, deviceUser: user, now: Date())
        }
        let records = try XCTUnwrap(outcome.alert?.records)
        XCTAssertTrue(records.allSatisfy { $0.reason == FiledYearSyncCheck.heldBatchReason }, "\(records.map(\.reason))")
        XCTAssertTrue(records.contains { $0.recordName == filedRow })
        XCTAssertGreaterThanOrEqual(records.count, 5, "the batch's records that waited are named, held with it")
        XCTAssertEqual(try b.count("transaction_"), counts, "none of the batch applies, not even the members that waited")
        XCTAssertEqual(try figures(b), before)
        let local = try b.localId("transaction_", coffee)
        XCTAssertEqual(try b.read { db in try String.fetchOne(db, sql: "SELECT note FROM transaction_ WHERE id = ?", arguments: [local]) },
                       "Flat white", "the unrelated edit applies")
        // A later flush (caught up again) still leaves the batch whole and waiting.
        try b.write { db in _ = try SyncBatch.flushClosed(db: db, deviceUser: user) }
        XCTAssertEqual(try b.count("transaction_"), counts)
        XCTAssertGreaterThanOrEqual(try held(b).count, 5, "the run, its batch and its rows wait held")
    }

    // MARK: The check itself

    func testAfterKeepsAnApplyThatMovesNothingAndRollsBackOneThatDoes() throws {
        let plumber = try b.localId("transaction_", try a.uuid("transaction_", ids["plumber"]!))!
        let kept = try b.write { db in
            try FiledYearSyncCheck.after(apply: {
                try db.execute(sql: "UPDATE transaction_ SET note = 'kept' WHERE id = ?", arguments: [plumber])
            }, db: db)
        }
        XCTAssertNil(kept)
        XCTAssertEqual(try b.read { db in try String.fetchOne(db, sql: "SELECT note FROM transaction_ WHERE id = ?", arguments: [plumber]) }, "kept")

        let alert = try b.write { db in
            try FiledYearSyncCheck.after(apply: {
                try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = 1, note = 'gone' WHERE id = ?", arguments: [plumber])
            }, db: db)
        }
        XCTAssertEqual(alert?.impacts.map(\.startYear), [2024])
        XCTAssertEqual(try b.read { db in try String.fetchOne(db, sql: "SELECT note FROM transaction_ WHERE id = ?", arguments: [plumber]) }, "kept",
                       "rolled back")
    }

    func testTheReplayedCheckAgreesWithTakingEveryFigure() throws {
        // A change to a table the figures read (a category's name) that moves nothing, and one that does.
        let plumber = try b.localId("transaction_", try a.uuid("transaction_", ids["plumber"]!))!
        try b.write { db in
            let baseline = try FiledYearSyncCheck.baseline(db: db)
            XCTAssertEqual(baseline.years, [2020, 2021, 2022, 2023, 2024])
            XCTAssertNotNil(baseline.reads, "the baseline is replayable")
            for (sql, moves) in [("UPDATE transaction_ SET note = 'x' WHERE id = \(plumber)", false),
                                 ("UPDATE transaction_ SET amountMinorUnits = -1 WHERE id = \(plumber)", true),
                                 ("UPDATE transaction_ SET date = '2026-01-01 00:00:00.000' WHERE id = \(plumber)", true)] {
                try db.inSavepoint {
                    let replayed = try FiledYearSyncCheck.impacts(db: db, baseline: baseline) { try db.execute(sql: sql) }
                    let full = FiledYearImpact.impacts(before: baseline.before,
                                                       after: try TaxFigures.snapshot(db: db, only: baseline.years), causes: [])
                    XCTAssertEqual(replayed, full, sql)
                    XCTAssertEqual(!replayed.isEmpty, moves, sql)
                    return .rollback
                }
            }
        }
    }

    func testTheProtectedYearsAreTheFixedRangeAndWhateverIsFiled() throws {
        // Ruling R13: 2020/21–2024/25 always, plus any year stored filed or paid.
        let fresh = try DatabaseManager(path: nil)
        try fresh.migrate()
        let baseline = try fresh.dbQueue.write { db in try FiledYearSyncCheck.baseline(db: db) }
        XCTAssertEqual(baseline.years, [2020, 2021, 2022, 2023, 2024])
        try b.write { db in
            try db.execute(sql: "INSERT INTO taxYear(startYear, personId, status) SELECT 2026, id, 'paid' FROM person LIMIT 1")
            XCTAssertEqual(try FiledYearSyncCheck.baseline(db: db).years, [2020, 2021, 2022, 2023, 2024, 2026])
        }
    }

    func testAFirstSyncOntoAnEmptyDeviceHoldsNothing() async throws {
        let c = try SyncEngineTestDevice("user-c", name: "iPhone", cloud: cloud, keys: keys)
        let report = try await c.engine.pull()
        XCTAssertNil(report.filedYearAlert)
        XCTAssertEqual(try figures(c), try figures(a))
    }

    /// Ruling R15: a record that waited for the household key goes through the same check once its key arrives.
    func testARecordThatWaitedForTheHouseholdKeyIsCheckedWhenItOpens() async throws {
        // C: a device whose key store had the first key, but not yet the key A rotates to.
        let cKeys = InMemorySyncKeyStore()
        try cKeys.store(try XCTUnwrap(keys.key(zone: SyncRecordStore.householdZone)), zone: SyncRecordStore.householdZone)
        let c = try SyncEngineTestDevice("user-c", name: "iPhone", cloud: cloud, keys: cKeys)
        try await c.engine.pull()
        let before = try figures(c)
        XCTAssertEqual(before, try figures(a))

        try await a.engine.rotateZoneKey()
        let plumber = try a.uuid("transaction_", ids["plumber"]!)
        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [ids["plumber"]!]) }
        try await a.engine.syncNow()

        let waiting = try await c.engine.pull()
        XCTAssertEqual(waiting.waitingForKey, 1)
        XCTAssertNil(waiting.filedYearAlert)
        XCTAssertEqual(try amount(c, plumber), -10_000)

        try cKeys.store(try XCTUnwrap(keys.key(zone: SyncRecordStore.householdZone)), zone: SyncRecordStore.householdZone)
        let opened = try await c.engine.pull()
        let alert = try XCTUnwrap(opened.filedYearAlert, "held by the filed-year check")
        XCTAssertEqual(alert.records.map(\.recordName), [plumber])
        XCTAssertEqual(try amount(c, plumber), -10_000)
        XCTAssertEqual(try figures(c), before, "the filed figures are unchanged")
        XCTAssertEqual(try held(c).map(\.uuid), [plumber])
    }

    // MARK: Fix round 1

    /// A's payload of one of its rows, as A would send it (not sent).
    private func payload(_ table: String, _ id: Int64) throws -> SyncPayload {
        let uuid = try a.uuid(table, id)
        return try a.write { db in
            try XCTUnwrap(SyncTranslator.outgoing(PendingChange(table: table, localId: id, uuid: uuid, kind: .update), db: db))
        }
    }

    func testAMergeOnPushThatWouldMoveAFiledYearIsHeld() async throws {
        let plumber = try a.uuid("transaction_", ids["plumber"]!)
        let before = try figures(b)
        try a.write { db in try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [ids["plumber"]!]) }
        try await a.engine.syncNow()
        // B edits the same row offline: its save meets A's newer version on the server.
        let local = try XCTUnwrap(try b.localId("transaction_", plumber))
        let stamp = try b.read { db in try SyncEngineCore.systemFields(uuid: plumber, db: db) }
        try b.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'Kitchen tap' WHERE id = ?", arguments: [local]) }
        let report = try await b.engine.pushPending()
        XCTAssertEqual(report.held, 1)
        XCTAssertEqual(report.filedYearAlert?.records.map(\.recordName), [plumber])
        XCTAssertEqual(try amount(b, plumber), -10_000, "the server's version isn't merged in")
        XCTAssertEqual(try figures(b), before)
        XCTAssertEqual(try held(b).map(\.uuid), [plumber])
        XCTAssertEqual(try b.read { db in try SyncEngineCore.systemFields(uuid: plumber, db: db) }, stamp, "no stamp for the held version")
        XCTAssertEqual(try b.read { db in try SyncChangeTracker.pending(db: db) }.map(\.uuid), [plumber], "the local edit waits")
        let again = try await b.engine.pushPending()
        XCTAssertEqual(again.heldBack, 1)
        XCTAssertEqual(again.saved, 0)
    }

    func testStagedRecordsAreRetriedThroughTheCheckOnTheNextPullNotAtOpen() async throws {
        // As an older build would have left them: two records it couldn't apply, one moving the filed year.
        try a.write { db in
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [ids["plumber"]!])
            try db.execute(sql: "UPDATE transaction_ SET note = 'Flat white' WHERE id = ?", arguments: [ids["coffee"]!])
        }
        let plumber = try payload("transaction_", ids["plumber"]!), coffee = try payload("transaction_", ids["coffee"]!)
        try b.write { db in
            for p in [plumber, coffee] {
                var row = SyncStagingRow(tableName: "transaction_", uuid: p.recordName, payloadJSON: try SyncTranslator.json(p),
                                         reason: "unknown record type", receivedAt: Date())
                try row.insert(db)
            }
        }
        let before = try figures(b)
        try b.manager.migrate()  // what opening does
        XCTAssertEqual(try b.read { db in try SyncStagingRow.fetchCount(db) }, 2, "nothing applied at open")
        XCTAssertTrue(try b.read { db in try SyncEngineCore.retryStagedRequested(db: db) })
        let report = try await b.engine.pull()
        XCTAssertEqual(report.filedYearAlert?.records.map(\.recordName), [plumber.recordName])
        XCTAssertEqual(try figures(b), before)
        let local = try b.localId("transaction_", coffee.recordName)
        XCTAssertEqual(try b.read { db in try String.fetchOne(db, sql: "SELECT note FROM transaction_ WHERE id = ?", arguments: [local]) },
                       "Flat white")
        XCTAssertFalse(try b.read { db in try SyncEngineCore.retryStagedRequested(db: db) })
        XCTAssertEqual(try held(b).map(\.uuid), [plumber.recordName])
    }

    func testAHeldBatchCountsOnceTowardsTheCap() async throws {
        let plumber = try a.uuid("transaction_", ids["plumber"]!)
        let coffee = try a.uuid("transaction_", ids["coffee"]!)
        let before = try figures(b)
        try await importWithAFiledYearRow(extraRows: 30)
        try await a.engine.syncNow()
        try a.write { db in
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -20000 WHERE id = ?", arguments: [ids["plumber"]!])
            try db.execute(sql: "UPDATE transaction_ SET note = 'Flat white' WHERE id = ?", arguments: [ids["coffee"]!])
        }
        try await a.engine.syncNow()
        let report = try await b.engine.pull()
        let records = try XCTUnwrap(report.filedYearAlert?.records)
        XCTAssertGreaterThanOrEqual(records.count, 34, "the batch's 33 rows, its run and batch, and the repair")
        XCTAssertTrue(records.contains { $0.recordName == plumber && $0.reason == FiledYearSyncCheck.heldReason })
        XCTAssertFalse(records.contains { $0.recordName == coffee })
        XCTAssertEqual(try figures(b), before)
        let local = try b.localId("transaction_", coffee)
        XCTAssertEqual(try b.read { db in try String.fetchOne(db, sql: "SELECT note FROM transaction_ WHERE id = ?", arguments: [local]) },
                       "Flat white", "the rest of the pull still applies")
    }

    func testAStagedRecordThatAppliesWhenItsParentArrivesIsTheOneHeld() async throws {
        // A new import batch row and a repair on it in the filed year; the repair reaches B first and waits.
        let (batchId, repairId) = try a.write { db -> (Int64, Int64) in
            var batch = ImportBatch(accountId: ids["bank"]!, sourceFileName: "later.csv", importedAt: Self.date(2026, 2, 1))
            try batch.insert(db)
            var t = Transaction(importBatchId: batch.id!, accountId: ids["bank"]!, date: Self.date(2024, 10, 1), rawDescription: "ROOFER",
                                amountMinorUnits: -7_000, categoryId: ids["repairs"]!, status: .confirmed, categorizedBy: .manual,
                                fingerprint: "fp-ROOFER")
            try t.insert(db)
            return (batch.id!, t.id!)
        }
        let batch = try payload("importBatch", batchId), repair = try payload("transaction_", repairId)
        let before = try figures(b)
        let user = b.user
        let outcome = try b.write { db -> FiledYearSyncCheck.Outcome in
            let waiting = try SyncTranslator.apply([.save(repair)], db: db, deviceUser: user)
            guard case .staged = waiting[repair.recordName] else { XCTFail("\(waiting)"); return FiledYearSyncCheck.Outcome() }
            return try FiledYearSyncCheck.apply([.save(batch)], baseline: try FiledYearSyncCheck.baseline(db: db), db: db, deviceUser: user, now: Date())
        }
        let records = try XCTUnwrap(outcome.alert?.records)
        XCTAssertEqual(records.map(\.recordName), [repair.recordName], "the repair is blamed, not its parent")
        XCTAssertEqual(records.first?.reason, FiledYearSyncCheck.heldReason)
        XCTAssertNotNil(try b.localId("importBatch", batch.recordName), "the parent applies")
        XCTAssertNil(try b.localId("transaction_", repair.recordName))
        XCTAssertEqual(try figures(b), before)
        XCTAssertEqual(try held(b).map(\.uuid), [repair.recordName])
    }

    func testAFiledYearSetBackToPreparingIsHeld() async throws {
        let year = try a.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM taxYear WHERE startYear = 2024")! }
        let uuid = try a.uuid("taxYear", year)
        try a.write { db in try db.execute(sql: "UPDATE taxYear SET status = 'preparing' WHERE id = ?", arguments: [year]) }
        try await a.engine.syncNow()
        let report = try await b.engine.pull()
        let alert = try XCTUnwrap(report.filedYearAlert)
        XCTAssertEqual(alert.records.map(\.recordName), [uuid])
        XCTAssertTrue(alert.impacts.contains { $0.startYear == 2024 && $0.returnChanges.contains { $0.label == "Status" } }, "\(alert.impacts)")
        XCTAssertEqual(try b.read { db in try FiledYearGuard.filedYears(db: db) }, [2024])
    }

    func testAChangeToA2021FigureIsHeldThoughThatYearIsNotStoredFiled() async throws {
        let before = try figures(b)
        let repair = try a.write { db -> Int64 in
            var t = Transaction(importBatchId: ids["batch"]!, accountId: ids["bank"]!, date: Self.date(2021, 8, 1), rawDescription: "GLAZIER",
                                amountMinorUnits: -5_000, categoryId: ids["repairs"]!, status: .confirmed, categorizedBy: .manual,
                                fingerprint: "fp-GLAZIER")
            try t.insert(db)
            return t.id!
        }
        try await a.engine.syncNow()
        let report = try await b.engine.pull()
        let alert = try XCTUnwrap(report.filedYearAlert)
        XCTAssertEqual(alert.records.map(\.recordName), [try a.uuid("transaction_", repair)])
        XCTAssertTrue(alert.impacts.contains { $0.startYear == 2021 }, "\(alert.impacts.map(\.startYear))")
        XCTAssertEqual(try figures(b), before)
    }

    func testAnEarlierYearsLossCarriedIntoTheFiledYearIsCaught() async throws {
        // Review item 8. The app's UK rules start at 2020/21, so the carry-forward chain does too: a 2019/20
        // row reaches no return (it applies); a 2020/21 tax year arriving with a loss carried into 2024/25 is held.
        let before = try figures(b)
        try a.write { db in
            let person = try Int64.fetchOne(db, sql: "SELECT id FROM person")!
            var y2019 = TaxYear(startYear: 2019, personId: person, status: .filed)
            try y2019.insert(db)
            var old = Transaction(importBatchId: ids["batch"]!, accountId: ids["bank"]!, date: Self.date(2019, 7, 1), rawDescription: "OLD ROOF",
                                  amountMinorUnits: -1_000_000, categoryId: ids["repairs"]!, status: .confirmed, categorizedBy: .manual,
                                  fingerprint: "fp-OLD")
            try old.insert(db)
        }
        try await a.engine.syncNow()
        let first = try await b.engine.pull()
        XCTAssertNil(first.filedYearAlert, "\(String(describing: first.filedYearAlert?.impacts))")
        let (yearId, lossId) = try a.write { db -> (Int64, Int64) in
            let person = try Int64.fetchOne(db, sql: "SELECT id FROM person")!
            var y2020 = TaxYear(startYear: 2020, personId: person, status: .preparing)
            try y2020.insert(db)
            var loss = Transaction(importBatchId: ids["batch"]!, accountId: ids["bank"]!, date: Self.date(2020, 7, 1), rawDescription: "NEW ROOF",
                                   amountMinorUnits: -1_000_000, categoryId: ids["repairs"]!, status: .confirmed, categorizedBy: .manual,
                                   fingerprint: "fp-NEW")
            try loss.insert(db)
            return (y2020.id!, loss.id!)
        }
        try await a.engine.syncNow()
        let report = try await b.engine.pull()
        let alert = try XCTUnwrap(report.filedYearAlert)
        XCTAssertTrue(alert.records.map(\.recordName).contains(try a.uuid("transaction_", lossId)))
        XCTAssertTrue(alert.impacts.contains { $0.startYear == 2024 }, "the loss reaches the filed 2024/25: \(alert.impacts.map(\.startYear))")
        _ = yearId
        let after = try figures(b).values.filter { $0.key.startYear == 2024 }
        XCTAssertEqual(after, before.values.filter { $0.key.startYear == 2024 })
    }
}
