import Foundation
import UIKit
import BudgetCore
import MangoUI

/// The iPad's built-in browser for the app's life (step 10, Task 5): its Downloads tray in
/// `Application Support/Mango/Tray` (app-private, protected, excluded from backup), the household's saved sites
/// (`attach`), and the web view's own persistent website data. None on the iPhone.
@MainActor
enum PhoneBrowser {
    static let shared: BrowserModel? = UIDevice.current.userInterfaceIdiom == .pad
        ? BrowserModel(tray: DownloadsTray(directory: trayFolder), store: LocalSavedSiteStore())
        : nil

    /// `Application Support/Mango/Tray`; the tray makes it, protected, on its first download.
    private static var trayFolder: URL {
        let support = (try? PhoneDatabase.appFolder())
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mango")
        return support.appendingPathComponent("Tray", isDirectory: true)
    }

    /// The strip's sites once the database is open: the household's (step 10 Task 6: synced, each add and remove written
    /// through the device writer as Property), with the sites saved on this device before moved into them once. With
    /// demo data (read-only, never synced), demo data's own, apart from this device's (never adopted; cleared on purge).
    /// `leases`: the import lease of the sync engine running now (step 19: a statement imported on the iPad).
    static func attach(_ environment: PhoneEnvironment, leases: @escaping @Sendable () async -> (any ImportLeasing)?) async {
        guard let browser = shared else { return }
        if environment.isDemo {
            await browser.useDemoSites()
        } else {
            // Check and link (step 10 Task 8): the tray's files read as the Mac's import reads them, saved through the
            // device writer into this iPad's library.
            if let folder = try? PhoneDatabase.libraryFolder() {
                let library = EvidenceLibrary(root: folder, database: environment.dbQueue)
                // Step 19: a bank statement imported here under the household's import lease (the engine's device id).
                var statements: PadStatementImport?
                if let deviceId = try? await environment.dbQueue.write({ db in try LocalSetting.phoneDeviceId(db) }) {
                    let device = SyncDevice(id: deviceId, name: UIDevice.current.name)
                    statements = PadStatementImport(dbQueue: environment.dbQueue, library: library,
                                                    leases: CurrentEngineLeasing(device: device, current: leases))
                }
                browser.checkSource = CheckAndLinkSource(engine: CheckAndLink(dbQueue: environment.dbQueue, library: library),
                                                         writer: environment.writer, statements: statements)
            }
            await browser.use(GRDBSavedSiteStore(writer: environment.writer, reader: environment.dbQueue), adopting: LocalSavedSiteStore())
        }
    }

    /// Sign-out, leaving the household, demo data: the tray emptied and the website data cleared, awaited.
    static func purge() async {
        await shared?.purgeAll()
    }

    /// Said when a PDF is shared to Mango where there's no tray (the iPhone, demo data).
    static let notCollectedHere = "PDFs are collected on the iPad. Share it to Mango there; this copy wasn't kept."

    /// A file shared into Mango (More… ▸ Mango; it arrives in `Documents/Inbox`): into the tray, and the browser shown
    /// with it. On the iPhone, or with demo data on, it isn't kept: the incoming copy is deleted and the returned notice
    /// says why (nil when the tray took it, or said why not itself).
    static func receiveShared(_ url: URL, isDemo: Bool) async -> String? {
        guard let browser = shared, !isDemo else {
            try? FileManager.default.removeItem(at: url)
            return notCollectedHere
        }
        await browser.ingestShared(url)
        browser.isPresented = true
        return nil
    }

    /// At launch: whatever was left in `Documents/Inbox` (a share the app didn't finish taking) goes into the tray on
    /// the iPad (PDFs only); anything else, and everything on the iPhone or with demo data, is deleted. Inbox is backed
    /// up: nothing stays there.
    static func sweepInbox(isDemo: Bool) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            if let browser = shared, !isDemo {
                await browser.ingestShared(file)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
