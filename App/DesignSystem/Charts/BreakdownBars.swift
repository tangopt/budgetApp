// App/DesignSystem/Charts/BreakdownBars.swift
import SwiftUI
import BudgetCore

/// One part of a whole: a label and its size (a positive amount in minor units, or a count).
struct BreakdownItem: Identifiable, Equatable {
    let id: String
    let label: String
    let value: Int

    /// A part measured in money (minor units, a positive magnitude).
    init(_ label: String, minorUnits: Int, id: String? = nil) {
        self.id = id ?? label
        self.label = label
        self.value = minorUnits
    }

    /// A part measured in things (documents of a kind).
    init(_ label: String, count: Int, id: String? = nil) {
        self.id = id ?? label
        self.label = label
        self.value = count
    }
}

/// A whole broken into parts (spec §4.1; costs by category, expenses by tax line, documents by
/// kind): per part a colour dot and label, a bar in proportion to the largest part, the
/// amount (or count) and its share — the Categories distribution legend as a chart. Parts
/// beyond `maxItems` fold into "Other". With `onSelect`, each part (not the folded row) ends
/// with a chevron that opens it (its transactions).
struct BreakdownBars: View {
    enum Measure: Equatable {
        case money(Currency, MoneyRole)
        case count
    }

    let items: [BreakdownItem]
    let measure: Measure
    var maxItems: Int
    var showsShare: Bool
    /// The folded parts' row ("Other kinds" where "Other" is a part of its own).
    var otherLabel: String
    /// Opens a part (the chevron at the end of its row); `selectTitle` says what it opens.
    var onSelect: ((BreakdownItem) -> Void)?
    var selectTitle: (BreakdownItem) -> String
    /// Keeps the parts of zero or less (a category whose refunds cancel its costs) as rows
    /// without a bar, after the others — still openable.
    var keepsNonPositive = false
    /// The part whose details are open (its row drawn in the selection colours).
    var selectedId: String?
    @Environment(\.theme) private var theme

    /// Parts in money: amounts as `MoneyText` in `role` (`.neutral` for a breakdown of costs).
    init(items: [BreakdownItem], currency: Currency, role: MoneyRole = .neutral, maxItems: Int = 8, showsShare: Bool = true,
         otherLabel: String = "Other", keepsNonPositive: Bool = false, selectedId: String? = nil, selectTitle: @escaping (BreakdownItem) -> String = { "Show \($0.label)" },
         onSelect: ((BreakdownItem) -> Void)? = nil) {
        self.items = items
        self.measure = .money(currency, role)
        self.maxItems = maxItems
        self.showsShare = showsShare
        self.otherLabel = otherLabel
        self.keepsNonPositive = keepsNonPositive
        self.selectedId = selectedId
        self.onSelect = onSelect
        self.selectTitle = selectTitle
    }

    /// Parts counted ("12" documents).
    init(counts items: [BreakdownItem], maxItems: Int = 8, showsShare: Bool = true, otherLabel: String = "Other",
         selectTitle: @escaping (BreakdownItem) -> String = { "Show \($0.label)" }, onSelect: ((BreakdownItem) -> Void)? = nil) {
        self.items = items
        self.measure = .count
        self.maxItems = maxItems
        self.showsShare = showsShare
        self.otherLabel = otherLabel
        self.onSelect = onSelect
        self.selectTitle = selectTitle
    }

    private var shown: [BreakdownItem] {
        let sorted = items.filter { $0.value > 0 }.sorted { ($0.value, $1.label) > ($1.value, $0.label) }
        let rest = keepsNonPositive ? items.filter { $0.value <= 0 }.sorted { ($0.value, $1.label) > ($1.value, $0.label) } : []
        guard sorted.count > maxItems else { return sorted + rest }
        let head = Array(sorted.prefix(maxItems - 1))
        let folded = sorted.dropFirst(maxItems - 1).reduce(0) { $0 + $1.value }
        return head + [BreakdownItem(otherLabel, count: folded, id: "breakdown.other")] + rest
    }

    var body: some View {
        let parts = shown
        let total = max(1, parts.reduce(0) { $0 + max(0, $1.value) })
        let largest = max(1, parts.map(\.value).max() ?? 1)
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                let color = part.id == "breakdown.other" ? Color.secondary : theme.series(index)
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                        // Labels keep their width; the bar gives way.
                        Text(part.label).lineLimit(1).fixedSize().fontWeight(part.id == selectedId ? .semibold : .regular)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(part.id == selectedId ? theme.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { if part.id != "breakdown.other" { onSelect?(part) } }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.12))
                            if part.value > 0 {
                                Capsule().fill(color)
                                    .frame(width: max(4, proxy.size.width * CGFloat(part.value) / CGFloat(largest)))
                            }
                        }
                    }
                    .frame(minWidth: 60, maxWidth: .infinity)
                    .frame(height: 8)
                    .accessibilityHidden(true)
                    value(part.value)
                        .gridColumnAlignment(.trailing)
                    if showsShare {
                        Text(part.value > 0 ? share(part.value, of: total) : "—")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    if let onSelect {
                        if part.id == "breakdown.other" {
                            Text(verbatim: "")
                        } else {
                            Button { onSelect(part) } label: {
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(part.id == selectedId ? Color.accentColor : Color.secondary)
                            .help(selectTitle(part))
                            .accessibilityLabel(selectTitle(part))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(part.id == selectedId ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func value(_ value: Int) -> some View {
        switch measure {
        case let .money(currency, role):
            MoneyText(minorUnits: value, currency: currency, role: role)
        case .count:
            Text("\(value)").monospacedDigit().lineLimit(1).fixedSize()
        }
    }

    private func share(_ part: Int, of total: Int) -> String {
        let percent = Double(part) / Double(total) * 100
        return percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }
}
