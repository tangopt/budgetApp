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
                    DashboardSection(title: "Money") {
                        NetWorthTile(content: content, navigate: navigate).tileSpan(2)
                        CurrentMonthTile(month: content.currentMonth, navigate: navigate) {
                            viewModel.clearCloseError()
                            closeTarget = CloseMonthTarget(month: PayMonth(year: content.currentMonth.year, month: content.currentMonth.month))
                        }
                        YearTile(viewModel: viewModel, content: content, navigate: navigate).tileSpan(2)
                        YearChangeTile(changes: content.yearChanges, thisYear: MonthRange.components(of: content.today).year, navigate: navigate)
                        TopCategoriesTile(categories: content.topCategories, hasActuals: content.currentMonth.hasTransactions, navigate: navigate)
                        UpcomingBillsTile(bills: content.bills, navigate: navigate)
                        AccountsTile(accounts: content.accounts, navigate: navigate)
                    }
                    let propertyRows = review.property.flatMap { visibility.shows(.propertyMonth) ? $0 : nil }
                    let mortgages = review.mortgages.flatMap { visibility.shows(.mortgage) ? $0 : nil } ?? []
                    if propertyRows != nil || !mortgages.isEmpty {
                        DashboardSection(title: "Property") {
                            if let rows = propertyRows { PropertyMonthTile(rows: rows, navigate: navigate) }
                            ForEach(mortgages, id: \.propertyName) { mortgage in
                                MortgageTile(mortgage: mortgage, today: content.today, navigate: navigate)
                            }
                        }
                    }
                    DashboardSection(title: "Tax & documents") {
                        if let tax = review.tax, visibility.shows(.taxYear) { TaxYearTile(tax: tax, navigate: navigate) }
                        if let evidence = review.evidence, visibility.shows(.evidence) { EvidenceTile(evidence: evidence, navigate: navigate) }
                        if review.importsWaiting > 0 { ImportsWaitingTile(count: review.importsWaiting, navigate: navigate) }
                        AttentionTile(items: content.attention, extra: review.attention, navigate: navigate)
                    }
                } else if viewModel.errorMessage == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
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
