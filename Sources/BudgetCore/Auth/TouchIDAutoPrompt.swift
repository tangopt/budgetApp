import Foundation

/// The lock screen starts Touch ID by itself, once per lock, when Mango is the active app and it is clear
/// who is signing in. This is only the decision; the app wires the events (lock, activation, results).
public struct TouchIDAutoPrompt: Equatable, Sendable {
    /// Whether this lock episode still needs a prompt: false once one was started and decided (or is running).
    private var needsPrompt = true
    private var running = false

    public init() {}

    /// Who to prompt: the last person signed in if enrolled on this Mac, otherwise the only enrolled person
    /// who can sign in, otherwise nobody (ambiguous or none enrolled).
    public static func user(lastSignedIn: Int64?, candidates: [Int64], enrolled: Set<Int64>, touchIDAvailable: Bool) -> Int64? {
        guard touchIDAvailable else { return nil }
        let eligible = candidates.filter(enrolled.contains)
        if let lastSignedIn, eligible.contains(lastSignedIn) { return lastSignedIn }
        return eligible.count == 1 ? eligible[0] : nil
    }

    /// A new lock: the next screen may prompt again.
    public mutating func lockBegan() {
        needsPrompt = true
        running = false
    }

    /// `otherStepInProgress`: a Touch ID or password attempt, or another step (recovery, new password, offer).
    public func shouldPrompt(isLocked: Bool, appIsActive: Bool, otherStepInProgress: Bool) -> Bool {
        isLocked && appIsActive && needsPrompt && !running && !otherStepInProgress
    }

    public mutating func promptStarted() { running = true }

    /// `decided`: the person answered (signed in, cancelled, or it failed) while Mango was active. A prompt
    /// that ended because the app went to the background wasn't decided, so activation asks again.
    public mutating func promptEnded(decided: Bool) {
        running = false
        if decided { needsPrompt = false }
    }
}
