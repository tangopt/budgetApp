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

    // Cards reflow to a single column on narrow windows rather than truncating.
    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)]

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
                    LazyVGrid(columns: columns, spacing: 12) {
                        YearChangeCard(changes: content.yearChanges, navigate: navigate)
                        CurrentMonthCard(month: content.currentMonth, catchAll: content.catchAll, navigate: navigate)
                    }
                    YearAtAGlanceCard(viewModel: viewModel, content: content, navigate: navigate)
                    LazyVGrid(columns: columns, spacing: 12) {
                        TopCategoriesCard(categories: content.topCategories, hasActuals: content.currentMonth.monthClass == .blended, navigate: navigate)
                        AttentionCard(items: content.attention, navigate: navigate)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        UpcomingBillsCard(bills: content.bills, navigate: navigate)
                        AccountsCard(accounts: content.accounts, navigate: navigate)
                    }
                } else if viewModel.errorMessage == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
    }
}
