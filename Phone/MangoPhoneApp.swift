import SwiftUI
import MangoUI

/// The iPhone app's entry point. A snapshot build (`SNAPSHOTS`) runs only the snapshot harness, as the Mac's
/// `BudgetMain` does, so a stray snapshot build never opens the phone's real database; every other build is
/// just the app.
@main
enum PhoneMain {
    @MainActor
    static func main() {
        #if SNAPSHOTS
        // Phone/Snapshots/PhoneSnapshotRunner.swift: the demo database, every route, then exit.
        PhoneSnapshotRunner.main()
        #else
        MangoPhoneApp.main()
        #endif
    }
}

struct MangoPhoneApp: App {
    /// The scene delegate puts the lock screen and the privacy cover in a window above every sheet and alert.
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    /// Locked on launch (auth spec §10); one model for the app's life, shared with the cover window.
    @ObservedObject private var lock = PhoneLockModel.shared
    /// The sync status the tabs show (Task 12 replaces the placeholder with the sync controller).
    @StateObject private var sync = PhoneSyncStatusSource()

    var body: some Scene {
        WindowGroup {
            PhoneRoot(lock: lock, sync: sync)
        }
    }
}

/// Opens the database off the main thread, then shows the tabs behind the lock. The load runs outside the lock (it
/// shows nothing), so unlocking doesn't wait for it and relocking doesn't reopen the database; the content itself
/// is only in the view tree while unlocked. The tabs' model (every tab's view model and the selected tab) lives here,
/// above the lock cover, so a relock keeps where the person was; every sheet is presented inside it.
struct PhoneRoot: View {
    private enum Stage {
        case loading
        case ready(PhoneEnvironment, PhoneTabsModel)
        case failed(String)
    }

    let lock: PhoneLockModel
    @ObservedObject var sync: PhoneSyncStatusSource
    @State private var stage: Stage = .loading
    @State private var showingSettings = false

    var body: some View {
        Group {
            switch stage {
            case .loading:
                ProgressView()
            case .ready(_, let tabs):
                PhoneTabs(model: tabs, syncStatus: sync.status, onRefresh: { await sync.refresh() },
                          onSettings: { showingSettings = true })
                    .sheet(isPresented: $showingSettings) {
                        LockNowSheet(lock: lock)
                    }
            case .failed(let message):
                ContentUnavailableView("Mango couldn't open its data", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            }
        }
        .lockCover(lock)
        .task {
            guard case .loading = stage else { return }
            do {
                let environment = try await PhoneEnvironment.load()
                // Property is absent only when the database has no property row; an unreadable answer keeps it.
                let hasProperty = await PhoneTabsModel.hasProperty(environment.dbQueue) ?? true
                stage = .ready(environment, PhoneTabsModel(dbQueue: environment.dbQueue, today: environment.today,
                                                           hasProperty: hasProperty))
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}
