/// What the phone's cover window (the lock screen and the privacy cover, in a window above every sheet and alert)
/// does for a lock state and scene activity. Pure, so the decision is tested; the scene delegate applies it.
public enum CoverWindowPolicy {
    public struct State: Equatable, Sendable {
        /// Opaque over the app: while locked (or unlocking), and whenever the scene isn't active.
        public let isShown: Bool
        /// While shown it is VoiceOver's modal screen and takes touches; otherwise it is hidden from VoiceOver and lets
        /// every touch through, so the app's tabs are reachable.
        public let takesAccessibilityAndTouches: Bool
        /// A lock closes whatever the content presented (sheets, alerts), out of sight under the cover. Going to the
        /// app switcher doesn't.
        public let dismissesPresented: Bool
        /// The screen VoiceOver sees changed for an active scene: the cover came up or went away, or the scene came
        /// back to the lock screen.
        public let announcesScreenChange: Bool
    }

    /// `wasShown`, `wasActive`: the window's and the scene's state before this change.
    public static func state(locked: Bool, active: Bool, wasShown: Bool, wasActive: Bool = true) -> State {
        let shown = locked || !active
        let changedForAnActiveScene = active && (shown != wasShown || (shown && !wasActive))
        return State(isShown: shown, takesAccessibilityAndTouches: shown, dismissesPresented: locked,
                     announcesScreenChange: changedForAnActiveScene)
    }
}
