// App/DesignSystem/MultiYearColumns.swift
import SwiftUI
import BudgetCore

/// The multi-year columns the Budget grid and the Forecast grid show when several years are
/// selected: per year its total, and after every year but the first its change on the
/// previous selected year as "Δ vs <prev>" (£) and "%". Each year's columns form one band
/// (`yearGroupBand`, `yearGroupSeparator`).
enum MultiYearColumns {
    /// The scrolling area's full width for `yearCount` years: a total column per year plus
    /// Δ £ and Δ % after every year but the first.
    static func width(yearCount: Int) -> CGFloat {
        CGFloat(3 * yearCount - 2) * GridMetrics.columnWidth
    }
}

/// The frozen header's multi-year labels: per year its number (bold), then "Δ vs <prev>" and
/// "%" after every year but the first.
struct MultiYearHeaderRow: View {
    let years: [Int]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(years.enumerated()), id: \.element) { index, year in
                HStack(spacing: 0) {
                    MultiYearHeaderCell(title: String(year)).bold()
                    if index > 0 {
                        MultiYearHeaderCell(title: "Δ vs \(String(years[index - 1]))")
                        MultiYearHeaderCell(title: "%")
                    }
                }
                .yearGroupBand(index)
                .yearGroupSeparator(index)
            }
        }
    }
}

/// A multi-year header label, the width of a value column.
struct MultiYearHeaderCell: View {
    let title: String

    var body: some View {
        Text(title)
            .figureText(.shrink())
            .frame(width: GridMetrics.cellWidth, alignment: .trailing)
            .padding(.horizontal, GridMetrics.cellPadding).padding(.vertical, 6)
    }
}

/// The Δ £ and Δ % cells: `current` against `previous` (`YearOverYear.delta`), the theme's
/// good colour when the change is good for a line of `categoryType`
/// (`YearOverYear.isImprovement`), its bad colour when bad,
/// secondary when neutral (transfers, balances); "—" when either is missing or nothing changed.
struct YearDeltaCells: View {
    let current: Int?
    let previous: Int?
    var currency: Currency = .gbp
    let categoryType: CategoryType?
    /// A section header's band: caption type, 24pt high, no bottom rule.
    var isSectionHeader = false
    let background: Color
    @Environment(\.theme) private var theme

    var body: some View {
        let delta = current.flatMap { current in previous.map { YearOverYear.delta(current: current, previous: $0) } }
        let improvement = delta.flatMap { YearOverYear.isImprovement(amount: $0.amount, categoryType: categoryType) }
        let color = theme.change(improvement: improvement)
        HStack(spacing: 0) {
            Group {
                if let delta, delta.amount != 0 {
                    Text((delta.amount > 0 ? "+" : "") + Money.format(delta.amount, currency: currency))
                } else {
                    Text("—")
                }
            }
            .figureText(.shrink())
            .multiYearValueCell()
            Text(DashboardFormat.percent(delta?.amount == 0 ? nil : delta?.fraction))
                .figureText(.shrink())
                .multiYearValueCell()
        }
        .font(isSectionHeader ? PlanCellView.captionFont : PlanCellView.bodyFont)
        .foregroundStyle(color)
        .frame(height: isSectionHeader ? 24 : 28)
        .background(background)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator).opacity(isSectionHeader ? 0 : 1), alignment: .bottom)
    }
}

extension View {
    /// A multi-year value cell's footprint, right-aligned like the month cells.
    func multiYearValueCell() -> some View {
        frame(width: GridMetrics.cellWidth, alignment: .trailing)
            .padding(.horizontal, GridMetrics.cellPadding)
    }

    /// Every other selected year's columns (its total, Δ and %) get a light tint, so each year
    /// reads as one band when comparing several. An overlay, so it shows over row stripes and
    /// cell fills alike, and never takes clicks.
    func yearGroupBand(_ index: Int) -> some View {
        overlay(Color.primary.opacity(index.isMultiple(of: 2) ? 0 : 0.06).allowsHitTesting(false))
    }

    /// The leading 1pt separator between multi-year groups (none before the first year: the
    /// category column draws its own).
    func yearGroupSeparator(_ index: Int) -> some View {
        overlay(Rectangle().frame(width: 1).foregroundStyle(.separator).opacity(index > 0 ? 1 : 0), alignment: .leading)
    }
}
