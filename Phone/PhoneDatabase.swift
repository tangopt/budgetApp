import Foundation
import BudgetCore
import GRDB

/// Where the phone keeps its database, and how the file is protected (sync spec §9 "On devices"):
/// `Application Support/Mango/budget.sqlite` in the app's sandbox, file protection
/// `completeUntilFirstUserAuthentication` (readable by a background sync after the first unlock), excluded from
/// iCloud backup (the household's data comes back from CloudKit, sealed). Opening only migrates
/// (`PhoneDatabasePolicy`): nothing is seeded, matched or created before the first pull.
enum PhoneDatabase {
    /// The database's path. Simulator Debug builds take `BUDGET_DB_PATH` (a demo database for `--sync-demo`);
    /// every other build uses the app's own folder.
    nonisolated static func path(fileManager: FileManager = .default) throws -> String {
        #if DEBUG && targetEnvironment(simulator)
        if let override = ProcessInfo.processInfo.environment["BUDGET_DB_PATH"], !override.isEmpty {
            return override
        }
        #endif
        let folder = try appFolder(fileManager: fileManager)
        return folder.appendingPathComponent(PhoneDatabasePolicy.fileName).path
    }

    /// `Application Support/Mango`, created with its protection and backup exclusion. New files inside it (the
    /// database, its journal) take the folder's protection class.
    nonisolated static func appFolder(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var folder = support.appendingPathComponent(PhoneDatabasePolicy.folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try protect(&folder, fileManager: fileManager)
        return folder
    }

    /// Opens and migrates the database at `path`; protects the files when they are the app's own.
    nonisolated static func open(at path: String, fileManager: FileManager = .default) throws -> DatabaseQueue {
        let manager = try PhoneDatabasePolicy.open(at: path)
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        if let own = try? appFolder(fileManager: fileManager), own.standardizedFileURL.path == folder.standardizedFileURL.path {
            for name in [PhoneDatabasePolicy.fileName, PhoneDatabasePolicy.fileName + "-journal",
                         PhoneDatabasePolicy.fileName + "-wal", PhoneDatabasePolicy.fileName + "-shm"] {
                var file = folder.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: file.path) else { continue }
                try protect(&file, fileManager: fileManager)
            }
        }
        return manager.dbQueue
    }

    /// File protection `completeUntilFirstUserAuthentication` and no iCloud backup.
    nonisolated private static func protect(_ url: inout URL, fileManager: FileManager) throws {
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
