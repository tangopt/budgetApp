import XCTest
import Observation
import GRDB
@testable import BudgetCore
import struct BudgetCore.Transaction
import BudgetDemo
@testable import MangoUI
import TestSupport

@MainActor
final class DocumentPanelModelTests: XCTestCase {
    private func demo() throws -> DatabaseQueue { try TestDatabase.demo() }

    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func insert(_ db: Database, name: String, kind: DocumentKind = .other, docDate: Date? = nil, periodStart: Date? = nil,
                        periodEnd: Date? = nil, amount: Int? = nil, currency: Currency? = nil, persons: [String] = []) throws -> Int64 {
        var document = EvidenceDocument(sha256: UUID().uuidString, storedRelativePath: "ab/\(name).pdf", originalFileName: "\(name).pdf",
                                        byteCount: 10, kind: kind, docDate: docDate, periodStart: periodStart, periodEnd: periodEnd,
                                        amountMinorUnits: amount, currency: currency, persons: persons, addedAt: utc(2026, 1, 1))
        try document.insert(db)
        return document.id!
    }

    private func recentDay(_ ago: Int) -> Date { Calendar.current.date(byAdding: .day, value: -ago, to: Date())! }

    func testPanelShowsWaitingForABillWithNoPayment() throws {
        let db = try demo()
        let id = try db.write { try insert($0, name: "Example Power", kind: .utilityInvoice, docDate: recentDay(3), amount: 6_000, currency: .eur) }
        let details = try db.read { try DocumentPanelDetails.load(db: $0, documentId: id) }
        XCTAssertTrue(details.waiting)
        XCTAssertEqual(DocumentPanelDetails.waitingLine, "Waiting for its payment — Mango links it when the statement arrives")
        let old = try db.write { try insert($0, name: "Old Power", kind: .utilityInvoice, docDate: recentDay(200), amount: 6_000, currency: .eur) }
        let lapsed = try db.read { try DocumentPanelDetails.load(db: $0, documentId: old) }
        XCTAssertFalse(lapsed.waiting, "an expired one is an ordinary unlinked document")
        let note = try db.write { try insert($0, name: "Note", kind: .other, docDate: recentDay(3)) }
        let plain = try db.read { try DocumentPanelDetails.load(db: $0, documentId: note) }
        XCTAssertFalse(plain.waiting)
    }

    func testPanelNotWaitingOnceLinked() throws {
        let db = try demo()
        let id = try db.write { db -> Int64 in
            let id = try insert(db, name: "Example Power", kind: .utilityInvoice, docDate: recentDay(3), amount: 6_000, currency: .eur)
            let transaction = try XCTUnwrap(try Transaction.fetchOne(db))
            try EvidenceLinks.link(db: db, documentId: id, to: .transaction(transaction.id!))
            return id
        }
        let details = try db.read { try DocumentPanelDetails.load(db: $0, documentId: id) }
        XCTAssertFalse(details.waiting)
    }

    func testDetailsOmitMissingFields() throws {
        let db = try TestDatabase.migrated()
        let id = try db.write { try self.insert($0, name: "bare") }
        let details = try db.read { try DocumentPanelDetails.load(db: $0, documentId: id) }
        XCTAssertEqual(details, DocumentPanelDetails(kind: DocumentKind.other.displayName, from: nil, period: nil, amount: nil, date: nil, linkedTo: nil))
        XCTAssertEqual(details.rows.map(\.label), ["Kind"])
    }

    func testAmountAndDateFormatted() throws {
        let db = try TestDatabase.migrated()
        let id = try db.write {
            try self.insert($0, name: "full", docDate: self.utc(2026, 3, 5), periodStart: self.utc(2026, 4, 6), periodEnd: self.utc(2026, 5, 5),
                            amount: 123_456, currency: .gbp, persons: ["Ana", "Rui"])
        }
        let eur = try db.write { try self.insert($0, name: "eur", amount: 5_000, currency: .eur) }
        let details = try db.read { try DocumentPanelDetails.load(db: $0, documentId: id) }
        XCTAssertEqual(details.amount, "£1,234.56")
        XCTAssertEqual(details.date, "5 Mar 2026".unbroken)
        XCTAssertEqual(details.period, "6 Apr 2026 – 5 May 2026".unbroken)
        XCTAssertEqual(details.from, "Ana, Rui")
        XCTAssertFalse(details.date!.contains(" "))
        XCTAssertFalse(details.period!.contains(" "))
        XCTAssertEqual(try db.read { try DocumentPanelDetails.load(db: $0, documentId: eur) }.amount, "€50.00")
        XCTAssertEqual(details.rows.map(\.label), ["Kind", "From", "Period", "Amount", "Date"])
    }

