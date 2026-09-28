// App/Forecast/ForecastView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct ForecastView: View {
    @ObservedObject var viewModel: ForecastViewModel
    @State private var selectedYear: Int
    @State private var horizontalOffset: CGFloat = 0

    // A plain memberwise init would make `selectedYear` a required call-site argument;
    // this way callers just pass `viewModel`, and the initial year comes from it.
    init(viewModel: ForecastViewModel) {
        self.viewModel = viewModel
        _selectedYear = State(initialValue: viewModel.thisYear)
    }

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type }
    }

    private enum ForecastRowKind: Identifiable {
        case sectionHeader(String)
        case category(Category)
        var id: String {
            switch self {
            case .sectionHeader(let title): return "header-\(title)"
            case .category(let category): return "cat-\(category.id ?? -1)"
            }
        }
    }

    private struct ForecastRow: Identifiable {
        let kind: ForecastRowKind
        let shaded: Bool
        var id: String { kind.id }
    }

    private func rowColor(for type: CategoryType) -> Color {
        switch type {
        case .income: return .green
        case .expense: return .red
        case .transfer: return .blue
        }
    }

    private var allRows: [ForecastRow] {
        func section(_ title: String, _ type: CategoryType) -> [ForecastRow] {
            var rows: [ForecastRow] = [ForecastRow(kind: .sectionHeader(title), shaded: false)]
            for (index, category) in categoriesByType(type).enumerated() {
                rows.append(ForecastRow(kind: .category(category), shaded: index % 2 == 1))
            }
            return rows
        }
        return section("Income", .income) + section("Expenses", .expense) + section("Transfers", .transfer)
    }

    /// A category renders as a two-line row (confirmed + preview) when any month in the
    /// selected year has a preview total that differs from confirmed.
    private func isTwoLine(_ category: Category, year: Int) -> Bool {
        (1...12).contains { month in
            viewModel.categoryTotal(category, year: year, month: month) != viewModel.previewCategoryTotal(category, year: year, month: month)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            yearPicker

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text("Category").font(.headline).frame(width: 220, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                    HStack(spacing: 0) {
                        ForEach(1...12, id: \.self) { month in
                            Text(Self.monthLabel(month))
                                .frame(width: 120, alignment: .trailing)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                        }
                        Text("Year Total").bold()
                            .frame(width: 120, alignment: .trailing)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    .offset(x: horizontalOffset)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                }
                .font(.headline)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(Rectangle().frame(height: 1.5).foregroundStyle(Color.primary.opacity(0.18)), alignment: .bottom)
                .shadow(color: .black.opacity(0.08), radius: 3, y: 2)

                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(allRows) { entry in
                                rowLabel(entry.kind, shaded: entry.shaded)
                            }
                        }
                        .frame(width: 236, alignment: .leading)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)

                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(allRows) { entry in
                                    rowCells(entry.kind, shaded: entry.shaded)
                                }
                            }
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: ForecastHorizontalOffsetKey.self, value: geo.frame(in: .named("forecastHScroll")).minX)
                            })
                        }
                        .coordinateSpace(.named("forecastHScroll"))
                    }
                }
                .onPreferenceChange(ForecastHorizontalOffsetKey.self) { horizontalOffset = $0 }
            }
        }
        .padding()
    }

    private var yearPicker: some View {
        HStack(spacing: 10) {
            ForEach([viewModel.thisYear, viewModel.nextYear], id: \.self) { year in
                Button {
                    selectedYear = year
                } label: {
                    Text(String(year)).font(.subheadline).bold()
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedYear == year ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedYear == year ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func rowLabel(_ row: ForecastRowKind, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader(let title):
            Text(title)
                .font(.caption).bold()
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .frame(width: 220, height: 24, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.accentColor.opacity(0.08))
        case .category(let category):
            let twoLine = isTwoLine(category, year: selectedYear)
            Text(category.name)
                .frame(width: 220, height: twoLine ? 44 : 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(rowColor(for: category.type)), alignment: .leading)
        }
    }

    @ViewBuilder
    private func rowCells(_ row: ForecastRowKind, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader:
            HStack(spacing: 0) {
                ForEach(1...(12 + 1), id: \.self) { _ in
                    Color.clear.frame(width: 120, height: 24).padding(.horizontal, 8)
                }
            }
            .background(Color.accentColor.opacity(0.08))
        case .category(let category):
            let year = selectedYear
            let twoLine = isTwoLine(category, year: year)
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    let confirmed = viewModel.categoryTotal(category, year: year, month: month)
                    let preview = viewModel.previewCategoryTotal(category, year: year, month: month)
                    forecastCell(confirmed: confirmed, preview: preview, twoLine: twoLine)
                        .frame(height: twoLine ? 44 : 28)
                        .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                }
                let confirmedYearTotal = (1...12).reduce(0) { $0 + viewModel.categoryTotal(category, year: year, month: $1) }
                let previewYearTotal = (1...12).reduce(0) { $0 + viewModel.previewCategoryTotal(category, year: year, month: $1) }
                forecastCell(confirmed: confirmedYearTotal, preview: previewYearTotal, twoLine: twoLine, bold: true)
                    .frame(height: twoLine ? 44 : 28)
                    .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            }
        }
    }

    private func forecastCell(confirmed: Int, preview: Int, twoLine: Bool, bold: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Group {
                if confirmed == 0 {
                    Text("—").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    MoneyText(minorUnits: confirmed, alignment: .trailing)
                }
            }
            .fontWeight(bold ? .bold : .regular)
            if twoLine {
                if preview != confirmed {
                    MoneyText(minorUnits: preview, font: .caption2.monospacedDigit(), alignment: .trailing)
                        .opacity(0.7)
                } else {
                    Color.clear.frame(height: 14)
                }
            }
        }
        .frame(width: 120)
        .padding(.horizontal, 8)
    }

    private static func monthLabel(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.monthSymbols = Calendar(identifier: .gregorian).monthSymbols
        return formatter.monthSymbols[month - 1]
    }
}

/// The forecast grid body's horizontal scroll offset — same technique as
/// `BudgetGridView`'s `HorizontalOffsetKey`, a separate type because SwiftUI
/// `PreferenceKey`s are matched by type, and this view has its own frozen header.
private struct ForecastHorizontalOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}
