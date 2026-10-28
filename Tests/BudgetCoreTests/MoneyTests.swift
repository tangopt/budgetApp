import XCTest
@testable import BudgetCore

final class MoneyTests: XCTestCase {
    /// Grouped in threes with "," whatever the device's locale (an en_IN phone would group 12,34,567 with a
    /// NumberFormatter); the same strings on the Mac and the phone.
    func testFormatGroupsInThreesWhateverTheLocale() {
        XCTAssertEqual(Money.format(123_456_789_012, currency: .gbp), "£1,234,567,890.12")
        XCTAssertEqual(Money.format(123_456_789, currency: .eur), "€1,234,567.89")
        XCTAssertEqual(Money.format(-100_000, currency: .gbp), "-£1,000.00")
        XCTAssertEqual(Money.format(99_999, currency: .gbp), "£999.99")
    }

    func testFormatUnderOnePound() {
        XCTAssertEqual(Money.format(5, currency: .gbp), "£0.05")
        XCTAssertEqual(Money.format(-5, currency: .gbp), "-£0.05")
        XCTAssertEqual(Money.format(0, currency: .eur), "€0.00")
        XCTAssertEqual(Money.format(-99, currency: .eur), "-€0.99")
    }

    func testFormatInputExamples() {
        XCTAssertEqual(Money.formatInput(4400751), "44,007.51")
        XCTAssertEqual(Money.formatInput(0), "0.00")
        XCTAssertEqual(Money.formatInput(-1200), "-12.00")
        XCTAssertEqual(Money.formatInput(100000000), "1,000,000.00")
        XCTAssertEqual(Money.formatInput(5), "0.05")
        XCTAssertEqual(Money.formatInput(99999), "999.99")
        XCTAssertEqual(Money.formatInput(100000), "1,000.00")
        XCTAssertEqual(Money.formatInput(-123456789), "-1,234,567.89")
    }

    func testFormatInputRoundTripsThroughParse() {
        let values = [0, 1, 5, 99, 100, 101, 99999, 100000, 4400751, 100000000, 123456789012,
                      -1, -99, -100, -1200, -4400751, -100000000]
        for value in values {
            XCTAssertEqual(Money.parseMinorUnits(Money.formatInput(value)), value, "round trip \(value)")
        }
    }

    func testPoundsFieldTextGroupsWhatIsTyped() {
        XCTAssertEqual(Money.poundsFieldText(typed: ""), "")
        XCTAssertEqual(Money.poundsFieldText(typed: "6"), "£6")
        XCTAssertEqual(Money.poundsFieldText(typed: "65000"), "£65,000")
        XCTAssertEqual(Money.poundsFieldText(typed: "£65,0000"), "£650,000")
        XCTAssertEqual(Money.poundsFieldText(typed: "1234."), "£1,234.")
        XCTAssertEqual(Money.poundsFieldText(typed: "1234.567"), "£1,234.56")
        XCTAssertEqual(Money.poundsFieldText(typed: ".5"), "£0.5")
        XCTAssertEqual(Money.poundsFieldText(typed: "007"), "£7")
        XCTAssertEqual(Money.poundsFieldText(typed: "abc"), "")
    }

    func testPoundsFieldTextRoundTripsWithParsing() {
        XCTAssertEqual(Money.poundsFieldText(pence: 0), "")
        XCTAssertEqual(Money.poundsFieldText(pence: 6_500_000), "£65,000")
        XCTAssertEqual(Money.poundsFieldText(pence: 123_450), "£1,234.50")
        for pence in [5, 100, 123_450, 6_500_000, 123_456_789] {
            XCTAssertEqual(Money.parseMinorUnits(Money.poundsFieldText(pence: pence)), pence)
        }
        XCTAssertEqual(Money.parseMinorUnits(Money.poundsFieldText(typed: "65000")), 6_500_000)
    }
}
