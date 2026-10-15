// App/Search/SearchFilterBar.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// The filters under the search field (spec 2026-10-15): Date, Amount, Accounts, Categories
/// and Flags, each a compact button opening a popover, then Reset when any is set.
struct SearchFilterBar: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        HStack(spacing: 8) {
            FilterButton(title: dateTitle, isActive: viewModel.criteria.date != .allTime) {
                DateFilterPopover(filter: $viewModel.criteria.date)
            }
            FilterButton(title: amountTitle, isActive: amountIsActive) {
                AmountFilterPopover(criteria: $viewModel.criteria)
            }
            FilterButton(title: accountsTitle, isActive: !viewModel.criteria.accountIds.isEmpty) {
                AccountsFilterPopover(accounts: viewModel.accounts, selection: $viewModel.criteria.accountIds)
            }
            FilterButton(title: categoriesTitle, isActive: viewModel.criteria.filtersCategories) {
                CategoriesFilterPopover(viewModel: viewModel)
            }
            FilterButton(title: flagsTitle, isActive: !viewModel.criteria.flags.isEmpty) {
                FlagsFilterPopover(flags: $viewModel.criteria.flags)
            }
            if viewModel.criteria != TransactionSearch.Criteria(text: viewModel.criteria.text) {
                Button("Reset filters") { viewModel.resetFilters() }
                    .buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    // MARK: Titles

    private var dateTitle: String {
        switch viewModel.criteria.date {
        case .allTime: return "All time"
        case .thisMonth: return "This month"
        case .thisYear: return "This year"
        case .last12Months: return "Last 12 months"
        case .custom(let from, let to):
            let first = min(from, to), last = max(from, to)
            return "\(SearchFormat.day(first)) – \(SearchFormat.day(last))"
        }
    }

    private var amountIsActive: Bool {
        let c = viewModel.criteria
        return c.minAmountMinorUnits != nil || c.maxAmountMinorUnits != nil || c.direction != .any
    }

    private var amountTitle: String {
        let c = viewModel.criteria
        var parts: [String] = []
        switch (c.minAmountMinorUnits, c.maxAmountMinorUnits) {
        case let (min?, max?): parts.append("\(Money.format(min, currency: .gbp))–\(Money.format(max, currency: .gbp))")
        case let (min?, nil): parts.append("≥ \(Money.format(min, currency: .gbp))")
        case let (nil, max?): parts.append("≤ \(Money.format(max, currency: .gbp))")
        case (nil, nil): break
        }
        switch c.direction {
        case .any: break
        case .moneyIn: parts.append("In")
        case .moneyOut: parts.append("Out")
        }
        return parts.isEmpty ? "Any amount" : parts.joined(separator: " · ")
    }

    private var accountsTitle: String {
        let ids = viewModel.criteria.accountIds
        if ids.isEmpty { return "All accounts" }
        if ids.count == 1, let account = viewModel.accounts.first(where: { $0.id == ids.first }) { return account.displayName }
        return "\(ids.count) accounts"
    }

    private var categoriesTitle: String {
        let c = viewModel.criteria
        let count = c.categoryIds.count + (c.includesUncategorised ? 1 : 0)
        if count == 0 { return "All categories" }
        if count == 1 {
            if c.includesUncategorised { return "Uncategorised" }
            if let category = viewModel.categories.first(where: { $0.id == c.categoryIds.first }) { return category.name }
        }
        return "\(count) categories"
    }

    private var flagsTitle: String {
        let flags = viewModel.criteria.flags
        if flags.isEmpty { return "Any flags" }
        if flags.count == 1, let flag = flags.first { return flag.title }
        return "\(flags.count) flags"
    }
}

/// A filter's button: its current value, accented while the filter is on; opens `content` in a popover.
private struct FilterButton<Content: View>: View {
    let title: String
    let isActive: Bool
    @ViewBuilder let content: Content
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content
                .padding(SheetMetrics.popoverPadding)
                .controlSize(.regular)
        }
    }
}

extension TransactionSearch.Flag {
    var title: String {
        switch self {
        case .unreviewed: return "Unreviewed"
        case .manual: return "Manual entries"
        case .linkedTransfer: return "Linked transfers"
        case .hasNote: return "Has note"
        }
    }
}

enum SearchFormat {
    /// "9 Mar 2026" for a stored (UTC) day.
    static func day(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC")!
        return date.formatted(style)
    }
}

// MARK: Popovers

private struct DateFilterPopover: View {
    @Binding var filter: TransactionSearch.DateFilter
    /// Local midnights, as the date pickers hold them.
    @State private var from: Date
    @State private var to: Date

    init(filter: Binding<TransactionSearch.DateFilter>) {
        _filter = filter
        let today = Calendar.current.startOfDay(for: Date())
        if case .custom(let from, let to) = filter.wrappedValue {
            _from = State(initialValue: PayCalendar.localDay(sameDayAs: min(from, to), in: .current))
            _to = State(initialValue: PayCalendar.localDay(sameDayAs: max(from, to), in: .current))
        } else {
            _from = State(initialValue: Calendar.current.date(byAdding: .month, value: -1, to: today) ?? today)
            _to = State(initialValue: today)
        }
    }

