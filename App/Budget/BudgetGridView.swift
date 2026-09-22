// App/Budget/BudgetGridView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct BudgetGridView: View {
    @ObservedObject var viewModel: BudgetGridViewModel

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading) {
                headerRow
                summaryRows
                Divider()
                categorySection(.income, title: "Income")
                categorySection(.expense, title: "Expenses")
                categorySection(.transfer, title: "Transfers")
            }
            .padding()
        }
    }

    private var headerRow: some View {
        GridRow {
            Text("").frame(width: 220, alignment: .leading)
            ForEach(viewModel.periods, id: \.startDate) { period in
                VStack {
                    Text(period.startDate.formatted(date: .abbreviated, time: .omitted))
                    if period.type == .projected { Text("(forecast)").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(width: 120)
            }
        }
        .font(.headline)
    }

    private var summaryRows: some View {
        Group {
            summaryRow("Income") { viewModel.summary(for: $0).incomeMinorUnits }
            summaryRow("Total Expenses") { viewModel.summary(for: $0).expensesMinorUnits }
            summaryRow("Total Transfers") { viewModel.summary(for: $0).transfersMinorUnits }
            summaryRow("Money Remaining") { viewModel.summary(for: $0).moneyRemainingMinorUnits }
        }
        .bold()
    }

    private func summaryRow(_ title: String, _ value: @escaping (PayPeriod) -> Int) -> some View {
        GridRow {
            Text(title).frame(width: 220, alignment: .leading)
            ForEach(viewModel.periods, id: \.startDate) { period in
                Text(Money.format(value(period), currency: .gbp)).frame(width: 120)
            }
        }
    }

    private func categorySection(_ type: CategoryType, title: String) -> some View {
        Section {
            ForEach(categoriesByType(type)) { category in
                GridRow {
                    Text(category.name).frame(width: 220, alignment: .leading)
                    ForEach(viewModel.periods, id: \.startDate) { period in
                        let total = viewModel.categoryTotal(category, in: period)
                        Text(total == 0 ? "—" : Money.format(total, currency: .gbp))
                            .frame(width: 120)
                            .foregroundStyle(total == 0 ? .secondary : .primary)
                    }
                }
            }
        } header: {
            GridRow { Text(title).font(.subheadline).bold().padding(.top, 8) }
        }
    }
}
