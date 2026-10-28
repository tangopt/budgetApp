import GRDB
import Foundation

/// A year of a tenancy's recharges, as the Recharges tab's summary reads it (user, 2026-10-27):
/// everything grouped by the month the statement is for, so a year's figures compare like
/// with like.
/// - `recharged`: the totals of the year's sent (or paid) statements.
/// - `billsPaid`: what the bank actually paid for the bills on those statements — each line's
///   bank movements (`Recharges.payments` for an invoice line, the line's own movement for a
///   manual one), refunds and credits netting, every movement counted once. A prorated line
///   takes its share of its invoice's movements. A line with no movement linked, and a rounding
///   line, pay nothing.
/// - `otherItems`: one-off statement lines with no bank movement and no document (the landlord's
///   own costs taken off the rent); kept out of the difference.
/// - `difference`: recharged less bills paid and less the other items, with the statements that
///   make it (`gaps`). Positive: the statements asked for more than the bills cost.
public struct RechargeYearFigures: Equatable, Sendable {
    /// Why a statement's recharges differ from its bills' bank payments.
    public enum GapReason: Int, CaseIterable, Comparable, Sendable {
        /// Rounding lines (a transfer's cents).
        case rounding
        /// Bills on the statement with no bank payment linked.
        case noPayment
        /// One-off lines (a repair, a refund) with no bank movement.
        case oneOff
        /// The bank paid a different amount than the lines recharge.
        case otherAmount
        /// One-off lines with no bank movement and no document: shown on their own, not part of
        /// the difference.
        case otherItems

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A statement's part of the difference, for one reason.
    public struct Gap: Equatable, Sendable {
        public var statementId: Int64
        /// The statement's month (its first day).
        public var month: Date
        public var reason: GapReason
        /// Recharged less paid for this reason (positive: recharged more).
        public var amountMinorUnits: Int
        /// The lines behind it (0 for `otherAmount`).
        public var lines: Int
    }

    public var year: Int
    /// The totals of the year's sent (or paid) statements, and how many.
    public var recharged = 0
    public var statements = 0
    /// What tenant credits paid of those statements.
    public var received = 0
    /// What the bank paid for the bills on those statements.
    public var billsPaid = 0
    /// The sum of the statements' other items (see above).
    public var otherItems = 0
    /// The statements' parts of the difference, by month then reason, and their other items.
    public var gaps: [Gap] = []

    public var difference: Int { recharged - billsPaid - otherItems }

