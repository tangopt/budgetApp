import SwiftUI
import BudgetCore

/// Property ▸ Overview on the iPad: the iPhone's cards (this month, the mortgage, what's coming up) in a two-column
/// grid. Every figure is `PropertyGlance`'s, as on the iPhone.
struct PadOverviewView: View {
    @ObservedObject var model: PropertyViewModel
    let syncStatus: SyncStatus
    let onRefresh: () async -> Void
    @Environment(\.phoneTheme) private var theme
    @Environment(\.padBrowser) private var browser

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(20)
            }
            .background(theme.background)
            .refreshable {
                await onRefresh()
                await model.load()
            }
            .offlineBannerSlot()
            .navigationTitle("Overview")
            .toolbar {
                // The built-in browser and its Downloads tray (hidden with demo data).
                if let browser {
                    ToolbarItem(placement: .primaryAction) {
                        Button { browser.present() } label: {
                            Label("Sites & downloads", systemImage: RowAction.openSite.systemImage)
                        }
                    }
                }
            }
        }
        .task(id: SyncReloadTrigger(syncStatus)) {
            await model.reload(for: PropertyViewModel.reloadKey(syncStatus))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        case .empty:
            EmptyState(symbol: "house", title: PropertyCopy.emptyTitle, message: PropertyCopy.emptyMessage)
                .frame(maxWidth: .infinity).padding(.top, 60)
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Property couldn't load", message: message)
                .frame(maxWidth: .infinity).padding(.top, 60)
        case .loaded(let page):
            ForEach(page.glances, id: \.property.id) { glance in
                if page.glances.count > 1 { Text(glance.property.name).font(.title3.weight(.semibold)) }
                Text(PropertyCopy.tenancyLine(glance).figuresUnbroken)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        ThisMonthCard(glance: glance)
                        if let mortgage = glance.mortgage {
                            MortgageCard(mortgage: mortgage, currency: glance.property.currency)
                        }
                    }
                    ComingUpList(obligations: glance.comingUp, currency: glance.property.currency)
                }
            }
        }
    }
}
