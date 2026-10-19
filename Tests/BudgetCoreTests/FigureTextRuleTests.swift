import XCTest
import BudgetCore

/// The app's rule that figures never wrap (UI polish spec §6.3), checked over the app's
/// sources (`App/`, which the package doesn't build): an amount is a `MoneyText`, and a
/// `Text` that shows a formatted figure is one line (`.figureText()`) or keeps the figure
/// whole inside wrapping prose (`.unbroken`, `.figuresUnbroken`). The snapshot harness's wrap
/// probe checks the rendered result; this catches a new site before it is ever rendered.
final class FigureTextRuleTests: XCTestCase {
    /// `App/`'s Swift files outside the snapshot harness, as (path relative to the repo, lines).
    private func appSources() throws -> [(path: String, lines: [String])] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("App")
        guard let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else {
            throw XCTSkip("App/ isn't next to the package")
        }
        var sources: [(String, [String])] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && !url.path.contains("/Snapshots/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            sources.append((String(url.path.dropFirst(root.path.count + 1)), text.components(separatedBy: "\n")))
        }
        XCTAssertFalse(sources.isEmpty, "no app sources found")
        return sources
    }

    /// A statement: the line, then the modifier lines under it (those starting with ".").
    private func statement(_ lines: [String], from index: Int) -> String {
        var parts = [lines[index]]
        var next = index + 1
        while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
            parts.append(lines[next])
            next += 1
        }
        return parts.joined(separator: " ")
    }

    func testAmountsAreMoneyText() throws {
        var offenders: [String] = []
        for (path, lines) in try appSources() where !path.hasSuffix("DesignSystem/MoneyText.swift") {
            for (index, line) in lines.enumerated() where line.contains("Text(Money.format(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(path):\(index + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "Show an amount with MoneyText, not Text(Money.format(…))")
    }

    func testFormattedFiguresStayOnOneLine() throws {
        // A Text whose words start with (or interpolate) a figure formatter.
        let figure = try NSRegularExpression(pattern: #"(?<![A-Za-z])Text\((?:verbatim: )?(?:"[^"]*\\\()?\s*(?:Money\.format\(|DashboardFormat\.(?:pounds|percent|day|monthYear|compactPounds|axisThousands)\(|DocumentFormat\.day\(|PayMonthFormat\.(?:name|longDay|range)\(|String\(format:|[A-Za-z_.()]+\.formatted\()"#)
        var offenders: [String] = []
        for (path, lines) in try appSources() {
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard figure.firstMatch(in: line, range: range) != nil, !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                let text = statement(lines, from: index)
                // A picker's or menu's item is drawn by AppKit on one line.
                if text.contains(".tag(") { continue }
                if !(text.contains(".figureText(") || text.contains("unbroken") || text.contains("figuresUnbroken")) {
                    offenders.append("\(path):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "A formatted figure in a Text needs .figureText() (or .unbroken inside prose)")
    }

    func testUnbrokenKeepsAFigureWhole() {
        XCTAssertEqual("8 Jan 2026".unbroken, "8\u{00A0}Jan\u{00A0}2026")
        XCTAssertEqual("-£12.00".unbroken, "-\u{2060}£12.00")
        XCTAssertEqual("2025/26".unbroken, "2025/\u{2060}26")
    }

    func testFiguresUnbrokenLeavesTheWordsBreakable() {
        let text = "Amount: -£12.00 → £15.00 from 8 Jan 2026 until Mar 2027 (1 Aug – 31 Aug)"
        XCTAssertEqual(text.figuresUnbroken,
                       "Amount: -\u{2060}£12.00 → £15.00 from 8\u{00A0}Jan\u{00A0}2026 until Mar\u{00A0}2027 (1\u{00A0}Aug\u{00A0}–\u{2060}\u{00A0}31\u{00A0}Aug)")
        XCTAssertEqual("Nothing to keep together here".figuresUnbroken, "Nothing to keep together here")
        XCTAssertEqual("GBP at 1.1655 EUR per £1 (€1 = £0.8580).".figuresUnbroken,
                       "GBP at 1.1655\u{00A0}EUR\u{00A0}per\u{00A0}£1 (€1\u{00A0}=\u{00A0}£0.8580).")
    }
}
