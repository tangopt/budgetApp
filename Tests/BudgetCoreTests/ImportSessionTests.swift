import XCTest
import GRDB
@testable import BudgetCore
@testable import BudgetDemo

/// The import centre's decisions (`ImportSession`): reading into a review, answering, rule fits,
/// Confirm import and its undo, as the Mac's Imports screen drives them (and the iPad will).
/// Synthetic data only: the demo database and its import samples, made-up letters.
@MainActor
final class ImportSessionTests: XCTestCase {
    private var folder: URL!
    private var sessions: [ImportSession] = []
    private static let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for session in sessions {
            session.discard()
            await session.settled()
            session.pipeline.discardPlanningCopy()
        }
        sessions = []
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fixtures

    /// A database of its own: the demo's (with its evidence library) or an empty one.
    private struct Store {
        let manager: DatabaseManager
        let library: EvidenceLibrary
        var db: DatabaseQueue { manager.dbQueue }
    }

    private func store(_ name: String, demo: Bool) throws -> Store {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let evidence = folder.appendingPathComponent(name, isDirectory: true).appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        if demo {
            try DemoDatabase.build(dbQueue: manager.dbQueue, evidenceRoot: evidence)
        } else {
            try manager.dbQueue.write { db in try CategorySeeder.seedDefaults(db) }
        }
        return Store(manager: manager, library: EvidenceLibrary(root: evidence, database: manager.dbQueue))
    }

    private func samples(_ store: Store, _ name: String) throws -> [URL] {
        try DemoImportSamples.write(into: folder.appendingPathComponent(name, isDirectory: true).appendingPathComponent("Samples", isDirectory: true),
                                    dbQueue: store.db)
    }

    private func session(_ store: Store, model: (any DocumentModelReading)? = nil) -> ImportSession {
        let made = ImportSession(dbQueue: store.db, databasePath: nil, library: store.library,
                                 categorizationService: CategorizationService(categorizer: FakeCategorizer()),
                                 modelReader: model, now: { Self.fixedNow })
        sessions.append(made)
        return made
    }

