import XCTest
@testable import BudgetCore

final class TaxCodeParserTests: XCTestCase {
    private func kind(_ text: String) -> TaxCode.Kind { TaxCode.parse(text).code.kind }
    private func notice(_ text: String) -> String? { TaxCode.parse(text).notice }

    func testTaxCodeParsing() {
        // Standard codes: digits × £10.
        XCTAssertEqual(kind("1257L"), .standard(allowance: 1_257_000))
        XCTAssertTrue(TaxCode.parse("1257L").code.isDefault)
        XCTAssertEqual(kind("1383M"), .standard(allowance: 1_383_000))
        XCTAssertEqual(kind("1131N"), .standard(allowance: 1_131_000))
        XCTAssertNil(notice("1257L"))
        // Trimmed and upper-cased.
        XCTAssertEqual(TaxCode.parse("  1257l ").code.text, "1257L")
        XCTAssertNil(notice("1257l"))
        // S and C prefixes accepted (the region is the one the person picked).
        XCTAssertEqual(TaxCode.parse("S1257L").code, TaxCode(kind: .standard(allowance: 1_257_000), text: "1257L"))
        XCTAssertEqual(TaxCode.parse("C1257L").code.text, "1257L")
        XCTAssertNil(notice("S1257L"))
        // Emergency suffixes ignored.
        XCTAssertEqual(TaxCode.parse("1257L W1").code.text, "1257L")
        XCTAssertEqual(TaxCode.parse("1257L M1").code.text, "1257L")
        XCTAssertEqual(TaxCode.parse("1257L X").code.text, "1257L")
        XCTAssertEqual(TaxCode.parse("1257LW1").code.text, "1257L")
        XCTAssertNil(notice("1257L W1"))
        // K codes and flat codes.
        XCTAssertEqual(kind("K475"), .k(addition: 475_000))
        XCTAssertEqual(kind("SK100"), .k(addition: 100_000))
        XCTAssertEqual(kind("BR"), .br)
        XCTAssertEqual(kind("SBR"), .br)
        XCTAssertEqual(kind("D0"), .d0)
        XCTAssertEqual(kind("D1"), .d1)
        XCTAssertEqual(kind("SD1"), .d1)
        XCTAssertEqual(kind("NT"), .nt)
        XCTAssertEqual(kind("0T"), .zeroT)
        XCTAssertEqual(kind("0T M1"), .zeroT)
        // Unreadable: 1257L with a notice.
        for text in ["abc", "", "   ", "K", "L", "12.57L", "1257Q", "BRX1", "S"] {
            let parsed = TaxCode.parse(text)
            XCTAssertEqual(parsed.code, TaxCode(kind: .standard(allowance: 1_257_000), text: "1257L"), text)
            XCTAssertEqual(parsed.notice, "Using 1257L: couldn't read that code", text)
        }
    }
}
