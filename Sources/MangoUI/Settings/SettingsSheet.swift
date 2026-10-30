import SwiftUI
import BudgetCore

/// Whether this iPhone's iCloud account can sync (CloudKit's account status, as the app reads it; `unknown`
/// before it is read or where this build can't ask).
public enum ICloudAccountState: Equatable, Sendable {
    case unknown, available, noAccount, restricted, couldNotDetermine

    /// No account, or restricted: the full-screen explanation (`ICloudUnavailableView`). A passing doubt
    /// (`couldNotDetermine`) never hides the data.
    public var isUnavailable: Bool { self == .noAccount || self == .restricted }
}

/// Light, dark, or as the system is.
public enum PhoneAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }

    /// A stored value, else `.system`.
    public init(storedValue: String) {
        self = PhoneAppearance(rawValue: storedValue) ?? .system
    }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// For `.preferredColorScheme` (nil: the system's).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Settings' words (the sync status's own come from `SyncStatusCopy`).
public enum SettingsCopy {
    public static func iCloudAccount(_ state: ICloudAccountState) -> String {
        switch state {
        case .unknown: "Not checked"
        case .available: "Signed in"
        case .noAccount: "Not signed in"
        case .restricted: "Restricted on this iPhone"
        case .couldNotDetermine: "Couldn't check just now"
        }
    }

    /// "0.2.0 (1)".
    public static func version(marketing: String?, build: String?) -> String {
        guard let marketing else { return "Unknown" }
        guard let build else { return marketing }
        return "\(marketing) (\(build))"
    }
}

/// Settings' demo data row: offered while this iPhone has none of the household's data yet, or the way out while
/// demo data is shown. Absent once real data is here.
public enum SettingsDemoRow {
    case tryIt(() -> Void)
    case leave(() -> Void)
}

/// "Me" on the iPhone (design review I16; plan step 4 Task 12 as Settings), opened from Home's avatar, presented inside the lock: the person and
/// sync first, the Salary calculator, Appearance
/// (System / Light / Dark) and the theme set (`ThemePickerSection`, the eight `ThemeSet`s, step 8); Sharing (read-only, `SharingSection`); Widgets (`WidgetsSection`); Notifications (`NotificationsSection`); Security (Lock now, the iCloud account, whether records are sealed with the
/// household key or it is still awaited); About (version, build, font licences).
/// Read-only phone: nothing here changes the household's data.
public struct SettingsSheet: View {
    @Binding var appearance: PhoneAppearance
    /// The theme set's id (`ThemeSet`): one choice for the palette and the fonts.
    @Binding var themeSetId: String
    let iCloud: ICloudAccountState
    /// Whether this iPhone holds the household key (nil: sync is off here).
    let keyHeld: Bool?
    let status: SyncStatus
    let version: String
    let now: () -> Date
    let onLockNow: () -> Void
    /// Nil while sync is off here: no "Sync now".
    let onSyncNow: (() async -> Void)?
    /// "Try with demo data" or "Leave demo"; nil once the household's data is here.
    let demo: SettingsDemoRow?
    /// The read-only Sharing section (step 6); nil while it hasn't been read (left out).
    let sharing: SharingSectionState?
    /// This iPhone's output settings (step 7b, Widgets); nil leaves the section out.
    let outputs: Binding<PhoneOutputSettings>?
    /// Settings ▸ Notifications (step 7b): what the system allows, and "Allow notifications" (nil: no such row).
    let notificationAccess: NotificationAuthorization
    let onAllowNotifications: (() -> Void)?
    /// The salary calculator, pushed inside this sheet (nil: no such row; the iPad has it in its sidebar).
    let salary: SalaryComparisonViewModel?
    /// The signed-in person's name, for the profile row (nil: "This iPhone").
    let personName: String?
    /// "Me" on the iPhone (design review I16), "Settings" where the iPad opens it.
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme
    @State private var syncing = false

