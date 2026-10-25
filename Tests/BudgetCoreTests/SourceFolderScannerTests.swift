import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Source folders and scans (spec 2026-10-16 §3), on synthetic files in temporary folders.
final class SourceFolderScannerTests: XCTestCase {
    private var manager: DatabaseManager!
    private var base: URL!
    private var folderURL: URL!
    private var library: EvidenceLibrary!
    private var scanner: SourceFolderScanner!

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("SourceFolderScannerTests-\(UUID().uuidString)", isDirectory: true)
        folderURL = base.appendingPathComponent("Lisboa", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: base.appendingPathComponent("Evidence", isDirectory: true), database: manager.dbQueue)
        scanner = SourceFolderScanner(library: library)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @discardableResult
    private func write(_ relativePath: String, _ contents: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? folderURL).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func sourceFiles() throws -> [SourceFile] {
        try manager.dbQueue.read { db in try SourceFile.order(Column("relativePath")).fetchAll(db) }
    }

    private func folder() throws -> SourceFolder {
        try XCTUnwrap(try scanner.sourceFolders().first)
    }

    private static let rentText = "Recibo de Renda Eletrónico N.º 12 Data de emissão: 2025-03-02 Período de renda: 2025-03-01 a 2025-03-31 "
        + "Importância recebida: 1.500,00 €"

    // MARK: Registering

    func testRegisterStoresBookmarkThatResolves() throws {
        let registered = try scanner.register(folderURL)
        XCTAssertEqual(registered.name, "Lisboa")
        XCTAssertEqual(registered.path, folderURL.standardizedFileURL.path)
        XCTAssertNotNil(registered.bookmark)

        let resolved = try scanner.resolve(registered)
        XCTAssertEqual(resolved.url.resolvingSymlinksInPath().path, folderURL.resolvingSymlinksInPath().path)
        XCTAssertFalse(resolved.bookmarkWasRefreshed)

        // Registering again updates, doesn't duplicate.
        let again = try scanner.register(folderURL)
        XCTAssertEqual(again.id, registered.id)
        XCTAssertEqual(try scanner.sourceFolders().count, 1)
    }

    func testRegisterRefusesFiles() throws {
        let file = try write("a.txt", "a")
        XCTAssertThrowsError(try scanner.register(file)) { XCTAssertEqual($0 as? SourceFolderError, .notAFolder) }
    }

    func testResolveFollowsAMovedFolderAndSavesItsPath() throws {
        let registered = try scanner.register(folderURL)
        let moved = base.appendingPathComponent("Lisboa (moved)", isDirectory: true)
        try FileManager.default.moveItem(at: folderURL, to: moved)

        let resolved = try scanner.resolve(registered)
        XCTAssertEqual(resolved.url.resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path)
        XCTAssertEqual(try folder().path, resolved.folder.path)
        XCTAssertEqual(resolved.folder.path, resolved.url.standardizedFileURL.path)
    }

    func testResolveWithoutBookmarkUsesPathAndCreatesOne() throws {
        var registered = try scanner.register(folderURL)
        registered.bookmark = nil
        try manager.dbQueue.write { db in try registered.update(db) }

        let resolved = try scanner.resolve(registered)
        XCTAssertTrue(resolved.bookmarkWasRefreshed)
        XCTAssertNotNil(try folder().bookmark)
    }

    func testUnavailableFolderThrows() throws {
        let registered = try scanner.register(folderURL)
        try FileManager.default.removeItem(at: folderURL)
        XCTAssertThrowsError(try scanner.scan(registered)) {
            XCTAssertEqual($0 as? SourceFolderError, .unavailable(path: registered.path))
        }
    }

