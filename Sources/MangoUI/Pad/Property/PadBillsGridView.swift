import SwiftUI
import BudgetCore

/// The stage's colour and icon in the bills grid and its legend (step 10, Task 11). The colour is never the only cue: each
/// stage has its own icon, and a cell is read out with the stage's name.
extension UtilityBillStage {
    var padSymbol: String {
        switch self {
        case .missingInvoice: "questionmark"
        case .invoiceIn: "doc.text"
        case .linkedToPayment: "link"
        case .inRecharge: "list.bullet.rectangle"
        case .sentToTenant: "paperplane"
        case .paidByTenant: "checkmark"
        }
    }

    func padColor(_ theme: PhoneTheme) -> Color {
        switch self {
        case .missingInvoice: .secondary
        case .invoiceIn: theme.transfer
        case .linkedToPayment: theme.accent
        case .inRecharge: theme.pending
        case .sentToTenant: .purple
        case .paidByTenant: theme.income
        }
    }
}

extension UtilityBillStage {
    /// The word inside a grid cell (the cell names its stage, so the grid needs no legend).
    var padCellName: String {
        switch self {
        case .missingInvoice: "Expected"
        case .invoiceIn: "Invoice in"
        case .linkedToPayment: "Linked"
        case .inRecharge: "In statement"
        case .sentToTenant: "Sent"
        case .paidByTenant: "Paid"
        }
    }
}

/// The year's bills as a provider × month grid. Each cell is coloured by the stage of its bill(s) and names it ("Paid",
/// "Sent"...) over the amount; a tap selects the cell's first bill (the document panel opens on it). Providers stay on the
/// left. The columns are as wide as the widest figure or stage word in view needs (so a wider typeface, or larger text,
/// shows fewer months, never a squeezed figure), and the months in view move with Earlier / Later.
struct PadBillsGridView: View {
    @ObservedObject var model: PadBillsAndRechargesModel
    @ObservedObject var property: PadPropertyModel
    @Environment(\.phoneTheme) private var theme
    /// How many months back from the latest the shown window sits, and the width the table has.
    @State private var back = 0
    @State private var width: CGFloat = 0
    /// The widest amount and the widest stage word (icon included) in view, measured in the page's font.
    @State private var widestFigure: CGFloat = 0
    @State private var widestLabel: CGFloat = 0
    @ScaledMetric(relativeTo: .subheadline) private var providerWidth: CGFloat = 120
    @ScaledMetric(relativeTo: .subheadline) private var cellHeight: CGFloat = 60
    @ScaledMetric(relativeTo: .subheadline) private var headerHeight: CGFloat = 24

    static let minimumCellWidth: CGFloat = 92
    static let cellPadding: CGFloat = 8
    static let spacing: CGFloat = 8

    /// A cell's width: the widest content plus its padding (and a little air), never below the minimum.
    static func cellWidth(widestFigure: CGFloat, widestLabel: CGFloat) -> CGFloat {
        max(minimumCellWidth, ceil(max(widestFigure, widestLabel)) + 2 * cellPadding + 4)
    }

    /// How many month columns fit in `width` beside `providerWidth`, at least one.
    static func columnsFit(width: CGFloat, providerWidth: CGFloat, cellWidth: CGFloat) -> Int {
        guard width.isFinite else { return 1 }
        return max(1, Int((width - providerWidth - spacing) / (cellWidth + spacing)))
    }

