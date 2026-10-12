import XCTest
@testable import BudgetCore

final class ReviewKeyTests: XCTestCase {
    private func keys(_ descriptions: [String]) -> [String] {
        ReviewKey.groupKeys(descriptions: descriptions)
    }

    // Spec §2, from the user's Lloyds statement (descriptions truncated at 18 characters).
    func testTruncatedVariantsJoinTheLongerKey() {
        XCTAssertEqual(keys(["SAINSBURYS S/MKTS", "SAINSBURYS S/MKT 2"]), ["SAINSBURYS S/MKTS", "SAINSBURYS S/MKTS"])
        XCTAssertEqual(keys(["OMNICOM", "OMNICOM MANAGEMENT"]), ["OMNICOM MANAGEMENT", "OMNICOM MANAGEMENT"])
        XCTAssertEqual(keys(["RINGGO", "RINGGO PARKING"]), ["RINGGO PARKING", "RINGGO PARKING"])
        XCTAssertEqual(keys(["AMERICAN EXP 1234X", "AMERICAN EXPRESS"]), ["AMERICAN EXPRESS", "AMERICAN EXPRESS"])
    }

    func testMidWordPrefixJoinsOnlyWhenTheDescriptionWasTruncated() {
        // "SHELL UK" (key SHELL) is a whole name, not a cut-off "SHELLEYS CAFE".
        XCTAssertEqual(keys(["SHELL UK", "SHELLEYS CAFE"]), ["SHELL", "SHELLEYS CAFE"])
        // One-word key shorter than the truncation length: a whole name.
        XCTAssertEqual(keys(["SHELLEY", "SHELLEYS CAFE"]), ["SHELLEY", "SHELLEYS CAFE"])
        // One-word key with a description at the truncation length: enough.
        XCTAssertEqual(keys(["ABCDEFGHIJKLMNOPQR", "ABCDEFGHIJKLMNOPQRSTU"]), Array(repeating: "ABCDEFGHIJKLMNOPQRSTU", count: 2))
    }

    // The real Lloyds truncations are 15-17 characters; a multi-word key joins mid-word.
    func testMultiWordMidWordPrefixJoinsAtAnyLength() {
        XCTAssertEqual(keys(["SAINSBURYS S/MKT", "SAINSBURYS S/MKTS"]), ["SAINSBURYS S/MKTS", "SAINSBURYS S/MKTS"])
        XCTAssertEqual(keys(["AMERICAN EXP 3773", "AMERICAN EXPRESS"]), ["AMERICAN EXPRESS", "AMERICAN EXPRESS"])
        XCTAssertEqual(keys(["OMNICOM MAN LTD", "OMNICOM MANAGEMENT"]), ["OMNICOM MANAGEMENT", "OMNICOM MANAGEMENT"])
        XCTAssertEqual(keys(["AMERICAN EXP", "AMERICAN EXPRESS"]), ["AMERICAN EXPRESS", "AMERICAN EXPRESS"])
    }

    func testWordBoundaryPrefixJoinsWhateverTheLength() {
        XCTAssertEqual(keys(["OMNICOM", "OMNICOM MANAGEMENT"]), ["OMNICOM MANAGEMENT", "OMNICOM MANAGEMENT"])
        XCTAssertEqual(keys(["SHELL UK", "SHELL ESSO GARAGE"]), ["SHELL ESSO GARAGE", "SHELL ESSO GARAGE"])
    }

    func testTrailingGenericTokensAreDropped() {
        XCTAssertEqual(keys(["POD POINT LTD", "POD POINT"]), ["POD POINT", "POD POINT"])
        XCTAssertEqual(keys(["ACME LIMITED UK"]), ["ACME"])
        // Only trailing: a generic word inside the name stays.
        XCTAssertEqual(keys(["CO OP GROUP"]), ["CO OP GROUP"])
    }

    func testNothingIsDroppedWhenOnlyGenericTokensWouldRemain() {
        XCTAssertEqual(keys(["LIMITED"]), ["LIMITED"])
    }