    private func pdf(_ name: String, _ lines: [String]) throws -> URL {
        let made = EvidenceTestPDFs.textPDF(lines, name: name)
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: url)
        return url
    }

    /// A letter of a made-up issuer that nothing built in recognises.
    private func letter(_ name: String, day: String) throws -> URL {
        try pdf(name, ["Example Seguros, S.A. NIF 503504564", "Rua Exemplo 1, Lisboa", "Assunto: comunicacao \(day)",
                       "Caro senhor, segue a informacao pedida."])
    }

    private func item(_ plan: ImportPlan?, _ name: String) throws -> ImportItem {
        let plan = try XCTUnwrap(plan)
        return try XCTUnwrap(plan.items.first { $0.file.fileName == name }, "\(plan.items.map(\.file.fileName))")
    }

    /// Every table an import can change, row by row (`ImportChangeCapture.trackedTables`).
    private func trackedDump(_ db: DatabaseQueue) throws -> [String: [Row]] {
        try db.read { db in
            var dump: [String: [Row]] = [:]
            for table in try ImportChangeCapture.trackedTables(db: db) {
                dump[table] = try Row.fetchAll(db, sql: "SELECT rowid AS rowid_, * FROM \"\(table)\" ORDER BY rowid")
            }
            return dump
        }
    }

    /// `dump` without what differs between two databases built and imported into apart: the
    /// clock's times (when built, imported, a file last changed) and random fingerprints.
    private static func comparable(_ dump: [String: [Row]]) -> [String: [[String: DatabaseValue]]] {
        let clockColumns: Set<String> = ["createdAt", "importedAt", "updatedAt", "sourceModifiedAt"]
        return dump.mapValues { rows in
            rows.map { row in
                var values: [String: DatabaseValue] = [:]
                for column in row.columnNames where !clockColumns.contains(column) {
                    let value: DatabaseValue = row[column]
                    if column == "fingerprint", let text = String.fromDatabaseValue(value), text.hasPrefix("manual-") { continue }
                    values[column] = value
                }
                return values
            }
        }
    }

    private func changedTables<Value: Equatable>(_ a: [String: [Value]], _ b: [String: [Value]]) -> [String] {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
    }

    // MARK: Review Focus 1

    /// Plan → answer → confirm → undo through the session writes exactly what the importer's own
    /// steps write (as ImportCenterModel called them), and the undo leaves the database as it was.
    func testPlanAnswerConfirmUndoRoundTrip() async throws {
        // The importer's steps, called directly.
        let direct = try store("Direct", demo: true)
        let directSamples = try samples(direct, "Direct")
        let pipeline = ImportPipeline(dbQueue: direct.db, library: direct.library,
                                      categorizationService: CategorizationService(categorizer: FakeCategorizer()))
        defer { pipeline.discardPlanningCopy() }
        var directPlan = try await pipeline.plan(directSamples, intent: .none)
        for needing in directPlan.items(in: .needsYou) {
            directPlan = try await pipeline.resolve(directPlan, itemId: needing.id, .leaveOut)
        }
        let directSummary = try ImportApplier(dbQueue: direct.db, databasePath: nil, library: direct.library)
            .apply(directPlan, entryPoint: "Test", reasons: directPlan.resolutionReasons, confirmedBy: nil, now: Self.fixedNow)
        let directAfter = try trackedDump(direct.db)

        // The same through the session.
        let viaSession = try store("Session", demo: true)
        let before = try trackedDump(viaSession.db)
        let session = session(viaSession)
        session.start(try samples(viaSession, "Session"), entryPoint: "Test")
        await session.settled()
        XCTAssertEqual(session.phase, .review)
        let needsYou = try XCTUnwrap(session.plan).items(in: .needsYou)
        XCTAssertEqual(needsYou.map(\.file.fileName).sorted(), directPlan.items.filter(\.isLeftOut).map(\.file.fileName).sorted())
        for needing in needsYou { session.resolve(needing.id, .leaveOut) }
        await session.settled()
        XCTAssertTrue(try XCTUnwrap(session.plan).canConfirm)
        session.confirm(confirmedBy: nil)
        XCTAssertEqual(session.phase, .applying)
        await session.settled()
        guard case .finished(let summary) = session.phase else { return XCTFail("\(session.phase) \(String(describing: session.problem))") }
        XCTAssertNil(session.plan)
        XCTAssertEqual(session.selectedRunId, summary.runId)
        XCTAssertEqual(session.runs.first?.id, summary.runId)
        XCTAssertEqual(summary.filed, directSummary.filed)
        XCTAssertEqual(summary.transactions, directSummary.transactions)
        let after = try trackedDump(viaSession.db)
        XCTAssertNotEqual(changedTables(before, after), [], "the import wrote something")
        XCTAssertEqual(changedTables(Self.comparable(directAfter), Self.comparable(after)), [],
                       "the session writes what the importer's steps write")

        let refused = try await session.undo(summary.runId)
        XCTAssertEqual(refused, [])
        await session.settled()
        XCTAssertEqual(changedTables(before, try trackedDump(viaSession.db)), [], "the undo leaves the database as it was")
        XCTAssertNotNil(session.runs.first { $0.id == summary.runId }?.undoneAt)
    }

    // MARK: Review Focus 2

    /// Answers "slow.pdf" only when cancelled (it says when it was asked); every other file at once.
    private final class SlowModel: DocumentModelReading, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        private var wasAsked = false

        func availability() -> DocumentModelAvailability { .available }

        func read(text: String, fileName: String, kinds: [DocumentKind]) async throws -> DocumentModelGuess? {
            guard fileName == "slow.pdf" else { return nil }
            lock.withLock {
                if let waiting {
                    waiting.resume()
                    self.waiting = nil
                } else {
                    wasAsked = true
                }
            }
            try await Task.sleep(for: .seconds(60))
            return nil
        }

        /// Returns once "slow.pdf" is being asked about (again, after the last call).
        func asked() async {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if wasAsked {
                        wasAsked = false
                        continuation.resume()
                    } else {
                        waiting = continuation
                    }
                }
            }
        }
    }

    func testCancelThenRestartShowsOnlyTheNewPlan() async throws {
        let empty = try store("Cancel", demo: false)
        let model = SlowModel()
        let session = session(empty, model: model)
        var phases: [ImportSession.Phase] = []
        session.onPhaseChange = { phases.append($0) }

        session.start([try letter("slow.pdf", day: "1")], entryPoint: "Test")
        await model.asked()
        guard case .reading = session.phase else { return XCTFail("still reading: \(session.phase)") }
        session.cancelReading()
        XCTAssertEqual(session.phase, .idle, "back to what showed before")
        XCTAssertNil(session.plan)

        session.start([try letter("new.pdf", day: "2")], entryPoint: "Again")
        await session.settled()
        XCTAssertEqual(session.phase, .review)
        XCTAssertEqual(try XCTUnwrap(session.plan).items.map(\.file.fileName), ["new.pdf"], "nothing of the cancelled reading")
        XCTAssertEqual(session.review?.items.count, 1)
        // After the restart: reading, then the review, and nothing of the cancelled one after it.
        let afterCancel = phases.drop { $0 != .idle }.dropFirst()
        XCTAssertEqual(afterCancel.last, .review)
        XCTAssertEqual(afterCancel.filter { $0 == .review }.count, 1)

        // Cancelling an added reading keeps the open review as it was.
        session.start([try letter("slow.pdf", day: "3")], entryPoint: "More")
        await model.asked()
        session.cancelReading()
        XCTAssertEqual(session.phase, .review)
        await session.settled()
        XCTAssertEqual(session.phase, .review)
        XCTAssertEqual(try XCTUnwrap(session.plan).items.map(\.file.fileName), ["new.pdf"])
    }

    // MARK: Confirm

    func testConfirmUsesTheGivenUser() async throws {
        let empty = try store("User", demo: false)
        let userId = try await empty.db.write { db -> Int64 in
            var person = Person(name: "User A", shortName: "A")
            try People.save(db: db, &person)
            var user = AppUser(personId: person.id!, displayName: "User A", createdAt: Date())
            try user.insert(db)
            return user.id!
        }
        let session = session(empty)
        session.start([try letter("a.pdf", day: "1")], entryPoint: "Test")
        await session.settled()
        // Nothing built in knows the letter: filed as another document.
        session.resolve(try item(session.plan, "a.pdf").id, .chooseKind(.other))
        await session.settled()
        let reasons = try item(session.plan, "a.pdf").needsYouReasons
        XCTAssertTrue(try XCTUnwrap(session.plan).canConfirm, "\(reasons)")
        session.confirm(confirmedBy: userId)
        await session.settled()
        guard case .finished(let summary) = session.phase else { return XCTFail("\(session.phase) \(String(describing: session.problem))") }
        let run = try await empty.db.read { db in try ImportRun.fetchOne(db, key: summary.runId) }
        XCTAssertEqual(run?.appUserId, userId)
        XCTAssertEqual(run?.entryPoint, "Test")
        XCTAssertEqual(run?.confirmedAt, Self.fixedNow)
        XCTAssertEqual(session.userNames[userId], "User A")

        // Nobody signed in: nobody recorded.
        session.start([try letter("b.pdf", day: "2")], entryPoint: "Test")
        await session.settled()
        session.resolve(try item(session.plan, "b.pdf").id, .chooseKind(.other))
        await session.settled()
        session.confirm(confirmedBy: nil)
        await session.settled()
        guard case .finished(let second) = session.phase else { return XCTFail("\(session.phase)") }
        let secondRun = try await empty.db.read { db in try ImportRun.fetchOne(db, key: second.runId) }
        XCTAssertNil(secondRun?.appUserId)
    }

    // MARK: Rule fits

    func testRuleFitsAppliedAndUndone() async throws {
        let empty = try store("Rules", demo: false)
        let session = session(empty)
        session.start([try letter("a.pdf", day: "1"), try letter("b.pdf", day: "2")], entryPoint: "Test")
        await session.settled()
        XCTAssertEqual(session.ruleFits, [:], "no correction yet")
        let a = try item(session.plan, "a.pdf"), b = try item(session.plan, "b.pdf")

        session.resolve(a.id, .setIssuer("Seguradora Exemplo"))
        await session.settled()
        XCTAssertEqual(session.ruleFits[a.id]?.map(\.itemId), [b.id])
        session.reviewRuleFits(a.id)
        XCTAssertEqual(session.ruleFitsReview?.sourceId, a.id)
        let beforeRule = try item(session.plan, "b.pdf")

        session.applyRule(from: a.id, to: [b.id])
        XCTAssertNil(session.ruleFitsReview)
        await session.settled()
        XCTAssertEqual(try XCTUnwrap(session.plan).ruleChangedItems(from: a.id), [b.id])
        XCTAssertNotEqual(try item(session.plan, "b.pdf"), beforeRule, "the rule changed b")
        XCTAssertEqual(session.ruleFits[a.id] ?? [], [], "worked out again: b no longer fits")

        session.undoRuleChange(b.id)
        await session.settled()
        XCTAssertEqual(try item(session.plan, "b.pdf"), beforeRule, "as it was before the rule changed it")
        XCTAssertEqual(session.ruleFits[a.id]?.map(\.itemId), [b.id], "it fits again")

        // Every change of the source's rules taken back at once.
        session.applyRule(from: a.id, to: [b.id])
        await session.settled()
        session.undoRuleChanges(from: a.id)
        await session.settled()
        XCTAssertEqual(try item(session.plan, "b.pdf"), beforeRule)
        XCTAssertEqual(try XCTUnwrap(session.plan).ruleChangedItems(from: a.id), [])
        XCTAssertNil(session.problem)
    }

    /// Taking back the tick that drafted a rule other documents were changed by asks first
    /// (`pendingUndo`): "Undo all" takes the changes back too.
    /// The model reads an issuer on a.pdf only (the other letters get nothing).
    private final class FirstLetterModel: DocumentModelReading, @unchecked Sendable {
        func availability() -> DocumentModelAvailability { .available }
        func read(text: String, fileName: String, kinds: [DocumentKind]) async throws -> DocumentModelGuess? {
            fileName == "a.pdf" ? DocumentModelGuess(issuer: "Seguradora Exemplo") : nil
        }
    }

    func testTakingBackACorrectionAsksAboutTheChangesItMade() async throws {
        let empty = try store("Pending", demo: false)
        let session = session(empty, model: FirstLetterModel())
        session.start([try letter("a.pdf", day: "1"), try letter("b.pdf", day: "2")], entryPoint: "Test")
        await session.settled()
        let a = try item(session.plan, "a.pdf"), b = try item(session.plan, "b.pdf")
        session.resolve(a.id, .markChecked(.figure(.issuer)))
        await session.settled()
        XCTAssertEqual(session.ruleFits[a.id]?.map(\.itemId), [b.id])
        session.applyRule(from: a.id, to: [b.id])
        await session.settled()
        XCTAssertEqual(try XCTUnwrap(session.plan).ruleChangedItems(from: a.id), [b.id])

        // Keep them: only the tick goes.
        let untick = ImportResolution.unmarkChecked(.figure(.issuer))
        session.resolve(a.id, untick)
        XCTAssertEqual(session.pendingUndo, ImportSession.PendingUndo(itemId: a.id, resolution: untick, others: 1))
        session.finishPendingUndo(alsoOthers: false)
        XCTAssertNil(session.pendingUndo)
        await session.settled()
        XCTAssertEqual(try item(session.plan, "a.pdf"), a)
        XCTAssertEqual(try XCTUnwrap(session.plan).ruleChangeSource(of: b.id)?.id, a.id)

        // Undo all: the tick again, and the change it made.
        session.resolve(a.id, .markChecked(.figure(.issuer)))
        await session.settled()
        session.resolve(a.id, untick)
        XCTAssertNotNil(session.pendingUndo)
        session.finishPendingUndo(alsoOthers: true)
        await session.settled()
        XCTAssertEqual(try item(session.plan, "a.pdf"), a)
        XCTAssertEqual(try item(session.plan, "b.pdf"), b)
        XCTAssertEqual(try XCTUnwrap(session.plan).ruleChangedItems(from: a.id), [])
    }

    // MARK: Progress

    func testStagesReportedInOrder() async throws {
        let demo = try store("Stages", demo: true)
        let session = session(demo)
        var phases: [ImportSession.Phase] = []
        session.onPhaseChange = { phases.append($0) }
        session.start(try samples(demo, "Stages"), entryPoint: "Test")
        XCTAssertEqual(session.phase, .reading(ImportProgress(completed: 0, total: 0)))
        await session.settled()
        XCTAssertEqual(session.phase, .review)

        let progress = phases.compactMap { phase -> ImportProgress? in
            if case .reading(let progress) = phase { return progress }
            return nil
        }
        XCTAssertEqual(phases.last, .review)
        XCTAssertEqual(phases.filter { $0 == .review }.count, 1)
        for (earlier, later) in zip(progress, progress.dropFirst()) {
            XCTAssertTrue(later.isNotBefore(earlier), "\(earlier) then \(later)")
        }
        let stages = progress.map(\.stage)
        XCTAssertEqual(stages.first, .reading)
        XCTAssertTrue(stages.contains(.filedYears), "\(stages)")
        XCTAssertTrue(progress.contains { $0.stage == .reading && $0.total == 9 && $0.completed > 0 }, "\(progress)")

        // A late report of an earlier stage (files finish out of order) never takes the count back.
        session.start([try pdf("late.pdf", ["Nothing to see"])], entryPoint: "More")
        guard case .reading(let shown) = session.phase else { return XCTFail("\(session.phase)") }
        let generation = session.currentReadingGeneration
        // A report of a reading no longer under way is ignored, even one that would move the phase on.
        session.readingProgressed(ImportProgress(.duplicates), generation: generation - 1)
        XCTAssertEqual(session.phase, .reading(shown), "a stale reading's later stage")
        session.readingProgressed(ImportProgress(.filedYears), generation: generation)
        session.readingProgressed(ImportProgress(completed: 0, total: 1), generation: generation)
        XCTAssertEqual(session.phase, .reading(ImportProgress(.filedYears)))
        await session.settled()
        XCTAssertEqual(session.phase, .review)
    }
}
