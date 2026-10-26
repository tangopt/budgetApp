// App/Snapshots/SharingSnapshots.swift
#if SNAPSHOTS
import SwiftUI
import BudgetCore
import GRDB

/// The sharing routes (step 6 Task 10), on the demo's synthetic data (`DemoSharing`: Person A the admin, "A", owning
/// every account but the joint one). Settings ▸ Sharing before the sheet and the sheet itself use a copy of the demo
/// with its owners taken back off; the member's routes sign in as Person B (an app user with no password, made in the
/// demo copy) for that route only (`SnapshotSession` signs the snapshot user back in before the next).
@MainActor
enum SharingSnapshots {
    static var routes: [SnapshotRoute] {
        [
            SnapshotRoute(name: "settings-sharing-setup", title: "Settings ▸ Sharing, before the owners are set") { context in
                let copy = try await unconfirmedCopy(context)
                return AnyView(SnapshotStandaloneCanvas(content: SettingsView(pane: .sharing, sharingModel: SharingSettingsModel(dbQueue: copy))))
            },
            SnapshotRoute(name: "settings-sharing-ownership_sheet", title: "Who owns each account? (one joint, the rest the admin's)") { context in
                let copy = try await unconfirmedCopy(context)
                let admin = try await copy.write { db in try AccessActor.admin(db: db) }
                var rows = try await copy.read { db in try SharingSetup.proposal(admin: admin, db: db) }
                guard let joint = rows.firstIndex(where: { $0.displayName == "Rainy Day Saver" }) else { throw SnapshotMissing("Rainy Day Saver") }
                rows[joint].owner = .joint
                rows[joint].level = .everything
                let name = try await copy.read { db in try AppUser.fetchOne(db, key: admin.appUserId)?.displayName } ?? ""
                return AnyView(SnapshotSheetCanvas(sheet: OwnershipSheet(rows: rows, adminName: name, onSave: { _ in })))
            },
            SnapshotRoute(name: "settings-sharing", title: "Settings ▸ Sharing: my accounts, joint accounts, tax years and income") { _ in
                AnyView(SnapshotStandaloneCanvas(content: SettingsView(pane: .sharing)))
            },
            SnapshotRoute(name: "settings-sharing-lower_warning", title: "Settings ▸ Sharing: lowering Euro Current to Balance only") { context in
                try await confirmation(context, account: "Euro Current", to: .balanceOnly)
            },
            SnapshotRoute(name: "settings-sharing-raise_note", title: "Settings ▸ Sharing: raising Travel Card to Everything") { context in
                try await confirmation(context, account: "Travel Card", to: .everything)
            },
            SnapshotRoute(name: "settings-sharing-hidden_blocked", title: "Settings ▸ Sharing: Hidden refused for an account a property needs") { context in
                try await confirmation(context, account: "Euro Current", to: .hidden)
            },
            SnapshotRoute(name: "auth-member_refused", title: "Lock screen: Person B refused on A's Mac user (it holds A's private accounts)") { context in
                let member = try await memberUser(context)
                guard let refusal = try await context.dbQueue.read({ db in try SharingSignIn.refusal(personId: member.personId, db: db) }) else {
                    throw SnapshotCheckFailed("Person B wasn't refused on A's database")
                }
                let admin = try await context.dbQueue.read { db in try AppUser.filter(Column("isAdmin") == true).order(Column("id")).fetchOne(db) }
                let locked = SessionModel(dbQueue: context.dbQueue, isSetUp: true, biometrics: StandInTouchID(enrolled: []), defaults: SnapshotMode.defaults)
                locked.snapshotLock()
                let model = LockScreenModel(session: locked, biometrics: StandInTouchID(enrolled: []), candidates: [admin, member].compactMap { $0 })
                model.prepare()
                model.snapshotShowRefusal(refusal, for: member.id)
                return AnyView(LockScreen(model: model))
            },
            SnapshotCatalog.screen("accounts", "sharing_badges", "Accounts: lock badges on A's accounts below Everything", .accounts) { models, context in
                models.accounts.selectedAccountId = context.accountId("Travel Card")
            },
        ]
    }

