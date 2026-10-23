// App/Snapshots/AuthSnapshots.swift
#if SNAPSHOTS
import SwiftUI
import BudgetCore
import GRDB

/// The sign-in routes (`auth-*`, `settings-sign-in`) and the confirm-time attribution check
/// (`imports-history_confirmed_by`). The people are the demo's ("Person A", "Person B"); their app users are
/// synthetic, made with few hashing rounds, and Touch ID is a stand-in that never asks this Mac.
@MainActor
enum AuthSnapshots {
    /// A recovery key in the real alphabet, invented.
    static let demoKey = "K7QM2XPA9RTVHC4NWE3J5BLY"
    static let demoPassword = "synthetic-pass 42"

    static var routes: [SnapshotRoute] {
        [
            SnapshotRoute(name: "auth-setup", title: "Set up Mango: who you are and a password") { context in
                let model = SetupModel(session: context.environment.session, biometrics: StandInTouchID(enrolled: []),
                                       people: try await people(context))
                model.snapshotShow(.who, password: demoPassword)
                return AnyView(SetupFlowView(model: model))
            },
            SnapshotRoute(name: "auth-setup_first_person", title: "Set up Mango on an empty database: your name") { context in
                let model = SetupModel(session: context.environment.session, biometrics: StandInTouchID(enrolled: []), people: [])
                model.snapshotShow(.who, password: demoPassword)
                model.newPersonName = "Person A"
                return AnyView(SetupFlowView(model: model))
            },
            SnapshotRoute(name: "auth-recovery-key", title: "Set up Mango: the recovery key, shown once") { context in
                let model = SetupModel(session: context.environment.session, biometrics: StandInTouchID(enrolled: []),
                                       people: try await people(context))
                model.snapshotShow(.recoveryKey(key: demoKey, owner: nil))
                return AnyView(SetupFlowView(model: model))
            },
            SnapshotRoute(name: "auth-locked-one", title: "Lock screen: one person, a password after too many tries") { context in
                let users = try await standInUsers(context)
                let model = LockScreenModel(session: context.environment.session, biometrics: StandInTouchID(enrolled: [1]),
                                            candidates: [users[0]])
                model.prepare()
                model.usePassword()
                model.throttledUntil = Date().addingTimeInterval(42)
                return AnyView(LockScreen(model: model))
            },
            SnapshotRoute(name: "auth-locked-two", title: "Lock screen: two people on a shared macOS user") { context in
                let users = try await standInUsers(context)
                let model = LockScreenModel(session: context.environment.session, biometrics: StandInTouchID(enrolled: [1]),
                                            candidates: users)
                model.prepare()
                return AnyView(LockScreen(model: model))
            },
            SnapshotRoute(name: "auth-forgot-password", title: "Lock screen: Forgot password?, the recovery key") { context in
                let users = try await standInUsers(context)
                let model = LockScreenModel(session: context.environment.session, biometrics: StandInTouchID(enrolled: []),
                                            candidates: [users[0]])
                model.prepare()
                model.forgotPassword()
                return AnyView(LockScreen(model: model))
            },
            SnapshotRoute(name: "settings-sign-in", title: "Settings ▸ Sign-in, as an admin") { context in
                let users = try await demoUsers(context)
                let session = context.environment.session
                session.snapshotSignIn(users[0])
                await session.refreshCandidates()
                let model = SignInSettingsModel(session: session, biometrics: StandInTouchID(enrolled: Set(users.compactMap(\.id).prefix(1))))
                return AnyView(SnapshotStandaloneCanvas(content: SettingsView(pane: .signIn, signInModel: model)))
            }
        ]
    }

