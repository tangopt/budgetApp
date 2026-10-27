import Foundation

/// What a device's sync engine may write to the server (step 8).
/// - `full`: the Mac. It makes the zones, their keys and the import lease, rebuilds its person's summaries, and
///   pushes to every zone it syncs.
/// - `readOnly`: a phone or tablet whose user has no Edit (the iPhone always, before step 7b). It pulls only and
///   never writes to the server.
/// - `device(zones:)`: an iPad or (step 7b) an iPhone whose user has Edit somewhere. It pushes only records placed
///   in `zones` (of the zones it syncs); any other record stays pending, counted in `SyncPushReport.heldBack`.
///   Otherwise it is as read-only: it never makes a zone, a key or a lease, never rebuilds summaries, and never
///   deletes a file record a pull names. What it pulls is tracked as on the Mac (its own edits merge with what
///   arrives).
public enum SyncWriteMode: Equatable, Sendable {
    case full
    case readOnly
    case device(zones: Set<String>)

    /// Makes zones, keys and leases, rebuilds summaries and cleans files: the Mac only.
    var ownsZones: Bool { self == .full }

    /// Sends anything at all.
    var pushes: Bool { self != .readOnly }

    /// Of `followed` (the zones the device syncs), those it may push to.
    func pushZones(of followed: [String]) -> [String] {
        switch self {
        case .full: followed
        case .readOnly: []
        case .device(let zones): followed.filter { zones.contains($0) }
        }
    }
}
