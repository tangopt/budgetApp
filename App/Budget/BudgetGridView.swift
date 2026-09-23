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
    @State private var drillDownTarget: GridDrillDownTarget?

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("Export CSV…") { showExporter = true }
            }
            .padding([.horizontal, .top])

            yearPicker

            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading) {
                    calendarHeaderRow
                    calendarCategorySection(.income, title: "Income")
                    calendarCategorySection(.expense, title: "Expenses")
                    calendarCategorySection(.transfer, title: "Transfers")
                }
                .padding()
            }
        }
        .fileExporter(isPresented: $showExporter, document: CSVDocument(text: BudgetGridExporter.export(categories: viewModel.categories, periods: viewModel.periods, transactions: viewModel.transactions)), contentType: .commaSeparatedText, defaultFilename: "budget-export") { _ in }
        // onDismiss clears any recategorize error so it can't bleed into the next,
        // unrelated drill-down.
        .sheet(item: $drillDownTarget, onDismiss: { viewModel.errorMessage = nil }) { target in
            GridDrillDownSheet(target: target, categories: viewModel.categories, errorMessage: viewModel.errorMessage, liveTransactions: viewModel.transactions) { transaction, categoryId in
                viewModel.recategorize(transaction, to: categoryId)
            }
        }
    }

    private var yearPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(viewModel.availableYears, id: \.self) { year in
                    Button {
                        viewModel.selectedYear = year
                    } label: {
                        VStack(spacing: 2) {
                            Text(String(year)).font(.subheadline).bold()
                            MoneyText(minorUnits: viewModel.yearlyTotal(year))
                            if let change = viewModel.yearOverYearChange(year) {
                                Text("\(change >= 0 ? "↑" : "↓") \(String(format: "%.1f", abs(change) * 100))%")
                                    .font(.caption2)
                                    .foregroundStyle(change >= 0 ? Color.green : Color.red)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(viewModel.selectedYear == year ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(viewModel.selectedYear == year ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private var calendarHeaderRow: some View {
        GridRow {
            Text("").frame(width: 220, alignment: .leading)
            if let year = viewModel.selectedYear {
                ForEach(1...12, id: \.self) { month in
                    Text(Self.monthYearLabel(year: year, month: month)).frame(width: 120)
                }
                Text("Year Total").frame(width: 120).bold()
            }
        }
        .font(.headline)
    }

    private func calendarCategorySection(_ type: CategoryType, title: String) -> some View {
        Section {
            ForEach(categoriesByType(type)) { category in
                GridRow {
                    Text(category.name).frame(width: 220, alignment: .leading)
                    if let year = viewModel.selectedYear {
                        ForEach(1...12, id: \.self) { month in
                            let total = viewModel.calendarCategoryTotal(category, year: year, month: month)
                            calendarCell(total)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard total != 0 else { return }
                                    let range = viewModel.dateRange(forYear: year, month: month)
                                    let matching = viewModel.transactions(forCategoryId: category.id!, from: range.start, to: range.end)
                                    drillDownTarget = .transactions(title: "\(category.name) — \(Self.monthYearLabel(year: year, month: month))", transactions: matching)
                                }
                        }
                        let yearTotal = (1...12).reduce(0) { $0 + viewModel.calendarCategoryTotal(category, year: year, month: $1) }
                        calendarCell(yearTotal).bold()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard yearTotal != 0 else { return }
                                let range = viewModel.dateRange(forYear: year)
                                let matching = viewModel.transactions(forCategoryId: category.id!, from: range.start, to: range.end)
                                drillDownTarget = .transactions(title: "\(category.name) — \(year)", transactions: matching)
                            }
                    }
                }
            }
        } header: {
            GridRow { Text(title).font(.subheadline).bold().padding(.top, 8) }
        }
    }

    private func calendarCell(_ total: Int) -> some View {
        Group {
            if total == 0 {
                Text("—").foregroundStyle(.secondary)
            } else {
                MoneyText(minorUnits: total)
            }
        }
        .frame(width: 120)
    }

    private static func monthYearLabel(year: Int, month: Int) -> String {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { return "\(month)/\(year)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
