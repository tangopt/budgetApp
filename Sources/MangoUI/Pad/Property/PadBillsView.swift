import SwiftUI
import BudgetCore

/// Property ▸ Bills on the iPad (read only): rows are providers, columns are months (the latest year's), each cell
/// its stage and amount as `UtilityBills.read` has it. A tap selects the cell (`selectedCellId`) for Task 8's actions.
struct PadBillsView: View {
    @ObservedObject var model: PadPropertyModel
    let syncStatus: SyncStatus
    /// How many months back from the latest the shown window sits, and the width the table has.
    @State private var back = 0
    @State private var width: CGFloat = 0
    @Environment(\.phoneTheme) private var theme

    private let providerWidth: CGFloat = 150
    private let cellWidth: CGFloat = 112

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let grid = model.bills {
                        header(grid)
                        if grid.rows.isEmpty { Text(grid.summaryText).foregroundStyle(.secondary) } else { table(grid) }
                    } else {
                        EmptyState(symbol: "doc.text", title: "No utility bills", message: "Bills appear here once the Mac has shared a tenancy.")
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(20)
            }
            .background(theme.background)
            .offlineBannerSlot()
            .navigationTitle("Bills")
            .toolbar {
                if model.tenancies.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("Tenancy", selection: $model.selectedTenancyId) {
                            ForEach(model.tenancies) { Text($0.tenantName ?? $0.referenceLabel).tag($0.id) }
                        }
                    }
                }
            }
        }
        .task(id: SyncReloadTrigger(syncStatus)) { await model.reload() }
    }

    private func header(_ grid: UtilityBillsGrid) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            do {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(UtilityBillStage.allCases, id: \.self) { stage in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(grid.count(stage))").font(.title3.weight(.semibold).monospacedDigit())
                            Text(stage.displayName).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surface))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Text(grid.summaryText).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private static func monthTitle(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: month)
    }

    /// Every month with a bill, oldest first.
    private func allMonths(_ grid: UtilityBillsGrid) -> [Date] { Array(Set(grid.bills.map(\.month))).sorted() }

    /// How many month columns fit beside the provider names.
    private var fit: Int { max(1, Int((width - providerWidth) / (cellWidth + 8))) }

    private func table(_ grid: UtilityBillsGrid) -> some View {
        let all = allMonths(grid)
        let count = min(fit, all.count)
        let end = max(count, all.count - back)
        let months = Array(all[(end - count)..<end])
        return VStack(alignment: .leading, spacing: 8) {
            if all.count > count {
                HStack {
                    Button { back = min(back + count, all.count - count) } label: { Label("Earlier", systemImage: "chevron.left") }
                        .disabled(end - count <= 0)
                    Button { back = max(back - count, 0) } label: { Label("Later", systemImage: "chevron.right") }
                        .disabled(back == 0)
                }
                .buttonStyle(.bordered)
            }
            HStack(alignment: .top, spacing: 8) {
                Color.clear.frame(width: providerWidth, height: 1)
                ForEach(months, id: \.self) { month in
                    Text(Self.monthTitle(month).figuresUnbroken)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: cellWidth, alignment: .leading)
                }
            }
            ForEach(grid.rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.name).font(.subheadline.weight(.medium))
                        .frame(width: providerWidth, alignment: .leading)
                    ForEach(months, id: \.self) { month in
                        cell(grid.cell(row: row, month: month))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @ViewBuilder
    private func cell(_ cell: UtilityBillCell?) -> some View {
        if let cell {
            let selected = cell.id == model.selectedCellId
            let total = cell.bills.reduce(0) { $0 + $1.amountMinorUnits }
            Button { model.selectedCellId = cell.id } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cell.stage.displayName).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    MoneyText(minorUnits: total, currency: model.property?.currency ?? .gbp, role: .neutral, fit: .shrink())
                }
                .padding(10)
                .frame(width: cellWidth, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? theme.accent : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            Color.clear.frame(width: cellWidth, height: 1)
        }
    }
}
