import SwiftUI
import BudgetCore

/// Month (iPhone spec §3.3): the pay month with ‹ › and its payday-to-payday range, the summary grid (Income · Spent
/// so far · Still expected · Left to spend), the segments Spending | Income | Transfers and a row per category;
/// tapping a row opens its transactions. Read-only: plans are edited on the Mac. Pull to refresh asks for changes
/// (`onRefresh`) and reads again; a new sync (`syncStatus`'s last-sync time) reads again too.
///
/// `model` belongs to whoever shows Month, above the lock cover, so a relock keeps the month, the segment and the
/// pushed transactions (`model.path`).
public struct MonthView: View {
    @ObservedObject var model: MonthViewModel
    let syncStatus: SyncStatus
    let onRefresh: () async -> Void
    @Environment(\.phoneTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.quickEdit) private var quickEdit

    public init(model: MonthViewModel, syncStatus: SyncStatus, onRefresh: @escaping () async -> Void = {}) {
        self.model = model
        self.syncStatus = syncStatus
        self.onRefresh = onRefresh
    }

    public var body: some View {
        NavigationStack(path: $model.path) {
            ScrollView {
                // Not lazy: a month has a few dozen rows at most, and the snapshot probe measures every one.
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(16)
            }
            .background(theme.background)
            .refreshable {
                await onRefresh()
                await model.load()
            }
            .offlineBannerSlot()
            .navigationTitle("Month")
            .navigationDestination(for: MonthRowDestination.self) { destination in
                MonthTransactionsView(model: model.transactionsModel(for: destination))
                    .demoBannerSlot()
            }
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await model.reload(for: MonthViewModel.reloadKey(syncStatus))
            await quickEdit?.load()
        }
        .modifier(QuickSortSheet(model: quickEdit))
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Month couldn't load", message: message)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        case .loaded(let page):
            if let error = model.errorMessage {
                InlineBanner(tone: .amber, text: error)
            }
            MonthHeader(page: page, canShowPrevious: model.canShowPrevious, canShowNext: model.canShowNext,
                        onPrevious: { Task { await model.showPrevious() } },
                        onNext: { Task { await model.showNext() } })
            MonthSummaryGrid(review: page.review)
            // The queue is the current pay month's.
            if let quickEdit, !model.canShowNext {
                QuickSortEntryRow(model: quickEdit)
            }
            if page.isEmpty {
                EmptyState(symbol: "calendar", title: MonthCopy.emptyTitle, message: MonthCopy.emptyMessage)
            } else {
                segmentPicker
                rows(page)
            }
        }
    }

    @ViewBuilder
    private var segmentPicker: some View {
        let picker = Picker("Show", selection: $model.segment) {
            ForEach(MonthSegment.allCases) { segment in
                Text(segment.title).tag(segment)
            }
        }
        // At accessibility sizes a segmented control would cut its titles short: a menu keeps them whole.
        if dynamicTypeSize.isAccessibilitySize {
            HStack {
                Text("Show")
                    .foregroundStyle(.secondary)
                picker.pickerStyle(.menu)
            }
            .frame(minHeight: 44)
        } else {
            picker
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minHeight: 44)
        }
    }

    @ViewBuilder
    private func rows(_ page: MonthPage) -> some View {
        let rows = page.rows(model.segment)
        Card {
            if rows.isEmpty {
                Text(model.segment.emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    NavigationLink(value: MonthRowDestination(row: row, range: page.review.range)) {
                        HStack(spacing: 8) {
                            CategoryRow(row: row)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// What a category row pushes: the row and its pay month's range.
public struct MonthRowDestination: Hashable, Sendable {
    public let row: PayMonthReview.Row
    public let range: PayMonthReview.DayRange

    public init(row: PayMonthReview.Row, range: PayMonthReview.DayRange) {
        self.row = row
        self.range = range
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(row.id)
        hasher.combine(range.start)
        hasher.combine(range.end)
    }
}

/// The pay month's name between ‹ and ›, its range under it.
struct MonthHeader: View {
    let page: MonthPage
    let canShowPrevious: Bool
    let canShowNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            arrow("chevron.left", label: "Previous month", enabled: canShowPrevious, action: onPrevious)
            VStack(spacing: 2) {
                Text(MonthCopy.title(page.review.month).figuresUnbroken)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(MonthCopy.range(page.review.range).figuresUnbroken)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            arrow("chevron.right", label: "Next month", enabled: canShowNext, action: onNext)
        }
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// The summary grid: two by two, each figure shrinking a little in its half of the card rather than wrapping; at
/// accessibility sizes one figure per row, under its label.
struct MonthSummaryGrid: View {
    let review: PayMonthReview
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let tiles = MonthSummaryTile.tiles(review)
        Card {
            if AmountRowLayout.stacks(at: dynamicTypeSize) {
                ForEach(tiles) { tile in
                    FigureRow(label: tile.label) {
                        MoneyText(minorUnits: tile.minorUnits, currency: .gbp, role: tile.role, font: .title3.weight(.semibold))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tile.label)
                    .accessibilityValue(tile.spoken)
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow {
                        cell(tiles[0])
                        cell(tiles[1])
                    }
                    GridRow {
                        cell(tiles[2])
                        cell(tiles[3])
                    }
                }
            }
        }
    }

    private func cell(_ tile: MonthSummaryTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MoneyText(minorUnits: tile.minorUnits, currency: .gbp, role: tile.role, fit: .shrink(),
                      font: .title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.label)
        .accessibilityValue(tile.spoken)
    }
}
