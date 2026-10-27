import Foundation
import GRDB

/// The iPad sidebar's "N changes waiting" (step 10, Task 5): this device's changes not yet taken by the server, in the
/// zones it may push to. A change placed in a zone the device doesn't push to is not counted (it never goes from
/// here), nor anything on a read-only device.
public enum SyncWaitingChanges {
    public static func count(db: Database, mode: SyncWriteMode) throws -> Int {
        guard try db.tableExists("syncPending") else { return 0 }
        switch mode {
        case .readOnly:
            return 0
        case .full:
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending") ?? 0
        case .device(let zones):
            guard !zones.isEmpty else { return 0 }
            let placement = SyncEngineCore.placement(try SyncZoneRouter(db: db), override: nil, db: db)
            var count = 0
            for uuid in try String.fetchAll(db, sql: "SELECT uuid FROM syncPending") {
                // A record the router can't place yet waits where it is: not counted until it can be.
                if let zone = (try? placement.zones(uuid)) ?? nil, zones.contains(zone) { count += 1 }
            }
            return count
        }
    }
}
