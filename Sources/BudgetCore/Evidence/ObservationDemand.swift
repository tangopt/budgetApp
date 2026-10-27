import Foundation

/// Who currently needs a live database observation. A screen and the sheets it presents each
/// hold a named claim; the observation runs while any claim is held. Presenting a sheet can
/// fire the presenting screen's disappear, so a screen-only on/off switch would stop the
/// observation under the open sheet and leave it (and the screen behind it) stale.
public struct ObservationDemand: Equatable, Sendable {
    private var holders: Set<String> = []

    public init() {}

    public var isWanted: Bool { !holders.isEmpty }

    /// A claim name of its own for one appearance of a screen. Two screens can share one model (Missing evidence
    /// standalone and in Tax years): switching between them fires the incoming screen's appear before the outgoing
    /// one's disappear, so a shared name would let the outgoing screen's release stop the incoming screen's
    /// observation, leaving it showing the other screen's list.
    public static func screenClaim() -> String { "screen-\(UUID().uuidString)" }

    /// Claims or releases `holder`'s need; returns whether anything is still wanted.
    @discardableResult
    public mutating func set(_ holder: String, wanted: Bool) -> Bool {
        if wanted { holders.insert(holder) } else { holders.remove(holder) }
        return isWanted
    }
}
