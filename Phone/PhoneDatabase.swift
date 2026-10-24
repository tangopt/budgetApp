import Foundation
import BudgetCore
import GRDB

/// `BUDGET_DB_PATH` named something the phone won't open (`PhoneDatabasePolicy.overrideRefusal`).
struct PhoneDatabaseOverrideRefused: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// Where the phone keeps its database, and how the file is protected (sync spec §9 "On devices"):
/// `Application Support/Mango/budget.sqlite` in the app's sandbox, file protection
/// `completeUntilFirstUserAuthentication` (readable by a background sync after the first unlock), excluded from
/// iCloud backup (the household's data comes back from CloudKit, sealed). Opening only migrates
/// (`PhoneDatabasePolicy`): nothing is seeded, matched or created before the first pull.
enum PhoneDatabase {
    /// Where the database is, and whether it is the app's own (protected, excluded from backup).
    struct Location: Sendable {
        let path: String
        let isAppsOwn: Bool
    }

    /// The database's location. Simulator Debug builds take `BUDGET_DB_PATH`, but only a demo database outside
    /// any app data (`PhoneDatabasePolicy.overrideRefusal`), refused before anything opens it; every other build
    /// uses the app's own folder.
    nonisolated static func location(fileManager: FileManager = .default) throws -> Location {
        #if DEBUG && targetEnvironment(simulator)
        if let override = ProcessInfo.processInfo.environment["BUDGET_DB_PATH"], !override.isEmpty {
            if let reason = PhoneDatabasePolicy.overrideRefusal(path: override, fileManager: fileManager) {
                throw PhoneDatabaseOverrideRefused(reason: reason)
            }
            return Location(path: override, isAppsOwn: false)
        }
        #endif
        let folder = try appFolder(fileManager: fileManager)
        return Location(path: folder.appendingPathComponent(PhoneDatabasePolicy.fileName).path, isAppsOwn: true)
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

    /// Opens and migrates the database at `location`; protects the files when they are the app's own. A failure
    /// to protect them throws (the root view shows it) rather than leaving them unprotected.
    nonisolated static func open(_ location: Location, fileManager: FileManager = .default) throws -> DatabaseQueue {
        let manager = try PhoneDatabasePolicy.open(at: location.path)
        let folder = URL(fileURLWithPath: location.path).deletingLastPathComponent()
        if location.isAppsOwn {
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
