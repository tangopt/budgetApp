import XCTest
import GRDB
import CryptoKit
@testable import BudgetCore

/// The evidence library (spec 2026-10-16 §3): documents copied into a content-addressed store,
/// linked to transactions and other records, with remembered source folders.
final class EvidenceLibraryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var root: URL!
    private var inbox: URL!
    private var library: EvidenceLibrary!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("EvidenceLibraryTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Evidence", isDirectory: true)
        inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        library = EvidenceLibrary(root: root, database: manager.dbQueue)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A synthetic file in the inbox (never a real document).
    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = inbox.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func sha(_ contents: String) -> String {
        SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// An account, a batch, a category and one transaction to link to.
    private func seedTransaction() throws -> (account: Int64, category: Int64, transaction: Int64) {
        try manager.dbQueue.write { db in
            var account = Account(name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "bbva.xlsx", importedAt: Date())
            try batch.insert(db)
            var category = Category(name: "Lisbon: IMI", type: .expense)
            try category.insert(db)
            var transaction = Transaction(importBatchId: batch.id!, accountId: account.id!, date: Self.date(2025, 5, 2),
                                          rawDescription: "IMI", amountMinorUnits: -31_250, categoryId: category.id,
                                          status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return (account.id!, category.id!, transaction.id!)
        }
    }

    @discardableResult
    private func addTransaction(account: Int64, amount: Int = -5_000) throws -> Int64 {
        try manager.dbQueue.write { db in
            let batch = try ImportBatch.filter(Column("accountId") == account).fetchOne(db)!
            var transaction = Transaction(importBatchId: batch.id!, accountId: account, date: Self.date(2025, 6, 1),
                                          rawDescription: "Other", amountMinorUnits: amount, categoryId: nil,
                                          status: .pendingReview, categorizedBy: .none, fingerprint: UUID().uuidString)
            try transaction.insert(db)
            return transaction.id!
        }
    }

    // MARK: Adding

    func testAddCopiesIntoContentAddressedStoreWithMetadata() throws {
        let source = try file("Nota IMI.PDF", "imi notice 2024")
        let hash = sha("imi notice 2024")
        let metadata = EvidenceMetadata(kind: .imiNotice, docDate: Self.date(2025, 3, 31),
                                        periodStart: Self.date(2024, 1, 1), periodEnd: Self.date(2024, 12, 31),
                                        amountMinorUnits: 93_750, currency: .eur, persons: ["Person A", "Person B"],
                                        canonicalName: "20250331 - Property - IMI notice - Lisbon - 2024", note: "3 instalments")
        let result = try library.add(source, metadata: metadata)

        XCTAssertTrue(result.isNew)
        let document = result.document
        XCTAssertNotNil(document.id)
        XCTAssertEqual(document.sha256, hash)
        XCTAssertEqual(document.storedRelativePath, "\(hash.prefix(2))/\(hash).pdf")
        XCTAssertEqual(document.originalFileName, "Nota IMI.PDF")
        XCTAssertEqual(document.byteCount, 15)
        XCTAssertEqual(document.kind, .imiNotice)
        XCTAssertEqual(document.persons, ["Person A", "Person B"])
        XCTAssertEqual(document.textStatus, .unknown)
        XCTAssertEqual(document.displayName, "20250331 - Property - IMI notice - Lisbon - 2024")

        let stored = library.fileURL(for: document)
        XCTAssertEqual(stored, root.appendingPathComponent(document.storedRelativePath))
        XCTAssertEqual(try String(contentsOf: stored, encoding: .utf8), "imi notice 2024")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the user's file is never moved")

        let fetched = try manager.dbQueue.read { db in try EvidenceDocument.fetchOne(db, key: document.id) }
        XCTAssertEqual(fetched, document)
        // No temporary files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    func testAddingTheSameContentAgainReturnsTheExistingDocument() throws {
        let first = try library.add(try file("a.pdf", "same bytes"), metadata: EvidenceMetadata(kind: .rentReceipt))
        let second = try library.add(try file("copy of a.pdf", "same bytes"), metadata: EvidenceMetadata(kind: .other))

        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.document, first.document)
        XCTAssertEqual(second.document.kind, .rentReceipt, "a duplicate keeps the library's metadata")
        XCTAssertEqual(try manager.dbQueue.read { db in try EvidenceDocument.fetchCount(db) }, 1)
        let shard = root.appendingPathComponent(String(first.document.sha256.prefix(2)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shard.path).count, 1)
    }

    func testFileWithoutExtensionIsStoredByHashAlone() throws {
        let document = try library.add(try file("README", "plain"), metadata: EvidenceMetadata()).document
        XCTAssertEqual(document.storedRelativePath, "\(document.sha256.prefix(2))/\(document.sha256)")
        XCTAssertEqual(document.kind, .other)
        XCTAssertEqual(document.displayName, "README")
    }

    func testAddReusesAnOrphanedStoredFile() throws {
        // A copy left by an earlier add whose database write failed.
        let hash = sha("orphan")
        let shard = root.appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: shard.appendingPathComponent("\(hash).pdf"))

        let result = try library.add(try file("x.pdf", "orphan"), metadata: EvidenceMetadata())
        XCTAssertTrue(result.isNew)
        XCTAssertEqual(try String(contentsOf: library.fileURL(for: result.document), encoding: .utf8), "orphan")
    }

    func testAddRemovesItsCopyWhenTheDatabaseWriteFails() throws {
        let source = try file("y.pdf", "rolled back")
        // Breaks the insert: a source folder id that doesn't exist.
        XCTAssertThrowsError(try library.add(source, metadata: EvidenceMetadata(sourceFolderId: 999)))
        let hash = sha("rolled back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(hash.prefix(2))/\(hash).pdf").path))
    }

    func testSourceDetailsAreRecorded() throws {
        var folder = SourceFolder(path: "/Users/me/Lisboa", bookmark: Data([1, 2, 3]), name: "Lisboa")
        try manager.dbQueue.write { db in try folder.insert(db) }
        let modified = Self.date(2025, 6, 1)
        let document = try library.add(try file("r.pdf", "receipt"), metadata: EvidenceMetadata(
            kind: .condominioReceipt, sourceFolderId: folder.id, sourceRelativePath: "Condominio/2025/r.pdf", sourceModifiedAt: modified)).document
        XCTAssertEqual(document.sourceFolderId, folder.id)
        XCTAssertEqual(document.sourceRelativePath, "Condominio/2025/r.pdf")
        XCTAssertEqual(document.sourceModifiedAt, modified)
        XCTAssertEqual(try library.documents(inSourceFolder: folder.id!).map(\.id), [document.id])

        // Forgetting the folder keeps the document; it just no longer points at the folder.
        _ = try manager.dbQueue.write { db in try SourceFolder.deleteOne(db, key: folder.id) }
        let after = try manager.dbQueue.read { db in try EvidenceDocument.fetchOne(db, key: document.id) }
        XCTAssertNil(after?.sourceFolderId)
        XCTAssertEqual(after?.sourceRelativePath, "Condominio/2025/r.pdf")
    }

    func testSourceFolderPathIsUnique() throws {
        try manager.dbQueue.write { db in
            var first = SourceFolder(path: "/Users/me/Tax", bookmark: nil, name: "Tax")
            try first.insert(db)
            XCTAssertEqual(first.lastScanAt, nil)
            var second = SourceFolder(path: "/Users/me/Tax", bookmark: nil, name: "Tax again")
            XCTAssertThrowsError(try second.insert(db))
        }
    }

    func testLargeFilesHashAcrossChunks() throws {
        var bytes = Data(count: 2_621_440 + 17) // 2.5 MiB and a bit: three 1 MiB chunks
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 11) }
        let url = inbox.appendingPathComponent("big.pdf")
        try bytes.write(to: url)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(try EvidenceLibrary.sha256(of: url), expected)
        let document = try library.add(url, metadata: EvidenceMetadata()).document
        XCTAssertEqual(document.sha256, expected)
        XCTAssertEqual(document.byteCount, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: library.fileURL(for: document)), bytes)
    }

    func testSymbolicLinkAddsTheFileItPointsTo() throws {
        let target = try file("target.pdf", "behind a link")
        let link = inbox.appendingPathComponent("Shortcut.PDF")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let document = try library.add(link, metadata: EvidenceMetadata()).document
        XCTAssertEqual(document.originalFileName, "Shortcut.PDF")
        XCTAssertEqual(document.sha256, sha("behind a link"))
        let stored = library.fileURL(for: document)
        XCTAssertEqual(try String(contentsOf: stored, encoding: .utf8), "behind a link")
        let type = try FileManager.default.attributesOfItem(atPath: stored.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular, "the library stores the bytes, not the link")

        let folderLink = inbox.appendingPathComponent("folder link")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: inbox)
        XCTAssertThrowsError(try library.add(folderLink, metadata: EvidenceMetadata())) { error in
            XCTAssertEqual(error as? EvidenceLibraryError, .notAFile)
        }
    }

    func testHashDescribesTheStoredBytesWhenTheSourceChangesMidAdd() throws {
        let source = try file("changing.pdf", "version one")
        var hooks = EvidenceLibrary.AddHooks()
        hooks.afterCopy = { _ in try Data("version two, longer".utf8).write(to: source) }
        let document = try library.add(source, metadata: EvidenceMetadata(), now: Date(), hooks: hooks).document
        XCTAssertEqual(document.sha256, sha("version one"))
        XCTAssertEqual(document.byteCount, 11)
        XCTAssertEqual(try EvidenceLibrary.sha256(of: library.fileURL(for: document)), document.sha256)
    }

    func testAConcurrentAddOfTheSameContentWins() throws {
        let source = try file("race.pdf", "raced")
        let hash = sha("raced")
        let queue = manager.dbQueue
        var hooks = EvidenceLibrary.AddHooks()
        hooks.beforeInsert = {
            try queue.write { db in
                var other = EvidenceDocument(sha256: hash, storedRelativePath: "\(hash.prefix(2))/\(hash).pdf",
                                             originalFileName: "other.pdf", byteCount: 5, addedAt: Self.date(2025, 1, 1))
                try other.insert(db)
            }
        }
        let result = try library.add(source, metadata: EvidenceMetadata(), now: Date(), hooks: hooks)
        XCTAssertFalse(result.isNew)
        XCTAssertEqual(result.document.originalFileName, "other.pdf")
        XCTAssertEqual(try manager.dbQueue.read { db in try EvidenceDocument.fetchCount(db) }, 1)
        XCTAssertEqual(try String(contentsOf: library.fileURL(for: result.document), encoding: .utf8), "raced", "the stored file is kept")
    }

    func testALeftoverOfTheWrongSizeIsReplaced() throws {
        let hash = sha("good bytes")
        let shard = root.appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        try Data("trunc".utf8).write(to: shard.appendingPathComponent("\(hash).pdf"))

        let document = try library.add(try file("g2.pdf", "good bytes"), metadata: EvidenceMetadata()).document
        XCTAssertEqual(try String(contentsOf: library.fileURL(for: document), encoding: .utf8), "good bytes")
    }

    func testStaleTemporaryCopiesAreCleanedUp() throws {
        let now = Date()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appendingPathComponent(".adding-\(Int(now.timeIntervalSince1970) - 7200)-old")
        let fresh = root.appendingPathComponent(".adding-\(Int(now.timeIntervalSince1970) - 60)-busy")
        let unnamed = root.appendingPathComponent(".adding-garbage")
        for url in [stale, fresh, unnamed] { try Data("x".utf8).write(to: url) }

        try library.add(try file("t2.pdf", "cleanup"), metadata: EvidenceMetadata(), now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unnamed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "an add in progress is left alone")
    }

    func testSourceModifiedAtIsKeptToTheSecond() throws {
        let fractional = Date(timeIntervalSinceReferenceDate: 780_000_000.789)
        let document = try library.add(try file("f.pdf", "fractional"), metadata: EvidenceMetadata(sourceModifiedAt: fractional)).document
        XCTAssertEqual(document.sourceModifiedAt, Date(timeIntervalSinceReferenceDate: 780_000_000))
        let fetched = try manager.dbQueue.read { db in try EvidenceDocument.fetchOne(db, key: document.id) }
        XCTAssertEqual(fetched, document)
    }

    func testLookupByHash() throws {
        let document = try library.add(try file("h.pdf", "hash me"), metadata: EvidenceMetadata()).document
        XCTAssertEqual(try library.document(sha256: sha("hash me")), document)
        XCTAssertNil(try library.document(sha256: sha("other")))
        XCTAssertEqual(try EvidenceLibrary.sha256(of: library.fileURL(for: document)), document.sha256)
    }

    func testDocumentSummariesLeaveOutTheText() throws {
        var first = try library.add(try file("s1.pdf", "first"), metadata: EvidenceMetadata(kind: .rentReceipt), now: Self.date(2025, 1, 1)).document
        first.extractedText = String(repeating: "long text ", count: 1000)
        try manager.dbQueue.write { db in try first.update(db) }
        let second = try library.add(try file("s2.pdf", "second"), metadata: EvidenceMetadata(canonicalName: "Named"), now: Self.date(2025, 2, 1)).document

        let summaries = try library.documentSummaries()
        XCTAssertEqual(summaries.map(\.id), [second.id!, first.id!], "newest added first")
        XCTAssertEqual(summaries.map(\.displayName), ["Named", "s1.pdf"])
        XCTAssertEqual(summaries.last?.kind, .rentReceipt)
        XCTAssertEqual(summaries.last?.sha256, first.sha256)
        let sql = try manager.dbQueue.read { db in try EvidenceDocumentSummary.newestFirst.makePreparedRequest(db).statement.sql }
        XCTAssertFalse(sql.contains("extractedText"))
    }

    // MARK: Links

    func testLinkingDocumentsToRecords() throws {
        let seed = try seedTransaction()
        let notice = try library.add(try file("n.pdf", "notice"), metadata: EvidenceMetadata(kind: .imiNotice, docDate: Self.date(2025, 3, 31))).document
        let proof = try library.add(try file("p.pdf", "proof"), metadata: EvidenceMetadata(kind: .imiPayment, docDate: Self.date(2025, 5, 2))).document

        let link = try library.link(notice.id!, to: .transaction(seed.transaction), role: "notice")
        XCTAssertNotNil(link.id)
        XCTAssertEqual(link.entityType, .transaction)
        XCTAssertEqual(link.role, "notice")
        try library.link(proof.id!, to: .transaction(seed.transaction), role: "payment")
        try library.link(notice.id!, to: .category(seed.category))

        XCTAssertEqual(try library.documents(for: .transaction(seed.transaction)).map(\.id), [notice.id, proof.id], "oldest document date first")
        XCTAssertEqual(try library.documents(for: .category(seed.category)).map(\.id), [notice.id])
        XCTAssertEqual(try library.entities(for: notice.id!).map(\.entity), [.transaction(seed.transaction), .category(seed.category)])
        XCTAssertEqual(try library.linkCounts(.transaction), [seed.transaction: 2])
        XCTAssertEqual(try library.linkCounts(.category), [seed.category: 1])
        XCTAssertEqual(try library.unlinkedDocuments().map(\.id), [])
    }

    func testLinkingTwiceKeepsOneLinkAndUpdatesTheRole() throws {
        let seed = try seedTransaction()
        let document = try library.add(try file("d.pdf", "doc"), metadata: EvidenceMetadata()).document
        let first = try library.link(document.id!, to: .transaction(seed.transaction))
        let second = try library.link(document.id!, to: .transaction(seed.transaction), role: "receipt")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.role, "receipt")
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertEqual(try manager.dbQueue.read { db in try DocumentLink.fetchCount(db) }, 1)

        // The database enforces one link per (document, entity type, entity id).
        try manager.dbQueue.write { db in
            var duplicate = DocumentLink(documentId: document.id!, entity: .transaction(seed.transaction), role: nil)
            XCTAssertThrowsError(try duplicate.insert(db))
        }
    }

    func testRecordsWithoutTablesYetCanBeLinked() throws {
        let document = try library.add(try file("p60.pdf", "p60"), metadata: EvidenceMetadata(kind: .p60, persons: ["Person A"])).document
        try library.link(document.id!, to: EvidenceEntity(type: .taxYear, id: 2025))
        try library.link(document.id!, to: EvidenceEntity(type: .person, id: 1))
        XCTAssertEqual(try library.entities(for: document.id!).map(\.entity.type), [.taxYear, .person])
    }

    func testUnlink() throws {
        let seed = try seedTransaction()
        let document = try library.add(try file("u.pdf", "unlink me"), metadata: EvidenceMetadata()).document
        try library.link(document.id!, to: .transaction(seed.transaction))
        XCTAssertTrue(try library.unlink(document.id!, from: .transaction(seed.transaction)))
        XCTAssertFalse(try library.unlink(document.id!, from: .transaction(seed.transaction)))
        XCTAssertEqual(try library.documents(for: .transaction(seed.transaction)), [])
        XCTAssertEqual(try library.unlinkedDocuments().map(\.id), [document.id])
    }

    func testLinkingAMissingDocumentFails() throws {
        XCTAssertThrowsError(try library.link(42, to: .account(1)))
    }

    func testDeletingARecordRemovesItsLinks() throws {
        let seed = try seedTransaction()
        let document = try library.add(try file("t.pdf", "linked"), metadata: EvidenceMetadata()).document
        try library.link(document.id!, to: .transaction(seed.transaction))
        try library.link(document.id!, to: .account(seed.account))
        try library.link(document.id!, to: .category(seed.category))

        _ = try manager.dbQueue.write { db in try Transaction.deleteOne(db, key: seed.transaction) }
        XCTAssertEqual(try library.entities(for: document.id!).map(\.entity.type), [.account, .category])
        _ = try manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE transaction_ SET categoryId = NULL")
            return try Category.deleteOne(db, key: seed.category)
        }
        XCTAssertEqual(try library.entities(for: document.id!).map(\.entity.type), [.account])
        _ = try manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM importBatch")
            return try Account.deleteOne(db, key: seed.account)
        }
        XCTAssertEqual(try library.entities(for: document.id!), [])
        XCTAssertNotNil(try library.document(sha256: document.sha256), "the document itself stays")
    }

    func testManualEntryReplacedByImportKeepsItsDocuments() throws {
        let seed = try seedTransaction()
        let (manualId, importedId): (Int64, Int64) = try manager.dbQueue.write { db in
            let manual = try ManualTransactions.add(db: db, accountId: seed.account, date: Self.date(2025, 6, 10),
                                                    description: "Condominio", amountMinorUnits: -12_000, categoryId: seed.category, note: nil)
            let batch = try ImportBatch.fetchOne(db)!
            var imported = Transaction(importBatchId: batch.id!, accountId: seed.account, date: Self.date(2025, 6, 11),
                                       rawDescription: "CONDOMINIO", amountMinorUnits: -12_000, categoryId: seed.category,
                                       status: .confirmed, categorizedBy: .manual, fingerprint: UUID().uuidString)
            try imported.insert(db)
            return (manual.id!, imported.id!)
        }
        let document = try library.add(try file("c.pdf", "condominio"), metadata: EvidenceMetadata(kind: .condominioReceipt)).document
        try library.link(document.id!, to: .transaction(manualId), role: "receipt")

        try manager.dbQueue.write { db in try ManualTransactions.replace(db: db, manualId: manualId, with: importedId) }
        XCTAssertEqual(try library.documents(for: .transaction(importedId)).map(\.id), [document.id])
        XCTAssertEqual(try library.entities(for: document.id!).first?.role, "receipt")
    }

    func testRepointMergesIntoAnExistingLink() throws {
        let seed = try seedTransaction()
        let other = try addTransaction(account: seed.account)
        let document = try library.add(try file("m.pdf", "merge"), metadata: EvidenceMetadata()).document
        try library.link(document.id!, to: .transaction(seed.transaction), role: "old")
        try library.link(document.id!, to: .transaction(other), role: "kept")
        try manager.dbQueue.write { db in try EvidenceLinks.repoint(db: db, from: .transaction(seed.transaction), to: .transaction(other)) }
        let links = try library.entities(for: document.id!)
        XCTAssertEqual(links.map(\.entity), [.transaction(other)])
        XCTAssertEqual(links.first?.role, "kept")
    }

    func testLinkingToAMissingRecordFails() throws {
        let document = try library.add(try file("e.pdf", "entity"), metadata: EvidenceMetadata()).document
        for entity in [EvidenceEntity.transaction(77), .account(77), .category(77)] {
            XCTAssertThrowsError(try library.link(document.id!, to: entity)) { error in
                XCTAssertEqual(error as? EvidenceLibraryError, .entityNotFound)
            }
        }
        XCTAssertEqual(try library.entities(for: document.id!), [])
    }

    func testSetRoleSetsAndClears() throws {
        let seed = try seedTransaction()
        let document = try library.add(try file("r2.pdf", "role"), metadata: EvidenceMetadata()).document
        try library.link(document.id!, to: .transaction(seed.transaction), role: "notice")
        XCTAssertTrue(try library.setRole(nil, documentId: document.id!, entity: .transaction(seed.transaction)))
        XCTAssertNil(try library.entities(for: document.id!).first?.role)
        XCTAssertTrue(try library.setRole(" proof ", documentId: document.id!, entity: .transaction(seed.transaction)))
        XCTAssertEqual(try library.entities(for: document.id!).first?.role, "proof")
        XCTAssertFalse(try library.setRole("x", documentId: document.id!, entity: .account(seed.account)))
    }

    // MARK: Removing

    func testRemoveRefusesALinkedDocumentUnlessForced() throws {
        let seed = try seedTransaction()
        let document = try library.add(try file("l.pdf", "linked doc"), metadata: EvidenceMetadata()).document
        try library.link(document.id!, to: .transaction(seed.transaction))
        try library.link(document.id!, to: .account(seed.account))
        let stored = library.fileURL(for: document)

        XCTAssertThrowsError(try library.remove(document.id!)) { error in
            XCTAssertEqual(error as? EvidenceLibraryError, .documentIsLinked(linkCount: 2))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))

        try library.remove(document.id!, force: true)
        XCTAssertNil(try library.document(sha256: document.sha256))
        XCTAssertEqual(try manager.dbQueue.read { db in try DocumentLink.fetchCount(db) }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
    }

    func testRemoveAnUnlinkedDocument() throws {
        let source = try file("z.pdf", "unlinked doc")
        let document = try library.add(source, metadata: EvidenceMetadata()).document
        try library.remove(document.id!)
        XCTAssertNil(try library.document(sha256: document.sha256))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.fileURL(for: document).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the user's file is never touched")
        XCTAssertThrowsError(try library.remove(document.id!)) { error in
            XCTAssertEqual(error as? EvidenceLibraryError, .documentNotFound)
        }
    }

    // MARK: Root

    func testDefaultRootIsInsideTheAppsSupportFolder() {
        let root = EvidenceLibrary.defaultRoot
        XCTAssertEqual(root.lastPathComponent, "Evidence")
        XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "Budget")
    }

    // MARK: Text status

    func testTextStatusRoundTrips() throws {
        var document = try library.add(try file("g.pdf", "glyphs"), metadata: EvidenceMetadata(kind: .mortgageNotice)).document
        document.textStatus = .glyph
        document.extractedText = "Prestação"
        try manager.dbQueue.write { db in try document.update(db) }
        let fetched = try manager.dbQueue.read { db in try EvidenceDocument.fetchOne(db, key: document.id) }
        XCTAssertEqual(fetched?.textStatus, .glyph)
        XCTAssertEqual(fetched?.extractedText, "Prestação")
    }

    // MARK: Adding with analysis

    private static let rentText = "Recibo de Renda Eletrónico N.º 12 Data de emissão: 2025-03-02 Período de renda: 2025-03-01 a 2025-03-31 "
        + "Importância recebida: 1.500,00 €"

    func testAddWithoutAnalysisLeavesTextUnknown() throws {
        let document = try library.add(try file("rent.txt", Self.rentText)).document
        XCTAssertEqual(document.textStatus, .unknown)
        XCTAssertNil(document.extractedText)
        XCTAssertEqual(document.kind, .other)
    }

    func testAddAnalyzingRecordsWhatItFinds() throws {
        let added = try library.addAnalyzing(try file("rent.txt", Self.rentText))
        let stored = try XCTUnwrap(try manager.dbQueue.read { db in try EvidenceDocument.fetchOne(db, key: added.document.id) })
        XCTAssertEqual(stored, added.document)
        XCTAssertEqual(stored.kind, .rentReceipt)
        XCTAssertEqual(stored.textStatus, .text)
        XCTAssertEqual(stored.extractedText, Self.rentText)
        XCTAssertEqual(stored.docDate, Self.date(2025, 3, 2))
        XCTAssertEqual(stored.periodStart, Self.date(2025, 3, 1))
        XCTAssertEqual(stored.periodEnd, Self.date(2025, 3, 31))
        XCTAssertEqual(stored.amountMinorUnits, 150_000)
        XCTAssertEqual(stored.currency, .eur)
    }

    func testCallerMetadataWinsOverAnalysis() throws {
        let metadata = EvidenceMetadata(kind: .bankTransferProof, amountMinorUnits: 1_000, currency: .gbp, note: "checked")
        let document = try library.addAnalyzing(try file("rent.txt", Self.rentText), metadata: metadata).document
        XCTAssertEqual(document.kind, .bankTransferProof)
        XCTAssertEqual(document.amountMinorUnits, 1_000)
        XCTAssertEqual(document.currency, .gbp)
        XCTAssertEqual(document.docDate, Self.date(2025, 3, 2), "unset fields come from the analysis")
        XCTAssertEqual(document.textStatus, .text)
        XCTAssertEqual(document.note, "checked")
    }

    func testAddWithAProvidedAnalysis() throws {
        let analysis = EvidenceAnalysis(metadata: EvidenceMetadata(kind: .imiPayment, docDate: Self.date(2024, 5, 31)),
                                        textStatus: .glyph, extractedText: "IMI")
        let document = try library.add(try file("imi.pdf", "not really a pdf"), analysis: analysis).document
        XCTAssertEqual(document.kind, .imiPayment)
        XCTAssertEqual(document.docDate, Self.date(2024, 5, 31))
        XCTAssertEqual(document.textStatus, .glyph)
        XCTAssertEqual(document.extractedText, "IMI")
    }

    func testAddAnalyzingExistingContentReturnsItUnchanged() throws {
        let first = try library.add(try file("rent.txt", Self.rentText)).document
        let again = try library.addAnalyzing(try file("rent again.txt", Self.rentText))
        XCTAssertFalse(again.isNew)
        XCTAssertEqual(again.document, first)
    }

    func testMetadataCarriesTextStatus() throws {
        let metadata = EvidenceMetadata(kind: .p60, textStatus: .image)
        let document = try library.add(try file("scan.jpg", "jpeg"), metadata: metadata).document
        XCTAssertEqual(document.textStatus, .image)
    }
}

