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
        // The app's name used mid-sentence ("Budget looks in…", "Open the Budget window").
        let sentence = try NSRegularExpression(pattern: #"\bBudget (looks|keeps|window|isn't|is |stops|deletes|will)|the Budget window"#)
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                guard l.contains("\"") else { continue }  // string literals only; comments may say "the Budget"
                if banned.contains(where: { l.contains($0) }) || sentence.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil { hits.append("\(url.lastPathComponent):\(n + 1)") }
            }
        }
        XCTAssertEqual(hits, [], "App name written as Budget in user copy")
    }
}
