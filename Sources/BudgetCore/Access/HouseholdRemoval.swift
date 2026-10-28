import Foundation
import GRDB
import os

/// Removing the household's member (step 15, Settings ▸ Household ▸ Remove): she comes off the share, then the household
/// gets a new key and every record sealed under a key she held is sealed again (`SyncEngineCore.finishKeyRevocation`).
/// The admin's Mac only.
///
/// Never half-removed: iCloud is asked first, and offline nothing changes ("Connect to the internet to remove someone").
/// Once she is off the share, a rotation or sweep cut short (offline, a quit, a crash) stays pending here and is finished
/// after a later sync (`resumeIfPending`). Copies she already downloaded can't be recalled (the pane says so).
public enum HouseholdRemoval {
    public enum Outcome: Equatable, Sendable {
        /// iCloud couldn't be reached: nothing changed.
        case offline
        /// She is off the share and the household is secured under a new key.
        case removed(SyncResealReport)
        /// She is off the share; the new key or the sweep finishes after a later sync.
        case securingLater
    }

    private static let log = Logger(subsystem: "com.personal.budget", category: "Household")

    /// Takes `member` off the household's share and secures the household. `progress` hears the sweep's counts.
    public static func remove(transport: any SyncShareTransport, engine: SyncEngineCore, member: AppUser, db: any DatabaseWriter,
                              progress: @escaping @Sendable (SyncKeyRotation.Progress) -> Void = { _ in }) async throws -> Outcome {
        do {
            // Reachable now, or nothing is done.
            _ = try await transport.zoneShare(SyncZones.household)
        } catch let error as SyncTransportError where error.isPassing {
            log.notice("Household: removal refused, iCloud unreachable")
            return .offline
        }
        // Revoked before she comes off the share: whatever happens next, her keys are never handed out again and the
        // rotation is owed.
        try await engine.beginKeyRevocation()
        do {
            try await HouseholdInvite.remove(transport: transport, member: member, db: db)
        } catch let error as SyncTransportError where error.isPassing {
            // The removal may or may not have reached iCloud: the rotation stays owed; the admin presses Remove again.
            log.error("Household: removal interrupted; the new key is still owed")
            return .offline
        }
        return try await secure(engine: engine, progress: progress)
    }

    /// After a sync on the admin's Mac: a removal's rotation or sweep left unfinished goes on. Nil when none is pending.
    public static func resumeIfPending(engine: SyncEngineCore, db: any DatabaseReader,
                                       progress: @escaping @Sendable (SyncKeyRotation.Progress) -> Void = { _ in }) async throws -> Outcome? {
        guard try await db.read({ db in try SyncKeyRotation.isPending(db: db) }) else { return nil }
        return try await secure(engine: engine, progress: progress)
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
