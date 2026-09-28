// App/Forecast/ForecastView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct ForecastView: View {
    @ObservedObject var viewModel: ForecastViewModel
    @State private var selectedYear: Int
    @State private var horizontalOffset: CGFloat = 0
    @State private var showNewEntrySheet = false
    @State private var editingEntry: ForecastEntry?
    @State private var manageExpanded = false

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
        // The whole page scrolls (not just the grid): with "Manage forecast" expanded and
        // populated with real groups/entries, (headline + picker + grid + panel) can easily
        // exceed the window's height, and without an enclosing ScrollView here, standard
        // VStack layout negotiation squeezes the grid's own ScrollView toward a degenerate
        // size while the panel's content lays out beyond what's reachable — freezing the
        // whole screen (no scroll container anywhere could reach it). See git history for
        // the incident this fixes.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                netWorthHeadline
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
                    // Bounded height keeps this the fixed-size scrollable viewport the
                    // frozen-header/frozen-column technique needs — without it, this
                    // ScrollView sizes to its ideal (unbounded) content height and competes
                    // for space with manageForecastSection below, which is what caused the
                    // freeze this fixes. 480 shows a comfortable number of rows (~15-17
                    // single-line, ~10-11 two-line) before this inner view needs its own
                    // scroll — picked to roughly match how much of the grid was visible in
                    // the pre-fix baseline on a normal window before "Manage forecast"
                    // existed.
                    .frame(height: 480)
                    .onPreferenceChange(ForecastHorizontalOffsetKey.self) { horizontalOffset = $0 }
                }
                manageForecastSection
            }
            .padding()
        }
        .sheet(isPresented: $showNewEntrySheet) {
            NewForecastEntryView(categories: viewModel.categories) { newGroupName, categoryId, amountMinorUnits, frequency, interval, startDate in
                viewModel.addHypotheticalEntry(groupName: newGroupName, categoryId: categoryId, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate)
                showNewEntrySheet = false
            }
        }
        .sheet(item: $editingEntry) { entry in
            EditForecastEntryView(entry: entry) { amountMinorUnits, frequency, interval in
                viewModel.updateEntry(entry, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval)
                editingEntry = nil
            }
        }
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

    private var netWorthHeadline: some View {
        HStack(spacing: 12) {
            netWorthStat(year: viewModel.thisYear, baselineLabel: "vs Dec \(viewModel.thisYear - 1)")
            netWorthStat(year: viewModel.nextYear, baselineLabel: "vs Dec \(viewModel.thisYear) forecast")
        }
    }

    private func netWorthStat(year: Int, baselineLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // String(year) first, not a bare Int interpolated straight into this literal:
            // interpolating a bare Int directly into Text("...") routes through
            // LocalizedStringKey's numeric-formatting overload, which applies locale
            // grouping — "Dec 2,026" instead of "Dec 2026". Converting to String first
            // sidesteps that overload.
            Text("Forecast net worth — Dec \(String(year))").font(.caption).foregroundStyle(.secondary)
            if let forecast = viewModel.forecastNetWorth(atEndOf: year) {
                MoneyText(minorUnits: forecast, font: .title2.bold())
            } else {
                Text("—").font(.title2.bold()).foregroundStyle(.secondary)
            }
            if let yoy = viewModel.forecastNetWorthYoY(atEndOf: year), let percent = yoy.percent {
                Text("\(percent >= 0 ? "↑" : "↓") \(String(format: "%.1f", abs(percent) * 100))% \(baselineLabel)")
                    .font(.caption2)
                    .foregroundStyle(percent >= 0 ? Color.green : Color.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var manageForecastSection: some View {
        DisclosureGroup("Manage forecast", isExpanded: $manageExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                ForEach(viewModel.groups) { group in
                    HStack {
                        Toggle(group.name, isOn: Binding(
                            get: { group.isEnabled },
                            set: { _ in viewModel.toggleGroup(group) }
                        ))
                        if !group.isSystemManaged {
                            Text("custom").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(viewModel.entries.filter { $0.groupId == group.id }) { entry in
                        HStack {
                            Toggle(viewModel.categories.first(where: { $0.id == entry.categoryId })?.name ?? "Unknown", isOn: Binding(
                                get: { entry.isEnabled },
                                set: { _ in viewModel.toggleEntry(entry) }
                            ))
                            .padding(.leading, 24)
                            Text(entry.status.rawValue).font(.caption).foregroundStyle(.secondary)
                            Button("Edit…") { editingEntry = entry }
                                .buttonStyle(.plain)
                                .font(.caption)
                            if entry.status == .hypothetical {
                                Button("Confirm") { viewModel.confirm(entry) }
                            } else if entry.status == .confirmed {
                                Button("Un-confirm") { viewModel.unconfirm(entry) }
                            }
                        }
                    }
                }
                Button("Add hypothetical forecast entry…") { showNewEntrySheet = true }
            }
            .padding(.top, 8)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
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
                    MoneyText(minorUnits: preview, font: .caption2.monospacedDigit(), alignment: .trailing, tint: .orange)
                        .opacity(0.7)
                } else {
                    Color.clear.frame(height: 14)
                }
            }
        }
        .frame(width: 120)
        .padding(.horizontal, 8)
    }

    // Same technique as BudgetGridView.monthYearLabel: build a real Date via DateComponents
    // and format it, rather than reading .monthSymbols off a locale-less Calendar (which
    // doesn't yield real month names in this runtime — rendered "M01", "M02", ... instead
    // of "January", "February", ...). The year is arbitrary (only the month matters here;
    // the year is already shown via the year picker above the grid, not per column).
    private static func monthLabel(_ month: Int) -> String {
        var components = DateComponents()
        components.year = 2000; components.month = month; components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { return "\(month)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// The forecast grid body's horizontal scroll offset — same technique as
/// `BudgetGridView`'s `HorizontalOffsetKey`, a separate type because SwiftUI
/// `PreferenceKey`s are matched by type, and this view has its own frozen header.
private struct ForecastHorizontalOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

struct NewForecastEntryView: View {
    let categories: [Category]
    let onSave: (String, Int64, Int, ForecastFrequency, Int, Date) -> Void

    @State private var groupName = "New scenario"
    @State private var categoryId: Int64?
    @State private var amountPounds = ""
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    @State private var startDate = Date()

    var body: some View {
        Form {
            TextField("Group name", text: $groupName)
            Picker("Category", selection: $categoryId) {
                Text("Select…").tag(Int64?.none)
                ForEach(categories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
            }
            TextField("Amount (£, positive number)", text: $amountPounds)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            DatePicker("Starting", selection: $startDate, displayedComponents: .date)
            Button("Save") {
                guard let categoryId, let pounds = Double(amountPounds) else { return }
                let category = categories.first { $0.id == categoryId }
                let signedMinorUnits = Int(pounds * 100) * (category?.type == .income ? 1 : -1)
                onSave(groupName, categoryId, signedMinorUnits, frequency, interval, startDate)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

struct EditForecastEntryView: View {
    let entry: ForecastEntry
    let onSave: (Int, ForecastFrequency, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var amountPounds: String
    @State private var frequency: ForecastFrequency
    @State private var interval: Int

    init(entry: ForecastEntry, onSave: @escaping (Int, ForecastFrequency, Int) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _amountPounds = State(initialValue: String(format: "%.2f", Double(abs(entry.amountMinorUnits)) / 100))
        _frequency = State(initialValue: entry.frequency)
        _interval = State(initialValue: entry.interval)
    }

    /// Preserves the entry's existing sign (income positive, everything else negative) —
    /// the field only ever asks for a positive magnitude. nil if the field doesn't parse.
    private var signedAmount: Int? {
        guard let minorUnits = Money.parseMinorUnits(amountPounds) else { return nil }
        return entry.amountMinorUnits < 0 ? -abs(minorUnits) : abs(minorUnits)
    }

    /// Save is a no-op unless something actually changed: saving an untouched `.auto`
    /// entry would otherwise promote it to `.manual` (via `updateEntry`) and permanently
    /// opt that category out of `AutoForecastGenerator.refresh` for no reason.
    private var hasChanges: Bool {
        guard let signedAmount else { return false }
        return signedAmount != entry.amountMinorUnits || frequency != entry.frequency || interval != entry.interval
    }

    var body: some View {
        Form {
            TextField("Amount (£)", text: $amountPounds)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard hasChanges, let signedAmount else { return }
                    onSave(signedAmount, frequency, interval)
                }
                .disabled(!hasChanges)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
