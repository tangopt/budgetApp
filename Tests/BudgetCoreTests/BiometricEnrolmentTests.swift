import XCTest
@testable import BudgetCore

/// Stands in for the lock screen's inline Touch ID prompt.
@MainActor
private final class FakePrompt: BiometricPromptContext {}

/// Stands in for `LAContext`: the Mac's current fingerprint set and the answer to the next Touch ID check.
/// `refusal` makes the next check throw (a finger not recognised, Touch ID locked out).
@MainActor
private final class FakeBiometry: BiometryCheck {
    var isAvailable = true
    var domainState: Data? = Data([1, 2, 3])
    var answer = true
    var refusal: BiometricUnlockError?
    private(set) var evaluations = 0
    private(set) var prompts: [ObjectIdentifier] = []
    func evaluate(reason: String, prompt: any BiometricPromptContext) async throws -> Bool {
        evaluations += 1
        prompts.append(ObjectIdentifier(prompt))
        if let refusal { throw refusal }
        return answer
    }
}

/// Stands in for the data-protection Keychain. `invalidate()` is what macOS does to `.biometryCurrentSet`
/// items when the fingerprints change: they read as not found.
/// `readStatus` makes every read throw that Keychain status (`errSecInteractionNotAllowed`, say), the way
/// a team build answers a query it won't serve; `failAdd` makes adding throw.
@MainActor
private final class FakeSecretStore: BiometricSecretStore {
    var secrets: [String: Data] = [:]
    var invalidated: Set<String> = []
    var cancelNext = false
    var readStatus: OSStatus?
    var failAdd: OSStatus?
    var refusal: BiometricUnlockError?
    private(set) var reads = 0
    private(set) var prompts: [ObjectIdentifier] = []
    func add(secret: Data, account: String) throws {
        if let failAdd { throw BiometricUnlockError.keychain(failAdd) }
        secrets[account] = secret
    }
    func read(account: String, reason: String, prompt: any BiometricPromptContext) async throws -> BiometricSecretRead {
        reads += 1
        prompts.append(ObjectIdentifier(prompt))
        if let refusal { throw refusal }
        if let readStatus { throw BiometricUnlockError.keychain(readStatus) }
        if cancelNext { cancelNext = false; return .cancelled }
        guard let secret = secrets[account], !invalidated.contains(account) else { return .notFound }
        return .secret(secret)
    }
    func delete(account: String) { secrets[account] = nil; invalidated.remove(account) }
    func invalidateAll() { invalidated = Set(secrets.keys) }
}

