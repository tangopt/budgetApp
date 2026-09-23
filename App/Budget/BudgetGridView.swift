// App/Budget/BudgetGridView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import UniformTypeIdentifiers

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = "" }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct BudgetGridView: View {
    @ObservedObject var viewModel: BudgetGridViewModel
    @State private var showExporter = false

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Button("Export CSV…") { showExporter = true }
                .padding([.horizontal, .top])
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
        .fileExporter(isPresented: $showExporter, document: CSVDocument(text: BudgetGridExporter.export(categories: viewModel.categories, periods: viewModel.periods, transactions: viewModel.transactions)), contentType: .commaSeparatedText, defaultFilename: "budget-export") { _ in }
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
                MoneyText(minorUnits: value(period)).frame(width: 120)
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
                        Group {
                            if total == 0 {
                                Text("—").foregroundStyle(.secondary)
                            } else {
                                MoneyText(minorUnits: total)
                            }
                        }
                        .frame(width: 120)
                    }
                }
            }
        } header: {
            GridRow { Text(title).font(.subheadline).bold().padding(.top, 8) }
        }
    }
}