    func testLinkedToNamesTheOwner() async throws {
        let db = try demo()
        let (id, expected) = try await db.read { db -> (Int64, [String]) in
            for document in try EvidenceDocumentSummary.newestFirst.fetchAll(db) {
                let links = try EvidenceLinks.links(db: db, for: document.id)
                if !links.isEmpty {
                    return (document.id, try links.map { try EvidenceLinkTitles.line(db: db, entity: $0.entity).title })
                }
            }
            return (0, [])
        }
        XCTAssertNotEqual(id, 0, "the demo has a linked document")
        let details = try await db.read { try DocumentPanelDetails.load(db: $0, documentId: id) }
        XCTAssertEqual(details.linkedTo, expected.joined(separator: "\n"))
        let unlinked = try await db.read { try EvidenceLinks.unlinkedDocuments(db: $0) }.compactMap(\.id).first
        if let unlinked {
            let other = try await db.read { try DocumentPanelDetails.load(db: $0, documentId: unlinked) }
            XCTAssertNil(other.linkedTo)
        }
    }

    func testPanelWidthIs380InLandscapeAndPortrait() {
        // Detail-column widths: portrait without and with the sidebar, landscape on the 11" and the 13".
        for width in [514.0, 834.0, 874.0, 1056.0] {
            XCTAssertEqual(DocumentPanelLayout.panelWidth(containerWidth: width), 380)
            XCTAssertGreaterThanOrEqual(DocumentPanelLayout.contentWidth(containerWidth: width), 420)
        }
        XCTAssertEqual(DocumentPanelLayout.placement(containerWidth: 874), .beside)
        XCTAssertEqual(DocumentPanelLayout.placement(containerWidth: 834), .beside)
        XCTAssertEqual(DocumentPanelLayout.placement(containerWidth: 514), .overlay)
        XCTAssertEqual(DocumentPanelLayout.contentWidth(containerWidth: 874), 494)
    }

    private func receiptId(_ db: DatabaseQueue) throws -> Int64 {
        try db.write { try insert($0, name: "Receipt", kind: .other) }
    }

    func testAStalledDownloadEndsInAFailureWithRetryInsteadOfSpinningForEver() async throws {
        let db = try demo()
        let id = try receiptId(db)
        let attempts = Counter()
        let stall = DocumentPanelSource(dbQueue: db, open: { _ in
            await attempts.bump()
            try await Task.sleep(for: .seconds(3600))
            throw PadDocumentNotOnDevice()
        })
        let model = DocumentPanelModel(documentId: id, source: stall, timeout: .milliseconds(150))
        await model.load()
        XCTAssertEqual(model.file, .failed(PadDocumentsModel.timedOutCopy))
        await model.retry()
        XCTAssertEqual(model.file, .failed(PadDocumentsModel.timedOutCopy))
        let count = await attempts.count
        XCTAssertEqual(count, 2, "Try again asks again")
    }

    func testADownloadThatAnswersInTimeIsReady() async throws {
        let db = try demo()
        let id = try receiptId(db)
        let url = URL(fileURLWithPath: "/tmp/receipt.pdf")
        let model = DocumentPanelModel(documentId: id, source: DocumentPanelSource(dbQueue: db, open: { _ in url }), timeout: .seconds(5))
        await model.load()
        XCTAssertEqual(model.file, .ready(url))
    }

    // MARK: The device hang (TestFlight 1036–1038): "Downloading…" for ever, no title, no details

    /// Root cause: the views keep the model in `@State`, which only sees changes the model reports through
    /// Observation. The panel must hear the title, the details and the file arrive.
    func testTheViewHearsTheLoadFinish() async throws {
        let db = try demo()
        let id = try receiptId(db)
        let url = URL(fileURLWithPath: "/tmp/receipt.pdf")
        let model = DocumentPanelModel(documentId: id, source: DocumentPanelSource(dbQueue: db, open: { _ in url }), timeout: .seconds(5))
        let changed = Flag()
        withObservationTracking {
            _ = model.title
            _ = model.details
            _ = model.file
        } onChange: { changed.set() }
        await model.load()
        XCTAssertEqual(model.file, .ready(url))
        XCTAssertTrue(changed.isSet, "a view drawing the panel is told to draw it again")
    }

