import XCTest
import Foundation

/// The app is called Mango. "Budget" stays only where it names the budget grid or plan, so no
/// user-facing string may use it as the app's name.
final class AppNameCopyTests: XCTestCase {
    func testNoAppNameBudgetInUserCopy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        let banned = ["\"Budget is", "\"Budget ▸", "\"Budget deletes", "\"Budget stops", "\"Set up Budget"]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if banned.contains(where: { line.contains($0) }) { hits.append("\(url.lastPathComponent):\(n + 1)") }
            }
        }
        XCTAssertEqual(hits, [], "App name written as Budget in user copy")
    }
}
