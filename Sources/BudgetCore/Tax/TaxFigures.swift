import Foundation
import GRDB

/// Every tax figure the app computes for a set of years, flattened to named values so two runs
/// can be compared (a data step must leave filed years exactly as filed): per UK tax year and
/// person, each property's rental-account lines (whole property and the person's share, in the
/// property's currency and in pounds) and the Self Assessment's boxes and calculation.
public enum TaxFigures {
    public struct Key: Hashable, Comparable, Sendable {
        public let startYear: Int
        public let person: String
        public let field: String

        public static func < (lhs: Key, rhs: Key) -> Bool {
            (lhs.startYear, lhs.person, lhs.field) < (rhs.startYear, rhs.person, rhs.field)
        }
    }

    /// A field's value: an amount (minor units), or a text when the field isn't an amount.
    public enum Value: Equatable, Sendable, CustomStringConvertible {
        case amount(Int)
        case missing
        case text(String)

        public var description: String {
            switch self {
            case .amount(let value): return String(value)
            case .missing: return "—"
            case .text(let text): return text
            }
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public var values: [Key: Value] = [:]
        /// Year → status per person ("filed", "paid", "open").
        public var statuses: [Int: [String: TaxYearStatus]] = [:]
    }

    public struct Change: Equatable, Sendable {
        public let key: Key
        public let before: Value?
        public let after: Value?
    }

    /// The years every person has a tax year for, plus `extraYears`.
    public static func snapshot(db: Database, years extraYears: [Int] = []) throws -> Snapshot {
        try snapshot(db: db, only: years(db: db, extra: extraYears))
    }

    /// The years `snapshot(db:years:)` works out: every stored tax year's, plus `extraYears`, sorted.
    static func years(db: Database, extra extraYears: [Int] = []) throws -> [Int] {
        Set(try Int.fetchAll(db, sql: "SELECT startYear FROM taxYear") + extraYears).sorted()
    }

    /// The figures of `years` only, with every stored year's statuses. Each year is worked out
    /// on its own, so these are `snapshot(db:years:)`'s values for those years (the filed-year
    /// guard takes again only the years whose reads changed: `TaxFiguresReads`).
    /// `memo`: returns and accounts already worked out in this state of the database (else a new one).
    static func snapshot(db: Database, only years: [Int], memo: TaxComputationMemo? = nil) throws -> Snapshot {
        var snapshot = Snapshot()
        // Each year's return works out the earlier years' again (brought-forward figures) and
        // its rental accounts: worked out once here.
        let memo = memo ?? TaxComputationMemo()
        let people = try Person.order(Column("id")).fetchAll(db)
        let properties = try Property.order(Column("id")).fetchAll(db)
        let stored = try TaxYear.fetchAll(db)
        for year in stored {
            if let person = people.first(where: { $0.id == year.personId }) {
                snapshot.statuses[year.startYear, default: [:]][person.name] = year.status
            }
        }
        for year in years {
            for person in people {
                guard let personId = person.id else { continue }
                func set(_ field: String, _ value: Value) {
                    snapshot.values[Key(startYear: year, person: person.name, field: field)] = value
                }
                for property in properties {
                    guard let propertyId = property.id else { continue }
                    let owners = try Properties.owners(db: db, propertyId: propertyId)
                    guard owners.contains(where: { $0.personId == personId }) else { continue }
                    let result = try RentalAccounts.compute(db: db, taxYear: UKTaxYear(startYear: year), personId: personId, propertyId: propertyId,
                                                            memo: memo)
                    for line in result.allLines {
                        let prefix = "\(property.name) · \(line.expenseType.rawValue)"
                        set(prefix + " · whole", .amount(line.whole.native))
                        set(prefix + " · share", .amount(line.amount.native))
                        set(prefix + " · share GBP items", .amount(line.amount.gbpNative))
                        set(prefix + " · share in GBP", line.amount.gbp.map(Value.amount) ?? .missing)
                    }
                    let totals = result.totals
                    for (name, amount) in [("income", totals.income), ("expenses", totals.expenses), ("profit", totals.profit),
                                           ("finance costs", totals.financeCosts), ("foreign tax", totals.foreignTax)] {
                        set("\(property.name) · total \(name)", .amount(amount.native))
                        set("\(property.name) · total \(name) in GBP", amount.gbp.map(Value.amount) ?? .missing)
                    }
                }
                guard UKTaxRules.forYear(year) != nil else { continue }
                let result: SelfAssessment.Result
                do {
                    result = try SelfAssessment.compute(db: db, startYear: year, personId: personId, memo: memo)
                } catch {
                    // Recorded, so a failure that starts (or stops) shows as a change.
                    set("SA computation", .text("failed: \(error)"))
                    continue
                }
                for box in result.boxes {
                    let field = "SA \(box.form) \(box.section) box \(box.number) \(box.label)"
                    switch box.value {
                    case .amount(let value): set(field, .amount(value))
                    case .text(let text): set(field, .text(text))
                    case .cross: set(field, .text("X"))
                    }
                }
                let c = result.calculation
                let calculation: [(String, Int)] = [
                    ("total income", c.totalIncome), ("property profit", c.propertyProfit), ("taxable income", c.taxableIncome),
                    ("income tax charged", c.incomeTaxCharged), ("finance costs", c.financeCosts), ("finance cost reduction", c.financeCostReduction),
                    ("finance costs carried forward", c.financeCostsCarriedForward), ("foreign tax credit relief", c.foreignTaxCreditRelief),
                    ("income tax due", c.incomeTaxDue), ("SA liability", c.selfAssessmentLiability), ("balancing payment", c.balancingPayment),
                    ("property loss carried forward", c.propertyLossCarriedForward)
                ]
                for (name, value) in calculation { set("SA calculation · \(name)", .amount(value)) }
            }
        }
        return snapshot
    }

    /// The fields whose value differs (or exists on one side only), sorted.
    public static func changes(from before: Snapshot, to after: Snapshot) -> [Change] {
        let keys = Set(before.values.keys).union(after.values.keys)
        return keys.sorted().compactMap { key in
            let old = before.values[key], new = after.values[key]
            return old == new ? nil : Change(key: key, before: old, after: new)
        }
    }

    /// Whether anyone's year is filed (or, with `includePaid`, paid).
    public static func isFiled(_ snapshot: Snapshot, startYear: Int, includePaid: Bool = false) -> Bool {
        (snapshot.statuses[startYear] ?? [:]).values.contains { $0 == .filed || (includePaid && $0 == .paid) }
    }
}
