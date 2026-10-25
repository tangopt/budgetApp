// App/Property/PropertyFigurePanel.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Transaction

/// A figure of the Money tab beside it (clicking its row, or a cost category): the transactions
/// behind it, oldest first, each with what it counts, its day, category and account, documents,
/// Edit transaction and Show in Search. It reads them again whenever the page refreshes, so the
/// open figure stays open and current.
struct PropertyFigurePanel: View {
    @ObservedObject var viewModel: PropertyViewModel
    let title: String
    let drillDown: PropertyDrillDown
    let openTransaction: (Transaction) -> Void
    @State private var editing: Transaction?

    var body: some View {
        let rows = viewModel.transactions(drillDown)
        PropertySidePanel(title: title, subtitle: subtitle(rows.count), onClose: { viewModel.sidePanel = nil }) {
            if rows.isEmpty {
                Text("No transactions in this period.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(rows) { row in
                        PropertyPanelTransactionRow(
                            transaction: row.transaction, minorUnits: row.transaction.amountMinorUnits, currency: row.currency,
                            detail: [row.categoryName, row.accountName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                            onEdit: { editing = $0 }, onShow: openTransaction)
                    }
                }
                .wrapProbeClips()
            }
        }
        .sheet(item: $editing) { PropertyEditTransactionSheet(transaction: $0, dbQueue: viewModel.dbQueue) }
    }

    private func subtitle(_ count: Int) -> String {
        let period = viewModel.snapshot.summary?.period.label ?? ""
        return "\(count) transaction\(count == 1 ? "" : "s")" + (period.isEmpty ? "" : " · \(period)")
    }
}
