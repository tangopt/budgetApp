import Foundation

/// How a change would move the figures of a filed (or paid) tax year of one person: the return's
/// own lines (Self Assessment fields), the other figures of that year (information only), the
/// difference in tax, and what causes it.
public struct FiledYearImpact: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var label: String
        public var before: String
        public var after: String

        public init(label: String, before: String, after: String) {
            self.label = label
            self.before = before
            self.after = after
        }
    }

    public var startYear: Int
    public var person: String
    public var isPaid: Bool
    public var returnChanges: [Line]
    public var informationChanges: [Line]
    public var taxDifferenceMinorUnits: Int
    public var causes: [String]

    public init(startYear: Int, person: String, isPaid: Bool, returnChanges: [Line], informationChanges: [Line],
                taxDifferenceMinorUnits: Int, causes: [String]) {
        self.startYear = startYear
        self.person = person
        self.isPaid = isPaid
        self.returnChanges = returnChanges
        self.informationChanges = informationChanges
        self.taxDifferenceMinorUnits = taxDifferenceMinorUnits
        self.causes = causes
    }

    static let returnPrefix = "SA "
    static let liabilityField = "SA calculation · SA liability"

    /// One impact per (year, person) that person filed or paid, whose return figures (fields starting
    /// `"SA "`) differ between `before` and `after`; years without such a change are left out,
    /// unless `includeInformationOnly` (then a year where only other figures moved is kept, with
    /// no return changes).
    static func impacts(before: TaxFigures.Snapshot, after: TaxFigures.Snapshot, causes: [String],
                        includeInformationOnly: Bool = false) -> [FiledYearImpact] {
        let changes = TaxFigures.changes(from: before, to: after)
        let groups = Dictionary(grouping: changes) { YearPerson(startYear: $0.key.startYear, person: $0.key.person) }
        return groups.keys.sorted().compactMap { key in
            // Filed or paid is per person: another person's filed year doesn't freeze this one's.
            func closed(_ snapshot: TaxFigures.Snapshot) -> Bool {
                let status = snapshot.statuses[key.startYear]?[key.person]
                return status == .filed || status == .paid
            }
            guard closed(before) || closed(after) else { return nil }
            let fields = groups[key] ?? []
            let returnFields = fields.filter { $0.key.field.hasPrefix(returnPrefix) }
            guard !returnFields.isEmpty || (includeInformationOnly && !fields.isEmpty) else { return nil }
            func line(_ change: TaxFigures.Change, label: String) -> Line {
                Line(label: label, before: text(change.before), after: text(change.after))
            }
            let returnLines = returnFields.map { line($0, label: returnLabel($0.key.field)) }
            let information = fields.filter { !$0.key.field.hasPrefix(returnPrefix) }.map { line($0, label: $0.key.field) }
            let liability = fields.first { $0.key.field == liabilityField }
            let difference = amount(liability?.after) - amount(liability?.before)
            let status = before.statuses[key.startYear]?[key.person] ?? after.statuses[key.startYear]?[key.person]
            return FiledYearImpact(startYear: key.startYear, person: key.person, isPaid: status == .paid,
                                   returnChanges: returnLines, informationChanges: information,
                                   taxDifferenceMinorUnits: difference, causes: causes)
        }
    }

    /// `"Would change the filed 2024/25 return of Person A"` (`paid` when the year is paid).
    public var headline: String {
        "Would change the \(isPaid ? "paid" : "filed") \(UKTaxYear(startYear: startYear).label) return of \(person)"
    }

    /// The return lines that would change (`"<label>: <before> → <after>"`), the tax
    /// difference (`"Tax: £230.00 more to pay"`, `"… less to pay"`, `"Tax: no change"`) and
    /// what causes it (`"Caused by <cause>"`).
    public var explanation: [String] {
        let tax: String
        if taxDifferenceMinorUnits == 0 {
            tax = "Tax: no change"
        } else {
            let amount = Money.format(abs(taxDifferenceMinorUnits), currency: .gbp)
            tax = "Tax: \(amount) \(taxDifferenceMinorUnits > 0 ? "more" : "less") to pay"
        }
        return returnChanges.map { "\($0.label): \($0.before) → \($0.after)" } + [tax] + causes.map { "Caused by \($0)" }
    }

    /// The field without `"SA "`, its form code in capitals: `"SA sa102 Employment 1: …"` →
    /// `"SA102 Employment 1: …"`.
    static func returnLabel(_ field: String) -> String {
        let label = String(field.dropFirst(returnPrefix.count))
        let code = label.prefix { !$0.isWhitespace }
        guard code.count > 2, code.lowercased().hasPrefix("sa"), code.dropFirst(2).allSatisfy(\.isNumber) else { return label }
        return code.uppercased() + label.dropFirst(code.count)
    }

    private struct YearPerson: Hashable, Comparable {
        let startYear: Int
        let person: String
        static func < (lhs: YearPerson, rhs: YearPerson) -> Bool { (lhs.startYear, lhs.person) < (rhs.startYear, rhs.person) }
    }

    private static func text(_ value: TaxFigures.Value?) -> String {
        switch value {
        case .amount(let minorUnits): return Money.format(minorUnits, currency: .gbp)
        case .text(let text): return text
        case .missing, nil: return "—"
        }
    }

    private static func amount(_ value: TaxFigures.Value?) -> Int {
        if case .amount(let minorUnits) = value { return minorUnits }
        return 0
    }
}
