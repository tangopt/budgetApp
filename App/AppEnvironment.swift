// App/AppEnvironment.swift
import Foundation
import BudgetCore
import GRDB

@MainActor
final class AppEnvironment: ObservableObject {
    let dbQueue: DatabaseQueue

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Budget", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("budget.sqlite").path

        let manager = try! DatabaseManager(path: dbPath)
        try! manager.migrate()
        try! manager.dbQueue.write { db in
            try CategorySeeder.seedDefaults(db)
        }
        self.dbQueue = manager.dbQueue
    }
}
