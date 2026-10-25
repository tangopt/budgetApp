import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The tax archive import (`ImportTaxArchive`): payroll forms become employment records only
/// where a year has none, records from a filed return are kept and the form linked to them,
/// the other files go through the importer, and the filed figures guard refuses a run that
/// leaves a filed figure neither as filed nor as before. Synthetic people, forms and figures.
final class TaxArchiveImportTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }
    private var folder: URL!
    private var archive: URL!
    private var library: EvidenceLibrary!
    private var personA: Person!
    private var personB: Person!

    override func setUpWithError() throws {
        manager = try TestDatabase.migratedManager()
        try db.write { db in
            var a = Person(name: "Person A", shortName: "A", ukNino: "QQ123456C")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B", ukNino: "QQ654321A")
            try People.save(db: db, &b)
            personA = a
            personB = b
            var year = try TaxYears.ensure(db: db, startYear: 2024, personId: a.id!)
            year.status = .filed
            try TaxYears.save(db: db, &year)
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TaxArchiveImportTests-\(UUID().uuidString)", isDirectory: true)
        archive = folder.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive.appendingPathComponent("SA 2024:25", isDirectory: true), withIntermediateDirectories: true)
        library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: db)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The synthetic P60 (Person A's National Insurance number, Example Ltd, 2024/25, £45,678.90 pay, £6,543.21 tax) in the year's folder.
    private func placeP60(named name: String = "P60 - A - 2025.pdf") throws -> URL {
        let made = PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p60RowLayout, name: "p60.pdf")
        let target = archive.appendingPathComponent("SA 2024:25", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.copyItem(at: made, to: target)
        return target
    }

    private func settings(pay: String = "45678", tax: String = "6544") -> SelfAssessmentRegression.Settings {
        SelfAssessmentRegression.Settings(personYears: [
            .init(person: "Person A", startYear: 2024, forms: nil, payments: nil, filed: ["sa102.1": pay, "sa102.2": tax], note: nil)
        ])
    }

    private func run(_ options: TaxArchiveImport.Options) async throws -> TaxArchiveImport.Report {
        try await TaxArchiveImport.run(dbQueue: db, library: library, options: options)
    }

    /// A synchronous read (the async tests would otherwise pick the async overload).
    private func read<T>(_ body: (Database) throws -> T) throws -> T { try manager.dbQueue.read(body) }
    private func write<T>(_ body: (Database) throws -> T) throws -> T { try manager.dbQueue.write(body) }

    // MARK: Payroll forms

    func testP60RecordsTheEmploymentOfAYearWithoutOneAndLinksTheYear() async throws {
        _ = try placeP60()
        var options = TaxArchiveImport.Options(folder: archive, filed: settings())
        options.allowOCR = false
        let report = try await run(options)

        XCTAssertEqual(report.count(.recorded), 1, report.text)
        XCTAssertTrue(report.passed, report.refusals.joined(separator: "\n"))
        let personId = personA.id!
        let (employments, income, links) = try read { db -> ([Employment], Employments.EffectiveIncome?, [DocumentLink]) in
            let employments = try Employments.employments(db: db, startYear: 2024, personId: personId)
            let income = try employments.first.flatMap { try Employments.effectiveIncome(db: db, employmentId: $0.id!) }
            let document = try EvidenceDocument.fetchOne(db)!
            return (employments, income, try EvidenceLinks.links(db: db, for: document.id!))
        }
        XCTAssertEqual(employments.map(\.employerName), ["Example Ltd"])
        XCTAssertEqual(income?.payMinorUnits, 4_567_890)
        XCTAssertEqual(income?.taxDeductedMinorUnits, 654_321)
        XCTAssertEqual(Set(links.map(\.entityType)), [.employmentIncome, .taxYear])
        // The guard: the SA102 figures now equal the return (pay rounded down, tax up).
        XCTAssertEqual(report.guardRows.map(\.after), [4_567_800, 654_400])
        XCTAssertTrue(report.guardRows.allSatisfy(\.matchesFiled))

        // Again: the form is already in the library and the year has the employer: linked, nothing changed.
        let again = try await run(options)
        XCTAssertEqual(again.count(.recorded), 0, again.text)
        XCTAssertEqual(again.count(.linkedToExisting), 1, again.text)
        XCTAssertTrue(again.passed)
        XCTAssertEqual(try read { try Employment.fetchCount($0) }, 1)
        XCTAssertEqual(try read { try EvidenceDocument.fetchCount($0) }, 1)
    }

    func testFormIsLinkedToTheRecordFromTheReturnAndItsFiguresAreKept() async throws {
        let personId = personA.id!
        try write { db in
            var employment = Employment(startYear: 2024, personId: personId, employerName: "Example Ltd", payeReference: "123/AB456",
                                        notes: "From the filed return")
            try Employments.save(db: db, &employment)
            // As filed: whole pounds, not the form's pence.
            var row = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: 4_567_800, taxDeductedMinorUnits: 654_400)
            try Employments.save(db: db, &row)
        }
        _ = try placeP60()
        var options = TaxArchiveImport.Options(folder: archive, filed: settings())
        options.allowOCR = false
        let report = try await run(options)

        XCTAssertEqual(report.count(.linkedToExisting), 1, report.text)
        XCTAssertEqual(report.count(.recorded), 0)
        XCTAssertTrue(report.passed)
        let outcome = report.files.first { $0.kind == .linkedToExisting }!
        XCTAssertTrue(outcome.detail.contains("figures kept"), outcome.detail)
        XCTAssertTrue(outcome.detail.contains("£45,678.90"), outcome.detail)
        let income = try read { db in try Employments.effectiveIncome(db: db, employmentId: try Employment.fetchOne(db)!.id!) }
        XCTAssertEqual(income?.payMinorUnits, 4_567_800)
        XCTAssertEqual(income?.taxDeductedMinorUnits, 654_400)
        XCTAssertEqual(try read { try EvidenceLinks.links(db: $0, for: try EvidenceDocument.fetchOne($0)!.id!).map(\.entityType) }.sorted { $0.rawValue < $1.rawValue },
                       [.employmentIncome, .taxYear])
    }

    func testFormOfAnotherEmployerInAClosedYearSetUpFromTheReturnIsFiledNotRecorded() async throws {
        let personId = personA.id!
        try write { db in
            var employment = Employment(startYear: 2024, personId: personId, employerName: "Other Employer", payeReference: "999/ZZ999")
            try Employments.save(db: db, &employment)
            var row = EmploymentIncome(employmentId: employment.id!, source: .p60, payMinorUnits: 4_000_000, taxDeductedMinorUnits: 600_000)
            try Employments.save(db: db, &row)
        }
        _ = try placeP60()
        var options = TaxArchiveImport.Options(folder: archive)
        options.allowOCR = false
        let report = try await run(options)

        XCTAssertEqual(report.count(.needsYou), 1, report.text)
        XCTAssertEqual(try read { try Employment.fetchCount($0) }, 1)
        let outcome = report.files.first { $0.kind == .needsYou }!
        XCTAssertTrue(outcome.reasons.first?.contains("recorded from the return") == true, outcome.reasons.joined())
        // Filed and linked to the year all the same.
        XCTAssertEqual(try read { try EvidenceDocument.fetchCount($0) }, 1)
        XCTAssertEqual(try read { try EvidenceLinks.links(db: $0, for: try EvidenceDocument.fetchOne($0)!.id!).map(\.entityType) }, [.taxYear])
    }

    func testToleranceOnlyForTheYearsBefore2020AndAtMostAPound() {
        func year(_ start: Int, _ tolerance: Int?) -> SelfAssessmentRegression.Settings.PersonYear {
            .init(person: "A", startYear: start, filed: [:], tolerancePence: tolerance)
        }
        XCTAssertEqual(TaxArchiveImport.tolerance(year(2024, 100)), 1)
        XCTAssertEqual(TaxArchiveImport.tolerance(year(2020, 5)), 1)
        XCTAssertEqual(TaxArchiveImport.tolerance(year(2019, 100)), 100)
        XCTAssertEqual(TaxArchiveImport.tolerance(year(2019, 5_000)), 100)
        XCTAssertEqual(TaxArchiveImport.tolerance(year(2019, nil)), 1)
        XCTAssertEqual(TaxArchiveImport.tolerance(year(2019, 0)), 1)
    }

    func testGuardAcceptsAFigureThatMovesTowardsTheReturn() {
        // Pay was missing (nil) and is now as filed; a figure nearer the return than before passes; one further away doesn't.
        XCTAssertTrue(TaxArchiveImport.GuardRow(person: "A", startYear: 2024, label: "pay", filed: 100, before: nil, after: 100).ok)
        XCTAssertTrue(TaxArchiveImport.GuardRow(person: "A", startYear: 2024, label: "x", filed: 100, before: 10, after: 90).ok)
        XCTAssertFalse(TaxArchiveImport.GuardRow(person: "A", startYear: 2024, label: "x", filed: 100, before: 90, after: 10).ok)
        XCTAssertFalse(TaxArchiveImport.GuardRow(person: "A", startYear: 2024, label: "x", filed: 100, before: 100, after: 90).ok)
        XCTAssertTrue(TaxArchiveImport.GuardRow(person: "A", startYear: 2024, label: "x", filed: 100, before: 90, after: 90).ok)
        XCTAssertFalse(TaxArchiveImport.GuardRow(person: "A", startYear: 2024, label: "x", filed: 100, before: nil, after: 90).ok)
        // Absent before and after (the year couldn't be computed): not a pass.
        XCTAssertFalse(TaxArchiveImport.GuardRow(person: "A", startYear: 2024, label: "x", filed: 100, before: nil, after: nil).ok)
    }

    func testGuardRefusesWhenAFiledFigureEndsUpNeitherAsFiledNorAsBefore() async throws {
        _ = try placeP60()
        var options = TaxArchiveImport.Options(folder: archive, filed: settings(pay: "40000", tax: "6544"))
        options.allowOCR = false
        let report = try await run(options)

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.refusals.count, 1, report.refusals.joined(separator: "\n"))
        XCTAssertTrue(report.refusals[0].contains("SA102 box 1 pay"), report.refusals[0])
        XCTAssertTrue(report.text.contains("REFUSED"))
    }


    func testP11DBeforeItsP60BothRecordOnTheSameEmployment() async throws {
        // Named so the P11D is read first: the employment it creates still takes the P60's pay.
        let p11d = PayrollFormTestPDFs.textPDF(PayrollFormTestPDFs.p11d, name: "p11d.pdf")
        try FileManager.default.copyItem(at: p11d, to: archive.appendingPathComponent("SA 2024:25", isDirectory: true).appendingPathComponent("Person A - P11D 2025.pdf"))
        _ = try placeP60(named: "Person A - P60 2025.pdf")
        var options = TaxArchiveImport.Options(folder: archive)
        options.allowOCR = false
        let report = try await run(options)

        XCTAssertEqual(report.count(.recorded), 2, report.text)
        XCTAssertEqual(try read { try Employment.fetchCount($0) }, 1)
        let personId = personA.id!
        let (income, benefits) = try read { db -> (Employments.EffectiveIncome?, [BenefitInKind]) in
            let employment = try Employments.employments(db: db, startYear: 2024, personId: personId)[0]
            return (try Employments.effectiveIncome(db: db, employmentId: employment.id!), try Employments.benefits(db: db, employmentId: employment.id!))
        }
        XCTAssertEqual(income?.payMinorUnits, 4_567_890)
        XCTAssertEqual(benefits.map(\.cashEquivalentMinorUnits).sorted(), [5_000, 123_456, 300_000])
    }

    // MARK: The other files

    func testWorkpapersAreFiledForTheirYearZipsSkippedAndUnsureFilesLeftForTheReview() async throws {
        let year = archive.appendingPathComponent("SA 2024:25", isDirectory: true)
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: year.appendingPathComponent("Supporting Documents.zip"))
        try Data("not really a workbook".utf8).write(to: year.appendingPathComponent("Template - 2024.25 - Person A.xlsx"))
        let note = EvidenceTestPDFs.textPDF(["Synthetic words only", "Nothing to recognise here"], name: "note.pdf")
        try FileManager.default.copyItem(at: note, to: year.appendingPathComponent("note.pdf"))
        var options = TaxArchiveImport.Options(folder: archive)
        options.allowOCR = false
        let report = try await run(options)

        XCTAssertEqual(report.count(.skipped), 1, report.text)
        XCTAssertEqual(report.count(.filed), 1, report.text)
        XCTAssertEqual(report.count(.needsYou), 1, report.text)
        let workpaper = report.files.first { $0.kind == .filed }!
        XCTAssertTrue(workpaper.detail.contains("Person A 2024/25"), workpaper.detail)
        let document = try read { try EvidenceDocument.fetchOne($0, key: workpaper.documentId!)! }
        XCTAssertEqual(document.kind, .other)
        XCTAssertEqual(document.persons, ["Person A"])
        XCTAssertTrue(document.canonicalName?.contains("Accountant workpaper") == true, document.canonicalName ?? "")
        XCTAssertEqual(try read { try EvidenceLinks.links(db: $0, for: document.id!).map(\.entityType) }, [.taxYear])
        XCTAssertEqual(report.files.first { $0.kind == .needsYou }?.relativePath, "SA 2024:25/note.pdf")
    }

    // MARK: Telling the person and the year

    func testYearFromPathAndText() {
        XCTAssertEqual(TaxArchiveImport.startYear(inPath: "SA 2022:23/P60_Person A_2022-23.pdf"), 2022)
        XCTAssertEqual(TaxArchiveImport.startYear(inPath: "SA 2023:24/Template - 2023.24 - A.xlsx"), 2023)
        XCTAssertEqual(TaxArchiveImport.startYear(inPath: "WDF 2015:16-2019:20/Documents/UK Income/P60-2016-17.pdf"), 2015)
        XCTAssertEqual(TaxArchiveImport.startYear(inPath: "Documents/UK Income/P60-2016-17.pdf"), 2016)
        XCTAssertEqual(TaxArchiveImport.startYear(inPath: "A_SA 21.22 - Tax return.pdf"), 2021)
        XCTAssertNil(TaxArchiveImport.startYear(inPath: "HMRC/Person B UTR.pdf"))
        XCTAssertNil(TaxArchiveImport.startYear(inPath: "Invoice INV-10001-2.pdf"))

        XCTAssertEqual(TaxArchiveImport.startYear(inText: "HMRC Tax Calculation Summary - SA302\nCalculation Result for 2023-24"), 2023)
        XCTAssertEqual(TaxArchiveImport.startYear(inText: "This is to tell you your tax code(s) for 6 April 2025 to 5 April 2026"), 2025)
        XCTAssertEqual(TaxArchiveImport.startYear(inText: "Tax year to 5 April 2022 This is a printed copy of an eP60"), 2021)
        XCTAssertEqual(TaxArchiveImport.startYear(inText: "P11D Expenses and benefits 2018 to 2019"), 2018)
        XCTAssertEqual(TaxArchiveImport.startYear(inText: "Tax return for the year ended 5 April 2021"), 2020)
        XCTAssertNil(TaxArchiveImport.startYear(inText: "Nothing about a year"))
        XCTAssertNil(TaxArchiveImport.startYear(inText: nil))
    }

    func testPersonFromPathAndFromText() {
        let people = [personA!, personB!]
        XCTAssertEqual(TaxArchiveImport.personNamed(in: "SA 2022:23/P60_Person A_2022-23.pdf", people: people)?.id, personA.id)
        XCTAssertEqual(TaxArchiveImport.personNamed(in: "Templates/Template - 2023.24 - person.xlsx", people: people)?.id, nil)
        // The short name alone doesn't count (one letter); both names in one path is nobody's.
        XCTAssertNil(TaxArchiveImport.personNamed(in: "SA 2022:23/A.pdf", people: people))
        XCTAssertNil(TaxArchiveImport.personNamed(in: "Person A and Person B joint.pdf", people: people))
        XCTAssertEqual(TaxArchiveImport.personMatching(text: "UTR: 1234567890 NINO: QQ 65 43 21 A", people: people)?.id, personB.id)
        XCTAssertNil(TaxArchiveImport.personMatching(text: "no numbers here", people: people))
    }
}
