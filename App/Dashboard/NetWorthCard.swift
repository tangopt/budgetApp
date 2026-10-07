// App/Dashboard/NetWorthCard.swift
import SwiftUI
import BudgetCore

struct NetWorthCard: View {
    let content: DashboardContent
    let navigate: (AppScreen) -> Void

    private var series: NetWorthSeries { content.netWorth }

    private var title: String {
        series.actual.first.map { "Net worth since \($0.year)" } ?? "Net worth"
    }

    var body: some View {
        DashboardCard(title: title, linkTitle: "Accounts", onLink: { navigate(.accounts) }) {
            if series == .empty {
                // No balance snapshots at all.
                Text("No history yet — record a balance on the Accounts screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if let behind = series.behindBalances {
                    Label("\(behind.accountCount) balance\(behind.accountCount == 1 ? " was" : "s were") last updated \(DashboardFormat.day(behind.oldestSnapshotDate)), so the forecast restarts from \(behind.accountCount == 1 ? "it" : "them"). Update balances to correct it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if series.actual.isEmpty {
                    // Balances exist but none reach back to the transactions' month, so there is
                    // no actual line to draw. The headline and forecast below are still valid.
                    Text("No actual history to chart yet — your first balance was recorded after your latest imported transaction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 12) {
                    // The headline is the current net worth, not the last chart point: a typed
                    // snapshot dated after the data-through month makes the two differ.
                    statBlock(
                        title: series.asOf.map { "Net worth as of \(DashboardFormat.day($0))" } ?? "Net worth",
                        value: series.currentNetWorthMinorUnits.map(DashboardFormat.pounds) ?? "—",
                        detail: series.changeVsPreviousMonthMinorUnits.map { "\($0 >= 0 ? "↑" : "↓") \(DashboardFormat.pounds(abs($0))) vs previous month" },
                        large: true
                    )
                    ForEach(series.yearEnds, id: \.year) { yearEnd in
                        statBlock(
                            title: "Forecast Dec \(yearEnd.year)",
                            value: DashboardFormat.pounds(yearEnd.valueMinorUnits),
                            detail: "\(yearEnd.changeMinorUnits >= 0 ? "↑" : "↓") \(change(of: yearEnd)) vs Dec \(yearEnd.year - 1)",
                            large: false
                        )
                    }
                }
                NetWorthLineChart(actual: series.actual, forecast: series.forecast, today: content.today)
                HStack(spacing: 14) {
                    if !series.actual.isEmpty { legend(solid: true, "Actual") }
                    if !series.forecast.isEmpty { legend(solid: false, "Confirmed forecast") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Signed percent change so the figure agrees with the arrow ("↓ -4.0%"); the pound
    /// change when the baseline is zero and there is no percentage.
    private func change(of yearEnd: YearEndForecast) -> String {
        if let percent = yearEnd.percent { return DashboardFormat.percent(percent) }
        return DashboardFormat.pounds(abs(yearEnd.changeMinorUnits))
    }

    private func statBlock(title: String, value: String, detail: String?, large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(large ? .title2.bold() : .headline).monospacedDigit()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
    }

    /// Swatch matching the chart: a solid line for actual, a dashed line (same blue) for the
    /// confirmed forecast.
    private func legend(solid: Bool, _ text: String) -> some View {
        HStack(spacing: 4) {
            if solid {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.blue)
                    .frame(width: 14, height: 3)
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 1.5))
                    path.addLine(to: CGPoint(x: 14, y: 1.5))
                }
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                .frame(width: 14, height: 3)
            }
            Text(text)
        }
    }
}
