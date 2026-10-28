// App/Sync/HouseholdController.swift
import AppKit
import CloudKit
import Foundation
import GRDB
import os
import BudgetCore
import MangoSync

/// Settings ▸ Household on the admin's Mac (step 7a Task 9): reads the member and the household's share, binds her iCloud
/// user once she accepts, answers her device's key request, and runs the pane's buttons. Every database write is a
/// BudgetCore entry point that writes as the admin through `ActorWrite` (`AppUserStore.addMember`,
/// `HouseholdInvite.bindAcceptedParticipant`/`remove`); nothing here touches a table itself. CloudKit (the share, the
/// audit, the exchange) is only reached while this Mac's real sync runs (`isRunning`), and always off the main thread.
@MainActor
final class HouseholdController: ObservableObject {
    struct SharePrompt: Equatable, Identifiable {
        let id = UUID()
        let share: CKShare
        let container: CKContainer
    }

    @Published private(set) var state = HouseholdPaneState.empty
    /// Shows the system share sheet for a prompt, from the open pane (`LiveHouseholdSettings`); false: it couldn't.
    /// Nil while the pane isn't open.
    var presenter: ((SharePrompt) -> Bool)?

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    private let dbQueue: DatabaseQueue
    private let session: SessionModel
    /// This Mac's real sync runs, as the admin's iCloud user (set by `RealSync`).
    var isRunning: () -> Bool = { false }
    /// The running engine (set by `RealSync`): removing the member gives the household a new key through it (step 15).
    var engine: SyncEngineCore?
    private var transport: CloudKitTransport?
    private var share: SyncZoneShare?
    private var granter: (member: String, granter: SyncKeyExchange.Granter)?
    private var request: SyncKeyExchange.Request?
    private var blockers: [String] = []
    private var ambiguous: String?
    private var error: String?
    private var busy = false
    /// "Invite…" is running its gate (the pane says so: the server audit can take a while).
    private var checking = false
    /// Where "Invite…" has got to (the pane's progress line).
    private var stage: HouseholdInvite.Stage = .checkingThisMac
    private var refreshing = false
    /// The re-seal sweep's counts while it runs here (the pane's "Securing the household… n of m").
    private var securing: SyncKeyRotation.Progress?

    init(dbQueue: DatabaseQueue, session: SessionModel) {
        self.dbQueue = dbQueue
        self.session = session
    }

    var actions: HouseholdActions {
        HouseholdActions(
            add: { [weak self] index, name in Task { await self?.add(unclaimedIndex: index, name: name) } },
            invite: { [weak self] in Task { await self?.invite() } },
            allowEdits: { [weak self] in Task { await self?.allowEdits() } },
            remove: { [weak self] in Task { await self?.remove() } },
            give: { [weak self] in Task { await self?.give() } },
            notNow: { [weak self] in Task { await self?.notNow() } },
            saveGrid: { [weak self] grid in Task { await self?.saveGrid(grid) } })
    }

    private var isAdmin: Bool { session.currentUser?.isAdmin == true }

    private func cloud() -> CloudKitTransport {
        if let transport { return transport }
        // Someone is waiting on these calls (the pane's buttons): not background sync's `.utility`.
        let made = CloudKitTransport(qualityOfService: .userInitiated)
        transport = made
        return made
    }

    /// The iCloud account changed (`RealSync`): the transport (which keeps the iCloud user it first read) and what was
    /// read through it are dropped, so the next call reads the account signed in now (final review M-5).
    func accountChanged() {
        transport = nil
        share = nil
        granter = nil
        request = nil
    }

    private var keys: KeychainSyncKeyStore { KeychainSyncKeyStore(container: CloudKitTransport.keyScope(demo: false)) }

    // MARK: Reading

    /// After each sync (`RealSync`) and while the pane is open: reads the member and, when sync runs, her share; binds
    /// her once she has accepted; looks for her key request.
    func refresh(contactCloud: Bool) async {
        guard !refreshing, isAdmin else { return }
        refreshing = true
        defer { refreshing = false }
        let running = contactCloud && isRunning()
        if running {
            await contactICloud()
            await resumeSecuring()
        }
        await publish()
    }

    /// A removal's new key or re-seal sweep left unfinished (offline, a quit, a crash) goes on after a sync.
    private func resumeSecuring() async {
        guard !busy, let engine else { return }
        do {
            let outcome = try await HouseholdRemoval.resumeIfPending(transport: cloud(), engine: engine, db: dbQueue,
                                                                     progress: securingProgress())
            if outcome != nil { Self.log.notice("Household: securing resumed") }
        } catch {
            Self.log.error("Household: securing failed (\(String(describing: type(of: error)), privacy: .public))")
        }
        securing = nil
    }

