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

    /// A file shared into Mango (More… ▸ Mango; it arrives in `Documents/Inbox`): into the tray, and the browser shown
    /// with it. On the iPhone, or with demo data on, it isn't kept: the incoming copy is deleted.
    static func receiveShared(_ url: URL, isDemo: Bool) async {
        guard let browser = shared, !isDemo else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        await browser.ingestShared(url)
        browser.isPresented = true
    }
}