    func testRemoveFolderForgetsScansButKeepsDocuments() throws {
        try write("rent.txt", Self.rentText)
        let registered = try scanner.register(folderURL)
        let result = try scanner.scan(registered)
        let added = try scanner.addToLibrary(try XCTUnwrap(result.new.first), from: result.folder)

        try scanner.removeSourceFolder(try XCTUnwrap(registered.id))
        XCTAssertTrue(try scanner.sourceFolders().isEmpty)
        XCTAssertTrue(try sourceFiles().isEmpty)
        let document = try XCTUnwrap(try library.document(sha256: added.document.sha256))
        XCTAssertNil(document.sourceFolderId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(for: document).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("rent.txt").path))
    }

    // MARK: Scanning

    func testFirstScanSortsFilesAndIgnoresClutter() throws {
        try write("rent.txt", Self.rentText)
        try write("2025/notes.csv", "a,b\n1,2")
        try write(".hidden.txt", "hidden")
        try write(".DS_Store", "ds")
        try write("~$Contract.docx", "lock")
        try write(".git/config", "x")
        try write("2025/.Statement.pdf.icloud", "placeholder")
        try FileManager.default.createSymbolicLink(at: folderURL.appendingPathComponent("link.txt"),
                                                   withDestinationURL: folderURL.appendingPathComponent("rent.txt"))
        let registered = try scanner.register(folderURL)

        let result = try scanner.scan(registered, now: Self.date(2026, 10, 16))

        XCTAssertEqual(result.new.map(\.relativePath), ["2025/notes.csv", "rent.txt"])
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertTrue(result.inLibrary.isEmpty)
        XCTAssertEqual(result.notDownloaded, ["2025/Statement.pdf"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: result.ignored.map { ($0.relativePath, $0.reason) }), [
            ".hidden.txt": .hidden, ".DS_Store": .systemFile, "~$Contract.docx": .officeLock, ".git": .hidden, "link.txt": .alias
        ])

        let rent = try XCTUnwrap(result.new.first { $0.relativePath == "rent.txt" })
        XCTAssertEqual(rent.analysis?.metadata.kind, .rentReceipt)
        XCTAssertEqual(rent.analysis?.textStatus, .text)
        XCTAssertEqual(rent.analysis?.metadata.amountMinorUnits, 150_000)

        XCTAssertEqual(try sourceFiles().map(\.relativePath), ["2025/notes.csv", "rent.txt"])
        XCTAssertEqual(try folder().lastScanAt, Self.date(2026, 10, 16))
        XCTAssertEqual(result.folder.lastScanAt, Self.date(2026, 10, 16))
    }

    func testScanLeavesTheFolderUntouched() throws {
        let rent = try write("rent.txt", Self.rentText)
        try setModified(rent, Self.date(2025, 3, 2))
        let before = try FileManager.default.contentsOfDirectory(atPath: folderURL.path).sorted()
        let registered = try scanner.register(folderURL)
        _ = try scanner.scan(registered)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folderURL.path).sorted(), before)
        XCTAssertEqual(try rent.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Self.date(2025, 3, 2))
        XCTAssertEqual(try String(contentsOf: rent, encoding: .utf8), Self.rentText)
    }

    func testRescanIsIdempotent() throws {
        try write("rent.txt", Self.rentText)
        try write("other.txt", "something else entirely, of no particular kind")
        let registered = try scanner.register(folderURL)

        let first = try scanner.scan(registered, now: Self.date(2026, 10, 16))
        let rows = try sourceFiles()
        let second = try scanner.scan(try folder(), now: Self.date(2026, 10, 17))

        XCTAssertEqual(second.new.map(\.relativePath), first.new.map(\.relativePath))
        XCTAssertEqual(second.new.map(\.sha256), first.new.map(\.sha256))
        XCTAssertEqual(second.new.map(\.analysis), first.new.map(\.analysis))
        XCTAssertTrue(second.changed.isEmpty && second.missing.isEmpty && second.inLibrary.isEmpty)
        let rowsAfter = try sourceFiles()
        XCTAssertEqual(rowsAfter.map(\.id), rows.map(\.id))
        XCTAssertEqual(rowsAfter.map(\.sha256), rows.map(\.sha256))
        XCTAssertEqual(rowsAfter.map(\.lastSeenAt), [Self.date(2026, 10, 17), Self.date(2026, 10, 17)])
    }

    func testChangedFileIsReportedOnceThenPending() throws {
        let file = try write("rent.txt", Self.rentText)
        try setModified(file, Self.date(2025, 3, 2))
        let registered = try scanner.register(folderURL)
        let first = try scanner.scan(registered)
        let added = try scanner.addToLibrary(try XCTUnwrap(first.new.first), from: first.folder)

        try write("rent.txt", Self.rentText + " (corrected)")
        let second = try scanner.scan(try folder(), now: Self.date(2026, 10, 17))
        XCTAssertEqual(second.changed.map(\.relativePath), ["rent.txt"])
        XCTAssertEqual(second.changed.first?.previousDocumentId, added.document.id)
        XCTAssertEqual(second.changed.first?.previousSha256, added.document.sha256)
        XCTAssertEqual(second.changed.first?.changeDetectedAt, Self.date(2026, 10, 17))
        XCTAssertNil(second.changed.first?.documentId)
        XCTAssertNotNil(second.changed.first?.analysis)
        XCTAssertTrue(second.new.isEmpty)

        // Pending until acknowledged, across rescans.
        let third = try scanner.scan(try folder(), now: Self.date(2026, 10, 18))
        XCTAssertEqual(third.changed.map(\.relativePath), ["rent.txt"])
        XCTAssertEqual(third.changed.first?.changeDetectedAt, Self.date(2026, 10, 17))
        XCTAssertTrue(third.new.isEmpty)
        let id = try XCTUnwrap(registered.id)
        let pending = try scanner.pendingChanges(inFolder: id)
        XCTAssertEqual(pending.map(\.relativePath), ["rent.txt"])
        XCTAssertEqual(pending.first?.previousDocumentId, added.document.id)
        XCTAssertEqual(try scanner.summaries()[id]?.changedCount, 1)

        XCTAssertTrue(try scanner.acknowledgeChange(folderId: id, relativePath: "rent.txt"))
        XCTAssertFalse(try scanner.acknowledgeChange(folderId: id, relativePath: "rent.txt"))
        XCTAssertTrue(try scanner.pendingChanges(inFolder: id).isEmpty)
        let fourth = try scanner.scan(try folder())
        XCTAssertTrue(fourth.changed.isEmpty)
        XCTAssertEqual(fourth.new.map(\.relativePath), ["rent.txt"])
        XCTAssertEqual(try scanner.summaries()[id]?.changedCount, 0)
    }

    func testChangingAgainKeepsTheOriginalAndRevertingClearsIt() throws {
        let file = try write("a.txt", "original")
        let registered = try scanner.register(folderURL)
        let first = try scanner.scan(registered)
        let originalHash = try XCTUnwrap(first.new.first?.sha256)

        try write("a.txt", "second version")
        try setModified(file, Self.date(2025, 1, 2))
        _ = try scanner.scan(try folder(), now: Self.date(2026, 10, 17))
        try write("a.txt", "third version!")
        try setModified(file, Self.date(2025, 1, 3))
        let third = try scanner.scan(try folder(), now: Self.date(2026, 10, 18))
        XCTAssertEqual(third.changed.first?.previousSha256, originalHash)
        XCTAssertEqual(third.changed.first?.changeDetectedAt, Self.date(2026, 10, 17))

        try write("a.txt", "original")
        try setModified(file, Self.date(2025, 1, 4))
        let reverted = try scanner.scan(try folder())
        XCTAssertTrue(reverted.changed.isEmpty)
        XCTAssertEqual(reverted.new.map(\.relativePath), ["a.txt"])
        XCTAssertTrue(try scanner.pendingChanges(inFolder: try XCTUnwrap(registered.id)).isEmpty)
    }

    func testFilesNotReadThisTimeAreNotMissing() throws {
        try write("cloud.txt", "cloud")
        let locked = try write("locked.txt", "locked")
        try write("linked.txt", "linked")
        try write("target.txt", "target")
        let registered = try scanner.register(folderURL)
        _ = try scanner.scan(registered, now: Self.date(2026, 10, 16))

        // Evicted to iCloud, unreadable (changed, so it's reread), replaced by a link.
        try FileManager.default.removeItem(at: folderURL.appendingPathComponent("cloud.txt"))
        try write(".cloud.txt.icloud", "placeholder")
        try write("locked.txt", "locked, longer now")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        try FileManager.default.removeItem(at: folderURL.appendingPathComponent("linked.txt"))
        try FileManager.default.createSymbolicLink(at: folderURL.appendingPathComponent("linked.txt"),
                                                   withDestinationURL: folderURL.appendingPathComponent("target.txt"))

        let second = try scanner.scan(try folder(), now: Self.date(2026, 10, 17))
        XCTAssertEqual(second.notDownloaded, ["cloud.txt"])
        XCTAssertEqual(second.unreadable.map(\.relativePath), ["locked.txt"])
        XCTAssertEqual(second.ignored.map(\.relativePath), ["linked.txt"])
        XCTAssertTrue(second.missing.isEmpty)
        let summary = try XCTUnwrap(try scanner.summaries()[try XCTUnwrap(registered.id)])
        XCTAssertEqual(summary.missingCount, 0)
        XCTAssertEqual(try sourceFiles().map(\.lastSeenAt), Array(repeating: Self.date(2026, 10, 17), count: 4))
    }

    func testOnlyNotDownloadedCountsAsNotDownloaded() {
        typealias Scanner = SourceFolderScanner
        XCTAssertTrue(Scanner.isNotDownloaded(isUbiquitous: true, status: .notDownloaded, isDataless: false))
        XCTAssertFalse(Scanner.isNotDownloaded(isUbiquitous: true, status: .downloaded, isDataless: false))
        XCTAssertFalse(Scanner.isNotDownloaded(isUbiquitous: true, status: .current, isDataless: false))
        XCTAssertFalse(Scanner.isNotDownloaded(isUbiquitous: false, status: nil, isDataless: false))
        XCTAssertTrue(Scanner.isNotDownloaded(isUbiquitous: nil, status: nil, isDataless: true))
    }

    func testUnchangedSizeAndDateAreNotRehashed() throws {
        let file = try write("a.txt", "aaaa")
        try setModified(file, Self.date(2025, 1, 1))
        let registered = try scanner.register(folderURL)
        let first = try scanner.scan(registered)

        // Same size and date, different bytes: trusted as unchanged (not reread).
        try write("a.txt", "bbbb")
        try setModified(file, Self.date(2025, 1, 1))
        let second = try scanner.scan(try folder())
        XCTAssertTrue(second.changed.isEmpty)
        XCTAssertEqual(second.new.first?.sha256, first.new.first?.sha256)

        // A touched date with the same bytes is rehashed and found unchanged.
        try write("b.txt", "bbbb")
        try setModified(file, Self.date(2025, 1, 2))
        let third = try scanner.scan(try folder())
        XCTAssertEqual(third.changed.map(\.relativePath), ["a.txt"], "content differs from the recorded hash")
    }

    func testMissingFilesAreReportedAndKept() throws {
        let file = try write("rent.txt", Self.rentText)
        try write("keep.txt", "keep")
        let registered = try scanner.register(folderURL)
        _ = try scanner.scan(registered)

        try FileManager.default.removeItem(at: file)
        let second = try scanner.scan(try folder())
        XCTAssertEqual(second.missing.map(\.relativePath), ["rent.txt"])
        XCTAssertEqual(second.new.map(\.relativePath), ["keep.txt"])
        let third = try scanner.scan(try folder())
        XCTAssertEqual(third.missing.map(\.relativePath), ["rent.txt"])
        XCTAssertEqual(try sourceFiles().count, 2)

        let summary = try XCTUnwrap(try scanner.summaries()[try XCTUnwrap(registered.id)])
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertEqual(summary.missingCount, 1)
        XCTAssertEqual(summary.inLibraryCount, 0)
    }

    func testFilesAlreadyInTheLibraryAreRecognisedByContent() throws {
        let inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        let original = try write("Recibo.txt", Self.rentText, in: inbox)
        let added = try library.add(original)
        try write("2025/rent copy.txt", Self.rentText)
        try write("rent.txt", Self.rentText)
        let registered = try scanner.register(folderURL)

        let result = try scanner.scan(registered)
        XCTAssertEqual(result.inLibrary.map(\.relativePath), ["2025/rent copy.txt", "rent.txt"])
        XCTAssertEqual(Set(result.inLibrary.map(\.documentId)), [added.document.id])
        XCTAssertTrue(result.inLibrary.allSatisfy { $0.analysis == nil }, "content in the library isn't reanalysed")
        XCTAssertTrue(result.new.isEmpty)
        XCTAssertEqual(try sourceFiles().map(\.documentId), [added.document.id, added.document.id])

        let summary = try XCTUnwrap(try scanner.summaries()[try XCTUnwrap(registered.id)])
        XCTAssertEqual(summary.fileCount, 2)
        XCTAssertEqual(summary.inLibraryCount, 2)
    }

    func testAddToLibraryRecordsSourceAndAnalysis() throws {
        let file = try write("2025/rent.txt", Self.rentText)
        try setModified(file, Self.date(2025, 3, 2))
        let registered = try scanner.register(folderURL)
        let result = try scanner.scan(registered)

        let added = try scanner.addToLibrary(try XCTUnwrap(result.new.first), from: result.folder)
        XCTAssertTrue(added.isNew)
        let document = added.document
        XCTAssertEqual(document.sourceFolderId, registered.id)
        XCTAssertEqual(document.sourceRelativePath, "2025/rent.txt")
        XCTAssertEqual(document.sourceModifiedAt, Self.date(2025, 3, 2))
        XCTAssertEqual(document.kind, .rentReceipt)
        XCTAssertEqual(document.textStatus, .text)
        XCTAssertEqual(document.amountMinorUnits, 150_000)
        XCTAssertEqual(document.currency, .eur)
        XCTAssertEqual(document.periodStart, Self.date(2025, 3, 1))
        XCTAssertNotNil(document.extractedText)
        XCTAssertEqual(try sourceFiles().first?.documentId, document.id)

        let rescan = try scanner.scan(try folder())
        XCTAssertEqual(rescan.inLibrary.map(\.relativePath), ["2025/rent.txt"])
    }

    func testNewFilesGetTransactionSuggestions() throws {
        let transactionId: Int64 = try manager.dbQueue.write { db in
            var account = Account(name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bbva.xlsx", importedAt: Date())
            try batch.insert(db)
            for (day, amount) in [(1, 150_000), (15, -2_000)] {
                var transaction = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.date(2025, 3, day),
                                              rawDescription: "TRF RENDA MARCO", amountMinorUnits: amount, categoryId: nil,
                                              status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
                try transaction.insert(db)
            }
            // Far away in time: never a candidate.
            var old = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.date(2019, 3, 1),
                                  rawDescription: "TRF RENDA", amountMinorUnits: 150_000, categoryId: nil,
                                  status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try old.insert(db)
            return try Transaction.filter(Column("date") == Self.date(2025, 3, 1)).fetchOne(db)!.id!
        }
        try write("rent.txt", Self.rentText)
        let result = try scanner.scan(try scanner.register(folderURL))
        XCTAssertEqual(result.new.first?.suggestions.first?.transactionId, transactionId)
        XCTAssertEqual(result.new.first?.suggestions.count, 1)

        let unanalysed = try scanner.scan(try folder(), options: .init(analyzeNewFiles: false))
        XCTAssertNil(unanalysed.new.first?.analysis)
        XCTAssertEqual(unanalysed.new.first?.suggestions, [])
    }

    func testScansThousandsOfFiles() throws {
        for index in 0..<2_500 { try write("\(index % 25)/file \(index).txt", "Synthetic receipt \(index) total 12,34 €") }
        let registered = try scanner.register(folderURL)
        let start = Date()
        let first = try scanner.scan(registered)
        let second = try scanner.scan(try folder())
        XCTAssertEqual(first.new.count, 2_500)
        XCTAssertEqual(second.new.count, 2_500)
        XCTAssertEqual(try sourceFiles().count, 2_500)
        XCTAssertLessThan(Date().timeIntervalSince(start), 60)
    }

    func testProgressIsReported() throws {
        for index in 0..<5 { try write("f\(index).txt", "file \(index)") }
        let registered = try scanner.register(folderURL)
        let updates = Locked<[SourceFolderScanner.Progress]>([])
        _ = try scanner.scan(registered) { update in updates.mutate { $0.append(update) } }
        let reading = updates.value.filter { $0.phase == .reading }
        XCTAssertEqual(reading.last?.completed, reading.last?.total)
        XCTAssertGreaterThanOrEqual(reading.last?.total ?? 0, 5)
        XCTAssertTrue(reading.contains { $0.currentPath == "f2.txt" })
    }

    func testCancelledScanRecordsNothing() async throws {
        for index in 0..<5 { try write("f\(index).txt", "file \(index)") }
        let registered = try scanner.register(folderURL)
        let scanner = self.scanner!
        let task = Task.detached {
            try scanner.scan(registered) { update in
                if update.phase == .reading && update.completed == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(try sourceFiles().isEmpty)
        XCTAssertNil(try folder().lastScanAt)
    }
}

/// A value shared with `@Sendable` callbacks in tests.
final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
