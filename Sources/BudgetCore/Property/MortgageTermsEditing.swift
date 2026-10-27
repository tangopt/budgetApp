import Foundation
import GRDB

/// Mortgage terms… (Profile) as a form, shared by the Mac's sheet and the iPad's (step 10, Task 16): the fields as typed,
/// what is wrong with them in the Mac's words, the terms they build, the rate they give now, the periods a rate can be
/// given for, and the save — the terms and the rates given for single periods together, through the device writer's
/// filed-year check on the iPad (mortgage interest feeds the returns, so a change that would move a filed one is refused).
public enum MortgageTermsEditing {
    /// What the form or the terms can't be saved with, in the Mac's words.
    public struct Problem: Error, Equatable, LocalizedError, Sendable {
        public var message: String

        public init(_ message: String) { self.message = message }

        public var errorDescription: String? { message }
    }

    /// The name a filed-year question gives the save.
    public static let edit = "Mortgage terms saved"

    /// What the save reaches: every protected year (the rules can move any year's mortgage figures).
    public static let scope = FiledYearEditCheck.Scope.everyYear

    /// The rules `MortgageTerms.save` keeps, as problems (none when the terms can be saved).
    public static func validate(_ terms: PropertyMortgageTerms) -> [Problem] {
        do {
            _ = try MortgageTerms.checked(terms)
            return []
        } catch let error as MortgageTermsError {
            return [Problem(message(error))]
        } catch {
            return [Problem(error.localizedDescription)]
        }
    }

    /// A refused save's words (the Mac's `PropertyMessages`).
    public static func message(_ error: MortgageTermsError) -> String {
        switch error {
        case .invalidRevisionMonths: return "Choose at least one month the rate is revised in."
        case .negativeBalloon: return "The balloon can't be negative."
        case .invalidRate: return "Enter a rate between 0% and 50%."
        case .invalidSpread: return "Enter a spread between −5% and 20%."
        case .invalidCount: return "Enter between 1 and 1,200 instalments (and 0–10 business days, 0–6 decimals)."
        case .finalBeforeFirst: return "The final instalment is before the first."
        case .invalidAmountBorrowed: return "The amount borrowed must be more than the balloon."
        }
    }

    /// An amount field that doesn't read (the Mac's `MoneyField` words).
    public static func invalidAmount(_ text: String) -> String {
        "“\(text.trimmingCharacters(in: .whitespacesAndNewlines))” isn't a valid amount. Use digits with an optional decimal point, e.g. 1,234.56."
    }

    /// Saves `terms` and the rates given for single periods: the overrides listed replace the stored ones. In the
    /// caller's transaction; the rules broken throw `MortgageTermsError`.
    public static func apply(db: Database, terms: PropertyMortgageTerms, overrides: [MortgageRateOverride]) throws {
        try MortgageTerms.save(db: db, terms)
        let kept = Set(overrides.map { MonthRange.calendar.startOfDay(for: $0.periodStart) })
        for existing in try MortgageRate.overrides(db: db, propertyId: terms.propertyId) where !kept.contains(existing.periodStart) {
            _ = try MortgageRate.removeOverride(db: db, propertyId: terms.propertyId, periodStart: existing.periodStart)
        }
        for given in overrides {
            _ = try MortgageRate.setOverride(db: db, propertyId: terms.propertyId, periodStart: given.periodStart,
                                             ratePercent: given.ratePercent, note: given.note)
        }
    }

    /// `apply` through the device writer in Property, checking filed years: a save that would move a filed or paid
    /// return throws `DeviceWriteRefusal.filedYear` and saves nothing (nor do the writer's other refusals).
    public static func save(terms: PropertyMortgageTerms, overrides: [MortgageRateOverride], writer: DeviceWriter) async throws {
        try await writer.writeCheckingFiledYears(.property, origin: .edit, edit: edit, scope: scope) { db in
            try apply(db: db, terms: terms, overrides: overrides)
        }
    }

