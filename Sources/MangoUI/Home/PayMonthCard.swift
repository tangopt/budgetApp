import SwiftUI
import BudgetCore

/// This pay month (iPhone spec §3.2): what's been spent of the planned spending, a bar with the still-expected
/// part hatched (`MonthBlend`, as the dashboard's current month card), and the days to payday. The hatched figure
/// is "Still expected" (ruling: "Left to spend" is Month's net, never Home's).
struct PayMonthCard: View {
    let summary: HomeSummary
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        let month = summary.month
        Card(title: "This pay month") {
            Text("\(PhoneDateFormat.day(month.start)) – \(PhoneDateFormat.day(month.end))".figuresUnbroken)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            FigureRow(label: "Spent") {
                MoneyText(minorUnits: month.expenses.actual, currency: .gbp, role: .expense)
            }
            bar
            FigureRow(label: "Still expected") {
                MoneyText(minorUnits: summary.leftToSpendMinorUnits, currency: .gbp, role: .neutral)
            }
            FigureRow(label: "Planned spending") {
                MoneyText(minorUnits: summary.plannedSpendingMinorUnits, currency: .gbp, role: .neutral)
            }
            FigureRow(label: "Payday") {
                Text(HomeCopy.daysToPayday(summary.daysToPayday)).figureText()
            }
        }
    }

    private var bar: some View {
        let shares = PayMonthBar(spentMinorUnits: summary.month.expenses.actual,
                                 stillExpectedMinorUnits: summary.leftToSpendMinorUnits,
                                 plannedMinorUnits: summary.plannedSpendingMinorUnits)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(theme.expense)
                        .frame(width: width * shares.spent)
                    Hatch(color: theme.expense)
                        .frame(width: width * shares.stillExpected)
                    Spacer(minLength: 0)
                }
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            }
            .frame(height: 12)
            HStack(spacing: 16) {
                legend(Rectangle().fill(theme.expense), "Spent")
                legend(Hatch(color: theme.expense), "Still expected")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spent and still expected, out of the planned spending")
        .accessibilityValue(HomeCopy.payMonthBarValue(summary))
    }

    private func legend<Swatch: View>(_ swatch: Swatch, _ label: String) -> some View {
        HStack(spacing: 4) {
            swatch
                .frame(width: 14, height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            Text(label)
        }
    }
}

/// Diagonal stripes in `color` over a light wash of it: planned spending not spent yet.
struct Hatch: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.18)))
            var path = Path()
            let step: CGFloat = 5
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.stroke(path, with: .color(color.opacity(0.75)), lineWidth: 1.5)
        }
    }
}
