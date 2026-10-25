import XCTest
import GRDB
@testable import BudgetCore
import struct BudgetCore.Category
import TestSupport

/// The initial evidence import (plan 2026-10-16 Task 6), on synthetic folders and data.
final class EvidenceInitialImportTests: XCTestCase {
    private var manager: DatabaseManager!
    private var base: URL!
    private var folderA: URL!
    private var folderB: URL!
    private var library: EvidenceLibrary!
    private var imiTransaction: Int64 = 0

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private static func imiText(_ day: String, reference: String) -> String {
        "AVISO DE DÉBITO\nPAGAMENTOS AO ESTADO\nDATA: \(day)\nReferencia : \(reference)\nMONTANTE PAGO : 250,00 EUROS\n"
    }

    private static let condominioText = "Recibo nº 0042 Condomínio Edifício Exemplo Recebemos de v/ exa o pagamento dos seguintes valores: quota"

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("EvidenceInitialImportTests-\(UUID().uuidString)", isDirectory: true)
        folderA = base.appendingPathComponent("Lisboa", isDirectory: true)
        folderB = base.appendingPathComponent("Tax", isDirectory: true)
        library = EvidenceLibrary(root: base.appendingPathComponent("Evidence", isDirectory: true), database: manager.dbQueue)

        imiTransaction = try manager.dbQueue.write { db in
            var bbva = Account(name: "BBVA", currency: .eur, kind: .cash, trackingMode: .imported)
            try bbva.insert(db)
            var loan = Account(name: "BBVA mortgage", currency: .eur, kind: .credit, trackingMode: .imported, includeInNetWorth: false)
            try loan.insert(db)
            var group = CategoryGroup(name: "Lisbon")
            try group.insert(db)
            var imi = Category(name: "IMI", type: .expense, groupId: group.id)
            try imi.insert(db)
            var condominio = Category(name: "Condomínio", type: .expense, groupId: group.id)
            try condominio.insert(db)
            var transfer = Category(name: "Transfer: BBVA mortgage", type: .transfer, transferAccountId: loan.id)
            try transfer.insert(db)
            var batch = ImportBatch(accountId: bbva.id!, sourceFileName: "bbva.xlsx", importedAt: Date())
            try batch.insert(db)
            func insert(_ date: Date, _ amount: Int, _ description: String, _ category: Int64?) throws -> Int64 {
                var transaction = Transaction(importBatchId: batch.id!, accountId: bbva.id!, date: date, rawDescription: description,
                                              amountMinorUnits: amount, categoryId: category, status: .confirmed, categorizedBy: .manual,
                                              fingerprint: UUID().uuidString)
                try transaction.insert(db)
                return transaction.id!
            }
            // Before the minimum date: its proof is matched but not imported.
            _ = try insert(Self.date(2022, 5, 9), -25_000, "PG PAGEST 111122000000999", imi.id)
            return try insert(Self.date(2025, 5, 8), -25_000, "PG PAGEST 111122000000193", imi.id)
        }

        try write("IMI/2025 IMI pagamento.txt", Self.imiText("2025-05-08", reference: "111122000000193"), in: folderA)
        try write("IMI/2022 IMI pagamento.txt", Self.imiText("2022-05-09", reference: "111122000000999"), in: folderA)
        try write("Condominio/20240305 - recibo condominio.txt", Self.condominioText, in: folderA)
        try write("Condominio/20190305 - recibo condominio.txt", Self.condominioText + " 2019", in: folderA)
        try write("notes.txt", "Hello, nothing to see here.", in: folderA)
        try write("_app-import/imi.txt", Self.imiText("2025-05-08", reference: "111122000000193") + " extracted", in: folderA)
        // The same IMI proof filed again in the tax folder.
        try write("PT/IMI copy.txt", Self.imiText("2025-05-08", reference: "111122000000193"), in: folderB)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    private func write(_ relativePath: String, _ contents: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private var options: EvidenceInitialImport.Options {
        EvidenceInitialImport.Options(minimumTransactionDate: Self.date(2023, 1, 1),
                                      reviewWindow: DateInterval(start: Self.date(2023, 1, 1), end: Self.date(2026, 10, 16)),
                                      taxYears: [UKTaxYear(startYear: 2024), UKTaxYear(startYear: 2025)])
    }

    private func folderContents(_ url: URL) throws -> [String: Data] {
        var contents: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let file as URL in enumerator where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            contents[file.path] = try Data(contentsOf: file)
        }
        return contents
    }

