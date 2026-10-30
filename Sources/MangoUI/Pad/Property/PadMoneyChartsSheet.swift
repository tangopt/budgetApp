import SwiftUI
import Charts
import BudgetCore

/// "Charts and figures" (step 10, Task 15; inline on the Money page since round 2): what the Mac's Money tab keeps beside and below its table: the
/// full figures table in its groups (a row with transactions opens them), cash flow by month, the mortgage's interest and
/// capital by month, and the monthly figures. Amounts follow "Show in GBP".
struct PadMoneyChartsContent: View {
    @ObservedObject var model: PadMoneyModel
    let onShow: (PadMoneyModel.Figure) -> Void
    @Environment(\.phoneTheme) private var theme

    private static let utc = TimeZone(identifier: "UTC")!

    var body: some View {
        VStack(alignment: .leading, spacing: MangoSpacing.section) {
            if let summary = model.summary {
                figures
                cashFlow(summary)
                mortgage(summary)
                monthly(summary)
            }
        }
    }

    // MARK: Figures

    private var figures: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Figures").mangoFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            Text("Select a figure to list its transactions").mangoFont(.footnote).foregroundStyle(.secondary)
            ForEach(model.figureSections) { section in
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title).mangoFont(.subheadline, weight: .semibold).foregroundStyle(.secondary).padding(.bottom, 6)
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, figure in
                        if index > 0 { Divider() }
                        row(figure)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
            }
        }
    }

    @ViewBuilder
    private func row(_ figure: PadMoneyModel.Figure) -> some View {
        let content = ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(figure.title).fontWeight(figure.isTotal ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                amount(figure)
                chevron(figure)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(figure.title).fontWeight(figure.isTotal ? .semibold : .regular)
                amount(figure)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        if figure.drillDown != nil {
            Button { onShow(figure) } label: { content }
                .buttonStyle(.plain)
                .accessibilityHint("Lists the transactions")
        } else {
            content
        }
    }

    private func amount(_ figure: PadMoneyModel.Figure) -> some View {
        MoneyText(minorUnits: model.shown(figure.amount), currency: model.displayCurrency, role: figure.role,
                  font: .body.weight(figure.isTotal ? .semibold : .regular))
    }

    @ViewBuilder
    private func chevron(_ figure: PadMoneyModel.Figure) -> some View {
        if figure.drillDown != nil {
            Image(systemName: "chevron.right").mangoFont(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    // MARK: Charts

    private func major(_ amount: PropertyAmount) -> Double { Double(model.shown(amount)) / 100 }

    private func axisFormat() -> FloatingPointFormatStyle<Double>.Currency {
        .currency(code: model.displayCurrency.rawValue.uppercased()).precision(.fractionLength(0)).notation(.compactName)
    }

    private func cashFlow(_ summary: PropertySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cash flow by month").mangoFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            Text("Rent received above the line, costs below, net cash flow as the line").mangoFont(.footnote).foregroundStyle(.secondary)
            Chart {
                ForEach(summary.months, id: \.start) { month in
                    BarMark(x: .value("Month", month.start, unit: .month), y: .value("Rent received", major(month.figures.rentReceived)))
                        .foregroundStyle(theme.income)
                    BarMark(x: .value("Month", month.start, unit: .month), y: .value("Costs", -major(month.figures.costs)))
                        .foregroundStyle(theme.expense)
                    LineMark(x: .value("Month", month.start, unit: .month), y: .value("Net cash flow", major(month.figures.netCashFlow)))
                        .foregroundStyle(theme.accent)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: Date.FormatStyle(timeZone: Self.utc).month(.narrow), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: axisFormat())
                }
            }
            .environment(\.calendar, MonthRange.calendar)
            .environment(\.timeZone, Self.utc)
            .frame(height: 220)
            .accessibilityLabel("Cash flow by month")
            .accessibilityValue("Net \(Money.format(model.shown(summary.totals.netCashFlow), currency: model.displayCurrency)) over the period")
            legend([("Rent received", theme.income), ("Costs", theme.expense), ("Net cash flow", theme.accent)])
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
    }

    @ViewBuilder
    private func mortgage(_ summary: PropertySummary) -> some View {
        let t = summary.totals
        let paid = model.shown(t.mortgageInterest) + model.shown(t.mortgageCapital)
        VStack(alignment: .leading, spacing: 8) {
            Text("Mortgage").mangoFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            if paid > 0 {
                Text("\(Money.format(paid, currency: model.displayCurrency)) paid: interest and capital by month".figuresUnbroken)
                    .mangoFont(.footnote).foregroundStyle(.secondary)
                Chart {
                    ForEach(summary.months, id: \.start) { month in
                        BarMark(x: .value("Month", month.start, unit: .month), y: .value("Interest", major(month.figures.mortgageInterest)))
                            .foregroundStyle(by: .value("Part", "Interest"))
                        BarMark(x: .value("Month", month.start, unit: .month), y: .value("Capital repaid", major(month.figures.mortgageCapital)))
                            .foregroundStyle(by: .value("Part", "Capital repaid"))
                    }
                }
                .chartForegroundStyleScale(["Interest": theme.expense, "Capital repaid": theme.transfer])
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: Date.FormatStyle(timeZone: Self.utc).month(.narrow), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: axisFormat())
                    }
                }
                .environment(\.calendar, MonthRange.calendar)
                .environment(\.timeZone, Self.utc)
                .frame(height: 170)
                .accessibilityLabel("Mortgage interest and capital repaid by month")
                legend([("Interest", theme.expense), ("Capital repaid", theme.transfer)])
                HStack(spacing: 18) {
                    part("Interest", t.mortgageInterest, of: paid)
                    part("Capital repaid", t.mortgageCapital, of: paid)
                }
            } else {
                Text("No mortgage payments in this period: link the mortgage account in Profile.")
                    .mangoFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
    }

    private func part(_ title: String, _ amount: PropertyAmount, of total: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).mangoFont(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                MoneyText(minorUnits: model.shown(amount), currency: model.displayCurrency, role: .neutral, font: .subheadline)
                if total > 0 {
                    Text("\(Int((Double(model.shown(amount)) / Double(total) * 100).rounded()))%").mangoFont(.subheadline, figures: true)
                        .foregroundStyle(.secondary).fixedSize()
                }
            }
        }
    }

    private func legend(_ items: [(String, Color)]) -> some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 6) {
                    Circle().fill(item.1).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(item.0).mangoFont(.footnote).lineLimit(1)
                }
            }
        }
    }

    // MARK: Monthly figures

    private func monthly(_ summary: PropertySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monthly figures").mangoFont(.title3, weight: .semibold).accessibilityAddTraits(.isHeader)
            Text("Month by month, in \(model.displayCurrency.rawValue.uppercased())").mangoFont(.footnote).foregroundStyle(.secondary)
            ForEach(model.months, id: \.start) { month in monthCard(PadMoneyModel.monthTitle(month), month.figures) }
            monthCard("Total", summary.totals)
        }
    }

    private func monthCard(_ title: String, _ figures: PropertyFigures) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.figuresUnbroken).mangoFont(.headline).lineLimit(1)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .top)], alignment: .leading, spacing: 8) {
                cell("Rent per receipts", figures.rentPerReceipts, .neutral)
                cell("Rent received", figures.rentReceived, .income)
                cell("Recharges", figures.recharges, .income)
                cell("Costs", figures.costs, .expense)
                cell("Interest", figures.mortgageInterest, .expense)
                cell("Capital", figures.mortgageCapital, .expense)
                cell("Net cash flow", figures.netCashFlow, .income)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
    }

    private func cell(_ title: String, _ amount: PropertyAmount, _ role: MoneyRole) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
            MoneyText(minorUnits: model.shown(amount), currency: model.displayCurrency, role: role, fit: .shrink(), font: .subheadline)
        }
    }
}
