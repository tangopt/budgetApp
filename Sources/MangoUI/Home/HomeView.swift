import SwiftUI
import BudgetCore

/// Home (iPhone spec §3.2): the freshness line, then Net worth, This pay month, Needs attention and Upcoming, in
/// that order. Read-only: nothing here edits. The avatar button top right opens Settings (`onSettings`, Task 12);
/// pull to refresh asks for changes (`onRefresh`) and then reads again; a change of `syncStatus`'s last-sync time
/// (a scheduled sync, the first download) reads again too.
///
/// `model` belongs to whoever shows Home, above the lock cover, so a relock keeps it.
public struct HomeView: View {
    @ObservedObject var model: HomeViewModel
    let syncStatus: SyncStatus
    let onRefresh: () async -> Void
    let onSettings: () -> Void
    /// The clock the sync copy counts from ("Up to date · 5 minutes ago").
    let now: () -> Date
    @Environment(\.phoneTheme) private var theme

    public init(model: HomeViewModel, syncStatus: SyncStatus, onRefresh: @escaping () async -> Void,
                onSettings: @escaping () -> Void, now: @escaping () -> Date = { Date() }) {
        self.model = model
        self.syncStatus = syncStatus
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.now = now
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
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
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onSettings) {
                        Image(systemName: "person.crop.circle")
                            .mangoFont(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        // Loads on first appearance, then again whenever a sync brings changes in (its last-sync time moves).
        .task(id: SyncReloadTrigger(syncStatus)) {
            await model.reload(for: HomeViewModel.reloadKey(syncStatus))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        case .empty:
            VStack(spacing: 16) {
                EmptyState(symbol: "tray", title: "Nothing here yet",
                           message: "The household's budget shows here once it has synced from the Mac.")
                SyncStatusLine(status: syncStatus, now: now())
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Home couldn't load", message: message)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        case .loaded(let summary):
            if let error = model.errorMessage {
                InlineBanner(tone: .amber, text: error)
            }
            FreshnessLine(summary: summary)
            NetWorthCard(netWorth: summary.netWorth)
            PayMonthCard(summary: summary)
            AttentionCard(lines: AttentionLine.lines(summary.attention, syncStatus: syncStatus, now: now()))
            UpcomingCard(items: summary.upcoming)
        }
    }
}
