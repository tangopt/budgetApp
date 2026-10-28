// App/Dashboard/DashboardView.swift
import SwiftUI
import BudgetCore

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    /// The window's importer (the import card shows an import under way).
    let importCenter: ImportCenterModel
    let accounts: [Account]
    @Binding var selectedImportAccountId: Int64?
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
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let content = viewModel.content {
                    let visibility = DashboardCardVisibility(storedString: hiddenCards)
                    let review = content.review
                    FreshnessImportCard(freshness: content.freshness, importedThrough: content.importedThrough, eurToGbpRate: content.eurToGbpRate, importCenter: importCenter, accounts: accounts, selectedAccountId: $selectedImportAccountId, navigate: navigate)
                    // What the Dashboard showed before the review cards, first.
                    let moneyIDs = [DashboardTile.netWorth, DashboardTile.currentMonth, DashboardTile.year, DashboardTile.yearChange,
                                    DashboardTile.topCategories, DashboardTile.upcomingBills, DashboardTile.accounts]
                    DashboardSection(section: .money, tiles: moneyIDs) {
                        NetWorthTile(content: content, navigate: navigate).dashSlot(.money, DashboardTile.netWorth)
                        CurrentMonthTile(month: content.currentMonth, navigate: navigate) {
                            viewModel.clearCloseError()
                            closeTarget = CloseMonthTarget(month: PayMonth(year: content.currentMonth.year, month: content.currentMonth.month))
                        }
                        .dashSlot(.money, DashboardTile.currentMonth)
                        YearTile(viewModel: viewModel, content: content, navigate: navigate).dashSlot(.money, DashboardTile.year)
                        YearChangeTile(changes: content.yearChanges, thisYear: MonthRange.components(of: content.today).year, navigate: navigate)
                            .dashSlot(.money, DashboardTile.yearChange)
                        TopCategoriesTile(categories: content.topCategories, hasActuals: content.currentMonth.hasTransactions, navigate: navigate)
                            .dashSlot(.money, DashboardTile.topCategories)
                        UpcomingBillsTile(bills: content.bills, navigate: navigate).dashSlot(.money, DashboardTile.upcomingBills)
                        AccountsTile(accounts: content.accounts, navigate: navigate).dashSlot(.money, DashboardTile.accounts)
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
                    let taxIDs = (taxTax != nil ? [DashboardTile.taxYear] : []) + (taxEvidence != nil ? [DashboardTile.evidence] : [])
                        + (review.importsWaiting > 0 ? [DashboardTile.importsWaiting] : []) + [DashboardTile.attention]
                    DashboardSection(section: .tax, tiles: taxIDs) {
                        if let tax = taxTax { TaxYearTile(tax: tax, navigate: navigate).dashSlot(.tax, DashboardTile.taxYear) }
                        if let evidence = taxEvidence { EvidenceTile(evidence: evidence, navigate: navigate).dashSlot(.tax, DashboardTile.evidence) }
                        if review.importsWaiting > 0 {
                            ImportsWaitingTile(count: review.importsWaiting, navigate: navigate).dashSlot(.tax, DashboardTile.importsWaiting)
                        }
                        AttentionTile(items: content.attention, extra: review.attention, navigate: navigate).dashSlot(.tax, DashboardTile.attention)
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
                Menu {
                    Button("Reset layout") { storedLayout = "" }
                        .disabled(DashboardLayout(storedString: storedLayout).isDefault)
                } label: {
                    Label("Layout", systemImage: "rectangle.3.group")
                }
                .help("Drag the gaps between tiles to resize them. Reset layout puts every tile back")
            }
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
