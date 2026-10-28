import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import TestSupport

/// The Documents screen's helpers (spec 2026-10-16 §2–§3): editing details, copying links,
/// searching and filtering the library, and documents proposed for a transaction.
final class EvidenceBrowsingTests: XCTestCase {
    private var manager: DatabaseManager!
    private var base: URL!
    private var library: EvidenceLibrary!

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("EvidenceBrowsingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        library = EvidenceLibrary(root: base.appendingPathComponent("Evidence"), database: manager.dbQueue)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// Adds a synthetic text file (never a real document).
    @discardableResult
    private func add(_ name: String, _ contents: String, _ metadata: EvidenceMetadata = EvidenceMetadata()) throws -> EvidenceDocument {
        let url = base.appendingPathComponent("Inbox").appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return try library.add(url, metadata: metadata).document
    }

    /// Two accounts with one transaction each.
    private func seed() throws -> (bbva: Int64, lloyds: Int64, bbvaTransaction: Int64, lloydsTransaction: Int64) {
        try manager.dbQueue.write { db in
            var bbva = Account(name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)
            try bbva.insert(db)
            var lloyds = Account(name: "Lloyds", currency: .gbp, kind: .cash, trackingMode: .imported)
            try lloyds.insert(db)
            var ids: [Int64] = []
            for account in [bbva.id!, lloyds.id!] {
                var batch = ImportBatch(accountId: account, sourceFileName: "f.csv", importedAt: Date())
                try batch.insert(db)
                var transaction = Transaction(importBatchId: batch.id!, accountId: account, date: Self.date(2025, 5, 2),
                                              rawDescription: "PAYMENT", amountMinorUnits: -31_250, categoryId: nil,
                                              status: .confirmed, categorizedBy: .none, fingerprint: UUID().uuidString)
                try transaction.insert(db)
                ids.append(transaction.id!)
            }
            return (bbva.id!, lloyds.id!, ids[0], ids[1])
        }
    }

    // MARK: Kinds

    // MARK: Details

    func testUpdateDetailsSavesTheEditedFields() throws {
        let document = try add("a.pdf", "a")
        var details = EvidenceDocumentDetails(document)
        details.kind = .imiNotice
        details.docDate = Self.date(2025, 3, 31)
        details.periodStart = Self.date(2024, 1, 1)
        details.periodEnd = Self.date(2024, 12, 31)
        details.amountMinorUnits = -31_250
        details.currency = .eur
        details.persons = [" Ana ", "", "Bruno", "ana"]
        details.note = "  "
        details.canonicalName = " 20250331 - Lisbon - IMI - Notice "
        let saved = try library.updateDetails(document.id!, details)
        XCTAssertEqual(saved.kind, .imiNotice)
        XCTAssertEqual(saved.amountMinorUnits, 31_250, "sign-free")
        XCTAssertEqual(saved.persons, ["Ana", "Bruno"])
        XCTAssertNil(saved.note)
        XCTAssertEqual(saved.canonicalName, "20250331 - Lisbon - IMI - Notice")
        XCTAssertEqual(try library.document(id: document.id!), saved)
        XCTAssertEqual(saved.sha256, document.sha256, "the file is untouched")
    }

    func testUpdateDetailsClearsTheCurrencyWithoutAnAmount() throws {
        let document = try add("a.pdf", "a", EvidenceMetadata(amountMinorUnits: 100, currency: .gbp))
        var details = EvidenceDocumentDetails(document)
        details.amountMinorUnits = nil
        XCTAssertNil(try library.updateDetails(document.id!, details).currency)
    }

    func testUpdateDetailsRefusesABackwardsPeriodOrAnAmountWithoutCurrency() throws {
        let document = try add("a.pdf", "a")
        var details = EvidenceDocumentDetails(document)
        details.periodStart = Self.date(2025, 2, 1)
        details.periodEnd = Self.date(2025, 1, 1)
        XCTAssertThrowsError(try library.updateDetails(document.id!, details)) { XCTAssertEqual($0 as? EvidenceDetailsError, .periodEndsBeforeStart) }
        details.periodEnd = nil
        details.amountMinorUnits = 100
        XCTAssertThrowsError(try library.updateDetails(document.id!, details)) { XCTAssertEqual($0 as? EvidenceDetailsError, .amountWithoutCurrency) }
        XCTAssertThrowsError(try library.updateDetails(9_999, EvidenceDocumentDetails())) {
            XCTAssertEqual($0 as? EvidenceLibraryError, .documentNotFound)
        }
    }

    func testChangeKindKeepsEveryOtherDetail() throws {
        let document = try add("advice.pdf", "a", EvidenceMetadata(kind: .bankDebitAdvice, docDate: Self.date(2025, 6, 1),
                                                                     amountMinorUnits: 26_400, currency: .eur))
        var details = EvidenceDocumentDetails(document)
        details.note = "kept"
        details.persons = ["Ana"]
        _ = try library.updateDetails(document.id!, details)
        let changed = try library.changeKind(document.id!, to: .builtIn(.insuranceReceipt))
        XCTAssertEqual(changed.kind, .insuranceReceipt)
        XCTAssertEqual(changed.docDate, Self.date(2025, 6, 1))
        XCTAssertEqual(changed.amountMinorUnits, 26_400)
        XCTAssertEqual(changed.currency, .eur)
        XCTAssertEqual(changed.note, "kept")
        XCTAssertEqual(changed.persons, ["Ana"])
        XCTAssertEqual(try library.document(id: document.id!), changed)
        XCTAssertThrowsError(try library.changeKind(9_999, to: .builtIn(.p60))) {
            XCTAssertEqual($0 as? EvidenceLibraryError, .documentNotFound)
        }
    }

    func testChangeKindToAndFromACustomKind() throws {
        let boiler = try manager.dbQueue.write { db in
            try XCTUnwrap(try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: Date()).id)
        }
        let document = try add("service.pdf", "s", EvidenceMetadata(kind: .bankDebitAdvice, docDate: Self.date(2025, 6, 1)))
        let custom = try library.changeKind(document.id!, to: .custom(boiler))
        XCTAssertEqual(custom.kindRef, .custom(boiler))
        XCTAssertEqual(custom.docDate, Self.date(2025, 6, 1))
        let builtIn = try library.changeKind(document.id!, to: .builtIn(.repairInvoice))
        XCTAssertEqual(builtIn.kind, .repairInvoice)
        XCTAssertNil(builtIn.customKindId)
        XCTAssertEqual(try library.document(id: document.id!)?.kindRef, .builtIn(.repairInvoice))
    }

