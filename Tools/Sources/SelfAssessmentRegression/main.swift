// Sources/SelfAssessmentRegression/main.swift
//
// One-off Self Assessment regression (plan phase 4 Task 5; `SelfAssessmentRegression`): on a
// COPY of the database, optionally applies the rental-accounts regression settings
// (`TaxRegression`), loads each person-year's P60 / P45 / P11D through the reader and import
// into a scratch evidence library, records documented HMRC payments, computes the returns and
// compares their box values and SA110 figures with those filed.
//
// The settings (file paths, filed figures) are personal data kept outside the repository.
//
// Usage: swift run --package-path Tools SelfAssessmentRegression <db-copy> --settings <sa.json> --evidence <scratch-library-folder>
//          [--rental-settings <tax_regression_settings.json>] [--report <out.txt>]
//   The database and the evidence folder are written: never pass the app's own.

import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("Usage: swift run --package-path Tools SelfAssessmentRegression <db-copy> --settings <json> --evidence <folder> [--rental-settings <json>] [--report <out.txt>]\n".data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var settingsPath: String?, evidencePath: String?, rentalPath: String?, reportPath: String?
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--settings": settingsPath = remaining.popFirst() ?? { usage() }()
    case "--evidence": evidencePath = remaining.popFirst() ?? { usage() }()
    case "--rental-settings": rentalPath = remaining.popFirst() ?? { usage() }()
    case "--report": reportPath = remaining.popFirst() ?? { usage() }()
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let settingsPath, let evidencePath else { usage() }
let dbPath = paths[0]
for (path, what) in [(dbPath, "database"), (evidencePath, "evidence folder")] + (reportPath.map { [($0, "report")] } ?? []) {
    if TaxRegression.isAppDatabase(path) { fail("Refusing to write the app's own \(what): pass a copy.") }
}
if let reportPath, TaxRegression.isSameFile(reportPath, dbPath) { fail("The report path is the database: pick another file.") }
guard FileManager.default.fileExists(atPath: dbPath) else { fail("No database at \(dbPath)") }

do {
    let settings = try JSONDecoder().decode(SelfAssessmentRegression.Settings.self, from: Data(contentsOf: URL(fileURLWithPath: settingsPath)))
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()
    let library = EvidenceLibrary(root: URL(fileURLWithPath: evidencePath, isDirectory: true), database: manager.dbQueue)
    var out = "Self Assessment regression · \(dbPath)\n"
    if let rentalPath {
        let rental = try JSONDecoder().decode(TaxRegression.Settings.self, from: Data(contentsOf: URL(fileURLWithPath: rentalPath)))
        try manager.dbQueue.write { db in for line in try TaxRegression.apply(db: db, settings: rental) { out += line + "\n" } }
    }
    var rows: [SelfAssessmentRegression.Row] = []
    var results: [String: SelfAssessment.Result] = [:]
    for year in settings.personYears {
        let person = try manager.dbQueue.read { db in try SelfAssessmentRegression.person(db: db, year.person) }
        out += "\n\(UKTaxYear(startYear: year.startYear).label) \(person.name):\n"
        for form in year.forms ?? [] {
            let url = URL(fileURLWithPath: (form.path as NSString).expandingTildeInPath)
            let (extraction, result) = try SelfAssessmentRegression.importForm(library: library, url: url, personId: person.id!, startYear: year.startYear,
                                                                                kind: form.kind.flatMap(PayrollFormKind.init(rawValue:)))
            out += "  \(url.lastPathComponent): \(extraction.kind?.displayName ?? "?") \(extraction.entryMethod.rawValue) → \(result.employment.employerName)"
                + (result.income.map { " pay \(Money.format($0.payMinorUnits, currency: .gbp)) tax \(Money.format($0.taxDeductedMinorUnits, currency: .gbp))" } ?? "")
                + (result.benefits.isEmpty ? "" : " benefits " + result.benefits.map { "box \($0.sa102Box) \(Money.format($0.cashEquivalentMinorUnits, currency: .gbp))" }.joined(separator: ", "))
                + "\n"
            for warning in extraction.warnings { out += "    ! \(warning)\n" }
        }
        try manager.dbQueue.write { db in
            for payment in year.payments ?? [] { try SelfAssessmentRegression.record(db: db, payment: payment, personId: person.id!) }
        }
        let result = try manager.dbQueue.read { db in try SelfAssessment.compute(db: db, startYear: year.startYear, personId: person.id!) }
        results["\(year.startYear)|\(person.name)"] = result
        rows += try SelfAssessmentRegression.compare(person: person.name, result: result, filed: year.filed)
        if let note = year.note { out += "  Note: \(note)\n" }
    }
    let matched = rows.filter(\.matches).count
    out += "\n\(matched) of \(rows.count) figures match.\n"
    out += SelfAssessmentRegression.report(rows, results: results)
    print(out)
    if let reportPath { try out.write(toFile: reportPath, atomically: true, encoding: .utf8) }
} catch {
    fail("Failed: \(error)")
}