    func testImportsLinksAndQueuesReview() throws {
        let before = try folderContents(base)
        let hash = try EvidenceLibrary.sha256(of: folderA.appendingPathComponent("IMI/2025 IMI pagamento.txt"))
        var options = self.options
        options.canonicalNames = [hash: "20250508 - IMI - payment.txt"]

        let report = try EvidenceInitialImport.run(library: library, folderURLs: [folderA, folderB], options: options)

        // Folders registered and scanned.
        XCTAssertEqual(report.folders.map(\.name), ["Lisboa", "Tax"])
        XCTAssertEqual(report.folders.map(\.new), [6, 1])
        XCTAssertEqual(report.folders.map(\.alreadyRegistered), [false, false])
        XCTAssertEqual(report.folders.map(\.relevant), [4, 1])
        XCTAssertEqual(try SourceFolderScanner(library: library).sourceFolders().count, 2)

        // The recent IMI proof is linked (once, despite its copy); the 2024 condomínio receipt waits for review.
        XCTAssertEqual(report.documentsAdded, 2)
        XCTAssertEqual(report.links.map(\.transactionId), [imiTransaction])
        XCTAssertEqual(report.links.first?.kind, .imiPayment)
        XCTAssertEqual(report.links.first?.categoryName, "IMI")
        XCTAssertEqual(report.linksByCategoryAndKind.map(\.key), ["IMI · IMI payment"])
        XCTAssertEqual(report.review.map(\.path), ["Lisboa/Condominio/20240305 - recibo condominio.txt"])
        XCTAssertEqual(report.review.first?.kind, .condominioReceipt)
        XCTAssertEqual(report.review.first?.reason, .noCandidate)
        XCTAssertEqual(report.left[.notRelevant], 1)
        XCTAssertEqual(report.left[.matchedBeforeMinimum], 1)
        XCTAssertEqual(report.left[.outsideReviewWindow], 1)
        XCTAssertEqual(report.left[.duplicate], 1)
        XCTAssertEqual(report.left[.excluded], 1)

        let documents = try library.documentSummaries()
        XCTAssertEqual(documents.count, 2)
        let linked = try XCTUnwrap(library.documents(for: .transaction(imiTransaction)).first)
        XCTAssertEqual(linked.canonicalName, "20250508 - IMI - payment.txt")
        XCTAssertNil(linked.note)
        XCTAssertEqual(documents.first { $0.kind == .condominioReceipt }?.note, EvidenceInitialImport.reviewNote)
        XCTAssertEqual(try library.unlinkedDocuments().count, 1)

        // Rules seeded; the IMI payment now has its proof.
        XCTAssertEqual(report.rulesAdded, ["Lisbon: Condomínio", "Lisbon: IMI", "Lisbon: Mortgage instalments"])
        let year = UKTaxYear(startYear: 2025)
        XCTAssertEqual(report.progressBefore[year], MissingEvidence.Progress(total: 1, satisfied: 0))
        XCTAssertEqual(report.progressAfter[year], MissingEvidence.Progress(total: 1, satisfied: 1))
        XCTAssertEqual(report.progressAfter[UKTaxYear(startYear: 2024)], MissingEvidence.Progress())
        XCTAssertTrue(report.text().contains("2025/26: 0/1 (0%) → 1/1 (100%)"))

        // The source folders are untouched; the library holds the two copies.
        let after = try folderContents(base)
        for (path, data) in before { XCTAssertEqual(after[path], data, path) }
        XCTAssertEqual(try folderContents(library.root).count, 2)
    }

    func testRunningAgainAddsNothing() throws {
        _ = try EvidenceInitialImport.run(library: library, folderURLs: [folderA, folderB], options: options)
        let again = try EvidenceInitialImport.run(library: library, folderURLs: [folderA, folderB], options: options)
        XCTAssertEqual(again.folders.map(\.alreadyRegistered), [true, true])
        XCTAssertEqual(again.folders.map(\.inLibrary), [2, 1])
        XCTAssertEqual(again.documentsAdded, 0)
        XCTAssertEqual(again.links.count, 0)
        XCTAssertEqual(again.review.count, 0)
        XCTAssertEqual(again.rulesAdded, [])
        XCTAssertEqual(try library.documentSummaries().count, 2)
        XCTAssertEqual(try manager.dbQueue.read { try EvidenceRequirement.fetchCount($0) }, 3)
    }

