import XCTest
@testable import BudgetCore
import TestSupport

/// Step 10 Task 5: the Downloads tray keeps PDFs only, one per sha256, app-private and out of backups, and empties
/// completely. Local fixtures only.
final class DownloadsTrayTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tray-tests-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func tray(now: @escaping @Sendable () -> Date = Date.init) -> DownloadsTray {
        DownloadsTray(directory: folder.appendingPathComponent("Tray", isDirectory: true), now: now)
    }

    func testNonPDFRefused() throws {
        let tray = tray()
        let html = try WebFixtures.copy("notpdf.pdf")
        XCTAssertThrowsError(try tray.ingest(fileAt: html, suggestedName: "bill.pdf", sourceHost: "example.test")) { error in
            XCTAssertEqual(error as? TrayError, .notAPDF)
        }
        XCTAssertEqual(tray.items(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: html.path), "a refused file is the caller's to remove")
        XCTAssertNotNil(TrayError.notAPDF.errorDescription)
    }

    func testEmptyFileRefused() throws {
        let tray = tray()
        let empty = folder.appendingPathComponent("empty.pdf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: empty)
        XCTAssertThrowsError(try tray.ingest(fileAt: empty, suggestedName: "empty.pdf", sourceHost: nil)) { error in
            XCTAssertEqual(error as? TrayError, .empty)
        }
        XCTAssertEqual(tray.items(), [])
    }

    func testSameHashKeptOnce() throws {
        let tray = tray()
        let first = try tray.ingest(fileAt: WebFixtures.copy("bill.pdf"), suggestedName: "bill.pdf", sourceHost: "example.test")
        let again = try WebFixtures.copy("bill.pdf")
        let second = try tray.ingest(fileAt: again, suggestedName: "bill (1).pdf", sourceHost: "other.test")
        XCTAssertEqual(second, first, "the same PDF is the same item")
        XCTAssertEqual(tray.items().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.path), "the duplicate is deleted")
        let stored = try FileManager.default.contentsOfDirectory(atPath: tray.directory.path).filter { $0.hasSuffix(".pdf") }
        XCTAssertEqual(stored.count, 1)
    }

    func testIngestMovesTheFileIn() throws {
        let tray = tray()
        let source = try WebFixtures.copy("bill.pdf")
        let item = try tray.ingest(fileAt: source, suggestedName: "statement", sourceHost: "example.test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "moved, not copied (a shared file leaves Inbox)")
        XCTAssertEqual(item.fileName, "statement.pdf")
        XCTAssertEqual(item.sourceHost, "example.test")
        XCTAssertEqual(item.byteCount, try Data(contentsOf: tray.fileURL(for: item)).count)
        XCTAssertTrue(try Data(contentsOf: tray.fileURL(for: item)).starts(with: Data("%PDF-".utf8)))
        XCTAssertEqual(item.sha256.count, 64)
    }

    func testIngestSetsProtectionAndBackupExclusion() throws {
        let tray = tray()
        let item = try tray.ingest(fileAt: WebFixtures.copy("bill.pdf"), suggestedName: "bill.pdf", sourceHost: nil)
        for url in [tray.fileURL(for: item), tray.directory, tray.directory.appendingPathComponent(DownloadsTray.indexName)] {
            var url = url
            url.removeAllCachedResourceValues()
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, url.lastPathComponent)
            // The Mac reports no protection class; iOS (the simulator too) does.
            if let protection = values.fileProtection {
                XCTAssertEqual(protection, .completeUntilFirstUserAuthentication, url.lastPathComponent)
            }
        }
    }

    func testItemsNewestFirst() throws {
        let clock = Clock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let tray = tray(now: { clock.next() })
        let older = try tray.ingest(fileAt: WebFixtures.copy("bill.pdf"), suggestedName: "older.pdf", sourceHost: nil)
        let newer = try tray.ingest(fileAt: pdf(containing: "another"), suggestedName: "newer.pdf", sourceHost: nil)
        XCTAssertEqual(tray.items().map(\.id), [newer.id, older.id])
        // Read back by a fresh tray over the same folder (the JSON sidecar).
        XCTAssertEqual(DownloadsTray(directory: tray.directory).items(), [newer, older])
    }

    func testDiscardAndPurgeAllDeleteFiles() throws {
        let tray = tray()
        let one = try tray.ingest(fileAt: WebFixtures.copy("bill.pdf"), suggestedName: "one.pdf", sourceHost: nil)
        let two = try tray.ingest(fileAt: pdf(containing: "two"), suggestedName: "two.pdf", sourceHost: nil)
        tray.discard(one)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tray.fileURL(for: one).path))
        XCTAssertEqual(tray.items(), [two])
        tray.purgeAll()
        XCTAssertEqual(tray.items(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tray.directory.path), "nothing left on disk")
        // Usable again after a purge.
        XCTAssertNoThrow(try tray.ingest(fileAt: WebFixtures.copy("bill.pdf"), suggestedName: "bill.pdf", sourceHost: nil))
    }

    func testDisplayName() {
        XCTAssertEqual(DownloadsTray.displayName("../../etc/statement.PDF"), "statement.PDF")
        XCTAssertEqual(DownloadsTray.displayName(""), "Download.pdf")
        XCTAssertEqual(DownloadsTray.displayName("invoice"), "invoice.pdf")
    }

    // MARK: Helpers

    /// A different (tiny) PDF: starts with the magic, differs in its bytes.
    private func pdf(containing text: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("%PDF-1.4\n% \(text)\n%%EOF\n".utf8).write(to: url)
        return url
    }

    private final class Clock: @unchecked Sendable {
        private var current: Date
        private let lock = NSLock()
        init(start: Date) { current = start }
        func next() -> Date { lock.withLock { current = current.addingTimeInterval(60); return current } }
    }
}
