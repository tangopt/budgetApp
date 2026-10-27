import Foundation
import Observation
import SwiftUI
import WebKit
import BudgetCore

extension EnvironmentValues {
    /// The iPad's built-in browser, where a screen offers "Open site" or "Sites & downloads"; nil with demo data (the
    /// browser is hidden) and on the iPhone.
    @Entry public var padBrowser: BrowserModel? = nil
}

/// Clears what sites left on this device (cookies, storage, caches): sign-out, leaving the household, demo data.
public protocol WebsiteDataClearing: Sendable {
    /// Returns once the data is gone.
    @MainActor func clearAll() async
}

/// The built-in browser's own store: `WKWebsiteDataStore.default()`, persistent on this device so a site remembers its
/// sign-in between visits.
public struct WebKitWebsiteData: WebsiteDataClearing {
    public init() {}

    @MainActor public func clearAll() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// The iPad's built-in browser (step 10, Task 5): the saved sites' strip, the open site, and the Downloads tray beside
/// it. Every PDF the site downloads (an attachment, an inline PDF, a form POST, `<a download>`, a `blob:`) is captured
/// into the tray; so is a PDF shared into Mango from Safari or another app (`ingestShared`). Only `https` is loaded:
/// a saved site is checked again before it opens, and the web view cancels any other main-frame navigation.
///
/// Sign-in is typed or pasted on the site; Mango stores no password and no cookie (the web view's own store keeps
/// the session on this device until `purgeAll`). Closing a site clears nothing: the person stays signed in there
/// until sign-out, leaving the household or demo data, which call `purgeAll` (the tray emptied, the site data
/// cleared, both awaited).
@MainActor @Observable
public final class BrowserModel {
    /// A request for the web view to load `url`; a new `id` loads again.
    public struct LoadRequest: Equatable, Sendable {
        public let id: UUID
        public let url: URL
    }

    /// What the web view does with a navigation.
    public enum NavigationDecision: Equatable, Sendable { case allow, download, cancel }

    /// The browser is on screen (the iPad's root presents it over everything).
    public var isPresented = false
    public private(set) var sites: [SavedSite] = []
    /// Whether "Add site" and "Remove site" are offered: the store's say (Edit on Property for the household's sites).
    public private(set) var canEditSites = true
    /// Whether the tray's Check is offered: Edit on Property and Documents. True until `checkSource` says otherwise.
    public private(set) var canCheck = true
    public private(set) var currentSite: SavedSite?
    public private(set) var loadRequest: LoadRequest?
    /// The open page's host (the address bar shows it, read-only).
    public var currentHost: String?
    public var isLoading = false
    public var canGoBack = false
    public var canGoForward = false
    /// The tray, newest first: read on `reload`, and again after each capture or discard.
    public private(set) var downloadedItems: [TrayItem] = []
    /// The latest refusal or failure, said once in plain words ("That download isn't a PDF..."); nil when none.
    public var notice: String?

    /// Counts purges: a download started before the latest purge is dropped when it finishes.
    @ObservationIgnored public private(set) var generation = 0

    /// Back and forward, set by the web view while it is shown.
    @ObservationIgnored public var goBack: () -> Void = {}
    @ObservationIgnored public var goForward: () -> Void = {}

    @ObservationIgnored public let tray: DownloadsTray
    /// What the check-and-link sheet reads and saves with (step 10 Task 8); nil: Check only previews the file.
    @ObservationIgnored public var checkSource: CheckAndLinkSource?
    @ObservationIgnored private var store: any SavedSiteStore
    /// This device's own sites, still to move into `store` (step 10 Task 6); nil once moved, or with nothing to move.
    @ObservationIgnored private var adopting: LocalSavedSiteStore?
    @ObservationIgnored private let websiteData: any WebsiteDataClearing

    public init(tray: DownloadsTray, store: any SavedSiteStore, websiteData: any WebsiteDataClearing = WebKitWebsiteData()) {
        self.tray = tray
        self.store = store
        self.websiteData = websiteData
    }