    /// Change kind… is a Documents edit: a member who may only view Documents is refused, nothing written.
    func testChangeKindIsRefusedForAMemberWhoCanOnlyViewDocuments() throws {
        let document = try add("advice.pdf", "a", EvidenceMetadata(kind: .bankDebitAdvice))
        let member = try manager.dbQueue.write { db -> AccessActor in
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Admin')")
            var admin = AppUser(personId: db.lastInsertedRowID, displayName: "Admin", isAdmin: true, createdAt: Date())
            try admin.insert(db)
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Member')")
            var user = AppUser(personId: db.lastInsertedRowID, displayName: "Member", isAdmin: false, createdAt: Date())
            try user.insert(db)
            var permission = MemberPermission(appUserId: user.id!, area: AccessArea.documents.storageKey, level: .view)
            try permission.insert(db)
            return try AccessActor.load(appUserId: user.id!, db: db)
        }
        XCTAssertThrowsError(try library.changeKind(document.id!, to: .builtIn(.insuranceReceipt), actor: member)) {
            XCTAssertEqual($0 as? AccessDenied, AccessDenied(area: .documents))
        }
        XCTAssertEqual(try library.document(id: document.id!)?.kind, .bankDebitAdvice)
    }

    func testPersonsFromText() {
        XCTAssertEqual(EvidenceDocumentDetails.persons(from: "Ana, Bruno; ; ana"), ["Ana", "Bruno"])
        XCTAssertEqual(EvidenceDocumentDetails.persons(from: "  "), [])
    }

    // MARK: Links

