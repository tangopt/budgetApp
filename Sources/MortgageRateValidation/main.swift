// Sources/MortgageRateValidation/main.swift
//
// Checks the mortgage rate rules (MortgageRate) against what the bank actually charged: copies
// the database into memory (the file is opened read-only and never written), migrates the
// copy, saves the loan's rules given on the command line as the property's mortgage terms,
// stores the Euribor monthly averages (fetched from the ECB Data Portal, or read from a CSV
// the portal returned), then for every instalment on the mortgage account compares the
// interest charged with owed × the computed rate ÷ 12, and for every revision the instalment
// the bank reset to with the computed annuity. Prints the table and a summary per fixing
// convention; the loan's own figures come only from the database and the arguments.
//
// Usage: swift run MortgageRateValidation <db-path> --spread <percent> --total <instalments>
//          --first <YYYY-MM-DD> [--balloon <amount>] [--index euribor3m] [--ecb-csv <file>]
//          [--revisions 8] [--bank-next-rate <percent>] [--bank-next <amount>]

import Foundation
import BudgetCore
import GRDB

func usage() -> Never {
    FileHandle.standardError.write("""
        Usage: MortgageRateValidation <db-path> --spread <percent> --total <instalments> --first <YYYY-MM-DD>
               [--balloon <amount>] [--index euribor3m] [--ecb-csv <file>] [--revisions 8]
               [--bank-next-rate <percent>] [--bank-next <amount>]

        """.data(using: .utf8)!)
    exit(2)
}

func day(_ text: String) -> Date? {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return MonthRange.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}

var options: [String: String] = [:]
var paths: [String] = []
var arguments = Array(CommandLine.arguments.dropFirst())[...]
while let argument = arguments.popFirst() {
    if argument.hasPrefix("--") {
        guard let value = arguments.popFirst() else { usage() }
        options[String(argument.dropFirst(2))] = value
    } else {
        paths.append(argument)
    }
}
guard paths.count == 1, let spread = options["spread"].flatMap(Double.init), let total = options["total"].flatMap(Int.init),
      let first = options["first"].flatMap(day) else { usage() }
let index = options["index"].flatMap(InterestIndex.init(rawValue:)) ?? .euribor3M
let balloon = options["balloon"].flatMap { Money.parseMinorUnits($0) } ?? 0
let revisionCount = options["revisions"].flatMap(Int.init) ?? 8

func eur(_ minorUnits: Int) -> String { Money.format(minorUnits, currency: .eur) }
func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : String(repeating: " ", count: width - text.count) + text }
func padRight(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }

let semaphore = DispatchSemaphore(value: 0)
var fetched: [ECBEuriborFile.Observation]?
var fetchSource = ""
if let csv = options["ecb-csv"] {
    fetched = try? ECBEuriborFile.parse(String(contentsOfFile: csv, encoding: .utf8))
    fetchSource = "ECB CSV file \(URL(fileURLWithPath: csv).lastPathComponent)"
} else {
    Task {
        fetched = await ECBEuriborFetcher().fetchMonthlyAverages(for: index, startPeriod: InterestIndexValues.fetchStartPeriod)
        semaphore.signal()
    }
    semaphore.wait()
    fetchSource = ECBEuriborFile.monthlyURL(for: index, startPeriod: InterestIndexValues.fetchStartPeriod)!.absoluteString
}
guard let observations = fetched, !observations.isEmpty else {
    FileHandle.standardError.write("No Euribor values: the ECB fetch failed.\n".data(using: .utf8)!)
    exit(1)
}

