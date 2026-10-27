// App/Snapshots/SharingSnapshots.swift
#if SNAPSHOTS
import SwiftUI
import BudgetCore
import GRDB

/// The sharing routes (step 6 Task 10), on the demo's synthetic data (`DemoSharing`: Person A the admin, "A", owning
/// every account but the joint one). Each account's Sharing section is in Edit account (sync-ui); the one before the
/// owners are confirmed uses a copy of the demo with its owners taken back off; the member's routes sign in as Person B (an app user with no password, made in the
/// demo copy) for that route only (`SnapshotSession` signs the snapshot user back in before the next).
@MainActor
enum SharingSnapshots {
    static var routes: [SnapshotRoute] {
        [
            SnapshotRoute(name: "settings-sharing", title: "Settings ▸ Sharing: tax years and income, accounts' sharing is in Accounts") { _ in
                AnyView(SnapshotStandaloneCanvas(content: SettingsView(pane: .sharing)))
            },
            editSheet("accounts-edit-sharing", "Edit account: Sharing, A's card at Category totals", account: "Travel Card"),
            editSheet("accounts-edit-sharing-lower", "Edit account: Sharing, lowering Euro Current to Balance only (counted, warned)",
                      account: "Euro Current", preset: .init(level: .balanceOnly)),
            editSheet("accounts-edit-sharing-to_joint", "Edit account: Sharing, A's card made Joint", account: "Travel Card",
                      preset: .init(joint: true)),
            editSheet("accounts-edit-sharing-tallest", "Edit account: the tallest case (UK card lowered from Category totals to Balance only, warning shown) scrolls within 1100×700",
                      account: "Travel Card", preset: .init(level: .balanceOnly)),
            editSheet("accounts-edit-sharing-joint", "Edit account: Sharing, a joint account (always Everything)", account: "Rainy Day Saver"),
            editSheet("accounts-edit-sharing-hidden_blocked", "Edit account: Sharing, Hidden refused for an account a property needs",
                      account: "Euro Current", preset: .init(level: .hidden)),
            SnapshotRoute(name: "accounts-edit-sharing-unconfirmed", title: "Edit account: Sharing before the owners are confirmed (Save confirms the defaults)") { context in
                let copy = try await unconfirmedCopy(context)
                return try await editSheetView(copy, account: "Rainy Day Saver", preset: .init(joint: true))
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
        ] + turnOnRoutes + householdRoutes + sidebarRoutes + [
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
            SnapshotRoute(name: "settings-sharing-member", title: "Settings ▸ Sharing as Person B on her own database") { context in
                try await becomeMembersDatabase(context)
                try await signInMember(context)
                return AnyView(SnapshotStandaloneCanvas(content: SettingsView(pane: .sharing)))
            },
        ]
    }

    /// Settings ▸ Household in each state (step 7a Task 9), from given values; nothing here touches iCloud. Synthetic names.
    static var householdRoutes: [SnapshotRoute] {
        func route(_ name: String, _ title: String, _ state: HouseholdPaneState) -> SnapshotRoute {
            SnapshotRoute(name: "settings-household" + name, title: "Settings ▸ Household: " + title) { _ in
                AnyView(SnapshotStandaloneCanvas(content: SettingsView(pane: .household, householdState: state).scenePadding().frame(width: 640)))
            }
        }
        let member = "Person B"
        func added(_ status: HouseholdMemberState) -> HouseholdPaneState { HouseholdPaneState(member: member, status: status) }
        var blocked = added(.notInvited)
        blocked.blockers = [HouseholdCopy.blocker(.pendingUpload(3)), HouseholdCopy.blocker(.misplaced(2)),
                            HouseholdCopy.blocker(.householdAudit(1), alreadyShared: false)]
        var request = added(.joined)
        request.keyCode = "482 019"
        var locked = added(.joined)
        locked.locked = true
        var longName = added(.invited)
        longName.member = "Person B with a very long synthetic name that goes on and on and on and on and on"
        var editsWaiting = added(.joined)
        editsWaiting.edits = .waiting
        var editsBlocked = editsWaiting
        editsBlocked.blockers = [HouseholdCopy.blocker(.pendingUpload(1), alreadyShared: true),
                                 HouseholdCopy.blocker(.householdAudit(1), alreadyShared: true)]
        var editsAllowed = added(.joined)
        editsAllowed.edits = .allowed
        var ambiguous = added(.notInvited)
        ambiguous.ambiguous = HouseholdCopy.ambiguousParticipants(member)
        return [
            route("", "nobody added, a pick or a new name", HouseholdPaneState(unclaimed: ["Person C", "Person D"])),
            route("-added", "member added, not invited", added(.notInvited)),
            route("-blocked", "the invite is blocked, with the reasons", blocked),
            route("-invited", "invited, waiting", added(.invited)),
            route("-joined", "joined", added(.joined)),
            route("-edits_waiting", "joined, view only: the button that lets her make changes", editsWaiting),
            route("-edits_blocked", "joined, view only: the upgrade is blocked, with the reasons", editsBlocked),
            route("-edits_allowed", "joined: she can make changes", editsAllowed),
            route("-key_request", "her device asks for the key, with the code", request),
            route("-locked", "too many attempts", locked),
            route("-removed", "removed", added(.removed)),
            route("-long_name", "a long name truncates in the middle", longName),
            route("-ambiguous", "two people accepted", ambiguous),
        ]
    }

    /// "Turn on sync…" at each step and Settings ▸ Sync around it (step 6 Task 13), from synthetic facts: nothing here
    /// touches iCloud, the Keychain or a database.
    static var turnOnRoutes: [SnapshotRoute] {
        func sheet(_ name: String, _ title: String, _ facts: SyncTurnOnFlow.Facts, error: String? = nil) -> SnapshotRoute {
            SnapshotRoute(name: name, title: title) { _ in
                AnyView(SnapshotSheetCanvas(sheet: TurnOnSyncSheetContent(screen: SyncTurnOnFlow.screen(facts), error: error, onBackUp: {},
                                                                          onStartUpload: {}, onClose: {})))
            }
        }
        func pane(_ name: String, _ title: String, status: SyncStatus, running: Bool, report: SyncReport?, real: SyncSettingsPane.Real) -> SnapshotRoute {
            SnapshotRoute(name: name, title: title) { _ in
                AnyView(SnapshotStandaloneCanvas(content: SyncSettingsPane(status: status, isRunning: running, report: report,
                                                                           onSyncNow: running ? {} : nil, real: real, onTurnOn: {})
                    .scenePadding().frame(width: 640)))
            }
        }
        let backup = "/synthetic/Budget/" + SyncTurnOn.backupPrefix + "20261026-101500"
        func facts(_ stage: SyncTurnOn.Stage, blockers: [SyncTurnOn.Blocker] = [], sent: Int = 0, total: Int = 0,
                   status: SyncStatus = .off, refusal: String? = nil) -> SyncTurnOnFlow.Facts {
            SyncTurnOnFlow.Facts(progress: SyncTurnOn.Progress(stage: stage, backupPath: stage >= .backedUp ? backup : nil, total: total, sent: sent),
                                 blockers: blockers, checked: true, syncStatus: status, syncRefusal: refusal)
        }
        // The status line reads the real clock (`TimelineView`): two minutes before now.
        let lastSync = Date().addingTimeInterval(-120)
        var pulled = SyncPullReport()
        pulled.received = 12
        var pushed = SyncPushReport()
        pushed.saved = 4
        let report = SyncReport(pull: pulled, push: pushed)
        return [
            sheet("settings-sync-turn_on", "Turn on sync: blocked by a test's key and no iCloud account",
                  facts(.notStarted, blockers: [.strayHouseholdKey, .strayPrivateKey, .noICloudAccount])),
            sheet("settings-sync-turn_on-ready", "Turn on sync: backed up, ready to start the upload",
                  facts(.backedUp)),
            sheet("settings-sync-turn_on-uploading", "Turn on sync: uploading",
                  facts(.uploading, sent: 1_248, total: 3_006, status: .syncing(.pushing))),
            sheet("settings-sync-turn_on-paused", "Turn on sync: upload paused while offline",
                  facts(.uploading, sent: 1_248, total: 3_006, status: .offline(since: lastSync, retryAt: nil))),
            sheet("settings-sync-turn_on-done", "Turn on sync: done",
                  facts(.done, sent: 3_006, total: 3_006, status: .idle(lastSync: lastSync))),
            pane("settings-sync-off", "Settings ▸ Sync: off, Turn on sync…", status: .off, running: false, report: nil,
                 real: SyncSettingsPane.Real(stage: .notStarted, uploadLine: nil, refusal: nil, blockerLines: [], offersTurnOn: true)),
            pane("settings-sync-blocked", "Settings ▸ Sync: a build that can't turn sync on", status: .off, running: false, report: nil,
                 real: SyncSettingsPane.Real(stage: .notStarted, uploadLine: nil, refusal: nil,
                                             blockerLines: [SyncTurnOn.text(.wrongEnvironment)], offersTurnOn: false)),
            pane("settings-sync-uploading", "Settings ▸ Sync: the first upload running", status: .syncing(.pushing), running: true, report: nil,
                 real: SyncSettingsPane.Real(stage: .uploading, uploadLine: SyncTurnOnFlow.uploading(sent: 1_248, total: 3_006), refusal: nil,
                                             blockerLines: [], offersTurnOn: true)),
            pane("settings-sync-on", "Settings ▸ Sync: on, up to date", status: .idle(lastSync: lastSync), running: true, report: report,
                 real: SyncSettingsPane.Real(stage: .done, uploadLine: nil, refusal: nil, blockerLines: [], offersTurnOn: true)),
            pane("settings-sync-wrong_user", "Settings ▸ Sync: this Mac signed in to another iCloud user", status: .off, running: false, report: nil,
                 real: SyncSettingsPane.Real(stage: .done, uploadLine: nil, refusal: SyncTurnOnFlow.differentICloudUserAtLaunch,
                                             blockerLines: [], offersTurnOn: true)),
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

    /// Edit account for the demo account `name`, with a sharing choice already made, over the window.
    private static func editSheet(_ route: String, _ title: String, account name: String,
                                  preset: AccountSharingDraft.Preset? = nil) -> SnapshotRoute {
        SnapshotRoute(name: route, title: title, settleFactor: 1.5) { context in
            try await editSheetView(context.dbQueue, account: name, preset: preset)
        }
    }

    private static func editSheetView(_ dbQueue: DatabaseQueue, account name: String, preset: AccountSharingDraft.Preset?) async throws -> AnyView {
        let model = AccountsViewModel(dbQueue: dbQueue)
        _ = model.load()
        guard let account = try await dbQueue.read({ db in try Account.filter(Column("name") == name).fetchOne(db) }) else { throw SnapshotMissing(name) }
        return AnyView(SnapshotSheetCanvas(sheet: EditAccountSheet(viewModel: model, account: account, sharingPreset: preset)))
    }

    /// The sidebar's sync row in each state, over the Dashboard (`SidebarSyncRow`; nothing runs, the state is given).
    static var sidebarRoutes: [SnapshotRoute] {
        func route(_ tab: String, _ title: String, _ row: SyncSidebarStatus) -> SnapshotRoute {
            SnapshotRoute(name: "sidebar-sync-\(tab)", title: "Sidebar: \(title)", settleFactor: 1.5) { context in
                AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .dashboard))
                    .environment(\.sidebarSyncOverride, row))
            }
        }
        return [
            route("uploading", "the first upload, 1,248 of 3,006", .syncing(sent: 1_248, total: 3_006)),
            route("syncing", "syncing", .syncing(sent: nil, total: nil)),
            route("synced", "synced two minutes ago", .synced(Date().addingTimeInterval(-120))),
            route("paused", "paused while offline", .paused),
            route("attention", "needs attention", .attention),
        ]
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
