import Foundation
import UIKit
import BudgetCore
import GRDB
import MangoUI

/// The iPhone's import of statements and documents from Files (spec 2026-10-31): the same engines as the iPad's Check
/// and link, with an inbox of its own (`Application Support/Mango/ImportInbox`, app-private, protected, out of backups).
@MainActor
enum PhoneImportSetup {
    /// Gives `tabs` the import's source once the database is open; none with demo data (nothing is written there).
    static func attach(_ environment: PhoneEnvironment, tabs: PhoneTabsModel, leases: @escaping @Sendable () async -> (any ImportLeasing)?) async {
        guard !environment.isDemo, let support = try? PhoneDatabase.appFolder(), let folder = try? PhoneDatabase.libraryFolder() else {
            tabs.phoneImport.source = nil
            return
        }
        let dbQueue = environment.dbQueue
        let library = EvidenceLibrary(root: folder, database: dbQueue)
        var statements: PadStatementImport?
        if let deviceId = try? await dbQueue.write({ db in try LocalSetting.phoneDeviceId(db) }) {
            let device = SyncDevice(id: deviceId, name: UIDevice.current.name)
            statements = PadStatementImport(dbQueue: dbQueue, library: library, leases: CurrentEngineLeasing(device: device, current: leases))
        }
        tabs.phoneImport.source = PhoneImportSource(
            inbox: ImportInbox(directory: support.appendingPathComponent("ImportInbox", isDirectory: true)),
            engine: CheckAndLink(dbQueue: dbQueue, library: library),
            writer: environment.writer,
            statements: statements,
            accounts: {
                let accounts = (try? await dbQueue.read { db in try Account.fetchAll(db) }) ?? []
                return accounts.compactMap { account in account.id.map { PhoneImportAccount(id: $0, name: account.displayName) } }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            },
            uncategorised: { runIds in
                (try? await dbQueue.read { db in try PhoneImportBatch.uncategorisedRows(runIds: runIds, db: db) }) ?? 0
            })
    }
}