    /// Missing evidence's Unlink on a record the document isn't linked to (a P60 linked to the employment's
    /// income record instead): nothing to unlink, false, its link elsewhere kept.
    func testUnlinkFromARecordTheDocumentIsntLinkedToChangesNothing() throws {
        let ids = try seed()
        let document = try add("p60.pdf", "p", EvidenceMetadata(kind: .p60))
        try library.link(document.id!, to: .transaction(ids.bbvaTransaction))
        XCTAssertFalse(try library.unlink(document.id!, from: .transaction(ids.lloydsTransaction)))
        XCTAssertEqual(try library.entities(for: document.id!).map(\.entity), [.transaction(ids.bbvaTransaction)])
    }

    func testMoveLinksKeepsRolesAndExistingLinksAndEmptiesTheOldVersion() throws {
        let ids = try seed()
        let old = try add("old.pdf", "v1"), new = try add("new.pdf", "v2")
        try library.link(old.id!, to: .transaction(ids.bbvaTransaction), role: "notice")
        try library.link(old.id!, to: .account(ids.bbva))
        try library.link(new.id!, to: .account(ids.bbva), role: "statement")
        XCTAssertEqual(try library.moveLinks(from: old.id!, to: new.id!), 1)
        let links = try library.entities(for: new.id!)
        XCTAssertEqual(Set(links.map(\.entity)), [.transaction(ids.bbvaTransaction), .account(ids.bbva)])
        XCTAssertEqual(links.first { $0.entityType == .transaction }?.role, "notice")
        XCTAssertEqual(links.first { $0.entityType == .account }?.role, "statement", "an existing link wins")
        XCTAssertEqual(try library.entities(for: old.id!), [], "the old version's links moved")
        XCTAssertNotNil(try library.document(id: old.id!), "the old version stays in the library")
        XCTAssertThrowsError(try library.moveLinks(from: new.id!, to: 9_999))
        XCTAssertEqual(try library.entities(for: new.id!).count, 2, "a refused move changes nothing")
    }

    // MARK: Staging (Edit transaction)

    func testStagingLinksAndUnlinksUntilApplied() {
        var staging = EvidenceLinkStaging(saved: [1, 2])
        XCTAssertFalse(staging.hasChanges)
        staging.stageLink(3)
        staging.stageLink(3)
        staging.stageLink(1) // already linked
        staging.toggleUnlink(2)
        XCTAssertEqual(staging.shownIds, [1, 2, 3])
        XCTAssertTrue(staging.isLinked(1))
        XCTAssertFalse(staging.isLinked(2))
        XCTAssertTrue(staging.willUnlink(2))
        XCTAssertTrue(staging.willLink(3))
        XCTAssertEqual(staging.changes, EvidenceLinkChanges(link: [3], unlink: [2]))

        staging.toggleUnlink(2) // Undo
        staging.toggleUnlink(3) // a staged link is dropped
        XCTAssertFalse(staging.hasChanges)
        staging.toggleUnlink(1)
        staging.stageLink(1) // linking again undoes the unlink
        XCTAssertFalse(staging.hasChanges)
        staging.toggleUnlink(9) // not linked: nothing
        XCTAssertTrue(staging.changes.isEmpty)
    }

    func testStagedChangesApplyWithTheTransactionsSaveAndRollBackWithIt() throws {
        let ids = try seed()
        let kept = try add("kept.pdf", "k"), dropped = try add("dropped.pdf", "d"), added = try add("added.pdf", "a")
        try library.link(kept.id!, to: .transaction(ids.bbvaTransaction))
        try library.link(dropped.id!, to: .transaction(ids.bbvaTransaction))
        var staging = EvidenceLinkStaging(saved: [kept.id!, dropped.id!])
        staging.toggleUnlink(dropped.id!)
        staging.stageLink(added.id!)

        // A refused save (an unknown category) writes none of it.
        XCTAssertThrowsError(try manager.dbQueue.write { db in
            try TransactionEditing.save(db: db, id: ids.bbvaTransaction,
                                        changes: TransactionEditChanges(categoryId: 9_999, note: nil, documents: staging.changes))
        })
        XCTAssertEqual(Set(try library.documents(for: .transaction(ids.bbvaTransaction)).map(\.id)), [kept.id, dropped.id])

        try manager.dbQueue.write { db in
            try TransactionEditing.save(db: db, id: ids.bbvaTransaction,
                                        changes: TransactionEditChanges(categoryId: nil, note: "with documents", documents: staging.changes))
        }
        XCTAssertEqual(Set(try library.documents(for: .transaction(ids.bbvaTransaction)).map(\.id)), [kept.id, added.id])
    }

