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
    /// Locked on launch (auth spec §10); one model for the app's life, so nothing else needs to know about it.
    @StateObject private var lock = PhoneLockModel()

    var body: some Scene {
        WindowGroup {
            PhoneRoot(lock: lock)
        }
    }
}

/// Opens the database off the main thread, then shows the app behind the lock. The load runs outside the lock (it
/// shows nothing), so unlocking doesn't wait for it and relocking doesn't reopen the database; the content itself
/// is only in the view tree while unlocked.
struct PhoneRoot: View {
    private enum Stage {
        case loading
        case ready(PhoneEnvironment)
        case failed(String)
    }

    let lock: PhoneLockModel
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
        .lockCover(lock)
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
