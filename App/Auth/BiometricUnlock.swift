// App/Auth/BiometricUnlock.swift
import Foundation
import LocalAuthentication
import Security
import BudgetCore
import OSLog

/// Picks how Touch ID works on this build (auth spec §8). The decisions live in BudgetCore
/// (`KeychainBiometricEnrolment`, `DefaultsBiometricEnrolment`); this file holds only the Keychain and
/// `LAContext` calls.
@MainActor
enum BiometricUnlock {
    /// Probes the data-protection Keychain once with a throwaway item. Only `errSecMissingEntitlement`
    /// (no team signature) selects the `LAContext`-only fallback; any other failure is logged and the
    /// Keychain is still used. `scope` is the database's `LocalSetting.databaseId`.
    static func make(scope: String, defaults: UserDefaults = .standard) -> any BiometricUnlocker {
        let status = KeychainBiometricUnlock.probe()
        if status == errSecMissingEntitlement {
            return DefaultsBiometricEnrolment(defaults: defaults, scope: scope, biometry: LAContextBiometricUnlock())
        }
        if status != errSecSuccess {
            authLog.error("Keychain probe failed with \(status, privacy: .public); keeping Keychain-bound Touch ID")
        }
        return KeychainBiometricEnrolment(store: KeychainBiometricUnlock(), index: DefaultsEnrolmentIndex(defaults: defaults),
                                          scope: scope, isAvailable: { LAContextBiometricUnlock.canUseBiometrics() })
    }

    /// For the snapshot build: never touches the Keychain or asks for Touch ID.
    static func snapshot(scope: String, defaults: UserDefaults) -> any BiometricUnlocker {
        DefaultsBiometricEnrolment(defaults: defaults, scope: scope, biometry: LAContextBiometricUnlock())
    }
}

/// Status codes only, never secrets or account names.
private let authLog = Logger(subsystem: "com.personal.budget", category: "Auth")

/// One `.biometryCurrentSet` item per enrolled app user in the data-protection Keychain: service
/// `ubberninja.mango.unlock`, account `"<databaseId>:<appUserId>"`, holding a random 32-byte secret.
@MainActor
final class KeychainBiometricUnlock: BiometricSecretStore {
    nonisolated static let service = "ubberninja.mango.unlock"
    nonisolated private static let probeService = "ubberninja.mango.unlock.probe"

    /// The first `keychain-access-groups` entry of this build's signature (`<team prefix>ubberninja.mango`).
    private static let accessGroup: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) else { return nil }
        return (value as? [String])?.first
    }()

    private static func baseQuery(service: String = service) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecUseDataProtectionKeychain: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }

    /// The status of adding a throwaway item: `errSecMissingEntitlement` means no team signature.
    static func probe() -> OSStatus {
        var add = baseQuery(service: probeService)
        add[kSecAttrAccount] = "probe"
        add[kSecValueData] = Data([0])
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { status = errSecSuccess }
        var delete = baseQuery(service: probeService)
        delete[kSecAttrAccount] = "probe"
        SecItemDelete(delete as CFDictionary)
        return status
    }

    /// The items' access control: this Mac's current fingerprints, while the Mac is unlocked. Adding an item
    /// with it asks for nothing (enrolment never shows Touch ID); reading one needs Touch ID.
    private static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .biometryCurrentSet, &error) else {
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? Int(errSecParam)
            authLog.error("Touch ID access control couldn't be made: \(code, privacy: .public)")
            throw BiometricUnlockError.keychain(OSStatus(truncatingIfNeeded: code))
        }
        return access
    }

    func add(secret: Data, account: String) throws {
        let access = try Self.accessControl()
        var query = Self.baseQuery()
        query[kSecAttrAccount] = account
        query[kSecValueData] = secret
        query[kSecAttrAccessControl] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            authLog.error("Touch ID enrol: SecItemAdd returned \(status, privacy: .public)")
            throw BiometricUnlockError.keychain(status)
        }
    }

    /// Touch ID first, in the lock screen's own view: the prompt's context (paired with the embedded
    /// `LAAuthenticationView`) evaluates the items' access control, so the finger is asked for in Mango, never
    /// in the system's panel. Then the secret is read with that already-authenticated context and interaction
    /// not allowed: the Keychain accepts the context without asking again (SecItem.h,
    /// `kSecUseAuthenticationContext`), and if it ever wanted to ask it fails with
    /// `errSecInteractionNotAllowed` instead of showing a panel. Unlocking still needs the secret itself.
    func read(account: String, reason: String, prompt: any BiometricPromptContext) async throws -> BiometricSecretRead {
        guard let inline = prompt as? InlineTouchIDPrompt else { throw BiometricUnlockError.unavailable }
        let context = inline.context
        context.localizedReason = reason
        do {
            guard try await context.evaluateAccessControl(try Self.accessControl(), operation: .useItem,
                                                          localizedReason: reason) else { return .cancelled }
        } catch let error as LAError {
            authLog.notice("Touch ID unlock: evaluateAccessControl failed with \(error.code.rawValue, privacy: .public)")
            let end = TouchIDAttemptEnd.classify(laErrorCode: error.code.rawValue)
            if end == .cancelled { return .cancelled }
            throw end.unlockError ?? error
        }
        context.interactionNotAllowed = true
        var query = Self.baseQuery()
        query[kSecAttrAccount] = account
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context
        let request = UncheckedQuery(query: query)
        // Off the main thread: a Keychain call can take a moment.
        let (status, data) = await Task.detached(priority: .userInitiated) { () -> (OSStatus, Data?) in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request.query as CFDictionary, &result)
            return (status, result as? Data)
        }.value
        if status != errSecSuccess {
            authLog.notice("Touch ID unlock: SecItemCopyMatching returned \(status, privacy: .public)")
        }
        switch status {
        case errSecSuccess: return data.map { .secret($0) } ?? .notFound
        case errSecItemNotFound: return .notFound
        case errSecUserCanceled: return .cancelled
        case errSecAuthFailed: throw BiometricUnlockError.notRecognised
        default: throw BiometricUnlockError.keychain(status)
        }
    }

    func delete(account: String) {
        var query = Self.baseQuery()
        query[kSecAttrAccount] = account
        SecItemDelete(query as CFDictionary)
    }
}

/// A Keychain query handed to the background read; built and used once, never shared.
private struct UncheckedQuery: @unchecked Sendable {
    let query: [CFString: Any]
}

/// The fallback for builds without a team: Touch ID through `LAContext` alone (auth spec §8).
@MainActor
final class LAContextBiometricUnlock: BiometryCheck {
    static func canUseBiometrics() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var isAvailable: Bool { Self.canUseBiometrics() }

    var domainState: Data? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        // `evaluatedPolicyDomainState`'s successor: changes whenever a fingerprint is added or removed.
        return context.domainState.biometry.stateHash
    }

    /// Evaluated on the prompt's context, so it asks in the lock screen's embedded view.
    func evaluate(reason: String, prompt: any BiometricPromptContext) async throws -> Bool {
        guard let inline = prompt as? InlineTouchIDPrompt else { throw BiometricUnlockError.unavailable }
        do {
            return try await inline.context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError {
            let end = TouchIDAttemptEnd.classify(laErrorCode: error.code.rawValue)
            if end == .cancelled { return false }
            throw end.unlockError ?? error
        }
    }
}
