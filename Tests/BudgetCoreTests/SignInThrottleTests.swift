import XCTest
@testable import BudgetCore

final class SignInThrottleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testThrottleSchedule() {
        var throttle = SignInThrottle()
        XCTAssertEqual(throttle.delay(now: start), 0)
        var delays: [TimeInterval] = []
        for _ in 0..<13 {
            throttle.recordFailure(now: start)
            delays.append(throttle.delay(now: start))
        }
        XCTAssertEqual(delays, [0, 0, 0, 0, 0, 1, 2, 4, 8, 16, 32, 60, 60])
    }

    func testDelayCountsDownFromTheLastFailure() {
        var throttle = SignInThrottle()
        for _ in 0..<8 { throttle.recordFailure(now: start) }   // 4 s
        XCTAssertEqual(throttle.delay(now: start.addingTimeInterval(1)), 3)
        XCTAssertEqual(throttle.delay(now: start.addingTimeInterval(10)), 0)
    }

    func testResetClearsFailures() {
        var throttle = SignInThrottle()
        for _ in 0..<9 { throttle.recordFailure(now: start) }
        throttle.reset()
        throttle.recordFailure(now: start)
        XCTAssertEqual(throttle.delay(now: start), 0)
    }
}
