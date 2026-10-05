// App/Dashboard/DashboardView.swift
import SwiftUI
import BudgetCore

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var importViewModel: ImportViewModel
    let accounts: [Account]
    @Binding var selectedImportAccountId: Int64?
    let profileStore: ImportProfileStore
    let navigate: (AppScreen) -> Void
    @State private var closeTarget: CloseMonthTarget?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The import host reports picker and wizard failures through
                // `importViewModel.errorMessage`. ImportView owns the only other banner for it,
                // and ReviewView shows it itself while reviewing, so skip it then.
                if let error = importViewModel.errorMessage, !importViewModel.isReviewing {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(error).foregroundStyle(.red)
                        Spacer()
                        Button("Dismiss") { importViewModel.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                    .font(.callout)
                }
                if let content = viewModel.content {
                    FreshnessImportCard(freshness: content.freshness, importViewModel: importViewModel, accounts: accounts, selectedAccountId: $selectedImportAccountId, profileStore: profileStore, navigate: navigate)
                    NetWorthCard(content: content, navigate: navigate)
                    TwoUpRow {
                        YearChangeCard(changes: content.yearChanges, navigate: navigate)
                    } second: {
                        CurrentMonthCard(month: content.currentMonth, navigate: navigate) {
                            viewModel.clearCloseError()
                            closeTarget = CloseMonthTarget(month: PayMonth(year: content.currentMonth.year, month: content.currentMonth.month))
                        }
                    }
                    YearAtAGlanceCard(viewModel: viewModel, content: content, navigate: navigate)
                    TwoUpRow {
                        TopCategoriesCard(categories: content.topCategories, hasActuals: content.currentMonth.hasTransactions, navigate: navigate)
                    } second: {
                        AttentionCard(items: content.attention, navigate: navigate)
                    }
                    TwoUpRow {
                        UpcomingBillsCard(bills: content.bills, navigate: navigate)
                    } second: {
                        AccountsCard(accounts: content.accounts, navigate: navigate)
                    }
                } else if viewModel.errorMessage == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
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
            VStack(spacing: Self.spacing) {
                first
                second
            }
        }
    }
}
