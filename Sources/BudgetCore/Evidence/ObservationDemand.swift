import Foundation

/// Who currently needs a live database observation. A screen and the sheets it presents each
/// hold a named claim; the observation runs while any claim is held. Presenting a sheet can
/// fire the presenting screen's disappear, so a screen-only on/off switch would stop the
/// observation under the open sheet and leave it (and the screen behind it) stale.
public struct ObservationDemand: Equatable, Sendable {
    private var holders: Set<String> = []

    public init() {}

    public var isWanted: Bool { !holders.isEmpty }

    /// Claims or releases `holder`'s need; returns whether anything is still wanted.
    @discardableResult
    public mutating func set(_ holder: String, wanted: Bool) -> Bool {
        if wanted { holders.insert(holder) } else { holders.remove(holder) }
        return isWanted
    }
}
