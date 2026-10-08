// App/DesignSystem/PlanCellView.swift
import SwiftUI
import BudgetCore

/// A plan grid cell (the Budget grid and the scenario lab's grid) with its unconfirmed part
/// shown: the value italic and `Color.pending` while any of it is pending, with `circle.fill` (all
/// expected) or `circle.lefthalf.filled` (partly happened), and help text splitting it
/// ("£x actual + £y expected"; a Year Total says "Includes £x not yet confirmed").
struct PlanCellView: View {
    static let bodyFont: Font = .system(.body, design: .default).monospacedDigit()
    static let captionFont: Font = .system(.caption, design: .default).monospacedDigit()

    let value: Int
    let pending: Int
    let state: PendingState
    var isYearTotal = false
    var font: Font = PlanCellView.bodyFont
    /// Extra help text appended on its own line (the lab's "Budget: £x" for a differing cell).
    var extraHelp: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if state != .none {
                Image(systemName: state == .partial ? "circle.lefthalf.filled" : "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.pending)
            }
            if value == 0 {
                Text("—").font(font).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            } else if pending != 0 {
                MoneyText(minorUnits: value, font: font.italic(), alignment: .trailing, tint: .pending)
            } else {
                MoneyText(minorUnits: value, font: font, alignment: .trailing)
            }
        }
        .frame(width: 120)
        .padding(.horizontal, 8)
        .help(help)
    }

    private var help: String {
        let pendingHelp = pending == 0 ? ""
            : isYearTotal ? "Includes \(Money.format(abs(pending), currency: .gbp)) not yet confirmed"
            : PlanFormat.pendingHelp(value: value, pending: pending)
        return [pendingHelp, extraHelp ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
