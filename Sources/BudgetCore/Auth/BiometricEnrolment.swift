import Foundation
import Security

/// Touch ID sign-in on this Mac (auth spec §8). Enrolment is device-local: it lives in this Mac's Keychain
/// or preferences, never in the database, so a copied database carries none.
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

/// Enrolment as a list of app user ids in this Mac's defaults, stored with the fingerprint set it was made
/// under. A different fingerprint set drops every enrolment.
@MainActor
public final class DefaultsBiometricEnrolment: BiometricUnlocker {
    public static let enrolledKey = "auth.enrolledAppUserIds"
    public static let domainStateKey = "auth.biometryDomainState"

    private let defaults: UserDefaults
    private let biometry: BiometryCheck

    public init(defaults: UserDefaults, biometry: BiometryCheck) {
        self.defaults = defaults
        self.biometry = biometry
    }

    public var isAvailable: Bool { biometry.isAvailable }

    public func enrol(appUserId: Int64) async throws {
        guard biometry.isAvailable, let state = biometry.domainState else { throw BiometricUnlockError.unavailable }
        let ids = enrolledIds().union([appUserId])
        defaults.set(ids.sorted().map { NSNumber(value: $0) }, forKey: Self.enrolledKey)
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
        let ids = storedIds().subtracting([appUserId])
        if ids.isEmpty {
            clear()
        } else {
            defaults.set(ids.sorted().map { NSNumber(value: $0) }, forKey: Self.enrolledKey)
        }
    }

    public func enrolledIds() -> Set<Int64> {
        let ids = storedIds()
        guard !ids.isEmpty else { return [] }
        guard let stored = defaults.data(forKey: Self.domainStateKey), stored == biometry.domainState else {
            clear()
            return []
        }
        return ids
    }

    private func storedIds() -> Set<Int64> {
        Set((defaults.array(forKey: Self.enrolledKey) as? [NSNumber] ?? []).map(\.int64Value))
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

/// The Keychain calls the Keychain-bound unlock needs: one `.biometryCurrentSet` item per app user.
@MainActor
public protocol BiometricSecretStore: AnyObject {
    func add(secret: Data, appUserId: Int64) throws
    /// Reading asks for Touch ID.
    func read(appUserId: Int64, reason: String) async throws -> BiometricSecretRead
    func delete(appUserId: Int64)
    /// The app users with an item, read without asking for Touch ID.
    func storedIds() -> Set<Int64>
}

/// Each enrolled user holds a random 32-byte secret only their fingerprints on this Mac can read. An item
/// the system has invalidated reads as not found; that drops the enrolment, so the password is asked once.
@MainActor
public final class KeychainBiometricEnrolment: BiometricUnlocker {
    public static let secretLength = 32

    private let store: BiometricSecretStore
    private let availability: @MainActor () -> Bool

    public init(store: BiometricSecretStore, isAvailable: @escaping @MainActor () -> Bool) {
        self.store = store
        self.availability = isAvailable
    }

    public var isAvailable: Bool { availability() }

    public func enrol(appUserId: Int64) async throws {
        guard isAvailable else { throw BiometricUnlockError.unavailable }
        var secret = Data(count: Self.secretLength)
        let status = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, Self.secretLength, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BiometricUnlockError.keychain(status) }
        store.delete(appUserId: appUserId)
        try store.add(secret: secret, appUserId: appUserId)
    }

    public func unlock(appUserId: Int64, reason: String) async throws -> Bool {
        guard store.storedIds().contains(appUserId) else { throw BiometricUnlockError.notEnrolled }
        switch try await store.read(appUserId: appUserId, reason: reason) {
        case .secret(let secret):
            return secret.count == Self.secretLength
        case .cancelled:
            return false
        case .notFound:
            store.delete(appUserId: appUserId)
            throw BiometricUnlockError.notEnrolled
        }
    }

    public func remove(appUserId: Int64) {
        store.delete(appUserId: appUserId)
    }

    public func enrolledIds() -> Set<Int64> {
        store.storedIds()
    }
}
