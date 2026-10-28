// App/Salary/SalaryResultsView.swift
import SwiftUI
import Charts
import BudgetCore

/// Everything the salary simulator works out, on the right of the split: the difference between
/// the two salaries, what each leaves you line by line (Current and New in two columns), and where
/// the money goes. Rows are always all there (a dash where one doesn't apply, a column faded
/// until it has a salary), so nothing moves as the figures are typed.
struct SalaryResultsView: View {
    @Bindable var model: SalaryComparisonViewModel
    @Environment(\.theme) private var theme

    private static let valueColumn: CGFloat = 112

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                strip
                results
                chart
                Text("An estimate from published UK rates, not tax advice.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(ScreenMetrics.padding)
        }
    }

    // MARK: Comparison strip

    private var strip: some View {
        Panel("New against current", accessory: {
            Button(model.resetTitle) { model.reset() }.buttonStyle(.link).font(.caption)
        }, content: {
            FigureStrip([
                FigureTile(title: "Take-home a month", value: .money(model.comparison.monthlyDifference, .gbp, .signed)),
                FigureTile(title: "Take-home a year", value: .money(model.comparison.annualDifference, .gbp, .signed)),
                FigureTile(title: "Of each extra £1 gross you keep",
                           value: .text(Self.pence(model.comparison.keepPerExtraPound)))
            ])
        })
    }

    private static func pence(_ basisPoints: Int) -> String {
        String(format: "%.0fp", Double(basisPoints) / 100)
    }

    // MARK: Take-home and breakdowns

    private var results: some View {
        let current = model.comparison.current, offer = model.comparison.offer
        let ready = model.ready
        return Panel("Take-home", subtitle: "What each salary leaves you") {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 7) {
                    GridRow {
                        Color.clear.frame(height: 1)
                        Text("Current").font(.subheadline.weight(.semibold)).frame(width: Self.valueColumn, alignment: .trailing)
                        Text("New").font(.subheadline.weight(.semibold)).frame(width: Self.valueColumn, alignment: .trailing)
                    }
                    pair("A year", current.takeHomeAnnual, offer.takeHomeAnnual, bold: true, always: true)
                    pair("A month", current.takeHomeMonthly, offer.takeHomeMonthly, bold: true, always: true)
                    pair("A week", current.takeHomeWeekly, offer.takeHomeWeekly, bold: true, always: true)
                    Divider().gridCellColumns(3)
                    pair("Income tax", current.incomeTax, offer.incomeTax, cost: true)
                    pair("National Insurance", current.employeeNI, offer.employeeNI, cost: true)
                    pair("Student loan", current.studentLoan, offer.studentLoan, cost: true)
                    pair("Postgraduate loan", current.postgraduateLoan, offer.postgraduateLoan, cost: true)
                    pair("Your pension", current.employeePension, offer.employeePension, cost: true)
                    pair("Employer pension", current.employerPension, offer.employerPension)
                    pair("Tax on benefits in kind", current.benefitsInKindTax, offer.benefitsInKindTax, cost: true)
                    Divider().gridCellColumns(3)
                    pair("Personal allowance", current.personalAllowance, offer.personalAllowance)
                    percentPair("Effective rate", current.effectiveRateBP, offer.effectiveRateBP)
                    percentPair("Marginal rate", current.marginalRateBP, offer.marginalRateBP)
                }
                .opacity(ready.current && ready.offer ? 1 : 0.55)
                // Reserved, so a salary being typed moves nothing.
                Text(readyNote).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: true)
                notices
            }
        }
    }

    private var readyNote: String {
        switch (model.ready.current, model.ready.offer) {
        case (true, true): return " "
        case (false, false): return "Enter a salary to see the take-home."
        case (false, true): return "Enter a Current salary to see its take-home."
        case (true, false): return "Enter a New salary to see its take-home."
        }
    }

    private func pair(_ label: String, _ current: Int, _ offer: Int, cost: Bool = false, bold: Bool = false, always: Bool = false) -> some View {
        GridRow {
            Text(label).lineLimit(1).truncationMode(.middle).help(label).frame(maxWidth: .infinity, alignment: .leading)
                .fontWeight(bold ? .semibold : .regular)
            cell(current, ready: model.ready.current, cost: cost, bold: bold, always: always)
            cell(offer, ready: model.ready.offer, cost: cost, bold: bold, always: always)
        }
    }

    @ViewBuilder
    private func cell(_ pence: Int, ready: Bool, cost: Bool, bold: Bool, always: Bool) -> some View {
        Group {
            if pence > 0 || always {
                MoneyText(minorUnits: pence, font: bold ? .body.monospacedDigit().weight(.semibold) : .body.monospacedDigit(),
                          role: cost ? .cost : .neutral)
            } else {
                Text("—").foregroundStyle(.secondary).accessibilityLabel("none")
            }
        }
        .frame(width: Self.valueColumn, alignment: .trailing)
        .opacity(ready ? 1 : 0.35)
    }

    private func percentPair(_ label: String, _ current: Int, _ offer: Int) -> some View {
        GridRow {
            Text(label).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            percent(current, ready: model.ready.current)
            percent(offer, ready: model.ready.offer)
        }
    }

    private func percent(_ basisPoints: Int, ready: Bool) -> some View {
        Text(String(format: "%.1f%%", Double(basisPoints) / 100)).monospacedDigit().figureText()
            .frame(width: Self.valueColumn, alignment: .trailing)
            .opacity(ready ? 1 : 0.35)
    }

    /// Notices come and go with the figures: their room is kept.
    private var notices: some View {
        let comparison = model.comparison
        let sides: [(String, SalaryResult)] = [("Current", comparison.current), ("New", comparison.offer)]
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(sides, id: \.0) { name, result in
                if let caption = SalaryResult.marginalPensionCaption(result) {
                    Text("\(name): \(caption)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(result.notices.filter { $0 != TaxCode.unreadableNotice }, id: \.self) { notice in
                    Text("\(name): \(notice)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let rules = SalaryRules.forYear(result.effectiveTaxYear), !rules.checkedFields.isEmpty {
                    Text("Rates for \(rules.ukTaxYear.label) not yet confirmed").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
    }

    // MARK: Chart

    private struct Bar: Identifiable {
        let side: String, part: String, pounds: Double
        var id: String { side + part }
    }

    private var bars: [Bar] {
        [("Current", model.comparison.current), ("New", model.comparison.offer)].flatMap { side, result in
            SalaryBarSegments.segments(result).filter { $0.pence > 0 }.map { Bar(side: side, part: $0.label, pounds: Double($0.pence) / 100) }
        }
    }

    private var chart: some View {
        let parts = ["Take-home", "Income tax", "National Insurance", "Loans", "Pension"]
        let colors = theme.chartSeries
        return Panel("Where the money goes", subtitle: "A year of gross pay, split by what it goes to") {
            Chart(bars) { bar in
                BarMark(x: .value("Pounds", bar.pounds), y: .value("Salary", bar.side))
                    .foregroundStyle(by: .value("Part", bar.part))
            }
            .chartForegroundStyleScale(domain: parts, range: parts.indices.map { colors.isEmpty ? Color.accentColor : colors[$0 % colors.count] })
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let pounds = value.as(Double.self) { Text("£\(Int(pounds / 1000))k").monospacedDigit() }
                    }
                }
            }
            .chartLegend(position: .bottom)
            .frame(height: 140)
        }
    }
}