    /// A long write holding the database's queue (a sync run applying a pull): the read can't be cancelled, so the
    /// load gives up at its deadline, keeps the screen's title, and Try again reads once the queue is free.
    func testAStalledReadEndsInAFailureWithRetry() async throws {
        let db = try demo()
        let id = try receiptId(db)
        let url = URL(fileURLWithPath: "/tmp/receipt.pdf")
        let opened = Counter()
        let source = DocumentPanelSource(dbQueue: db, open: { _ in await opened.bump(); return url })
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? db.write { _ in
                holding.signal()
                release.wait()
            }
        }
        holding.wait()
        let model = DocumentPanelModel(documentId: id, source: source, title: "Receipt 50", timeout: .milliseconds(200))
        await model.load()
        XCTAssertEqual(model.file, .failed(PadDocumentsModel.timedOutCopy))
        XCTAssertEqual(model.title, "Receipt 50", "the screen's own name stays while the read is held up")
        XCTAssertNil(model.details)
        let none = await opened.count
        XCTAssertEqual(none, 0)

        release.signal()
        await model.retry()
        XCTAssertEqual(model.file, .ready(url))
        XCTAssertNotNil(model.details)
        XCTAssertEqual(model.title, "Receipt.pdf", "the document's own name once read")
    }

    /// A download that never answers: the whole load (read and open) shares one deadline, and the stalled open is
    /// cancelled; Try again asks again and, answered this time, is ready.
    func testACancelledDownloadThenRetryIsReady() async throws {
        let db = try demo()
        let id = try receiptId(db)
        let url = URL(fileURLWithPath: "/tmp/receipt.pdf")
        let attempts = Counter()
        let cancelled = Flag()
        let source = DocumentPanelSource(dbQueue: db, open: { _ in
            await attempts.bump()
            if await attempts.count == 1 {
                do { try await Task.sleep(for: .seconds(3600)) } catch { cancelled.set(); throw error }
            }
            return url
        })
        let model = DocumentPanelModel(documentId: id, source: source, timeout: .milliseconds(200))
        await model.load()
        XCTAssertEqual(model.file, .failed(PadDocumentsModel.timedOutCopy))
        XCTAssertNotNil(model.details, "the read answered before the download stalled")
        for _ in 0..<50 where !cancelled.isSet { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cancelled.isSet, "the stalled download is cancelled, not left running")
        await model.retry()
        XCTAssertEqual(model.file, .ready(url))
    }

    /// Try again after a failed read reads again (it used to return without a word, leaving the failure up).
    func testRetryAfterAMissingDocumentReadsAgain() async throws {
        let db = try TestDatabase.migrated()
        let url = URL(fileURLWithPath: "/tmp/receipt.pdf")
        let model = DocumentPanelModel(documentId: 999, source: DocumentPanelSource(dbQueue: db, open: { _ in url }), timeout: .seconds(5))
        await model.load()
        XCTAssertEqual(model.file, .failed(PadDocumentsModel.failureCopy))
        await model.retry()
        XCTAssertEqual(model.file, .failed(PadDocumentsModel.failureCopy), "ends in a failure again, never left loading")
    }

    /// An older load that answers after a newer one began changes nothing.
    func testALateAnswerFromAnOlderLoadIsIgnored() async throws {
        let db = try demo()
        let id = try receiptId(db)
        let late = URL(fileURLWithPath: "/tmp/late.pdf")
        let fresh = URL(fileURLWithPath: "/tmp/fresh.pdf")
        let attempts = Counter()
        let source = DocumentPanelSource(dbQueue: db, open: { _ in
            await attempts.bump()
            if await attempts.count == 1 {
                try? await Task.sleep(for: .milliseconds(300))
                return late
            }
            return fresh
        })
        let model = DocumentPanelModel(documentId: id, source: source, timeout: .seconds(5))
        let first = Task { await model.load() }
        for _ in 0..<50 { if await attempts.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        await model.retry()
        XCTAssertEqual(model.file, .ready(fresh))
        await first.value
        XCTAssertEqual(model.file, .ready(fresh))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private actor Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}
