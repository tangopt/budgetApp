import Foundation
import GRDB

/// What the iPad offers for a checked bank statement (step 19).
public enum PadImportRoute: Equatable, Sendable {
    /// Import here (the lease is free, or this device's).
    case importHere
    /// Another device holds the household's import lease: Import waits ("The Mac is importing (started 10:42)").
    case heldBy(deviceName: String, since: Date)
    /// The lease can't be read: importing needs a moment online.
    case offline
    /// No import access for this account on this device (a member without Import, or an account whose import goes
    /// to a zone this device doesn't write): "Send to the Mac", as before step 19.
    case sendToMac
}

/// Why the iPad didn't import (step 19). Nothing was written.
public enum PadImportRefusal: Error, Equatable, LocalizedError {
    case heldBy(deviceName: String, since: Date)
    case offline
    case noImportAccess

    public var errorDescription: String? {
        switch self {
        case .heldBy(let name, let since): return PadStatementImportCopy.heldBy(name, since: since)
        case .offline: return PadStatementImportCopy.offline
        case .noImportAccess: return PadStatementImportCopy.noImportAccess
        }
    }
}

/// The words of the iPad's statement import.
public enum PadStatementImportCopy {
    /// "Mac is importing (started 10:42). Try again when it finishes."
    public static func heldBy(_ name: String, since: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return "\(name) is importing (started \(formatter.string(from: since))). Try again when it finishes."
    }

    public static let offline = "Connect to the internet to import"
    public static let noImportAccess = "This statement is imported on the Mac. Send it to the Mac to import it there."
    public static let importButton = "Import"
    public static let sendToMac = "Send to the Mac"
    public static let finishOnMac = "Finish on the Mac"
    public static let undo = "Undo import"
    /// The run's entry point, as the Mac's import history lists it: "Imported on Pablo's iPad".
    public static func entryPoint(deviceName: String) -> String { "Imported on \(deviceName)" }
    /// What the filed-year question calls the import.
    public static func edit(_ title: String) -> String { "Imported \(title)" }
    public static func undone(_ result: ImportUndoResult) -> String {
        "Import undone: \(result.rowsRemoved) \(result.rowsRemoved == 1 ? "row" : "rows") removed"
    }
}

/// A bank statement imported on the iPad (step 19) with the Mac's import engine (`ImportApplier`: the run, its change
/// capture and sync batch, duplicates skipped, follow-on matching, waiting documents linked to new rows only, the
/// filed-year backstop), its one write through the device writer (`ImportApplier.apply(_:entryPoint:writer:edit:)`).
///
/// One device imports at a time: with sync on, Import takes the household's import lease first (`ImportLeasing`,
/// sync spec §5.2) and needs a moment online. While another device holds it Import waits; a lease expires on its own
/// (30 minutes after it was last taken or renewed) so a device that stopped never blocks the household. The lease of
/// an import made here stays held while its batch uploads (renewed by the push) and is released by the push once the
/// batch's close is up; an import that didn't happen gives it back at once.
///
/// Who may import: Edit on Import, and (with sync) the account's import going to a zone this device writes (the
/// household for a member's iPad). Anyone else gets "Send to the Mac" (`CheckAndLink.save`).
public struct PadStatementImport: Sendable {
    private let dbQueue: DatabaseQueue
    private let library: EvidenceLibrary
    private let leases: (any ImportLeasing)?
    private let deviceName: String

    /// `leases`: the sync engine; nil without sync (no lease to take, every zone written). `deviceName`: what the Mac's
    /// import history shows (the lease's device name when nil).
    public init(dbQueue: DatabaseQueue, library: EvidenceLibrary, leases: (any ImportLeasing)?, deviceName: String? = nil) {
        self.dbQueue = dbQueue
        self.library = library
        self.leases = leases
        self.deviceName = deviceName ?? leases?.leaseDevice.name ?? "iPad"
    }

    // MARK: Who may import

    /// Whether `actor` may import a statement of `accountId` on a device pushing `zones` (nil: every zone): Edit on
    /// Import, and the run's zone (`SyncZoneRouter.importZone`) one the device writes. Before ownership is confirmed
    /// everything goes to the household.
    public static func canImport(_ actor: AccessActor, accountId: Int64?, zones: [String]?, db: Database) throws -> Bool {
        guard try AccessPolicy.can(actor, .edit, .import, db: db) else { return false }
        guard let zones else { return true }
        guard let accountId, try SharingSetup.isConfirmed(db: db) else { return zones.contains(SyncZones.household) }
        return zones.contains(try SyncZoneRouter(db: db).importZone(account: accountId))
    }