    private var cellWidth: CGFloat { Self.cellWidth(widestFigure: widestFigure, widestLabel: widestLabel) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let grid = property.bills {
                let months = model.months(year: model.year)
                let rows = grid.rows.filter { row in months.contains { grid.cell(row: row, month: $0) != nil } }
                if rows.isEmpty {
                    Text("No bills in \(String(model.year)).").foregroundStyle(.secondary)
                } else {
                    let shown = window(months)
                    table(grid, rows: rows, months: shown, all: months)
                        .background(measuring(grid, rows: rows, months: months))
                    Text(grid.summaryText).mangoFont(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// Invisible copies of the longest amounts and the stage words, in the cell's fonts, to read the widest of each.
    private func measuring(_ grid: UtilityBillsGrid, rows: [UtilityBillRow], months: [Date]) -> some View {
        let totals = rows.flatMap { row in months.compactMap { grid.cell(row: row, month: $0) } }
            .map { cell in cell.bills.reduce(0) { $0 + $1.amountMinorUnits } }
        // The longest few by characters: the widest rendering is among them (digits share a width in the figure face; a
        // minus sign or a wider digit set can still reorder neighbours).
        let candidates = Array(Set(totals.map { Money.format($0, currency: model.currency) })
            .sorted { $0.count > $1.count }.prefix(4))
        return ZStack {
            VStack(alignment: .leading) {
                ForEach(candidates, id: \.self) { Text($0).mangoFont(.subheadline, figures: true) }
            }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widestFigure = $0 }
            VStack(alignment: .leading) {
                ForEach(UtilityBillStage.padLegend, id: \.self) { stage in
                    HStack(spacing: 4) {
                        Image(systemName: stage.padSymbol).mangoFont(.caption2, weight: .bold)
                        Text(stage.padCellName).mangoFont(.caption, weight: .semibold)
                        Text("×2").mangoFont(.caption2)
                    }
                }
            }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widestLabel = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// How many month columns fit beside the provider names.
    private var fit: Int { Self.columnsFit(width: width, providerWidth: providerWidth, cellWidth: cellWidth) }

    /// The months shown: as many as fit, ending `back` months before the latest.
    private func window(_ all: [Date]) -> [Date] {
        let count = min(fit, all.count)
        let end = max(count, all.count - back)
        return Array(all[(end - count)..<end])
    }

    private func table(_ grid: UtilityBillsGrid, rows: [UtilityBillRow], months: [Date], all: [Date]) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            if all.count > months.count {
                HStack(spacing: MangoSpacing.xxs) {
                    let earliest = all.firstIndex(of: months.first ?? Date()) ?? 0
                    PadIconButton(systemImage: "chevron.left", label: "Earlier months") { back = min(back + months.count, all.count - months.count) }
                        .disabled(earliest <= 0)
                    Text("\(Self.monthTitle(months.first ?? Date())) – \(Self.monthTitle(months.last ?? Date()))")
                        .mangoFont(.subheadline, weight: .semibold).foregroundStyle(.secondary)
                    PadIconButton(systemImage: "chevron.right", label: "Later months") { back = max(back - months.count, 0) }
                        .disabled(back == 0)
                }
            }
            HStack(alignment: .top, spacing: Self.spacing) {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    Color.clear.frame(width: providerWidth, height: headerHeight)
                    ForEach(rows) { row in
                        Text(row.name).mangoFont(.subheadline, weight: .medium)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(width: providerWidth, height: cellHeight, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: Self.spacing) {
                    HStack(spacing: Self.spacing) {
                        ForEach(months, id: \.self) { month in
                            Text(Self.monthTitle(month)).mangoFont(.subheadline, weight: .semibold)
                                .frame(width: cellWidth, height: headerHeight, alignment: .leading)
                        }
                    }
                    ForEach(rows) { row in
                        HStack(spacing: Self.spacing) {
                            ForEach(months, id: \.self) { month in cell(grid.cell(row: row, month: month), row: row, month: month) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cell(_ cell: UtilityBillCell?, row: UtilityBillRow, month: Date) -> some View {
        if let cell {
            let selected = cell.bills.contains { $0.id == model.selectedBillId }
            let stage = cell.stage
            let color = stage.padColor(theme)
            let total = cell.bills.reduce(0) { $0 + $1.amountMinorUnits }
            Button { model.select(cell) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: stage.padSymbol).mangoFont(.caption2, weight: .bold).foregroundStyle(color)
                        Text(stage.padCellName).mangoFont(.caption, weight: .semibold).foregroundStyle(color).lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                        if cell.bills.count > 1 { Text("×\(cell.bills.count)").mangoFont(.caption2).foregroundStyle(.secondary).fixedSize() }
                    }
                    MoneyText(minorUnits: total, currency: model.currency, role: .neutral, fit: .shrink(), font: .subheadline)
                }
                .padding(Self.cellPadding)
                .frame(width: cellWidth, height: cellHeight, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? theme.accent : .clear, lineWidth: 2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(row.name), \(Self.monthTitle(month)), \(stage.padName), \(Money.format(total, currency: model.currency))")
            .accessibilityIdentifier("pad-bill-cell-\(cell.id)")
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            Color.clear.frame(width: cellWidth, height: cellHeight)
        }
    }

    static func monthTitle(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMM"
        return formatter.string(from: month)
    }
}
