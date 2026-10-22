import XCTest
import GRDB
@testable import BudgetCore

@MainActor
final class SignInGateTests: XCTestCase {
    private let password = "synthetic pass 1"
    private var manager: DatabaseManager!
    private var userId: Int64 = 0
    private var recoveryKey = ""

    override func setUp() async throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
        let created = try await manager.dbQueue.write { [password] db in
            var person = Person(name: "Sam Example")
            try person.insert(db)
            return try AppUserStore.create(db, personId: person.id!, displayName: "Sam", password: password,
                                           isAdmin: true, now: Date(timeIntervalSince1970: 0), rounds: 1_000)
        }
        userId = created.0.id!
        recoveryKey = created.recoveryKey
    }

    func testPasswordAndRecoveryKeyShareTheThrottle() async throws {
        let gate = SignInGate(dbQueue: manager.dbQueue)
        let now = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<5 {
            let outcome = await gate.password(appUserId: userId, password: "wrong password", now: now)
            XCTAssertEqual(outcome, .rejected)
        }
        let sixth = await gate.recoveryKey(appUserId: userId, key: "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA", now: now)
        XCTAssertEqual(sixth, .throttled(1))
        // Even the right recovery key waits, then works.
        let waiting = await gate.recoveryKey(appUserId: userId, key: recoveryKey, now: now)
        XCTAssertEqual(waiting, .throttled(1))
        let later = await gate.recoveryKey(appUserId: userId, key: recoveryKey, now: now.addingTimeInterval(1))
        XCTAssertEqual(later, .accepted)
        // Success resets the throttle.
        let afterReset = await gate.password(appUserId: userId, password: "wrong password", now: now.addingTimeInterval(1))
        XCTAssertEqual(afterReset, .rejected)
    }

    func testRightPasswordIsAccepted() async throws {
        let gate = SignInGate(dbQueue: manager.dbQueue)
        let outcome = await gate.password(appUserId: userId, password: password, now: Date())
        XCTAssertEqual(outcome, .accepted)
    }

    func testRefusesAConcurrentAttempt() async throws {
        let gate = SignInGate(dbQueue: manager.dbQueue)
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first check started")
        let first = Task { @MainActor in
            await gate.attempt(now: Date()) {
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
                return false
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let second = await gate.attempt(now: Date()) { true }
        XCTAssertEqual(second, .busy)
        release?.resume()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .rejected)
        XCTAssertEqual(gate.failures, 1, "the refused attempt neither counts nor resets")
        let third = await gate.attempt(now: Date()) { true }
        XCTAssertEqual(third, .accepted)
    }
}
