import XCTest
@testable import BudgetCore

/// Files set aside (spec 2026-10-24 §1): which files of a review are offered (top-level, not
/// imported, not already in the library), and Copy to a folder…, which never overwrites.
final class ImportSetAsideTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportSetAsideTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Candidates

    private func file(_ name: String, sha: String) -> ImportFile {
        ImportFile(url: folder.appendingPathComponent(name), fileName: name, sha256: sha, byteCount: 10, fileExtension: "pdf",
                   text: "text of \(name)", textStatus: .text, usedOCR: false)
    }

    private func item(_ name: String, sha: String? = nil, kind: ImportKind = .evidence(.other), confidence: ImportConfidence = .certain,
                      reason: String = "Read", leftOut: Bool = false, parent: UUID? = nil, duplicate: ImportDuplicate? = nil) -> ImportItem {
        ImportItem(file: file(name, sha: sha ?? "sha-\(name)"), recognition: ImportRecognition(kind: kind, confidence: confidence, reason: reason),
                   title: name, duplicate: duplicate, parentId: parent, isLeftOut: leftOut)
    }

    /// A review: one ready file, a file left out with nothing to say, one not recognised and left
    /// out, a statement left out with a row of its own, a file identical to a library document,
    /// a probable duplicate of a library document.
    private func review() -> ImportPlan {
        let statement = item("statement.csv", kind: .bankStatementCSV, leftOut: true)
        return ImportPlan(items: [
            item("ready.pdf", kind: .evidence(.repairInvoice)),
            item("chosen.pdf", kind: .evidence(.insuranceReceipt), leftOut: true),
            item("unknown.pdf", kind: .unknown, confidence: .needsReview, reason: "Not recognised", leftOut: true),
            statement,
            item("row 1", sha: statement.file.sha256, parent: statement.id),
            item("identical.pdf", duplicate: ImportDuplicate(level: .file, of: "Identical file: already in the library as X.pdf", existingDocumentId: 4)),
            item("identical-left-out.pdf", leftOut: true,
                 duplicate: ImportDuplicate(level: .file, of: "Identical file: already in the library as Y.pdf", existingDocumentId: 5)),
            item("probable.pdf", duplicate: ImportDuplicate(level: .document, of: "Duplicate of Z.pdf: the same invoice, ATCUD AB-1", existingDocumentId: 6)),
        ])
    }

    func testCandidatesAtConfirmAreTheLeftOutFilesNotRowsNorIdenticalLibraryFiles() {
        let candidates = ImportSetAside.candidates(review(), discarding: false)
        XCTAssertEqual(candidates.map(\.fileName), ["chosen.pdf", "unknown.pdf", "statement.csv", "probable.pdf"])
        let byName = Dictionary(uniqueKeysWithValues: candidates.map { ($0.fileName, $0) })
        XCTAssertEqual(byName["chosen.pdf"]?.reason, "Left out by you")
        XCTAssertEqual(byName["chosen.pdf"]?.recognisedAs, "Insurance receipt")
        XCTAssertEqual(byName["unknown.pdf"]?.reason, "Not recognised")
        XCTAssertEqual(byName["unknown.pdf"]?.recognisedAs, "Unknown")
        XCTAssertEqual(byName["probable.pdf"]?.reason, "Duplicate of Z.pdf: the same invoice, ATCUD AB-1")
        let chosen = try? XCTUnwrap(byName["chosen.pdf"])
        XCTAssertEqual(chosen?.sha256, "sha-chosen.pdf")
        XCTAssertEqual(chosen?.text, "text of chosen.pdf")
        XCTAssertEqual(chosen?.textStatus, .text)
        XCTAssertEqual(chosen?.byteCount, 10)
        XCTAssertEqual(chosen?.url, folder.appendingPathComponent("chosen.pdf"))
    }

    func testCandidatesWhenDiscardingAreEveryFileButIdenticalLibraryFiles() {
        let candidates = ImportSetAside.candidates(review(), discarding: true)
        XCTAssertEqual(candidates.map(\.fileName), ["ready.pdf", "chosen.pdf", "unknown.pdf", "statement.csv", "probable.pdf"])
        XCTAssertEqual(candidates.first?.reason, "Import discarded")
        XCTAssertEqual(candidates.first?.recognisedAs, "Repair bill")
    }

    func testCandidatesNameCustomKindsAndListAFileOnce() {
        var plan = ImportPlan(items: [
            item("a.pdf", sha: "same", kind: .customEvidence(.saved(3)), leftOut: true),
            item("a copy.pdf", sha: "same", leftOut: true, duplicate: ImportDuplicate(level: .file, of: "Identical file: same as a.pdf in this import")),
        ])
        plan.pendingKinds = []
        let names = ImportKindNames([.saved(3): ImportCustomKind(key: .saved(3), name: "Boiler service", area: .property)])
        let candidates = ImportSetAside.candidates(plan, discarding: false, names: names)
        XCTAssertEqual(candidates.map(\.fileName), ["a.pdf"])
        XCTAssertEqual(candidates.first?.recognisedAs, "Boiler service")
    }

    // MARK: Copy to a folder

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func setAside(_ url: URL, name: String) -> SetAsideFile {
        SetAsideFile(url: url, fileName: name, sha256: "sha-\(name)", byteCount: 1, text: nil, textStatus: .noText,
                     reason: "Left out by you", recognisedAs: "Other")
    }

    func testCopyToAFolderNumbersClashesAndNeverOverwrites() throws {
        let original = folder.appendingPathComponent("Drop/a.pdf")
        try write("the original", to: original)
        let target = folder.appendingPathComponent("Target", isDirectory: true)
        let existing = target.appendingPathComponent("a.pdf")
        let taken = target.appendingPathComponent("a 2.pdf")
        try write("already there", to: existing)
        try write("also there", to: taken)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [original, existing] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }

        let result = ImportSetAside.copy([setAside(original, name: "a.pdf"), setAside(original, name: "a.pdf")],
                                         waitingCopy: { _ in nil }, to: target)
        XCTAssertEqual(result.copied.map(\.lastPathComponent), ["a 3.pdf", "a 4.pdf"])
        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a 3.pdf"), encoding: .utf8), "the original")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "already there")
        XCTAssertEqual(try String(contentsOf: taken, encoding: .utf8), "also there")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: existing.path)[.modificationDate] as? Date, old)
        // The original: same bytes, same modification date.
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "the original")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date, old)
    }

    func testCopyNumbersANameWithoutExtension() throws {
        let original = folder.appendingPathComponent("Drop/README")
        try write("notes", to: original)
        let target = folder.appendingPathComponent("Target", isDirectory: true)
        try write("there", to: target.appendingPathComponent("README"))
        let result = ImportSetAside.copy([setAside(original, name: "README")], waitingCopy: { _ in nil }, to: target)
        XCTAssertEqual(result.copied.map(\.lastPathComponent), ["README 2"])
    }

    func testCopyFallsBackToTheWaitingCopy() throws {
        let gone = folder.appendingPathComponent("Drop/b.pdf")
        let waitingCopy = folder.appendingPathComponent("Waiting/sha-b.pdf/b.pdf")
        try write("Mango's copy", to: waitingCopy)
        let missing = folder.appendingPathComponent("Drop/c.pdf")
        let target = folder.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let result = ImportSetAside.copy([setAside(gone, name: "b.pdf"), setAside(missing, name: "c.pdf")],
                                         waitingCopy: { sha in sha == "sha-b.pdf" ? waitingCopy : nil }, to: target)
        XCTAssertEqual(result.copied.map(\.lastPathComponent), ["b.pdf"])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("b.pdf"), encoding: .utf8), "Mango's copy")
        XCTAssertEqual(result.failed.map(\.fileName), ["c.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: waitingCopy.path), "Mango's copy stays")
    }
}
