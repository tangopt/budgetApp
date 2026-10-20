import XCTest
@testable import BudgetCore

final class ImportModelTests: XCTestCase {
    private func file(_ name: String = "x.pdf") -> ImportFile {
        ImportFile(url: URL(fileURLWithPath: "/tmp/\(name)"), fileName: name, sha256: "abc", byteCount: 1,
                   fileExtension: "pdf", text: nil, textStatus: .noText, usedOCR: false)
    }

    private func item(facts: [ImportFact] = [], issues: [ImportIssue] = [], duplicate: ImportDuplicate? = nil,
                      leftOut: Bool = false) -> ImportItem {
        ImportItem(file: file(), recognition: ImportRecognition(kind: .unknown, confidence: .certain, reason: "r"),
                   title: "t", facts: facts, issues: issues, duplicate: duplicate, isLeftOut: leftOut)
    }

    private let issue = ImportIssue(id: "i", kind: .missingFigure(.amount), reason: "Amount missing")

    func testOCRFactPutsItemInNeedsYou() {
        let fact = ImportFact(field: .amount, value: .money(100, .eur), source: .ocr, confidence: .needsReview, reason: "ocr")
        let it = item(facts: [fact])
        XCTAssertEqual(it.section, .needsYou)
        XCTAssertEqual(it.needsYouReasons, ["Amount read by text recognition: check it"])
    }

    func testOCRFactIsAlwaysNeedsReview() {
        let fact = ImportFact(field: .amount, value: .money(100, .eur), source: .ocr, confidence: .certain, reason: "ocr")
        XCTAssertEqual(fact.confidence, .needsReview)
    }

    func testDuplicateWinsOverIssuesAndLeftOutWinsOverAll() {
        let dup = ImportDuplicate(level: .file, of: "a.pdf")
        XCTAssertEqual(item(issues: [issue], duplicate: dup).section, .duplicates)
        XCTAssertEqual(item(issues: [issue], duplicate: dup, leftOut: true).section, .leftOut)
        XCTAssertEqual(item().section, .ready)
    }

    func testCanConfirmOnlyWithEmptyNeedsYouAndSomethingReady() {
        let ready = item(), needs = item(issues: [issue]), dup = item(duplicate: ImportDuplicate(level: .file, of: "a")), out = item(leftOut: true)
        XCTAssertTrue(ImportPlan(items: [ready]).canConfirm)
        XCTAssertFalse(ImportPlan(items: [ready, needs]).canConfirm)
        XCTAssertFalse(ImportPlan(items: [dup]).canConfirm)
        XCTAssertTrue(ImportPlan(items: [ready, out]).canConfirm)
    }

    func testMayChangeTaxFiguresAndKindNames() {
        XCTAssertFalse(ImportEffect.file.mayChangeTaxFigures)
        XCTAssertTrue(ImportEffect.ukStatement(UKStatementEffect(accountId: 1, sourceFileName: "s.csv", staged: [], statement: nil, accountFill: nil)).mayChangeTaxFigures)
        XCTAssertEqual(ImportKind.payrollForm(.p60).displayName, "P60")
        XCTAssertEqual(ImportKind.unknown.displayName, "Unknown")
    }

    func testCollectExpandsFoldersAndSkipsSystemFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collect-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for path in ["a.pdf", ".hidden.pdf", ".DS_Store", "~$lock.xlsx", "sub/b.pdf", "sub/c 10.pdf", "sub/c 2.pdf"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(path))
        }
        let result = ImportFileCollector.collect([dir])
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["a.pdf", "b.pdf", "c 2.pdf", "c 10.pdf"])
        XCTAssertEqual(result.ignored.count, 3)
    }

    func testLoadReadsTextLayerAndHash() throws {
        let url = EvidenceTestPDFs.textPDF(["FACTURA 123", "Fornecedor de electricidade e gas", "Total a pagar neste periodo"])
        let f = try ImportFile.load(url)
        XCTAssertEqual(f.textStatus, .text)
        XCTAssertFalse(f.usedOCR)
        XCTAssertEqual(f.sha256, try EvidenceLibrary.sha256(of: url))
        XCTAssertTrue(f.text?.contains("FACTURA 123") == true)
    }

    func testLoadReadsCSVAndLeavesSpreadsheetsWithoutText() throws {
        let csv = EvidenceTestPDFs.temporaryURL("t.csv")
        try Data([0x61, 0x3B, 0xE9]).write(to: csv) // "a;é" in ISO Latin 1
        XCTAssertEqual(try ImportFile.load(csv).text, "a;é")
        let xlsx = EvidenceTestPDFs.temporaryURL("t.xlsx")
        try Data("x".utf8).write(to: xlsx)
        let f = try ImportFile.load(xlsx)
        XCTAssertNil(f.text)
        XCTAssertEqual(f.textStatus, .noText)
    }

    func testLoadDropsByteOrderMarkAndReadsNoTextFromOtherTypes() throws {
        let csv = EvidenceTestPDFs.temporaryURL("bom.csv")
        try Data([0xEF, 0xBB, 0xBF] + Array("a;b".utf8)).write(to: csv)
        XCTAssertEqual(try ImportFile.load(csv).text, "a;b")
        let other = EvidenceTestPDFs.temporaryURL("t.rtf")
        try Data("hello".utf8).write(to: other)
        let f = try ImportFile.load(other)
        XCTAssertNil(f.text)
        XCTAssertEqual(f.textStatus, .noText)
    }
    // MARK: What an issue's controls offer

    func testFiledYearHoldsTakeOnlyLeaveOut() {
        let impact = FiledYearImpact(startYear: 2024, person: "Person A", isPaid: false,
                                     returnChanges: [.init(label: "SA105 Rent", before: "£1.00", after: "£2.00")],
                                     informationChanges: [], taxDifferenceMinorUnits: 0, causes: [])
        let hold = ImportIssue(id: "filed-2024-Person A", kind: .filedYear(impact), reason: impact.headline, offers: [.leaveOut])
        let failed = ImportIssue(id: "filed-check", kind: .readerProblem("x"), reason: "x", offers: [.leaveOut])
        XCTAssertTrue(ImportResolutions.isFiledYearHold(hold))
        XCTAssertTrue(ImportResolutions.isFiledYearHold(failed))
        XCTAssertFalse(ImportResolutions.isFiledYearHold(issue))
        XCTAssertTrue(ImportResolutions.onlyLeavesOut(hold, in: item(issues: [hold])))
        XCTAssertFalse(ImportResolutions.onlyLeavesOut(issue, in: item(issues: [issue])))
    }

    func testAnUnreadableFileOnlyLeavesOut() {
        let unreadable = ImportIssue(id: "unreadable", kind: .readerProblem("Couldn't read"), reason: "Couldn't read")
        let it = item(issues: [unreadable, issue])
        XCTAssertTrue(ImportResolutions.onlyLeavesOut(issue, in: it))
        XCTAssertTrue(ImportResolutions.onlyLeavesOut(unreadable, in: it))
    }
}
