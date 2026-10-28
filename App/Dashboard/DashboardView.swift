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
            VStack(spacing: 12) {
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let content = viewModel.content {
                    FreshnessImportCard(freshness: content.freshness, importedThrough: content.importedThrough, eurToGbpRate: content.eurToGbpRate, importCenter: importCenter, accounts: accounts, selectedAccountId: $selectedImportAccountId, importsWaiting: content.review.importsWaiting, navigate: navigate)
                    let visibility = DashboardCardVisibility(storedString: hiddenCards)
                    let review = content.review
                    CurrentMonthCard(month: content.currentMonth, navigate: navigate) {
                        viewModel.clearCloseError()
                        closeTarget = CloseMonthTarget(month: PayMonth(year: content.currentMonth.year, month: content.currentMonth.month))
                    }
                    let taxCard = review.tax.flatMap { visibility.shows(.taxYear) ? $0 : nil }
                    let propertyCard = review.property.flatMap { visibility.shows(.propertyMonth) ? $0 : nil }
                    if let tax = taxCard, let rows = propertyCard {
                        TwoUpRow {
                            TaxYearPositionCard(tax: tax, navigate: navigate)
                        } second: {
                            PropertyMonthCard(rows: rows, navigate: navigate)
                        }
                    } else if let tax = taxCard {
                        TaxYearPositionCard(tax: tax, navigate: navigate)
                    } else if let rows = propertyCard {
                        PropertyMonthCard(rows: rows, navigate: navigate)
                    }
                    if let evidence = review.evidence, visibility.shows(.evidence) {
                        EvidenceDocumentsCard(evidence: evidence, navigate: navigate)
                    }
                    NetWorthCard(content: content, navigate: navigate)
                    YearChangeCard(changes: content.yearChanges, navigate: navigate)
                    YearAtAGlanceCard(viewModel: viewModel, content: content, navigate: navigate)
                    TwoUpRow {
                        TopCategoriesCard(categories: content.topCategories, hasActuals: content.currentMonth.hasTransactions, navigate: navigate)
                    } second: {
                        AttentionCard(items: content.attention, extra: review.attention, navigate: navigate)
                    }
                    TwoUpRow {
                        UpcomingBillsCard(bills: content.bills, navigate: navigate)
                    } second: {
                        AccountsCard(accounts: content.accounts, navigate: navigate)
                    }
                    if let mortgages = review.mortgages, visibility.shows(.mortgage) {
                        MortgageCard(mortgages: mortgages, navigate: navigate)
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
