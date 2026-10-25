// Sources/TaxRegression/main.swift
//
// One-off rental-accounts regression (plan phase 3 Task 5; `TaxRegression`): on a COPY of the
// database, writes the regression settings (HMRC rates implied by the filed returns, splits,
// GBP manual items), computes each filed person-year's rental accounts and compares them line
// by line with the filed figures from the history CSV; prints the report, with the sources of
// every line that differs and, for the apportioned lines, the figure under each rule.
//
// The settings and history are personal data files kept outside the repository.
//
// Usage: swift run --package-path Tools TaxRegression <db-copy> --history <history.csv> --settings <settings.json> [--report <out.txt>] [--no-apply]
//   The database is written (settings applied): never pass the real one.
//   --no-apply  compares what the stored records give (the app's own settings), writing nothing but the
//               rule-alternatives savepoints (rolled back): only the settings' property, personAliases and
//               years[].startYear are read (eurGbpPerUnit may be left out).

import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("Usage: swift run --package-path Tools TaxRegression <db-copy> --history <csv> --settings <json> [--report <out.txt>] [--no-apply]\n".data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

var historyPath: String?, settingsPath: String?, reportPath: String?
var applySettings = true
var paths: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    switch argument {
    case "--history": historyPath = remaining.popFirst() ?? { usage() }()
    case "--settings": settingsPath = remaining.popFirst() ?? { usage() }()
    case "--report": reportPath = remaining.popFirst() ?? { usage() }()
    case "--no-apply": applySettings = false
    default:
        if argument.hasPrefix("--") { usage() }
        paths.append(argument)
    }
}
guard paths.count == 1, let historyPath, let settingsPath else { usage() }
let dbPath = paths[0]
if TaxRegression.isAppDatabase(dbPath) { fail("Refusing to write the app's own database: pass a copy.") }
if let reportPath {
    if TaxRegression.isAppDatabase(reportPath) { fail("Refusing to write the report into the app's data folder.") }
    if TaxRegression.isSameFile(reportPath, dbPath) { fail("The report path is the database: pick another file.") }
}
guard FileManager.default.fileExists(atPath: dbPath) else { fail("No database at \(dbPath)") }

do {
    let settings = try JSONDecoder().decode(TaxRegression.Settings.self, from: Data(contentsOf: URL(fileURLWithPath: settingsPath)))
    let filed = TaxRegression.parseHistory(try String(contentsOfFile: historyPath, encoding: .utf8))
    let manager = try DatabaseManager(path: dbPath)
    try manager.migrate()
    var out = "Rental accounts regression · \(dbPath)\(applySettings ? "" : " (stored settings only)")\n"
    try manager.dbQueue.write { db in
        if applySettings { for line in try TaxRegression.apply(db: db, settings: settings) { out += line + "\n" } }
        let (accounts, comparisons) = try TaxRegression.compare(db: db, settings: settings, filed: filed)
        out += TaxRegression.report(comparisons, accounts: accounts)

        // The apportioned lines under each rule, whole property.
        guard let property = try Property.filter(sql: "name = ? COLLATE NOCASE", arguments: [settings.property]).fetchOne(db),
              let person = try Person.order(Column("id")).fetchOne(db) else { return }
        out += "\n== Rule alternatives (whole property, EUR) ==\n"
        for year in settings.years {
            for type in [TaxExpenseType.serviceCharge, .insurance, .councilTax, .financeCost, .accountancy, .otherExpense] {
                let alternatives = try TaxRegression.ruleAlternatives(db: db, propertyId: property.id!, personId: person.id!, startYear: year.startYear, type: type)
                out += "\(UKTaxYear(startYear: year.startYear).label) \(type.displayName): "
                    + alternatives.map { "\($0.0) \(Money.format($0.1, currency: .eur))" }.joined(separator: " · ") + "\n"
            }
        }
    }
    print(out)
    if let reportPath { try out.write(toFile: reportPath, atomically: true, encoding: .utf8) }
} catch {
    fail("Failed: \(error)")
}
