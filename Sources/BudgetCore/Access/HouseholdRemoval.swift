import Foundation
import GRDB
import os

/// Removing the household's member (step 15, Settings ▸ Household ▸ Remove): she comes off the share, then the household
/// gets a new key and every record sealed under a key she held goes up again under the new one
/// (`SyncEngineCore.finishKeyRevocation`). The admin's Mac only.
///
/// Never half-removed: iCloud is asked first, and offline nothing changes ("Connect to the internet to remove someone").
/// Once the removal has begun, each step is owed work, kept here (`SyncKeyRotation`), in order: taking her off the share
/// (retried first, never skipped: nothing is rotated while she may still be on it), the new key, the sweep. A step cut
/// short (offline, a quit, a crash) is finished after a later sync (`resumeIfPending`). Copies she already downloaded
/// can't be recalled (the pane says so).
public enum HouseholdRemoval {
    public enum Outcome: Equatable, Sendable {
        /// iCloud couldn't be reached before anything began: nothing changed.
        case offline
        /// She is off the share and the household is secured under a new key.
        case removed(SyncResealReport)
        /// She is off the share; the new key or the sweep finishes after a later sync (or once sync runs).
        case securingLater
        /// Taking her off the share didn't finish: it is retried (then the new key and the sweep) when online.
        case removalOwed
    }

    private static let log = Logger(subsystem: "com.personal.budget", category: "Household")

    /// Takes `member` off the household's share and secures the household. `engine`: the running engine (nil while sync
    /// isn't running here: she still comes off the share, and the new key is owed until it runs). `keys`: the household
    /// keys (every one held now is revoked). `progress` hears the sweep's counts.
    public static func remove(transport: any SyncShareTransport, engine: SyncEngineCore?, keys: any SyncKeyStore, member: AppUser,
                              db: any DatabaseWriter,
                              progress: @escaping @Sendable (SyncKeyRotation.Progress) -> Void = { _ in }) async throws -> Outcome {
        do {
            // Reachable now, or nothing is done.
            _ = try await transport.zoneShare(SyncZones.household)
        } catch let error as SyncTransportError where error.isPassing {
            log.notice("Household: removal refused, iCloud unreachable")
            return .offline
        }
        // Revoked before she comes off the share: whatever happens next, her keys are never handed out again, and taking
        // her off the share, then the new key, are owed.
        let held = Set(try keys.allKeys(zone: SyncZones.household).keys)
        try await db.write { db in try SyncKeyRotation.begin(revoking: held, removingFromShare: true, db: db, now: Date()) }
        guard try await takeOffShare(transport: transport, member: member, db: db) else { return .removalOwed }
        guard let engine else { return .securingLater }
        return try await secure(engine: engine, progress: progress)
    }

    /// After a sync on the admin's Mac: a removal left unfinished goes on, in order (off the share, the new key, the
    /// sweep). Nil when none is pending.
    public static func resumeIfPending(transport: any SyncShareTransport, engine: SyncEngineCore, db: any DatabaseWriter,
                                       progress: @escaping @Sendable (SyncKeyRotation.Progress) -> Void = { _ in }) async throws -> Outcome? {
        guard try await db.read({ db in try SyncKeyRotation.isPending(db: db) }) else { return nil }
        if try await db.read({ db in try SyncKeyRotation.isShareRemovalOwed(db: db) }) {
            let member = try await db.read { db in try HouseholdInvite.member(db: db) }
            if let member {
                guard try await takeOffShare(transport: transport, member: member, db: db) else { return .removalOwed }
            } else {
                // Nobody to take off any more (the member was deleted here).
                try await db.write { db in try SyncKeyRotation.shareRemoved(db: db, now: Date()) }
            }
        }
        return try await secure(engine: engine, progress: progress)
    }

    /// `HouseholdInvite.remove` (idempotent), then the owed step is cleared. False when iCloud couldn't confirm it.
    private static func takeOffShare(transport: any SyncShareTransport, member: AppUser, db: any DatabaseWriter) async throws -> Bool {
        do {
            try await HouseholdInvite.remove(transport: transport, member: member, db: db)
        } catch let error as SyncTransportError where error.isPassing {
            log.error("Household: taking the member off the share didn't finish; retried when online")
            return false
        }
        try await db.write { db in try SyncKeyRotation.shareRemoved(db: db, now: Date()) }
        return true
    }

    private static func secure(engine: SyncEngineCore, progress: @escaping @Sendable (SyncKeyRotation.Progress) -> Void) async throws -> Outcome {
        do {
            guard let report = try await engine.finishKeyRevocation(progress: progress) else { return .securingLater }
            return report.remaining == 0 ? .removed(report) : .securingLater
        } catch let error as SyncTransportError where error.isPassing {
            log.notice("Household: securing interrupted (offline); it goes on after a later sync")
            return .securingLater
        } catch SyncKeyError.unavailable {
            log.notice("Household: securing interrupted (key marker unreachable); it goes on after a later sync")
            return .securingLater
        }
    }
}
