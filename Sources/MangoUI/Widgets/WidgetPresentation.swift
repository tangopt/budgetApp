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
}
