import XCTest
@testable import BudgetCore

final class AppIdentityTests: XCTestCase {
    private var legacyDomain = ""
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        legacyDomain = "test.legacy.\(UUID().uuidString)"
        suiteName = "test.new.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.setPersistentDomain(["appTheme": "midnight", "appAppearance": "dark", "budgetGrid.showForecast": true], forName: legacyDomain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: legacyDomain)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCopiesTheOldPreferencesOnce() {
        XCTAssertEqual(AppIdentity.copyLegacyPreferencesOnce(from: legacyDomain, into: defaults), 3)
        XCTAssertEqual(defaults.string(forKey: "appTheme"), "midnight")
        XCTAssertEqual(defaults.string(forKey: "appAppearance"), "dark")
        XCTAssertTrue(defaults.bool(forKey: "budgetGrid.showForecast"))

        // A later change under the new id is not overwritten by a second launch.
        defaults.set("classic", forKey: "appTheme")
        XCTAssertEqual(AppIdentity.copyLegacyPreferencesOnce(from: legacyDomain, into: defaults), 0)
        XCTAssertEqual(defaults.string(forKey: "appTheme"), "classic")
    }

    func testKeepsWhatTheNewDomainAlreadyHolds() {
        defaults.set("sunset", forKey: "appTheme")
        XCTAssertEqual(AppIdentity.copyLegacyPreferencesOnce(from: legacyDomain, into: defaults), 2)
        XCTAssertEqual(defaults.string(forKey: "appTheme"), "sunset")
    }

    func testNoOldPreferencesCopiesNothing() {
        XCTAssertEqual(AppIdentity.copyLegacyPreferencesOnce(from: "test.absent.\(UUID().uuidString)", into: defaults), 0)
        XCTAssertTrue(defaults.bool(forKey: AppIdentity.legacyPreferencesCopiedKey))
    }
}
