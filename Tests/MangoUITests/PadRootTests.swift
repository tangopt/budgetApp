import XCTest
@testable import MangoUI

/// The iPad sidebar's sections and the harness's route split (step 8, Task 6).
final class PadRootTests: XCTestCase {
    func testPhoneRoutesUnchanged() {
        let phone = DemoRoutes.all.filter { !$0.pad }.map(\.name)
        XCTAssertEqual(phone.first, "gallery")
        XCTAssertFalse(phone.contains("pad-root"))
        XCTAssertEqual(DemoRoutes.all.filter { $0.pad && !$0.name.hasPrefix("journey-") }.map(\.name), ["quick-edit-sheet-pad", "pad-settings", "pad-root", "pad-sidebar-expanded", "pad-sidebar-collapsed", "pad-this-month", "pad-this-month-empty", "pad-this-month-allDone", "pad-tenancies", "pad-tenancies-panel", "pad-tenancies-refusal", "pad-money", "pad-money-panel", "pad-calendar", "pad-calendar-flat", "pad-calendar-personal", "pad-calendar-month", "pad-checks", "pad-profile", "pad-mortgage-terms", "pad-accounts", "pad-account-detail", "pad-account-transaction", "pad-account-add", "pad-account-edit", "pad-documents",
                                                                     "pad-month", "pad-month-panel", "pad-search", "pad-search-query", "pad-bills-recharges", "pad-bills-panel", "pad-bills-refusal", "pad-prepare-email",
                                                                     "pad-evidence", "pad-evidence-panel", "pad-documents-downloads", "pad-documents-downloads-empty", "pad-document-panel", "pad-document-waiting", "pad-document-fullview", "pad-document-refusal", "pad-browser", "pad-tray", "pad-check-utility", "pad-check-statement", "pad-import-statement", "pad-import-held", "pad-import-offline", "pad-import-send", "pad-import-member", "pad-check-refusal", "salary"])
        // The routes before this task, in order.
        let before = ["account-detail", "accounts", "accounts-empty", "accounts-sharing_badges", "demo-tabs", "first-download", "first-download-waiting", "first-download-waiting-actions", "gallery", "gallery-fold", "home", "home-empty", "home-offline", "home-stale_data", "home-waiting_for_key", "icloud-unavailable", "month", "month-empty", "month-income", "month-private_lines", "month-transactions", "property", "property-empty", "property-no_mortgage", "search", "search-amount", "search-empty", "search-results", "settings", "settings-demo", "settings-sharing", "tabs", "transaction-detail"]
        for name in before { XCTAssertTrue(phone.contains(name), name) }
        XCTAssertEqual(phone.count, Set(phone).count)
    }

    /// Step 7: each journey is a numbered route sequence over screens that exist; the recharge and evidence ones are iPad
    /// routes at all four window sizes, the quick check the iPhone's.
    func testJourneysAreOrderedSequencesOfRealScreens() {
        for (prefix, pad, steps) in [("journey-recharge-", true, 6), ("journey-quick-", false, 5), ("journey-evidence-", true, 4)] {
            let routes = DemoRoutes.all.filter { $0.name.hasPrefix(prefix) }
            XCTAssertEqual(routes.count, steps, prefix)
            XCTAssertEqual(routes.map(\.name).sorted(), routes.map(\.name), prefix)
            for (index, route) in routes.enumerated() {
                XCTAssertEqual(route.pad, pad, route.name)
                XCTAssertTrue(route.name.hasPrefix("\(prefix)\(index + 1)-"), route.name)
            }
        }
        XCTAssertEqual(PadRoutes.windowSizes.count, 4)
    }
}
