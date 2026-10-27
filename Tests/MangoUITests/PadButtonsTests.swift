import XCTest
@testable import MangoUI

/// Step 10 Task 4: one button system, and row actions as icon buttons whose icon never changes.
final class PadButtonsTests: XCTestCase {
    func testIconVocabularyIsFixed() {
        let pairs = RowAction.allCases.map { [$0.systemImage, $0.accessibilityLabel] }
        XCTAssertEqual(pairs, [
            ["globe", "Open site"],
            ["paperclip", "Link document"],
            ["magnifyingglass", "Check"],
            ["envelope", "Email"],
            ["bell.slash", "Not expected any more"],
            ["arrow.down.tray", "Download"],
            ["trash", "Discard"],
            ["link", "Link payment"],
            ["doc.badge.plus", "Add to recharge"],
            ["paperplane", "Mark sent"],
            ["checkmark.circle", "Record payment"],
            ["eye", "View"],
            ["link.slash", "Unlink"],
        ])
    }

    func testUnlinkAndDiscardAreDestructive() {
        XCTAssertEqual(RowAction.allCases.filter(\.isDestructive), [.discard, .unlink])
    }

    func testEveryActionHasAnAccessibilityLabel() {
        for action in RowAction.allCases { XCTAssertFalse(action.accessibilityLabel.isEmpty) }
        XCTAssertEqual(RowAction.link(.linkDocument, item: "Gas bill"), "Link document, Gas bill")
        XCTAssertEqual(RowAction.link(.email, item: nil), "Email")
    }

    func testNoTwoActionsShareASymbol() {
        XCTAssertEqual(Set(RowAction.allCases.map(\.systemImage)).count, RowAction.allCases.count)
    }

    func testMinimumTapTarget() {
        XCTAssertEqual(PadButtonStyle.minimumTapTarget, 44)
        XCTAssertEqual(PadButtonSize.regular.minimumTapTarget, 44)
        XCTAssertEqual(PadButtonSize.small.minimumTapTarget, 36)
        XCTAssertEqual(RowIconButton.targetSize(.regular), 44)
        XCTAssertEqual(RowIconButton.targetSize(.small), 36)
    }
}
