import Foundation
import GRDB

/// "Try with demo data" on the iPhone: the synthetic demo database (`BudgetDemo`'s `DemoDatabase`), built on the
/// phone into its own folder, `Caches/Mango-Demo`, never the phone's database (`Application Support/Mango`) or any
/// other app data folder, opened read-only and shown in the ordinary screens under a "Demo data — not yours" banner.
/// While it is on, sync is off (no CloudKit, no Keychain); leaving deletes the folder.
///
/// The rules live here so they are tested; the app (`Phone/Demo`) supplies the folders and the builder.
public enum PhoneDemoMode {
    /// The `UserDefaults` flag: demo data is on, across launches, until the person leaves it.
    public static let defaultsKey = "phone.demoMode"
    /// The folder under the app's Caches that holds the demo database and its evidence.
    public static let folderName = "Mango-Demo"
    public static let fileName = "demo.sqlite"
    static let buildingSuffix = ".building"

    public enum Failure: LocalizedError, Equatable {
        /// The demo folder would be the real database's folder, inside it, around it, or app data.
        case notSeparate(String)
        /// The folder to delete isn't the demo folder.
        case notDemoFolder(String)
        /// What was built isn't the demo database.
        case notDemoDatabase

        public var errorDescription: String? {
            switch self {
            case .notSeparate: "The demo data's folder isn't separate from Mango's own data."
            case .notDemoFolder: "That folder isn't the demo data's."
            case .notDemoDatabase: "The demo data couldn't be built."
            }
        }
    }

    /// `<base>/Mango-Demo` (`base`: the app's Caches), refused when it is the real database's folder, inside it or
    /// around it, or app data (`TaxRegression.isAppData`). `realDatabasePath`: the phone's own `budget.sqlite`.
    public static func folder(in base: URL, realDatabasePath: String, fileManager: FileManager = .default) throws -> URL {
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        let demo = TaxRegression.resolvedPath(folder.path, fileManager: fileManager).lowercased()
        let realFolder = TaxRegression.resolvedPath(URL(fileURLWithPath: realDatabasePath).deletingLastPathComponent().path,
                                                    fileManager: fileManager).lowercased()
        let real = TaxRegression.resolvedPath(realDatabasePath, fileManager: fileManager).lowercased()
        let overlaps = demo == realFolder || demo.hasPrefix(realFolder + "/") || realFolder.hasPrefix(demo + "/")
            || real.hasPrefix(demo + "/")
        guard !overlaps, !TaxRegression.isAppData(folder.path, fileManager: fileManager) else {
            throw Failure.notSeparate(folder.path)
        }
        return folder
    }

    /// The demo database's path inside `folder`.
    public static func databasePath(in folder: URL) -> String {
        folder.appendingPathComponent(fileName).path
    }

    /// Whether `path` lies in a demo folder (any `…/Mango-Demo/…`).
    public static func isInDemoFolder(_ path: String, fileManager: FileManager = .default) -> Bool {
        let resolved = TaxRegression.resolvedPath(path, fileManager: fileManager)
        return URL(fileURLWithPath: resolved).pathComponents.dropLast().contains(folderName)
    }

    /// The demo database in `folder`, built when it isn't there (or isn't the demo's): `build(path, evidenceRoot)`
    /// (the app passes `DemoDatabase.build`) writes into a fresh `.building` file that only replaces the database
    /// once it carries the demo id (`DemoMarker`). Returns the database's path.
    public static func prepare(folder: URL, fileManager: FileManager = .default,
                               build: (_ path: String, _ evidenceRoot: URL) throws -> Void) throws -> String {
        guard folder.lastPathComponent == folderName else { throw Failure.notDemoFolder(folder.path) }
        let path = databasePath(in: folder)
        if DemoMarker.isDemoDatabase(atPath: path, fileManager: fileManager) { return path }
        if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder
        try? excluded.setResourceValues(values)
        let building = path + buildingSuffix
        try build(building, folder.appendingPathComponent("Evidence", isDirectory: true))
        guard DemoMarker.isDemoDatabase(atPath: building, fileManager: fileManager) else {
            try? fileManager.removeItem(at: folder)
            throw Failure.notDemoDatabase
        }
        try fileManager.moveItem(atPath: building, toPath: path)
        return path
    }

    /// Leaving demo data: deletes `folder` (only the demo's: named `Mango-Demo`) and clears the flag in `defaults`.
    public static func leave(folder: URL, defaults: UserDefaults, fileManager: FileManager = .default) throws {
        guard folder.lastPathComponent == folderName else { throw Failure.notDemoFolder(folder.path) }
        if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Why sync must not run on the database at `databasePath`, or nil. Demo data never syncs: not while demo
    /// mode is on, not a database in a demo folder, and not a demo database (`DemoMarker`) unless this is the
    /// developer's `--sync-demo` launch (`isSyncDemoLaunch`, which pulls the Development container's demo zone into
    /// a demo database and is itself gated by `SyncActivation`).
    public static func syncRefusal(databasePath: String, demoModeOn: Bool, isSyncDemoLaunch: Bool,
                                   fileManager: FileManager = .default) -> String? {
        if demoModeOn { return "Demo data is on: sync is off until it is left." }
        if isInDemoFolder(databasePath, fileManager: fileManager) {
            return "The database open is the demo data's: it never syncs."
        }
        if !isSyncDemoLaunch, DemoMarker.isDemoDatabase(atPath: databasePath, fileManager: fileManager) {
            return "The database open is a demo database: it never syncs."
        }
        return nil
    }

    /// Whether the phone's database holds the household's data: it has pulled once (a change token), or holds any
    /// synced row. Before that, the phone waits for the Mac and offers demo data.
    public static func hasRealData(db: Database) throws -> Bool {
        if try SyncEngineCore.hasChangeToken(db: db) { return true }
        return try PhoneDatabasePolicy.syncedRowCount(db: db) > 0
    }
}
