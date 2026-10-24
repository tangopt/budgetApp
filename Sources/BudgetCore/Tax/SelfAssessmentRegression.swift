import GRDB
import Foundation

/// The Self Assessment regression (plan phase 4 Task 5): loads each person-year's P60 / P45 /
/// P11D through the reader and import, records documented HMRC payments, computes the return
/// and compares box values and the SA110 figures with those filed (the SA302 and the approval
/// pack). The filed figures and file paths are personal data in a JSON file outside the
/// repository; this code only knows its shape. Run on a copy of the database.
public enum SelfAssessmentRegression {
    public struct Settings: Codable, Equatable, Sendable {
        public struct Form: Codable, Equatable, Sendable {
            public var path: String
            /// "p60", "p45" or "p11d"; `nil` = recognised from the text.
            public var kind: String?
        }

        public struct Payment: Codable, Equatable, Sendable {
            /// "YYYY-MM-DD".
            public var date: String
            /// Decimal text ("123.45").
            public var amount: String
            /// An `HMRCPaymentKind` raw value.
            public var kind: String
            /// The tax year it counts towards.
            public var startYear: Int
            public var reference: String?
        }

        public struct PersonYear: Codable, Equatable, Sendable {
            public var person: String
            public var startYear: Int
            public var forms: [Form]?
            public var payments: [Payment]?
            /// Field (`fields`) → decimal text, as filed. SA110 box 1 negative when overpaid.
            public var filed: [String: String]
            public var note: String?
            /// How far (pence) the app's figure may be from `filed` and still count as equal
            /// (default 1): a disclosure worked out in pence rather than whole pounds takes 100.
            public var tolerancePence: Int?

            public init(person: String, startYear: Int, forms: [Form]? = nil, payments: [Payment]? = nil, filed: [String: String],
                        note: String? = nil, tolerancePence: Int? = nil) {
                self.person = person
                self.startYear = startYear
                self.forms = forms
                self.payments = payments
                self.filed = filed
                self.note = note
                self.tolerancePence = tolerancePence
            }
        }

        public var personYears: [PersonYear]
    }

    public enum RegressionError: Error, Equatable {
        case personNotFound(String)
        case badAmount(String)
        case badDate(String)
        case badKind(String)
        case formIncomplete(String, [PayrollFormImport.Problem])
    }

    /// The compared fields and what they are.
    public static let fields: [(key: String, label: String)] = [
        ("sa102.1", "SA102 box 1 pay"), ("sa102.2", "SA102 box 2 UK tax taken off"), ("sa102.benefits", "SA102 boxes 9–16 benefits"),
        ("sa106.F1.2", "SA106 box 2 total FTCR"), ("sa106.14", "SA106 box 14 rents"), ("sa106.15", "SA106 box 15 properties"),
        ("sa106.17", "SA106 box 17 expenses"), ("sa106.24", "SA106 box 24 adjusted profit"), ("sa106.24.1", "SA106 box 24.1 finance costs"),
        ("sa106.B", "SA106 column B profit"), ("sa106.C", "SA106 column C foreign tax"), ("sa106.F", "SA106 column F taxable"),
        ("sa106.27", "SA106 box 27 taxable profits"), ("sa106.28", "SA106 box 28 foreign tax"), ("sa106.30", "SA106 box 30 taxable amount"),
        ("calc.totalIncome", "SA302 total income received"), ("calc.personalAllowance", "SA302 personal allowance"),
        ("calc.incomeTaxCharged", "SA302 income tax charged"), ("calc.financeCostReduction", "SA302 relief for finance costs"),
        ("calc.foreignTaxCreditRelief", "SA302 Foreign Tax Credit Relief"), ("calc.incomeTaxDue", "SA302 income tax due after reductions"),
        ("calc.taxDeducted", "SA302 tax deducted"), ("sa110.1", "SA110 box 1 (negative: box 2 overpaid)"),
        ("calc.balancingPayment", "Balancing payment"), ("calc.nextPaymentOnAccount", "Each payment on account for next year")
    ]

