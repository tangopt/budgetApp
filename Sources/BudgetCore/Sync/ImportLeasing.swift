import Foundation

/// The household import lease as a device's import needs it (step 19): who holds it, take it, give it up. The sync
/// engine is the app's (`SyncEngineCore`); tests give their own. Taking it stores it in `SyncImportGate`, which the
/// import engine requires once sync is on; the push renews a used lease while its batch uploads and releases it once
/// the batch's close is uploaded (sync spec §5.2).
public protocol ImportLeasing: Sendable {
    /// The device a lease taken here names.
    var leaseDevice: SyncDevice { get }
    /// The zones this device pushes; nil: every zone (no sync placement to respect).
    func importZones() async -> [String]?
    /// Who holds the lease now (this device included), or nil. Throws when the server can't be reached.
    func importLeaseHolder() async throws -> ImportLeaseRecord?
    /// Takes the lease, or throws `ImportLeaseError.heldBy` while another device holds it.
    func acquireImportLease() async throws
    /// Gives the lease up (nothing was imported under it).
    func releaseImportLease() async throws
    /// Brings in what other devices sent (a pull), so their imports are here before this one is written.
    func catchUp() async throws
}

extension SyncEngineCore: ImportLeasing {
    public func catchUp() async throws {
        _ = try await pull()
    }
}

/// The lease of whichever sync engine runs now (the app's: it is made again when the device's write mode changes),
/// read at each call. With no engine running nothing can be leased: the holder and Import say offline, and no zone is
/// checked (Import says offline).
public struct CurrentEngineLeasing: ImportLeasing {
    public let leaseDevice: SyncDevice
    private let current: @Sendable () async -> (any ImportLeasing)?

    public init(device: SyncDevice, current: @escaping @Sendable () async -> (any ImportLeasing)?) {
        leaseDevice = device
        self.current = current
    }

    /// With no engine running: nil (no placement to judge), so the holder's read says offline rather than Send to the Mac.
    public func importZones() async -> [String]? {
        guard let engine = await current() else { return nil }
        return await engine.importZones()
    }

    public func importLeaseHolder() async throws -> ImportLeaseRecord? {
        guard let engine = await current() else { throw LeaseStoreError.unavailable("sync isn't running") }
        return try await engine.importLeaseHolder()
    }

    public func acquireImportLease() async throws {
        guard let engine = await current() else { throw LeaseStoreError.unavailable("sync isn't running") }
        try await engine.acquireImportLease()
    }

    public func releaseImportLease() async throws {
        try await current()?.releaseImportLease()
    }

    public func catchUp() async throws {
        guard let engine = await current() else { throw LeaseStoreError.unavailable("sync isn't running") }
        try await engine.catchUp()
    }
}