    /// The sheet's fields as typed, from the stored terms; nothing is saved until the caller saves `terms(today:)`.
    public struct Form: Equatable, Sendable {
        public var index: InterestIndex
        public var spreadText: String
        public var fixedRateText: String
        public var convention: MortgageFixingConvention
        public var businessDays: Int
        public var months: Set<Int>
        public var totalText: String
        public var hasFirstDate: Bool
        public var firstDate: Date?
        public var hasFinalDate: Bool
        public var finalDate: Date?
        public var balloonText: String
        public var borrowedText: String
        public var dayCount: MortgageDayCount
        public var rounding: MortgageInterestRounding
        public var indexDecimals: Int
        /// The rates given for single periods, by period.
        public var overrides: [MortgageRateOverride]
        /// The figures the terms keep from before (a note, and the fixed rate's column).
        public let stored: PropertyMortgageTerms

        public init(terms: PropertyMortgageTerms, overrides: [MortgageRateOverride]) {
            stored = terms
            index = terms.rateIndex ?? .euribor3M
            spreadText = terms.spreadPercent.map { String($0) } ?? ""
            // As stored: no rounding, so saving unchanged keeps the rate.
            fixedRateText = terms.annualRatePercent.map { String($0) } ?? ""
            convention = terms.fixingConvention
            businessDays = terms.fixingBusinessDays
            months = Set(terms.revisionMonths)
            totalText = terms.totalInstalments.map(String.init) ?? ""
            hasFirstDate = terms.firstInstalmentDate != nil
            firstDate = terms.firstInstalmentDate
            hasFinalDate = terms.finalInstalmentDate != nil
            finalDate = terms.finalInstalmentDate
            balloonText = terms.balloonMinorUnits.map { Money.formatInput($0) } ?? ""
            borrowedText = terms.amountBorrowedMinorUnits.map { Money.formatInput($0) } ?? ""
            dayCount = terms.dayCount
            rounding = terms.interestRounding
            indexDecimals = terms.indexDecimals
            self.overrides = overrides.sorted { $0.periodStart < $1.periodStart }
        }

        public var propertyId: Int64 { stored.propertyId }

        /// Save is offered once a revision month is chosen.
        public var canSave: Bool { !months.isEmpty }

        /// "On the 1st: …", or that a month is needed.
        public var scheduleNote: String {
            months.isEmpty ? "Choose at least one month" : "On the 1st: " + MortgageTerms.scheduleText(Array(months))
        }

        /// The final instalment's day from the first one's and their number, while it isn't given.
        public var derivedFinalDate: Date? {
            guard hasFirstDate, let first = firstDate, let total = Int(totalText.trimmingCharacters(in: .whitespaces)), total >= 1 else { return nil }
            return MortgageTerms.dueDate(monthsAfter: total - 1, first: first)
        }

        /// What is wrong with the fields, in the order the Mac checks them: amounts and percentages that don't read, a
        /// number of instalments that doesn't, then the rules the terms break (`validate`). Empty: Save saves.
        public func validate(today: Date) -> [Problem] {
            let balloonInput = balloonText.trimmingCharacters(in: .whitespaces)
            if !balloonInput.isEmpty, Money.parseMinorUnits(balloonInput) == nil { return [Problem(invalidAmount(balloonInput))] }
            let borrowedInput = borrowedText.trimmingCharacters(in: .whitespaces)
            if !borrowedInput.isEmpty, Money.parseMinorUnits(borrowedInput) == nil { return [Problem(invalidAmount(borrowedInput))] }
            let (text, name) = index == .fixed ? (fixedRateText, "rate") : (spreadText, "spread")
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, Self.percentValue(text) == nil {
                return [Problem("“\(text)” isn't a \(name): enter a percentage such as 1.000.")]
            }
            let totalInput = totalText.trimmingCharacters(in: .whitespaces)
            if !totalInput.isEmpty, Int(totalInput) == nil { return [Problem("“\(totalText)” isn't a number of instalments.")] }
            return MortgageTermsEditing.validate(terms(today: today))
        }