    /// The app's figure for `field`, pence; `nil` when the return has no such value.
    public static func appValue(_ field: String, result: SelfAssessment.Result) -> Int? {
        func amount(_ box: SelfAssessment.Box?) -> Int? {
            if case let .amount(value)? = box?.value { return value }
            if case let .text(text)? = box?.value, let number = Int(text) { return number * 100 }
            return nil
        }
        func sum(_ form: SelfAssessment.Form, _ numbers: [String]) -> Int? {
            let values = result.boxes.filter { $0.form == form && numbers.contains($0.number) }.compactMap { amount($0) }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        let c = result.calculation
        switch field {
        case "sa102.1": return sum(.sa102, ["1"])
        case "sa102.2": return sum(.sa102, ["2"])
        case "sa102.benefits": return sum(.sa102, (9...16).map(String.init))
        case "sa106.F1.2": return result.box(.sa106, "2", section: "Foreign Tax Credit Relief").flatMap(amount)
        case "sa106.B", "sa106.C", "sa106.F": return sum(.sa106, [String(field.dropFirst(6))])
        case _ where field.hasPrefix("sa106."): return result.box(.sa106, String(field.dropFirst(6)), section: "Land and property abroad").flatMap(amount)
        case "sa110.1": return c.selfAssessmentLiability
        case "calc.totalIncome": return c.totalIncome
        case "calc.personalAllowance": return c.personalAllowance
        case "calc.incomeTaxCharged": return c.incomeTaxCharged
        case "calc.financeCostReduction": return c.financeCostReduction
        case "calc.foreignTaxCreditRelief": return c.foreignTaxCreditRelief
        case "calc.incomeTaxDue": return c.incomeTaxDue
        case "calc.taxDeducted": return c.taxDeducted
        case "calc.balancingPayment": return c.balancingPayment
        case "calc.nextPaymentOnAccount": return c.nextPaymentOnAccount
        default: return nil
        }
    }

    public struct Row: Equatable, Sendable {
        public var person: String
        public var startYear: Int
        public var field: String
        public var label: String
        public var filed: Int
        public var app: Int?
        public var difference: Int? { app.map { $0 - filed } }
        /// Within a penny.
        public var matches: Bool { difference.map { abs($0) <= 1 } ?? false }
    }

    /// The comparisons of a person-year, in `fields` order (fields not filed are left out).
    public static func compare(person: String, result: SelfAssessment.Result, filed: [String: String]) throws -> [Row] {
        try fields.compactMap { field in
            guard let text = filed[field.key] else { return nil }
            guard let value = Money.parseMinorUnits(text) else { throw RegressionError.badAmount(text) }
            return Row(person: person, startYear: result.taxYear.startYear, field: field.key, label: field.label, filed: value,
                       app: appValue(field.key, result: result))
        }
    }

    // MARK: Loading (on a copy)

    /// Adds the form to `library`, reads it and saves it for the person (`PayrollFormImport`);
    /// the confirmed values are the reader's, with the year given when it found none.
    @discardableResult
    public static func importForm(library: EvidenceLibrary, url: URL, personId: Int64, startYear: Int, kind: PayrollFormKind?) throws -> (PayrollFormExtraction, PayrollFormImport.Result) {
        let document = try library.addAnalyzing(url).document
        let extraction = PayrollFormReader.read(library.fileURL(for: document), kind: kind)
        guard let resolvedKind = kind ?? extraction.kind else { throw RegressionError.formIncomplete(url.lastPathComponent, [.missingTaxYear]) }
        var confirmed = PayrollFormImport.Confirmed(extraction, kind: resolvedKind, personId: personId)
        if confirmed.startYear == nil { confirmed.startYear = startYear }
        let problems = PayrollFormImport.problems(confirmed)
        guard problems.isEmpty else { throw RegressionError.formIncomplete(url.lastPathComponent, problems) }
        let result = try library.database.write { db in try PayrollFormImport.apply(db: db, confirmed, documentId: document.id) }
        return (extraction, result)
    }

    /// Records the payment (replacing one of the same person, kind, year and date).
    public static func record(db: Database, payment: Settings.Payment, personId: Int64) throws {
        guard let amount = Money.parseMinorUnits(payment.amount) else { throw RegressionError.badAmount(payment.amount) }
        guard let kind = HMRCPaymentKind(rawValue: payment.kind) else { throw RegressionError.badKind(payment.kind) }
        guard let date = day(payment.date) else { throw RegressionError.badDate(payment.date) }
        try HMRCPayment.filter(Column("personId") == personId && Column("kind") == kind.rawValue && Column("startYear") == payment.startYear
                               && Column("date") == date).deleteAll(db)
        var record = HMRCPayment(personId: personId, startYear: payment.startYear, date: date, amountMinorUnits: amount, kind: kind,
                                 reference: payment.reference, notes: "Regression setting")
        try HMRCPayments.save(db: db, &record)
    }

    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = UKTaxYear.utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        // The calendar rolls "2025-13-99" over: only an exact day counts.
        let back = UKTaxYear.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return (back.year, back.month, back.day) == (parts[0], parts[1], parts[2]) ? date : nil
    }

    public static func person(db: Database, _ name: String) throws -> Person {
        guard let person = try Person.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchOne(db) else {
            throw RegressionError.personNotFound(name)
        }
        return person
    }

    // MARK: Report

    public static func report(_ rows: [Row], results: [String: SelfAssessment.Result]) -> String {
        var out = ""
        func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
            let padding = String(repeating: " ", count: max(0, width - text.count))
            return left ? text + padding : padding + text
        }
        func money(_ value: Int?) -> String { value.map { Money.format($0, currency: .gbp) } ?? "—" }
        let groups = Dictionary(grouping: rows) { "\($0.startYear)|\($0.person)" }
        for key in groups.keys.sorted() {
            let group = groups[key]!
            out += "\n== \(UKTaxYear(startYear: group[0].startYear).label) · \(group[0].person) ==\n"
            out += " " + pad("figure", 44, left: true) + pad("filed", 14) + pad("app", 14) + pad("diff", 12) + "\n"
            for row in group {
                out += (row.matches ? " " : "*") + pad(row.label, 44, left: true) + pad(money(row.filed), 14) + pad(money(row.app), 14)
                    + pad(money(row.difference), 12) + "\n"
            }
            if let result = results[key] {
                for warning in result.warnings { out += "! \(warning)\n" }
                out += "  Steps:\n"
                for step in result.steps { out += "    \(step.title): \(step.detail)\n" }
            }
        }
        return out
    }
}
