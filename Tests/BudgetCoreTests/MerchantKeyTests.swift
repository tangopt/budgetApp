import XCTest
@testable import BudgetCore

final class MerchantKeyTests: XCTestCase {
    func testStoreNumbersAreDropped() {
        XCTAssertEqual(MerchantKey.make("TESCO STORES 2041"), "TESCO STORES")
        XCTAssertEqual(MerchantKey.make("TESCO STORES 3312"), "TESCO STORES")
    }

    func testDigitTokensAndEdgePunctuationAreDropped() {
        XCTAssertEqual(MerchantKey.make("PLAYTOMIC* PI-5B20"), "PLAYTOMIC")
        XCTAssertEqual(MerchantKey.make("Shake Shack - Argy"), "SHAKE SHACK ARGY")
        XCTAssertEqual(MerchantKey.make("SQ *DONUTELIER CAR"), "SQ DONUTELIER CAR")
    }

    func testPlainDescriptionIsKept() {
        XCTAssertEqual(MerchantKey.make("TFL TRAVEL CH"), "TFL TRAVEL CH")
    }

    func testInnerPunctuationIsKept() {
        XCTAssertEqual(MerchantKey.make("APPLE.COM/BILL"), "APPLE.COM/BILL")
    }

    func testShortKeyFallsBackToFullDescription() {
        XCTAssertEqual(MerchantKey.make("12345"), "12345")
        XCTAssertEqual(MerchantKey.make("ab  1"), "AB 1")
    }

    func testEmptyDescription() {
        XCTAssertEqual(MerchantKey.make(""), "")
        XCTAssertEqual(MerchantKey.make("   "), "")
    }

    func testGenericOrProcessorOnlyKeyKeepsFullDescription() {
        XCTAssertEqual(MerchantKey.make("AB1 LIMITED"), "AB1 LIMITED")
        XCTAssertEqual(MerchantKey.make("99P STORES LTD"), "99P STORES LTD")
        XCTAssertEqual(MerchantKey.make("3 MOBILE"), "3 MOBILE")
        XCTAssertEqual(MerchantKey.make("PAYPAL *12345"), "PAYPAL *12345")
        XCTAssertEqual(MerchantKey.make("MARKS&SPENCER PLC"), "MARKS&SPENCER PLC")
    }

    func testProcessorPrefixWithMerchantIsKept() {
        XCTAssertEqual(MerchantKey.make("PAYPAL *STEAM GAMES"), "PAYPAL STEAM GAMES")
    }
}
