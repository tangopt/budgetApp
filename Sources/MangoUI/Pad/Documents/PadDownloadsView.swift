import SwiftUI
import BudgetCore

/// Documents ▸ Downloads on the iPad (redesign step 4, D4): the one place for the saved sites and the downloads waiting.
/// The sites are chips (tap one to open it in the built-in browser; "Add site" and "Remove site" with Edit on the
/// sites), the tray below them lists each PDF waiting to be checked with Check (the magnifier) and Discard. This
/// month's "Sites & downloads" link comes here; the browser itself still opens over everything. Where there is no
/// browser (demo data) the page says so.
struct PadDownloadsView: View {
    let syncStatus: SyncStatus
    @Environment(\.padBrowser) private var browser
    @Environment(\.phoneTheme) private var theme
    @State private var addingSite = false
    @State private var checking: TrayItem?

    var body: some View {
        NavigationStack {
            Group {
                if let browser { content(browser) } else { unavailable }
            }
            .background(theme.background)
            .offlineBannerSlot()
            .padPage("Downloads") {
                if let browser {
                    RowIconButton(.openSite, item: "sites and downloads") { browser.present() }
                }
            }
        }
        .sheet(isPresented: $addingSite) {
            if let browser {
                AddSiteSheet { name, address, kind in
                    let site = try await browser.addSite(name: name, address: address, kind: kind)
                    browser.present(site)
                }
            }
        }
        .sheet(item: $checking) { item in
            if let browser, let source = browser.checkSource {
                CheckAndLinkHost(item: item, tray: browser.tray, source: source) {
                    checking = nil
                    Task { await browser.refreshTray() }
                }
            }
        }
        .task(id: SyncReloadTrigger(syncStatus)) { await browser?.reload() }
    }

    private func content(_ browser: BrowserModel) -> some View {
        PadPageInsetReading { inset in
            VStack(alignment: .leading, spacing: MangoSpacing.section) {
                if let notice = browser.notice {
                    InlineBanner(tone: .amber, text: notice).onTapGesture { browser.notice = nil }
                }
                VStack(alignment: .leading, spacing: MangoSpacing.xs) {
                    PadSectionHeader("Saved sites")
                    SavedSitesStrip(sites: browser.sites, currentId: nil, canEdit: browser.canEditSites,
                                    onOpen: { browser.present($0) },
                                    onRemove: { site in Task { await browser.removeSite(id: site.id) } },
                                    onAdd: { addingSite = true })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mangoSurface()
                }
                VStack(alignment: .leading, spacing: MangoSpacing.xs) {
                    PadSectionHeader("Waiting to be checked")
                    TrayListView(items: browser.downloadedItems, onCheck: check, onDiscard: { item in
                        Task { await browser.discard(item) }
                    }, canCheck: browser.canCheck)
                        .mangoSurface()
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, inset)
            .padding(.top, MangoSpacing.xs).padding(.bottom, MangoSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func check(_ item: TrayItem) {
        guard let browser else { return }
        if browser.checkSource != nil { checking = item } else { browser.present() }
    }

    private var unavailable: some View {
        EmptyState(symbol: RowAction.download.systemImage, title: "No sites or downloads here",
                   message: "The built-in browser isn't available with demo data.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
