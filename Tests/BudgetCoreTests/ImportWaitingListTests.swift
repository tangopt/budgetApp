import XCTest
import GRDB
@testable import BudgetCore

/// The waiting list (spec 2026-10-24 §1): files kept for later in Mango's own copy, listed across
/// restarts, re-read when the recognisers change, marked imported by a run and back when it is
/// undone, purged 30 days after a standing run. Synthetic files only, in temporary folders.
final class ImportWaitingListTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var root: URL { folder.appendingPathComponent("Waiting", isDirectory: true) }
    private var list: ImportWaitingList { ImportWaitingList(root: root, database: db) }
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportWaitingListTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fixtures

    /// A text file the user dropped, read as the import reads it.
    private func dropped(_ name: String, _ text: String) throws -> SetAsideFile {
        let directory = folder.appendingPathComponent("Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let file = try ImportFile.load(url, ocr: false)
        return SetAsideFile(url: url, fileName: name, sha256: file.sha256, byteCount: file.byteCount, text: file.text,
                            textStatus: file.textStatus, reason: "Not recognised", recognisedAs: "Unknown")
    }

    private func run(confirmedAt: Date, undone: Bool = false) throws -> Int64 {
        try db.write { db in
            var run = ImportRun(confirmedAt: confirmedAt, entryPoint: "Test", summary: "",
                                undoneAt: undone ? confirmedAt.addingTimeInterval(60) : nil)
            try run.insert(db)
            return try XCTUnwrap(run.id)
        }
    }

    private func rows() throws -> [ImportWaitingFile] {
        try db.read { db in try ImportWaitingFile.order(Column("id")).fetchAll(db) }
    }

    // MARK: Keep

    func testKeepCopiesTheFileAndListsItAcrossReopen() throws {
        let file = try dropped("letter.txt", "A letter nobody recognises")
        let result = try list.keep([file], now: Self.now)
        XCTAssertEqual(result.kept.map(\.originalFileName), ["letter.txt"])
        XCTAssertEqual(result.alreadyWaiting, [])
        XCTAssertEqual(result.failed, [])

        let copy = root.appendingPathComponent(file.sha256).appendingPathComponent("letter.txt")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: file.url))
        // Only the copy: no temporary file left beside it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path), ["letter.txt"])

        // A new list on the same database (Mango reopened) lists it.
        let reopened = ImportWaitingList(root: root, database: db)
        let waiting = try reopened.waiting()
        XCTAssertEqual(waiting.count, 1)
        let row = try XCTUnwrap(waiting.first)
        XCTAssertEqual(row.sha256, file.sha256)
        XCTAssertEqual(row.storedRelativePath, "\(file.sha256)/letter.txt")
        XCTAssertEqual(row.byteCount, file.byteCount)
        XCTAssertEqual(row.text, "A letter nobody recognises")
        XCTAssertEqual(row.textStatus, .text)
        XCTAssertEqual(row.reason, "Not recognised")
        XCTAssertEqual(row.recognisedAs, "Unknown")
        XCTAssertEqual(row.keptAt, Self.now)
        XCTAssertNil(row.importedRunId)
        XCTAssertEqual(reopened.fileURL(row), copy)
        // The original stays where it was.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    /// Review Focus 4.
    func testKeepWithAMissingOriginalSkipsThatFileOnly() throws {
        let kept = try dropped("kept.txt", "Still here")
        let gone = try dropped("gone.pdf", "Moved away after reading")
        try FileManager.default.removeItem(at: gone.url)

        let result = try list.keep([kept, gone], now: Self.now)
        XCTAssertEqual(result.kept.map(\.originalFileName), ["kept.txt"])
        XCTAssertEqual(result.failed.map(\.fileName), ["gone.pdf"])
        XCTAssertFalse(result.failed.first?.reason.isEmpty ?? true)
        XCTAssertEqual(try rows().map(\.originalFileName), ["kept.txt"])
        // No copy (nor folder) for the file that failed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(gone.sha256).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [kept.sha256])
    }

    func testKeepAFileChangedSinceItWasReadFails() throws {
        let file = try dropped("changed.txt", "As read")
        try Data("Changed since".utf8).write(to: file.url)
        let result = try list.keep([file], now: Self.now)
        XCTAssertEqual(result.kept, [])
        XCTAssertEqual(result.failed.map(\.fileName), ["changed.txt"])
        XCTAssertEqual(try rows(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(file.sha256).path))
    }

    /// A root spelled through `/private` (`/private/var/…` for `/var/…`, or `/private/tmp`): a second keep, its folder
    /// not made yet, still finds the folder under the root.
    func testKeepUnderARootSpelledThroughPrivateKeepsEveryFile() throws {
        let spelled = URL(fileURLWithPath: "/private" + folder.path).appendingPathComponent("Waiting", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: spelled.deletingLastPathComponent().path), "No /private spelling here")
        let list = ImportWaitingList(root: spelled, database: db)
        let result = try list.keep([try dropped("one.txt", "First bytes"), try dropped("two.txt", "Second bytes")], now: Self.now)
        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(result.kept.count, 2)
        let again = try list.keep([try dropped("three.txt", "Third bytes")], now: Self.now)
        XCTAssertEqual(again.failed, [])
        XCTAssertEqual(again.kept.count, 1)
    }

    func testKeepingTheSameFileTwiceIsAlreadyWaiting() throws {
        let file = try dropped("twice.txt", "The same bytes")
        _ = try list.keep([file], now: Self.now)
        let again = try list.keep([file], now: Self.now.addingTimeInterval(60))
        XCTAssertEqual(again.kept, [])
        XCTAssertEqual(again.alreadyWaiting, ["twice.txt"])
        XCTAssertEqual(again.failed, [])
        XCTAssertEqual(try rows().count, 1)
        XCTAssertEqual(try rows().first?.keptAt, Self.now)
    }

    func testDiscardRemovesRowAndCopyButNeverTheOriginal() throws {
        let file = try dropped("discard.txt", "To discard")
        let other = try dropped("other.txt", "To keep")
        let kept = try list.keep([file, other], now: Self.now).kept
        let id = try XCTUnwrap(kept.first { $0.originalFileName == "discard.txt" }?.id)
        try list.discard([id])
        XCTAssertEqual(try rows().map(\.originalFileName), ["other.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(file.sha256).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(other.sha256).appendingPathComponent("other.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path), "the user's original is never touched")
    }

    // MARK: Suggested again

    func testSignatureChangesWithANewKindOrRule() throws {
        func signature() throws -> String { try db.read { db in try ImportWaitingList.signature(db: db) } }
        let empty = try signature()
        XCTAssertEqual(empty, try signature(), "the same recognisers, the same signature")

        _ = try db.write { db in try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: Self.now) }
        let withKind = try signature()
        XCTAssertNotEqual(withKind, empty)

        func rule(_ kind: ImportRuleKind, _ key: String, enabled: Bool) throws {
            try db.write { db in
                var rule = ImportRule(kind: kind, matchKey: key, matchLabel: key, actionJSON: #"{"kind":"repairInvoice"}"#,
                                      actionLabel: "Kind: Repair bill", isEnabled: enabled, createdAt: Self.now)
                try rule.insert(db)
            }
        }
        try rule(.documentKind, "nif:500000000", enabled: true)
        let withRule = try signature()
        XCTAssertNotEqual(withRule, withKind)

        // A disabled rule, or one about links, recognises nothing: the signature stays.
        try rule(.documentKind, "nif:500000001", enabled: false)
        try rule(.link, "nif:500000002", enabled: true)
        XCTAssertEqual(try signature(), withRule)

        try rule(.issuer, "nif:500000003", enabled: true)
        XCTAssertNotEqual(try signature(), withRule)
    }

    func testRecheckSuggestsFilesNowRecognised() throws {
        let repair = try dropped("repair.txt", "Reparacao da caldeira")
        let letter = try dropped("letter.txt", "Carta")
        _ = try list.keep([repair, letter], now: Self.now)

        var asked: [String] = []
        let recognise: (ImportFile) -> ImportRecognition = { file in
            asked.append(file.fileName)
            if file.fileName == "repair.txt" {
                XCTAssertEqual(file.text, "Reparacao da caldeira")
                XCTAssertEqual(file.sha256, repair.sha256)
                return ImportRecognition(kind: .evidence(.repairInvoice), confidence: .certain, reason: "Repair")
            }
            return ImportRecognition(kind: .evidence(.other), confidence: .needsReview, reason: "Other")
        }
        let suggested = try list.recheck(recognise: recognise, signature: "one")
        XCTAssertEqual(asked.sorted(), ["letter.txt", "repair.txt"])
        let byName = Dictionary(uniqueKeysWithValues: try rows().map { ($0.originalFileName, $0) })
        XCTAssertEqual(suggested, [try XCTUnwrap(byName["repair.txt"]?.id)])
        XCTAssertEqual(byName["repair.txt"]?.suggestion, "Now recognised as Repair bill")
        XCTAssertNil(byName["letter.txt"]?.suggestion, "Other is no suggestion")
        XCTAssertEqual(Set(try rows().map(\.checkedSignature)), ["one"])

        // The same signature: nothing is read again.
        asked = []
        XCTAssertEqual(try list.recheck(recognise: recognise, signature: "one"), [])
        XCTAssertEqual(asked, [])

        // A new signature: read again; the suggestion it already had isn't new.
        XCTAssertEqual(try list.recheck(recognise: recognise, signature: "two"), [])
        XCTAssertEqual(asked.sorted(), ["letter.txt", "repair.txt"])
        XCTAssertEqual(try rows().first { $0.originalFileName == "repair.txt" }?.suggestion, "Now recognised as Repair bill")
    }

    func testRecheckNamesCustomKindsAndClearsASuggestionNoLongerTrue() throws {
        let file = try dropped("boiler.txt", "Revisao anual")
        _ = try list.keep([file], now: Self.now)
        let custom: (ImportFile) -> ImportRecognition = { _ in ImportRecognition(kind: .customEvidence(.saved(7)), confidence: .certain, reason: "Rule") }
        let names: (ImportKind) -> String = { kind in kind == .customEvidence(.saved(7)) ? "Boiler service" : kind.displayName }
        XCTAssertEqual(try list.recheck(recognise: custom, kindName: names, signature: "a").count, 1)
        XCTAssertEqual(try rows().first?.suggestion, "Now recognised as Boiler service")

        let unknown: (ImportFile) -> ImportRecognition = { _ in ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "Not recognised") }
        XCTAssertEqual(try list.recheck(recognise: unknown, signature: "b"), [])
        XCTAssertNil(try rows().first?.suggestion)
    }

    func testRecheckReadsTheCopyWhenThisDeviceHasNoText() throws {
        let file = try dropped("synced.txt", "Read from the copy")
        _ = try list.keep([file], now: Self.now)
        // As it arrives by sync: the device-local columns at their defaults.
        try db.write { db in
            try db.execute(sql: "UPDATE importWaitingFile SET text = NULL, textStatus = 'unknown', suggestion = NULL, checkedSignature = ''")
        }
        try FileManager.default.removeItem(at: file.url)

        var seen: ImportFile?
        _ = try list.recheck(recognise: { file in
            seen = file
            return ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "Not recognised")
        }, signature: "s")
        XCTAssertEqual(seen?.text, "Read from the copy")
        XCTAssertEqual(seen?.url, root.appendingPathComponent(file.sha256).appendingPathComponent("synced.txt"))
        let row = try XCTUnwrap(try rows().first)
        XCTAssertEqual(row.text, "Read from the copy")
        XCTAssertEqual(row.textStatus, .text)
        XCTAssertEqual(row.checkedSignature, "s")
    }

    func testRecheckWaitsForACopyNotArrivedYet() throws {
        let file = try dropped("later.txt", "Arrives later")
        _ = try list.keep([file], now: Self.now)
        try db.write { db in
            try db.execute(sql: "UPDATE importWaitingFile SET text = NULL, textStatus = 'unknown', checkedSignature = ''")
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(file.sha256))
        var asked = 0
        _ = try list.recheck(recognise: { _ in
            asked += 1
            return ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "")
        }, signature: "s")
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(try rows().first?.checkedSignature, "", "read again once its copy is here")
    }

    // MARK: Imported, undone, purged

    func testImportedRowsLeaveTheListAndComeBackWhenTheRunIsUndone() throws {
        let imported = try dropped("imported.txt", "Imported")
        let stays = try dropped("stays.txt", "Stays")
        _ = try list.keep([imported, stays], now: Self.now)
        let runId = try run(confirmedAt: Self.now)
        try db.write { db in try ImportWaitingList.markImported(db: db, runId: runId, sha256s: [imported.sha256]) }
        XCTAssertEqual(try list.waiting().map(\.originalFileName), ["stays.txt"])
        XCTAssertEqual(try rows().first { $0.originalFileName == "imported.txt" }?.importedRunId, runId)

        try db.write { db in try db.execute(sql: "UPDATE importRun SET undoneAt = ? WHERE id = ?", arguments: [Self.now, runId]) }
        XCTAssertEqual(Set(try list.waiting().map(\.originalFileName)), ["imported.txt", "stays.txt"])
    }

    func testWaitingIsNewestFirst() throws {
        let first = try dropped("first.txt", "First")
        let second = try dropped("second.txt", "Second")
        _ = try list.keep([first], now: Self.now)
        _ = try list.keep([second], now: Self.now.addingTimeInterval(60))
        XCTAssertEqual(try list.waiting().map(\.originalFileName), ["second.txt", "first.txt"])
    }

    func testPurgeRemovesRowsOfStandingRunsAfter30Days() throws {
        let old = try dropped("old.txt", "Imported long ago")
        let undone = try dropped("undone.txt", "Imported long ago, undone")
        let recent = try dropped("recent.txt", "Imported recently")
        let waiting = try dropped("waiting.txt", "Never imported")
        _ = try list.keep([old, undone, recent, waiting], now: Self.now)
        let day: TimeInterval = 86_400
        let oldRun = try run(confirmedAt: Self.now.addingTimeInterval(-31 * day))
        let undoneRun = try run(confirmedAt: Self.now.addingTimeInterval(-31 * day), undone: true)
        let recentRun = try run(confirmedAt: Self.now.addingTimeInterval(-10 * day))
        try db.write { db in
            try ImportWaitingList.markImported(db: db, runId: oldRun, sha256s: [old.sha256])
            try ImportWaitingList.markImported(db: db, runId: undoneRun, sha256s: [undone.sha256])
            try ImportWaitingList.markImported(db: db, runId: recentRun, sha256s: [recent.sha256])
        }

        XCTAssertEqual(try list.purgeImported(now: Self.now), 1)
        XCTAssertEqual(Set(try rows().map(\.originalFileName)), ["undone.txt", "recent.txt", "waiting.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(old.sha256).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(recent.sha256).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.url.path), "the user's original is never touched")
        XCTAssertEqual(try list.purgeImported(now: Self.now), 0)
    }

    // MARK: Sync

    func testWaitingTableSyncsWithoutItsText() throws {
        let table = try XCTUnwrap(SyncSchema.table("importWaitingFile"))
        XCTAssertEqual(table.syncedColumns, ["sha256", "originalFileName", "byteCount", "storedRelativePath", "reason", "recognisedAs", "keptAt", "importedRunId"])
        XCTAssertEqual(table.foreignKeys, ["importedRunId": "importRun"])
        XCTAssertEqual(Set(table.localOnlyColumns), ["text", "textStatus", "suggestion", "checkedSignature"])
        let names = SyncSchema.tables.map(\.name)
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "importRun")), try XCTUnwrap(names.firstIndex(of: "importWaitingFile")))
        XCTAssertEqual(SyncSchema.uniqueKey(table: "importWaitingFile", columns: ["sha256"])?.resolution, .identity)
    }

    func testARowArrivingWithoutItsLocalColumnsIsAccepted() throws {
        // A row as sync inserts it: synced columns only; the device's own columns take their defaults.
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO importWaitingFile(sha256, originalFileName, byteCount, storedRelativePath, reason, recognisedAs, keptAt)
                VALUES ('abc', 'a.pdf', 3, 'abc/a.pdf', 'Not recognised', 'Unknown', ?)
                """, arguments: [Self.now])
        }
        let row = try XCTUnwrap(try rows().first)
        XCTAssertNil(row.text)
        XCTAssertEqual(row.textStatus, .unknown)
        XCTAssertEqual(row.checkedSignature, "")
    }

    // MARK: Fix round 1

    /// I1: a row (arriving by sync) whose stored path leaves the waiting folder, or isn't the
    /// file's `<sha>/<name>`, has no copy here: never read, imported or copied.
    func testAHostileStoredPathReadsAsNoCopy() throws {
        let secret = folder.appendingPathComponent("secret.txt")
        try Data("outside the waiting folder".utf8).write(to: secret)
        let sha = String(repeating: "a", count: 64)
        let hostile = ["../secret.txt", "\(sha)/../../secret.txt", "\(sha)/other.txt", "/etc/hosts"]
        try db.write { db in
            for (i, path) in hostile.enumerated() {
                try db.execute(sql: """
                    INSERT INTO importWaitingFile(sha256, originalFileName, byteCount, storedRelativePath, reason, recognisedAs, keptAt)
                    VALUES (?, 'a.txt', 3, ?, 'Not recognised', 'Unknown', ?)
                    """, arguments: [String(repeating: "\(i)", count: 64), path, Self.now])
            }
            // A name that isn't one plain component.
            try db.execute(sql: """
                INSERT INTO importWaitingFile(sha256, originalFileName, byteCount, storedRelativePath, reason, recognisedAs, keptAt)
                VALUES (?, '../secret.txt', 3, ?, 'Not recognised', 'Unknown', ?)
                """, arguments: [String(repeating: "b", count: 64), "\(String(repeating: "b", count: 64))/../secret.txt", Self.now])
        }
        let rows = try list.waiting()
        XCTAssertEqual(rows.count, 5)
        for row in rows {
            XCTAssertNil(list.fileURL(row), row.storedRelativePath)
            XCTAssertNil(list.setAsideFile(row), row.storedRelativePath)
        }
        var asked = 0
        _ = try list.recheck(recognise: { _ in
            asked += 1
            return ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "")
        }, signature: "s")
        XCTAssertEqual(asked, 0, "nothing outside the waiting folder is read")
    }

    /// I2: a symlinked original: Mango keeps the target's bytes, not a link to it.
    func testKeepCopiesASymlinksTargetNotTheLink() throws {
        let target = try dropped("target.txt", "The real bytes")
        let link = folder.appendingPathComponent("Links/link.txt")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.url)
        var file = target
        file.url = link
        file.fileName = "link.txt"
        XCTAssertEqual(try list.keep([file], now: Self.now).kept.count, 1)
        let copy = root.appendingPathComponent(target.sha256).appendingPathComponent("link.txt")
        let type = try FileManager.default.attributesOfItem(atPath: copy.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
        try FileManager.default.removeItem(at: target.url)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "The real bytes", "still there once the original goes")
    }

    /// M2: kept again under another name (after its run): only the new name's copy stays.
    func testKeepingAgainUnderANewNameLeavesOneCopy() throws {
        let first = try dropped("old name.txt", "Same bytes")
        _ = try list.keep([first], now: Self.now)
        let runId = try run(confirmedAt: Self.now)
        try db.write { db in try ImportWaitingList.markImported(db: db, runId: runId, sha256s: [first.sha256]) }
        var renamed = first
        renamed.fileName = "new name.txt"
        XCTAssertEqual(try list.keep([renamed], now: Self.now).kept.map(\.originalFileName), ["new name.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(first.sha256).path), ["new name.txt"])
        XCTAssertEqual(try list.waiting().first?.storedRelativePath, "\(first.sha256)/new name.txt")
    }

    /// M3: the row can't be written: the copy placed for it goes, even into a folder already there.
    func testAFailedRowWriteLeavesNoCopy() throws {
        let file = try dropped("refused.txt", "No row for me")
        let folder = root.appendingPathComponent(file.sha256, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try db.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER refuseWaiting BEFORE INSERT ON main.importWaitingFile BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        XCTAssertThrowsError(try list.keep([file], now: Self.now))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        XCTAssertEqual(try rows(), [])
    }

    /// M1: a copy folder whose hash has a row again (kept meanwhile) is never removed.
    func testRemovingCopiesSparesAHashKeptAgain() throws {
        let file = try dropped("again.txt", "Kept again")
        let kept = try XCTUnwrap(try list.keep([file], now: Self.now).kept.first)
        // As if discarded, then kept again before its copy was removed.
        list.removeCopies([kept])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(file.sha256).appendingPathComponent("again.txt").path))
    }

    /// M4: a waiting file whose bytes reach the library another way leaves the list (and is
    /// purged 30 days after).
    func testAWaitingFileAlreadyInTheLibraryLeavesTheList() throws {
        let file = try dropped("filed.txt", "Filed elsewhere")
        let other = try dropped("other.txt", "Still waiting")
        _ = try list.keep([file, other], now: Self.now)
        try db.write { db in
            var document = EvidenceDocument(sha256: file.sha256, storedRelativePath: "x/filed.txt", originalFileName: "filed.txt", byteCount: 1,
                                            addedAt: Self.now)
            try document.insert(db)
        }
        XCTAssertEqual(try list.waiting().map(\.originalFileName), ["other.txt"])
        XCTAssertEqual(try list.keep([file], now: Self.now).alreadyWaiting, [], "not waiting: in the library")
        XCTAssertEqual(try list.purgeImported(now: Self.now.addingTimeInterval(10 * 86_400)), 0)
        XCTAssertEqual(try list.purgeImported(now: Self.now.addingTimeInterval(31 * 86_400)), 1)
        XCTAssertEqual(try rows().map(\.originalFileName), ["other.txt"])
    }

    /// M5: discarding and purging delete the rows on the household's other devices too.
    func testDiscardAndPurgeQueueSyncDeletes() throws {
        let discarded = try dropped("discarded.txt", "Discarded")
        let purged = try dropped("purged.txt", "Purged")
        let kept = try list.keep([discarded, purged], now: Self.now).kept
        func pendingKind(_ id: Int64?) throws -> PendingChange.Kind? {
            try db.read { db in try SyncChangeTracker.pending(db: db).first { $0.table == "importWaitingFile" && $0.localId == id }?.kind }
        }
        XCTAssertEqual(try pendingKind(kept[0].id), .insert)
        try list.discard([try XCTUnwrap(kept[0].id)])
        XCTAssertEqual(try pendingKind(kept[0].id), .delete)
        let runId = try run(confirmedAt: Self.now.addingTimeInterval(-31 * 86_400))
        try db.write { db in try ImportWaitingList.markImported(db: db, runId: runId, sha256s: [purged.sha256]) }
        XCTAssertEqual(try list.purgeImported(now: Self.now), 1)
        XCTAssertEqual(try pendingKind(kept[1].id), .delete)
    }
}