    func testProcessorOnlyDescriptionsGroupUnderTheProcessor() {
        XCTAssertEqual(keys(["AMAZON* NQ7KP7EB5", "AMAZON* 2K4LL0QX1", "AMAZON*7Y8TT1ZZ0"]), ["AMAZON", "AMAZON", "AMAZON"])
        XCTAssertEqual(keys(["PAYPAL *4X9K2", "PAYPAL *77AB1"]), ["PAYPAL", "PAYPAL"])
    }

    func testAMerchantBehindAProcessorKeepsItsOwnKey() {
        XCTAssertEqual(keys(["PAYPAL *SPOTIFY", "AMAZON* NQ7KP7EB5"]), ["PAYPAL SPOTIFY", "AMAZON"])
    }

    func testProcessorGroupsDoNotJoinALongerKey() {
        XCTAssertEqual(keys(["AMAZON* NQ7KP7EB5", "AMAZON PRIME"]), ["AMAZON", "AMAZON PRIME"])
    }

    func testAmazonMarketplaceVariantIsAProcessorGroup() {
        XCTAssertEqual(keys(["AMZNMktplace AB12CD"]), ["AMZNMKTPLACE"])
        XCTAssertTrue(ReviewKey.isProcessorGroup("AMZNMKTPLACE"))
    }

    func testIsProcessorGroup() {
        XCTAssertTrue(ReviewKey.isProcessorGroup("AMAZON"))
        XCTAssertTrue(ReviewKey.isProcessorGroup("PAYPAL"))
        XCTAssertFalse(ReviewKey.isProcessorGroup("AMAZON PRIME"))
        XCTAssertFalse(ReviewKey.isProcessorGroup("SAINSBURYS S/MKTS"))
    }

    func testBranchesStaySeparate() {
        XCTAssertEqual(keys(["GAILS KINGSTON", "GAILS PUTNEY"]), ["GAILS KINGSTON", "GAILS PUTNEY"])
        XCTAssertEqual(keys(["SAINSBURYS PETROL", "SAINSBURYS S/MKTS"]), ["SAINSBURYS PETROL", "SAINSBURYS S/MKTS"])
    }

    func testAmbiguousPrefixJoinsTheKeyWithMostRows() {
        let result = keys(["OMNICOM", "OMNICOM STAFF DINI", "OMNICOM MANAGEMENT", "OMNICOM MANAGEMENT"])
        XCTAssertEqual(result, ["OMNICOM MANAGEMENT", "OMNICOM STAFF DINI", "OMNICOM MANAGEMENT", "OMNICOM MANAGEMENT"])
    }

    func testAmbiguousPrefixWithEqualRowsJoinsTheFirstSeen() {
        XCTAssertEqual(keys(["OMNICOM", "OMNICOM STAFF DINI", "OMNICOM MANAGEMENT"]), ["OMNICOM STAFF DINI", "OMNICOM STAFF DINI", "OMNICOM MANAGEMENT"])
    }

    func testChainsResolveToTheLongestKey() {
        XCTAssertEqual(keys(["SAINSBURYS S/M 123", "SAINSBURYS S/MKT 2", "SAINSBURYS S/MKTS"]), Array(repeating: "SAINSBURYS S/MKTS", count: 3))
    }

    func testShortPrefixesDoNotMerge() {
        XCTAssertEqual(keys(["TFL", "TFL TRAVEL CH"]), ["TFL", "TFL TRAVEL CH"])
        XCTAssertEqual(keys(["GAIL", "GAILS"]), ["GAIL", "GAILS"])
    }

    func testStoreNumbersStillDropped() {
        XCTAssertEqual(keys(["TESCO STORES 2041", "TESCO STORES 3312"]), ["TESCO STORES", "TESCO STORES"])
    }

    func testKeepsOrderAndCount() {
        XCTAssertEqual(keys([]), [])
        XCTAssertEqual(keys(["B SHOP", "A SHOP 1"]).count, 2)
    }
}