    func testUncategorizedContains() throws {
        let ids = try seed()
        try manager.dbQueue.read { db in
            XCTAssertTrue(try UncategorizedTransactions.contains(db: db, id: ids.bbvaTransaction))
            XCTAssertFalse(try UncategorizedTransactions.contains(db: db, id: 9_999))
        }
    }

    // MARK: Search

    private func index() throws -> EvidenceDocumentSearch.Index {
        try manager.dbQueue.read { db in try EvidenceDocumentSearch.Index(db: db) }
    }

    private func names(_ filter: EvidenceDocumentSearch.Filter) throws -> [String] {
        EvidenceDocumentSearch.entries(try index(), filter: filter).map(\.summary.originalFileName)
    }

    func testSearchMatchesNameKindNotePersonsAndTextIgnoringCaseAndAccents() throws {
        try add("Recibo condominio.pdf", "x1", EvidenceMetadata(kind: .condominioReceipt, docDate: Self.date(2024, 3, 1), amountMinorUnits: 12_000,
                                                                currency: .eur, persons: ["Ana"], note: "Quota Q1",
                                                                textStatus: .text, extractedText: "Administração do Condomínio, Rua Exemplo"))
        try add("p60.pdf", "x2", EvidenceMetadata(kind: .p60, docDate: Self.date(2025, 4, 5), persons: ["Bruno"]))
        XCTAssertEqual(try names(.init(text: "CONDOMÍNIO")), ["Recibo condominio.pdf"], "file name and text, accent-insensitive")
        XCTAssertEqual(try names(.init(text: "receipt")), ["Recibo condominio.pdf"], "the kind's name")
        XCTAssertEqual(try names(.init(text: "administracao rua")), ["Recibo condominio.pdf"], "every word, in the text")
        XCTAssertEqual(try names(.init(text: "quota")), ["Recibo condominio.pdf"], "the note")
        XCTAssertEqual(try names(.init(text: "bruno")), ["p60.pdf"], "persons")
        XCTAssertEqual(try names(.init(text: "120.00")), ["Recibo condominio.pdf"], "the amount")
        XCTAssertEqual(try names(.init(text: "rua bruno")), [])
        XCTAssertEqual(try names(.init()), ["p60.pdf", "Recibo condominio.pdf"], "newest added first")
    }

