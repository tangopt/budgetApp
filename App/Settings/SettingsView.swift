// App/Settings/SettingsView.swift
import Combine
import SwiftUI
import BudgetCore

/// Budget ▸ Settings… (⌘,): Appearance (System / Light / Dark) and Theme (the swatch grid) —
/// both apply immediately, app-wide, and are remembered (`appAppearance`, `appTheme`) — and
/// Evidence (the source folders scanned for documents), Sign-in (auth spec §6), Sharing (my tax years and income; each
/// account's owner and level are set in the account itself) and Sync (turning sync on, its status).
struct SettingsView: View {
    enum Pane: Hashable { case appearance, theme, evidence, signIn, sharing, sync, household }
    @State private var pane: Pane
    @ObservedObject private var navigation = SettingsNavigation.shared
    private let signInModel: SignInSettingsModel?
    private let sharingModel: SharingSettingsModel?
    /// Snapshot routes: the Household pane from values (always shown).
    private let householdState: HouseholdPaneState?
    private let householdDraft: PermissionGrid?
    @StateObject private var admin = SettingsAdminWatch()

    /// `signInModel`, `sharingModel`: snapshot routes only.
    init(pane: Pane = .appearance, signInModel: SignInSettingsModel? = nil, sharingModel: SharingSettingsModel? = nil,
         householdState: HouseholdPaneState? = nil, householdDraft: PermissionGrid? = nil) {
        self.householdState = householdState
        self.householdDraft = householdDraft
        _pane = State(initialValue: pane)
        self.signInModel = signInModel
        self.sharingModel = sharingModel
    }

    var body: some View {
        TabView(selection: $pane) {
            Tab("Appearance", systemImage: "circle.lefthalf.filled", value: Pane.appearance) {
                AppearanceSettings()
            }
            Tab("Theme", systemImage: "paintpalette", value: Pane.theme) {
                ThemeSettings()
            }
            Tab("Evidence", systemImage: "folder.badge.gearshape", value: Pane.evidence) {
                EvidenceSourcesSettings()
            }
            Tab("Sign-in", systemImage: "person.badge.key", value: Pane.signIn) {
                SignInSettings(model: signInModel)
            }
            Tab(SharingCopy.paneTitle, systemImage: "person.2.badge.key", value: Pane.sharing) {
                SharingSettings(model: sharingModel)
            }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath.icloud", value: Pane.sync) {
                SyncSettings()
            }
            // Admin only.
            if admin.isAdmin || householdState != nil {
                Tab(HouseholdCopy.paneTitle, systemImage: "person.2.circle", value: Pane.household) {
                    if let householdState {
                        HouseholdPane(state: householdState, draft: householdDraft)
                    } else {
                        HouseholdSettings()
                    }
                }
            }
        }
        .scenePadding()
        .frame(width: 640)
        // Opened for a pane (the sidebar's sync row): show it.
        .onChange(of: navigation.request, initial: true) { _, request in
            guard let request else { return }
            pane = request.pane
            navigation.done(request)
        }
    }
}

/// Whether the person signed in on this Mac is the household's admin (Settings ▸ Household is theirs).
@MainActor
final class SettingsAdminWatch: ObservableObject {
    @Published private(set) var isAdmin = false
    private var environmentWatch: AnyCancellable?
    private var sessionWatch: AnyCancellable?

    init() {
        environmentWatch = AppEnvironment.Current.shared.$environment.sink { [weak self] environment in
            self?.watch(environment)
        }
    }

    private func watch(_ environment: AppEnvironment?) {
        guard let session = environment?.session else { isAdmin = false; sessionWatch = nil; return }
        sessionWatch = session.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self, weak session] _ in
            self?.isAdmin = session?.currentUser?.isAdmin == true
        }
        isAdmin = session.currentUser?.isAdmin == true
    }
}

/// Asks the Settings window for a pane (the sidebar's "Sync needs attention" opens Settings ▸ Sync).
@MainActor
final class SettingsNavigation: ObservableObject {
    struct Request: Equatable {
        let pane: SettingsView.Pane
        /// Tells apart two requests for the same pane.
        let serial: Int
    }

    static let shared = SettingsNavigation()
    @Published private(set) var request: Request?

    private var serial = 0

    func show(_ pane: SettingsView.Pane) {
        serial += 1
        request = Request(pane: pane, serial: serial)
    }

    /// The Settings window showed it: a later opening keeps the pane it was on.
    func done(_ shown: Request) {
        if request == shown { request = nil }
    }
}

/// System / Light / Dark (moved from the sidebar). `ThemedRoot` applies the choice.
private struct AppearanceSettings: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Form {
            Picker("Appearance:", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            Text("System follows the macOS appearance. Each theme has a light and a dark version.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }
}

/// Every theme as a swatch card; clicking one applies it.
private struct ThemeSettings: View {
    @AppStorage(Theme.storageKey) private var themeID = ThemePalette.defaultID

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Theme.all) { theme in
                    Button { themeID = theme.id } label: {
                        ThemeSwatchCard(theme: theme, isSelected: theme.id == Theme.named(themeID).id)
                    }
                    .buttonStyle(.plain)
                    .help("Use the \(theme.name) theme")
                }
            }
            .padding(4)
        }
        .frame(height: 470)
    }
}

/// A theme's card: its name over a miniature grid drawn in its own colours (header, a section
/// band, plain and striped rows, a group row, the Net totals row; income, expense and pending
/// amounts) and its first chart colours, outlined in its accent when selected. Drawn in the
/// current appearance's variant, like the app.
struct ThemeSwatchCard: View {
    let theme: Theme
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            preview
            HStack(spacing: 4) {
                ForEach(0..<min(theme.chartSeries.count, 8), id: \.self) { index in
                    Circle().fill(theme.series(index)).frame(width: 7, height: 7)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent)
                }
            }
            Text(theme.name).font(.callout.weight(isSelected ? .semibold : .regular))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? theme.accent.opacity(0.10) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? theme.accent : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Category").bold()
                Spacer()
                Text("Oct").bold().figureText()
            }
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(theme.gridHeaderBackground)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.primary.opacity(0.18)), alignment: .bottom)

            HStack {
                Text("INCOME").font(.system(size: 7, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 5)
            .frame(height: 12)
            .background(theme.sectionHeaderTint)

            row("Salary", stripe: theme.income, background: .clear) {
                Text("£3,200").foregroundStyle(theme.income)
            }
            row("Rent", stripe: theme.expense, background: theme.rowStripe) {
                Text("−£1,450").foregroundStyle(theme.expense)
            }
            row("Bills", bold: true, stripe: theme.expense, background: theme.groupRowTint) {
                HStack(spacing: 2) {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 6))
                    Text("−£86").italic()
                }
                .foregroundStyle(theme.pending)
            }
            row("Net", bold: true, stripe: theme.totalsStripe, background: theme.totalsNetTint) {
                Text("£1,664").foregroundStyle(theme.income).bold()
            }
        }
        .font(.system(size: 9).monospacedDigit())
        .background(theme.windowFill)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func row<Amount: View>(_ name: String, bold: Bool = false, stripe: Color, background: Color, @ViewBuilder amount: () -> Amount) -> some View {
        HStack(spacing: 0) {
            Text(name).fontWeight(bold ? .bold : .regular).lineLimit(1)
            Spacer(minLength: 4)
            amount().figureText()
        }
        .padding(.leading, 6).padding(.trailing, 5)
        .frame(height: 15)
        .background(background)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .bottom)
        .overlay(Rectangle().frame(width: 2).foregroundStyle(stripe), alignment: .leading)
    }
}
