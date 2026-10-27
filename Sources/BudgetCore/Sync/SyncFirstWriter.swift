import Foundation
import GRDB

/// The first run as a writer of a device that only read until now (the iPhone before step 7b). Whatever its
/// `syncPending` holds was queued while it was read-only, never a person's edit (a read-only device had no edit
/// screens), so it is dropped rather than pushed over what the Mac holds. Once per device: `defaultsKey` (a date in
/// `UserDefaults`, which never syncs) records that it has written.
public enum SyncFirstWriter {
    public static let defaultsKey = "sync.writerSince"

    /// Before the engine is made with `mode`. When `mode` writes and this device has never written: empties
    /// `syncPending` if the device `wasReadOnly` (an iPad that already wrote keeps its queue), records the date, and
    /// returns how many entries went (0 otherwise).
    public static func prepare(mode: SyncWriteMode, wasReadOnly: Bool, defaults: UserDefaults, db: some DatabaseWriter,
                               now: Date = Date()) async throws -> Int {
        guard mode.pushes, defaults.object(forKey: defaultsKey) == nil else { return 0 }
        let discarded = wasReadOnly ? try await db.write { db in
            try db.execute(sql: "DELETE FROM syncPending")
            return db.changesCount
        } : 0
        defaults.set(now, forKey: defaultsKey)
        return discarded
    }
}
