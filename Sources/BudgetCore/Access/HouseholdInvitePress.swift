import Foundation
import GRDB

extension HouseholdInvite {
    /// What pressing "Invite…" on the Mac comes to (`press`): every outcome the pane shows, none silent.
    public enum PressOutcome<Sheet> {
        /// The invite can't go yet: one line each (`HouseholdCopy.blocker`), shown under "Not yet:".
        case blocked([String])
        /// The share is made (or was already): the system share sheet opens for `sheet`.
        case present(SyncZoneShare, sheet: Sheet)
        /// The share is made but the sheet couldn't be prepared for it (`HouseholdCopy.shareFailed`).
        case sheetUnavailable(SyncZoneShare)
    }

    /// The Mac's "Invite…" (Settings ▸ Household): the local gate, then real sync must be running, then `invite` (the
    /// whole gate and the share), then `sheet` reads what the system share sheet needs (the `CKShare` and its container).
    /// Errors that aren't passing are thrown for the pane's error line.
    public static func press<Sheet>(running: Bool, transport: any SyncTransport & SyncShareTransport, keys: any SyncKeyStore,
                                    db: any DatabaseWriter, title: String, isolation: isolated (any Actor)? = #isolation,
                                    sheet: () async throws -> Sheet?) async throws -> PressOutcome<Sheet> {
        let local = try await db.read { db in try localBlockers(db: db) }
        guard local.isEmpty else { return .blocked(local.map { HouseholdCopy.blocker($0) }) }
        guard running else { return .blocked([HouseholdCopy.blocker(.syncNotOn)]) }
        let existed = (try? await transport.zoneShare(SyncZones.household)) != nil
        switch try await invite(transport: transport, keys: keys, db: db, title: title) {
        case .blocked(let found):
            return .blocked(found.map { HouseholdCopy.blocker($0, alreadyShared: existed) })
        case .share(let made):
            guard let ready = try await sheet() else { return .sheetUnavailable(made) }
            return .present(made, sheet: ready)
        }
    }
}
