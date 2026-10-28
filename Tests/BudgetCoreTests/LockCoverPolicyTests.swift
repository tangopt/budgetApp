import XCTest
@testable import BudgetCore

final class LockCoverPolicyTests: XCTestCase {
    func testSameUserGetsTheirSheetsBack() {
        XCTAssertEqual(LockCoverPolicy.onUncover(coveredFor: 1, signedIn: 1), .restore)
    }

    func testAnotherUserNeverSeesThem() {
        XCTAssertEqual(LockCoverPolicy.onUncover(coveredFor: 1, signedIn: 2), .dismiss)
    }

    func testUnknownOwnerOrNobodyDismisses() {
        XCTAssertEqual(LockCoverPolicy.onUncover(coveredFor: nil, signedIn: 2), .dismiss)
        XCTAssertEqual(LockCoverPolicy.onUncover(coveredFor: 1, signedIn: nil), .dismiss)
        XCTAssertEqual(LockCoverPolicy.onUncover(coveredFor: nil, signedIn: nil), .dismiss)
    }

    // A sheet under a lock takes the whole content area of its window, so no frame of its own shows.
    func testCoveringFrameIsTheWindowsContentArea() {
        let parent = CGRect(x: 100, y: 200, width: 1_000, height: 700)
        // The title bar and toolbar take 52 pt at the top: the layout rect starts at the window's bottom.
        let layout = CGRect(x: 0, y: 0, width: 1_000, height: 648)
        let sheet = CGRect(x: 400, y: 400, width: 420, height: 300)
        XCTAssertEqual(LockCoverPolicy.coveringFrame(sheet: sheet, parent: parent, contentLayoutRect: layout),
                       CGRect(x: 100, y: 200, width: 1_000, height: 648))
    }

    func testCoveringFrameNeverShrinksTheSheet() {
        let parent = CGRect(x: 0, y: 0, width: 500, height: 400)
        let sheet = CGRect(x: 50, y: 50, width: 700, height: 300)
        let covering = LockCoverPolicy.coveringFrame(sheet: sheet, parent: parent, contentLayoutRect: CGRect(x: 0, y: 0, width: 500, height: 360))
        XCTAssertTrue(covering.contains(sheet))
        XCTAssertTrue(covering.contains(CGRect(x: 0, y: 0, width: 500, height: 360)))
    }

    // Locked with a sheet open (and a sheet over a sheet): exactly one lock screen, in the top sheet.
    func testOneLockScreenPerWindowAndItsSheets() {
        for depth in 1...3 {
            let covers = (0..<depth).map { LockCoverPolicy.cover(hasSheetAbove: $0 < depth - 1) }
            XCTAssertEqual(covers.filter { $0 == .lockScreen }.count, 1, "\(depth) window(s) stacked")
            XCTAssertEqual(covers.last, .lockScreen, "the top one takes the keyboard")
        }
    }

    // Settings open next to the main window: the main window carries the lock, Settings is hidden.
    func testAuxiliaryWindowsHideWhileTheMainWindowIsOpen() {
        XCTAssertEqual(LockCoverPolicy.auxiliaryWindow(mainWindowOpen: true, hasLockOverlay: true), .hide)
        XCTAssertEqual(LockCoverPolicy.auxiliaryWindow(mainWindowOpen: true, hasLockOverlay: false), .hide)
    }

    // No main window: Settings keeps showing the lock screen, so there is somewhere to unlock.
    func testSettingsCarriesTheLockWithoutAMainWindow() {
        XCTAssertEqual(LockCoverPolicy.auxiliaryWindow(mainWindowOpen: false, hasLockOverlay: true), .carryLock)
        XCTAssertEqual(LockCoverPolicy.auxiliaryWindow(mainWindowOpen: false, hasLockOverlay: false), .hide)
    }

    func testHiddenWindowsComeBackForTheSamePersonOnly() {
        XCTAssertEqual(LockCoverPolicy.auxiliaryOnUncover(coveredFor: 1, signedIn: 1), .orderBack)
        XCTAssertEqual(LockCoverPolicy.auxiliaryOnUncover(coveredFor: 1, signedIn: 2), .stayClosed)
        XCTAssertEqual(LockCoverPolicy.auxiliaryOnUncover(coveredFor: nil, signedIn: 1), .stayClosed)
        XCTAssertEqual(LockCoverPolicy.auxiliaryOnUncover(coveredFor: 1, signedIn: nil), .stayClosed)
    }

    // Exactly one lock screen across main + Settings, whichever are open.
    func testOneLockScreenAcrossWindows() {
        for mainOpen in [true, false] {
            let settings = LockCoverPolicy.auxiliaryWindow(mainWindowOpen: mainOpen, hasLockOverlay: true)
            let screens = (mainOpen ? 1 : 0) + (settings == .carryLock ? 1 : 0)
            XCTAssertEqual(screens, 1)
        }
    }
}
