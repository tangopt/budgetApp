import SwiftUI
import BudgetCore
import MangoUI
import OSLog

/// The iPhone app's entry point. A snapshot build (`SNAPSHOTS`) runs only the snapshot harness, as the Mac's
/// `BudgetMain` does, so a stray snapshot build never opens the phone's real database; every other build is
/// just the app.
@main
enum PhoneMain {
    @MainActor
    static func main() {
        #if SNAPSHOTS
        // Phone/Snapshots/PhoneSnapshotRunner.swift: the demo database, every route, then exit.
        BundledFonts.register()
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

    init() {
        // The bundled typefaces (Phone/Fonts, the app's Fonts folder), before any text is drawn.
        BundledFonts.register()
    }

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
/// for the Mac while the household's zone doesn't exist yet, or while sync is off and nothing of the household's is
/// here: with Settings, Lock, Sync now and "Try with demo data").
///
/// Demo data (`PhoneDemoData`, on across launches until left): the demo database instead of the phone's own, sync
/// off, the "Demo data — not yours" banner over every screen, "Leave demo" in Settings. The lock still applies.
struct PhoneRoot: View {
    private enum Stage {
        case loading
        case ready(PhoneEnvironment, PhoneTabsModel)
        case failed(String)
    }

    @ObservedObject var lock: PhoneLockModel
    @ObservedObject var sync: PhoneSyncController
    /// The widget's snapshot and Settings ▸ Widgets (step 7b).
    @ObservedObject private var outputs = PhoneOutputs.shared
    @State private var stage: Stage = .loading
    @State private var showingSettings = false
    @State private var showingSalary = false
    /// Kept on this device (`SalaryDraftStore`); gone on leaving the household and with demo data.
    @State private var salary = SalaryComparisonViewModel(store: SalaryDraftStore())
    /// "Show what's here" on the iCloud explanation, for this run of the app.
    @State private var showsLocalData = false
    /// A PDF shared to Mango where it isn't collected (the iPhone, demo data): said once, then gone.
    @State private var sharedNotice: String?
    /// Settings' read-only Sharing section, read each time Settings opens.
    @State private var sharing: SharingSectionState?
    @AppStorage("phone.appearance") private var appearanceValue = PhoneAppearance.system.rawValue
    @AppStorage("phone.theme") private var themeId = PhoneTheme.classic.id
    /// The typeface app text is drawn in (step 16): this device's own choice, never synced.
    @AppStorage("phone.font") private var fontId = FontCatalog.defaultID
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
            case .ready(let environment, let tabs):
                content(environment, tabs)
                    .sheet(isPresented: $showingSettings) {
                        settings(environment, tabs)
                    }
                    .sheet(isPresented: $showingSalary) {
                        salarySheet
                    }
            case .failed(let message):
                ContentUnavailableView("Mango couldn't open its data", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            }
        }
        .lockCover(lock)
        .environment(\.phoneTheme, PhoneTheme.named(themeId))
        .environment(\.phoneTypeface, FontCatalog.font(id: fontId))
        .tint(PhoneTheme.named(themeId).accent)
        .preferredColorScheme(PhoneAppearance(storedValue: appearanceValue).colorScheme)
        .onChange(of: lock.state) { _, state in
            // The cover window dismisses open sheets in UIKit on a lock; their SwiftUI state is cleared here too, so
            // nothing re-presents after unlocking and the avatar opens Settings again.
            guard case .locked = state else {
                refreshOutputs()
                return
            }
            showingSettings = false
            showingSalary = false
            if case .ready(_, let tabs) = stage { tabs.dismissSheets() }
            // The browser closes too: nothing of a site shows behind the lock or after it.
            PhoneBrowser.shared?.isPresented = false
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                sync.sceneBecameActive()
                refreshOutputs()
            case .background: sync.sceneEnteredBackground()
            default: break
            }
        }
        .onChange(of: sync.householdNotice) { _, notice in
            // Removed from the household: the salary draft and the prefill leave with its data.
            if notice != nil { salary.forget() }
        }
        .onChange(of: sync.account) { _, account in
            // Signed in again: the explanation may show again if it goes once more.
            if account == .available { showsLocalData = false }
        }
        .task {
            guard case .loading = stage else { return }
            await load()
        }
        .onChange(of: outputs.pendingLink) { _, _ in openTappedReminder() }
        .alert(sharedNotice ?? "", isPresented: Binding(get: { sharedNotice != nil }, set: { if !$0 { sharedNotice = nil } })) {
            Button("OK", role: .cancel) { sharedNotice = nil }
        }
        .onOpenURL { url in
            // A PDF shared into Mango (More… ▸ Mango; the iPad's tray), copied by the system into Documents/Inbox.
            if url.isFileURL {
                let isDemo = if case .ready(let environment, _) = stage { environment.isDemo } else { PhoneDemoData.isOn }
                Task { sharedNotice = await PhoneBrowser.receiveShared(url, isDemo: isDemo) }
                return
            }
            // The widget's link: Home or Month, over whatever was open.
            guard let link = WidgetLink.tab(from: url), case .ready(_, let tabs) = stage else { return }
            showingSettings = false
            tabs.dismissSheets()
            tabs.open(link)
        }
    }

    /// A tapped reminder's tab, over whatever was open (waits until the tabs exist, on a cold start).
    private func openTappedReminder() {
        guard let link = outputs.pendingLink, case .ready(_, let tabs) = stage else { return }
        outputs.pendingLink = nil
        showingSettings = false
        tabs.dismissSheets()
        tabs.open(link)
    }

    /// The widget's snapshot written again for this device's viewer (nothing in demo data, which clears it).
    private func refreshOutputs() {
        guard case .ready(let environment, _) = stage, !environment.isDemo else { return }
        outputs.refresh(viewer: sync.deviceViewer)
    }

    /// Opens demo data while it is on, else the phone's own database (and attaches sync to it).
    private func load() async {
        do {
            // The device's writer (step 8; the iPhone too, step 7b): as this device's iCloud user, each committed write
            // asking sync for a push.
            let sync = self.sync
            let environment = PhoneDemoData.isOn
                ? try await PhoneEnvironment.loadDemo()
                : try await PhoneEnvironment.load(viewer: { sync.deviceViewer },
                                                  afterWrite: { Task { @MainActor in sync.localChange() } })
            // Property is absent only when the database has no property row; an unreadable answer keeps it.
            let hasProperty = await PhoneTabsModel.hasProperty(environment.dbQueue) ?? true
            // Whose figures: demo data's admin, else this iPhone's iCloud user (nobody's own until it is named).
            let viewer: PhoneViewer = environment.isDemo ? .demoAdmin : .iCloudUser(recordName: sync.viewerRecordName)
            // Edits write through the device writer; demo data's database is read-only: no writer.
            let tabs = PhoneTabsModel(dbQueue: environment.dbQueue, today: environment.today, hasProperty: hasProperty, viewer: viewer,
                                      writer: environment.isDemo ? nil : environment.writer)
            // This iPhone's iCloud user, as sync reads it: followed by the model, not by a view, because the content
            // is out of the view tree while locked and the name is usually read before the first unlock.
            if !environment.isDemo {
                tabs.follow(recordNames: sync.$viewerRecordName)
                // A quick edit moved figures: the widget and the reminders follow at once.
                tabs.afterEdit = { [outputs] in outputs.refresh(viewer: sync.deviceViewer) }
                // The iPad's Documents open a file by downloading it on demand (the iPhone has no such screen).
                if UIDevice.current.userInterfaceIdiom == .pad {
                    tabs.padDocuments.open = { path in try await sync.openDocument(storedRelativePath: path) }
                }
            }
            // The salary simulator: no drafts in demo data; otherwise the signed-in person's own latest pay as Current.
            salary.savesDrafts = !environment.isDemo
            salary.loadPrefill = { [weak tabs] in
                guard let tabs else { return (nil, nil) }
                return await tabs.salaryPrefill(today: environment.today())
            }
            stage = .ready(environment, tabs)
            await PhoneBrowser.attach(environment)
            await PhoneBrowser.sweepInbox(isDemo: environment.isDemo)
            outputs.attach(dbQueue: environment.dbQueue, today: environment.today, isDemo: environment.isDemo)
            refreshOutputs()
            openTappedReminder()
            if !environment.isDemo { await sync.attach(environment) }
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// "Try with demo data": sync stops, the flag goes on, and the demo database is built and shown.
    private func tryDemo() {
        showingSettings = false
        Task {
            await sync.enterDemo()
            salary.forget()
            PhoneDemoData.turnOn()
            stage = .loading
            await load()
        }
    }

    /// "Leave demo": the demo folder is deleted, the flag cleared, and the phone's own database opens again with
    /// sync.
    private func leaveDemo() {
        showingSettings = false
        stage = .loading
        Task {
            do {
                try await Task.detached { try PhoneDemoData.leave() }.value
            } catch {
                Self.log.error("The demo data couldn't be removed (\(String(describing: type(of: error)), privacy: .public))")
                // The flag goes anyway: the phone shows its own data; the folder is retried on the next leave.
                UserDefaults.standard.removeObject(forKey: PhoneDemoMode.defaultsKey)
            }
            // Demo data's sites, sessions and downloads go before the phone's own database opens.
            await PhoneBrowser.purge()
            sync.leaveDemo()
            salary.forget()
            await load()
        }
    }

    @ViewBuilder
    private func content(_ environment: PhoneEnvironment, _ tabs: PhoneTabsModel) -> some View {
        if environment.isDemo {
            if UIDevice.current.userInterfaceIdiom == .pad {
                PadRootView(tabs: tabs, syncStatus: .off, isDemo: true, salary: salary, onRefresh: {}, onSettings: { showingSettings = true })
            } else {
                PhoneTabs(model: tabs, syncStatus: .off, isDemo: true, onRefresh: {}, onSettings: { showingSettings = true })
            }
        } else if let joining = sync.joinState {
            // Joining the household (a member's device), or just removed from it.
            HouseholdJoinView(state: joining, onRetry: { sync.retryJoin() }, onStartAgain: { sync.startKeyExchangeAgain() },
                              onDismiss: { sync.dismissHouseholdNotice() })
        } else if let state = iCloudUnavailable {
            ICloudUnavailableView(state: state, onOpenSettings: openSettings, onShowLocal: { showsLocalData = true })
        } else if sync.isFirstDownload, case .syncing = sync.status {
            FirstDownloadView(received: sync.downloadedRecords)
        } else if waitsForTheMac(environment) {
            // Nothing of the household's here yet: the Mac hasn't shared the zone, or sync is off in this build.
            FirstDownloadView(received: 0, waiting: true, actions: waitingActions)
        } else {
            if UIDevice.current.userInterfaceIdiom == .pad {
                PadRootView(tabs: tabs, syncStatus: sync.status, lastSync: sync.lastSync, waitingChanges: sync.waitingChanges,
                            browser: PhoneBrowser.shared, salary: salary, onRefresh: { await sync.syncNow() },
                            onSettings: { showingSettings = true })
            } else {
                PhoneTabs(model: tabs, syncStatus: sync.status, lastSync: sync.lastSync, onRefresh: { await sync.syncNow() },
                          onSettings: { showingSettings = true })
            }
        }
    }

    /// Synced, yet nothing to download; or sync isn't running and the database holds none of the household's data.
    private func waitsForTheMac(_ environment: PhoneEnvironment) -> Bool {
        if sync.isFirstDownload, case .idle = sync.status { return true }
        return !sync.isRunning && !environment.hasRealData
    }

    private var waitingActions: FirstDownloadView.WaitingActions {
        FirstDownloadView.WaitingActions(onSettings: { showingSettings = true }, onLock: { lock.lock() },
                                         onSyncNow: sync.isRunning ? { await sync.syncNow() } : nil,
                                         onTryDemo: tryDemo)
    }

    /// Settings; its demo row offers demo data only while none of the household's data is here, and the way out
    /// while demo data is shown.
    private func settings(_ environment: PhoneEnvironment, _ tabs: PhoneTabsModel) -> some View {
        let demo: SettingsDemoRow? = environment.isDemo ? .leave(leaveDemo) : (environment.hasRealData ? nil : .tryIt(tryDemo))
        return SettingsSheet(appearance: appearance, themeId: $themeId, iCloud: sync.account, keyHeld: sync.keyHeld,
                             status: sync.status, version: Self.version, onLockNow: { lock.lock() },
                             onSyncNow: sync.isRunning ? { await sync.syncNow() } : nil, demo: demo, sharing: sharing,
                             outputs: $outputs.settings, notificationAccess: outputs.notificationAccess,
                             onAllowNotifications: { Task { await outputs.allowNotifications() } },
                             onOpenSalary: { showingSalary = true })
            .task { await outputs.refreshNotificationAccess() }
            .task { sharing = await SharingSectionState.load(environment.dbQueue, viewer: tabs.viewer) }
            .environment(\.showsDemoData, environment.isDemo)
            .environment(\.phoneTheme, PhoneTheme.named(themeId))
            .environment(\.phoneTypeface, FontCatalog.font(id: fontId))
            .preferredColorScheme(PhoneAppearance(storedValue: appearanceValue).colorScheme)
    }

    /// The salary simulator (opened from Settings' Tools): a tool, nothing of the household's data.
    private var salarySheet: some View {
        NavigationStack {
            SalarySimulatorScreen(viewModel: salary)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSalary = false } } }
        }
        .environment(\.phoneTheme, PhoneTheme.named(themeId))
        .environment(\.phoneTypeface, FontCatalog.font(id: fontId))
        .preferredColorScheme(PhoneAppearance(storedValue: appearanceValue).colorScheme)
    }

    private static let log = Logger(subsystem: "ubberninja.mango.ios", category: "Demo")

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return SettingsCopy.version(marketing: info?["CFBundleShortVersionString"] as? String,
                                    build: info?["CFBundleVersion"] as? String)
    }
}
