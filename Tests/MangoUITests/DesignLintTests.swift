import XCTest
import Foundation

/// The design system's lint (design review 2026-10-28, I14), over the iPhone, iPad and widget sources (`Sources/MangoUI`,
/// `Phone`, `Widgets`): text goes through `mangoFont` (a glyph — an `Image` — may keep `.font(.system(size:))`), and
/// status colours come from the theme's roles, never a hard-coded `.red`, `.green` or `.orange`.
final class DesignLintTests: XCTestCase {
    /// The repository's root, from this file's path.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let folders = ["Sources/MangoUI", "Phone", "Widgets"]

    /// Where a theme maps its tokens onto the system colours, the one place `.red` and `.green` belong.
    private static let colourExempt: Set<String> = ["Sources/MangoUI/DesignSystem/PhoneTheme.swift"]

    /// Each Swift file under the folders: its path from the root and its lines.
    private static func sources() throws -> [(path: String, lines: [String])] {
        var files: [(String, [String])] = []
        for folder in folders {
            let url = root.appending(path: folder)
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                let path = String(file.path.dropFirst(root.path.count + 1))
                files.append((path, text.components(separatedBy: "\n")))
            }
        }
        return files.sorted { $0.0 < $1.0 }
    }

    func testTheLintSeesTheSources() throws {
        let paths = try Self.sources().map(\.path)
        XCTAssertTrue(paths.contains("Sources/MangoUI/DesignSystem/PhoneTheme.swift"))
        XCTAssertTrue(paths.contains { $0.hasPrefix("Widgets/") })
    }

    /// `.font(.system…)` set on a `Text`, `Label`, `TextField` or `SecureField`: text must use `mangoFont`.
    func testNoSystemFontOnText() throws {
        var found: [String] = []
        for (path, lines) in try Self.sources() {
            for (index, line) in lines.enumerated() {
                for violation in DesignLint.systemFontOnText(lines, at: index) {
                    found.append("\(path):\(index + 1): \(violation) — \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(found, [], "Use mangoFont for text:\n" + found.joined(separator: "\n"))
    }

    /// `.red`, `.green`, `.orange` (or `Color.red`, …) outside the theme: use the roles (`theme.expense`,
    /// `theme.income`, `theme.warning`).
    func testNoHardCodedStatusColours() throws {
        var found: [String] = []
        for (path, lines) in try Self.sources() where !Self.colourExempt.contains(path) {
            for (index, line) in lines.enumerated() where DesignLint.hardCodedColour(line) != nil {
                found.append("\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(found, [], "Use the theme's roles:\n" + found.joined(separator: "\n"))
    }

    // MARK: The rules themselves

    func testSystemFontRuleFlagsTextAndLeavesGlyphs() {
        XCTAssertEqual(DesignLint.systemFontOnText(["Text(\"Payday\").font(.system(size: 9))"], at: 0).count, 1)
        XCTAssertEqual(DesignLint.systemFontOnText(["Text(code)", "    .bold()", "    .font(.system(size: 56))"], at: 2).count, 1)
        XCTAssertEqual(DesignLint.systemFontOnText(["Label(\"x\", systemImage: \"y\").font(Font.system(.body))"], at: 0).count, 1)
        XCTAssertEqual(DesignLint.systemFontOnText(["Image(systemName: \"lock\")", "    .font(.system(size: 48))"], at: 1), [])
        XCTAssertEqual(DesignLint.systemFontOnText(["Image(systemName: \"x\").font(.system(size: 30))"], at: 0), [])
        XCTAssertEqual(DesignLint.systemFontOnText(["Text(\"a\").mangoFont(.body)"], at: 0), [])
    }

    func testColourRuleFlagsSystemStatusColoursOnly() {
        XCTAssertNotNil(DesignLint.hardCodedColour(".foregroundStyle(.red)"))
        XCTAssertNotNil(DesignLint.hardCodedColour("Color.green.opacity(0.1)"))
        XCTAssertNotNil(DesignLint.hardCodedColour(".foregroundStyle(.white, .orange)"))
        XCTAssertNil(DesignLint.hardCodedColour(".foregroundStyle(theme.expense)"))
        XCTAssertNil(DesignLint.hardCodedColour("// a red disc read as a problem: .red"))
        XCTAssertNil(DesignLint.hardCodedColour("let reddish = model.greenhouse"))
    }
}

/// The lint's line rules, kept apart from the file walk so their own tests can feed them lines.
enum DesignLint {
    /// The `.font(.system` (or `.font(Font.system`) calls on `lines[index]` whose view is text: a text view earlier on
    /// the line, or — when the line continues a modifier chain (`.font…` on its own line) — at the chain's head.
    static func systemFontOnText(_ lines: [String], at index: Int) -> [String] {
        let line = lines[index]
        let pattern = #/\.font\(\s*(Font)?\.system\b/#
        var results: [String] = []
        for match in line.matches(of: pattern) {
            let before = String(line[..<match.range.lowerBound])
            if isComment(before) { continue }
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            let head: String
            if trimmed.isEmpty || trimmed.hasPrefix(".") {
                // A chain: walk up to the line that starts the expression.
                var row = index - 1
                while row >= 0, lines[row].trimmingCharacters(in: .whitespaces).hasPrefix(".") { row -= 1 }
                head = (row >= 0 ? lines[row] : "") + trimmed
            } else {
                head = before
            }
            if let view = textView(in: head) { results.append("\(view) with .font(.system)") }
        }
        return results
    }

    /// The last view constructor in `code` when it draws text; nil for a glyph (`Image`) or anything else.
    private static func textView(in code: String) -> String? {
        let views = #/\b(Text|Label|TextField|SecureField|Image)\(/#
        guard let last = code.matches(of: views).last else { return nil }
        let name = String(last.output.1)
        return name == "Image" ? nil : name
    }

    /// `.red`, `.green` or `.orange` as a colour (`.red`, `Color.red`), outside a comment; nil when there's none.
    static func hardCodedColour(_ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        for match in colourPattern.matches(in: line, range: range) {
            guard let found = Range(match.range, in: line), !isComment(String(line[..<found.lowerBound])) else { continue }
            return String(line[found])
        }
        return nil
    }

    private static let colourPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])(Color)?\.(red|green|orange)\b"#)

    private static func isComment(_ prefix: String) -> Bool {
        prefix.contains("//")
    }
}
