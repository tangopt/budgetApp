import Foundation
import BudgetCore

/// What the widgets say (step 7b): the snapshot's figures as text, in Home's own format (`Money.format`), shared by the
/// extension and the tests. No figure is computed here.
public enum WidgetPresentation {
    public static let emptyText = "Open Mango to set up"

    private static func currency(_ s: WidgetSnapshot) -> Currency {
        Currency(rawValue: s.currencyCode.lowercased()) ?? .gbp
    }

    /// Home's net worth; "—" without balances.
    public static func netWorthText(_ s: WidgetSnapshot) -> String {
        guard let net = s.netWorthMinorUnits else { return "—" }
        return Money.format(net, currency: currency(s))
    }

    /// Home's net worth in whole units, as the small widget shows it ("£12,345"): a figure is never scaled down, so
    /// the pence go instead. "—" without balances.
    public static func netWorthWholeText(_ s: WidgetSnapshot) -> String {
        guard let net = s.netWorthMinorUnits else { return "—" }
        return wholeText(net, currencyCode: s.currencyCode)
    }

    /// Home's "left to spend" this pay month.
    public static func leftText(_ s: WidgetSnapshot) -> String {
        Money.format(s.leftToSpendMinorUnits, currency: currency(s))
    }

    /// "12 days", "1 day", "Today".
    public static func paydayText(_ s: WidgetSnapshot, on day: Date) -> String {
        switch s.daysToPayday(on: day) {
        case 0: "Today"
        case 1: "1 day"
        case let days: "\(days) days"
        }
    }

    /// The figure is marked privacy sensitive (hidden while the device is locked) unless it is on the lock screen
    /// and the person turned the setting on.
    public static func isRedacted(_ s: WidgetSnapshot, isLockScreen: Bool) -> Bool {
        !(isLockScreen && s.showFiguresOnLockScreen)
    }

    /// What a widget shows for a stored snapshot (nil: none yet).
    public static func text(_ s: WidgetSnapshot?, _ figure: (WidgetSnapshot) -> String) -> String {
        s.map(figure) ?? emptyText
    }

    // MARK: Step 18

    private static func currency(code: String) -> Currency {
        Currency(rawValue: code.lowercased()) ?? .gbp
    }

    /// An amount in whole units ("£1,235"): the small tiles have no room for pence. Rounded to the nearest unit.
    public static func wholeText(_ minorUnits: Int, currencyCode: String) -> String {
        let rounded = (minorUnits.magnitude + 50) / 100 * 100
        let body = String(Money.format(Int(rounded), currency: currency(code: currencyCode)).dropLast(3))
        return minorUnits < 0 && rounded != 0 ? "-\(body)" : body
    }

    /// "+£120" for an amount over a budget.
    public static func overText(_ minorUnits: Int, currencyCode: String) -> String {
        "+" + wholeText(minorUnits, currencyCode: currencyCode)
    }

    /// The share of the budget spent, "62%" (0% without a budget).
    public static func percentText(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// How the spending sits against the pace: "£120 over pace", "£80 under pace", "On pace".
    public static func paceText(_ figures: MonthSpendFigures) -> String {
        let delta = figures.overPaceMinorUnits
        if abs(delta) < 100 { return "On pace" }
        let amount = wholeText(abs(delta), currencyCode: figures.currencyCode)
        return delta > 0 ? "\(amount) over pace" : "\(amount) under pace"
    }

    /// "Bills in" count, "2 of 3".
    public static func billsText(_ figures: RechargePipelineFigures) -> String {
        figures.billsExpected == 0 ? "None due" : "\(figures.billsIn) of \(figures.billsExpected)"
    }

    public static func sentText(_ figures: RechargePipelineFigures) -> String {
        figures.statementSent ? "Yes" : "Not yet"
    }

    public static func paidText(_ figures: RechargePipelineFigures) -> String {
        figures.paidByTenant ? "Paid" : "Waiting"
    }

    /// What the tenant still owes, whole units.
    public static func outstandingText(_ figures: RechargePipelineFigures) -> String {
        wholeText(figures.outstandingMinorUnits, currencyCode: figures.currencyCode)
    }
}
