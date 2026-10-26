import Foundation
import GRDB

/// How one-off tools (and the tool paths in BudgetCore: rehearsals, dry runs, planning copies) open a database
/// file: with the connection settings the app's own `DatabaseManager` uses. Today that is
/// `PRAGMA recursive_triggers = ON`, without which a `REPLACE` that removes a row with another rowid fires no
/// delete trigger, so the sync tombstone waited for the app's next open (step 3 follow-up).
public enum ToolDatabase {
    /// `configuration` with the app's connection settings added (its own `prepareDatabase` still runs first).
    public static func configuration(_ base: Configuration = Configuration()) -> Configuration {
        var configuration = base
        // A row that `REPLACE` removes fires delete triggers (sync tombstones) only with this on.
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA recursive_triggers = ON") }
        return configuration
    }

    /// Opens the database at `path` (created when missing, unless `configuration` is read only).
    /// A writable one writes as the household's admin outside `ActorWrite.perform` (`ActorWrite.useDefaultWriter`).
    public static func open(path: String, configuration: Configuration = Configuration()) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path, configuration: self.configuration(configuration))
        if !configuration.readonly {
            try queue.write { db in try ActorWrite.useDefaultWriter(appUserId: nil, db: db) }
        }
        return queue
    }
}
