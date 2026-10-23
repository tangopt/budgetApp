import XCTest
import Foundation

/// The main window keeps its toolbar while the lock screen covers it (hiding it resizes the window), so
/// every toolbar item and search field in App/ must go through `screenToolbar` / `screenSearchable`
/// (App/Auth/LockCoveredToolbar.swift), which take them away while covered. A line that adds toolbar
/// content or a search field directly must say how it is covered with a `// lock-cover:` note.
final class LockCoverToolbarTests: XCTestCase {
    func testToolbarsAndSearchFieldsHideUnderTheLockScreen() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        // `.toolbar {`, `.toolbar(content:`, `.toolbar(id:`, and any `.searchable(`. Not `.toolbar(removing:)`,
        // `.toolbar(.hidden, for:)` or `.toolbarBackground`: those add nothing to see.
        let pattern = try NSRegularExpression(pattern: #"\.toolbar\s*(\{|\(\s*(content|id)\s*:)|\.searchable\s*\("#)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var hits: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            // The snapshot build has no lock screen over its routes' toolbars to protect.
            guard !url.pathComponents.contains("Snapshots") else { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                let code = l.components(separatedBy: "//").first ?? l
                guard pattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil else { continue }
                if l.contains("// lock-cover:") { continue }
                hits.append("\(url.lastPathComponent):\(n + 1)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "App/ wasn't found")
        XCTAssertEqual(hits, [], "use screenToolbar { … } / screenSearchable(text:prompt:) so the lock screen hides it")
    }
}
