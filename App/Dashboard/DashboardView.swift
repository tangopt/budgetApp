// App/Dashboard/DashboardView.swift
import SwiftUI
import BudgetCore

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    /// The window's importer (the title row shows an import under way).
    let importCenter: ImportCenterModel
    let navigate: (AppScreen) -> Void
    @State private var closeTarget: CloseMonthTarget?
    @AppStorage(DashboardCardVisibility.storageKey) private var hiddenCards = ""
    @AppStorage(DashboardLayout.storageKey) private var storedLayout = ""

    /// The saved layout, with a way to change it (every change is saved at once).
    private var layoutContext: DashboardLayoutContext {
        DashboardLayoutContext(layout: DashboardLayout(storedString: storedLayout), change: { mutate in
            var layout = DashboardLayout(storedString: storedLayout)
            mutate(&layout)
            storedLayout = layout.storedString
        }, hide: { tile in
            guard let card = DashboardCardVisibility.Card(tileID: tile) else { return }
            var visibility = DashboardCardVisibility(storedString: hiddenCards)
            visibility.hidden.insert(card)
            hiddenCards = visibility.storedString
        })
    }

    /// The widgets that have something to show now.
    private var availableWidgets: Set<DashboardCardVisibility.Card> {
        var cards = Set(DashboardCardVisibility.Card.allCases)
        guard let review = viewModel.content?.review else { return cards }
        if review.property == nil { cards.remove(.propertyMonth) }
        if review.mortgages == nil { cards.remove(.mortgage) }
        if review.tax == nil { cards.remove(.taxYear) }
        if review.evidence == nil { cards.remove(.evidence) }
        if review.importsWaiting == 0 { cards.remove(.importsWaiting) }
        return cards
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DashboardTitleRow(status: viewModel.content.map { DashboardStatus.make(freshness: $0.freshness, importsWaiting: $0.review.importsWaiting,
                                                                                       staleBalances: $0.attention.staleBalanceCount) },
                                  importCenter: importCenter, navigate: navigate)
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let content = viewModel.content {
                    let visibility = DashboardCardVisibility(storedString: hiddenCards)
                    let review = content.review
                    // What the Dashboard showed before the review cards, first.
                    let moneyIDs = DashboardCardVisibility.Card.cards(in: .money).filter(visibility.shows).map(\.tileID)
                    if !moneyIDs.isEmpty {
                        DashboardSection(section: .money, tiles: moneyIDs) {
                            if visibility.shows(.netWorth) { NetWorthTile(content: content, navigate: navigate).dashSlot(.money, DashboardTile.netWorth) }
                            if visibility.shows(.currentMonth) {
                                CurrentMonthTile(month: content.currentMonth, navigate: navigate) {
                                    viewModel.clearCloseError()
                                    closeTarget = CloseMonthTarget(month: PayMonth(year: content.currentMonth.year, month: content.currentMonth.month))
                                }
                                .dashSlot(.money, DashboardTile.currentMonth)
                            }
                            if visibility.shows(.year) { YearTile(viewModel: viewModel, content: content, navigate: navigate).dashSlot(.money, DashboardTile.year) }
                            if visibility.shows(.yearChange) {
                                YearChangeTile(changes: content.yearChanges, thisYear: MonthRange.components(of: content.today).year, navigate: navigate)
                                    .dashSlot(.money, DashboardTile.yearChange)
                            }
                            if visibility.shows(.topCategories) {
                                TopCategoriesTile(categories: content.topCategories, hasActuals: content.currentMonth.hasTransactions, navigate: navigate)
                                    .dashSlot(.money, DashboardTile.topCategories)
                            }
                            if visibility.shows(.upcomingBills) { UpcomingBillsTile(bills: content.bills, navigate: navigate).dashSlot(.money, DashboardTile.upcomingBills) }
                            if visibility.shows(.accounts) { AccountsTile(accounts: content.accounts, navigate: navigate).dashSlot(.money, DashboardTile.accounts) }
                        }
                    }
                    let propertyRows = review.property.flatMap { visibility.shows(.propertyMonth) ? $0 : nil }
                    let mortgages = review.mortgages.flatMap { visibility.shows(.mortgage) ? $0 : nil } ?? []
                    if propertyRows != nil || !mortgages.isEmpty {
                        let ids = (propertyRows != nil ? [DashboardTile.propertyMonth] : []) + mortgages.map { DashboardTile.mortgage($0.propertyName) }
                        DashboardSection(section: .property, tiles: ids) {
                            if let rows = propertyRows { PropertyMonthTile(rows: rows, navigate: navigate).dashSlot(.property, DashboardTile.propertyMonth) }
                            ForEach(mortgages, id: \.propertyName) { mortgage in
                                MortgageTile(mortgage: mortgage, today: content.today, navigate: navigate)
                                    .dashSlot(.property, DashboardTile.mortgage(mortgage.propertyName))
                            }
                        }
                    }
                    let taxTax = review.tax.flatMap { visibility.shows(.taxYear) ? $0 : nil }
                    let taxEvidence = review.evidence.flatMap { visibility.shows(.evidence) ? $0 : nil }
                    let showsImports = review.importsWaiting > 0 && visibility.shows(.importsWaiting)
                    let showsAttention = visibility.shows(.attention)
                    let taxIDs = (taxTax != nil ? [DashboardTile.taxYear] : []) + (taxEvidence != nil ? [DashboardTile.evidence] : [])
                        + (showsImports ? [DashboardTile.importsWaiting] : []) + (showsAttention ? [DashboardTile.attention] : [])
                    if !taxIDs.isEmpty {
                    DashboardSection(section: .tax, tiles: taxIDs) {
                        if let tax = taxTax { TaxYearTile(tax: tax, navigate: navigate).dashSlot(.tax, DashboardTile.taxYear) }
                        if let evidence = taxEvidence { EvidenceTile(evidence: evidence, navigate: navigate).dashSlot(.tax, DashboardTile.evidence) }
                        if showsImports {
                            ImportsWaitingTile(count: review.importsWaiting, navigate: navigate).dashSlot(.tax, DashboardTile.importsWaiting)
                        }
                        if showsAttention {
                            AttentionTile(items: content.attention, extra: review.attention, navigate: navigate).dashSlot(.tax, DashboardTile.attention)
                        }
                    }
                    }
                } else if viewModel.errorMessage == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .environment(\.dashboardLayoutContext, layoutContext)
        .screenToolbar {
            ToolbarItem(placement: .primaryAction) {
                DashboardWidgetsButton(available: availableWidgets, hiddenCards: $hiddenCards, storedLayout: $storedLayout)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .onDisappear { viewModel.markVisited() }
        .sheet(item: $closeTarget, onDismiss: { viewModel.clearCloseError() }) { target in
            if let calendar = viewModel.payCalendar {
                CloseMonthView(month: target.month, calendar: calendar, errorMessage: viewModel.closeErrorMessage) { day in
                    viewModel.closeMonth(target.month, on: day)
                }
            }
        }
    }
}

/// Two cards side by side, at equal width, when there is room for both at their minimum
/// width; stacked one above the other otherwise. Unlike an adaptive grid it never leaves
/// empty cells on a wide window (it is always exactly two-up or one-up).
struct TwoUpRow<First: View, Second: View>: View {
    private static var minimumCardWidth: CGFloat { 340 }
    private static var spacing: CGFloat { 12 }

    @ViewBuilder let first: First
    @ViewBuilder let second: Second

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // `idealWidth` pins each card's ideal width to the minimum, so a card's long
            // single-line text can't make the side-by-side layout look too wide to fit.
            HStack(alignment: .top, spacing: Self.spacing) {
                first.frame(minWidth: Self.minimumCardWidth, idealWidth: Self.minimumCardWidth, maxWidth: .infinity)
                second.frame(minWidth: Self.minimumCardWidth, idealWidth: Self.minimumCardWidth, maxWidth: .infinity)
            }
            // The row takes the taller card's height and both cards stretch to it.
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Self.spacing) {
                first
                second
            }
        }
    }
}
