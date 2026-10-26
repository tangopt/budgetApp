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
    /// The system share sheet asked for; the pane shows it and clears this.
    @Published var sharePrompt: SharePrompt?

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    private let dbQueue: DatabaseQueue
    private let session: SessionModel
    /// This Mac's real sync runs, as the admin's iCloud user (set by `RealSync`).
    var isRunning: () -> Bool = { false }
    private var transport: CloudKitTransport?
    private var share: SyncZoneShare?
    private var granter: (member: String, granter: SyncKeyExchange.Granter)?
    private var request: SyncKeyExchange.Request?
    private var blockers: [String] = []
    private var ambiguous: String?
    private var error: String?
    private var busy = false
    private var refreshing = false

    init(dbQueue: DatabaseQueue, session: SessionModel) {
        self.dbQueue = dbQueue
        self.session = session
    }

    var actions: HouseholdActions {
        HouseholdActions(
            add: { [weak self] index, name in Task { await self?.add(unclaimedIndex: index, name: name) } },
            invite: { [weak self] in Task { await self?.invite() } },
            remove: { [weak self] in Task { await self?.remove() } },
            give: { [weak self] in Task { await self?.give() } },
            notNow: { [weak self] in Task { await self?.notNow() } })
    }

    private var isAdmin: Bool { session.currentUser?.isAdmin == true }

    private func cloud() -> CloudKitTransport {
        if let transport { return transport }
        let made = CloudKitTransport()
        transport = made
        return made
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
        }
        await publish()
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
        let read = try? await dbQueue.read { db -> (AppUser?, [String], Bool) in
            (try HouseholdInvite.member(db: db), try AppUserStore.unclaimedPeople(db).map(\.name), try HouseholdInvite.wasRemoved(db: db))
        }
        guard let (member, unclaimed, removed) = read else { return }
        var next = HouseholdPaneState()
        next.unclaimed = unclaimed
        next.busy = busy
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

    func invite() async {
        await run {
            blockers = []
            let local = try await dbQueue.read { db in try HouseholdInvite.localBlockers(db: db) }
            guard local.isEmpty else { blockers = local.map { HouseholdCopy.blocker($0) }; return }
            guard isRunning() else { blockers = [HouseholdCopy.blocker(.syncNotOn)]; return }
            let transport = cloud()
            let existed = (try? await transport.zoneShare(SyncZones.household)) != nil
            let result = try await HouseholdInvite.invite(transport: transport, keys: keys, db: dbQueue, title: "Mango household")
            switch result {
            case .blocked(let found):
                blockers = found.map { HouseholdCopy.blocker($0, alreadyShared: existed) }
            case .share(let made):
                share = made
                guard let sheet = try await transport.shareForSheet(SyncZones.household) else { error = HouseholdCopy.shareFailed; return }
                sharePrompt = SharePrompt(share: sheet.share, container: sheet.container)
            }
        }
    }

    func shareFailed() {
        error = HouseholdCopy.shareFailed
        Task { await publish() }
    }

    func remove() async {
        await run {
            guard let member = try await dbQueue.read({ db in try HouseholdInvite.member(db: db) }) else { return }
            try await HouseholdInvite.remove(transport: cloud(), member: member, db: dbQueue)
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

    func notNow() async {
        guard let request, let granter = granter?.granter else { return }
        await run {
            try await granter.decline(request, now: Date())
            self.request = nil
        }
    }
}
