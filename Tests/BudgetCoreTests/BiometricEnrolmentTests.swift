import XCTest
@testable import BudgetCore

/// Stands in for `LAContext`: the Mac's current fingerprint set and the answer to the next Touch ID check.
@MainActor
private final class FakeBiometry: BiometryCheck {
    var isAvailable = true
    var domainState: Data? = Data([1, 2, 3])
    var answer = true
    private(set) var evaluations = 0
    func evaluate(reason: String) async throws -> Bool {
        evaluations += 1
        return answer
    }
}

/// Stands in for the data-protection Keychain. `invalidate()` is what macOS does to `.biometryCurrentSet`
/// items when the fingerprints change: they read as not found.
@MainActor
private final class FakeSecretStore: BiometricSecretStore {
    var secrets: [Int64: Data] = [:]
    var invalidated: Set<Int64> = []
    var cancelNext = false
    func add(secret: Data, appUserId: Int64) throws { secrets[appUserId] = secret }
    func read(appUserId: Int64, reason: String) async throws -> BiometricSecretRead {
        if cancelNext { cancelNext = false; return .cancelled }
        guard let secret = secrets[appUserId], !invalidated.contains(appUserId) else { return .notFound }
        return .secret(secret)
    }
    func delete(appUserId: Int64) { secrets[appUserId] = nil; invalidated.remove(appUserId) }
    func storedIds() -> Set<Int64> { Set(secrets.keys) }
    func invalidateAll() { invalidated = Set(secrets.keys) }
}