    func testFiltersByKindYearAccountLinksAndSourceFolder() throws {
        let ids = try seed()
        let folderId: Int64 = try manager.dbQueue.write { db in
            var folder = SourceFolder(path: "/tmp/x", bookmark: nil, name: "x")
            try folder.insert(db)
            return folder.id!
        }
        let notice = try add("notice.pdf", "1", EvidenceMetadata(kind: .imiNotice, docDate: Self.date(2024, 4, 1)))
        let receipt = try add("receipt.pdf", "2", EvidenceMetadata(kind: .insuranceReceipt, periodEnd: Self.date(2025, 6, 30),
                                                                     sourceFolderId: folderId, sourceRelativePath: "a/receipt.pdf"))
        let statement = try add("statement.pdf", "3", EvidenceMetadata(kind: .bankStatement))
        try add("loose.pdf", "4")
        try library.link(notice.id!, to: .transaction(ids.bbvaTransaction))
        try library.link(receipt.id!, to: .transaction(ids.lloydsTransaction))
        try library.link(statement.id!, to: .account(ids.bbva))

        XCTAssertEqual(try names(.init(kind: .builtIn(.imiNotice))), ["notice.pdf"])
        XCTAssertEqual(try names(.init(year: 2025)), ["receipt.pdf"], "dated by the period's end when there's no date")
        XCTAssertEqual(try names(.init(accountId: ids.bbva)), ["statement.pdf", "notice.pdf"], "through a transaction or directly")
        XCTAssertEqual(try names(.init(linkState: .unlinked)), ["loose.pdf"])
        XCTAssertEqual(try names(.init(linkState: .linked)).count, 3)
        XCTAssertEqual(try names(.init(sourceFolderId: folderId)), ["receipt.pdf"])
        XCTAssertEqual(try names(.init(text: "a/receipt")), ["receipt.pdf"], "the source path")

        let index = try index()
        XCTAssertEqual(index.years, [2025, 2024])
        XCTAssertEqual(index.kinds, [.builtIn(.insuranceReceipt), .builtIn(.imiNotice), .builtIn(.bankStatement), .builtIn(.other)])
        let entry = try XCTUnwrap(index.entries.first { $0.id == notice.id })
        XCTAssertEqual(entry.linkCount, 1)
        XCTAssertEqual(entry.transactionLinkCount, 1)
        XCTAssertEqual(index.entries.first { $0.id == statement.id }?.transactionLinkCount, 0)
        XCTAssertTrue(EvidenceDocumentSearch.Filter().isDefault)
        XCTAssertFalse(EvidenceDocumentSearch.Filter(text: "x").hasFilters)
        XCTAssertTrue(EvidenceDocumentSearch.Filter(year: 2024).hasFilters)
    }

    func testLibraryFilterByCustomKind() throws {
        let (boiler, alarm) = try manager.dbQueue.write { db in
            (try CustomDocumentKinds.create(db: db, name: "Boiler service", area: .property, now: Date()).id!,
             try CustomDocumentKinds.create(db: db, name: "Alarm contract", area: .other, now: Date()).id!)
        }
        _ = alarm  // made, but no document is of it: not offered
        let custom = try add("caldeira.pdf", "1", EvidenceMetadata(kind: .other, docDate: Self.date(2024, 4, 1)))
        try manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE document SET customKindId = ? WHERE id = ?", arguments: [boiler, custom.id!])
        }
        try add("plain.pdf", "2")
        try add("p60.pdf", "3", EvidenceMetadata(kind: .p60))

        XCTAssertEqual(try names(.init(kind: .custom(boiler))), ["caldeira.pdf"])
        XCTAssertEqual(try names(.init(kind: .builtIn(.other))), ["plain.pdf"], "Other is documents with no kind, not custom ones")
        XCTAssertEqual(try names(.init(text: "boiler")), ["caldeira.pdf"], "searched by its custom kind's name")
        let index = try index()
        XCTAssertEqual(index.kinds, [.builtIn(.p60), .builtIn(.other), .custom(boiler)], "built-ins, then the custom kinds present by name")
        XCTAssertEqual(index.catalog.displayName(.custom(boiler)), "Boiler service")