    func testMissingGroupIsAWarning() throws {
        var options = self.options
        options.categoryGroupName = "Porto"
        let report = try EvidenceInitialImport.run(library: library, folderURLs: [folderA], options: options)
        XCTAssertEqual(report.rulesAdded, [])
        XCTAssertEqual(report.warnings, ["No category group named Porto: no rules seeded."])
        XCTAssertEqual(report.links.count, 1)
    }

    // MARK: Deciding

    private func scanned(_ kind: DocumentKind, date: Date?, suggestions: [EvidenceMatcher.Suggestion]) -> SourceFolderScanner.ScannedFile {
        SourceFolderScanner.ScannedFile(relativePath: "a.pdf", url: URL(fileURLWithPath: "/a.pdf"), size: 1, modifiedAt: Date(), sha256: "x",
                                        documentId: nil, previousSha256: nil, previousDocumentId: nil, changeDetectedAt: nil,
                                        analysis: EvidenceAnalysis(metadata: EvidenceMetadata(kind: kind, docDate: date), textStatus: .text, extractedText: nil),
                                        suggestions: suggestions)
    }

    func testDecide() {
        let strong = EvidenceMatcher.Suggestion(transactionId: 1, score: 200, reasons: [], amountMatched: true, dateInWindow: true)
        let tie = EvidenceMatcher.Suggestion(transactionId: 2, score: 200, reasons: [], amountMatched: true, dateInWindow: true)
        let weak = EvidenceMatcher.Suggestion(transactionId: 1, score: 80, reasons: [], amountMatched: false, dateInWindow: true)
        let dates: [Int64: Date] = [1: Self.date(2024, 5, 1), 2: Self.date(2024, 5, 1)]
        let recent = Self.date(2024, 5, 1)
        func decide(_ file: SourceFolderScanner.ScannedFile) -> EvidenceInitialImport.Decision {
            EvidenceInitialImport.decide(file, transactionDates: dates, options: options)
        }
        XCTAssertEqual(decide(scanned(.condominioReceipt, date: recent, suggestions: [strong])), .link(strong))
        XCTAssertEqual(decide(scanned(.condominioReceipt, date: recent, suggestions: [strong, tie])), .review(.ambiguous))
        XCTAssertEqual(decide(scanned(.condominioReceipt, date: recent, suggestions: [weak])), .review(.notConfident))
        XCTAssertEqual(decide(scanned(.condominioReceipt, date: recent, suggestions: [])), .review(.noCandidate))
        XCTAssertEqual(decide(scanned(.condominioReceipt, date: nil, suggestions: [])), .leave(.outsideReviewWindow))
        XCTAssertEqual(decide(scanned(.rentReceipt, date: recent, suggestions: [strong])), .leave(.notRelevant))
        XCTAssertEqual(decide(scanned(.other, date: recent, suggestions: [])), .leave(.notRelevant))
        var working = scanned(.condominioReceipt, date: recent, suggestions: [strong])
        working.relativePath = "_app-import/a.pdf"
        XCTAssertEqual(decide(working), .leave(.excluded))
        var unanalysed = scanned(.other, date: nil, suggestions: [])
        unanalysed.analysis = nil
        XCTAssertEqual(decide(unanalysed), .leave(.notAnalysed))
    }

    func testCanonicalNamesFromMoveMap() {
        let sha = String(repeating: "ab", count: 32)
        let csv = """
            old_path,new_path,action,category,doc_type,ref_date,period,amount_eur,text_status,size,sha256,dup_in_lisboa
            Old/a.pdf,"01 Mortgage/2024/20240502 - Mortgage, notice.pdf",move+rename,mortgage,Notice,2024-05,,,"text; encrypted",10,\(sha.uppercased()),
            Old/b.pdf,,keep,,,,,,,10,\(String(repeating: "cd", count: 32)),
            Old/c.pdf,x.pdf,keep,,,,,,,10,short,
            """
        XCTAssertEqual(EvidenceInitialImport.canonicalNames(fromMoveMap: csv), [sha: "20240502 - Mortgage, notice.pdf"])
        XCTAssertEqual(EvidenceInitialImport.canonicalNames(fromMoveMap: "a,b\n1,2"), [:])
    }
}
