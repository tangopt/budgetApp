// App/Auth/BiometricUnlock.swift
import Foundation
import LocalAuthentication
import Security
import BudgetCore

/// Picks how Touch ID works on this build (auth spec §8). The decisions live in BudgetCore
/// (`KeychainBiometricEnrolment`, `DefaultsBiometricEnrolment`); this file holds only the Keychain and
/// `LAContext` calls.
@MainActor
enum BiometricUnlock {
    /// Probes the data-protection Keychain once with a throwaway item. Without a team signature it answers
    /// `errSecMissingEntitlement`, and the `LAContext`-only fallback is used instead.
    static func make(defaults: UserDefaults = .standard) -> any BiometricUnlocker {
        if KeychainBiometricUnlock.probe() {
            let keychain = KeychainBiometricUnlock()
            return KeychainBiometricEnrolment(store: keychain, isAvailable: { LAContextBiometricUnlock.canUseBiometrics() })
        }
        return DefaultsBiometricEnrolment(defaults: defaults, biometry: LAContextBiometricUnlock())
    }

    /// For the snapshot build: never touches the Keychain or asks for Touch ID.
    static func snapshot(defaults: UserDefaults) -> any BiometricUnlocker {
        DefaultsBiometricEnrolment(defaults: defaults, biometry: LAContextBiometricUnlock())
    }
}

/// One `.biometryCurrentSet` item per enrolled app user in the data-protection Keychain: service
/// `ubberninja.mango.unlock`, account `"<appUserId>"`, holding a random 32-byte secret.
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

    /// True when this build can use the data-protection Keychain (it has a team signature).
    static func probe() -> Bool {
        var add = baseQuery(service: probeService)
        add[kSecAttrAccount] = "probe"
        add[kSecValueData] = Data([0])
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { status = errSecSuccess }
        var delete = baseQuery(service: probeService)
        delete[kSecAttrAccount] = "probe"
        SecItemDelete(delete as CFDictionary)
        return status == errSecSuccess
    }

    func add(secret: Data, appUserId: Int64) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .biometryCurrentSet, &error) else {
            throw BiometricUnlockError.keychain(errSecParam)
        }
        var query = Self.baseQuery()
        query[kSecAttrAccount] = String(appUserId)
        query[kSecValueData] = secret
        query[kSecAttrAccessControl] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw BiometricUnlockError.keychain(status) }
    }

    func read(appUserId: Int64, reason: String) async throws -> BiometricSecretRead {
        let context = LAContext()
        context.localizedReason = reason
        var query = Self.baseQuery()
        query[kSecAttrAccount] = String(appUserId)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context
        let request = UncheckedQuery(query: query)
        // The Touch ID sheet blocks the calling thread until answered, so never on the main thread.
        let (status, data) = await Task.detached(priority: .userInitiated) { () -> (OSStatus, Data?) in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request.query as CFDictionary, &result)
            return (status, result as? Data)
        }.value
        switch status {
        case errSecSuccess: return data.map { .secret($0) } ?? .notFound
        case errSecItemNotFound: return .notFound
        case errSecUserCanceled, errSecAuthFailed: return .cancelled
        default: throw BiometricUnlockError.keychain(status)
        }
    }

    func delete(appUserId: Int64) {
        var query = Self.baseQuery()
        query[kSecAttrAccount] = String(appUserId)
        SecItemDelete(query as CFDictionary)
    }

    func storedIds() -> Set<Int64> {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = Self.baseQuery()
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        query[kSecUseAuthenticationContext] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return Set(items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(Int64.init) })
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

    func evaluate(reason: String) async throws -> Bool {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .authenticationFailed, .userFallback].contains(error.code) {
            return false
        }
    }
}
