import Foundation
import GRDB
@testable import BudgetCore
@testable import BudgetDemo
import TestSupport

/// The demo database (`DemoDatabase`, as of 2026-10-15) loaded the way the Mac's dashboard
/// loads it (`DashboardInput.load`), for the phone calculators' tests.
enum PhoneDemoFixture {
    static let today = DemoDatabase.defaultAsOf

    /// A fresh in-memory demo database; the caller removes `evidence`.
    static func build() throws -> (manager: DatabaseManager, evidence: URL) {
        let manager = try TestDatabase.migratedManager()
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneDemoEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try TestDatabase.fillDemo(manager.dbQueue, evidenceRoot: evidence)
        return (manager, evidence)
    }

    /// The input the Mac's dashboard builds.
    static func input(_ db: Database, today: Date = today) throws -> DashboardInput {
        try DashboardInput.load(db: db, today: today)
    }
}
