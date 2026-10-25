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

/// Settings (plan step 4 Task 12), opened from Home's avatar, presented inside the lock: Lock now; Appearance and the
/// theme (`ThemeCatalog`'s, as `PhoneTheme.all`); Security (the iCloud account, whether records are sealed with the
/// household key or it is still awaited); About (version, build, the sync status line, "Sync now" while sync runs).
/// Read-only phone: nothing here changes the household's data.
public struct SettingsSheet: View {
    @Binding var appearance: PhoneAppearance
    @Binding var themeId: String
    let iCloud: ICloudAccountState
    /// Whether this iPhone holds the household key (nil: sync is off here).
    let keyHeld: Bool?
    let status: SyncStatus
    let version: String
    let now: () -> Date
    let onLockNow: () -> Void
    /// Nil while sync is off here: no "Sync now".
    let onSyncNow: (() async -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var syncing = false

    public init(appearance: Binding<PhoneAppearance>, themeId: Binding<String>, iCloud: ICloudAccountState, keyHeld: Bool?,
                status: SyncStatus, version: String, now: @escaping () -> Date = { Date() }, onLockNow: @escaping () -> Void,
                onSyncNow: (() async -> Void)?) {
        _appearance = appearance
        _themeId = themeId
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
                Section {
                    Button {
                        dismiss()
                        onLockNow()
                    } label: {
                        Label("Lock now", systemImage: "lock")
                            .frame(minHeight: 44)
                    }
                }
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(PhoneAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: 44)
                    Picker("Theme", selection: $themeId) {
                        ForEach(PhoneTheme.all) { Text($0.name).tag($0.id) }
                    }
                    .frame(minHeight: 44)
                }
                Section("Security") {
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
                    VStack(alignment: .leading, spacing: 4) {
                        SyncStatusLine(status: status, now: now())
                        if let detail = SyncStatusCopy.detail(status) {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(minHeight: 44)
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
            .navigationTitle("Settings")
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
}
