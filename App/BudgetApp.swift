import SwiftUI
import AppKit

/// The entry point. A snapshot build (`SNAPSHOTS`, made only by `scripts/render-snapshots.sh`)
/// runs the snapshot harness and nothing else — it refuses to start as the app, so a stray
/// snapshot build can never open the real database; every other build is just the app.
@main
enum BudgetMain {
    @MainActor
    static func main() {
        #if SNAPSHOTS
        guard SnapshotMode.isActive else {
            FileHandle.standardError.write(Data("This is a snapshot build of Budget: it only runs \(SnapshotMode.argument) (scripts/render-snapshots.sh).\n".utf8))
            exit(2)
        }
        SnapshotRunner.main()
        #else
        BudgetApp.main()
        #endif
    }
}

struct BudgetApp: App {
    var body: some Scene {
        WindowGroup {
            LaunchView()
                .themedRoot()
        }
        .commands {
            SearchCommands()
            ImportCommands()
        }
        // Budget ▸ Settings… (⌘,): Appearance and Theme.
        Settings {
            SettingsView()
                .themedRoot()
        }
    }
}

/// ⌘F's action for the focused window: its Search screen, with the field focused.
struct TransactionSearchAction {
    let perform: () -> Void
}

extension FocusedValues {
    /// Published per window by ContentView (`focusedSceneValue`).
    @Entry var transactionSearch: TransactionSearchAction?
}

/// Edit ▸ Search Transactions (⌘F), ahead of the standard Find items so ⌘F reaches it first.
/// Acts on the focused window only; off while that window shows a sheet or alert (⌘F then
/// stays with the sheet's own fields).
struct SearchCommands: Commands {
    @FocusedValue(\.transactionSearch) private var search
    @ObservedObject private var keyWindow = KeyWindowSheetState.shared

    var body: some Commands {
        CommandGroup(before: .textEditing) {
            Button("Search Transactions") { search?.perform() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(search == nil || keyWindow.isSheetKey)
            Divider()
        }
    }
}

/// Whether the key window is a sheet (or alert) or has one attached, kept current as windows
/// become and resign key.
@MainActor
final class KeyWindowSheetState: ObservableObject {
    static let shared = KeyWindowSheetState()
    @Published private(set) var isSheetKey = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private func refresh() {
        let window = NSApp.keyWindow
        let value = window.map { $0.isSheet || $0.attachedSheet != nil } ?? false
        if value != isSheetKey { isSheetKey = value }
    }
}
