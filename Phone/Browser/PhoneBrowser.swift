import Foundation
import UIKit
import BudgetCore
import MangoUI

/// The iPad's built-in browser for the app's life (step 10, Task 5): its Downloads tray in
/// `Application Support/Mango/Tray` (app-private, protected, excluded from backup), the sites saved on this device,
/// and the web view's own persistent website data. None on the iPhone.
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
