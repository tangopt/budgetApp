// App/Forecast/ForecastView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct ForecastView: View {
    @ObservedObject var viewModel: ForecastViewModel
    @State private var selectedYear: Int
    @State private var horizontalOffset: CGFloat = 0
    @State private var expandedGroupIds: Set<Int64> = []
    @State private var showNewScenarioSheet = false
    @State private var addingItemTo: ForecastGroup?
    @State private var editingEntry: ForecastEntry?
    @State private var isConfirmingScenario = false
    @State private var reserveSheet: ReserveSheet?
    @State private var renamingReserve: Category?
    @State private var deletingReserve: Category?

    private enum ReserveSheet: Identifiable {
        case newReserve
        case addAmount(Category)
        var id: String {
            switch self {
            case .newReserve: return "new-reserve"
            case .addAmount(let reserve): return "add-amount-\(reserve.id ?? -1)"
            }
        }
    }

    // A plain memberwise init would make `selectedYear` a required call-site argument;
    // this way callers just pass `viewModel`, and the initial year comes from it.
    init(viewModel: ForecastViewModel) {
        self.viewModel = viewModel
        _selectedYear = State(initialValue: viewModel.thisYear)
    }

    /// Clears a stale save error as the user edits a reserve form — only when one is set,
    /// so typing doesn't republish the view model (and redraw the grid) on every keystroke.
    private func clearErrorMessage() {
        if viewModel.errorMessage != nil { viewModel.errorMessage = nil }
    }

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type && !$0.isReserved }
    }

    private enum ForecastRowKind: Identifiable {
        case sectionHeader(String, CategoryType)
        case category(Category)
        case groupHeader(CategoryGroup, categories: [Category])
        case groupChild(Category)
        case reservedHeader
        case reserve(Category)
        case reservedTotal
        var id: String {
            switch self {
            case .sectionHeader(let title, _): return "header-\(title)"
            case .category(let category): return "cat-\(category.id ?? -1)"
            case .groupHeader(let group, let categories): return "group-\(group.id ?? -1)-\(categories.first?.type.rawValue ?? "")"
            case .groupChild(let category): return "groupchild-\(category.id ?? -1)"
            case .reservedHeader: return "reserved-header"
            case .reserve(let reserve): return "reserve-\(reserve.id ?? -1)"
            case .reservedTotal: return "reserved-total"
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

    /// Categories sharing a `groupId` collapse into one `.groupHeader` row (first-seen
    /// order wins for where the group appears), expanding to a `.groupChild` row per
    /// member only when its id is in `expandedGroupIds`. Ungrouped categories render
    /// exactly as `.category`, interleaved in the section's existing order. Identical
    /// logic to `BudgetGridView.rowKinds(for:)`.
    private func rowKinds(for type: CategoryType) -> [ForecastRowKind] {
        let cats = categoriesByType(type)
        var rows: [ForecastRowKind] = []
        var seenGroupIds: Set<Int64> = []
        for category in cats {
            if let groupId = category.groupId {
                guard !seenGroupIds.contains(groupId) else { continue }
                seenGroupIds.insert(groupId)
                guard let group = viewModel.categoryGroups.first(where: { $0.id == groupId }) else { continue }
                let members = cats.filter { $0.groupId == groupId }
                rows.append(.groupHeader(group, categories: members))
                if expandedGroupIds.contains(groupId) {
                    rows += members.map { .groupChild($0) }
                }
            } else {
                rows.append(.category(category))
            }
        }
        return rows
    }

    private var allRows: [ForecastRow] {
        func section(_ title: String, _ type: CategoryType) -> [ForecastRow] {
            var rows: [ForecastRow] = [ForecastRow(kind: .sectionHeader(title, type), shaded: false)]
            for (index, kind) in rowKinds(for: type).enumerated() {
                rows.append(ForecastRow(kind: kind, shaded: index % 2 == 1))
            }
            return rows
        }
        var reservedRows: [ForecastRow] = [ForecastRow(kind: .reservedHeader, shaded: false)]
        for (index, reserve) in viewModel.reserves.enumerated() {
            reservedRows.append(ForecastRow(kind: .reserve(reserve), shaded: index % 2 == 1))
        }
        if !viewModel.reserves.isEmpty { reservedRows.append(ForecastRow(kind: .reservedTotal, shaded: false)) }
        return section("Income", .income) + section("Expenses", .expense) + reservedRows + section("Transfers", .transfer)
    }

    /// A category renders as a two-line row (confirmed + preview) when any month in the
    /// selected year has a preview total that differs from confirmed.
    private func isTwoLine(_ category: Category, year: Int) -> Bool {
        (1...12).contains { month in
            viewModel.categoryTotal(category, year: year, month: month) != viewModel.previewCategoryTotal(category, year: year, month: month)
        }
    }

    private func isTwoLineGroup(_ categories: [Category], year: Int) -> Bool {
        categories.contains { isTwoLine($0, year: year) }
    }

    /// True when `group` has at least one entry and *every* one of its entries has been
    /// promoted to `.confirmed` — not just "any entry confirmed". Old-UI data (or a
    /// partially-confirmed scenario from a future partial-confirm flow) can leave a group
    /// with a mix of `.confirmed` and still-`.hypothetical` entries; treating that as
    /// "confirmed" would permanently hide the Add/Confirm controls for entries that are
    /// still only previewed. Shared by `scenarioPicker` and `selectedScenarioSection` so
    /// the definition only lives in one place.
    private func isScenarioConfirmed(_ group: ForecastGroup) -> Bool {
        let groupEntries = viewModel.entries.filter { $0.groupId == group.id }
        return !groupEntries.isEmpty && !groupEntries.contains { $0.status == .hypothetical }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
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
                                    let range = viewModel.payCalendar.range(of: PayMonth(year: selectedYear, month: month))
                                    Text(Self.monthLabel(month))
                                        .frame(width: 120, alignment: .trailing)
                                        .padding(.horizontal, 8).padding(.vertical, 6)
                                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                                        .help("\(Self.dayLabel(range.start)) – \(Self.dayLabel(range.end))")
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
                        // ScrollView sizes to its ideal (unbounded) content height and
                        // competes for space inside the left column's own outer
                        // `ScrollView` (netWorthHeadline, yearPicker, and the frozen grid
                        // header all sit above it in that same outer scroll), which would
                        // otherwise make the whole page scroll instead of just the grid
                        // body. 480 shows a comfortable number of rows (~15-17 single-line,
                        // ~10-11 two-line) before this inner view needs its own scroll.
                        .frame(height: 480)
                        .onPreferenceChange(ForecastHorizontalOffsetKey.self) { horizontalOffset = $0 }
                    }
                }
                .padding()
            }
            Divider()
            scenarioPanel
                .frame(width: 280)
        }
        .sheet(isPresented: $showNewScenarioSheet) {
            ScenarioItemFormView(mode: .newScenario, viewModel: viewModel) { name, item in
                viewModel.createScenario(name: name ?? "New scenario", items: [item])
                showNewScenarioSheet = false
            }
        }
        .sheet(item: $addingItemTo) { group in
            ScenarioItemFormView(mode: .addItem(to: group), viewModel: viewModel) { _, item in
                viewModel.addItem(to: group, item)
                addingItemTo = nil
            }
        }
        .sheet(item: $editingEntry) { entry in
            EditForecastEntryView(entry: entry) { amountMinorUnits, frequency, interval, startDate, endDate in
                viewModel.updateEntry(entry, amountMinorUnits: amountMinorUnits, frequency: frequency, interval: interval, startDate: startDate, endDate: endDate)
                editingEntry = nil
            }
        }
        // Failed saves keep the sheet open and show `errorMessage` inside it; whatever
        // error is left over when the sheet closes is cleared so it doesn't linger.
        .sheet(item: $reserveSheet, onDismiss: { viewModel.errorMessage = nil }) { sheet in
            switch sheet {
            case .newReserve:
                ReserveFormView(mode: .newReserve, errorMessage: viewModel.errorMessage, onEdit: clearErrorMessage) { name, amount, frequency, interval, start, end in
                    if viewModel.addReserve(name: name, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end) {
                        reserveSheet = nil
                    }
                }
            case .addAmount(let reserve):
                ReserveFormView(mode: .addAmount(reserve), errorMessage: viewModel.errorMessage, onEdit: clearErrorMessage) { _, amount, frequency, interval, start, end in
                    if viewModel.addReserveAmount(to: reserve, amountMinorUnits: amount, frequency: frequency, interval: interval, startDate: start, endDate: end) {
                        reserveSheet = nil
                    }
                }
            }
        }
        .sheet(item: $renamingReserve, onDismiss: { viewModel.errorMessage = nil }) { reserve in
            RenameReserveView(reserve: reserve, errorMessage: viewModel.errorMessage, onEdit: clearErrorMessage) { name in
                if viewModel.renameReserve(reserve, to: name) {
                    renamingReserve = nil
                }
            }
        }
        .confirmationDialog("Delete “\(deletingReserve?.name ?? "")”? Its allowances are removed from the forecast.", isPresented: Binding(
            get: { deletingReserve != nil },
            set: { if !$0 { deletingReserve = nil } }
        ), titleVisibility: .visible) {
            Button("Delete reserve", role: .destructive) {
                if let reserve = deletingReserve { viewModel.deleteReserve(reserve) }
                deletingReserve = nil
            }
            Button("Cancel", role: .cancel) { deletingReserve = nil }
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

    private var scenarioPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                scenarioPicker
                if let selectedGroup = viewModel.groups.first(where: { $0.id == viewModel.selectedScenarioGroupId }) {
                    selectedScenarioSection(selectedGroup)
                }
                detectedRecurringSection
            }
            .padding()
        }
    }

    private var scenarioPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scenario").font(.caption).foregroundStyle(.secondary)
            scenarioRow(name: "None (confirmed only)", isSelected: viewModel.selectedScenarioGroupId == nil, badge: nil) {
                viewModel.selectedScenarioGroupId = nil
            }
            ForEach(viewModel.scenarioGroups) { group in
                let isConfirmed = isScenarioConfirmed(group)
                scenarioRow(name: group.name, isSelected: viewModel.selectedScenarioGroupId == group.id, badge: isConfirmed ? "confirmed" : nil) {
                    // A confirmed scenario is still selectable — purely for viewing/editing
                    // its items. `selectedScenarioSection` already hides the Add/Confirm/
                    // impact UI when `isScenarioConfirmed` is true, and a fully-confirmed
                    // group has no hypothetical entries left, so `previewCategoryTotal`
                    // equals `categoryTotal` and no amber preview line appears.
                    viewModel.selectedScenarioGroupId = group.id
                }
            }
            Button("+ New scenario…") { showNewScenarioSheet = true }
                .buttonStyle(.plain).font(.caption).padding(.top, 4)
        }
    }

    private func scenarioRow(name: String, isSelected: Bool, badge: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(name).font(.callout)
                Spacer()
                if let badge {
                    Text(badge).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func selectedScenarioSection(_ group: ForecastGroup) -> some View {
        let isConfirmed = isScenarioConfirmed(group)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(group.name) — items").font(.caption).foregroundStyle(.secondary)
            ForEach(viewModel.entries.filter { $0.groupId == group.id }) { entry in
                scenarioItemRow(entry)
            }
            if !isConfirmed {
                Button("+ Add item…") { addingItemTo = group }
                    .buttonStyle(.plain).font(.caption)
                Button("Confirm scenario") { isConfirmingScenario = true }
                    .font(.caption)
                    .confirmationDialog("Confirm this scenario?", isPresented: $isConfirmingScenario) {
                        Button("Confirm") { viewModel.confirmScenario(group) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Its items will be added to your permanent forecast.")
                    }
                if let impact = viewModel.scenarioNetWorthImpact(atEndOf: selectedYear), impact != 0 {
                    HStack(spacing: 4) {
                        Text("With this scenario:").font(.caption).foregroundStyle(.secondary)
                        MoneyText(minorUnits: impact, font: .caption.bold(), tint: .orange)
                        Text("by Dec \(String(selectedYear))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                // Reachable now that `scenarioPicker` allows re-selecting a confirmed
                // scenario. Bulk un-confirms every entry in the group — the mirror image
                // of `confirmScenario`'s bulk confirm — by looping `unconfirm` (which only
                // ever operates on one entry) across the group's entries.
                Button("Un-confirm scenario") {
                    for entry in viewModel.entries where entry.groupId == group.id {
                        viewModel.unconfirm(entry)
                    }
                }
                .buttonStyle(.plain).font(.caption)
            }
        }
    }

    private func scenarioItemRow(_ entry: ForecastEntry) -> some View {
        HStack {
            Text(viewModel.categories.first(where: { $0.id == entry.categoryId })?.name ?? "Unknown").font(.caption)
            Spacer()
            MoneyText(minorUnits: entry.amountMinorUnits, font: .caption)
            Text(Self.frequencyLabel(entry)).font(.caption2).foregroundStyle(.secondary)
            if let endDate = entry.endDate {
                Text("ends \(Self.monthYearLabel(endDate))").font(.caption2).foregroundStyle(.secondary)
            }
            Button("Edit…") { editingEntry = entry }
                .buttonStyle(.plain).font(.caption)
        }
    }

    private var detectedRecurringSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let detectedRecurring = viewModel.groups.first(where: { $0.isSystemManaged }) {
                Toggle(detectedRecurring.name, isOn: Binding(
                    get: { detectedRecurring.isEnabled },
                    set: { _ in viewModel.toggleGroup(detectedRecurring) }
                )).font(.caption)
                ForEach(viewModel.entries.filter { $0.groupId == detectedRecurring.id }) { entry in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { entry.isEnabled },
                            set: { _ in viewModel.toggleEntry(entry) }
                        ))
                        .labelsHidden()
                        Text(viewModel.categories.first(where: { $0.id == entry.categoryId })?.name ?? "Unknown").font(.caption)
                        Text(entry.status.rawValue).font(.caption2).foregroundStyle(.secondary)
                        if let endDate = entry.endDate {
                            Text("ends \(Self.monthYearLabel(endDate))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editingEntry = entry }
                            .buttonStyle(.plain).font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowLabel(_ row: ForecastRowKind, shaded: Bool) -> some View {
        switch row {
        case .sectionHeader(let title, _):
            // Planned items are added from the Budget grid's section headers.
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
        case .groupHeader(let group, let categories):
            let twoLine = isTwoLineGroup(categories, year: selectedYear)
            Button {
                if let id = group.id {
                    if expandedGroupIds.contains(id) { expandedGroupIds.remove(id) } else { expandedGroupIds.insert(id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: (group.id.map { expandedGroupIds.contains($0) } ?? false) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(group.name).bold()
                }
            }
            .buttonStyle(.plain)
            .frame(width: 220, height: twoLine ? 44 : 28, alignment: .leading)
            .padding(.horizontal, 8)
            .background(Color.orange.opacity(0.10))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            .overlay(Rectangle().frame(width: 3).foregroundStyle(categories.first.map { rowColor(for: $0.type) } ?? .clear), alignment: .leading)
        case .groupChild(let category):
            let twoLine = isTwoLine(category, year: selectedYear)
            Text(category.name).foregroundStyle(.secondary)
                .frame(width: 200, height: twoLine ? 44 : 28, alignment: .leading)
                .padding(.leading, 28).padding(.trailing, 8)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(rowColor(for: category.type)), alignment: .leading)
        case .reservedHeader:
            HStack {
                Text("RESERVED")
                    .font(.caption).bold()
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { reserveSheet = .newReserve } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add reserve…")
            }
            .frame(width: 220, height: 24, alignment: .leading)
            .padding(.horizontal, 8)
            .background(Color.accentColor.opacity(0.08))
        case .reserve(let reserve):
            let twoLine = isTwoLine(reserve, year: selectedYear)
            Text(reserve.name)
                .frame(width: 220, height: twoLine ? 44 : 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(shaded ? Color.primary.opacity(0.07) : Color.clear)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(.purple), alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    ForEach(viewModel.reserveEntries(reserve)) { entry in
                        Button("Edit \(Self.frequencyLabel(entry)) allowance…") { editingEntry = entry }
                    }
                    Button("Add amount…") { reserveSheet = .addAmount(reserve) }
                    Button("Rename…") { renamingReserve = reserve }
                    Divider()
                    Button("Delete reserve…", role: .destructive) { deletingReserve = reserve }
                }
        case .reservedTotal:
            let twoLine = viewModel.reserves.contains { isTwoLine($0, year: selectedYear) }
            Text("Total reserved").bold()
                .frame(width: 220, height: twoLine ? 44 : 28, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.purple.opacity(0.08))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                .overlay(Rectangle().frame(width: 3).foregroundStyle(.purple), alignment: .leading)
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
            categoryCells(category, shaded: shaded)
        case .groupHeader(_, let categories):
            let year = selectedYear
            let twoLine = isTwoLineGroup(categories, year: year)
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    let confirmed = categories.reduce(0) { $0 + viewModel.categoryTotal($1, year: year, month: month) }
                    let preview = categories.reduce(0) { $0 + viewModel.previewCategoryTotal($1, year: year, month: month) }
                    forecastCell(confirmed: confirmed, preview: preview, twoLine: twoLine, bold: true)
                        .frame(height: twoLine ? 44 : 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                }
                let confirmedYearTotal = (1...12).reduce(0) { sum, month in sum + categories.reduce(0) { $0 + viewModel.categoryTotal($1, year: year, month: month) } }
                let previewYearTotal = (1...12).reduce(0) { sum, month in sum + categories.reduce(0) { $0 + viewModel.previewCategoryTotal($1, year: year, month: month) } }
                forecastCell(confirmed: confirmedYearTotal, preview: previewYearTotal, twoLine: twoLine, bold: true)
                    .frame(height: twoLine ? 44 : 28)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            }
            .background(Color.orange.opacity(0.10))
        case .groupChild(let category):
            categoryCells(category, shaded: shaded)
        case .reservedHeader:
            HStack(spacing: 0) {
                ForEach(1...(12 + 1), id: \.self) { _ in
                    Color.clear.frame(width: 120, height: 24).padding(.horizontal, 8)
                }
            }
            .background(Color.accentColor.opacity(0.08))
        case .reserve(let reserve):
            // `categoryTotal`/`previewCategoryTotal` already apply the reserve month rule.
            categoryCells(reserve, shaded: shaded)
        case .reservedTotal:
            let year = selectedYear
            let twoLine = viewModel.reserves.contains { isTwoLine($0, year: year) }
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    forecastCell(confirmed: viewModel.reserveTotal(year: year, month: month, preview: false), preview: viewModel.reserveTotal(year: year, month: month, preview: true), twoLine: twoLine, bold: true)
                        .frame(height: twoLine ? 44 : 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                }
                let confirmedYearTotal = (1...12).reduce(0) { $0 + viewModel.reserveTotal(year: year, month: $1, preview: false) }
                let previewYearTotal = (1...12).reduce(0) { $0 + viewModel.reserveTotal(year: year, month: $1, preview: true) }
                forecastCell(confirmed: confirmedYearTotal, preview: previewYearTotal, twoLine: twoLine, bold: true)
                    .frame(height: twoLine ? 44 : 28)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            }
            .background(Color.purple.opacity(0.08))
        }
    }

    /// One category's twelve month cells plus its year total — shared by `.category`,
    /// `.groupChild` and `.reserve` rows.
    private func categoryCells(_ category: Category, shaded: Bool) -> some View {
        let year = selectedYear
        let twoLine = isTwoLine(category, year: year)
        return HStack(spacing: 0) {
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()

    /// "16 Sep" — a pay month boundary day for the column header tooltip.
    private static func dayLabel(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static func monthYearLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// A short human label for a scenario item's frequency, e.g. "one-off", "monthly",
    /// or "every 3 months" — lets a one-off and a recurring item of the same amount be
    /// told apart at a glance in `scenarioItemRow`.
    private static func frequencyLabel(_ entry: ForecastEntry) -> String {
        switch entry.frequency {
        case .once: return "one-off"
        case .weekly: return entry.interval == 1 ? "weekly" : "every \(entry.interval) weeks"
        case .monthly: return entry.interval == 1 ? "monthly" : "every \(entry.interval) months"
        case .annually: return entry.interval == 1 ? "annually" : "every \(entry.interval) years"
        }
    }

    /// Normalizes a `Date` picked from a date-only `DatePicker` to 23:59:59 UTC on the
    /// calendar day the user actually picked, discarding whatever time-of-day the picker's
    /// initial value happened to carry (today's current time for a fresh `endDate`, or an
    /// existing entry's stored `endDate` time). Without this, a date picked near a DST
    /// boundary can carry a time-of-day that lands on the wrong side of an occurrence's own
    /// timestamp when `FrequencyExpander` compares them, silently including or excluding
    /// the final occurrence. `fileprivate` (not `private`) so `ScenarioItemFormView` and
    /// `EditForecastEntryView` — both declared later in this file — can call it too.
    fileprivate static func normalizedEndOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        var endComponents = components
        endComponents.hour = 23
        endComponents.minute = 59
        endComponents.second = 59
        return calendar.date(from: endComponents)!
    }

    /// The start-date counterpart to `normalizedEndOfDay`: every occurrence
    /// `FrequencyExpander` generates is computed by adding steps to `entry.startDate`
    /// itself, so its time-of-day carries through to every future occurrence, and
    /// `FrequencyExpander` compares those timestamps directly against period bounds — the
    /// same class of DST/time-of-day bug `normalizedEndOfDay` fixes for end dates. Picking a
    /// date-only `DatePicker` value should always mean "the whole calendar day," so this
    /// normalizes to 00:00:00 UTC on the picked day.
    fileprivate static func normalizedStartOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: components)!
    }
}

/// The forecast grid body's horizontal scroll offset — same technique as
/// `BudgetGridView`'s `HorizontalOffsetKey`, a separate type because SwiftUI
/// `PreferenceKey`s are matched by type, and this view has its own frozen header.
private struct ForecastHorizontalOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

struct ScenarioItemFormView: View {
    enum Mode {
        case newScenario
        case addItem(to: ForecastGroup)
    }
    let mode: Mode
    @ObservedObject var viewModel: ForecastViewModel
    let onSave: (String?, ForecastViewModel.ScenarioItem) -> Void // scenario name only non-nil for .newScenario
    @Environment(\.dismiss) private var dismiss

    /// Sentinel `categoryId` value meaning "+ New category…" is selected — real category
    /// ids are GRDB auto-increment rowids, always positive, so this never collides with one.
    private static let newCategorySentinel: Int64 = -1

    @State private var scenarioName = "New scenario"
    @State private var categoryId: Int64?
    @State private var newCategoryName = ""
    @State private var newCategoryType: CategoryType = .expense
    @State private var amountPounds = ""
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()

    private var isCreatingNewCategory: Bool { categoryId == Self.newCategorySentinel }

    /// Every non-reserved category, with reserves in their own section.
    private var pickerCategories: [Category] {
        viewModel.categories.filter { !$0.isReserved }
    }

    var body: some View {
        Form {
            if case .newScenario = mode {
                TextField("Scenario name", text: $scenarioName)
            }
            Picker("Category", selection: $categoryId) {
                Text("Select…").tag(Int64?.none)
                ForEach(pickerCategories) { category in Text(category.name).tag(Int64?.some(category.id!)) }
                if !viewModel.reserves.isEmpty {
                    Section("Reserved") {
                        ForEach(viewModel.reserves) { reserve in Text(reserve.name).tag(Int64?.some(reserve.id!)) }
                    }
                }
                Text("+ New category…").tag(Int64?.some(Self.newCategorySentinel))
            }
            if isCreatingNewCategory {
                // A scenario item can be for a category that doesn't exist yet (e.g. a
                // hypothetical new income source or a one-off project). Created together
                // with the item itself on Save, not immediately — so Cancel here leaves no
                // orphaned category behind.
                TextField("New category name", text: $newCategoryName)
                Picker("New category type", selection: $newCategoryType) {
                    Text("Expense").tag(CategoryType.expense)
                    Text("Income").tag(CategoryType.income)
                }
                .pickerStyle(.segmented)
            }
            MoneyField("Amount", text: $amountPounds, currency: .gbp)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            DatePicker("Starting", selection: $startDate, displayedComponents: .date)
            Toggle("Ends on a specific date", isOn: $hasEndDate)
            if hasEndDate {
                DatePicker("Ends", selection: $endDate, displayedComponents: .date)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard let minorUnits = Money.parseMinorUnits(amountPounds) else { return }
                    let resolvedCategoryId: Int64
                    let resolvedCategoryType: CategoryType
                    if isCreatingNewCategory {
                        let trimmedName = newCategoryName.trimmingCharacters(in: .whitespaces)
                        guard !trimmedName.isEmpty, let created = viewModel.createCategory(name: trimmedName, type: newCategoryType) else { return }
                        resolvedCategoryId = created.id!
                        resolvedCategoryType = created.type
                    } else {
                        guard let categoryId, let category = viewModel.categories.first(where: { $0.id == categoryId }) else { return }
                        resolvedCategoryId = categoryId
                        resolvedCategoryType = category.type
                    }
                    let signedMinorUnits = resolvedCategoryType == .income ? abs(minorUnits) : -abs(minorUnits)
                    let item = ForecastViewModel.ScenarioItem(categoryId: resolvedCategoryId, amountMinorUnits: signedMinorUnits, frequency: frequency, interval: interval, startDate: ForecastView.normalizedStartOfDay(startDate), endDate: hasEndDate ? ForecastView.normalizedEndOfDay(endDate) : nil)
                    let name: String? = { if case .newScenario = mode { return scenarioName }; return nil }()
                    onSave(name, item)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

struct EditForecastEntryView: View {
    let entry: ForecastEntry
    let onSave: (Int, ForecastFrequency, Int, Date, Date?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var amountPounds: String
    @State private var frequency: ForecastFrequency
    @State private var interval: Int
    @State private var startDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date

    init(entry: ForecastEntry, onSave: @escaping (Int, ForecastFrequency, Int, Date, Date?) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _amountPounds = State(initialValue: Money.formatInput(abs(entry.amountMinorUnits)))
        _frequency = State(initialValue: entry.frequency)
        _interval = State(initialValue: entry.interval)
        _startDate = State(initialValue: entry.startDate)
        _hasEndDate = State(initialValue: entry.endDate != nil)
        _endDate = State(initialValue: entry.endDate ?? Date())
    }

    /// Preserves the entry's existing sign (income positive, everything else negative) —
    /// the field only ever asks for a positive magnitude. nil if the field doesn't parse.
    private var signedAmount: Int? {
        guard let minorUnits = Money.parseMinorUnits(amountPounds) else { return nil }
        return entry.amountMinorUnits < 0 ? -abs(minorUnits) : abs(minorUnits)
    }

    /// Normalized to 23:59:59 UTC on the picked calendar day (see
    /// `ForecastView.normalizedEndOfDay`) rather than the raw `DatePicker` value, both so
    /// the saved date can't silently drop or include an occurrence near a DST boundary and
    /// so `hasChanges`'s comparison against `entry.endDate` below doesn't spuriously flip
    /// just from toggling the picker without actually changing the day.
    private var resolvedStartDate: Date { ForecastView.normalizedStartOfDay(startDate) }
    private var resolvedEndDate: Date? { hasEndDate ? ForecastView.normalizedEndOfDay(endDate) : nil }

    /// Save is a no-op unless something actually changed: saving an untouched `.auto`
    /// entry would otherwise promote it to `.manual` (via `updateEntry`) and permanently
    /// opt that category out of `AutoForecastGenerator.refresh` for no reason.
    private var hasChanges: Bool {
        guard let signedAmount else { return false }
        return signedAmount != entry.amountMinorUnits || frequency != entry.frequency || interval != entry.interval || resolvedStartDate != entry.startDate || resolvedEndDate != entry.endDate
    }

    var body: some View {
        Form {
            MoneyField("Amount", text: $amountPounds, currency: .gbp)
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            DatePicker("Starting", selection: $startDate, displayedComponents: .date)
            Toggle("Ends on a specific date", isOn: $hasEndDate)
            if hasEndDate {
                DatePicker("Ends", selection: $endDate, displayedComponents: .date)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard hasChanges, let signedAmount else { return }
                    onSave(signedAmount, frequency, interval, resolvedStartDate, resolvedEndDate)
                }
                .disabled(!hasChanges)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

/// Creates a reserve with its first allowance, or adds another allowance to an existing
/// one. Modelled on `ScenarioItemFormView`, minus the category picker.
struct ReserveFormView: View {
    enum Mode { case newReserve; case addAmount(Category) }
    let mode: Mode
    /// The view model's error from the last failed save, shown inline above the buttons.
    let errorMessage: String?
    /// Called when the user edits the name or amount, to clear a stale `errorMessage`.
    let onEdit: () -> Void
    let onSave: (_ name: String, _ amountMinorUnits: Int, ForecastFrequency, Int, Date, Date?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var amountPounds = ""
    @State private var frequency: ForecastFrequency = .monthly
    @State private var interval = 1
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()

    private var parsedAmount: Int? {
        guard let minorUnits = Money.parseMinorUnits(amountPounds), minorUnits != 0 else { return nil }
        return minorUnits
    }

    /// Save needs a non-zero amount and, for a new reserve, a non-blank name.
    private var canSave: Bool {
        guard parsedAmount != nil else { return false }
        if case .newReserve = mode { return !name.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    var body: some View {
        Form {
            switch mode {
            case .newReserve:
                TextField("Reserve name", text: $name)
                    .onChange(of: name) { _, _ in onEdit() }
                Text("A forecast-only allowance for spending you expect but don't plan line by line. It never holds transactions.")
                    .font(.caption).foregroundStyle(.secondary)
            case .addAmount(let reserve):
                Text("Add an amount to \(reserve.name)").font(.headline)
            }
            MoneyField("Amount", text: $amountPounds, currency: .gbp)
                .onChange(of: amountPounds) { _, _ in onEdit() }
            Picker("Frequency", selection: $frequency) {
                ForEach(ForecastFrequency.allCases, id: \.self) { freq in Text(freq.rawValue).tag(freq) }
            }
            Stepper("Every \(interval) \(frequency.rawValue)", value: $interval, in: 1...12)
            DatePicker("Starting", selection: $startDate, displayedComponents: .date)
            Toggle("Ends on a specific date", isOn: $hasEndDate)
            if hasEndDate { DatePicker("Ends", selection: $endDate, displayedComponents: .date) }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard canSave, let minorUnits = parsedAmount else { return }
                    onSave(name, -abs(minorUnits), frequency, interval, ForecastView.normalizedStartOfDay(startDate), hasEndDate ? ForecastView.normalizedEndOfDay(endDate) : nil)
                }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

/// Renames a reserve. A sheet rather than an alert so a failed rename (duplicate or
/// blank name) can stay open with the typed name kept and the error shown inline.
struct RenameReserveView: View {
    let reserve: Category
    let errorMessage: String?
    let onEdit: () -> Void
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    init(reserve: Category, errorMessage: String?, onEdit: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.reserve = reserve
        self.errorMessage = errorMessage
        self.onEdit = onEdit
        self.onSave = onSave
        _name = State(initialValue: reserve.name)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            Text("Rename reserve").font(.headline)
            TextField("Name", text: $name)
                .onChange(of: name) { _, _ in onEdit() }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard canSave else { return }
                    onSave(name)
                }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