    private func access(_ accountId: Int64?, writer: DeviceWriter) async throws -> Bool {
        guard let actor = try await writer.actor() else { throw DeviceWriteRefusal.notLinkedYet }
        let zones = await leases?.importZones()
        return try await dbQueue.read { db in try Self.canImport(actor, accountId: accountId, zones: zones, db: db) }
    }

    /// What the sheet offers for a statement of `accountId`. Reads the lease (online); never writes.
    public func route(accountId: Int64?, writer: DeviceWriter) async -> PadImportRoute {
        guard (try? await access(accountId, writer: writer)) == true else { return .sendToMac }
        guard let leases else { return .importHere }
        do {
            if let holder = try await leases.importLeaseHolder(), holder.holderId != leases.leaseDevice.id {
                return .heldBy(deviceName: holder.holderName, since: holder.takenAt)
            }
            return .importHere
        } catch {
            return .offline
        }
    }

    /// The statement's account, read (a BBVA or UK statement staged against it), else nil.
    public static func accountId(of item: ImportItem) -> Int64? {
        switch item.effect {
        case .bbvaStatement(let effect): return effect.currentAccountId
        case .ukStatement(let effect): return effect.accountId
        default: return nil
        }
    }

    // MARK: Import

    /// Imports `plan` (one statement, confirmed: nothing left to answer) as one run: the lease taken first (with sync
    /// on), then `ImportApplier` through `writer`. Refused (`PadImportRefusal`, `DeviceWriteRefusal`, `AccessDenied`,
    /// `ImportApplyError`): nothing is written, and a lease taken for it is given back.
    public func importStatement(_ plan: ImportPlan, title: String, writer: DeviceWriter, now: Date = Date()) async throws -> ImportRunSummary {
        let accountId = plan.items.first(where: { $0.parentId == nil }).flatMap(Self.accountId(of:))
        guard try await access(accountId, writer: writer) else { throw PadImportRefusal.noImportAccess }
        let took = try await takeLease(now: now)
        do {
            return try await ImportApplier(dbQueue: dbQueue, databasePath: nil, library: library)
                .apply(plan, entryPoint: PadStatementImportCopy.entryPoint(deviceName: deviceName), writer: writer,
                       edit: PadStatementImportCopy.edit(title), reasons: plan.resolutionReasons, now: now)
        } catch {
            if took { await giveBack() }
            throw error
        }
    }

    /// Undoes run `runId` (made here or on the Mac) as the device's user: the lease taken first, as for an import
    /// (`ImportUndo`, sync spec §5.2: an Undo is a batch too).
    public func undo(runId: Int64, writer: DeviceWriter, now: Date = Date()) async throws -> ImportUndoResult {
        guard let actor = try await writer.actor() else { throw DeviceWriteRefusal.notLinkedYet }
        guard try await dbQueue.read({ db in try AccessPolicy.can(actor, .edit, .import, db: db) }) else {
            throw PadImportRefusal.noImportAccess
        }
        let took = try await takeLease(now: now)
        do {
            let result = try ImportUndo.undo(dbQueue: dbQueue, library: library, runId: runId, actor: actor, now: now)
            writer.didWrite()
            return result
        } catch {
            if took { await giveBack() }
            throw error
        }
    }

    /// Takes the lease (with sync on), unless this device still holds an unexpired one (a batch of its own still
    /// uploading: taking it again would forget that). True when it took it now.
    private func takeLease(now: Date) async throws -> Bool {
        guard let leases else { return false }
        if let held = try await dbQueue.read({ db in try SyncImportGate.heldLease(db: db) }), held.record.expiresAt > now {
            return false
        }
        do {
            try await leases.acquireImportLease()
            return true
        } catch ImportLeaseError.heldBy(let name, let until) {
            let since = (try? await leases.importLeaseHolder())?.takenAt ?? until.addingTimeInterval(-ImportLease.duration)
            throw PadImportRefusal.heldBy(deviceName: name, since: since)
        } catch {
            if Self.isOffline(error) { throw PadImportRefusal.offline }
            throw error
        }
    }

    private func giveBack() async {
        try? await leases?.releaseImportLease()
    }

    /// A failure that passes with a connection.
    static func isOffline(_ error: Error) -> Bool {
        switch error {
        case LeaseStoreError.unavailable: return true
        case let transport as SyncTransportError: return transport.isPassing
        case is URLError: return true
        default: return false
        }
    }
}
