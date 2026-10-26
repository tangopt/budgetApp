import XCTest
@testable import BudgetCore

/// Settings ▸ Sharing's level change steps (`SharingLevelChangeFlow`) and the ownership sheet's owner toggle.
final class SharingLevelChangeFlowTests: XCTestCase {
    private let card = SharingOverview.AccountRow(id: 3, displayName: "Card", bankName: "Bank", level: .categoryTotals)
    private let saver = SharingOverview.AccountRow(id: 4, displayName: "Saver", bankName: nil, level: .balanceOnly)

    private func preview(_ account: SharingOverview.AccountRow, to level: SharingLevel, blocked: Bool = false) -> SharingOverview.LevelChangePreview {
        SharingOverview.LevelChangePreview(accountId: account.id, from: account.level, to: level, affectedCount: blocked ? 0 : 12,
                                           blockers: blocked ? [.propertyLink(propertyName: "Property A")] : [])
    }

    func testOneConfirmationAtATimeAndNeverForTheSameLevel() {
        var flow = SharingLevelChangeFlow()
        XCTAssertNil(flow.request(.categoryTotals, for: card), "the level it has")
        XCTAssertNil(flow.pending)
        let id = flow.request(.balanceOnly, for: card)
        XCTAssertNotNil(id)
        XCTAssertNil(flow.request(.everything, for: saver), "another is open")
        XCTAssertEqual(flow.pending?.account, card)
        XCTAssertEqual(flow.pending?.to, .balanceOnly)
    }

    func testChangeOnlyOnceCountedAndNotBlockedAndNotTwice() throws {
        var flow = SharingLevelChangeFlow()
        let id = try XCTUnwrap(flow.request(.balanceOnly, for: card))
        XCTAssertNil(flow.beginChange(), "still counting")
        flow.counted(preview(card, to: .balanceOnly), for: id)
        XCTAssertEqual(flow.pending?.preview?.affectedCount, 12)
        let change = try XCTUnwrap(flow.beginChange())
        XCTAssertEqual(change.accountId, card.id)
        XCTAssertEqual(change.level, .balanceOnly)
        XCTAssertNil(flow.beginChange(), "already running")
        flow.cancel()
        XCTAssertNotNil(flow.pending, "Cancel waits while the change runs")
        flow.changed(change.id)
        XCTAssertNil(flow.pending)

        let hidden = try XCTUnwrap(flow.request(.hidden, for: card))
        flow.counted(preview(card, to: .hidden, blocked: true), for: hidden)
        XCTAssertNil(flow.beginChange(), "a blocked Hidden has no Change")
        flow.cancel()
        XCTAssertNil(flow.pending)
    }

    /// A count for a confirmation that was cancelled (and a new one opened, even for the same account and level)
    /// never lands on the new one; a failure keeps the confirmation open with its message.
    func testLateCountsAndFailures() throws {
        var flow = SharingLevelChangeFlow()
        let first = try XCTUnwrap(flow.request(.everything, for: card))
        flow.cancel()
        let second = try XCTUnwrap(flow.request(.everything, for: card))
        XCTAssertNotEqual(first, second)
        flow.counted(preview(card, to: .everything), for: first)
        XCTAssertNil(flow.pending?.preview, "the cancelled one's count is dropped")
        flow.failed("Offline", for: first)
        XCTAssertNil(flow.pending?.error)
        flow.counted(preview(card, to: .everything), for: second)
        let change = try XCTUnwrap(flow.beginChange())
        flow.failed("Only the account's owner changes how much of it is shared.", for: change.id)
        XCTAssertEqual(flow.pending?.error, "Only the account's owner changes how much of it is shared.")
        XCTAssertFalse(flow.pending?.isChanging ?? true)
        XCTAssertNotNil(flow.beginChange(), "Change can be tried again")
    }

    func testJointLocksEverythingAndBackRestoresTheDefault() {
        var personal = SharingSetup.Row(id: 1, displayName: "Current", bankName: nil, isPropertyLinked: false, owner: .person(7), level: .categoryTotals)
        personal.setJoint(true, adminPersonId: 7)
        XCTAssertEqual(personal.owner, .joint)
        XCTAssertEqual(personal.level, .everything)
        personal.setJoint(true, adminPersonId: 7)
        XCTAssertEqual(personal.level, .everything)
        personal.setJoint(false, adminPersonId: 7)
        XCTAssertEqual(personal.owner, .person(7))
        XCTAssertEqual(personal.level, .balanceOnly, "the personal default")

        var property = SharingSetup.Row(id: 2, displayName: "Euro", bankName: nil, isPropertyLinked: true, owner: .person(7), level: .balanceOnly)
        property.setJoint(false, adminPersonId: 7)
        XCTAssertEqual(property.level, .balanceOnly, "unchanged: already the admin's")
        property.setJoint(true, adminPersonId: 7)
        property.setJoint(false, adminPersonId: 7)
        XCTAssertEqual(property.level, .everything, "property-linked default")
    }
}