/// Canonical file names: `YYYYMMDD - <Area> - <Type> - <Detail>[ - period][ - amount]` (spec §3).
final class EvidenceNamingTests: XCTestCase {
    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testFullName() {
        let name = EvidenceNaming.canonicalName(date: Self.date(2021, 3, 15), area: "Building Insurance", type: "Premium", detail: "Example Seguros",
                                                period: (Self.date(2021, 3, 1), Self.date(2021, 9, 30)), amountMinorUnits: 12_345, currency: .eur)
        XCTAssertEqual(name, "20210315 - Building Insurance - Premium - Example Seguros - 2021-03 to 2021-09 - €123.45")
    }

    func testMinimalName() {
        XCTAssertEqual(EvidenceNaming.canonicalName(date: Self.date(2025, 1, 31), area: "Tax", type: "UTR letter"),
                       "20250131 - Tax - UTR letter")
    }

    func testMonthAndYearPrecision() {
        XCTAssertEqual(EvidenceNaming.canonicalName(date: Self.date(2016, 1, 15), precision: .month, area: "Letting", type: "ERA Fee Invoice"),
                       "201601 - Letting - ERA Fee Invoice")
        XCTAssertEqual(EvidenceNaming.canonicalName(date: Self.date(2021, 3, 2), precision: .year, area: "Mortgage", type: "Amortisation tracker"),
                       "2021 - Mortgage - Amortisation tracker")
    }