    /// For the snapshot routes: the strip, an open site's host and the tray, as given.
    public func preload(sites: [SavedSite], current: SavedSite?, items: [TrayItem]) {
        self.sites = sites
        currentSite = current
        currentHost = current?.url.host
        downloadedItems = items
    }

    /// Keeps the sites in `store` from now on (the household's, once its database is open), first moving `local`'s
    /// sites into it when given: tried on each `reload` until the move is done (a refused write keeps them for later).
    public func use(_ store: any SavedSiteStore, adopting local: LocalSavedSiteStore? = nil) async {
        self.store = store
        adopting = local
        await reload()
    }

    /// Reads the saved sites and the tray again.
    public func reload() async {
        if let local = adopting, await SavedSiteAdoption.adopt(from: local, into: store) {
            adopting = nil
        }
        do {
            sites = try await store.all()
        } catch {
            notice = "The saved sites couldn't be read."
        }
        canEditSites = await store.canEdit()
        if let source = checkSource { canCheck = await source.offersCheck() }
        await refreshTray()
    }

    // MARK: Sites

    /// Shows the browser, opening `site` when given.
    public func present(_ site: SavedSite? = nil) {
        if let site { load(site) }
        isPresented = true
    }

    /// Opens `site`, if its address is https (checked again here: a stored address is never trusted as it is).
    public func load(_ site: SavedSite) {
        do {
            let url = try SavedSite.validate(site.url.absoluteString)
            currentSite = site
            currentHost = url.host
            notice = nil
            loadRequest = LoadRequest(id: UUID(), url: url)
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "That site can't be opened."
        }
    }

    /// Leaves the site. Nothing is cleared: the person stays signed in there.
    public func closeSite() {
        currentSite = nil
        currentHost = nil
        loadRequest = nil
        isLoading = false
        canGoBack = false
        canGoForward = false
    }

    /// The open site's address, for "Open in Safari".
    public var currentURL: URL? { loadRequest?.url }

    /// Saves a new site from what the person typed (https only), at the end of the strip, and returns it.
    @discardableResult
    public func addSite(name: String, address: String, kind: SavedSiteKind) async throws -> SavedSite {
        let url = try SavedSite.validate(address)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = SavedSite(name: trimmed.isEmpty ? (url.host ?? url.absoluteString) : trimmed, url: url, kind: kind,
                             sortOrder: (sites.map(\.sortOrder).max() ?? -1) + 1)
        try await store.save(site)
        sites = try await store.all()
        return site
    }

    public func removeSite(id: UUID) async {
        do {
            try await store.remove(id: id)
            sites = try await store.all()
            if currentSite?.id == id { closeSite() }
        } catch {
            notice = "The site couldn't be removed."
        }
    }

    // MARK: Downloads

    /// A download the web view finished into a temporary file: into the tray (PDFs only, once per sha256). The
    /// temporary file is gone afterwards, kept or refused. `generation` is the model's when the download started
    /// (nil: now): a download that outlived a purge is dropped, not kept.
    public func handleCapturedDownload(at url: URL, suggestedName: String, host: String?, generation started: Int? = nil) async {
        await ingest(url, suggestedName: suggestedName, host: host, generation: started ?? generation)
    }

    /// A file shared into Mango (More… ▸ Mango from Safari, or another app; it arrives in `Documents/Inbox`): the
    /// same tray ingest. The incoming copy is deleted, kept or refused. True when the tray took it.
    @discardableResult
    public func ingestShared(_ url: URL) async -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return await ingest(url, suggestedName: url.lastPathComponent, host: nil, generation: generation)
    }