    /// The lock overlay over real content: the Search screen with its field focused, under a session of the
    /// route's own that is locked (the app's snapshot session never locks). Nothing of Search may show.
    static var lockedContentRoute: SnapshotRoute {
        SnapshotRoute(name: "auth-locked_over_content", title: "Lock screen over the Search screen, its field focused", settleFactor: 1.5) { context in
            _ = try await demoUsers(context)
            let locked = SessionModel(dbQueue: context.dbQueue, isSetUp: true, biometrics: StandInTouchID(enrolled: []),
                                      defaults: SnapshotMode.defaults)
            locked.snapshotLock()
            await locked.refreshCandidates()
            return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .search, prepare: { models in
                models.search.requestFocus()
            })).lockOverlay(.main, session: locked))
        }
    }

    /// The lock overlay over screens that put items in the window toolbar: Scenario Lab (its view picker and
    /// a horizon menu that names the horizon) and Rules with a search typed. The toolbar stays (so the
    /// window keeps its size) but none of its items or the search text may show. `rules-search_typed` is
    /// the same Rules page unlocked, so the search text is known to be there under the lock.
    static var lockedToolbarRoutes: [SnapshotRoute] {
        [
            SnapshotRoute(name: "auth-locked_over_scenario_lab", title: "Lock screen over Scenario Lab: no toolbar items show", settleFactor: 1.5) { context in
                try await lockedContent(context, screen: .forecast)
            },
            SnapshotRoute(name: "auth-locked_over_rules_search", title: "Lock screen over Rules with a search typed: no search text shows", settleFactor: 1.5) { context in
                try await lockedContent(context, screen: .rules) { $0.rules.snapshotSearchText = rulesSearch }
            },
            SnapshotRoute(name: "rules-search_typed", title: "Rules with a search typed (unlocked, to compare)", settleFactor: 1.5) { context in
                AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .rules, prepare: { models in
                    models.rules.snapshotSearchText = rulesSearch
                })))
            },
        ]
    }

    private static let rulesSearch = "Synthetic search"

    private static func lockedContent(_ context: SnapshotContext, screen: AppScreen,
                                      prepare: @escaping @MainActor (SnapshotScreenModels) -> Void = { _ in }) async throws -> AnyView {
        _ = try await demoUsers(context)
        let locked = SessionModel(dbQueue: context.dbQueue, isSetUp: true, biometrics: StandInTouchID(enrolled: []),
                                  defaults: SnapshotMode.defaults)
        locked.snapshotLock()
        await locked.refreshCandidates()
        return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: screen, prepare: prepare))
            .lockOverlay(.main, session: locked))
    }

    /// `LaunchView` under the lock overlay, mounted with no environment yet, as at launch: the overlay must
    /// keep the content's identity when the environment arrives, so `load()` runs once (it ran twice when
    /// the overlay swapped the content in an `if`). Prints the count; last, as it replaces `Current`.
    static var launchLoadsOnceRoute: SnapshotRoute {
        SnapshotRoute(name: "auth-launch_loads_once", title: "Launch under the lock overlay: the environment loads once", settleFactor: 3) { _ in
            let before = AppEnvironment.loadCount
            AppEnvironment.Current.shared.environment = nil
            return AnyView(LaunchView().lockOverlay(.main).task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                let loads = AppEnvironment.loadCount - before
                print("  auth-launch_loads_once: AppEnvironment.load ran \(loads) time\(loads == 1 ? " — OK" : "s — FAILED")")
            })
        }
    }

    /// Confirm import records whoever is signed in when Confirm is pressed, not who opened the review
    /// (auth spec §6, Review Focus 3): a review opened as Person A, the lock changing hands to Person B, then
    /// the real `confirm()`. The route fails (and the run prints it) unless the run records Person B; it then
    /// shows the history with "Confirmed by Person B". Writes to the demo copy, so it runs after the imports.
    static var attributionRoute: SnapshotRoute {
        SnapshotRoute(name: "imports-history_confirmed_by", title: "Imports: a run confirmed after the lock changed hands", settleFactor: 1.5) { context in
            let users = try await demoUsers(context)
            guard let personA = users[0].id, let personB = users[1].id else { throw SnapshotMissing("The demo's app users") }
            let signedIn = SignedInStandIn(appUserId: personA)
            let center = ImportCenterModel(
                dbQueue: context.dbQueue, databasePath: context.environment.databasePath, library: context.library,
                categorizationService: CategorizationService(categorizer: OnDeviceCategorizer.systemDefault()),
                modelReader: nil, currentAppUserId: { signedIn.appUserId })
            let (corrected, _, _) = try await SnapshotCatalog.correctedInsurerLetter(context)
            let plan = try await context.environment.importCenter.snapshotLeavingOutNeedsYou(corrected)
            center.showSnapshotPlan(plan, selecting: nil)
            // The lock changes hands while the review is open.
            signedIn.appUserId = personB
            center.confirm()
            let deadline = Date().addingTimeInterval(60)
            while center.phase == .applying || center.phase == .review, center.problem == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard case .finished(let summary) = center.phase else {
                throw AttributionCheckFailed("Confirm didn't finish: \(center.problem?.title ?? String(describing: center.phase))")
            }
            let recorded = try await context.dbQueue.read { db in
                try Int64.fetchOne(db, sql: "SELECT appUserId FROM importRun WHERE id = ?", arguments: [summary.runId])
            }
            guard recorded == personB else {
                throw AttributionCheckFailed("The run records app user \(recorded.map(String.init) ?? "nil"), not Person B (\(personB))")
            }
            print("  imports-history_confirmed_by: Confirm recorded Person B, signed in at Confirm — OK")
            let shown = context.environment.importCenter
            shown.discard()
            await shown.reloadRuns()
            shown.selectedRunId = summary.runId
            return AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .imports, prepare: { _ in })))
        }
    }

    // MARK: Data

    /// The demo's people, as setup lists them.
    static func people(_ context: SnapshotContext) async throws -> [Person] {
        let people = try await context.dbQueue.read { try Person.order(Column("name")).fetchAll($0) }
        guard people.count >= 2 else { throw SnapshotMissing("Two demo people") }
        return Array(people.prefix(2))
    }

    /// Lock-screen people that are never written: ids 1 and 2.
    static func standInUsers(_ context: SnapshotContext) async throws -> [AppUser] {
        try await people(context).enumerated().map { index, person in
            AppUser(id: Int64(index + 1), personId: person.id ?? 0, displayName: person.name, isAdmin: index == 0, createdAt: AppClock.now)
        }
    }

    /// App users for both demo people in the demo copy (Person A the admin), made once.
    static func demoUsers(_ context: SnapshotContext) async throws -> [AppUser] {
        let people = try await people(context)
        return try await context.dbQueue.write { db in
            try people.enumerated().map { index, person -> AppUser in
                if let existing = try AppUser.filter(Column("personId") == person.id).fetchOne(db) { return existing }
                return try AppUserStore.create(db, personId: person.id!, displayName: person.name, password: demoPassword,
                                               isAdmin: index == 0, now: AppClock.now, rounds: 1_000).0
            }
        }
    }
}

/// Who `currentAppUserId` says is signed in, changed between opening the review and Confirm.
@MainActor
private final class SignedInStandIn {
    var appUserId: Int64?
    init(appUserId: Int64?) { self.appUserId = appUserId }
}

struct AttributionCheckFailed: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = "attribution check failed: \(description)" }
}

/// Touch ID that's always there and never asks: the routes show it on for `enrolled`.
@MainActor
final class StandInTouchID: BiometricUnlocker {
    private var enrolled: Set<Int64>
    init(enrolled: Set<Int64>) { self.enrolled = enrolled }
    var isAvailable: Bool { true }
    func enrol(appUserId: Int64) async throws { enrolled.insert(appUserId) }
    func unlock(appUserId: Int64, reason: String) async throws -> Bool { false }
    func remove(appUserId: Int64) { enrolled.remove(appUserId) }
    func enrolledIds() -> Set<Int64> { enrolled }
}
#endif
