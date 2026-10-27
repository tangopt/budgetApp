import XCTest
import SwiftUI
@testable import MangoUI
import BudgetCore

/// Step 7b Task 6: Settings ▸ Widgets, the lock screen toggle (off until turned on, kept per device).
@MainActor
final class SettingsOutputsTests: XCTestCase {
    func testLockScreenToggleDefaultsOff() throws {
        let suite = "SettingsOutputsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored = PhoneOutputSettings.load(from: defaults)
        let binding = Binding(get: { stored }, set: { stored = $0 })
        let section = WidgetsSection(settings: binding)
        XCTAssertFalse(section.showsFiguresOnLockScreen, "off on a fresh iPhone")

        binding.wrappedValue.showFiguresOnLockScreen = true
        stored.save(to: defaults)
        XCTAssertTrue(WidgetsSection(settings: binding).showsFiguresOnLockScreen)
        XCTAssertTrue(PhoneOutputSettings.load(from: defaults).showFiguresOnLockScreen, "kept once turned on")
        XCTAssertEqual(WidgetsCopy.lockScreenToggle, "Show figures on the lock screen")
    }
}
