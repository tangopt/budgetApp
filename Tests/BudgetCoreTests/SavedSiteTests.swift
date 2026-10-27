import XCTest
@testable import BudgetCore

/// Step 10 Task 5: saved sites are https addresses only, and the device's store keeps their order. Synthetic hosts.
final class SavedSiteTests: XCTestCase {
    func testOnlyHTTPSAccepted() {
        for text in ["javascript:alert(1)", "JavaScript:alert(1)", "file:///etc/hosts", "http://example.com/login",
                     "data:text/html,<p>hi</p>", "ftp://example.com", "mailto:someone@example.com"] {
            XCTAssertThrowsError(try SavedSite.validate(text), text) { error in
                XCTAssertEqual(error as? SavedSiteError, .notHTTPS, text)
            }
        }
        for text in ["", "   ", "https://", "https://bank.example@other.example/", "https://user:pass@example.com",
                     "exa mple.com", "https://-example.com"] {
            XCTAssertThrowsError(try SavedSite.validate(text), text) { error in
                XCTAssertEqual(error as? SavedSiteError, .invalid, text)
            }
        }
        XCTAssertEqual(try SavedSite.validate("example.com/login").absoluteString, "https://example.com/login")
        XCTAssertEqual(try SavedSite.validate(" HTTPS://Example.COM/Path?q=1 ").absoluteString, "https://example.com/Path?q=1")
    }

    func testBareHostGetsHTTPS() throws {
        XCTAssertEqual(try SavedSite.validate("example.com").absoluteString, "https://example.com")
        XCTAssertEqual(try SavedSite.validate("portal.example.test:8443/start").absoluteString, "https://portal.example.test:8443/start")
    }

    func testLocalStoreRoundTripAndOrder() async throws {
        let suite = "mango.tests.savedSites." + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LocalSavedSiteStore(suiteName: suite)
        let initial = try await store.all()
        XCTAssertEqual(initial, [], "starts empty")

        let tax = SavedSite(name: "Tax portal", url: try SavedSite.validate("tax.example.test"), kind: .tax, sortOrder: 2)
        let bank = SavedSite(name: "Bank", url: try SavedSite.validate("bank.example.test"), kind: .bank, sortOrder: 0)
        var water = SavedSite(name: "Water", url: try SavedSite.validate("water.example.test"), kind: .utility, sortOrder: 1)
        try await store.save(tax)
        try await store.save(bank)
        try await store.save(water)
        let ordered = try await store.all()
        XCTAssertEqual(ordered.map(\.name), ["Bank", "Water", "Tax portal"])

        water.name = "Water company"
        try await store.save(water)
        try await store.remove(id: bank.id)
        let reread = try await LocalSavedSiteStore(suiteName: suite).all()
        XCTAssertEqual(reread, [water, tax])

        let insecure = SavedSite(name: "Old", url: URL(string: "http://old.example.test")!, kind: .other, sortOrder: 3)
        do {
            try await store.save(insecure)
            XCTFail("an http site is refused")
        } catch {
            XCTAssertEqual(error as? SavedSiteError, .notHTTPS)
        }
        store.removeAll()
        let emptied = try await store.all()
        XCTAssertEqual(emptied, [])
    }
}
