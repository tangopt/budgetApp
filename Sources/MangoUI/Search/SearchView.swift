import SwiftUI
import BudgetCore

/// Search (iPhone spec §3.4), the iOS 26 search tab (`Tab(role: .search)` in `PhoneTabs`). The field matches the
/// description, an amount ("24.99", ">100") and the category; tokens filter by Uncategorised, account and period.
/// Results are grouped by day with each day's total (`TransactionSearch.totals`); uncategorised rows carry the
/// amber "?" badge. With nothing typed it lists the newest transactions. Tapping a row opens it read-only
/// (`TransactionDetailSheet`). Quick sort and the swipe actions are edits: they come with the editing step.
///
/// `model` belongs to whoever shows Search, above the lock cover, so a relock keeps the query, the tokens and an open
/// transaction. The sheet is presented from here, inside the lock cover.
public struct SearchView: View {
    @ObservedObject var model: SearchViewModel
    let syncStatus: SyncStatus
    let onRefresh: () async -> Void
    @Environment(\.phoneTheme) private var theme
    @Environment(\.usesPadPage) private var usesPadPage

    public init(model: SearchViewModel, syncStatus: SyncStatus, onRefresh: @escaping () async -> Void = {}) {
        self.model = model
        self.syncStatus = syncStatus
        self.onRefresh = onRefresh
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                // Not lazy: the list stops at about 150 rows (`SearchViewModel.resultRowLimit`), and the snapshot probe
                // measures every figure.
                VStack(alignment: .leading, spacing: 16) {
                    if usesPadPage { PadFlatSearchField(model: model) }
                    content
                }
                .phonePageContent()
            }
            .background(theme.background)
            .refreshable {
                await onRefresh()
                await model.load()
            }
            .offlineBannerSlot()
            .phonePageTitle("Search", keepsSearchBar: !usesPadPage)
            .modifier(SearchFieldIfNeeded(model: model, usesPadPage: usesPadPage))
        }
        .sheet(item: $model.detail) { row in
            TransactionDetailSheet(row: row)
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await model.reload(for: SearchViewModel.reloadKey(syncStatus))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Search couldn't load", message: message)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        case .loaded:
            if let error = model.errorMessage {
                InlineBanner(tone: .amber, text: error)
            }
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        let results = model.results
        if results.days.isEmpty {
            if model.isBrowsing {
                EmptyState(symbol: "tray", title: SearchCopy.noTransactionsTitle, message: SearchCopy.noTransactionsMessage)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else {
                EmptyState(symbol: "magnifyingglass", title: SearchCopy.emptyTitle, message: SearchCopy.emptyMessage)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isBrowsing ? SearchCopy.recentTitle : SearchCopy.matches(results.matchCount))
                    .mangoFont(.headline)
                    .accessibilityAddTraits(.isHeader)
                if results.isCapped, !model.isBrowsing {
                    Text(SearchCopy.capped(shown: results.shownCount))
                        .mangoFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(results.days) { day in
                Card {
                    SearchDayHeader(day: day)
                    if day.listsUncountedTransfer {
                        Text(SearchCopy.transferNote)
                            .mangoFont(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(day.rows) { row in
                        Divider()
                        Button {
                            model.detail = row
                        } label: {
                            TransactionRow(row: row)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the transaction")
                    }
                }
            }
        }
    }
}

/// The search field with its tokens and suggested tokens, bound to `model`. On the tab's own navigation stack: put on
/// the tab view instead (iOS 26's other placement) the field showed but never took focus on the simulator.
struct SearchField: ViewModifier {
    @ObservedObject var model: SearchViewModel

    func body(content: Content) -> some View {
        content.searchable(text: $model.query, tokens: $model.tokens,
                           suggestedTokens: Binding(get: { model.suggestedTokens }, set: { _ in }),
                           prompt: SearchCopy.prompt) { token in
            Label(token.title, systemImage: token.symbol)
        }
    }
}

/// A day's date and its total (net, in pounds): side by side, or the total under the date at accessibility sizes.
struct SearchDayHeader: View {
    let day: SearchDay
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let total = MoneyText(minorUnits: day.totals.netMinorUnits, currency: .gbp, role: .income,
                              fit: AmountRowLayout.fit(.natural, at: dynamicTypeSize), font: .subheadline.weight(.semibold))
        Group {
            if AmountRowLayout.stacks(at: dynamicTypeSize) {
                VStack(alignment: .leading, spacing: 2) {
                    DateText(day.day, font: .subheadline.weight(.semibold))
                    total
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    DateText(day.day, font: .subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    total
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(PhoneDateFormat.spoken(day.day))
        .accessibilityValue("Day total, " + MoneyPresentation(minorUnits: day.totals.netMinorUnits, currency: .gbp, role: .income).spoken)
    }
}

/// The system search field on the iPhone; on the iPad the page carries its own flat field (`PadFlatSearchField`).
struct SearchFieldIfNeeded: ViewModifier {
    @ObservedObject var model: SearchViewModel
    let usesPadPage: Bool

    func body(content: Content) -> some View {
        if usesPadPage { content } else { content.modifier(SearchField(model: model)) }
    }
}

/// The iPad's search field: flat, directly under the title, full width with a hairline under it; the applied tokens
/// sit in it as chips and the suggested ones follow as chips to tap.
struct PadFlatSearchField: View {
    @ObservedObject var model: SearchViewModel
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: MangoSpacing.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                ForEach(model.tokens) { token in
                    Button { model.tokens.removeAll { $0 == token } } label: {
                        Label(token.title, systemImage: token.symbol).mangoFont(.subheadline, weight: .semibold)
                            .padding(.horizontal, 10).frame(minHeight: 32)
                            .background(Capsule().fill(theme.accent.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Removes this filter")
                }
                TextField(SearchCopy.prompt, text: $model.query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .mangoFont(.title3)
                if !model.query.isEmpty {
                    PadIconButton(systemImage: "xmark", label: "Clear search") { model.query = "" }
                }
            }
            .frame(minHeight: 48)
            Divider()
            let suggested = model.suggestedTokens
            if !suggested.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggested) { token in
                            Button { model.tokens.append(token) } label: {
                                Label(token.title, systemImage: token.symbol).mangoFont(.subheadline)
                                    .padding(.horizontal, 12).frame(minHeight: 36)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