    @discardableResult
    private func ingest(_ url: URL, suggestedName: String, host: String?, generation started: Int) async -> Bool {
        let tray = tray
        guard started == generation else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        let result = await Task.detached { () -> Result<TrayItem, Error> in
            let result = Result { try tray.ingest(fileAt: url, suggestedName: suggestedName, sourceHost: host) }
            // Refused (or failed): nothing of it stays outside the tray either.
            if case .failure = result { try? FileManager.default.removeItem(at: url) }
            return result
        }.value
        switch result {
        case .success(let item) where started != generation:
            // A purge ran meanwhile: the file doesn't stay.
            await Task.detached { tray.discard(item) }.value
            await refreshTray()
            return false
        case .success:
            notice = nil
            await refreshTray()
            return true
        case .failure(let error):
            notice = (error as? TrayError)?.errorDescription ?? "The download couldn't be kept."
            return false
        }
    }

    public func discard(_ item: TrayItem) async {
        let tray = tray
        await Task.detached { tray.discard(item) }.value
        await refreshTray()
    }

    public func fileURL(for item: TrayItem) -> URL { tray.fileURL(for: item) }

    /// Reads the tray again (after a file was checked and saved).
    public func refreshTray() async {
        let tray = tray
        downloadedItems = await Task.detached { tray.items() }.value
    }

    // MARK: Sign-out

    /// Sign-out, leaving the household, demo data: the tray emptied and the browser's website data cleared (awaited),
    /// the site closed. The saved sites stay (addresses only).
    public func purgeAll() async {
        generation += 1
        closeSite()
        let tray = tray
        await Task.detached { tray.purgeAll() }.value
        downloadedItems = []
        notice = nil
        await websiteData.clearAll()
    }

    // MARK: Policy (the web view's delegate asks)

    /// A navigation: a download the page asked for (`<a download>`, a `blob:`) is captured; the main frame loads only
    /// `https` (or `about:blank`); a frame inside the page may also be `about:`, `blob:` or `data:`.
    public nonisolated static func decision(for url: URL?, isMainFrame: Bool, shouldPerformDownload: Bool) -> NavigationDecision {
        guard let scheme = url?.scheme?.lowercased() else { return .cancel }
        if shouldPerformDownload { return downloadAllowed(url) ? .download : .cancel }
        if scheme == "https" { return .allow }
        if url?.absoluteString == "about:blank" { return .allow }
        if !isMainFrame, ["about", "blob", "data"].contains(scheme) { return .allow }
        return .cancel
    }

    /// A window the page opens (`target="_blank"`, `window.open`): loaded in the same web view under the main frame's
    /// rules, or captured when it is a download.
    public nonisolated static func newWindowDecision(for url: URL?, shouldPerformDownload: Bool) -> NavigationDecision {
        decision(for: url, isMainFrame: true, shouldPerformDownload: shouldPerformDownload)
    }

    /// Downloads come only from `https`, `blob:` or `data:` addresses.
    public nonisolated static func downloadAllowed(_ url: URL?) -> Bool {
        ["https", "blob", "data"].contains(url?.scheme?.lowercased() ?? "")
    }

    /// Whether a download announced at `expectedLength` bytes may start (unknown, -1, may: the tray checks the file).
    public nonisolated static func acceptsDownload(expectedLength: Int64) -> Bool {
        expectedLength <= Int64(DownloadsTray.defaultMaxBytes)
    }

    /// A response: a PDF (inline or as an attachment) or anything sent as an attachment, in the main frame, or anything
    /// the web view can't show, becomes a download (from an allowed address only: else cancelled); the rest is shown
    /// (an HTML error page stays a page). A PDF inside a frame is shown there.
    public nonisolated static func responseDecision(url: URL?, mimeType: String?, contentDisposition: String?, isMainFrame: Bool,
                                                    canShowMIMEType: Bool) -> NavigationDecision {
        let disposition = contentDisposition?.lowercased() ?? ""
        let downloads = (isMainFrame && (mimeType?.lowercased() == "application/pdf" || disposition.hasPrefix("attachment")))
            || !canShowMIMEType
        guard downloads else { return .allow }
        return downloadAllowed(url) ? .download : .cancel
    }
}