    public init(year: Int) {
        self.year = year
    }
}

extension Recharges {
    /// The tenancy's figures for every year with a sent (or paid) statement, by year.
    public static func yearFigures(db: Database, tenancyId: Int64) throws -> [Int: RechargeYearFigures] {
        let statements = try RechargeStatement.filter(Column("tenancyId") == tenancyId && Column("status") != RechargeStatementStatus.draft.rawValue)
            .order(Column("month"), Column("id")).fetchAll(db)
        var figures: [Int: RechargeYearFigures] = [:]
        // Each bank movement counts once a year, however many lines it pays.
        var counted: [Int: Set<Int64>] = [:]
        for statement in statements {
            let year = MonthRange.components(of: statement.month).year
            var figure = figures[year] ?? RechargeYearFigures(year: year)
            var seen = counted[year] ?? []
            figure.recharged += statement.totalMinorUnits
            figure.statements += 1
            figure.received += try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(amountMinorUnits), 0) FROM rechargePayment WHERE statementId = ? AND isDismissed = 0
                """, arguments: [statement.id!]) ?? 0

            var paid = 0
            var rounding = (amount: 0, lines: 0)
            var noPayment = 0
            var oneOffs = 0
            var other = (amount: 0, lines: 0)
            for detail in try lineDetails(db: db, statementId: statement.id!) {
                let line = detail.line
                if line.isRounding {
                    rounding.amount += line.amountMinorUnits
                    rounding.lines += 1
                    continue
                }
                if line.isOneOff, line.transactionId == nil, line.documentId == nil {
                    other.amount += line.amountMinorUnits
                    other.lines += 1
                    continue
                }
                let movements: [Transaction]
                if let invoice = detail.invoice {
                    movements = try payments(db: db, invoice)
                } else if let transactionId = line.transactionId {
                    movements = try Transaction.fetchOne(db, key: transactionId).map { [$0] } ?? []
                } else {
                    movements = []
                }
                if movements.isEmpty {
                    if line.isManual { oneOffs += 1 } else { noPayment += 1 }
                    continue
                }
                let fresh = movements.filter { seen.insert($0.id!).inserted }
                // Debits are negative: what was paid is their opposite (a refund credit, negative).
                let bank = -fresh.reduce(0) { $0 + $1.amountMinorUnits }
                if let invoice = detail.invoice, invoice.amountMinorUnits != 0, line.amountMinorUnits != invoice.amountMinorUnits {
                    paid += Int((Double(bank) * Double(line.amountMinorUnits) / Double(invoice.amountMinorUnits)).rounded())
                } else {
                    paid += bank
                }
            }
            figure.billsPaid += paid

            // The statement's difference: its rounding lines first, the rest put down to its
            // lines without a bank movement (bills, then one-offs), else to the amounts paid.
            var rest = statement.totalMinorUnits - paid - other.amount
            if rounding.lines > 0, rounding.amount != 0 {
                figure.gaps.append(.init(statementId: statement.id!, month: statement.month, reason: .rounding,
                                        amountMinorUnits: rounding.amount, lines: rounding.lines))
                rest -= rounding.amount
            }
            if rest != 0 {
                let (reason, lines): (RechargeYearFigures.GapReason, Int) =
                    noPayment > 0 ? (.noPayment, noPayment) : oneOffs > 0 ? (.oneOff, oneOffs) : (.otherAmount, 0)
                figure.gaps.append(.init(statementId: statement.id!, month: statement.month, reason: reason, amountMinorUnits: rest, lines: lines))
            }
            if other.lines > 0, other.amount != 0 {
                figure.otherItems += other.amount
                figure.gaps.append(.init(statementId: statement.id!, month: statement.month, reason: .otherItems,
                                        amountMinorUnits: other.amount, lines: other.lines))
            }
            figures[year] = figure
            counted[year] = seen
        }
        return figures
    }
}

extension RechargeYearFigures {
    /// What the Difference tile says, in a direction nobody can misread.
    public static func differenceCaption(_ difference: Int) -> String {
        difference == 0 ? "Every statement matches its bills"
            : difference > 0 ? "Statements asked for more than the bills" : "Statements asked for less than the bills"
    }

    /// The year's explanation lines, one per reason, signed as the figure is (recharged less paid:
    /// "+" the statements asked for more, "\u{2212}" for less). Other items come last and are not
    /// part of the difference.
    public func explanations(currency: Currency) -> [Explanation] {
        Dictionary(grouping: gaps, by: \.reason).sorted { $0.key < $1.key }.map { reason, gaps in
            let total = gaps.reduce(0) { $0 + $1.amountMinorUnits }
            let amount = (total < 0 ? "\u{2212}" : "+") + Money.format(abs(total), currency: currency)
            let months = gaps.map { RechargeEmail.monthName($0.month, language: .english) }
            let on = gaps.count == 1 ? "on \(months[0])'s statement" : "on \(gaps.count) statements"
            let lines = gaps.reduce(0) { $0 + $1.lines }
            let text: String = switch reason {
            case .rounding: "\(amount) rounding \(on)"
            case .noPayment where total < 0: "\(amount) refund not matched to a bank credit, \(on)"
            case .noPayment: "\(amount) from \(lines) bill\(lines == 1 ? "" : "s") with no bank payment linked, \(on)"
            case .oneOff where total < 0: "\(amount) refund not matched to a bank credit, \(on)"
            case .oneOff: "\(amount) from \(lines) one-off line\(lines == 1 ? "" : "s") with no bank movement, \(on)"
            case .otherAmount: "\(amount) where the bank paid a different amount than recharged, \(on)"
            case .otherItems: "\(amount) other items on statements (\(lines) line\(lines == 1 ? "" : "s"), not in the difference), \(on)"
            }
            return Explanation(reason: reason, text: text, gaps: gaps)
        }
    }

    public struct Explanation: Equatable, Sendable {
        public var reason: GapReason
        public var text: String
        public var gaps: [Gap]
    }
}
