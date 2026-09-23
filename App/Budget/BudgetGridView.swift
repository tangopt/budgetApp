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
                Picker("", selection: $viewModel.groupingMode) {
                    Text("Pay Period").tag(GridGroupingMode.payPeriod)
                    Text("Calendar").tag(GridGroupingMode.calendar)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
                Button("Export CSV…") { showExporter = true }
            }
            .padding([.horizontal, .top])

            if viewModel.groupingMode == .calendar {
                yearPicker
            }

            switch viewModel.groupingMode {
            case .payPeriod:
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
            case .calendar:
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
        }
        .fileExporter(isPresented: $showExporter, document: CSVDocument(text: BudgetGridExporter.export(categories: viewModel.categories, periods: viewModel.periods, transactions: viewModel.transactions)), contentType: .commaSeparatedText, defaultFilename: "budget-export") { _ in }
        .sheet(item: $drillDownTarget) { target in
            GridDrillDownSheet(target: target, categories: viewModel.categories, errorMessage: viewModel.errorMessage) { transaction, categoryId in
                viewModel.recategorize(transaction, to: categoryId)
            }
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
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard total != 0 else { return }
                            switch period.type {
                            case .actual:
                                let matching = viewModel.transactions(forCategoryId: category.id!, from: period.startDate, to: period.endDate)
                                drillDownTarget = .transactions(title: "\(category.name) — \(period.startDate.formatted(date: .abbreviated, time: .omitted))", transactions: matching)
                            case .projected:
                                let entries = viewModel.contributingForecastEntries(for: category, in: period)
                                drillDownTarget = .forecastEntries(title: "\(category.name) — Forecast", entries: entries)
                            }
                        }
                    }
                }
            }
        } header: {
            GridRow { Text(title).font(.subheadline).bold().padding(.top, 8) }
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
