// App/Categories/CategoryDistributionPanel.swift
import SwiftUI
import Charts
import BudgetCore

/// The Categories screen's side panel when nothing is selected (spec 2026-10-16 §C): where a
/// pay year's money went and came from, on the Budget grid's actuals basis
/// (`CategoryDistribution`). A year filter (the current year by default, or All years), then
/// two donuts — Expenses by group (click a slice or its legend row to see that group's
/// categories; ‹ All groups goes back) and Income by category — each with its total at the
/// centre (the hovered slice's name, amount and share instead while hovering) and a legend
/// list of every slice (name, amount, %).
struct CategoryDistributionPanel: View {
    @ObservedObject var viewModel: CategoriesViewModel
    /// The year filter and drill-in, kept by the Categories screen so they survive the panel
    /// giving way to a selection's transactions and coming back.
    @Binding var year: DistributionYear
    /// The expense group (slice id) whose categories the Expenses donut shows; nil = the groups.
    @Binding var drilledGroupId: String?
    @Environment(\.theme) private var theme

    /// The pay year shown; nil = All years.
    private var resolvedYear: Int? {
        switch year {
        case .current: return viewModel.payCalendar.current.year
        case .year(let year): return year
        case .all: return nil
        }
    }

    var body: some View {
        let distribution = viewModel.distribution(year: resolvedYear)
        let incomeSlots = viewModel.distributionColorSlots(.income)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Distribution").font(.headline)
                Spacer()
                yearPicker
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    expenses(distribution)
                    Divider()
                    DistributionDonut(title: "Income", emptyText: emptyText("income"),
                                      slices: distribution.incomeByCategory, total: distribution.incomeTotal,
                                      colorSlot: { incomeSlots[$0] ?? 0 }, otherHint: "Smaller categories — see the list")
                }
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.windowFill)
        .onChange(of: year) { _, _ in drilledGroupId = nil }
    }

    @ViewBuilder
    private func expenses(_ distribution: CategoryDistribution) -> some View {
        // The drilled group is shown as it is this year (back to the groups if it has no spending now).
        if let id = drilledGroupId, let group = distribution.expensesByGroup.first(where: { $0.id == id }) {
            let categories = distribution.expenseCategories(inGroup: group.groupId)
            let total = categories.reduce(0) { $0 + $1.amountMinorUnits }
            let slots = viewModel.distributionColorSlots(.expenseCategories(groupId: group.groupId))
            DistributionDonut(title: "Expenses · \(group.name)", emptyText: emptyText("expenses"),
                              caption: total == group.amountMinorUnits ? nil
                                : "Net \(Money.format(group.amountMinorUnits, currency: .gbp)) after refunds",
                              slices: categories, total: total,
                              colorSlot: { slots[$0] ?? 0 }, otherHint: "Smaller categories — see the list",
                              onBack: { drilledGroupId = nil })
                .id(group.id)
        } else {
            let slots = viewModel.distributionColorSlots(.expenseGroups)
            DistributionDonut(title: "Expenses by group", emptyText: emptyText("expenses"),
                              slices: distribution.expensesByGroup, total: distribution.expenseTotal,
                              colorSlot: { slots[$0] ?? 0 }, otherHint: "Smaller groups — see the list",
                              onSelect: { drilledGroupId = $0.id })
                .id("groups")
        }
    }

    private func emptyText(_ kind: String) -> String {
        resolvedYear.map { "No \(kind) in \(String($0))." } ?? "No \(kind) yet."
    }

    private var yearPicker: some View {
        let current = viewModel.payCalendar.current.year
        let selection = Binding<Int?>(
            get: { resolvedYear },
            set: { picked in year = picked.map { $0 == current ? .current : .year($0) } ?? .all }
        )
        return Picker("Year", selection: selection) {
            ForEach(viewModel.distributionYears, id: \.self) { year in
                Text(String(year)).tag(Int?.some(year))
            }
            Divider()
            Text("All years").tag(Int?.none)
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// The Distribution panel's year filter: the current pay year (the default, resolved when
/// shown), a given year, or All years.
enum DistributionYear: Hashable {
    case current
    case year(Int)
    case all
}

/// One donut with its centre total, hover readout and legend list. Each slice wears its
/// entity's stable chart series colour (`colorSlot`); past the palette's length the smallest
/// fold into one grey "Other" wedge (the legend still lists each).
private struct DistributionDonut: View {
    let title: String
    let emptyText: String
    /// Under the title (a drilled group's net when refunds make it differ from the total).
    var caption: String? = nil
    let slices: [CategoryDistribution.Slice]
    let total: Int
    /// Each slice's stable palette slot by slice id (`distributionColorSlots`), so a group or
    /// category keeps its colour across years and ranks.
    let colorSlot: (String) -> Int
    /// Shown in the centre while the folded Other wedge is hovered.
    let otherHint: String
    /// Back to the groups (a drilled-in Expenses donut).
    var onBack: (() -> Void)? = nil
    /// A slice clicked (the groups donut drills in).
    var onSelect: ((CategoryDistribution.Slice) -> Void)? = nil

    @Environment(\.theme) private var theme
    /// The wedge (or legend row) under the pointer: a slice id, or `otherId`.
    @State private var hoveredId: String?

    private static let otherId = "other"
    private static let innerRatio: CGFloat = 0.62

    /// A drawn wedge: one slice, or the folded "Other".
    private struct Wedge: Identifiable {
        let id: String
        let name: String
        let amount: Int
        let color: Color
        let slice: CategoryDistribution.Slice?
    }

    private var palette: Int { theme.chartSeries.count }

    /// Every slice gets its own colour when they fit; otherwise the first `palette - 1` do
    /// and the rest share Other's grey.
    private var colouredCount: Int { slices.count <= palette ? slices.count : palette - 1 }

    private var otherColor: Color { Color.secondary.opacity(0.45) }

    /// A kept slice's entity colour; folded ones share Other's grey.
    private func color(at index: Int) -> Color {
        index < colouredCount ? theme.series(colorSlot(slices[index].id)) : otherColor
    }

    private var wedges: [Wedge] {
        var wedges = slices.prefix(colouredCount).enumerated().map { index, slice in
            Wedge(id: slice.id, name: slice.name, amount: slice.amountMinorUnits, color: color(at: index), slice: slice)
        }
        let rest = slices.dropFirst(colouredCount)
        if !rest.isEmpty {
            wedges.append(Wedge(id: Self.otherId, name: "Other (\(rest.count))",
                                amount: rest.reduce(0) { $0 + $1.amountMinorUnits }, color: otherColor, slice: nil))
        }
        return wedges
    }

    var body: some View {
        let wedges = wedges
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let onBack {
                    Button(action: onBack) { Label("All groups", systemImage: "chevron.backward") }
                        .buttonStyle(.borderless)
                        .help("Back to all groups")
                }
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            if slices.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary)
            } else {
                chart(wedges)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                legend
            }
        }
    }

    // MARK: Chart

    private func chart(_ wedges: [Wedge]) -> some View {
        Chart(wedges) { wedge in
            SectorMark(angle: .value("Amount", wedge.amount), innerRadius: .ratio(Self.innerRatio), angularInset: 1)
                .cornerRadius(3)
                .foregroundStyle(wedge.color)
                .opacity(hoveredId == nil || hoveredId == wedge.id ? 1 : 0.35)
                .accessibilityLabel(wedge.name)
                .accessibilityValue("\(Money.format(wedge.amount, currency: .gbp)), \(percent(wedge.amount))")
        }
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    centre(wedges)
                        .frame(width: min(frame.width, frame.height) * Self.innerRatio * 0.85)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hoveredId = wedge(at: location, in: frame, wedges: wedges)?.id
                            case .ended: hoveredId = nil
                            }
                        }
                        .onTapGesture(coordinateSpace: .local) { location in
                            if let slice = wedge(at: location, in: frame, wedges: wedges)?.slice { onSelect?(slice) }
                        }
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: hoveredId)
    }

    /// The total, or the hovered wedge's name, amount and share.
    private func centre(_ wedges: [Wedge]) -> some View {
        let hovered = wedges.first { $0.id == hoveredId }
        return VStack(spacing: 2) {
            Text(hovered?.name ?? "Total")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(Money.format(hovered?.amount ?? total, currency: .gbp))
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let hovered {
                Text(percent(hovered.amount)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if hovered.slice == nil {
                    Text(otherHint).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).multilineTextAlignment(.center)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The wedge under `location`: within the ring, by its angle clockwise from 12 o'clock.
    private func wedge(at location: CGPoint, in frame: CGRect, wedges: [Wedge]) -> Wedge? {
        let dx = location.x - frame.midX, dy = location.y - frame.midY
        let distance = (dx * dx + dy * dy).squareRoot()
        let outer = min(frame.width, frame.height) / 2
        guard distance <= outer, distance >= outer * Self.innerRatio, total > 0 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let target = Double(angle / (2 * .pi)) * Double(wedges.reduce(0) { $0 + $1.amount })
        var running = 0.0
        for wedge in wedges {
            running += Double(wedge.amount)
            if target < running { return wedge }
        }
        return wedges.last
    }

    // MARK: Legend

    private var legend: some View {
        VStack(spacing: 0) {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                let wedgeId = index < colouredCount ? slice.id : Self.otherId
                legendRow(slice, color: color(at: index), highlighted: hoveredId == wedgeId)
                    .onHover { inside in
                        if inside { hoveredId = wedgeId } else if hoveredId == wedgeId { hoveredId = nil }
                    }
            }
        }
    }

    @ViewBuilder
    private func legendRow(_ slice: CategoryDistribution.Slice, color: Color, highlighted: Bool) -> some View {
        let content = HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(slice.name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(Money.format(slice.amountMinorUnits, currency: .gbp)).monospacedDigit()
            Text(percent(slice.amountMinorUnits))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            if onSelect != nil {
                Image(systemName: "chevron.forward").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(highlighted ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slice.name)
        .accessibilityValue("\(Money.format(slice.amountMinorUnits, currency: .gbp)), \(percent(slice.amountMinorUnits))")

        if let onSelect {
            Button { onSelect(slice) } label: { content }
                .buttonStyle(.plain)
                .help("Show \(slice.name)'s categories")
                .accessibilityHint("Shows the group's categories")
        } else {
            content
        }
    }

    private func percent(_ amount: Int) -> String {
        guard total > 0 else { return "" }
        let share = Double(amount) / Double(total)
        if share > 0 && share < 0.005 { return "<1%" }
        return share.formatted(.percent.precision(.fractionLength(0)))
    }
}