    public init(appearance: Binding<PhoneAppearance>, themeSetId: Binding<String>, iCloud: ICloudAccountState, keyHeld: Bool?,
                status: SyncStatus, version: String, now: @escaping () -> Date = { Date() }, onLockNow: @escaping () -> Void,
                onSyncNow: (() async -> Void)?, demo: SettingsDemoRow? = nil, sharing: SharingSectionState? = nil,
                outputs: Binding<PhoneOutputSettings>? = nil, notificationAccess: NotificationAuthorization = .notDetermined,
                onAllowNotifications: (() -> Void)? = nil, salary: SalaryComparisonViewModel? = nil,
                personName: String? = nil, title: String = "Settings") {
        self.salary = salary
        self.personName = personName
        self.title = title
        self.notificationAccess = notificationAccess
        self.onAllowNotifications = onAllowNotifications
        self.demo = demo
        self.sharing = sharing
        self.outputs = outputs
        _appearance = appearance
        _themeSetId = themeSetId
        self.iCloud = iCloud
        self.keyHeld = keyHeld
        self.status = status
        self.version = version
        self.now = now
        self.onLockNow = onLockNow
        self.onSyncNow = onSyncNow
    }

    public var body: some View {
        NavigationStack {
            List {
                profileSection
                if let demo {
                    demoSection(demo)
                }
                if let salary {
                    Section {
                        NavigationLink {
                            SalarySimulatorScreen(viewModel: salary)
                                .demoBannerSlot()
                        } label: {
                            Label("Salary calculator", systemImage: "percent")
                                .frame(minHeight: 44)
                        }
                    }
                }
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(PhoneAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: 44)
                }
                ThemePickerSection(themeSetId: $themeSetId)
                if let sharing {
                    SharingSection(state: sharing)
                }
                if let outputs {
                    WidgetsSection(settings: outputs)
                    NotificationsSection(settings: outputs, authorization: notificationAccess, isAdmin: sharing?.isAdmin ?? false,
                                         onAllow: { onAllowNotifications?() })
                }
                Section("Security") {
                    Button {
                        dismiss()
                        onLockNow()
                    } label: {
                        Label("Lock now", systemImage: "lock")
                            .frame(minHeight: 44)
                    }
                    LabeledContent("iCloud", value: SettingsCopy.iCloudAccount(iCloud))
                        .frame(minHeight: 44)
                    Label {
                        Text(SyncStatusCopy.householdKey(held: keyHeld))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        // Waiting isn't failing: the same secondary colour either way.
                        Image(systemName: keyHeld == true ? "lock.shield" : "key")
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
                Section("About") {
                    LabeledContent("Version", value: version)
                        .frame(minHeight: 44)
                    NavigationLink("Font licences") { FontLicencesView() }
                        .frame(minHeight: 44)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .demoBannerSlot()
            .mangoNavigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Who is signed in and how sync is doing (design review I16: person and sync first), with "Sync now" while sync runs.
    private var profileSection: some View {
        Section {
            HStack(spacing: MangoSpacing.s) {
                Image(systemName: "person.crop.circle.fill")
                    .mangoFont(.largeTitle)
                    .foregroundStyle(theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(personName ?? "This iPhone").mangoFont(.headline).fixedSize(horizontal: false, vertical: true)
                    SyncStatusLine(status: status, now: now())
                    if let detail = SyncStatusCopy.detail(status) {
                        Text(detail)
                            .mangoFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            if let onSyncNow {
                Button {
                    syncing = true
                    Task {
                        await onSyncNow()
                        syncing = false
                    }
                } label: {
                    HStack {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        if syncing {
                            Spacer()
                            ProgressView()
                        }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(syncing)
            }
        }
    }

    @ViewBuilder
    private func demoSection(_ demo: SettingsDemoRow) -> some View {
        switch demo {
        case .tryIt(let action):
            Section {
                Button {
                    dismiss()
                    action()
                } label: {
                    Label("Try with demo data", systemImage: "theatermasks")
                        .frame(minHeight: 44)
                }
            } header: {
                Text("Demo data")
            } footer: {
                Text("See Mango with made-up figures while this iPhone waits for the Mac. Nothing is synced while demo data is on.")
            }
        case .leave(let action):
            Section {
                Button(role: .destructive) {
                    dismiss()
                    action()
                } label: {
                    Label("Leave demo", systemImage: "xmark.circle")
                        .frame(minHeight: 44)
                }
            } header: {
                Text("Demo data")
            } footer: {
                Text("The figures shown are made up, not yours. Leaving deletes them and turns sync back on.")
            }
        }
    }
}
