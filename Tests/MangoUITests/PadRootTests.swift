import XCTest
@testable import MangoUI

/// The iPad sidebar's sections and the harness's route split (step 8, Task 6).
final class PadRootTests: XCTestCase {
    func testPhoneRoutesUnchanged() {
        let phone = DemoRoutes.all.filter { !$0.pad }.map(\.name)
        XCTAssertEqual(phone.first, "gallery")
        XCTAssertFalse(phone.contains("pad-root"))
        XCTAssertEqual(DemoRoutes.all.filter(\.pad).map(\.name), ["quick-edit-sheet-pad", "pad-root", "pad-sidebar-expanded", "pad-sidebar-collapsed", "pad-property-overview", "pad-tenancies", "pad-bills", "pad-documents",
                                                                     "pad-recharges", "pad-rent-receipts", "pad-bills-refusal",
                                                                     "pad-missing-evidence", "pad-document-panel", "pad-document-fullview", "pad-document-refusal", "pad-browser", "pad-tray", "pad-check-utility", "pad-check-statement", "pad-check-refusal"])
        // The routes before this task, in order.
        let before = ["account-detail", "accounts", "accounts-empty", "accounts-sharing_badges", "demo-tabs", "first-download", "first-download-waiting", "first-download-waiting-actions", "gallery", "gallery-fold", "home", "home-empty", "home-offline", "home-stale_data", "home-waiting_for_key", "icloud-unavailable", "month", "month-empty", "month-income", "month-private_lines", "month-transactions", "property", "property-empty", "property-no_mortgage", "search", "search-amount", "search-empty", "search-results", "settings", "settings-demo", "settings-sharing", "tabs", "transaction-detail"]
        for name in before { XCTAssertTrue(phone.contains(name), name) }
        XCTAssertEqual(phone.count, Set(phone).count)
    }
}
