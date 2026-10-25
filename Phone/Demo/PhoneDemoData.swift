import Foundation
import BudgetCore
import BudgetDemo
import GRDB

/// "Try with demo data" (`PhoneDemoMode` holds the rules): the synthetic demo database built on this iPhone by
/// `DemoDatabase.build` into `Caches/Mango-Demo`, never the phone's own database (`Application Support/Mango`)
/// nor any app data, and opened read-only. The flag (`PhoneDemoMode.defaultsKey`) keeps it on across launches until
/// the person leaves it; leaving deletes the folder. Sync never runs while it is on (`PhoneSyncController`).
enum PhoneDemoData {
    /// Whether demo data is on (survives launches).
    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: PhoneDemoMode.defaultsKey)
    }

    static func turnOn() {
        UserDefaults.standard.set(true, forKey: PhoneDemoMode.defaultsKey)
    }

    /// `Caches/Mango-Demo`, checked against the phone's own database path (`PhoneDemoMode.folder`).
    nonisolated static func folder(fileManager: FileManager = .default) throws -> URL {
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let real = try PhoneDatabase.appFolder(fileManager: fileManager).appendingPathComponent(PhoneDatabasePolicy.fileName).path
        return try PhoneDemoMode.folder(in: caches, realDatabasePath: real, fileManager: fileManager)
    }

    /// Builds the demo database when it isn't there yet (a first try, or the system emptied Caches), then opens
    /// it read-only. Returns the queue and its path.
    nonisolated static func open() throws -> (DatabaseQueue, String) {
        let path = try PhoneDemoMode.prepare(folder: try folder()) { path, evidenceRoot in
            try DemoDatabase.build(at: path, evidenceRoot: evidenceRoot)
        }
        var configuration = Configuration()
        configuration.readonly = true
        return (try DatabaseQueue(path: path, configuration: configuration), path)
    }

    /// Leaving: deletes the folder and clears the flag.
    nonisolated static func leave() throws {
        try PhoneDemoMode.leave(folder: try folder(), defaults: .standard)
    }

    /// The day the demo takes as today (its figures are as of then).
    static var today: Date { DemoDatabase.defaultAsOf }
}
