import SwiftUI
import UIKit
import Combine

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
    private let lock = PhoneLockModel.shared
    private let activity = PhoneSceneActivity.shared

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let cover = UIWindow(windowScene: windowScene)
        cover.windowLevel = .alert + 1
        let host = UIHostingController(rootView: CoverWindowContent(lock: lock, activity: activity))
        // Opaque whenever it shows (it shows only to cover), even before SwiftUI has drawn the new state.
        host.view.backgroundColor = .systemBackground
        host.view.accessibilityViewIsModal = true
        cover.rootViewController = host
        self.cover = cover
        update(locked: lock.state != .unlocked)
        // `$state` publishes before the change lands: the new value is passed along.
        lockObservation = lock.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.update(locked: state != .unlocked, stateLanded: false) }
        }
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

    /// Shows the cover window while locked or not active; hides it otherwise. A lock dismisses whatever the content
    /// presented, after the window is up. `stateLanded` false: called from `$state`, before the new state is set, so
    /// the content is drawn on the next pass, not now (drawn now, SwiftUI would keep the old state); the window is
    /// opaque meanwhile.
    private func update(locked: Bool, stateLanded: Bool = true) {
        guard let cover else { return }
        let show = locked || !activity.isActive
        // Always in the window list (alpha 0 when not needed: invisible, and touches pass to the window below).
        cover.isHidden = false
        cover.alpha = show ? 1 : 0
        if show, stateLanded {
            cover.rootViewController?.view.setNeedsLayout()
            cover.layoutIfNeeded()
        }
        if locked, let scene = cover.windowScene {
            for window in scene.windows where window !== cover {
                if window.rootViewController?.presentedViewController != nil {
                    window.rootViewController?.dismiss(animated: false)
                }
            }
        }
    }
}
