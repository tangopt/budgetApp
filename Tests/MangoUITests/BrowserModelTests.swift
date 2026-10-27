import XCTest
@testable import MangoUI
import BudgetCore
import TestSupport

/// Step 10 Task 5: the built-in browser opens https only, captures PDFs (and shared-in PDFs) into the tray, and
/// sign-out empties the tray and clears the website data. Local fixtures only; the real `WKDownload` path was
/// exercised by the spike.
@MainActor
final class BrowserModelTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("browser-tests-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private actor MemorySites: SavedSiteStore {
        var sites: [SavedSite] = []
        func all() async throws -> [SavedSite] { sites.sorted { $0.sortOrder < $1.sortOrder } }
        func save(_ site: SavedSite) async throws {
            _ = try SavedSite.validate(site.url.absoluteString)
            sites.removeAll { $0.id == site.id }
            sites.append(site)
        }
        func remove(id: UUID) async throws { sites.removeAll { $0.id == id } }
    }

    /// The household's sites as a member with View on Property sees them.
    private struct ViewOnlySites: SavedSiteStore {
        let sites: [SavedSite]
        func all() async throws -> [SavedSite] { sites }
        func save(_ site: SavedSite) async throws { throw AccessDenied(area: .property) }
        func remove(id: UUID) async throws { throw AccessDenied(area: .property) }
        func canEdit() async -> Bool { false }
    }

    private final class FakeWebsiteData: WebsiteDataClearing, @unchecked Sendable {
        var clears = 0
        @MainActor func clearAll() async { clears += 1 }
    }

    private func model(_ data: FakeWebsiteData = FakeWebsiteData()) -> BrowserModel {
        BrowserModel(tray: DownloadsTray(directory: folder.appendingPathComponent("Tray", isDirectory: true)),
                     store: MemorySites(), websiteData: data)
    }

    func testSignOutPurgesTrayAndWebsiteData() async throws {
        let data = FakeWebsiteData()
        let browser = model(data)
        let site = SavedSite(name: "Water", url: try SavedSite.validate("water.example.test"), kind: .utility, sortOrder: 0)
        browser.load(site)
        await browser.handleCapturedDownload(at: try WebFixtures.copy("bill.pdf"), suggestedName: "bill.pdf", host: "water.example.test")
        XCTAssertEqual(browser.downloadedItems.count, 1)

        await browser.purgeAll()

        XCTAssertEqual(browser.downloadedItems, [])
        XCTAssertEqual(browser.tray.items(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: browser.tray.directory.path), "nothing left on disk")
        XCTAssertEqual(data.clears, 1, "the website data cleared once, awaited")
        XCTAssertNil(browser.currentSite)
        XCTAssertNil(browser.loadRequest)
    }

    func testBrowserNeverLoadsNonHTTPSSite() throws {
        let browser = model()
        for address in ["http://water.example.test", "javascript:alert(1)", "file:///etc/hosts"] {
            let site = SavedSite(name: "Bad", url: URL(string: address)!, kind: .other, sortOrder: 0)
            browser.load(site)
            XCTAssertNil(browser.loadRequest, address)
            XCTAssertNil(browser.currentSite, address)
            XCTAssertNotNil(browser.notice, address)
        }
        let good = SavedSite(name: "Water", url: try SavedSite.validate("water.example.test/login"), kind: .utility, sortOrder: 0)
        browser.load(good)
        XCTAssertEqual(browser.loadRequest?.url.absoluteString, "https://water.example.test/login")
        XCTAssertEqual(browser.currentHost, "water.example.test")
        XCTAssertNil(browser.notice)
        browser.closeSite()
        XCTAssertNil(browser.loadRequest, "closing clears nothing but leaves the site")
    }

    func testNavigationPolicy() {
        func decide(_ text: String, main: Bool = true, download: Bool = false) -> BrowserModel.NavigationDecision {
            BrowserModel.decision(for: URL(string: text), isMainFrame: main, shouldPerformDownload: download)
        }
        XCTAssertEqual(decide("https://water.example.test/bills"), .allow)
        XCTAssertEqual(decide("http://water.example.test/bills"), .cancel)
        XCTAssertEqual(decide("javascript:alert(1)"), .cancel)
        XCTAssertEqual(decide("file:///etc/hosts"), .cancel)
        XCTAssertEqual(decide("data:text/html,hi"), .cancel, "not as the page")
        XCTAssertEqual(decide("data:text/html,hi", main: false), .allow, "inside the page")
        XCTAssertEqual(decide("blob:https://water.example.test/1234", download: true), .download, "<a download> of a blob")
        XCTAssertEqual(decide("https://water.example.test/bill.pdf", download: true), .download)
        XCTAssertEqual(decide("about:blank"), .allow)
        XCTAssertEqual(BrowserModel.decision(for: nil, isMainFrame: true, shouldPerformDownload: false), .cancel)
    }

    func testResponsePolicy() {
        func decide(_ mime: String?, _ disposition: String? = nil, main: Bool = true, canShow: Bool = true,
                    url: String = "https://water.example.test/bill") -> BrowserModel.NavigationDecision {
            BrowserModel.responseDecision(url: URL(string: url), mimeType: mime, contentDisposition: disposition, isMainFrame: main,
                                          canShowMIMEType: canShow)
        }
        XCTAssertEqual(decide("application/pdf"), .download, "inline PDF")
        XCTAssertEqual(decide("application/octet-stream", "Attachment; filename=bill.pdf"), .download)
        XCTAssertEqual(decide("text/html"), .allow, "an HTML error page stays a page")
        XCTAssertEqual(decide("application/zip", canShow: false), .download)
        XCTAssertEqual(decide("application/pdf", main: false), .allow, "a PDF inside a frame is shown")
        XCTAssertEqual(decide("application/pdf", url: "http://water.example.test/bill.pdf"), .cancel, "no download over http")
        XCTAssertEqual(decide("application/pdf", url: "blob:https://water.example.test/1"), .download)
    }

    func testDownloadsOnlyFromHTTPSBlobOrData() {
        func decide(_ text: String) -> BrowserModel.NavigationDecision {
            BrowserModel.decision(for: URL(string: text), isMainFrame: true, shouldPerformDownload: true)
        }
        XCTAssertEqual(decide("https://water.example.test/bill.pdf"), .download)
        XCTAssertEqual(decide("blob:https://water.example.test/1234"), .download)
        XCTAssertEqual(decide("data:application/pdf;base64,JVBERi0="), .download)
        XCTAssertEqual(decide("http://water.example.test/bill.pdf"), .cancel)
        XCTAssertEqual(decide("file:///tmp/bill.pdf"), .cancel)
        XCTAssertTrue(BrowserModel.acceptsDownload(expectedLength: -1), "unknown length: the tray checks the file")
        XCTAssertTrue(BrowserModel.acceptsDownload(expectedLength: 2_000_000))
        XCTAssertFalse(BrowserModel.acceptsDownload(expectedLength: Int64(DownloadsTray.defaultMaxBytes) + 1))
    }

    /// A download's redirect is held to the same rule: an https download redirected to http is cancelled.
    func testDownloadRedirectsHeldToHTTPS() {
        func redirect(_ text: String) -> BrowserModel.NavigationDecision {
            BrowserModel.downloadRedirectDecision(to: URL(string: text))
        }
        XCTAssertEqual(redirect("https://cdn.example.test/bill.pdf"), .allow)
        XCTAssertEqual(redirect("http://cdn.example.test/bill.pdf"), .cancel)
        XCTAssertEqual(redirect("file:///tmp/bill.pdf"), .cancel)
        XCTAssertEqual(redirect("ftp://cdn.example.test/bill.pdf"), .cancel)
        XCTAssertEqual(BrowserModel.downloadRedirectDecision(to: nil), .cancel)
    }

    func testNewWindowFollowsTheMainFrameRules() {
        func decide(_ text: String, download: Bool = false) -> BrowserModel.NavigationDecision {
            BrowserModel.newWindowDecision(for: URL(string: text), shouldPerformDownload: download)
        }
        XCTAssertEqual(decide("https://water.example.test/statement"), .allow, "loaded in the same web view")
        XCTAssertEqual(decide("http://water.example.test/statement"), .cancel)
        XCTAssertEqual(decide("javascript:void(0)"), .cancel)
        XCTAssertEqual(decide("data:text/html,hi"), .cancel)
        XCTAssertEqual(decide("https://water.example.test/bill.pdf", download: true), .download)
    }

    func testDownloadFinishingAfterAPurgeIsDropped() async throws {
        let browser = model()
        let started = browser.generation
        await browser.purgeAll()
        let file = try WebFixtures.copy("bill.pdf")
        await browser.handleCapturedDownload(at: file, suggestedName: "bill.pdf", host: "water.example.test", generation: started)
        XCTAssertEqual(browser.downloadedItems, [])
        XCTAssertEqual(browser.tray.items(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the late file is deleted, not kept")

        await browser.handleCapturedDownload(at: try WebFixtures.copy("bill.pdf"), suggestedName: "bill.pdf", host: nil,
                                             generation: browser.generation)
        XCTAssertEqual(browser.downloadedItems.count, 1, "a download started after the purge is kept")
    }

    func testDownloadOfPDFLandsInTray() async throws {
        let browser = model()
        let file = try WebFixtures.copy("bill.pdf")
        await browser.handleCapturedDownload(at: file, suggestedName: "bill.pdf", host: "water.example.test")
        XCTAssertEqual(browser.downloadedItems.map(\.fileName), ["bill.pdf"])
        XCTAssertEqual(browser.downloadedItems.first?.sourceHost, "water.example.test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "moved into the tray")
        XCTAssertNil(browser.notice)

        let page = try WebFixtures.copy("notpdf.pdf")
        await browser.handleCapturedDownload(at: page, suggestedName: "bill2.pdf", host: "water.example.test")
        XCTAssertEqual(browser.downloadedItems.count, 1, "an HTML page saved as .pdf is refused")
        XCTAssertEqual(browser.notice, TrayError.notAPDF.errorDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: page.path), "and not kept anywhere")
    }

    func testSharedPDFLeavesInboxForTheTray() async throws {
        let browser = model()
        let inbox = folder.appendingPathComponent("Documents/Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let shared = inbox.appendingPathComponent("statement.pdf")
        try FileManager.default.moveItem(at: try WebFixtures.copy("bill.pdf"), to: shared)

        let kept = await browser.ingestShared(shared)
        XCTAssertTrue(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path), "the Inbox copy is gone")
        XCTAssertEqual(browser.downloadedItems.map(\.fileName), ["statement.pdf"])
        XCTAssertNil(browser.downloadedItems.first?.sourceHost)

        let notPDF = inbox.appendingPathComponent("page.pdf")
        try FileManager.default.moveItem(at: try WebFixtures.copy("notpdf.pdf"), to: notPDF)
        let refused = await browser.ingestShared(notPDF)
        XCTAssertFalse(refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notPDF.path), "refused, and not left in Inbox")
        XCTAssertEqual(browser.downloadedItems.count, 1)
    }

    func testAddSiteChecksTheAddressAndAppends() async throws {
        let browser = model()
        do {
            try await browser.addSite(name: "Old", address: "http://old.example.test", kind: .other)
            XCTFail("http refused")
        } catch {
            XCTAssertEqual(error as? SavedSiteError, .notHTTPS)
        }
        try await browser.addSite(name: "Bank", address: "bank.example.test", kind: .bank)
        try await browser.addSite(name: " ", address: "tax.example.test/login", kind: .tax)
        XCTAssertEqual(browser.sites.map(\.name), ["Bank", "tax.example.test"])
        XCTAssertEqual(browser.sites.map(\.sortOrder), [0, 1])
        await browser.removeSite(id: browser.sites[0].id)
        XCTAssertEqual(browser.sites.map(\.name), ["tax.example.test"])
    }

    func testTrayRowSummary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = TrayItem(id: UUID(), fileName: "bill.pdf", sha256: "", byteCount: 120_000, receivedAt: now, sourceHost: "water.example.test")
        let summary = TrayListView.summary(item, now: now, calendar: calendar)
        XCTAssertTrue(summary.hasPrefix("water.example.test · "), summary)
        XCTAssertTrue(summary.hasSuffix("KB"), summary)
        var shared = item
        shared.sourceHost = nil
        XCTAssertTrue(TrayListView.summary(shared, now: now, calendar: calendar).hasPrefix("Shared to Mango"))
        XCTAssertEqual(TrayListView.title(count: 0), "Downloads")
        XCTAssertEqual(TrayListView.title(count: 2), "Downloads (2)")
    }

    /// Step 10 Task 6: the household's store replaces the device's, the device's sites moving into it once; without Edit
    /// the strip offers no Add or Remove.
    func testHouseholdStoreAdoptsLocalSitesAndHidesEditsWithoutEdit() async throws {
        let suite = "mango.tests.savedSites." + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let local = LocalSavedSiteStore(suiteName: suite)
        try await local.save(SavedSite(name: "Water", url: try SavedSite.validate("water.example.test"), kind: .utility, sortOrder: 0))
        let browser = model()
        let household = MemorySites()
        await browser.use(household, adopting: local)
        XCTAssertEqual(browser.sites.map(\.name), ["Water"])
        XCTAssertTrue(browser.canEditSites)
        let left = try await local.all()
        XCTAssertEqual(left, [], "moved once")

        let bank = SavedSite(name: "Bank", url: try SavedSite.validate("bank.example.test"), kind: .bank, sortOrder: 0)
        await browser.use(ViewOnlySites(sites: [bank]))
        XCTAssertEqual(browser.sites, [bank])
        XCTAssertFalse(browser.canEditSites, "Add and Remove are hidden")
    }

    /// Demo data's sites live in their own suite, never the device's (which the household adopts), and go on each purge
    /// (entering or leaving demo data, sign-out).
    func testDemoSitesKeptApartAndPurged() async throws {
        let suite = "mango.tests.savedSites." + UUID().uuidString
        let demoSuite = suite + ".demo"
        defer {
            UserDefaults().removePersistentDomain(forName: suite)
            UserDefaults().removePersistentDomain(forName: demoSuite)
        }
        let local = LocalSavedSiteStore(suiteName: suite)
        let browser = BrowserModel(tray: DownloadsTray(directory: folder.appendingPathComponent("Tray", isDirectory: true)),
                                   store: local, websiteData: FakeWebsiteData(), demoSites: LocalSavedSiteStore(suiteName: demoSuite))
        await browser.useDemoSites()
        try await browser.addSite(name: "Demo bank", address: "bank.example.test", kind: .bank)
        XCTAssertEqual(browser.sites.map(\.name), ["Demo bank"])
        let onDevice = try await local.all()
        XCTAssertEqual(onDevice, [], "the device's own sites (adopted by the household) never get demo sites")
        let household = MemorySites()
        await browser.use(household, adopting: local)
        XCTAssertEqual(browser.sites, [])

        await browser.purgeAll()
        let left = try await LocalSavedSiteStore(suiteName: demoSuite).all()
        XCTAssertEqual(left, [], "demo sites cleared")
        XCTAssertNotEqual(LocalSavedSiteStore.demoSuite, LocalSavedSiteStore.defaultSuite)
    }
}