        /// The terms as the fields stand (a field that doesn't read counts as empty: `validate` says so first).
        public func terms(today: Date) -> PropertyMortgageTerms {
            let spread = Self.percentValue(spreadText)
            let fixed = Self.percentValue(fixedRateText)
            let total = Int(totalText.trimmingCharacters(in: .whitespaces))
            let balloonInput = balloonText.trimmingCharacters(in: .whitespaces)
            let balloon = balloonInput.isEmpty ? nil : Money.parseMinorUnits(balloonInput)
            let borrowedInput = borrowedText.trimmingCharacters(in: .whitespaces)
            let borrowed = borrowedInput.isEmpty ? nil : Money.parseMinorUnits(borrowedInput)
            return PropertyMortgageTerms(propertyId: stored.propertyId, revisionMonths: months.sorted(), rateNote: stored.rateNote,
                                         finalInstalmentDate: hasFinalDate ? (finalDate ?? derivedFinalDate ?? today) : nil,
                                         balloonMinorUnits: balloon == 0 ? nil : balloon,
                                         annualRatePercent: index == .fixed ? fixed : nil, rateIndex: index,
                                         spreadPercent: index == .fixed ? stored.spreadPercent : spread,
                                         fixingConvention: convention, fixingBusinessDays: businessDays, dayCount: dayCount,
                                         totalInstalments: total, firstInstalmentDate: hasFirstDate ? (firstDate ?? today) : nil,
                                         indexDecimals: indexDecimals, interestRounding: rounding,
                                         amountBorrowedMinorUnits: borrowed == 0 ? nil : borrowed)
        }

        /// "3.250% (Euribor 3M 2.250% + 1.000%) from 1 Oct 2026": the rate these rules give today; nil while they give none.
        public func preview(series: MortgageRate.Series, today: Date) -> String? {
            guard !months.isEmpty,
                  let start = MortgageRate.periodStart(containing: today, months: Array(months)) ?? (index == .fixed ? today : nil),
                  let rate = MortgageRate.rate(periodStart: start, terms: terms(today: today), series: series, overrides: overrides)
            else { return nil }
            return "\(rate.explanation) from \(MortgageTerms.dayText(start))"
        }

        /// The revision days a rate can be given for: the period in force, the next two, then the three before; not
        /// those already given.
        public func overrideChoices(today: Date) -> [Date] {
            let calendar = MonthRange.calendar
            let dates = MortgageTerms.revisionDates(months: Array(months.isEmpty ? Set(MortgageTerms.defaultRevisionMonths) : months),
                                                    from: calendar.date(byAdding: .year, value: -2, to: today)!,
                                                    to: calendar.date(byAdding: .year, value: 1, to: today)!)
            let past = Array(dates.filter { $0 <= today }.suffix(4).reversed())
            let next = Array(dates.filter { $0 > today }.prefix(2))
            let given = Set(overrides.map(\.periodStart))
            return (past.prefix(1) + next + past.dropFirst()).filter { !given.contains($0) }
        }

        /// Gives `text` as the rate of the period starting `start`; the problem when it isn't a rate.
        public mutating func addOverride(start: Date, text: String) -> Problem? {
            guard let rate = Self.percentValue(text) else {
                return Problem("“\(text)” isn't a rate: enter a percentage such as 3.250.")
            }
            overrides.append(MortgageRateOverride(propertyId: stored.propertyId, periodStart: start, ratePercent: rate))
            overrides.sort { $0.periodStart < $1.periodStart }
            return nil
        }

        /// Drops the rate given for the period starting `start` (the rules' rate applies again).
        public mutating func removeOverride(start: Date) {
            overrides.removeAll { $0.periodStart == start }
        }

        /// "2,5" or "2.5%" as 2.5; nil when empty or not a number.
        public static func percentValue(_ text: String) -> Double? {
            let input = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "")
            return input.isEmpty ? nil : Double(input)
        }
    }
}