    /// Person B on her own database (the demo with A's private records taken out, as her device would hold it): the
    /// cell's private lines, net worth's note, her Settings ▸ Sharing. They change the demo copy, so they run last.
    static var memberRoutes: [SnapshotRoute] {
        [
            SnapshotRoute(name: "budget-cell-private_lines", title: "Budget on Person B's own database: a cell's shared transactions, then A's private card as one line",
                          settleFactor: 2) { context in
                try await becomeMembersDatabase(context)
                let cell = try await privateCell(context)
                try await signInMember(context)
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .budgetGrid, prepare: { models in
                    // After the grid's own first load has settled its year (a year change clears the panel).
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        models.budgetGrid.reveal(categoryId: cell.category, date: cell.date, accountId: cell.account)
                    }
                })))
            },
            SnapshotRoute(name: "dashboard-viewer_member", title: "Dashboard on Person B's own database: net worth includes everything she can see",
                          settleFactor: 1.5) { context in
                try await becomeMembersDatabase(context)
                try await signInMember(context)
                return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .dashboard)))
            },
            SnapshotRoute(name: "settings-sharing-member", title: "Settings ▸ Sharing as Person B on her own database: no accounts of her own, no Set owners…") { context in
                try await becomeMembersDatabase(context)
                try await signInMember(context)
                return AnyView(SnapshotStandaloneCanvas(content: SettingsView(pane: .sharing)))
            },
        ]
    }

    // MARK: Data

    /// The demo copy before the ownership sheet, in memory: every account unowned and at Everything, no sharing rows,
    /// no summaries. The snapshot user (A) is still its admin.
    private static func unconfirmedCopy(_ context: SnapshotContext) async throws -> DatabaseQueue {
        let manager = try DatabaseManager(path: nil)
        try context.dbQueue.backup(to: manager.dbQueue)
        try await manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE account SET ownerPersonId = NULL, sharingLevel = 'everything'")
            try db.execute(sql: "DELETE FROM personSharing")
            try db.execute(sql: "DELETE FROM accountBalancePoint")
            try db.execute(sql: "DELETE FROM accountSummaryMonth")
        }
        return manager.dbQueue
    }

    /// The confirmation a level picked in Settings ▸ Sharing opens, its records counted, over the window.
    private static func confirmation(_ context: SnapshotContext, account name: String, to level: SharingLevel) async throws -> AnyView {
        let (row, preview, other) = try await context.dbQueue.read { db -> (SharingOverview.AccountRow, SharingOverview.LevelChangePreview, String) in
            guard let account = try Account.filter(Column("name") == name).fetchOne(db), let id = account.id else { throw SnapshotMissing(name) }
            let admin = try Int64.fetchOne(db, sql: "SELECT personId FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1") ?? 0
            let other = try String.fetchOne(db, sql: "SELECT name FROM person WHERE id != ? ORDER BY id LIMIT 1", arguments: [admin]) ?? SharingCopy.otherPersonFallback
            return (SharingOverview.AccountRow(id: id, displayName: account.displayName, bankName: account.bankName, level: account.sharingLevel),
                    try SharingOverview.preview(accountId: id, to: level, db: db), other)
        }
        let change = SharingLevelChangeFlow.Pending(account: row, to: level, preview: preview)
        return AnyView(SnapshotSheetCanvas(sheet: LevelChangeConfirm(change: change, otherName: other, onCancel: {}, onChange: {})))
    }

    /// Person B as a member with no password (made once in the demo copy).
    private static func memberUser(_ context: SnapshotContext) async throws -> AppUser {
        try await context.dbQueue.write { db -> AppUser in
            guard let person = try Person.filter(Column("name") == "Person B").fetchOne(db), let personId = person.id else { throw SnapshotMissing("Person B") }
            if let existing = try AppUser.filter(Column("personId") == personId).fetchOne(db) { return existing }
            var user = AppUser(personId: personId, displayName: person.name, isAdmin: false, createdAt: AppClock.now)
            try user.insert(db)
            return user
        }
    }

    /// Signs in as Person B for this route, as sign-in would let her: only on a database that isn't someone else's.
    private static func signInMember(_ context: SnapshotContext) async throws {
        let member = try await memberUser(context)
        if let refusal = try await context.dbQueue.read({ db in try SharingSignIn.refusal(personId: member.personId, db: db) }) {
            throw SnapshotCheckFailed("Person B refused: \(refusal)")
        }
        context.environment.session.snapshotSignIn(member)
    }

    /// The demo copy as Person B's own device holds it: A's private records (`SharingSignIn.othersPrivateRecords`)
    /// taken out; A's private accounts stay as stubs with their summaries. Done once.
    private static func becomeMembersDatabase(_ context: SnapshotContext) async throws {
        let member = try await memberUser(context)
        try await context.dbQueue.write { db in
            let records = try SharingSignIn.othersPrivateRecords(personId: member.personId, db: db)
            for table in ["forecastEntry", "balanceSnapshot", "balanceSnapshotArchive", "transaction_", "importBatch", "importProfile"] {
                let ids = records.filter { $0.table == table }.map { String($0.id) }
                guard !ids.isEmpty else { continue }
                try db.execute(sql: "DELETE FROM \(table) WHERE id IN (\(ids.joined(separator: ",")))")
            }
        }
    }

    /// The latest closed month's biggest category on A's Category totals card, with one shared purchase in it on the
    /// joint account (added here, as A), so the cell has a shared transaction above the card's private line.
    private static func privateCell(_ context: SnapshotContext) async throws -> (category: Int64, date: Date, account: Int64) {
        let found = try await context.dbQueue.write { db -> (Int64, Date, Int64)? in
            guard let card = try Account.filter(Column("name") == "Travel Card").fetchOne(db)?.id,
                  let joint = try Account.filter(Column("name") == "Rainy Day Saver").fetchOne(db)?.id else { return nil }
            let row = try Row.fetchOne(db, sql: """
                SELECT categoryId, payMonth FROM accountSummaryMonth
                WHERE accountId = ? AND categoryId IS NOT NULL
                  AND payMonth < (SELECT MAX(payMonth) FROM accountSummaryMonth WHERE accountId = ?)
                ORDER BY payMonth DESC, ABS(amountMinorUnits) DESC LIMIT 1
                """, arguments: [card, card])
            guard let row, let category: Int64 = row["categoryId"], let payMonth: String = row["payMonth"],
                  // The month's close (its balance point's day): the days before are inside it.
                  let close = try Date.fetchOne(db, sql: "SELECT date FROM accountBalancePoint WHERE accountId = ? AND payMonth = ?",
                                                arguments: [card, payMonth]) else { return nil }
            let day = close.addingTimeInterval(-2 * 86_400)
            if try Transaction.filter(Column("accountId") == joint && Column("rawDescription") == sharedPurchase).fetchCount(db) == 0 {
                try ManualTransactions.add(db: db, accountId: joint, date: day, description: sharedPurchase, amountMinorUnits: -2_450,
                                           categoryId: category, note: nil)
            }
            return (category, day, card)
        }
        guard let found else { throw SnapshotMissing("A Travel Card summary") }
        return found
    }

    private static let sharedPurchase = "Shared purchase (demo)"
}

/// A route's own check failed (the run prints it and skips the route).
struct SnapshotCheckFailed: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = "check failed: \(description)" }
}
#endif
