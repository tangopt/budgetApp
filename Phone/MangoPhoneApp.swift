import SwiftUI
import BudgetCore
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
    /// Sync: the scheduler, its status, the iCloud account (Task 12).
    @StateObject private var sync = PhoneSyncController()

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
///
/// In front of the tabs, while it applies: the iCloud explanation (no account, or restricted; "Show what's here" goes
/// to the tabs for this run of the app), then the first download (before this iPhone's first pull lands, or waiting
/// for the Mac while the household's zone doesn't exist yet).
struct PhoneRoot: View {
    private enum Stage {
        case loading
        case ready(PhoneEnvironment, PhoneTabsModel)
        case failed(String)
    }

    @ObservedObject var lock: PhoneLockModel
    @ObservedObject var sync: PhoneSyncController
    @State private var stage: Stage = .loading
    @State private var showingSettings = false
    /// "Show what's here" on the iCloud explanation, for this run of the app.
    @State private var showsLocalData = false
    @AppStorage("phone.appearance") private var appearanceValue = PhoneAppearance.system.rawValue
    @AppStorage("phone.theme") private var themeId = PhoneTheme.classic.id
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private var appearance: Binding<PhoneAppearance> {
        Binding(get: { PhoneAppearance(storedValue: appearanceValue) }, set: { appearanceValue = $0.rawValue })
    }

    private var iCloudUnavailable: ICloudAccountState? {
        guard !showsLocalData else { return nil }
        if sync.account.isUnavailable { return sync.account }
        if sync.status == .unavailable(.noICloudAccount) { return .noAccount }
        return nil
    }

    var body: some View {
        Group {
            switch stage {
            case .loading:
                ProgressView()
            case .ready(_, let tabs):
                content(tabs)
                    .sheet(isPresented: $showingSettings) {
                        settings
                    }
            case .failed(let message):
                ContentUnavailableView("Mango couldn't open its data", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            }
        }
        .lockCover(lock)
        .environment(\.phoneTheme, PhoneTheme.named(themeId))
        .tint(PhoneTheme.named(themeId).accent)
        .preferredColorScheme(PhoneAppearance(storedValue: appearanceValue).colorScheme)
        .onChange(of: lock.state) { _, state in
            // The cover window dismisses open sheets in UIKit on a lock; their SwiftUI state is cleared here too, so
            // nothing re-presents after unlocking and the avatar opens Settings again.
            guard case .locked = state else { return }
            showingSettings = false
            if case .ready(_, let tabs) = stage { tabs.dismissSheets() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: sync.sceneBecameActive()
            case .background: sync.sceneEnteredBackground()
            default: break
            }
        }
        .onChange(of: sync.account) { _, account in
            // Signed in again: the explanation may show again if it goes once more.
            if account == .available { showsLocalData = false }
        }
        .task {
            guard case .loading = stage else { return }
            do {
                let environment = try await PhoneEnvironment.load()
                // Property is absent only when the database has no property row; an unreadable answer keeps it.
                let hasProperty = await PhoneTabsModel.hasProperty(environment.dbQueue) ?? true
                stage = .ready(environment, PhoneTabsModel(dbQueue: environment.dbQueue, today: environment.today,
                                                           hasProperty: hasProperty))
                await sync.attach(environment)
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private func content(_ tabs: PhoneTabsModel) -> some View {
        if let state = iCloudUnavailable {
            ICloudUnavailableView(state: state, onOpenSettings: openSettings, onShowLocal: { showsLocalData = true })
        } else if sync.isFirstDownload, case .syncing = sync.status {
            FirstDownloadView(received: sync.downloadedRecords)
        } else if sync.isFirstDownload, case .idle = sync.status {
            // Synced, yet nothing to download: the Mac hasn't shared the household's zone.
            FirstDownloadView(received: 0, waiting: true)
        } else {
            PhoneTabs(model: tabs, syncStatus: sync.status, lastSync: sync.lastSync, onRefresh: { await sync.syncNow() },
                      onSettings: { showingSettings = true })
        }
    }

    private var settings: some View {
        SettingsSheet(appearance: appearance, themeId: $themeId, iCloud: sync.account, keyHeld: sync.keyHeld,
                      status: sync.status, version: Self.version, onLockNow: { lock.lock() },
                      onSyncNow: sync.isRunning ? { await sync.syncNow() } : nil)
            .environment(\.phoneTheme, PhoneTheme.named(themeId))
            .preferredColorScheme(PhoneAppearance(storedValue: appearanceValue).colorScheme)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return SettingsCopy.version(marketing: info?["CFBundleShortVersionString"] as? String,
                                    build: info?["CFBundleVersion"] as? String)
    }
}