        // Editing details keeps the custom kind while the kind stays Other; a built-in kind replaces it.
        var details = EvidenceDocumentDetails(try XCTUnwrap(try library.document(id: custom.id!)))
        XCTAssertEqual(details.kindRef, .custom(boiler))
        details.note = "serviced"
        XCTAssertEqual(try library.updateDetails(custom.id!, details).kindRef, .custom(boiler))
        details.kindRef = .builtIn(.repairInvoice)
        let refiled = try library.updateDetails(custom.id!, details)
        XCTAssertEqual(refiled.kind, .repairInvoice)
        XCTAssertNil(refiled.customKindId)
    }

    func testUpdatingReReadsOnlyTheGivenDocuments() throws {
        let ids = try seed()
        let first = try add("first.pdf", "1"), second = try add("second.pdf", "2")
        var index = try index()
        try library.link(first.id!, to: .transaction(ids.bbvaTransaction))
        var details = EvidenceDocumentDetails(second)
        details.note = "edited"
        try library.updateDetails(second.id!, details)
        index = try manager.dbQueue.read { db in try index.updating(db: db, documentIds: [first.id!]) }
        XCTAssertEqual(index.entries.map(\.id), [second.id!, first.id!], "order kept")
        XCTAssertEqual(index.entries.first { $0.id == first.id }?.linkCount, 1)
        XCTAssertEqual(EvidenceDocumentSearch.entries(index, filter: .init(text: "edited")).count, 0, "not re-read")
        let third = try add("third.pdf", "3")
        try library.remove(second.id!)
        index = try manager.dbQueue.read { db in try index.updating(db: db, documentIds: [second.id!, third.id!]) }
        XCTAssertEqual(index.entries.map(\.id), [third.id!, first.id!], "removed dropped, new first")
    }

    func testOnlyTheStartOfLongTextIsSearched() throws {
        let filler = String(repeating: "x ", count: EvidenceDocumentSearch.indexedTextLength / 2)
        try add("long.pdf", "l", EvidenceMetadata(textStatus: .text, extractedText: "early " + filler + " latecomer"))
        XCTAssertEqual(try names(.init(text: "early")), ["long.pdf"])
        XCTAssertEqual(try names(.init(text: "latecomer")), [])
    }

    // MARK: Documents for a transaction

    func testDocumentSuggestionsForATransactionRankAndSkipLinked() {
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { Self.date(y, m, d) }
        let bbva = Account(id: 1, name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)
        let categories = [Category(id: 12, name: "IMI", type: .expense)]
        let transactions = [
            Transaction(id: 1, importBatchId: 1, accountId: 1, date: day(2023, 5, 8), rawDescription: "PG PAGEST 111122000000193",
                        amountMinorUnits: -25_000, categoryId: 12, status: .confirmed, categorizedBy: .none, fingerprint: "1"),
            Transaction(id: 2, importBatchId: 1, accountId: 1, date: day(2023, 8, 10), rawDescription: "PG PAGEST 111822000000293",
                        amountMinorUnits: -25_000, categoryId: 12, status: .confirmed, categorizedBy: .none, fingerprint: "2")
        ]
        func document(_ id: Int64, _ date: Date, _ amount: Int?) -> EvidenceDocument {
            EvidenceDocument(id: id, sha256: "\(id)", storedRelativePath: "x/\(id).pdf", originalFileName: "\(id).pdf", byteCount: 1,
                             kind: .imiPayment, docDate: date, amountMinorUnits: amount, currency: .eur, addedAt: Date())
        }
        let documents = [document(10, day(2023, 5, 8), 25_000), document(11, day(2023, 5, 9), nil), document(12, day(2023, 8, 10), 25_000),
                         document(13, day(2023, 5, 8), 25_000)]
        let index = EvidenceMatcher.Index(transactions: transactions, accounts: [bbva], categories: categories)
        let suggestions = EvidenceMatcher.documentSuggestions(for: 1, documents: documents, index: index, excluding: [13])
        XCTAssertEqual(suggestions.first?.documentId, 10)
        XCTAssertTrue(suggestions.first?.amountMatched ?? false)
        XCTAssertFalse(suggestions.contains { $0.documentId == 13 }, "already linked")
        XCTAssertFalse(suggestions.contains { $0.documentId == 12 && $0.score >= suggestions[0].score })
    }

    // MARK: One document on several transactions

    /// Two instalments of one repair bill (−40.00, −39.95) and a pounds debit; documents filed with
    /// their amounts and linked as `links` says.
    private func instalmentLibrary() throws -> (first: Int64, second: Int64, pounds: Int64, refund: Int64) {
        try manager.dbQueue.write { db in
            var euros = Account(name: "Bank EUR", currency: .eur, kind: .cash, trackingMode: .imported)
            try euros.insert(db)
            var pounds = Account(name: "Bank GBP", currency: .gbp, kind: .cash, trackingMode: .imported)
            try pounds.insert(db)
            var ids: [Int64] = []
            for (account, day, amount, text) in [(euros.id!, 5, -4_000, "PAG CANALIZACOES EXEMPLO 0001"), (euros.id!, 25, -3_995, "PAG CANALIZACOES EXEMPLO 0002"),
                                                 (pounds.id!, 6, -4_000, "CARD PAYMENT DEMO"), (euros.id!, 28, 1_000, "DEVOLUCAO CANALIZACOES EXEMPLO")] {
                var batch = ImportBatch(accountId: account, sourceFileName: "f.csv", importedAt: Date())
                try batch.insert(db)
                var transaction = Transaction(importBatchId: batch.id!, accountId: account, date: Self.date(2023, 3, day), rawDescription: text,
                                              amountMinorUnits: amount, categoryId: nil, status: .confirmed, categorizedBy: .none,
                                              fingerprint: UUID().uuidString)
                try transaction.insert(db)
                ids.append(transaction.id!)
            }
            return (ids[0], ids[1], ids[2], ids[3])
        }
    }

    private func filed(_ name: String, amount: Int?, currency: Currency? = .eur, kind: DocumentKind = .repairInvoice,
                       linkedTo transactions: [Int64] = []) throws -> Int64 {
        try manager.dbQueue.write { db in
            var document = EvidenceDocument(sha256: name, storedRelativePath: "x/\(name).pdf", originalFileName: "\(name).pdf", byteCount: 1,
                                            canonicalName: name, kind: kind, docDate: Self.date(2023, 3, 5),
                                            amountMinorUnits: amount, currency: amount == nil ? nil : currency, addedAt: Date())
            try document.insert(db)
            for id in transactions { try EvidenceLinks.link(db: db, documentId: document.id!, to: .transaction(id)) }
            return document.id!
        }
    }

    // MARK: Waiting for its payment (step 9)

    /// Documents dated 2023-03-05: waiting on 2023-04-01, lapsed on 2023-09-01.
    private func waitingLibrary() throws -> (waiting: Int64, paid: Int64, statement: Int64, noAmount: Int64) {
        let (first, _, _, _) = try instalmentLibrary()
        let waiting = try filed("Waiting bill", amount: 5_000)
        let paid = try filed("Paid bill", amount: 4_000, linkedTo: [first])
        let statement = try filed("A statement", amount: 5_000, kind: .bankStatement)
        let noAmount = try filed("No amount", amount: nil)
        return (waiting, paid, statement, noAmount)
    }

    private func listed(_ filter: EvidenceDocumentSearch.Filter, now: Date) throws -> [Int64] {
        let index = try manager.dbQueue.read { db in try EvidenceDocumentSearch.Index(db: db, now: now) }
        return EvidenceDocumentSearch.entries(index, filter: filter).map(\.id).sorted()
    }

    func testWaitingFilterShowsOnlyWaiting() throws {
        let ids = try waitingLibrary()
        let now = Self.date(2023, 4, 1)
        XCTAssertEqual(try listed(.init(linkState: .waiting), now: now), [ids.waiting])
        let index = try manager.dbQueue.read { db in try EvidenceDocumentSearch.Index(db: db, now: now) }
        XCTAssertEqual(index.entries.first { $0.id == ids.statement }?.waitingState, .notApplicable)
        XCTAssertEqual(index.entries.first { $0.id == ids.waiting }?.waitingState, .waiting)
        XCTAssertTrue(EvidenceDocumentSearch.Filter(linkState: .waiting).hasFilters)
    }

    func testLapsedIsOrdinaryUnlinked() throws {
        let ids = try waitingLibrary()
        let later = Self.date(2023, 9, 1)
        XCTAssertEqual(try listed(.init(linkState: .waiting), now: later), [])
        XCTAssertTrue(try listed(.init(linkState: .unlinked), now: later).contains(ids.waiting))
        let index = try manager.dbQueue.read { db in try EvidenceDocumentSearch.Index(db: db, now: later) }
        XCTAssertEqual(index.entries.first { $0.id == ids.waiting }?.waitingState, .lapsed)
    }

    func testWaitingDocumentIsNotInRecentUnlinked() throws {
        let ids = try waitingLibrary()
        let now = Self.date(2023, 4, 1)
        let index = try manager.dbQueue.read { db in try EvidenceDocumentSearch.Index(db: db, now: now) }
        let recent = EvidenceDocumentSearch.notLinkedYet(index.entries).map(\.id)
        XCTAssertFalse(recent.contains(ids.waiting))
        XCTAssertEqual(Set(recent), [ids.statement, ids.noAmount])
        // Once lapsed it is listed with the other unlinked documents.
        let lapsed = try manager.dbQueue.read { db in try EvidenceDocumentSearch.Index(db: db, now: Self.date(2023, 9, 1)) }
        XCTAssertTrue(EvidenceDocumentSearch.notLinkedYet(lapsed.entries).map(\.id).contains(ids.waiting))
    }

    func testAnyAndLinkedFiltersUnchanged() throws {
        let ids = try waitingLibrary()
        let now = Self.date(2023, 4, 1)
        XCTAssertEqual(try listed(.init(), now: now).count, 4)
        XCTAssertEqual(try listed(.init(linkState: .linked), now: now), [ids.paid])
        XCTAssertEqual(Set(try listed(.init(linkState: .unlinked), now: now)), [ids.waiting, ids.statement, ids.noAmount])
    }

    func testPartlyPaidDocumentsAreListedWithoutSearching() throws {
        let (first, second, pounds, refund) = try instalmentLibrary()
        // Its refund (a credit) is linked too: never counted as paying it.
        let partly = try filed("Part paid", amount: 7_995, linkedTo: [first, refund])
        let unlinked = try filed("Unlinked", amount: 5_000)
        _ = try filed("Paid", amount: 4_000, linkedTo: [first])
        _ = try filed("Paid twice", amount: 7_995, linkedTo: [first, second])
        _ = try filed("Pounds only", amount: 7_995, linkedTo: [pounds])
        _ = try filed("No amount", amount: nil, linkedTo: [first])
        // A statement's or a contract's figure is no bill: never "partly paid".
        _ = try filed("Statement", amount: 7_995, kind: .bankStatement, linkedTo: [first])
        _ = try filed("Contract", amount: 7_995, kind: .rentContract, linkedTo: [first])
        // Only a refund linked: nothing paid.
        _ = try filed("Refunded", amount: 7_995, linkedTo: [refund])
        let index = try manager.dbQueue.read { db in try EvidenceDocumentSearch.Index(db: db) }
        let listed = EvidenceDocumentSearch.entries(index, filter: .init(linkState: .unlinkedOrPartlyPaid))
        XCTAssertEqual(Set(listed.map(\.id)), [partly, unlinked])
        XCTAssertEqual(index.entries.filter(\.isPartlyPaid).map(\.id), [partly])
        XCTAssertEqual(EvidenceDocumentSearch.entries(index, filter: .init(linkState: .unlinked)).map(\.id), [unlinked])

        // What each document's linked debits paid, in its own currency.
        let linked = try manager.dbQueue.read { db in try EvidenceMatcher.linkedDebits(db: db) }
        XCTAssertEqual(linked[partly], [EvidenceMatcher.LinkedDebit(transactionId: first, amountMinorUnits: 4_000)])
        XCTAssertNil(linked[unlinked])

        // Link document… on the second instalment proposes the part-paid bill for the rest.
        let documents = try manager.dbQueue.read { db in try EvidenceDocument.fetchAll(db) }
        let transactions = try manager.dbQueue.read { db in try Transaction.fetchAll(db) }
        let accounts = try manager.dbQueue.read { db in try Account.fetchAll(db) }
        let matcher = EvidenceMatcher.Index(transactions: transactions, accounts: accounts, categories: [])
        let suggestions = EvidenceMatcher.documentSuggestions(for: second, documents: documents, index: matcher, linkedDebits: linked)
        let rest = try XCTUnwrap(suggestions.first { $0.documentId == partly })
        XCTAssertTrue(rest.amountMatched)
        XCTAssertEqual(rest.reasons.first, "Pays the rest of Part paid: €39.95 after €40.00")
        XCTAssertEqual(suggestions.first?.documentId, partly)
        XCTAssertFalse(EvidenceMatcher.documentSuggestions(for: second, documents: documents, index: matcher).contains { $0.documentId == partly && $0.amountMatched },
                       "without what it already paid, only the date fits")
    }
}