@MainActor
final class BiometricEnrolmentTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "BiometricEnrolmentTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: LAContext fallback (unsigned builds)

    func testChangedBiometryDropsEnrolment() async throws {
        let biometry = FakeBiometry()
        let enrolment = DefaultsBiometricEnrolment(defaults: defaults, biometry: biometry)
        try await enrolment.enrol(appUserId: 7)
        XCTAssertEqual(enrolment.enrolledIds(), [7])
        let unlocked = try await enrolment.unlock(appUserId: 7, reason: "test")
        XCTAssertTrue(unlocked)

        biometry.domainState = Data([9, 9, 9])   // a fingerprint added or removed
        XCTAssertEqual(enrolment.enrolledIds(), [])
        do {
            _ = try await enrolment.unlock(appUserId: 7, reason: "test")
            XCTFail("a dropped enrolment must not unlock")
        } catch {
            XCTAssertEqual(error as? BiometricUnlockError, .notEnrolled)
        }
        // Re-enrolling records the new fingerprint set.
        try await enrolment.enrol(appUserId: 7)
        XCTAssertEqual(enrolment.enrolledIds(), [7])
    }

    func testEnrolmentIsPerMacNotInDatabase() async throws {
        // Enrolment lives only in this Mac's defaults: a database (a copy, or a new one) whose users share
        // ids carries none of it, and another Mac's defaults have none.
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let enrolment = DefaultsBiometricEnrolment(defaults: defaults, biometry: FakeBiometry())
        try await enrolment.enrol(appUserId: 1)
        let tables = try await manager.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for table in tables {
            let sql = try await manager.dbQueue.read { db in
                try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = ?", arguments: [table]) ?? ""
            }
            XCTAssertFalse(sql.localizedCaseInsensitiveContains("biometr"), table)
            XCTAssertFalse(sql.localizedCaseInsensitiveContains("enrol"), table)
        }

        let otherSuite = "BiometricEnrolmentTests.other.\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherSuite)!
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let otherMac = DefaultsBiometricEnrolment(defaults: otherDefaults, biometry: FakeBiometry())
        XCTAssertEqual(otherMac.enrolledIds(), [])

        let keychainMac = KeychainBiometricEnrolment(store: FakeSecretStore(), isAvailable: { true })
        XCTAssertEqual(keychainMac.enrolledIds(), [])
        do {
            _ = try await keychainMac.unlock(appUserId: 1, reason: "test")
            XCTFail("no enrolment on this Mac")
        } catch {
            XCTAssertEqual(error as? BiometricUnlockError, .notEnrolled)
        }
    }

    func testRemoveClearsEnrolment() async throws {
        let enrolment = DefaultsBiometricEnrolment(defaults: defaults, biometry: FakeBiometry())
        try await enrolment.enrol(appUserId: 1)
        try await enrolment.enrol(appUserId: 2)
        enrolment.remove(appUserId: 1)
        XCTAssertEqual(enrolment.enrolledIds(), [2])
        enrolment.remove(appUserId: 2)
        XCTAssertEqual(enrolment.enrolledIds(), [])

        let store = FakeSecretStore()
        let keychain = KeychainBiometricEnrolment(store: store, isAvailable: { true })
        try await keychain.enrol(appUserId: 3)
        keychain.remove(appUserId: 3)
        XCTAssertEqual(keychain.enrolledIds(), [])
        XCTAssertTrue(store.secrets.isEmpty)
    }

    func testFallbackUnlockFollowsTheTouchIDAnswer() async throws {
        let biometry = FakeBiometry()
        let enrolment = DefaultsBiometricEnrolment(defaults: defaults, biometry: biometry)
        try await enrolment.enrol(appUserId: 4)
        biometry.answer = false
        let unlocked = try await enrolment.unlock(appUserId: 4, reason: "test")
        XCTAssertFalse(unlocked)
        XCTAssertEqual(enrolment.enrolledIds(), [4], "a cancelled check keeps the enrolment")
    }

    func testUnavailableBiometryRefusesEnrolment() async throws {
        let biometry = FakeBiometry()
        biometry.isAvailable = false
        let enrolment = DefaultsBiometricEnrolment(defaults: defaults, biometry: biometry)
        do {
            try await enrolment.enrol(appUserId: 1)
            XCTFail("no Touch ID, no enrolment")
        } catch {
            XCTAssertEqual(error as? BiometricUnlockError, .unavailable)
        }
        XCTAssertEqual(enrolment.enrolledIds(), [])
    }

    // MARK: Keychain-bound (team builds)

    func testKeychainEnrolStoresA32ByteSecretPerUser() async throws {
        let store = FakeSecretStore()
        let keychain = KeychainBiometricEnrolment(store: store, isAvailable: { true })
        try await keychain.enrol(appUserId: 1)
        try await keychain.enrol(appUserId: 2)
        XCTAssertEqual(store.secrets[1]?.count, 32)
        XCTAssertNotEqual(store.secrets[1], store.secrets[2])
        XCTAssertEqual(keychain.enrolledIds(), [1, 2])
        let unlocked = try await keychain.unlock(appUserId: 2, reason: "test")
        XCTAssertTrue(unlocked)
    }

    func testChangedBiometryDropsKeychainEnrolment() async throws {
        let store = FakeSecretStore()
        let keychain = KeychainBiometricEnrolment(store: store, isAvailable: { true })
        try await keychain.enrol(appUserId: 5)
        store.invalidateAll()   // errSecItemNotFound from here on
        do {
            _ = try await keychain.unlock(appUserId: 5, reason: "test")
            XCTFail("an invalidated item must not unlock")
        } catch {
            XCTAssertEqual(error as? BiometricUnlockError, .notEnrolled)
        }
        // Touch ID stops being offered; re-enrolling works again.
        XCTAssertEqual(keychain.enrolledIds(), [])
        try await keychain.enrol(appUserId: 5)
        let unlocked = try await keychain.unlock(appUserId: 5, reason: "test")
        XCTAssertTrue(unlocked)
    }

    func testKeychainCancelKeepsEnrolment() async throws {
        let store = FakeSecretStore()
        let keychain = KeychainBiometricEnrolment(store: store, isAvailable: { true })
        try await keychain.enrol(appUserId: 6)
        store.cancelNext = true
        let unlocked = try await keychain.unlock(appUserId: 6, reason: "test")
        XCTAssertFalse(unlocked)
        XCTAssertEqual(keychain.enrolledIds(), [6])
    }
}
