import SwiftUI
import BudgetCore

/// Home (design review §2.3): on the iPhone Left to spend, two tiles, Needs you and Upcoming, in that order (the
/// freshness line only on top when the data is stale); the iPad shows a tile grid (This pay month, Net worth, Recharges, Needs attention, Upcoming). Read-only: nothing here edits. The avatar button top right opens the Me sheet (`onSettings`);
/// pull to refresh asks for changes (`onRefresh`) and then reads again; a change of `syncStatus`'s last-sync time
/// (a scheduled sync, the first download) reads again too.
///
/// `model` belongs to whoever shows Home, above the lock cover, so a relock keeps it.
public struct HomeView: View {
    @ObservedObject var model: HomeViewModel
    let syncStatus: SyncStatus
    let onRefresh: () async -> Void
    let onSettings: () -> Void
    /// A tile asks for its tab (the iPhone's Home; the iPad's sidebar has its own way).
    let onOpenTab: (PhoneTab) -> Void
    /// The clock the sync copy counts from ("Up to date · 5 minutes ago").
    let now: () -> Date
    /// The iPad's recharges-status chart: the selected tenancy's bills by stage (empty: no card; the iPhone passes none).
    let recharges: [PadBillsAndRechargesModel.StageCount]
    @Environment(\.phoneTheme) private var theme
    @Environment(\.usesPadPage) private var usesPadPage

    public init(model: HomeViewModel, syncStatus: SyncStatus, onRefresh: @escaping () async -> Void,
                onSettings: @escaping () -> Void, onOpenTab: @escaping (PhoneTab) -> Void = { _ in },
                now: @escaping () -> Date = { Date() },
                recharges: [PadBillsAndRechargesModel.StageCount] = []) {
        self.recharges = recharges
        self.model = model
        self.syncStatus = syncStatus
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.onOpenTab = onOpenTab
        self.now = now
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
            // On the iPad, Settings is the sidebar footer's.
            .phonePageTitle("Home") {
                if !usesPadPage {
                    Button(action: onSettings) {
                        Image(systemName: "person.crop.circle")
                            .mangoFont(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Me")
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
            if usesPadPage {
                padContent(summary)
            } else {
                phoneContent(summary)
            }
        }
    }

    /// The iPad's tile grid (design review §2.3): this pay month spans two columns beside Net worth, then Recharges,
    /// Needs attention and Upcoming share the next row; equal heights, so the page fits one screen.
    @ViewBuilder
    private func padContent(_ summary: HomeSummary) -> some View {
        FreshnessLine(summary: summary)
        let attention = AttentionLine.lines(summary.attention, syncStatus: syncStatus, now: now())
        let showsRecharges = recharges.contains { $0.count > 0 }
        PadGrid(minimumColumnWidth: 260, maximumColumns: 3, balanced: false) {
            PayMonthCard(summary: summary).padGridSpan(2)
            NetWorthCard(netWorth: summary.netWorth)
            if showsRecharges { RechargesStatusCard(counts: recharges) }
            AttentionCard(lines: attention)
            UpcomingCard(items: summary.upcoming).padGridSpan(showsRecharges ? 1 : 2)
        }
        .padEqualHeightCards()
    }

    /// The iPhone's order (`HomeCopy.phoneBlocks`): Left to spend, two tiles, Needs you, Upcoming.
    @ViewBuilder
    private func phoneContent(_ summary: HomeSummary) -> some View {
        ForEach(Array(HomeCopy.phoneBlocks(summary).enumerated()), id: \.offset) { _, block in
            switch block {
            case .staleData, .freshness: FreshnessLine(summary: summary)
            case .leftToSpend: LeftToSpendCard(summary: summary)
            case .tiles: HomeTiles(summary: summary, open: onOpenTab)
            case .attention:
                AttentionCard(lines: AttentionLine.lines(summary.attention, syncStatus: syncStatus, now: now()))
            case .upcoming: UpcomingCard(items: summary.upcoming, limit: HomeCopy.phoneUpcomingLimit)
            }
        }
    }
}
