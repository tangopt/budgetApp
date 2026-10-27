import SwiftUI
import BudgetCore

/// Property ▸ Tenancies on the iPad: the tenancies, the current one first; a tap selects one (the Bills grid reads
/// the selected tenancy).
struct PadTenanciesView: View {
    @ObservedObject var model: PadPropertyModel
    /// Until Tenancies is rebuilt (Task 13), the rent receipts open from here.
    @ObservedObject var rentReceipts: PadRentReceiptsModel
    @ObservedObject var write: PadWriteModel
    let syncStatus: SyncStatus
    @State private var showsReceipts = false
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.tenancies.isEmpty {
                        EmptyState(symbol: "person.2", title: "No tenancies", message: "Tenancies appear here once the Mac has shared them.")
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(model.tenancies) { tenancy in row(tenancy) }
                        }
                    }
                }
                .padding(20)
            }
            .background(theme.background)
            .offlineBannerSlot()
            .navigationTitle("Tenancies")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Rent receipts") { showsReceipts = true }
                }
            }
        }
        .sheet(isPresented: $showsReceipts) {
            PadRentReceiptsView(model: rentReceipts, property: model, write: write, syncStatus: syncStatus)
        }
        .task(id: SyncReloadTrigger(syncStatus)) { await model.reload() }
    }

    private func row(_ tenancy: Tenancy) -> some View {
        let selected = tenancy.id == model.selectedTenancyId
        return Button { model.selectedTenancyId = tenancy.id } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(tenancy.tenantName ?? tenancy.referenceLabel).font(.headline)
                        Spacer(minLength: 8)
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent).accessibilityLabel("Selected") }
                    }
                    Text(tenancy.referenceLabel).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        DateText(tenancy.startDate, font: .subheadline)
                        Text("to").font(.subheadline).foregroundStyle(.secondary)
                        if let end = tenancy.endDate { DateText(end, font: .subheadline) } else { Text("ongoing").font(.subheadline) }
                    }
                    if tenancy.depositMonths > 0 || tenancy.advanceRentMonths > 0 {
                        Text("Deposit \(tenancy.depositMonths) mo · advance \(tenancy.advanceRentMonths) mo")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selected ? theme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