    private var isCustom: Bool {
        if case .custom = filter { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Date", selection: Binding(
                get: { isCustom ? nil : filter },
                set: { if let value = $0 { filter = value } else { applyCustom() } }
            )) {
                Text("This month").tag(TransactionSearch.DateFilter?.some(.thisMonth))
                Text("This year").tag(TransactionSearch.DateFilter?.some(.thisYear))
                Text("Last 12 months").tag(TransactionSearch.DateFilter?.some(.last12Months))
                Text("All time").tag(TransactionSearch.DateFilter?.some(.allTime))
                Text("Custom range").tag(TransactionSearch.DateFilter?.none)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("From").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    DatePicker("From", selection: $from, displayedComponents: .date).labelsHidden()
                }
                GridRow {
                    Text("To").foregroundStyle(.secondary)
                    DatePicker("To", selection: $to, displayedComponents: .date).labelsHidden()
                }
            }
            .disabled(!isCustom)
            .onChange(of: from) { _, _ in if isCustom { applyCustom() } }
            .onChange(of: to) { _, _ in if isCustom { applyCustom() } }
        }
        .frame(minWidth: 220, alignment: .leading)
    }

    private func applyCustom() {
        filter = .custom(from: PayCalendar.utcDay(sameDayAs: from, in: .current), to: PayCalendar.utcDay(sameDayAs: to, in: .current))
    }
}

private struct AmountFilterPopover: View {
    @Binding var criteria: TransactionSearch.Criteria
    @State private var minText: String
    @State private var maxText: String

    init(criteria: Binding<TransactionSearch.Criteria>) {
        _criteria = criteria
        _minText = State(initialValue: criteria.wrappedValue.minAmountMinorUnits.map(Money.formatInput) ?? "")
        _maxText = State(initialValue: criteria.wrappedValue.maxAmountMinorUnits.map(Money.formatInput) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("At least").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    MoneyField("Any", text: $minText, currency: .gbp, width: 110)
                }
                GridRow {
                    Text("At most").foregroundStyle(.secondary)
                    MoneyField("Any", text: $maxText, currency: .gbp, width: 110)
                }
            }
            Text("On the amount whatever its sign.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Direction", selection: $criteria.direction) {
                Text("Any").tag(TransactionSearch.Direction.any)
                Text("Money in").tag(TransactionSearch.Direction.moneyIn)
                Text("Money out").tag(TransactionSearch.Direction.moneyOut)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .frame(minWidth: 240, alignment: .leading)
        .onChange(of: minText) { _, text in criteria.minAmountMinorUnits = Self.bound(text, current: criteria.minAmountMinorUnits) }
        .onChange(of: maxText) { _, text in criteria.maxAmountMinorUnits = Self.bound(text, current: criteria.maxAmountMinorUnits) }
    }

    /// Empty clears the bound; an unparseable entry keeps the last one (the field shows it red).
    private static func bound(_ text: String, current: Int?) -> Int? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return Money.parseMinorUnits(text).map(abs) ?? current
    }
}

private struct AccountsFilterPopover: View {
    let accounts: [Account]
    @Binding var selection: Set<Int64>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("All accounts", isOn: Binding(get: { selection.isEmpty }, set: { if $0 { selection = [] } }))
                .toggleStyle(.checkbox)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(accounts) { account in
                        if let id = account.id {
                            Toggle(account.displayName, isOn: membership(id, in: $selection))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 220, alignment: .leading)
    }
}

private struct CategoriesFilterPopover: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var query = ""

    private var categories: [Category] { viewModel.filterCategories }

    private func matches(_ name: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || name.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        let selection = $viewModel.criteria.categoryIds
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter categories", text: $query)
                .textFieldStyle(.roundedBorder)
            HStack {
                Toggle("All categories", isOn: Binding(
                    get: { !viewModel.criteria.filtersCategories },
                    set: { if $0 { viewModel.criteria.categoryIds = []; viewModel.criteria.includesUncategorised = false } }
                ))
                .toggleStyle(.checkbox)
                Spacer()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if matches("Uncategorised") {
                        Toggle("Uncategorised", isOn: $viewModel.criteria.includesUncategorised)
                            .toggleStyle(.checkbox)
                    }
                    ForEach(viewModel.filterGroups) { group in
                        let members = categories.filter { $0.groupId == group.id }
                        let shown = matches(group.name) ? members : members.filter { matches($0.name) }
                        if !shown.isEmpty {
                            let memberIds = viewModel.memberIds(ofGroup: group)
                            Toggle(isOn: Binding(
                                get: { !memberIds.isEmpty && memberIds.isSubset(of: selection.wrappedValue) },
                                set: { on in
                                    if on { selection.wrappedValue.formUnion(memberIds) } else { selection.wrappedValue.subtract(memberIds) }
                                }
                            )) {
                                Text(group.name).fontWeight(.semibold)
                            }
                            .toggleStyle(.checkbox)
                            ForEach(shown) { category in
                                categoryToggle(category, selection: selection).padding(.leading, 20)
                            }
                        }
                    }
                    ForEach(categories.filter { $0.groupId == nil && matches($0.name) }) { category in
                        categoryToggle(category, selection: selection)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 260, alignment: .leading)
    }

    @ViewBuilder
    private func categoryToggle(_ category: Category, selection: Binding<Set<Int64>>) -> some View {
        if let id = category.id {
            Toggle(isOn: membership(id, in: selection)) {
                HStack(spacing: 4) {
                    CategoryBadge(category: category, size: .small)
                    Text(category.name).lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
        }
    }
}

private struct FlagsFilterPopover: View {
    @Binding var flags: Set<TransactionSearch.Flag>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(TransactionSearch.Flag.allCases, id: \.self) { flag in
                Toggle(flag.title, isOn: membership(flag, in: $flags))
                    .toggleStyle(.checkbox)
            }
            Text("Shows transactions with every flag ticked.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 200, alignment: .leading)
    }
}

/// A checkbox's binding for whether `element` is in `set`.
private func membership<T: Hashable>(_ element: T, in set: Binding<Set<T>>) -> Binding<Bool> {
    Binding(
        get: { set.wrappedValue.contains(element) },
        set: { on in
            if on { set.wrappedValue.insert(element) } else { set.wrappedValue.remove(element) }
        }
    )
}
