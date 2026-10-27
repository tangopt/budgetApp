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

/// The year's bills as a provider × month grid, each cell coloured by the stage of its bill(s) with their amount; a tap
/// selects the cell's first bill (the document panel opens on it). Providers stay on the left while the months scroll.
struct PadBillsGridView: View {
    @ObservedObject var model: PadBillsAndRechargesModel
    @ObservedObject var property: PadPropertyModel
    @Environment(\.phoneTheme) private var theme
    /// How many months back from the latest the shown window sits, and the width the table has.
    @State private var back = 0
    @State private var width: CGFloat = 0

    static let providerWidth: CGFloat = 120
    static let cellWidth: CGFloat = 92
    static let cellHeight: CGFloat = 56
    static let headerHeight: CGFloat = 24
    static let spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            legend
            if let grid = property.bills {
                let months = model.months(year: model.year)
                let shown = window(months)
                let rows = grid.rows.filter { row in months.contains { grid.cell(row: row, month: $0) != nil } }
                if rows.isEmpty {
                    Text("No bills in \(String(model.year)).").foregroundStyle(.secondary)
                } else {
                    table(grid, rows: rows, months: shown, all: months)
                    Text(grid.summaryText).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(UtilityBillStage.padLegend, id: \.self) { stage in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(stage.padColor(theme).opacity(0.25))
                        .overlay(Image(systemName: stage.padSymbol).font(.caption2.weight(.bold)).foregroundStyle(stage.padColor(theme)))
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    Text(stage.padName).font(.footnote).lineLimit(1)
                }
            }
        }
    }

    /// How many month columns fit beside the provider names.
    private var fit: Int { max(1, Int((width - Self.providerWidth - Self.spacing) / (Self.cellWidth + Self.spacing))) }

    /// The months shown: as many as fit, ending `back` months before the latest.
    private func window(_ all: [Date]) -> [Date] {
        let count = min(fit, all.count)
        let end = max(count, all.count - back)
        return Array(all[(end - count)..<end])
    }

    private func table(_ grid: UtilityBillsGrid, rows: [UtilityBillRow], months: [Date], all: [Date]) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            if all.count > months.count {
                HStack(spacing: 8) {
                    let earliest = all.firstIndex(of: months.first ?? Date()) ?? 0
                    Button { back = min(back + months.count, all.count - months.count) } label: { Label("Earlier", systemImage: "chevron.left") }
                        .disabled(earliest <= 0)
                    Button { back = max(back - months.count, 0) } label: { Label("Later", systemImage: "chevron.right") }
                        .disabled(back == 0)
                }
                .buttonStyle(.pad(.secondary, size: .small))
            }
            HStack(alignment: .top, spacing: Self.spacing) {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    Color.clear.frame(width: Self.providerWidth, height: Self.headerHeight)
                    ForEach(rows) { row in
                        Text(row.name).font(.subheadline.weight(.medium))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(width: Self.providerWidth, height: Self.cellHeight, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: Self.spacing) {
                    HStack(spacing: Self.spacing) {
                        ForEach(months, id: \.self) { month in
                            Text(Self.monthTitle(month)).font(.subheadline.weight(.semibold))
                                .frame(width: Self.cellWidth, height: Self.headerHeight, alignment: .leading)
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
                        Image(systemName: stage.padSymbol).font(.caption2.weight(.bold)).foregroundStyle(color)
                        Spacer(minLength: 0)
                        if cell.bills.count > 1 { Text("×\(cell.bills.count)").font(.caption2).foregroundStyle(.secondary) }
                    }
                    MoneyText(minorUnits: total, currency: model.currency, role: .neutral, fit: .shrink(), font: .subheadline)
                }
                .padding(8)
                .frame(width: Self.cellWidth, height: Self.cellHeight, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? theme.accent : .clear, lineWidth: 2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("\(row.name), \(Self.monthTitle(month)): \(stage.padName)")
            .accessibilityIdentifier("pad-bill-cell-\(cell.id)")
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            Color.clear.frame(width: Self.cellWidth, height: Self.cellHeight)
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
