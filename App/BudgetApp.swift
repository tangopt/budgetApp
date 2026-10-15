import SwiftUI

@main
struct BudgetApp: App {
    var body: some Scene {
        WindowGroup {
            LaunchView()
        }
        .commands {
            // Ahead of the standard Find items, so ⌘F reaches it first.
            CommandGroup(before: .textEditing) {
                Button("Search Transactions") {
                    NotificationCenter.default.post(name: .showTransactionSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Divider()
            }
        }
    }
}

extension Notification.Name {
    /// ⌘F: ContentView shows the Search screen and focuses its field.
    static let showTransactionSearch = Notification.Name("showTransactionSearch")
}
