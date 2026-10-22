// App/LaunchView.swift
import SwiftUI
import AppKit

/// Root view of the main window. Shows the splash (icon, name, spinner) while
/// `AppEnvironment.load()` opens the database, then cross-fades to `ContentView` — or to the setup
/// flow while nobody can sign in yet (auth spec §6). The lock overlay is the root's (`lockOverlay`).
/// A setup failure stays on this screen with the error and a Quit button.
struct LaunchView: View {
    private enum Phase {
        case loading
        case ready(AppEnvironment)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    var body: some View {
        ZStack {
            switch phase {
            case .loading:
                splash {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Opening your budget…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            case .ready(let environment):
                SessionRoot(environment: environment, session: environment.session)
                    .transition(.opacity)
            case .failed(let message):
                splash(iconSize: 64, showsName: false) {
                    VStack(spacing: 10) {
                        Text("Couldn't open your budget")
                            .font(.headline)
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                        Button("Quit") { NSApp.terminate(nil) }
                            .padding(.top, 6)
                    }
                    .frame(maxWidth: 420)
                }
            }
        }
        .task {
            guard case .loading = phase else { return }
            do {
                let environment = try await AppEnvironment.load()
                withAnimation(.easeInOut(duration: 0.3)) { phase = .ready(environment) }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func splash<Footer: View>(iconSize: CGFloat = 104, showsName: Bool = true, @ViewBuilder footer: () -> Footer) -> some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
            if showsName {
                Text("Budget")
                    .font(.title2.weight(.medium))
            }
            footer()
        }
        .padding(32)
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
    }
}

/// Setup until someone can sign in, then the content (under the lock overlay while locked).
private struct SessionRoot: View {
    let environment: AppEnvironment
    @ObservedObject var session: SessionModel

    var body: some View {
        if session.state == .notSetUp {
            SetupFlowView(model: SetupModel(session: session))
                .transition(.opacity)
        } else {
            ContentView(environment: environment)
                .transition(.opacity)
        }
    }
}
