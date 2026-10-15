// App/DesignSystem/YearCard.swift
import SwiftUI
import BudgetCore

/// A year in a year selector (the Budget grid's and the Forecast grid's), all the same size:
/// the year with an optional caption after it (" forecast", " today"), its year-end net worth,
/// and the change on the previous year-end as "↑ £24,953 · 16.4%" ("—" without one). Selected
/// cards are tinted and outlined in the accent colour. The whole tile hit-tests, so it can be
/// a plain button's label.
struct YearCard: View {
    let year: Int
    /// Shown after the year in secondary caption type, e.g. " forecast".
    var caption: String?
    /// The year-end net worth in minor units; nil shows "—".
    let yearEnd: Int?
    /// The year-end less the previous one, in minor units; nil when there's no previous.
    let change: Int?
    /// `change` as a fraction of the previous year-end's magnitude.
    let percent: Double?
    let isSelected: Bool

    /// Every year card's size: fits the largest content (three lines; a seven-figure net worth).
    static let size = CGSize(width: 160, height: 66)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(String(year)).font(.subheadline).bold()
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let yearEnd {
                MoneyText(minorUnits: yearEnd)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
            // No change (or less than shows in whole pounds) reads "—", not a green "↑ £0".
            if let change, DashboardFormat.pounds(abs(change)) != DashboardFormat.pounds(0) {
                Text(Self.changeText(change: change, percent: percent))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(change >= 0 ? Color.green : Color.red)
            } else {
                Text("—").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(8)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1))
        // The whole tile is the button: an unselected card's background is clear, which a plain
        // button otherwise doesn't hit-test (only its text was clickable).
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// "↑ £24,953 · 16.4%" (whole pounds); the percent is left out when there is none (a
    /// previous year-end of zero).
    static func changeText(change: Int, percent: Double?) -> String {
        let arrow = change >= 0 ? "↑" : "↓"
        let amount = DashboardFormat.pounds(abs(change))
        guard let percent else { return "\(arrow) \(amount)" }
        return "\(arrow) \(amount) · \(String(format: "%.1f", abs(percent) * 100))%"
    }
}

/// A horizontally scrolling row of `YearCard`s, each a plain button.
struct YearCardRow<Card: View>: View {
    let years: [Int]
    let onSelect: (Int) -> Void
    var help: String?
    @ViewBuilder let card: (Int) -> Card

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(years, id: \.self) { year in
                    Button { onSelect(year) } label: { card(year) }
                        .buttonStyle(.plain)
                        .help(help ?? "")
                }
            }
            // Vertical padding, not just horizontal: the selected card's 2pt stroke sits right
            // at the row's own edge, and ScrollView sizes its cross-axis tightly to content —
            // with no vertical breathing room the stroke's top/bottom pixel was clipped by the
            // scroll view's own bounds.
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }
}
