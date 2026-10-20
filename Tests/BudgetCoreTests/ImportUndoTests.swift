import XCTest
import GRDB
@testable import BudgetCore

final class ImportUndoTests: XCTestCase {
    private var manager: DatabaseManager!
    private var library: EvidenceLibrary!
    private var base: URL!
    private var accountId: Int64!
    private var batchId: Int64!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ImportUndoTests-\(UUID().uuidString)", isDirectory: true)
        library = EvidenceLibrary(root: base.appendingPathComponent("Evidence", isDirectory: true), database: manager.dbQueue)
        try manager.dbQueue.write { db in
            var account = Account(name: "Current", currency: .gbp, kind: .cash, trackingMode: .imported, alias: "Before")
            try account.insert(db)
            var batch = ImportBatch(accountId: account.id!, sourceFileName: "x.csv", importedAt: Date())
            try batch.insert(db)
            accountId = account.id
            batchId = batch.id
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// Runs `body` as one captured import run and returns its id.
    @discardableResult
    private func run(_ body: (Database) throws -> Void) throws -> Int64 {
        try manager.dbQueue.write { db -> Int64 in
            var run = ImportRun(confirmedAt: Date(), entryPoint: "Import…", summary: "s")
            try run.insert(db)
            try ImportChangeCapture.begin(db: db)
            try body(db)
            _ = try ImportChangeCapture.finish(db: db, runId: run.id!)
            return run.id!
        }
    }

    private func transaction(_ db: Database, _ description: String = "ACME SHOP") throws -> Transaction {
        let date = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 3, day: 4))!
        var t = Transaction(importBatchId: batchId, accountId: accountId, date: date, rawDescription: description, amountMinorUnits: -1234,
                            categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: UUID().uuidString)
        try t.insert(db)
        return t
    }

    private func refusal(_ runId: Int64, file: StaticString = #filePath, line: UInt = #line) -> [ImportUndoConflict] {
        do {
            _ = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)
            XCTFail("undo did not refuse", file: file, line: line)
        } catch ImportUndoError.refused(let conflicts) {
            return conflicts
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
        return []
    }

    func testUndoRemovesInsertedRowsAndRestoresUpdatedOnes() throws {
        var txId: Int64 = 0
        var linkId: Int64 = 0
        let pdf = EvidenceTestPDFs.textPDF(["SYNTHETIC RECEIPT"])
        let docId = try manager.dbQueue.write { db in
            try library.add(db: db, pdf, metadata: EvidenceMetadata(), analysis: nil).result.document.id!
        }
        let runId = try run { db in
            let t = try transaction(db)
            txId = t.id!
            linkId = try EvidenceLinks.link(db: db, documentId: docId, to: .transaction(t.id!)).id!
            var account = try Account.fetchOne(db, key: accountId)!
            account.alias = "After"
            try account.update(db)
        }
        let result = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)
        XCTAssertEqual(result.rowsRemoved, 2)
        XCTAssertEqual(result.rowsRestored, 1)
        XCTAssertEqual(result.filesRemoved, 0)
        try manager.dbQueue.read { db in
            XCTAssertFalse(try Transaction.exists(db, key: txId))
            XCTAssertFalse(try DocumentLink.exists(db, key: linkId))
            XCTAssertEqual(try Account.fetchOne(db, key: accountId)?.alias, "Before")
            let run = try ImportRun.fetchOne(db, key: runId)!
            XCTAssertNotNil(run.undoneAt)
            XCTAssertEqual(run.undoSummary, "Removed 2 rows, restored 1")
        }
    }

    func testUndoRefusesWhenImportedTransactionWasCategorisedSince() throws {
        var txId: Int64 = 0
        let runId = try run { db in txId = try transaction(db).id! }
        try manager.dbQueue.write { db in
            var groceries = Category(name: "Groceries", type: .expense)
            try groceries.insert(db)
            var t = try Transaction.fetchOne(db, key: txId)!
            t.categoryId = groceries.id
            t.categorizedBy = .manual
            t.status = .confirmed
            try t.update(db)
        }
        let conflicts = refusal(runId)
        XCTAssertEqual(conflicts, [.changedSince(table: "transaction_", rowId: txId, columns: ["categoryId", "status", "categorizedBy"])])
        XCTAssertEqual(conflicts.first?.message, "Transaction \(txId) was changed since (category, status, categorized by)")
        try manager.dbQueue.read { db in
            XCTAssertTrue(try Transaction.exists(db, key: txId))
            XCTAssertNil(try ImportRun.fetchOne(db, key: runId)?.undoneAt)
        }
    }

    func testUndoRefusesWhenALaterRunTouchedTheSameRow() throws {
        var txId: Int64 = 0
        let first = try run { db in txId = try transaction(db).id! }
        let second = try run { db in
            var t = try Transaction.fetchOne(db, key: txId)!
            t.note = "Later"
            try t.update(db)
        }
        XCTAssertEqual(refusal(first), [.laterImport(runId: second, table: "transaction_", rowId: txId)])
        // Undoing the later run first clears the way.
        _ = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: second)
        let result = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: first)
        XCTAssertEqual(result.rowsRemoved, 1)
    }

    func testUndoRefusesWhenAnUnloggedRowDependsOnAnInsertedOne() throws {
        var txId: Int64 = 0
        let runId = try run { db in txId = try transaction(db).id! }
        let linkId = try manager.dbQueue.write { db -> Int64 in
            let pdf = EvidenceTestPDFs.textPDF(["SYNTHETIC NOTE"])
            let doc = try library.add(db: db, pdf, metadata: EvidenceMetadata(), analysis: nil).result.document
            return try EvidenceLinks.link(db: db, documentId: doc.id!, to: .transaction(txId)).id!
        }
        XCTAssertEqual(refusal(runId), [.dependsOnIt(table: "transaction_", rowId: txId, dependent: "documentLink \(linkId)")])
    }

    /// A column a later migration adds (with a default) isn't in the run's captured rows: it
    /// is no change since.
    func testColumnAddedSinceDoesNotRefuseTheUndo() throws {
        var txId: Int64 = 0
        let runId = try run { db in
            txId = try transaction(db).id!
            var account = try Account.fetchOne(db, key: accountId)!
            account.alias = "After"
            try account.update(db)
        }
        try manager.dbQueue.write { db in
            try db.execute(sql: "ALTER TABLE transaction_ ADD COLUMN laterColumn TEXT DEFAULT 'later'")
            try db.execute(sql: "ALTER TABLE account ADD COLUMN laterColumn TEXT DEFAULT 'later'")
        }
        let result = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)
        XCTAssertEqual(result.rowsRemoved, 1)
        try manager.dbQueue.read { db in
            XCTAssertFalse(try Transaction.exists(db, key: txId))
            XCTAssertEqual(try Account.fetchOne(db, key: accountId)?.alias, "Before")
        }
    }

    /// A waiver of an evidence requirement on an imported record depends on it (deleting the
    /// record would drop the waiver with it).
    func testUndoRefusesWhenAnEvidenceWaiverPointsAtAnInsertedRow() throws {
        var txId: Int64 = 0
        let runId = try run { db in txId = try transaction(db).id! }
        let waiverId = try manager.dbQueue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO evidenceRequirement (name, scope, kinds, createdAt) VALUES ('Requirement', '{}', '[]', ?)",
                           arguments: [Date()])
            try db.execute(sql: "INSERT INTO evidenceWaiver (requirementId, entityType, entityId, reason, createdAt) VALUES (?, ?, ?, 'other', ?)",
                           arguments: [db.lastInsertedRowID, EvidenceEntityType.transaction.rawValue, txId, Date()])
            return db.lastInsertedRowID
        }
        XCTAssertEqual(refusal(runId), [.dependsOnIt(table: "transaction_", rowId: txId, dependent: "evidenceWaiver \(waiverId)")])
    }

    func testUndoRefusesWhenARowWithADeclaredForeignKeyDependsOnAnInsertedOne() throws {
        var batch2: Int64 = 0
        let runId = try run { db in
            var batch = ImportBatch(accountId: accountId, sourceFileName: "y.csv", importedAt: Date())
            try batch.insert(db)
            batch2 = batch.id!
        }
        let txId = try manager.dbQueue.write { db -> Int64 in
            let date = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 3, day: 4))!
            var t = Transaction(importBatchId: batch2, accountId: accountId, date: date, rawDescription: "LATER", amountMinorUnits: 100,
                                categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "later")
            try t.insert(db)
            return t.id!
        }
        XCTAssertEqual(refusal(runId), [.dependsOnIt(table: "importBatch", rowId: batch2, dependent: "transaction_ \(txId)")])
    }

    func testUndoRemovesStoredFileOfDocumentItAdded() throws {
        var stored: URL!
        let pdf = EvidenceTestPDFs.textPDF(["SYNTHETIC INVOICE 42"])
        let runId = try run { db in
            let staged = try library.add(db: db, pdf, metadata: EvidenceMetadata(), analysis: nil)
            stored = library.fileURL(for: staged.result.document)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        let result = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)
        XCTAssertEqual(result.filesRemoved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertEqual(try manager.dbQueue.read { try EvidenceDocument.fetchCount($0) }, 0)
    }

    func testUndoTwiceThrowsAlreadyUndone() throws {
        let runId = try run { db in _ = try transaction(db) }
        _ = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)
        XCTAssertThrowsError(try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)) {
            XCTAssertEqual($0 as? ImportUndoError, .alreadyUndone)
        }
        XCTAssertThrowsError(try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: 999)) {
            XCTAssertEqual($0 as? ImportUndoError, .runNotFound)
        }
    }

    func testNetChangesCollapseInsertThenDelete() {
        let changes = [
            ImportChange(runId: 1, seq: 1, tableName: "t", rowId: 1, operation: .insert, beforeJSON: nil, afterJSON: "{\"a\":1}"),
            ImportChange(runId: 1, seq: 2, tableName: "t", rowId: 2, operation: .update, beforeJSON: "{\"a\":1}", afterJSON: "{\"a\":2}"),
            ImportChange(runId: 1, seq: 3, tableName: "t", rowId: 1, operation: .delete, beforeJSON: "{\"a\":1}", afterJSON: nil),
            ImportChange(runId: 1, seq: 4, tableName: "t", rowId: 2, operation: .update, beforeJSON: "{\"a\":2}", afterJSON: "{\"a\":3}"),
            ImportChange(runId: 1, seq: 5, tableName: "t", rowId: 3, operation: .insert, beforeJSON: nil, afterJSON: "{\"a\":1}"),
            ImportChange(runId: 1, seq: 6, tableName: "t", rowId: 3, operation: .update, beforeJSON: "{\"a\":1}", afterJSON: "{\"a\":5}"),
        ]
        XCTAssertEqual(ImportUndo.netChanges(Array(changes.prefix(1)) + [changes[2]]), [])
        let net = ImportUndo.netChanges(changes)
        XCTAssertEqual(net.map(\.rowId), [2, 3])
        XCTAssertEqual(net.map(\.operation), [.update, .insert])
        XCTAssertEqual(net[0].beforeJSON, "{\"a\":1}")
        XCTAssertEqual(net[0].afterJSON, "{\"a\":3}")
        XCTAssertNil(net[1].beforeJSON)
        XCTAssertEqual(net[1].afterJSON, "{\"a\":5}")
    }

    // MARK: Review notes on change capture

    func testUndoRestoresANullBlob() throws {
        let folderId = try manager.dbQueue.write { db -> Int64 in
            var folder = SourceFolder(path: "/synthetic", bookmark: nil, name: "Synthetic")
            try folder.insert(db)
            return folder.id!
        }
        let runId = try run { db in
            try db.execute(sql: "UPDATE sourceFolder SET bookmark = ?, name = 'Renamed' WHERE id = ?", arguments: [Data([0xbe, 0xef]), folderId])
        }
        let before = try manager.dbQueue.read { try ImportChange.filter(Column("runId") == runId).fetchOne($0)!.beforeJSON! }
        XCTAssertTrue(before.contains("\"bookmark\":null"), before)
        _ = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)
        try manager.dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT bookmark, name FROM sourceFolder WHERE id = ?", arguments: [folderId])!
            XCTAssertTrue((row["bookmark"] as DatabaseValue).isNull)
            XCTAssertEqual(row["name"] as String, "Synthetic")
            XCTAssertEqual(try ImportChangeCapture.rowJSON(db: db, table: "sourceFolder", rowId: folderId)?.contains("\"bookmark\":null"), true)
        }
    }

    func testUndoRestoresADeletedParentAndItsCascadedChildren() throws {
        let pdf = EvidenceTestPDFs.textPDF(["SYNTHETIC CONTRACT"])
        var txId: Int64 = 0
        let (docId, linkId) = try manager.dbQueue.write { db -> (Int64, Int64) in
            let doc = try library.add(db: db, pdf, metadata: EvidenceMetadata(canonicalName: "Contract"), analysis: nil).result.document
            txId = try transaction(db).id!
            let link = try EvidenceLinks.link(db: db, documentId: doc.id!, to: .transaction(txId), role: "proof")
            return (doc.id!, link.id!)
        }
        let runId = try run { db in
            _ = try EvidenceDocument.deleteOne(db, key: docId)
            XCTAssertFalse(try DocumentLink.exists(db, key: linkId))
        }
        let changes = try manager.dbQueue.read { try ImportChange.filter(Column("runId") == runId).fetchAll($0) }
        XCTAssertEqual(Set(changes.map(\.tableName)), ["document", "documentLink"])
        let result = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)
        XCTAssertEqual(result.rowsRestored, 2)
        try manager.dbQueue.read { db in
            XCTAssertEqual(try EvidenceDocument.fetchOne(db, key: docId)?.canonicalName, "Contract")
            let link = try DocumentLink.fetchOne(db, key: linkId)
            XCTAssertEqual(link?.documentId, docId)
            XCTAssertEqual(link?.entityId, txId)
            XCTAssertEqual(link?.role, "proof")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM pragma_foreign_key_check"), 0)
        }
    }

    func testUndoRefusesWhenItWouldChangeAFiledReturn() throws {
        let employmentId = try manager.dbQueue.write { db -> Int64 in
            var person = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &person)
            var year = TaxYear(startYear: 2024, personId: person.id!, status: .filed)
            try year.insert(db)
            var employment = Employment(startYear: 2024, personId: person.id!, employerName: "Example Ltd")
            try Employments.save(db: db, &employment)
            return employment.id!
        }
        let runId = try run { db in
            var income = EmploymentIncome(employmentId: employmentId, source: .p60, payMinorUnits: 4_000_000, taxDeductedMinorUnits: 600_000)
            try Employments.save(db: db, &income)
        }
        let conflicts = refusal(runId)
        XCTAssertEqual(conflicts.count, 1)
        guard case .filedYear(let impact)? = conflicts.first else { return XCTFail("\(conflicts)") }
        XCTAssertEqual(impact.startYear, 2024)
        XCTAssertEqual(impact.person, "Person A")
        XCTAssertFalse(impact.isPaid)
        XCTAssertTrue(impact.returnChanges.contains { $0.label.lowercased().hasPrefix("sa102") && $0.before == "£40,000.00" }, "\(impact.returnChanges)")
        XCTAssertEqual(conflicts.first?.message, "Would change the filed 2024/25 return of Person A")
        XCTAssertEqual(try manager.dbQueue.read { try EmploymentIncome.fetchCount($0) }, 1)
    }

    func testDescribeTransactionAndDocument() throws {
        let (txId, docId) = try manager.dbQueue.write { db -> (Int64, Int64) in
            let t = try transaction(db)
            let doc = try library.add(db: db, EvidenceTestPDFs.textPDF(["X"], name: "receipt.pdf"), metadata: EvidenceMetadata(), analysis: nil).result.document
            return (t.id!, doc.id!)
        }
        try manager.dbQueue.read { db in
            XCTAssertEqual(try ImportUndo.describe(db: db, table: "transaction_", rowId: txId), "2026-03-04 ACME SHOP -£12.34")
            XCTAssertEqual(try ImportUndo.describe(db: db, table: "document", rowId: docId), "receipt.pdf")
            XCTAssertEqual(try ImportUndo.describe(db: db, table: "account", rowId: accountId), "Account \(accountId!)")
        }
    }

    // MARK: Review round 1

    func testUndoRefusesWhenTheParentOfADeletedRowWasDeletedSince() throws {
        let (batch, txId) = try manager.dbQueue.write { db -> (Int64, Int64) in
            var batch = ImportBatch(accountId: accountId, sourceFileName: "z.csv", importedAt: Date())
            try batch.insert(db)
            let date = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 3, day: 4))!
            var t = Transaction(importBatchId: batch.id!, accountId: accountId, date: date, rawDescription: "OLD", amountMinorUnits: 100,
                                categoryId: nil, status: .pendingReview, categorizedBy: .none, fingerprint: "old")
            try t.insert(db)
            return (batch.id!, t.id!)
        }
        let runId = try run { db in _ = try Transaction.deleteOne(db, key: txId) }
        try manager.dbQueue.write { db in _ = try ImportBatch.deleteOne(db, key: batch) }
        XCTAssertEqual(refusal(runId), [.removedSince(table: "importBatch", rowId: batch)])
        XCTAssertFalse(try manager.dbQueue.read { try Transaction.exists($0, key: txId) })
    }

    func testUndoRefusesWhenARestoredCategoryWasDeletedSince() throws {
        let (categoryId, txId) = try manager.dbQueue.write { db -> (Int64, Int64) in
            var category = Category(name: "Old category", type: .expense)
            try category.insert(db)
            var t = try transaction(db)
            t.categoryId = category.id
            try t.update(db)
            return (category.id!, t.id!)
        }
        let runId = try run { db in
            var t = try Transaction.fetchOne(db, key: txId)!
            t.categoryId = nil
            try t.update(db)
        }
        try manager.dbQueue.write { db in _ = try Category.deleteOne(db, key: categoryId) }
        XCTAssertEqual(refusal(runId), [.removedSince(table: "category", rowId: categoryId)])
        XCTAssertNil(try manager.dbQueue.read { try Transaction.fetchOne($0, key: txId)?.categoryId })
    }

    func testUndoRefusesToRestoreADocumentLinkToADeletedRecord() throws {
        let pdf = EvidenceTestPDFs.textPDF(["SYNTHETIC BILL"])
        let (docId, txId) = try manager.dbQueue.write { db -> (Int64, Int64) in
            let doc = try library.add(db: db, pdf, metadata: EvidenceMetadata(), analysis: nil).result.document
            let t = try transaction(db)
            try EvidenceLinks.link(db: db, documentId: doc.id!, to: .transaction(t.id!))
            return (doc.id!, t.id!)
        }
        let runId = try run { db in _ = try EvidenceLinks.unlink(db: db, documentId: docId, from: .transaction(txId)) }
        try manager.dbQueue.write { db in _ = try Transaction.deleteOne(db, key: txId) }
        XCTAssertEqual(refusal(runId), [.removedSince(table: "transaction_", rowId: txId)])
        XCTAssertEqual(try manager.dbQueue.read { try DocumentLink.fetchCount($0) }, 0)
    }

    func testUndoRefusesWhenAForecastEntryPointsAtAnInsertedCategory() throws {
        var categoryId: Int64 = 0
        let runId = try run { db in
            var category = Category(name: "Imported", type: .expense)
            try category.insert(db)
            categoryId = category.id!
        }
        let entryId = try manager.dbQueue.write { db -> Int64 in
            var group = ForecastGroup(name: "G", note: nil, isEnabled: true, isSystemManaged: false)
            try group.insert(db)
            var entry = ForecastEntry(groupId: group.id!, categoryId: categoryId, amountMinorUnits: 100, frequency: .monthly, interval: 1,
                                      startDate: Date(), endDate: nil, isEnabled: true, status: .manual, note: nil, accountId: accountId)
            try entry.insert(db)
            return entry.id!
        }
        XCTAssertEqual(refusal(runId), [.dependsOnIt(table: "category", rowId: categoryId, dependent: "forecastEntry \(entryId)")])
        try manager.dbQueue.read { db in
            XCTAssertEqual(try ForecastEntry.fetchOne(db, key: entryId)?.categoryId, categoryId)
            XCTAssertTrue(try Category.exists(db, key: categoryId))
        }
    }

    func testRealValuesAreRestoredExactly() throws {
        let precise = 0.1 + 0.2
        let (updatedId, deletedId) = try manager.dbQueue.write { db -> (Int64, Int64) in
            var a = HMRCRate(startYear: 2023, currencyCode: "EUR", gbpPerUnit: 1.17, source: .manual)
            try a.insert(db)
            var b = HMRCRate(startYear: 2024, currencyCode: "EUR", gbpPerUnit: precise, source: .manual)
            try b.insert(db)
            return (a.id!, b.id!)
        }
        let runId = try run { db in
            try db.execute(sql: "UPDATE hmrcRate SET gbpPerUnit = 1.0 WHERE id = ?", arguments: [updatedId])
            try db.execute(sql: "DELETE FROM hmrcRate WHERE id = ?", arguments: [deletedId])
        }
        let after = try manager.dbQueue.read { try ImportChange.filter(Column("runId") == runId).order(Column("seq")).fetchAll($0) }
        XCTAssertTrue(after[0].afterJSON!.contains("\"gbpPerUnit\":\"1.0\""), after[0].afterJSON!)
        XCTAssertEqual(try ImportUndo.conflicts(dbQueue: manager.dbQueue, runId: runId), [])
        _ = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)
        try manager.dbQueue.read { db in
            XCTAssertEqual(try HMRCRate.fetchOne(db, key: updatedId)?.gbpPerUnit, 1.17)
            XCTAssertEqual(try HMRCRate.fetchOne(db, key: deletedId)?.gbpPerUnit, precise)
            XCTAssertEqual(try ImportChangeCapture.rowJSON(db: db, table: "hmrcRate", rowId: deletedId), after[1].beforeJSON)
        }
    }

    func testUndoRefreshesTheAutoForecast() throws {
        // Three monthly paydays already saved: the forecast can be detected once refreshed.
        try manager.dbQueue.write { db in
            var income = Category(name: PaydaySource.salaryCategoryName, type: .income)
            try income.insert(db)
            for month in 1...3 {
                var pay = Transaction(importBatchId: batchId, accountId: accountId,
                                      date: MonthRange.calendar.date(from: DateComponents(year: 2026, month: month, day: 25))!,
                                      rawDescription: "EMPLOYER PAY", amountMinorUnits: 300_000, categoryId: income.id, status: .confirmed,
                                      categorizedBy: .manual, fingerprint: "pay-\(month)")
                try pay.insert(db)
            }
        }
        let runId = try run { db in _ = try transaction(db) }
        XCTAssertEqual(try manager.dbQueue.read { try ForecastGroup.fetchCount($0) }, 0)
        _ = try ImportUndo.undo(dbQueue: manager.dbQueue, library: library, runId: runId)
        XCTAssertEqual(try manager.dbQueue.read { try ForecastGroup.filter(Column("isSystemManaged") == true).fetchCount($0) }, 1,
                       "the forecast was refreshed after the undo")
    }
}
