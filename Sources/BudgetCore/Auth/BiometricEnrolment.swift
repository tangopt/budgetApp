import Foundation
import Security

/// Touch ID sign-in on this Mac (auth spec §8). Enrolment is device-local: it lives in this Mac's Keychain
/// or preferences, never in the database, keyed by the database's `LocalSetting.databaseId` (the `scope`)
/// and the app user id, so another database whose users share ids has no enrolment here.
@MainActor
public protocol BiometricUnlocker: AnyObject {
    /// This Mac has Touch ID with at least one fingerprint.
    var isAvailable: Bool { get }
    func enrol(appUserId: Int64) async throws
    /// True when Touch ID confirmed the user; false when it was cancelled or failed. Throws
    /// `BiometricUnlockError.notEnrolled` when the user isn't (or is no longer) enrolled on this Mac.
    func unlock(appUserId: Int64, reason: String) async throws -> Bool
    func remove(appUserId: Int64)
    func enrolledIds() -> Set<Int64>
}

public enum BiometricUnlockError: Error, Equatable, Sendable {
    case unavailable
    /// Never enrolled here, or dropped because the Mac's fingerprints changed: sign in with the password.
    case notEnrolled
    case keychain(OSStatus)
}

// MARK: - LAContext-only fallback (builds without a team)

/// The `LAContext` calls the fallback needs.
@MainActor
public protocol BiometryCheck: AnyObject {
    var isAvailable: Bool { get }
    /// `LAContext.domainState.biometry.stateHash` (formerly `evaluatedPolicyDomainState`): changes whenever a fingerprint is added or removed.
    var domainState: Data? { get }
    /// True when the owner passed Touch ID; false when they cancelled or it failed.
    func evaluate(reason: String) async throws -> Bool
}

/// Enrolment as a list of "<scope>:<appUserId>" entries in this Mac's defaults, stored with the fingerprint
/// set it was made under. A different fingerprint set drops every enrolment, for every database.
@MainActor
public final class DefaultsBiometricEnrolment: BiometricUnlocker {
    public static let enrolledKey = "auth.enrolledAppUserIds"
    public static let domainStateKey = "auth.biometryDomainState"

    private let defaults: UserDefaults
    private let scope: String
    private let biometry: BiometryCheck

    public init(defaults: UserDefaults, scope: String, biometry: BiometryCheck) {
        self.defaults = defaults
        self.scope = scope
        self.biometry = biometry
    }

    private func entry(_ appUserId: Int64) -> String { "\(scope):\(appUserId)" }

    public var isAvailable: Bool { biometry.isAvailable }

    public func enrol(appUserId: Int64) async throws {
        guard biometry.isAvailable, let state = biometry.domainState else { throw BiometricUnlockError.unavailable }
        _ = enrolledIds()   // drops entries made under another fingerprint set first
        defaults.set(storedEntries().union([entry(appUserId)]).sorted(), forKey: Self.enrolledKey)
        defaults.set(state, forKey: Self.domainStateKey)
    }

    public func unlock(appUserId: Int64, reason: String) async throws -> Bool {
        guard enrolledIds().contains(appUserId) else { throw BiometricUnlockError.notEnrolled }
        guard try await biometry.evaluate(reason: reason) else { return false }
        // The fingerprint set may have changed while the prompt was up.
        guard enrolledIds().contains(appUserId) else { throw BiometricUnlockError.notEnrolled }
        return true
    }

    public func remove(appUserId: Int64) {
        let entries = storedEntries().subtracting([entry(appUserId)])
        if entries.isEmpty {
            clear()
        } else {
            defaults.set(entries.sorted(), forKey: Self.enrolledKey)
        }
    }

    public func enrolledIds() -> Set<Int64> {
        let entries = storedEntries()
        guard !entries.isEmpty else { return [] }
        // No current state (Touch ID locked out or unavailable for now): nothing to offer, nothing dropped.
        guard let current = biometry.domainState else { return [] }
        guard let stored = defaults.data(forKey: Self.domainStateKey), stored == current else {
            clear()
            return []
        }
        let prefix = "\(scope):"
        return Set(entries.compactMap { $0.hasPrefix(prefix) ? Int64($0.dropFirst(prefix.count)) : nil })
    }

    private func storedEntries() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.enrolledKey) ?? [])
    }

    private func clear() {
        defaults.removeObject(forKey: Self.enrolledKey)
        defaults.removeObject(forKey: Self.domainStateKey)
    }
}

// MARK: - Keychain-bound (team-signed builds)

public enum BiometricSecretRead: Equatable, Sendable {
    case secret(Data)
    /// `errSecItemNotFound`: never enrolled, or invalidated by a change of fingerprints.
    case notFound
    /// The user cancelled Touch ID, or it failed.
    case cancelled
}

/// The Keychain calls the Keychain-bound unlock needs: one `.biometryCurrentSet` item per enrolled
/// "<scope>:<appUserId>" account.
@MainActor
public protocol BiometricSecretStore: AnyObject {
    func add(secret: Data, account: String) throws
    /// Reading asks for Touch ID.
    func read(account: String, reason: String) async throws -> BiometricSecretRead
    func delete(account: String)
    /// The accounts with an item, read without asking for Touch ID.
    func storedAccounts() -> Set<String>
}

/// Each enrolled user holds a random 32-byte secret only their fingerprints on this Mac can read. An item
/// the system has invalidated reads as not found; that drops the enrolment, so the password is asked once.
@MainActor
public final class KeychainBiometricEnrolment: BiometricUnlocker {
    public static let secretLength = 32

    private let store: BiometricSecretStore
    private let scope: String
    private let availability: @MainActor () -> Bool

    public init(store: BiometricSecretStore, scope: String, isAvailable: @escaping @MainActor () -> Bool) {
        self.store = store
        self.scope = scope
        self.availability = isAvailable
    }

    private func account(_ appUserId: Int64) -> String { "\(scope):\(appUserId)" }

    public var isAvailable: Bool { availability() }

    public func enrol(appUserId: Int64) async throws {
        guard isAvailable else { throw BiometricUnlockError.unavailable }
        var secret = Data(count: Self.secretLength)
        let status = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, Self.secretLength, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BiometricUnlockError.keychain(status) }
        store.delete(account: account(appUserId))
        try store.add(secret: secret, account: account(appUserId))
    }

    public func unlock(appUserId: Int64, reason: String) async throws -> Bool {
        guard enrolledIds().contains(appUserId) else { throw BiometricUnlockError.notEnrolled }
        switch try await store.read(account: account(appUserId), reason: reason) {
        case .secret(let secret):
            return secret.count == Self.secretLength
        case .cancelled:
            return false
        case .notFound:
            store.delete(account: account(appUserId))
            throw BiometricUnlockError.notEnrolled
        }
    }

    public func remove(appUserId: Int64) {
        store.delete(account: account(appUserId))
    }

    public func enrolledIds() -> Set<Int64> {
        let prefix = "\(scope):"
        return Set(store.storedAccounts().compactMap { $0.hasPrefix(prefix) ? Int64($0.dropFirst(prefix.count)) : nil })
    }
}
