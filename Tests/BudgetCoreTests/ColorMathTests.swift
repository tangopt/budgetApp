// Tests/BudgetCoreTests/ColorMathTests.swift
import XCTest
@testable import BudgetCore

final class ColorMathTests: XCTestCase {
    func testHexComponents() {
        let color = ThemeColor.hex(0xFF8000)
        XCTAssertEqual(color.red, 1, accuracy: 1e-9)
        XCTAssertEqual(color.green, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(color.blue, 0, accuracy: 1e-9)
        XCTAssertEqual(color.alpha, 1)
    }

    func testRelativeLuminanceExtremes() {
        XCTAssertEqual(ColorMath.relativeLuminance(.hex(0xFFFFFF)), 1, accuracy: 1e-9)
        XCTAssertEqual(ColorMath.relativeLuminance(.hex(0x000000)), 0, accuracy: 1e-9)
    }

    func testContrastRatioMatchesWCAG() {
        XCTAssertEqual(ColorMath.contrastRatio(.hex(0x000000), .hex(0xFFFFFF)), 21, accuracy: 1e-6)
        XCTAssertEqual(ColorMath.contrastRatio(.hex(0xFFFFFF), .hex(0xFFFFFF)), 1, accuracy: 1e-9)
        // #767676 is the classic "just passes 4.5:1 on white" grey.
        XCTAssertEqual(ColorMath.contrastRatio(.hex(0x767676), .hex(0xFFFFFF)), 4.54, accuracy: 0.01)
        // Order doesn't matter.
        XCTAssertEqual(ColorMath.contrastRatio(.hex(0xFFFFFF), .hex(0x767676)), 4.54, accuracy: 0.01)
    }

    func testCompositeOverOpaqueBackground() {
        let half = ThemeColor.hex(0x000000, alpha: 0.5)
        let result = ColorMath.composite(half, over: .hex(0xFFFFFF))
        // Rounded to 8 bits a channel, as the result is a hex colour.
        XCTAssertEqual(result.hexValue, 0x808080)
        XCTAssertEqual(result.alpha, 1)
        XCTAssertNil(result.system)
        // Opaque colours replace the background; fully clear ones leave it.
        XCTAssertEqual(ColorMath.composite(.hex(0x123456), over: .hex(0xFFFFFF)).hexValue, 0x123456)
        XCTAssertEqual(ColorMath.composite(.hex(0x123456, alpha: 0), over: .hex(0xABCDEF)).hexValue, 0xABCDEF)
    }

    func testLabOfWhiteAndBlack() {
        let white = ColorMath.lab(.hex(0xFFFFFF))
        XCTAssertEqual(white.l, 100, accuracy: 0.01)
        XCTAssertEqual(white.a, 0, accuracy: 0.01)
        XCTAssertEqual(white.b, 0, accuracy: 0.01)
        XCTAssertEqual(ColorMath.lab(.hex(0x000000)).l, 0, accuracy: 0.01)
        // sRGB red ≈ L 53.24, a 80.09, b 67.20.
        let red = ColorMath.lab(.hex(0xFF0000))
        XCTAssertEqual(red.l, 53.24, accuracy: 0.05)
        XCTAssertEqual(red.a, 80.09, accuracy: 0.1)
        XCTAssertEqual(red.b, 67.20, accuracy: 0.1)
    }

    /// Reference pairs from Sharma, Wu & Dalal, "The CIEDE2000 Color-Difference Formula".
    func testCIEDE2000ReferencePairs() {
        let pairs: [(ColorMath.Lab, ColorMath.Lab, Double)] = [
            (.init(l: 50, a: 2.6772, b: -79.7751), .init(l: 50, a: 0, b: -82.7485), 2.0425),
            (.init(l: 50, a: 0, b: 0), .init(l: 50, a: -1, b: 2), 2.3669),
            (.init(l: 50, a: 2.5, b: 0), .init(l: 73, a: 25, b: -18), 27.1492),
            (.init(l: 60.2574, a: -34.0099, b: 36.2677), .init(l: 60.4626, a: -34.1751, b: 39.4387), 1.2644),
        ]
        for (first, second, expected) in pairs {
            XCTAssertEqual(ColorMath.deltaE2000(first, second), expected, accuracy: 1e-4)
            XCTAssertEqual(ColorMath.deltaE2000(second, first), expected, accuracy: 1e-4)
        }
    }

    func testDeltaEOfColours() {
        XCTAssertEqual(ColorMath.deltaE2000(.hex(0x336699), .hex(0x336699)), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(ColorMath.deltaE2000(.hex(0xFF0000), .hex(0x00AA00)), 50)
    }
}
