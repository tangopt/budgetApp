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

/// The Budget grid body's horizontal scroll offset (content minX in the scroll view's
/// coordinate space: 0 at rest, negative once scrolled right).
private struct HorizontalOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    // Sum, don't overwrite: SwiftUI also reduces in the default (0) from sibling subtrees
    // that never set this key, and `value = nextValue()` let that 0 clobber the real
    // offset after scrolling (header stuck). Only one view sets it, so the sum is exact.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

struct BudgetGridView: View {
    @ObservedObject var viewModel: BudgetGridViewModel
    @State private var showExporter = false
    /// Built only when "Export CSV…" is pressed. The export scans every
    /// category × period × transaction, and `body` re-runs on every horizontal scroll
    /// frame (via `horizontalOffset`), so it must not be computed in `body`.
    @State private var exportDocument: CSVDocument?
    @State private var drillDownTarget: GridDrillDownTarget?
    @State private var horizontalOffset: CGFloat = 0
    @State private var expandedGroupIds: Set<Int64> = []

    private func categoriesByType(_ type: CategoryType) -> [Category] {
        viewModel.categories.filter { $0.type == type }
    }

    private enum GridRowKind: Identifiable {
        case sectionHeader(String)
        case category(Category)
        case groupHeader(CategoryGroup, categories: [Category])
        case groupChild(Category)

        var id: String {
            switch self {
            case .sectionHeader(let title): return "header-\(title)"
            case .category(let category): return "cat-\(category.id ?? -1)"
            case .groupHeader(let group, let categories): return "group-\(group.id ?? -1)-\(categories.first?.type.rawValue ?? "")"
            case .groupChild(let category): return "groupchild-\(category.id ?? -1)"
            }
        }
    }

