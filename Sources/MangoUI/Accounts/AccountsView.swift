import SwiftUI
import BudgetCore

/// Accounts (iPhone spec §3.6): net worth today and its change since last December, then Cash, Credit and
/// Investments, each with its subtotal; a row opens the account's balance chart and recent transactions. Every
/// figure is the Mac's Accounts screen's (`AccountsOverview`). Read-only: updating a balance comes in step 6. Pull to
/// refresh asks for changes (`onRefresh`) and reads again; a new sync (`syncStatus`'s last-sync time) reads again too.
///
/// `model` belongs to whoever shows Accounts, above the lock cover, so a relock keeps the pushed account
/// (`model.path`).
public struct AccountsView: View {
    @ObservedObject var model: AccountsViewModel
    let syncStatus: SyncStatus
    let onRefresh: () async -> Void
    @Environment(\.phoneTheme) private var theme

    public init(model: AccountsViewModel, syncStatus: SyncStatus, onRefresh: @escaping () async -> Void = {}) {
        self.model = model
        self.syncStatus = syncStatus
        self.onRefresh = onRefresh
    }

    public var body: some View {
        NavigationStack(path: $model.path) {
            ScrollView {
                // Not lazy: a household has a dozen accounts or so, and the snapshot probe measures every one.
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
            .navigationTitle("Accounts")
            .navigationDestination(for: AccountDestination.self) { destination in
                AccountDetailView(model: model.detailModel(for: destination))
            }
        }
        .task(id: AccountsViewModel.reloadKey(syncStatus)) {
            await model.reload(for: AccountsViewModel.reloadKey(syncStatus))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        case .empty:
            EmptyState(symbol: "building.columns", title: AccountsCopy.emptyTitle, message: AccountsCopy.emptyMessage)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Accounts couldn't load", message: message)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        case .loaded(let page):
            if let error = model.errorMessage {
                InlineBanner(tone: .amber, text: error)
            }
            AccountsHeader(page: page)
            ForEach(page.sections) { section in
                sectionCard(section)
            }
        }
    }

    private func sectionCard(_ section: AccountsSection) -> some View {
        Card {
            FigureRow(label: section.title) {
                MoneyText(minorUnits: section.subtotalGBP, currency: .gbp, role: .balance, font: .headline)
            }
            .font(.headline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(section.title)
            .accessibilityValue(section.spokenSubtotal)
            .accessibilityAddTraits(.isHeader)
            ForEach(section.rows) { row in
                Divider()
                NavigationLink(value: AccountDestination(accountId: row.id)) {
                    HStack(spacing: 8) {
                        AccountRowView(row: row)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Net worth today (`AccountsOverview.netWorthGBP`) and the change since last December.
struct AccountsHeader: View {
    let page: AccountsPage

    var body: some View {
        Card(title: "Net worth") {
            MoneyText(minorUnits: page.overview.netWorthGBP, currency: .gbp, role: .balance, fit: .shrink(),
                      font: .largeTitle.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Net worth")
                .accessibilityValue(MoneyPresentation(minorUnits: page.overview.netWorthGBP, currency: .gbp, role: .balance).spoken)
            if let since = page.sinceYearEnd {
                FigureRow(label: AccountsCopy.sinceLabel(since)) {
                    MoneyText(minorUnits: since.changeMinorUnits, currency: .gbp, role: .income)
                }
            }
        }
    }
}
