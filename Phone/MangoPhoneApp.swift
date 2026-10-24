import SwiftUI

/// The iPhone app's entry point. A snapshot build (`SNAPSHOTS`) runs only the snapshot harness, as the Mac's
/// `BudgetMain` does, so a stray snapshot build never opens the phone's real database; every other build is
/// just the app.
@main
enum PhoneMain {
    @MainActor
    static func main() {
        #if SNAPSHOTS
        // The phone's snapshot harness arrives with its routes; until then a snapshot build does nothing.
        FileHandle.standardError.write(Data("This is a snapshot build of Mango for iPhone: it only runs the snapshot harness.\n".utf8))
        exit(2)
        #else
        MangoPhoneApp.main()
        #endif
    }
}

struct MangoPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            PhoneRoot()
        }
    }
}

/// Opens the database off the main thread, then shows the app. The lock comes in front of this later.
struct PhoneRoot: View {
    private enum Stage {
        case loading
        case ready(PhoneEnvironment)
        case failed(String)
    }

    @State private var stage: Stage = .loading

    var body: some View {
        Group {
            switch stage {
            case .loading:
                ProgressView()
            case .ready:
                Text("Mango")
                    .font(.largeTitle.bold())
            case .failed(let message):
                ContentUnavailableView("Mango couldn't open its data", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            }
        }
        .task {
            guard case .loading = stage else { return }
            do {
                stage = .ready(try await PhoneEnvironment.load())
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}
