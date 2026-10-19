import Foundation

/// Figures inside wrapping prose (UI polish spec §6.3, "figures never wrap"): a sentence may
/// wrap, but never through a figure — "8 Jan 2026", "-£12.00", "3 months", "€1 = £0.8640".
public extension String {
    /// The whole string as one unbreakable run: no-break spaces, and a word joiner after each
    /// hyphen, dash or slash. For a figure put into a sentence: `"… \(day.unbroken) …"`.
    var unbroken: String {
        var result = ""
        result.reserveCapacity(count)
        for character in self {
            switch character {
            case " ":
                result.append("\u{00A0}")
            case "-", "–", "—", "/":
                result.append(character)
                result.append("\u{2060}")
            default:
                result.append(character)
            }
        }
        return result
    }

    /// Prose made elsewhere (a summary, a message) with the figures in it made unbreakable as
    /// `unbroken` does: days ("8 Jan 2026", "8 Jan", "Jan 2026"), a sign before a currency
    /// ("-£12.00"), a dash between figures ("1 Aug – 31 Aug", "2,000 – 3,000") and exchange
    /// rates ("1.1655 EUR per £1", "€1 = £0.8640").
    var figuresUnbroken: String {
        var result = self
        for regex in Self.figurePatterns {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: String(result[range]).unbroken)
            }
        }
        return result
    }

    private static let figurePatterns: [NSRegularExpression] = {
        let month = "(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\.?"
        return [
            "\\b\\d{1,2} \(month)(?: \\d{4})?(?=\\W|$)",
            "\\b\(month) \\d{4}\\b",
            "[-+−][£€$]",
            "(?:\\d|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)) [–—-] (?=[\\d£€$])",
            "\\d[\\d.,]* [A-Z]{3} per [£€$]\\d[\\d.,]*",
            "[£€$]\\d[\\d.,]* = [£€$]\\d[\\d.,]*",
        ].compactMap { try? NSRegularExpression(pattern: $0) }
    }()
}
