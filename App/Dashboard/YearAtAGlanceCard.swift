// App/Dashboard/YearAtAGlanceCard.swift
import SwiftUI
import BudgetCore

struct YearAtAGlanceCard: View {
    @ObservedObject var viewModel: DashboardViewModel
    let content: DashboardContent
    let navigate: (AppScreen) -> Void

    var body: some View {
        // Summed once per body evaluation (twelve additions), shared by every block below.
        let totals = DashboardCalculator.yearTotals(viewModel.flows)
        let isFuture = viewModel.flows.contains { $0.monthClass != .actual }
        DashboardCard(title: "Year at a glance — actual + forecast", linkTitle: isFuture ? "Forecast" : "Budget", onLink: { navigate(isFuture ? .forecast : .budgetGrid) }) {
            HStack {
                Spacer()
                Button { viewModel.selectYear(viewModel.selectedYear - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(viewModel.selectedYear <= content.yearRange.lowerBound)
                Text(String(viewModel.selectedYear)).font(.headline).frame(minWidth: 48)
                Button { viewModel.selectYear(viewModel.selectedYear + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(viewModel.selectedYear >= content.yearRange.upperBound)
            }
            YearAtAGlanceChart(flows: viewModel.flows)
            HStack(spacing: 14) {
                Label("Income", systemImage: "square.fill").foregroundStyle(.green)
                Label("Expenses", systemImage: "square.fill").foregroundStyle(.orange)
                Label("Net", systemImage: "circle.fill").foregroundStyle(.blue)
                Text("Solid = actual · hatched = forecast or still expected").foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack(spacing: 10) {
                total("Income", projected: totals.incomeProjected, actual: totals.incomeActual, hasForecast: totals.hasForecast)
                total("Expenses", projected: totals.expenseProjected, actual: totals.expenseActual, hasForecast: totals.hasForecast)
                total("Net saved", projected: totals.netProjected, actual: totals.netActual, hasForecast: totals.hasForecast)
            }
            Text(footnote(isFuture: isFuture))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Built as a String (the year via `String(_:)`, so it reads "2026", not "2,026").
    private func footnote(isFuture: Bool) -> String {
        var text = isFuture ? "Forecast months use confirmed entries only." : "Completed year — same totals as the Budget grid."
        let unreviewed = viewModel.unreviewed
        guard unreviewed.count > 0 else {
            return isFuture ? text + " Unreviewed transactions aren't included." : text
        }
        let single = unreviewed.count == 1
        let out = unreviewed.outflowMinorUnits > 0 ? " (\(DashboardFormat.pounds(unreviewed.outflowMinorUnits)) out)" : ""
        text += " \(unreviewed.count) unreviewed transaction\(single ? "" : "s")\(out) in \(String(viewModel.selectedYear)) \(single ? "isn't" : "aren't") included."
        return text
    }

    private func total(_ title: String, projected: Int, actual: Int, hasForecast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hasForecast ? "\(title) · projected" : title).font(.caption).foregroundStyle(.secondary)
            Text(DashboardFormat.pounds(projected)).font(.headline).monospacedDigit()
            if hasForecast {
                Text("of which actual \(DashboardFormat.pounds(actual))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
    }
}
