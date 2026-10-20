import XCTest
import GRDB
@testable import BudgetCore

final class ImportRuleStoreTests: XCTestCase {
    private func manager() throws -> DatabaseManager {
        let m = try DatabaseManager(path: nil); try m.migrate(); return m
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ text: String) -> ImportFile {
        ImportFile(url: URL(fileURLWithPath: "/tmp/x.csv"), fileName: "x.csv", sha256: "abc", byteCount: 1,
                   fileExtension: "csv", text: text, textStatus: .text, usedOCR: false)
    }

    func testLearnUpsertsByKindAndKey() throws {
        let m = try manager()
        try m.dbQueue.write { db in
            try ImportRuleStore.learn(db: db, kind: .statementAccount, key: "csv:a", matchLabel: "L",
                                      action: StatementAccountAction(accountId: 1), actionLabel: "Account: One", now: t0)
            try ImportRuleStore.learn(db: db, kind: .statementAccount, key: "csv:a", matchLabel: "L",
                                      action: StatementAccountAction(accountId: 2), actionLabel: "Account: Two", now: t0)
            let all = try ImportRuleStore.all(db: db)
            XCTAssertEqual(all.count, 1)
            XCTAssertEqual(all[0].actionLabel, "Account: Two")
            let action = try JSONDecoder().decode(StatementAccountAction.self, from: Data(all[0].actionJSON.utf8))
            XCTAssertEqual(action.accountId, 2)
        }
    }

    func testDisabledRuleIsNotReturnedAndLearningReEnables() throws {
        let m = try manager()
        try m.dbQueue.write { db in
            var rule = try ImportRuleStore.learn(db: db, kind: .statementAccount, key: "k", matchLabel: "L",
                                                 action: StatementAccountAction(accountId: 1), actionLabel: "A", now: t0)
            XCTAssertNotNil(try ImportRuleStore.rule(db: db, kind: .statementAccount, key: "k"))
            rule.isEnabled = false
            try rule.update(db)
            XCTAssertNil(try ImportRuleStore.rule(db: db, kind: .statementAccount, key: "k"))
            try ImportRuleStore.learn(db: db, kind: .statementAccount, key: "k", matchLabel: "L",
                                      action: StatementAccountAction(accountId: 1), actionLabel: "A", now: t0)
            XCTAssertNotNil(try ImportRuleStore.rule(db: db, kind: .statementAccount, key: "k"))
        }
    }

    func testCSVSignatureIgnoresRowsAndCase() {
        let a = StatementSignature.key(for: file("Date,Description,Amount\n2026-01-01,Shop,-4.00\n"), kind: .bankStatementCSV)
        let b = StatementSignature.key(for: file("DATE, description ,amount\n2026-02-02,Other,9.00\n"), kind: .bankStatementCSV)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.key, b?.key)
        XCTAssertEqual(a?.key, "csv:date|description|amount")
        XCTAssertEqual(a?.label, "CSV with columns Date, Description, Amount")
    }

    func testPDFSignatureDropsDigits() {
        let a = StatementSignature.key(for: file("Everyday Statement 12\nPeriod 2026\nrest"), kind: .bankStatementPDF)
        let b = StatementSignature.key(for: file("Everyday Statement 99\nPeriod 2027\nother"), kind: .bankStatementPDF)
        XCTAssertEqual(a?.key, b?.key)
        XCTAssertEqual(a?.label, "PDF starting “Everyday Statement 12”")
        XCTAssertNil(StatementSignature.key(for: file("x"), kind: .unknown))
    }

    func testMarkUsedCountsAndStamps() throws {
        let m = try manager()
        try m.dbQueue.write { db in
            let rule = try ImportRuleStore.learn(db: db, kind: .statementAccount, key: "k", matchLabel: "L",
                                                 action: StatementAccountAction(accountId: 1), actionLabel: "A", now: t0)
            let later = t0.addingTimeInterval(100)
            try ImportRuleStore.markUsed(db: db, ids: [rule.id!, rule.id!], now: later)
            let got = try XCTUnwrap(try ImportRuleStore.rule(db: db, kind: .statementAccount, key: "k"))
            XCTAssertEqual(got.useCount, 1)
            XCTAssertEqual(got.lastUsedAt, later)
        }
    }

    func testBlankTextGivesNoSignature() {
        XCTAssertNil(StatementSignature.key(for: file(" \n  \n"), kind: .bankStatementCSV))
        XCTAssertNil(StatementSignature.key(for: file(" \n  \n"), kind: .bankStatementPDF))
        XCTAssertNil(StatementSignature.key(for: file("12345\n 2026 \n"), kind: .bankStatementPDF))
    }

    func testPDFSignatureSkipsDigitOnlyLines() {
        let a = StatementSignature.key(for: file("12345\nEveryday Statement 1\nPeriod 2026\nrest"), kind: .bankStatementPDF)
        XCTAssertEqual(a?.key, "pdf:everyday statement|period")
        XCTAssertEqual(a?.label, "PDF starting “Everyday Statement 1”")
    }

    func testMarkUsedWithUnknownIdIsNoOp() throws {
        let m = try manager()
        try m.dbQueue.write { db in
            try ImportRuleStore.markUsed(db: db, ids: [999], now: t0)
            XCTAssertTrue(try ImportRuleStore.all(db: db).isEmpty)
        }
    }

    func testRuleTableIsCapturedByImportRuns() {
        XCTAssertFalse(ImportChangeCapture.untrackedTables.contains("importRule"))
    }
}
