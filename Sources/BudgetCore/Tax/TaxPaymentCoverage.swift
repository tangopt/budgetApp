import Foundation

/// Whether the HMRC payments recorded for a year cover what its return says is due, and so the
/// year can be offered as paid ("Payments cover what's due — mark as paid?").
public enum TaxPaymentCoverage {
    /// How close what's recorded may come to what's due and still count as covering it: £1
    /// (HMRC's figures are in pence, payments are often rounded to the pound).
    public static let tolerance = 100

    /// What the payments of `kind` recorded for the year starting `startYear` add up to.
    public static func recorded(_ payments: [HMRCPayment], kind: HMRCPaymentKind, startYear: Int) -> Int {
        payments.filter { $0.kind == kind && $0.startYear == startYear }.reduce(0) { $0 + $1.amountMinorUnits }
    }

    /// The balancing payments recorded add up to within £1 of `balancingDue` (something is due and
    /// something is recorded).
    public static func covers(balancingDue: Int, payments: [HMRCPayment], startYear: Int) -> Bool {
        let paid = recorded(payments, kind: .balancingPayment, startYear: startYear)
        return balancingDue > 0 && paid > 0 && paid >= balancingDue - tolerance
    }

    /// A filed year (not yet paid) whose recorded balancing payments cover what's due.
    public static func suggestsMarkingPaid(status: TaxYearStatus, balancingDue: Int, payments: [HMRCPayment], startYear: Int) -> Bool {
        status == .filed && covers(balancingDue: balancingDue, payments: payments, startYear: startYear)
    }
}