@MainActor
final class BiometricEnrolmentTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let prompt = FakePrompt()

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
        let enrolment = DefaultsBiometricEnrolment(defaults: defaults, scope: "db-a", biometry: biometry)
        try await enrolment.enrol(appUserId: 7)
        XCTAssertEqual(enrolment.enrolledIds(), [7])
        let unlocked = try await enrolment.unlock(appUserId: 7, reason: "test", prompt: prompt)
        XCTAssertTrue(unlocked)

        biometry.domainState = Data([9, 9, 9])   // a fingerprint added or removed
        XCTAssertEqual(enrolment.enrolledIds(), [])
        do {
            _ = try await enrolment.unlock(appUserId: 7, reason: "test", prompt: prompt)
            XCTFail("a dropped enrolment must not unlock")
        } catch {
            XCTAssertEqual(error as? BiometricUnlockError, .notEnrolled)
        }
        // Re-enrolling records the new fingerprint set.
        try await enrolment.enrol(appUserId: 7)
        XCTAssertEqual(enrolment.enrolledIds(), [7])
    }

    func testEnrolmentIsPerMacNotInDatabase() async throws {
        // Two databases whose app users share ids: enrolling user 1 of A on this Mac doesn't enrol user 1 of B
        // (a new database, or another household's), and another Mac's defaults have no enrolment at all.
        func database() throws -> (DatabaseManager, String, Int64) {
            let manager = try DatabaseManager(path: nil)
            try manager.migrate()
            return try manager.dbQueue.write { db in
                var person = Person(name: "Sam Example")
                try person.insert(db)
                let (user, _) = try AppUserStore.create(db, personId: person.id!, displayName: "Sam", password: "synthetic pass 1",
                                                        isAdmin: true, now: Date(timeIntervalSince1970: 0), rounds: 1_000)
                return (manager, try LocalSetting.databaseId(db), user.id!)
            }
        }
        let (_, idA, userA) = try database()
        let (_, idB, userB) = try database()
        XCTAssertEqual(userA, userB)
        XCTAssertNotEqual(idA, idB)

        let biometry = FakeBiometry()
        let onA = DefaultsBiometricEnrolment(defaults: defaults, scope: idA, biometry: biometry)
        let onB = DefaultsBiometricEnrolment(defaults: defaults, scope: idB, biometry: biometry)
        try await onA.enrol(appUserId: userA)
        XCTAssertEqual(onA.enrolledIds(), [userA])
        XCTAssertEqual(onB.enrolledIds(), [])
        do {
            _ = try await onB.unlock(appUserId: userB, reason: "test", prompt: prompt)
            XCTFail("another database's user must not unlock")
        } catch {
            XCTAssertEqual(error as? BiometricUnlockError, .notEnrolled)
        }
        onB.remove(appUserId: userB)
        XCTAssertEqual(onA.enrolledIds(), [userA], "removing B's user leaves A's enrolment")

        let store = FakeSecretStore()
        let keychainA = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults), scope: idA, isAvailable: { true })
        let keychainB = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults), scope: idB, isAvailable: { true })
        try await keychainA.enrol(appUserId: userA)
        XCTAssertEqual(keychainB.enrolledIds(), [])
        do {
            _ = try await keychainB.unlock(appUserId: userB, reason: "test", prompt: prompt)
            XCTFail("another database's user must not unlock")
        } catch {
            XCTAssertEqual(error as? BiometricUnlockError, .notEnrolled)
        }

        let otherSuite = "BiometricEnrolmentTests.other.\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherSuite)!
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        XCTAssertEqual(DefaultsBiometricEnrolment(defaults: otherDefaults, scope: idA, biometry: biometry).enrolledIds(), [])
    }

    func testDatabaseIdIsStableAndLocal() throws {
        let manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let first = try manager.dbQueue.write { try LocalSetting.databaseId($0) }
        let again = try manager.dbQueue.write { try LocalSetting.databaseId($0) }
        XCTAssertEqual(first, again)
        XCTAssertNotNil(UUID(uuidString: first))
    }

    func testUnavailableBiometryKeepsEnrolment() async throws {
        // Locked out, or the Touch ID sensor unavailable for now: no state to compare, nothing is dropped.
        let biometry = FakeBiometry()
        let enrolment = DefaultsBiometricEnrolment(defaults: defaults, scope: "db-a", biometry: biometry)
        try await enrolment.enrol(appUserId: 3)
        biometry.domainState = nil
        XCTAssertEqual(enrolment.enrolledIds(), [])
        biometry.domainState = Data([1, 2, 3])
        XCTAssertEqual(enrolment.enrolledIds(), [3])
    }

    func testRemoveClearsEnrolment() async throws {
        let enrolment = DefaultsBiometricEnrolment(defaults: defaults, scope: "db-a", biometry: FakeBiometry())
        try await enrolment.enrol(appUserId: 1)
        try await enrolment.enrol(appUserId: 2)
        enrolment.remove(appUserId: 1)
        XCTAssertEqual(enrolment.enrolledIds(), [2])
        enrolment.remove(appUserId: 2)
        XCTAssertEqual(enrolment.enrolledIds(), [])

        let store = FakeSecretStore()
        let keychain = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults), scope: "db-a", isAvailable: { true })
        try await keychain.enrol(appUserId: 3)
        keychain.remove(appUserId: 3)
        XCTAssertEqual(keychain.enrolledIds(), [])
        XCTAssertTrue(store.secrets.isEmpty)
    }

    func testFallbackUnlockFollowsTheTouchIDAnswer() async throws {
        let biometry = FakeBiometry()
        let enrolment = DefaultsBiometricEnrolment(defaults: defaults, scope: "db-a", biometry: biometry)
        try await enrolment.enrol(appUserId: 4)
        biometry.answer = false
        let unlocked = try await enrolment.unlock(appUserId: 4, reason: "test", prompt: prompt)
        XCTAssertFalse(unlocked)
        XCTAssertEqual(enrolment.enrolledIds(), [4], "a cancelled check keeps the enrolment")
    }

    func testUnavailableBiometryRefusesEnrolment() async throws {
        let biometry = FakeBiometry()
        biometry.isAvailable = false
        let enrolment = DefaultsBiometricEnrolment(defaults: defaults, scope: "db-a", biometry: biometry)
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
        let keychain = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults), scope: "db-a", isAvailable: { true })
        try await keychain.enrol(appUserId: 1)
        try await keychain.enrol(appUserId: 2)
        XCTAssertEqual(store.secrets["db-a:1"]?.count, 32)
        XCTAssertNotEqual(store.secrets["db-a:1"], store.secrets["db-a:2"])
        XCTAssertEqual(keychain.enrolledIds(), [1, 2])
        let unlocked = try await keychain.unlock(appUserId: 2, reason: "test", prompt: prompt)
        XCTAssertTrue(unlocked)
    }

    func testChangedBiometryDropsKeychainEnrolment() async throws {
        let store = FakeSecretStore()
        let keychain = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults), scope: "db-a", isAvailable: { true })
        try await keychain.enrol(appUserId: 5)
        store.invalidateAll()   // errSecItemNotFound from here on
        do {
            _ = try await keychain.unlock(appUserId: 5, reason: "test", prompt: prompt)
            XCTFail("an invalidated item must not unlock")
        } catch {
            XCTAssertEqual(error as? BiometricUnlockError, .notEnrolled)
        }
        // Touch ID stops being offered; re-enrolling works again.
        XCTAssertEqual(keychain.enrolledIds(), [])
        try await keychain.enrol(appUserId: 5)
        let unlocked = try await keychain.unlock(appUserId: 5, reason: "test", prompt: prompt)
        XCTAssertTrue(unlocked)
    }

    func testKeychainCancelKeepsEnrolment() async throws {
        let store = FakeSecretStore()
        let keychain = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults), scope: "db-a", isAvailable: { true })
        try await keychain.enrol(appUserId: 6)
        store.cancelNext = true
        let unlocked = try await keychain.unlock(appUserId: 6, reason: "test", prompt: prompt)
        XCTAssertFalse(unlocked)
        XCTAssertEqual(keychain.enrolledIds(), [6])
    }

    // MARK: Keychain-bound: the enrolment index

    func testEnrolledIdsNeverQueriesTheSecrets() async throws {
        // A team build may refuse any query of the access-controlled items without Touch ID: who is enrolled
        // must not depend on one.
        let store = FakeSecretStore()
        let keychain = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults),
                                                  scope: "db-a", isAvailable: { true })
        try await keychain.enrol(appUserId: 1)
        store.readStatus = errSecInteractionNotAllowed
        XCTAssertEqual(keychain.enrolledIds(), [1])
        XCTAssertEqual(store.reads, 0, "only an unlock reads a secret")
    }

    func testEnrolledIdsSurviveARelaunch() async throws {
        // A new enrolment object over the same Mac (the next launch) still knows who is enrolled.
        let store = FakeSecretStore()
        try await KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults),
                                             scope: "db-a", isAvailable: { true }).enrol(appUserId: 2)
        let relaunched = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults),
                                                    scope: "db-a", isAvailable: { true })
        XCTAssertEqual(relaunched.enrolledIds(), [2])
        let unlocked = try await relaunched.unlock(appUserId: 2, reason: "test", prompt: prompt)
        XCTAssertTrue(unlocked)
    }

    func testIndexAndSecretStayTogether() async throws {
        let store = FakeSecretStore()
        let index = DefaultsEnrolmentIndex(defaults: defaults)
        let keychain = KeychainBiometricEnrolment(store: store, index: index, scope: "db-a", isAvailable: { true })
        try await keychain.enrol(appUserId: 1)
        XCTAssertEqual(index.accounts(), ["db-a:1"])
        XCTAssertEqual(Set(store.secrets.keys), ["db-a:1"])

        keychain.remove(appUserId: 1)
        XCTAssertEqual(index.accounts(), [])
        XCTAssertTrue(store.secrets.isEmpty)

        // The fingerprints changed: the unlock's not-found drops the index entry too.
        try await keychain.enrol(appUserId: 1)
        store.invalidateAll()
        do {
            _ = try await keychain.unlock(appUserId: 1, reason: "test", prompt: prompt)
            XCTFail("an invalidated item must not unlock")
        } catch {
            XCTAssertEqual(error as? BiometricUnlockError, .notEnrolled)
        }
        XCTAssertEqual(index.accounts(), [])
        XCTAssertTrue(store.secrets.isEmpty)
    }

    func testFailedEnrolLeavesNoIndexEntry() async throws {
        let store = FakeSecretStore()
        let index = DefaultsEnrolmentIndex(defaults: defaults)
        let keychain = KeychainBiometricEnrolment(store: store, index: index, scope: "db-a", isAvailable: { true })
        try await keychain.enrol(appUserId: 1)
        store.failAdd = errSecMissingEntitlement
        do {
            try await keychain.enrol(appUserId: 1)
            XCTFail("a refused add must throw")
        } catch {
            XCTAssertEqual(error as? BiometricUnlockError, .keychain(errSecMissingEntitlement))
        }
        XCTAssertEqual(keychain.enrolledIds(), [], "the old secret went with the re-enrol")
        XCTAssertTrue(store.secrets.isEmpty)
    }

    func testKeychainReadErrorKeepsEnrolment() async throws {
        let store = FakeSecretStore()
        let keychain = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults),
                                                  scope: "db-a", isAvailable: { true })
        try await keychain.enrol(appUserId: 3)
        store.readStatus = errSecInteractionNotAllowed
        do {
            _ = try await keychain.unlock(appUserId: 3, reason: "test", prompt: prompt)
            XCTFail("a refused read must throw")
        } catch {
            XCTAssertEqual(error as? BiometricUnlockError, .keychain(errSecInteractionNotAllowed))
        }
        XCTAssertEqual(keychain.enrolledIds(), [3])
    }

    func testIndexIsApartFromTheFallbackList() async throws {
        // The fallback clears its list when the fingerprints change; the Keychain index must not go with it.
        let store = FakeSecretStore()
        let keychain = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults),
                                                  scope: "db-a", isAvailable: { true })
        try await keychain.enrol(appUserId: 4)
        let biometry = FakeBiometry()
        let fallback = DefaultsBiometricEnrolment(defaults: defaults, scope: "db-a", biometry: biometry)
        try await fallback.enrol(appUserId: 9)
        biometry.domainState = Data([7])
        XCTAssertEqual(fallback.enrolledIds(), [])
        XCTAssertEqual(keychain.enrolledIds(), [4])
    }

    func testKeychainErrorsReadAsSentences() {
        XCTAssertEqual(BiometricUnlockError.unavailable.localizedDescription, "Touch ID isn't available on this Mac.")
        for status in [errSecInteractionNotAllowed, errSecMissingEntitlement, errSecParam, OSStatus(-123_456)] {
            let text = BiometricUnlockError.keychain(status).localizedDescription
            XCTAssertTrue(text.hasPrefix("The Keychain refused it"), text)
            XCTAssertTrue(text.hasSuffix(".") && !text.hasSuffix(".."), text)
            XCTAssertFalse(text.contains("\(status)"), "the status code is for the log, not the user: \(text)")
            XCTAssertFalse(text.contains("BudgetCore"), text)
        }
    }

    // MARK: The inline prompt

    func testUnlockAsksInTheGivenPrompt() async throws {
        // Touch ID asks in Mango's own window: the lock screen's prompt reaches the check, every time.
        let biometry = FakeBiometry()
        let fallback = DefaultsBiometricEnrolment(defaults: defaults, scope: "db-a", biometry: biometry)
        try await fallback.enrol(appUserId: 1)
        _ = try await fallback.unlock(appUserId: 1, reason: "test", prompt: prompt)
        XCTAssertEqual(biometry.prompts, [ObjectIdentifier(prompt)])

        let store = FakeSecretStore()
        let keychain = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults), scope: "db-a", isAvailable: { true })
        try await keychain.enrol(appUserId: 1)
        _ = try await keychain.unlock(appUserId: 1, reason: "test", prompt: prompt)
        XCTAssertEqual(store.prompts, [ObjectIdentifier(prompt)])
    }

    func testRefusedFingerKeepsEnrolmentAndSaysWhy() async throws {
        for refusal in [BiometricUnlockError.notRecognised, .lockedOut] {
            let biometry = FakeBiometry()
            biometry.refusal = refusal
            let fallback = DefaultsBiometricEnrolment(defaults: defaults, scope: "db-a", biometry: biometry)
            try await fallback.enrol(appUserId: 2)
            do {
                _ = try await fallback.unlock(appUserId: 2, reason: "test", prompt: prompt)
                XCTFail("a refused finger must not unlock")
            } catch {
                XCTAssertEqual(error as? BiometricUnlockError, refusal)
            }
            XCTAssertEqual(fallback.enrolledIds(), [2])

            let store = FakeSecretStore()
            let keychain = KeychainBiometricEnrolment(store: store, index: DefaultsEnrolmentIndex(defaults: defaults), scope: "db-a", isAvailable: { true })
            try await keychain.enrol(appUserId: 2)
            store.refusal = refusal
            do {
                _ = try await keychain.unlock(appUserId: 2, reason: "test", prompt: prompt)
                XCTFail("a refused finger must not unlock")
            } catch {
                XCTAssertEqual(error as? BiometricUnlockError, refusal)
            }
            XCTAssertEqual(keychain.enrolledIds(), [2], "a refused finger keeps the secret")
            XCTAssertNotNil(store.secrets["db-a:2"])
        }
    }
}
