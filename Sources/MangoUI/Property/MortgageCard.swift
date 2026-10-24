import SwiftUI
import BudgetCore

/// The mortgage (iPhone spec §3.7): the next instalment and its day, what's owed (in the property's currency, with
/// pounds beneath), a repaid bar, the rate in force and its next review. All `PropertyGlance.Mortgage`'s figures.
struct MortgageCard: View {
    let mortgage: PropertyGlance.Mortgage
    let currency: Currency
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Card(title: "Mortgage") {
            FigureRow(label: "Next instalment", secondary: mortgage.nextInstalmentDate.map(PhoneDateFormat.day)) {
                if let amount = mortgage.nextInstalmentMinorUnits {
                    MoneyText(minorUnits: amount, currency: currency, role: .due)
                } else {
                    Text(PropertyCopy.amountNotKnown)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            outstanding
            if let progress = mortgage.progress {
                Divider()
                repaid(progress)
            }
            if let rate = mortgage.ratePercent {
                Divider()
                FigureRow(label: "Rate") {
                    Text(PropertyCopy.rate(rate))
                        .figureText()
                }
            }
            if let review = mortgage.nextReview {
                Divider()
                FigureRow(label: "Next review") {
                    DateText(review)
                }
            }
        }
    }

    /// Owed: neither gain nor loss, read as "owed"; pounds beneath for a property not in pounds.
    private var outstanding: some View {
        FigureRow(label: "Outstanding") {
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(minorUnits: mortgage.outstandingMinorUnits, currency: currency, role: .neutral)
                if currency != .gbp {
                    Text(MoneyPresentation.format(mortgage.outstandingGBPMinorUnits, currency: .gbp))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .figureText()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Outstanding")
        .accessibilityValue(outstandingSpoken)
    }

    private var outstandingSpoken: String {
        var parts = ["owed \(MoneyPresentation.format(mortgage.outstandingMinorUnits, currency: currency))"]
        if currency != .gbp {
            parts.append("about \(MoneyPresentation.format(mortgage.outstandingGBPMinorUnits, currency: .gbp))")
        }
        return parts.joined(separator: ", ")
    }

    private func repaid(_ progress: MortgageHistory.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FigureRow(label: "Repaid", secondary: PropertyCopy.instalment(progress)) {
                Text(PropertyCopy.repaid(progress))
                    .figureText()
            }
            ProgressView(value: progress.fraction)
                .tint(theme.accent)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Repaid")
        .accessibilityValue(([PropertyCopy.spokenRepaid(progress)] + (PropertyCopy.instalment(progress).map { [$0] } ?? []))
            .joined(separator: ", "))
    }
}