    /// Hands the sweep's counts to the pane.
    private func securingProgress() -> @Sendable (SyncKeyRotation.Progress) -> Void {
        { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.securing = progress
                let line = HouseholdCopy.securing(progress)
                if self.state.progress != line { self.state.progress = line }
            }
        }
    }

    /// The share, the bind, the exchange. A passing failure (offline) keeps what was known.
    private func contactICloud() async {
        let transport = cloud()
        do {
            let member = try await dbQueue.read { db in try HouseholdInvite.member(db: db) }
            guard member != nil else { share = nil; return }
            share = try await transport.zoneShare(SyncZones.household)
            if let found = share {
                let outcome = try await dbQueue.write { db in try HouseholdInvite.bindAcceptedParticipant(share: found, db: db) }
                if case .ambiguous = outcome, let name = member?.displayName { ambiguous = HouseholdCopy.ambiguousParticipants(name) }
                else if outcome == .bound { ambiguous = nil }
            }
            await pollExchange()
        } catch {
            Self.log.error("Household refresh failed (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    private func pollExchange() async {
        let facts = try? await dbQueue.read { db in
            (try HouseholdInvite.member(db: db), try HouseholdInvite.wasRemoved(db: db))
        }
        guard let (member, removed) = facts, let member, !removed, let name = member.cloudKitUserRecordName,
              HouseholdInvite.status(share: share, member: member) == .joined else {
            granter = nil
            request = nil
            return
        }
        if granter?.member != name {
            granter = (name, SyncKeyExchange.Granter(board: CloudKitPublicBoard(), transport: cloud(), member: name, db: dbQueue))
        }
        guard let granter = granter?.granter else { return }
        do {
            if try await granter.lockedUntil(now: Date()) != nil {
                request = nil
                return
            }
            request = try await granter.poll(now: Date())
        } catch {
            request = nil
            Self.log.error("Key exchange poll failed (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    private func publish() async {
        let share = share
        let request = request
        let read = try? await dbQueue.read { db -> (AppUser?, [String], Bool, PermissionGrid?, SyncKeyRotation.Progress?, Bool) in
            let member = try HouseholdInvite.member(db: db)
            let grid = try member?.id.flatMap { try? PermissionGrid.load(db: db, appUserId: $0) }
            return (member, try AppUserStore.unclaimedPeople(db).map(\.name), try HouseholdInvite.wasRemoved(db: db), grid,
                    try SyncKeyRotation.progress(db: db), try SyncKeyRotation.isShareRemovalOwed(db: db))
        }
        guard let (member, unclaimed, removed, grid, owed, shareOwed) = read else { return }
        var next = HouseholdPaneState()
        next.unclaimed = unclaimed
        next.busy = busy
        if busy && checking {
            next.progress = HouseholdCopy.inviteProgress(stage)
        } else if shareOwed, let member {
            // One honest state (review I2): she isn't off the share yet; it is retried, then secured, when online.
            next.progress = HouseholdCopy.removalOwed(member.displayName)
        } else if let securing {
            next.progress = HouseholdCopy.securing(securing)
        } else if owed != nil {
            // A removal's new key or sweep is still owed: it goes on after the next sync.
            next.progress = HouseholdCopy.securingLater
        }
        next.error = error
        if let member {
            next.member = member.displayName
            if removed {
                next.status = .removed
            } else {
                switch HouseholdInvite.status(share: share, member: member) {
                case .notInvited: next.status = .notInvited
                case .invited: next.status = .invited
                case .joined: next.status = .joined
                }
            }
            next.blockers = blockers
            next.ambiguous = ambiguous
            if next.status == .joined {
                next.grid = grid
                next.edits = HouseholdInvite.needsEditUpgrade(share) ? .waiting : .allowed
                next.keyCode = request?.code
                if let granter = granter?.granter, request == nil {
                    next.locked = (try? await granter.lockedUntil(now: Date())) != nil
                }
            }
        }
        if state != next { state = next }
    }

    // MARK: Buttons

    private func run(_ work: () async throws -> Void) async {
        busy = true
        error = nil
        await publish()
        do { try await work() } catch { self.error = SignInErrorText.describe(error) }
        busy = false
        await publish()
    }

    func add(unclaimedIndex: Int?, name: String) async {
        guard let adminId = session.currentAppUserId else { return }
        await run {
            let people = try await dbQueue.read { db in try AppUserStore.unclaimedPeople(db) }
            let person = unclaimedIndex.flatMap { people.indices.contains($0) ? people[$0] : nil }
            let typed = person?.name ?? name
            let personId = person?.id
            _ = try await dbQueue.write { db in try AppUserStore.addMember(db, personId: personId, name: typed, by: adminId, now: Date()) }
            blockers = []
            ambiguous = nil
        }
    }

    /// "Invite…": the gate (`HouseholdInvite.press`), then the system share sheet through `presenter`. Every outcome
    /// shows in the pane: the reasons under "Not yet:", or the error line when the sheet can't open.
    func invite() async {
        checking = true
        stage = .checkingThisMac
        defer { checking = false }
        await run {
            blockers = []
            let transport = cloud()
            let outcome = try await HouseholdInvite.press(running: isRunning(), transport: transport, keys: keys, db: dbQueue,
                                                          title: "Mango household", progress: { [weak self] stage in
                Task { @MainActor in self?.show(stage) }
            }) {
                try await transport.shareForSheet(SyncZones.household)
            }
            switch outcome {
            case .timedOut:
                error = HouseholdCopy.inviteTimedOut
            case .blocked(let lines):
                Self.log.notice("Household invite: blocked (\(lines.count, privacy: .public) reason(s))")
                blockers = lines
            case .sheetUnavailable(let made):
                Self.log.error("Household invite: share made but its CKShare couldn't be read")
                share = made
                error = HouseholdCopy.shareFailed
            case .present(let made, let sheet):
                share = made
                let prompt = SharePrompt(share: sheet.share, container: sheet.container)
                let shown = presenter?(prompt) ?? false
                Self.log.notice("Household invite: share sheet \(shown ? "shown" : "not shown", privacy: .public)")
                if !shown { error = HouseholdCopy.shareFailed }
            }
        }
    }

    /// The progress line follows the invite's steps (only while it runs).
    private func show(_ stage: HouseholdInvite.Stage) {
        guard checking, busy else { return }
        self.stage = stage
        let line = HouseholdCopy.inviteProgress(stage)
        if state.progress != line { state.progress = line }
    }

    /// "Let … make changes" (step 8): the admin's press is the only thing that upgrades the live share, behind the
    /// invite's gate and audit (`HouseholdInvite.allowMemberEdits`). Blocked: the reasons, as for an invite again.
    func allowEdits() async {
        await run {
            blockers = []
            guard isRunning() else { blockers = [HouseholdCopy.blocker(.syncNotOn, alreadyShared: true)]; return }
            let result = try await HouseholdInvite.allowMemberEdits(transport: cloud(), keys: keys, db: dbQueue, title: "Mango household")
            switch result {
            case .blocked(let found):
                blockers = found.map { HouseholdCopy.blocker($0, alreadyShared: true) }
            case .share(let upgraded):
                share = upgraded
            }
        }
    }

    /// "Remove": she comes off the share, then the household gets a new key and every record is sealed again
    /// (`HouseholdRemoval`, step 15). Offline, nothing changes and the pane says to connect.
    func remove() async {
        await run {
            guard let member = try await dbQueue.read({ db in try HouseholdInvite.member(db: db) }) else { return }
            defer { securing = nil }
            // Without running sync she still comes off the share; the new key is owed until sync runs (review M3).
            let outcome = try await HouseholdRemoval.remove(transport: cloud(), engine: isRunning() ? engine : nil, keys: keys,
                                                            member: member, db: dbQueue, progress: securingProgress())
            switch outcome {
            case .offline:
                error = HouseholdCopy.removeOffline
                return
            case .removalOwed:
                // The pane's one line says so (`removalOwed`), not an error.
                Self.log.notice("Household: taking the member off the share is owed; retried when online")
                return
            case .securingLater:
                Self.log.notice("Household: removed; securing goes on after a later sync")
            case .removed(let report):
                Self.log.notice("Household: removed; \(report.progress.done, privacy: .public) record(s) secured")
            }
            share = try? await cloud().zoneShare(SyncZones.household)
            granter = nil
            request = nil
            blockers = []
            ambiguous = nil
        }
    }

    func give() async {
        guard let request, let granter = granter?.granter else { return }
        await run {
            try await granter.grant(request, keys: keys, now: Date())
            self.request = nil
        }
    }

    /// Save on the grid: writes the changed areas as the admin (`PermissionGrid.save`), then reloads. A refusal shows in the pane.
    func saveGrid(_ grid: PermissionGrid) async {
        guard let adminId = session.currentAppUserId else { return }
        await run {
            try await dbQueue.write { db in
                let actor = try AccessActor.load(appUserId: adminId, db: db)
                try PermissionGrid.save(grid, actor: actor, db: db)
            }
        }
    }

    func notNow() async {
        guard let request, let granter = granter?.granter else { return }
        await run {
            try await granter.decline(request, now: Date())
            self.request = nil
        }
    }
}