    func testSingleMonthPeriodAndAbsoluteAmount() {
        let name = EvidenceNaming.canonicalName(date: Self.date(2025, 3, 15), area: "Mortgage", type: "Notice", detail: "BBVA",
                                                period: (Self.date(2025, 3, 1), Self.date(2025, 3, 31)), amountMinorUnits: -123_456, currency: .gbp)
        XCTAssertEqual(name, "20250315 - Mortgage - Notice - BBVA - 2025-03 - £1234.56")
    }

    func testBlankPartsAreSkippedAndPartsTrimmed() {
        XCTAssertEqual(EvidenceNaming.canonicalName(date: Self.date(2025, 4, 6), area: " PT IRS ", type: "Liquidação\n", detail: "  "),
                       "20250406 - PT IRS - Liquidação")
    }

    func testAmountWithoutCurrencyIsLeftOut() {
        XCTAssertEqual(EvidenceNaming.canonicalName(date: Self.date(2025, 4, 6), area: "A", type: "B", amountMinorUnits: 100, currency: nil),
                       "20250406 - A - B")
    }

    func testFileNameIsSafeOnDisk() {
        XCTAssertEqual(EvidenceNaming.fileName(canonicalName: "20251130 - Tax - Tax code letter - 2025/26", fileExtension: "PDF"),
                       "20251130 - Tax - Tax code letter - 2025:26.pdf")
        XCTAssertEqual(EvidenceNaming.fileName(canonicalName: "x", fileExtension: ""), "x")
    }
}
