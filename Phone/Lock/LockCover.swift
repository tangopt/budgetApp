import SwiftUI
import UIKit
import BudgetCore
import MangoUI

/// Keeps the content out of the view tree while the app is locked: an empty background renders instead. What the
/// person sees over it (the lock screen, and the privacy cover while the scene isn't active) is in its own window
/// above every sheet and alert (`CoverWindowController`), so nothing presented from the content can show through.
struct LockCover: ViewModifier {
    @ObservedObject var model: PhoneLockModel

    func body(content: Content) -> some View {
        if model.state == .unlocked {
            content
        } else {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }
}

/// Whether the scene is in front, fed by `PhoneSceneDelegate` (UIKit's callbacks arrive before the app-switcher
/// snapshot is taken).
@MainActor
final class PhoneSceneActivity: ObservableObject {
    static let shared = PhoneSceneActivity()
    /// Not active until the scene says so: the cover is up from launch.
    @Published var isActive = false
}

/// What the cover window shows: the lock screen while locked, and over anything the opaque privacy cover while the
/// scene isn't active.
struct CoverWindowContent: View {
    @ObservedObject var lock: PhoneLockModel
    @ObservedObject var activity: PhoneSceneActivity
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            switch lock.state {
            case .unlocked:
                Color.clear
            case .locked(let availability):
                lockScreen(availability, isBusy: false)
            case .unlocking:
                lockScreen(lock.availability, isBusy: true)
            }
            if !activity.isActive {
                PrivacyCover()
                    .transition(.identity)
            }
        }
        .onChange(of: activity.isActive) { _, isActive in
            if isActive { offerBiometricsIfDue() }
        }
    }

    private func lockScreen(_ availability: MobileLockPolicy.Availability, isBusy: Bool) -> some View {
        LockScreen(availability: availability, icon: Image("LockIcon"), isBusy: isBusy,
                   onPrimary: { primary(availability) },
                   onSecondary: { Task { await lock.unlock(allowPasscodeOnly: true) } })
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .task {
                // The first appearance after a lock offers Face ID or Touch ID once, if the app is in front.
                if activity.isActive { offerBiometricsIfDue() }
            }
    }

    private func primary(_ availability: MobileLockPolicy.Availability) {
        if MobileLockPolicy.canAttemptUnlock(availability) {
            Task { await lock.unlock(allowPasscodeOnly: false) }
        } else if let settings = URL(string: UIApplication.openSettingsURLString) {
            openURL(settings)
        }
    }

    private func offerBiometricsIfDue() {
        guard lock.takeAutoPrompt() else { return }
        Task { await lock.unlock(allowPasscodeOnly: false) }
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
    /// Removes the content while `model` is locked (see `LockCover`).
    func lockCover(_ model: PhoneLockModel) -> some View {
        modifier(LockCover(model: model))
    }
}
