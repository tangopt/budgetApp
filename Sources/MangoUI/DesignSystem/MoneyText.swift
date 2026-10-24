import SwiftUI
import BudgetCore

/// What an amount is on the phone, which decides its sign, its colour and how VoiceOver reads it (ui-polish spec
/// §1.4, iPhone spec §4):
///
/// - `income`: money in, given as it is (a salary, rent received). Positive in the income colour; a reversal,
///   negative, in the expense colour.
/// - `expense`: a cost given as a positive magnitude. Shown **negative, in the expense colour** ("−£24.99"); a
///   refund (a negative cost) reads as a gain. Costs never show in the income colour.
/// - `transfer`: money moved between the household's own accounts, with its sign, in the transfer colour: neither a
///   gain nor a loss.
/// - `neutral`: neither gain nor loss (a price, a deposit, an amount on a document, the parts of an all-cost
///   breakdown), as given, never coloured.
/// - `balance`: what an account holds: neutral, or in the expense colour when it is owed (negative).
/// - `due`: a cost still to come (Upcoming, the next instalment, Coming up), given as a positive magnitude. Drawn as
///   `expense` is, read as "due £24.99" (never "spent": it hasn't been); a credit to come reads "due back".
public enum MoneyRole: Sendable, CaseIterable {
    case income, expense, transfer, neutral, balance, due
}

/// The colour family an amount is drawn in (`PhoneTheme.color(_:)`).
public enum MoneyTone: Sendable, Equatable {
    case income, expense, transfer, neutral
}

/// An amount as the phone shows it: the text (`Money.format`, with a true minus sign), its tone and its spoken form.
/// The one place the role rules live; `MoneyText` only draws it. It formats, never computes: the figure comes from
/// BudgetCore.
public struct MoneyPresentation: Equatable, Sendable {
    public let text: String
    public let tone: MoneyTone
    /// What VoiceOver reads: the role in a word, then the amount without its sign ("spent £24.99").
    public let spoken: String

    public init(minorUnits: Int, currency: Currency, role: MoneyRole) {
        let shown = role == .expense || role == .due ? -minorUnits : minorUnits
        text = Self.format(shown, currency: currency)
        let magnitude = Self.format(abs(shown), currency: currency)
        let bySign: MoneyTone = shown > 0 ? .income : (shown < 0 ? .expense : .neutral)
        switch role {
        case .income, .expense:
            tone = bySign
            spoken = switch bySign {
            case .income: "received \(magnitude)"
            case .expense: "spent \(magnitude)"
            default: magnitude
            }
        case .due:
            tone = bySign
            spoken = switch bySign {
            case .income: "due back \(magnitude)"
            case .expense: "due \(magnitude)"
            default: magnitude
            }
        case .transfer:
            tone = shown == 0 ? .neutral : .transfer
            spoken = "moved \(magnitude)"
        case .neutral:
            tone = .neutral
            spoken = shown < 0 ? "minus \(magnitude)" : magnitude
        case .balance:
            tone = shown < 0 ? .expense : .neutral
            spoken = shown < 0 ? "owed \(magnitude)" : "balance \(magnitude)"
        }
    }

    /// `Money.format` with the typographic minus (U+2212), as wide as a plus in tabular digits.
    static func format(_ minorUnits: Int, currency: Currency) -> String {
        let plain = Money.format(minorUnits, currency: currency)
        return plain.hasPrefix("-") ? "\u{2212}" + plain.dropFirst() : plain
    }
}

/// An amount: one line, tabular digits, coloured by its role in the theme's money colours, read by VoiceOver with
/// its role. `fit` is `.natural` (its full width; the layout around it gives way) or `.shrink` where the width is
/// fixed (down to 70%, never wrapping or truncating). The wrap probe checks it in the snapshot harness.
public struct MoneyText: View {
    public let minorUnits: Int
    public let currency: Currency
    public let role: MoneyRole
    public let fit: FigureFit
    public var font: Font
    @Environment(\.phoneTheme) private var theme

    public init(minorUnits: Int, currency: Currency, role: MoneyRole, fit: FigureFit = .natural,
                font: Font = .body) {
        self.minorUnits = minorUnits
        self.currency = currency
        self.role = role
        self.fit = fit
        self.font = font
    }

    /// The same amount in another font (a card's headline figure).
    public func font(_ font: Font) -> MoneyText {
        var copy = self
        copy.font = font
        return copy
    }

    public var body: some View {
        let shown = MoneyPresentation(minorUnits: minorUnits, currency: currency, role: role)
        Text(shown.text)
            .font(font.monospacedDigit())
            .foregroundStyle(theme.color(shown.tone))
            .modifier(FigureFitModifier(fit: fit, kind: "MoneyText", text: shown.text, source: nil))
            .accessibilityLabel(shown.spoken)
    }
}