do {
    var configuration = Configuration()
    configuration.readonly = true
    let source = try DatabaseQueue(path: paths[0], configuration: configuration)
    let manager = try DatabaseManager(path: nil)
    try source.backup(to: manager.dbQueue)
    try manager.migrate()
    let now = Date()

    try manager.dbQueue.write { db in
        guard let propertyId = try Int64.fetchOne(db, sql: "SELECT propertyId FROM propertyAccount WHERE role = 'mortgage' ORDER BY propertyId LIMIT 1") else {
            print("No property has a mortgage account.")
            return
        }
        var terms = try MortgageTerms.terms(db: db, propertyId: propertyId)
        terms.rateIndex = index
        terms.spreadPercent = spread
        terms.totalInstalments = total
        terms.firstInstalmentDate = first
        terms.finalInstalmentDate = nil
        terms.balloonMinorUnits = balloon == 0 ? nil : balloon
        terms.fixingConvention = .previousMonthAverage
        try MortgageTerms.save(db: db, terms)
        terms = try MortgageTerms.terms(db: db, propertyId: propertyId)
        try InterestIndexValues.storeFetched(db: db, index: index, values: observations, now: now)
        let series = try MortgageRate.Series.load(db: db, index: index)

        let charged = try MortgageRate.chargedInstalments(db: db, propertyId: propertyId, paymentDay: terms.paymentDay!)
        let derivedDays = Set(try Date.fetchAll(db, sql: """
            SELECT date FROM transaction_ WHERE accountId IN (SELECT accountId FROM propertyAccount WHERE propertyId = ? AND role = 'mortgage')
            AND amountMinorUnits < 0 AND note LIKE '%Interest derived%'
            """, arguments: [propertyId]).map { MonthRange.calendar.startOfDay(for: $0) })

        print("Mortgage rate validation — \(MortgageTerms.dayText(MonthRange.calendar.startOfDay(for: now)))")
        print("Database: read-only copy, migrated in memory (nothing written)")
        print("Rules: \(index.displayName) + \(MortgageRate.percent(spread)), revised \(MortgageTerms.scheduleText(terms.revisionMonths)), "
              + "\(total) instalments from \(MortgageTerms.dayText(first)) to \(terms.effectiveFinalInstalmentDate.map(MortgageTerms.dayText) ?? "?"), "
              + "balloon \(eur(balloon)), \(terms.dayCount.rawValue), index rounded to \(terms.indexDecimals) decimals, interest rounded to the nearest cent")
        print("Euribor: \(observations.count) monthly averages, \(fetchSource)")
        print("")

        // Each instalment: the bank's interest against owed × rate ÷ 12, by convention.
        struct Alternative { let name: String; let monthsBefore: Int }
        let alternatives = [Alternative(name: "average of the previous month (default)", monthsBefore: 1),
                            Alternative(name: "average of the revision month itself", monthsBefore: 0),
                            Alternative(name: "average of two months before", monthsBefore: 2)]
        func rate(_ start: Date, monthsBefore: Int) -> Double? {
            let month = MonthRange.calendar.date(byAdding: .month, value: -monthsBefore, to: start)!
            return series.monthly[month].map { MortgageRate.round(MortgageRate.round($0, decimals: terms.indexDecimals) + spread, decimals: 3) }
        }
        var exact = Array(repeating: 0, count: alternatives.count), compared = 0, noticeExact = 0, noticeCompared = 0
        var maxDiff = Array(repeating: 0, count: alternatives.count)
        print("Per instalment (interest: bank vs owed × computed rate ÷ 12; * = the import derived the bank's split, not from a notice)")
        print(padRight("Paid", 12) + padRight("Due", 12) + pad("No.", 5) + pad("Owed before", 15) + pad("Rate", 9) + pad("Bank int.", 12)
              + pad("Computed", 12) + pad("Diff", 8) + pad("Paid", 12))
        for item in charged {
            guard let start = MortgageRate.periodStart(containing: item.due, months: terms.revisionMonths),
                  let period = MortgageRate.rate(periodStart: start, terms: terms, series: series) else { continue }
            let computed = MortgageRate.interest(owed: item.owedBeforeMinorUnits, annualRatePercent: period.ratePercent, dayCount: terms.dayCount,
                                                 previousDue: nil, due: item.due, rounding: terms.interestRounding)
            let diff = item.interestMinorUnits - computed
            let derived = derivedDays.contains(item.paidOn)
            compared += 1
            if !derived { noticeCompared += 1; if diff == 0 { noticeExact += 1 } }
            for (i, alternative) in alternatives.enumerated() {
                guard let r = rate(start, monthsBefore: alternative.monthsBefore) else { continue }
                let c = MortgageRate.interest(owed: item.owedBeforeMinorUnits, annualRatePercent: r, dayCount: terms.dayCount, previousDue: nil,
                                              due: item.due, rounding: terms.interestRounding)
                if c == item.interestMinorUnits { exact[i] += 1 }
                maxDiff[i] = max(maxDiff[i], abs(c - item.interestMinorUnits))
            }
            print(padRight(MissingEvidenceDay.text(item.paidOn), 12) + padRight(MissingEvidenceDay.text(item.due), 12)
                  + pad(terms.instalmentNumber(dueIn: item.due).map(String.init) ?? "?", 5) + pad(eur(item.owedBeforeMinorUnits), 15)
                  + pad(MortgageRate.percent(period.ratePercent), 9) + pad(eur(item.interestMinorUnits), 12) + pad(eur(computed), 12)
                  + pad(eur(diff), 8) + pad(eur(item.paidMinorUnits), 12) + (derived ? " *" : ""))
        }
        print("")
        print("Fixing conventions (\(compared) instalments; interest equal to the cent / largest difference):")
        for (i, alternative) in alternatives.enumerated() {
            print("  \(padRight(alternative.name, 42)) \(exact[i])/\(compared) exact, largest difference \(eur(maxDiff[i]))")
        }
        print("  value N business days before the revision     not testable: the ECB Data Portal publishes no daily Euribor")
        print("  Default convention: interest from the notices \(noticeExact)/\(noticeCompared) exact to the cent")
        print("")

        // Each revision: the bank's instalment against the annuity the rules give.
        var periods: [(start: Date, items: [MortgageRate.ChargedInstalment])] = []
        for item in charged {
            guard let start = MortgageRate.periodStart(containing: item.due, months: terms.revisionMonths) else { continue }
            if periods.last?.start == start { periods[periods.count - 1].items.append(item) } else { periods.append((start, [item])) }
        }
        print("Last \(revisionCount) revisions (instalment: bank vs annuity for owed at the revision over the instalments left, leaving the balloon)")
        print(padRight("Revision", 13) + padRight("Fixing", 22) + pad("Euribor", 9) + pad("Rate", 9) + pad("Implied", 9) + pad("Owed", 15)
              + pad("Left", 6) + pad("Bank", 12) + pad("Computed", 12) + pad("Diff", 8) + "   Interest diffs in the period")
        var instalmentDiffs: [Int] = []
        for period in periods.suffix(revisionCount) {
            guard let firstItem = period.items.first, let rate = MortgageRate.rate(periodStart: period.start, terms: terms, series: series),
                  let number = terms.instalmentNumber(dueIn: firstItem.due) else { continue }
            let left = total - number + 1
            let computed = MortgageRate.instalment(owed: firstItem.owedBeforeMinorUnits, annualRatePercent: rate.ratePercent, remaining: left, balloon: balloon) ?? 0
            let implied = Double(firstItem.interestMinorUnits) * 1200 / Double(firstItem.owedBeforeMinorUnits)
            let interestDiffs = period.items.map { item in
                item.interestMinorUnits - MortgageRate.interest(owed: item.owedBeforeMinorUnits, annualRatePercent: rate.ratePercent, dayCount: terms.dayCount,
                                                                previousDue: nil, due: item.due, rounding: terms.interestRounding)
            }
            instalmentDiffs.append(firstItem.paidMinorUnits - computed)
            let derived = period.items.contains { derivedDays.contains($0.paidOn) }
            print(padRight(MortgageTerms.dayText(period.start), 13) + padRight(rate.fixing?.dateText ?? "-", 22)
                  + pad(rate.fixing.map { String(format: "%.3f", $0.valuePercent) } ?? "-", 9) + pad(MortgageRate.percent(rate.ratePercent), 9)
                  + pad(MortgageRate.percent(implied), 9) + pad(eur(firstItem.owedBeforeMinorUnits), 15) + pad(String(left), 6)
                  + pad(eur(firstItem.paidMinorUnits), 12) + pad(eur(computed), 12) + pad(eur(firstItem.paidMinorUnits - computed), 8)
                  + "   " + interestDiffs.map { eur($0) }.joined(separator: " ") + (derived ? "  *" : ""))
        }
        print("Largest instalment difference over these revisions: \(eur(instalmentDiffs.map(abs).max() ?? 0))")
        print("")

        // Now: the rate in force and the next instalment, as Profile shows them.
        let today = MonthRange.calendar.startOfDay(for: now)
        if let status = try MortgageRate.status(db: db, propertyId: propertyId, today: today) {
            print("Now (\(MortgageTerms.dayText(today))): \(status.current?.explanation ?? "no rate")"
                  + ", next revision \(status.nextRevision.map(MortgageTerms.dayText) ?? "-")"
                  + ", next instalment \(status.nextInstalmentMinorUnits.map(eur) ?? "-") due \(status.nextDue.map(MortgageTerms.dayText) ?? "-")"
                  + " (\(status.remainingInstalments.map(String.init) ?? "?") left)")
            if let bankRate = options["bank-next-rate"] { print("  bank's rate for the period: \(bankRate)%") }
            if let bankNext = options["bank-next"].flatMap({ Money.parseMinorUnits($0) }) {
                print("  bank's next instalment: \(eur(bankNext)) (difference \(eur(bankNext - (status.nextInstalmentMinorUnits ?? 0))))")
            }
        }
        if let basis = try MortgageProjection.basis(db: db, propertyId: propertyId, today: today) {
            let result = MortgageProjection.project(basis.input)
            print("Projection: \(result.payments.count) instalments to \(result.finalDate.map(MortgageTerms.dayText) ?? "-"), "
                  + "final \(result.finalPaymentMinorUnits.map(eur) ?? "-"), first \(result.payments.first.map { eur($0.paidMinorUnits) } ?? "-")"
                  + (basis.heldFrom.map { ", fixing held from \(MortgageTerms.dayText($0.start)) at \($0.fixing?.dateText ?? "")" } ?? ""))
        }
    }
} catch {
    FileHandle.standardError.write("Failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}

enum MissingEvidenceDay {
    static func text(_ date: Date) -> String {
        let parts = MonthRange.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
