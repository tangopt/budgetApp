import XCTest
@testable import MangoUI

/// The iPad sidebar's sections and the harness's route split (step 8, Task 6).
final class PadRootTests: XCTestCase {
    func testSectionsAndTitles() {
        XCTAssertEqual(PadSection.allCases, [.home, .month, .accounts, .propertyOverview, .bills, .recharges, .rentReceipts,
                                             .tenancies, .documents, .missingEvidence, .search])
        XCTAssertEqual(PadSection.allCases.map(\.title), ["Home", "Month", "Accounts", "Overview", "Bills", "Recharges",
                                                          "Rent receipts", "Tenancies", "Documents", "Missing evidence", "Search"])
        let groups = PadSection.groups(hasProperty: true)
        XCTAssertEqual(groups.map(\.title), [nil, "Property", "Documents"])
        XCTAssertEqual(groups[0].sections, [.home, .month, .accounts, .search])
        XCTAssertEqual(groups[1].sections, [.propertyOverview, .bills, .recharges, .rentReceipts, .tenancies])
        XCTAssertEqual(groups[2].sections, [.documents, .missingEvidence])
    }

    func testPropertyGroupHiddenWithoutProperty() {
        let groups = PadSection.groups(hasProperty: false)
        XCTAssertEqual(groups.map(\.title), [nil, "Documents"])
        XCTAssertTrue(groups.flatMap(\.sections).allSatisfy { !PadSection.propertySections.contains($0) })
    }

    func testPhoneRoutesUnchanged() {
        let phone = DemoRoutes.all.filter { !$0.pad }.map(\.name)
        XCTAssertEqual(phone.first, "gallery")
        XCTAssertFalse(phone.contains("pad-root"))
        XCTAssertEqual(DemoRoutes.all.filter(\.pad).map(\.name), ["quick-edit-sheet-pad", "pad-root", "pad-property-overview", "pad-tenancies", "pad-bills", "pad-documents",
                                                                     "pad-recharges", "pad-rent-receipts", "pad-bills-refusal",
                                                                     "pad-missing-evidence", "pad-document-refusal"])
        // The routes before this task, in order.
        let before = ["account-detail", "accounts", "accounts-empty", "accounts-sharing_badges", "demo-tabs", "first-download", "first-download-waiting", "first-download-waiting-actions", "gallery", "gallery-fold", "home", "home-empty", "home-offline", "home-stale_data", "home-waiting_for_key", "icloud-unavailable", "month", "month-empty", "month-income", "month-private_lines", "month-transactions", "property", "property-empty", "property-no_mortgage", "search", "search-amount", "search-empty", "search-results", "settings", "settings-demo", "settings-sharing", "tabs", "transaction-detail"]
        for name in before { XCTAssertTrue(phone.contains(name), name) }
        XCTAssertEqual(phone.count, Set(phone).count)
    }
}
