import CloudKit
import SwiftUI
import UIKit
import Combine
import MangoUI

/// Gives the app's scene `PhoneSceneDelegate`, which owns the cover window.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = PhoneSceneDelegate.self
        return configuration
    }
}

/// The scene's lock and privacy cover (auth spec §10, plan step 4 Global Constraints). The lock screen and the opaque
/// cover live in their own window at a level above alerts, so every sheet, popover, menu and alert the content
/// presents sits under them:
/// - opaque while locked or unlocking, and from `sceneWillResignActive` until the scene is active again, so the
///   app-switcher snapshot is the cover;
/// - on a lock, the window shows first and then everything the content presented is dismissed, out of sight;
/// - on resigning active, any text field gives up focus, so the keyboard (a system window above this one) goes.
/// It also feeds the scene's activity to `PhoneLockModel` (background grace, re-checks) as UIKit reports it.
@MainActor
final class PhoneSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private var cover: UIWindow?
    private var lockObservation: AnyCancellable?
    /// The cover's and the scene's last state, for `CoverWindowPolicy`.
    private var wasShown = true
    private var wasActive = false
    private let lock = PhoneLockModel.shared
    private let activity = PhoneSceneActivity.shared

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // A cold start from the household invitation's link.
        if let metadata = connectionOptions.cloudKitShareMetadata { PhoneShareInbox.shared.receive(metadata) }
        let cover = UIWindow(windowScene: windowScene)
        cover.windowLevel = .alert + 1
        let host = UIHostingController(rootView: CoverWindowContent(lock: lock, activity: activity))
        // Opaque whenever it shows (it shows only to cover), even before SwiftUI has drawn the new state.
        host.view.backgroundColor = .systemBackground
        cover.rootViewController = host
        self.cover = cover
        update(locked: lock.state != .unlocked)
        // `$state` publishes before the change lands: the new value is passed along.
        lockObservation = lock.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.update(locked: state != .unlocked, stateLanded: false) }
        }
    }

    /// The household invitation (a CKShare link) was opened while the app runs: the sync controller accepts it.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        PhoneShareInbox.shared.receive(cloudKitShareMetadata)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        activity.isActive = false
        lock.sceneActivityChanged(isActive: false)
        (scene as? UIWindowScene)?.windows.forEach { $0.endEditing(true) }
        update(locked: lock.state != .unlocked)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        lock.sceneDidEnterBackground(now: .now())
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        lock.sceneWillEnterForeground(now: .now())
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        activity.isActive = true
        lock.sceneActivityChanged(isActive: true)
        update(locked: lock.state != .unlocked)
    }

    /// Applies `CoverWindowPolicy`: the cover window is opaque over the app while locked or not active, and then
    /// VoiceOver's modal screen and the target of touches; otherwise it is invisible, hidden from VoiceOver and lets
    /// every touch through. A lock dismisses whatever the content presented, after the window is up. A change an active
    /// scene's user can see is announced to VoiceOver. `stateLanded` false: called from `$state`, before the new state
    /// is set, so the content is drawn on the next pass, not now (drawn now, SwiftUI would keep the old state); the
    /// window is opaque meanwhile.
    private func update(locked: Bool, stateLanded: Bool = true) {
        guard let cover, let root = cover.rootViewController?.view else { return }
        let policy = CoverWindowPolicy.state(locked: locked, active: activity.isActive, wasShown: wasShown,
                                             wasActive: wasActive)
        wasShown = policy.isShown
        wasActive = activity.isActive
        // Always in the window list (a hidden window's SwiftUI content didn't redraw when shown again).
        cover.isHidden = false
        cover.alpha = policy.isShown ? 1 : 0
        cover.isUserInteractionEnabled = policy.takesAccessibilityAndTouches
        cover.accessibilityElementsHidden = !policy.takesAccessibilityAndTouches
        root.accessibilityElementsHidden = !policy.takesAccessibilityAndTouches
        root.accessibilityViewIsModal = policy.takesAccessibilityAndTouches
        if policy.isShown, stateLanded {
            root.setNeedsLayout()
            cover.layoutIfNeeded()
        }
        if policy.dismissesPresented, let scene = cover.windowScene {
            for window in scene.windows where window !== cover {
                if window.rootViewController?.presentedViewController != nil {
                    window.rootViewController?.dismiss(animated: false)
                }
            }
        }
        if policy.announcesScreenChange {
            // After the new state lands, so VoiceOver reads the lock screen (or the app), not the old frame.
            DispatchQueue.main.async {
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        }
    }
}
