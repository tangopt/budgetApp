import XCTest
import SwiftUI
import BudgetCore
@testable import MangoUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The probe's measuring path end to end: real figure views hosted in a window with the probe on, so a break in the
/// geometry plumbing shows as a failure here rather than as "0 violations" in the harness (review finding 4).
@MainActor
final class WrapProbeMeasurementTests: XCTestCase {
    private var registry: WrapProbeRegistry { WrapProbeRegistry.shared }

    override func setUp() async throws {
        registry.reset()
        registry.isActive = true
    }

    override func tearDown() async throws {
        registry.isActive = false
        registry.reset()
    }

    /// Hosts `view` in a 393×400 window, lets it lay out, returns the violations and leaves the window up until the
    /// caller is done with the registry.
    private func render<V: View>(_ view: V) async -> (violations: [WrapProbeRegistry.Violation], checked: Int) {
        let size = CGSize(width: 393, height: 400)
        #if canImport(UIKit)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        window.layoutIfNeeded()
        #else
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        #endif
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(50))
            #if canImport(UIKit)
            window.layoutIfNeeded()
            #else
            window.contentView?.layoutSubtreeIfNeeded()
            #endif
        }
        let result = (registry.violations(route: "test", window: size), registry.checkedCount)
        withExtendedLifetime(window) {}
        return result
    }

    func testAFigureThatFitsIsMeasuredAndPasses() async {
        let result = await render(MoneyText(minorUnits: 123_456_789, currency: .gbp, role: .balance).padding())
        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.violations, [])
    }

    func testAFigureSqueezedBeyondItsShrinkIsReportedTruncated() async {
        let result = await render(MoneyText(minorUnits: 123_456_789, currency: .gbp, role: .balance, fit: .shrink()).frame(width: 40))
        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.violations.map(\.problem), [.truncated])
        XCTAssertEqual(result.violations.first?.text, "£1,234,567.89")
    }

    func testANaturalFigureWiderThanItsCardIsReportedCutOff() async {
        let view = Card { MoneyText(minorUnits: 123_456_789, currency: .gbp, role: .balance) }
            .frame(width: 80)
        let result = await render(view)
        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.violations.map(\.problem), [.cutOff])
    }

    func testATextFigureIsNamedByItsWords() async {
        let result = await render(Text("1,234 days").figureText(.shrink(minimumScale: 1)).frame(width: 30))
        XCTAssertEqual(result.violations.first?.text, "1,234 days")
    }
}
