import Foundation

/// What happens to the sheets, alerts and dialogs a lock covered when the cover lifts (auth spec §6):
/// the person they were open for gets them back as they were; anyone else never sees them, so they end.
public enum LockCoverPolicy {
    public enum Outcome: Equatable, Sendable {
        case restore
        case dismiss
    }

    /// `coveredFor`: who was signed in when the cover went up; `signedIn`: who is signed in now.
    public static func onUncover(coveredFor: Int64?, signedIn: Int64?) -> Outcome {
        guard let coveredFor, let signedIn, coveredFor == signedIn else { return .dismiss }
        return .restore
    }

    /// The frame (screen coordinates) a sheet takes while a lock covers it: the whole content area of
    /// the window it hangs from (`contentLayoutRect` is in that window's own coordinates), so the lock
    /// screen in it reaches the window's edges and nothing of the sheet's own frame shows beside it.
    /// Never smaller than the sheet itself.
    public static func coveringFrame(sheet: CGRect, parent: CGRect, contentLayoutRect: CGRect) -> CGRect {
        let area = CGRect(x: parent.minX + contentLayoutRect.minX, y: parent.minY + contentLayoutRect.minY,
                          width: contentLayoutRect.width, height: contentLayoutRect.height)
        guard area.width >= sheet.width, area.height >= sheet.height else { return sheet.union(area) }
        return area
    }

    /// What a covered window shows: the lock screen, or a plain backdrop with nothing on it.
    public enum Cover: Equatable, Sendable {
        case lockScreen
        case backdrop
    }

    /// A window and the sheets stacked on it show one lock screen between them, in the top one: it's the one that
    /// takes the keyboard (a window with a sheet on it can't). Every window under a sheet shows a backdrop, so the
    /// lock screen isn't drawn twice, once in the window and again in its sheet.
    public static func cover(hasSheetAbove: Bool) -> Cover {
        hasSheetAbove ? .backdrop : .lockScreen
    }

    /// What a window that is neither the main window nor a sheet (Settings, any viewer window) does while locked.
    public enum AuxiliaryWindow: Equatable, Sendable {
        /// Ordered out: the main window carries the one lock screen.
        case hide
        /// Stays up and shows the lock screen: with no main window open it is the only place to unlock.
        case carryLock
    }

    /// The whole app shows exactly one lock screen, in the main window. With the main window open, every other
    /// window is hidden. With it closed, the window that has a lock overlay (Settings) carries the lock screen so
    /// there is somewhere to unlock; a window without an overlay is hidden regardless (it would show its content).
    public static func auxiliaryWindow(mainWindowOpen: Bool, hasLockOverlay: Bool) -> AuxiliaryWindow {
        mainWindowOpen || !hasLockOverlay ? .hide : .carryLock
    }

    /// What a hidden window does when the lock lifts.
    public enum AuxiliaryReturn: Equatable, Sendable {
        /// Ordered back in as it was (same frame, same tab).
        case orderBack
        /// Stays closed: it was another person's.
        case stayClosed
    }

    public static func auxiliaryOnUncover(coveredFor: Int64?, signedIn: Int64?) -> AuxiliaryReturn {
        onUncover(coveredFor: coveredFor, signedIn: signedIn) == .restore ? .orderBack : .stayClosed
    }
}