    /// Categories sharing a `groupId` collapse into one `.groupHeader` row (first-seen
    /// order wins for where the group appears), expanding to a `.groupChild` row per
    /// member only when its id is in `expandedGroupIds`. Ungrouped categories render
    /// exactly as `.category`, interleaved in the section's existing order.
    private func rowKinds(for type: CategoryType) -> [GridRowKind] {
        let cats = categoriesByType(type)
        var rows: [GridRowKind] = []
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

    private var allRowKinds: [GridRowKind] {
        var rows: [GridRowKind] = []
        rows.append(.sectionHeader("Income"))
        rows += rowKinds(for: .income)
        rows.append(.sectionHeader("Expenses"))
        rows += rowKinds(for: .expense)
        rows.append(.sectionHeader("Transfers"))
        rows += rowKinds(for: .transfer)
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("Export CSV…") {
                    exportDocument = CSVDocument(text: BudgetGridExporter.export(categories: viewModel.categories, periods: viewModel.periods, transactions: viewModel.transactions))
                    showExporter = true
                }
            }
            .padding([.horizontal, .top])

            yearPicker

            // spacing: 0 so the frozen header sits flush on the body, with no gap for
            // scrolled rows to show through.
            VStack(alignment: .leading, spacing: 0) {
                // Frozen month-header row: lives outside the vertical scroll (so it never
                // moves vertically), and mirrors the body's horizontal scroll offset (so it
                // stays aligned with whichever columns are currently visible).
                HStack(spacing: 0) {
                    Text("Category").font(.headline).frame(width: 220, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                    if let year = viewModel.selectedYear {
                        HStack(spacing: 0) {
                            ForEach(1...12, id: \.self) { month in
                                Text(Self.monthYearLabel(year: year, month: month))
                                    .frame(width: 120, alignment: .trailing)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                            }
                            Text("Year Total").bold()
                                .frame(width: 120, alignment: .trailing)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                        .offset(x: horizontalOffset)
                        // minWidth: 0 makes this frame take exactly the width it's offered
                        // (what's left of the window after the Category cell) rather than
                        // growing to the 13 columns' full width, which would push the whole
                        // screen wider than the window; the overflow is then clipped.
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .clipped()
                    }
                }
                .font(.headline)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)

                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        // Frozen category column: not inside any horizontal scroll, so it
                        // never moves left/right; it rides this same vertical ScrollView as
                        // the body, so it stays aligned with its own row.
                        VStack(spacing: 0) {
                            ForEach(allRowKinds) { row in
                                rowLabel(row)
                            }
                        }
                        // 236 = each label's 220pt frame + 8pt padding either side, matching
                        // the header's "Category" cell so the month columns line up.
                        .frame(width: 236, alignment: .leading)
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)

                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(allRowKinds) { row in
                                    rowCells(row)
                                }
                            }
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: HorizontalOffsetKey.self, value: geo.frame(in: .named("gridHScroll")).minX)
                            })
                        }
                        .coordinateSpace(.named("gridHScroll"))
                    }
                }
                .onPreferenceChange(HorizontalOffsetKey.self) { horizontalOffset = $0 }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .commaSeparatedText, defaultFilename: "budget-export") { _ in }
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

    @ViewBuilder
    private func rowLabel(_ row: GridRowKind) -> some View {
        switch row {
        case .sectionHeader(let title):
            Text(title).font(.subheadline).bold()
                .frame(width: 220, height: 32, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
        case .category(let category):
            Text(category.name)
                .frame(width: 220, height: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
        case .groupHeader(let group, _):
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
            .frame(width: 220, height: 28, alignment: .leading)
            .padding(.horizontal, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
        case .groupChild(let category):
            Text(category.name).foregroundStyle(.secondary)
                .frame(width: 200, height: 28, alignment: .leading)
                .padding(.leading, 28).padding(.trailing, 8)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
        }
    }

    @ViewBuilder
    private func rowCells(_ row: GridRowKind) -> some View {
        switch row {
        case .sectionHeader:
            if viewModel.selectedYear != nil {
                HStack(spacing: 0) {
                    ForEach(1...(12 + 1), id: \.self) { _ in
                        // Same footprint as a calendarCell: 120pt frame + 8pt padding
                        // either side, so the band spans exactly the 13 columns.
                        Color.clear.frame(width: 120, height: 32).padding(.horizontal, 8)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
            }
        case .category(let category):
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        let total = viewModel.calendarCategoryTotal(category, year: year, month: month)
                        calendarCell(total)
                            .frame(height: 28)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
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
                        .frame(height: 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard yearTotal != 0 else { return }
                            let range = viewModel.dateRange(forYear: year)
                            let matching = viewModel.transactions(forCategoryId: category.id!, from: range.start, to: range.end)
                            drillDownTarget = .transactions(title: "\(category.name) — \(year)", transactions: matching)
                        }
                }
            }
        case .groupHeader(_, let categories):
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        let total = categories.reduce(0) { $0 + viewModel.calendarCategoryTotal($1, year: year, month: month) }
                        calendarCell(total).bold()
                            .frame(height: 28)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
                    }
                    let yearTotal = (1...12).reduce(0) { sum, month in sum + categories.reduce(0) { $0 + viewModel.calendarCategoryTotal($1, year: year, month: month) } }
                    calendarCell(yearTotal).bold()
                        .frame(height: 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
        case .groupChild(let category):
            // Identical cell behavior to `.category` — a `@ViewBuilder` function
            // returning `some View` can't call itself recursively (the compiler can't
            // resolve a self-referential opaque return type), so this repeats the
            // `.category` branch's body rather than calling `rowCells(.category(...))`.
            if let year = viewModel.selectedYear {
                HStack(spacing: 0) {
                    ForEach(1...12, id: \.self) { month in
                        let total = viewModel.calendarCategoryTotal(category, year: year, month: month)
                        calendarCell(total)
                            .frame(height: 28)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
                            .overlay(Rectangle().frame(width: 1).foregroundStyle(.separator), alignment: .trailing)
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
                        .frame(height: 28)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
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
    }

    private func calendarCell(_ total: Int) -> some View {
        Group {
            if total == 0 {
                Text("—").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                MoneyText(minorUnits: total, alignment: .trailing)
            }
        }
        .frame(width: 120)
        .padding(.horizontal, 8)
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
