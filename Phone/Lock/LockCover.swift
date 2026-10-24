import SwiftUI
import UIKit
import BudgetCore
import MangoUI

/// The phone's root lock modifier. While locked it renders `LockScreen` instead of the content (the content is
/// not in the view tree at all); while the scene isn't active it puts an opaque cover with the app's icon on top,
/// so the app-switcher snapshot never shows a figure. It also feeds the scene's phase changes to the model.
struct LockCover: ViewModifier {
    @ObservedObject var model: PhoneLockModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        ZStack {
            switch model.state {
            case .unlocked:
                // Under the inactive cover the content stays in the tree; VoiceOver must not read it there.
                content
                    .accessibilityHidden(scenePhase != .active)
            case .locked(let availability):
                lockScreen(availability, isBusy: false)
            case .unlocking:
                lockScreen(model.availability, isBusy: true)
            }
            if scenePhase != .active {
                PrivacyCover()
                    .transition(.identity)
            }
        }
        .onChange(of: scenePhase) { old, new in
            model.sceneActivityChanged(isActive: new == .active)
            if new == .background {
                model.sceneDidEnterBackground(now: .now())
            } else if old == .background {
                model.sceneWillEnterForeground(now: .now())
            }
            if new == .active { offerBiometricsIfDue() }
        }
    }

    private func lockScreen(_ availability: MobileLockPolicy.Availability, isBusy: Bool) -> some View {
        LockScreen(availability: availability, icon: Image("LockIcon"), isBusy: isBusy,
                   onPrimary: { primary(availability) },
                   onSecondary: { Task { await model.unlock(allowPasscodeOnly: true) } })
            .task {
                // The first appearance after a lock offers Face ID or Touch ID once, if the app is in front.
                if scenePhase == .active { offerBiometricsIfDue() }
            }
    }

    private func primary(_ availability: MobileLockPolicy.Availability) {
        if MobileLockPolicy.canAttemptUnlock(availability) {
            Task { await model.unlock(allowPasscodeOnly: false) }
        } else if let settings = URL(string: UIApplication.openSettingsURLString) {
            openURL(settings)
        }
    }

    private func offerBiometricsIfDue() {
        guard model.takeAutoPrompt() else { return }
        Task { await model.unlock(allowPasscodeOnly: false) }
    }
}

/// Opaque: the system background and the app's icon, nothing else.
private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Image("LockIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Locks the whole app behind `model` (see `LockCover`).
    func lockCover(_ model: PhoneLockModel) -> some View {
        modifier(LockCover(model: model))
    }
}
