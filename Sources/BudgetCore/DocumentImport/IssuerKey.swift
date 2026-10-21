import Foundation
import GRDB

/// Who issued a document: a stable key learnt rules hang on, and a short name to show.
public struct IssuerKey: Hashable, Codable, Sendable {
    public let key: String
    public let label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }

    /// Words that only say what a document is ("TAX INVOICE", "FATURA SIMPLIFICADA", "2ª VIA",
    /// "P60 END OF YEAR CERTIFICATE"): a line made only of these and numbering names nobody.
    public static let titleWords: Set<String> = [
        "INVOICE", "FATURA", "FACTURA", "RECIBO", "RECEIPT", "STATEMENT", "EXTRATO", "CERTIFICATE", "TAX", "VAT",
        "SIMPLIFICADA", "ORIGINAL", "DUPLICADO", "DUPLICATE", "TRIPLICADO", "COPY", "COPIA", "VIA", "SEGUNDA", "ORDER",
        "CONFIRMATION", "P60", "P45", "P11D", "END", "YEAR", "NOTA", "CREDITO", "CREDIT", "DEBITO", "DEBIT", "NOTE",
        "PAGE", "PAGINA", "ACCOUNT", "CONTA", "SUMMARY", "RESUMO", "DOCUMENTO", "DOCUMENT", "PRO", "FORMA",
        // Numbering and filler.
        "N", "NO", "NR", "NUM", "NUMERO", "NUMBER", "\u{00BA}", "\u{00AA}", "N\u{00BA}", "NR\u{00BA}", "N\u{00AA}", "OF", "DE", "DO", "DA", "A", "THE", "AND", "E",
        // Portuguese document series ("FT 2024/12", "FR", "FS", "NC", "ND").
        "FT", "FR", "FS", "NC", "ND",
    ]

    /// Numbers that never identify an issuer: "consumidor final" and all zeros.
    static let anonymousNIFs: Set<String> = ["999999990", "000000000"]

    /// Words that mark a NIF as belonging to the customer, not the issuer.
    static let partyWords = ["CLIENTE", "ADQUIRENTE", "DESTINATARIO", "CUSTOMER", "TENANT", "INQUILINO", "ARRENDATARIO"]

    /// The prefix of a known person's name among the known parties (`"name:ANA DEMO"`).
    static let namePrefix = "name:"

    /// Everyone who is "ours": every person's NIF, and every person's name (`"name:<NAME>"`,
    /// normalised). Callers of `derive` must pass this as `ownNIFs` (plus any tenant NIFs they
    /// know; the app stores none today), or a customer's NIF — or the recipient's name heading
    /// the letter — can key an issuer.
    public static func knownParties(db: Database) throws -> Set<String> {
        let nifs = try String.fetchAll(db, sql: "SELECT ptNif FROM person WHERE ptNif IS NOT NULL")
        let names = try String.fetchAll(db, sql: "SELECT name FROM person")
            .map { words(EvidenceText.normalized($0)).joined(separator: " ") }
            .filter { $0.filter(\.isLetter).count >= 3 }
        return Set(nifs.map { $0.filter(\.isNumber) }.filter { !$0.isEmpty }).union(names.map { namePrefix + $0 })
    }

    /// Whether the key is a first line's (`line:`): never enough to make anything certain.
    public static func isLineKey(_ key: String) -> Bool { key.hasPrefix("line:") }

    /// The reason of something a rule keyed by a first line suggests: to check.
    public static func lineKeyReason(_ base: String, line: String) -> String {
        "\(base). Learnt from the first line “\(line)”: check it"
    }

    /// First match wins: a valid PT NIF/NIPC after its label (not an anonymous, known-party or customer NIF),
    /// a UK VAT number, a company number, else the first line that names a company. Nil when none is found.
    public static func derive(text: String?, fileName: String, ownNIFs: Set<String>) -> IssuerKey? {
        guard let text else { return nil }
        let names = ownNIFs.filter { $0.hasPrefix(namePrefix) }.map { words(String($0.dropFirst(namePrefix.count))) }
        func companyName(_ line: String) -> String? {
            guard let name = Self.companyName(line) else { return nil }
            return names.contains(where: { Self.names($0, in: words(line)) }) ? nil : name
        }
        func nearestLabel(lines: [String], to index: Int) -> String? {
            let candidates = lines.indices.compactMap { i in companyName(lines[i]).map { (i, $0) } }
            if let before = candidates.last(where: { $0.0 <= index }) { return titled(before.1) }
            return candidates.first.map { titled($0.1) }
        }
        let lines = text.components(separatedBy: .newlines).map { EvidenceText.normalized($0) }
        let joined = lines.joined(separator: "\n")
        var lineStarts: [Int] = []
        var offset = 0
        for line in lines { lineStarts.append(offset); offset += line.utf16.count + 1 }
        func lineIndex(_ location: Int) -> Int { lineStarts.lastIndex(where: { $0 <= location }) ?? 0 }

        func make(key: String, matchLocation: Int) -> IssuerKey {
            let line = lineIndex(matchLocation)
            // The issuer's name may share the line with the number ("Demo Power, S.A. NIPC 5..."): the text before the label.
            let before = (joined as NSString).substring(with: NSRange(location: lineStarts[line], length: matchLocation - lineStarts[line]))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-|/\u{2013}\u{2014}"))
            let own = companyName(before).map(titled)
            return IssuerKey(key: key, label: own ?? nearestLabel(lines: lines, to: line) ?? key)
        }

        // PT NIF / NIPC.
        let ns = joined as NSString
        for label in matches(#"(?<![A-Z])(?:N\.? ?I\.? ?F\.?|NIPC|CONTRIBUINTE)(?![A-Z])"#, in: joined) {
            let end = label.location + label.length
            let lineEnd = ns.range(of: "\n", range: NSRange(location: end, length: ns.length - end))
            let windowLength = min(30, (lineEnd.location == NSNotFound ? ns.length : lineEnd.location) - end)
            let window = ns.substring(with: NSRange(location: end, length: max(0, windowLength)))
            let index = lineIndex(label.location)
            let context = [lines[index], index > 0 ? lines[index - 1] : "", window].joined(separator: "\n")
            if partyWords.contains(where: context.contains) { continue }
            for digits in matches(#"(?<!\d)\d{3} ?\d{3} ?\d{3}(?!\d)"#, in: window) {
                let value = (window as NSString).substring(with: digits).filter(\.isNumber)
                if RentReceiptPDFs.isValidNIF(value), !anonymousNIFs.contains(value), !ownNIFs.contains(value) {
                    return make(key: "nif:" + value, matchLocation: label.location)
                }
            }
        }
        // UK VAT number: GB and its digits, or the digits after "VAT Reg(istration) No/Number" —
        // as for a NIF, not an anonymous or known party's number, nor one on a customer's line.
        func isIssuers(_ digits: String, at location: Int) -> Bool {
            guard !anonymousNIFs.contains(digits), !ownNIFs.contains(digits) else { return false }
            let index = lineIndex(location)
            if partyWords.contains(where: lines[index].contains) { return false }
            // A party label alone on the line before ("CUSTOMER" / "VAT NO 123…").
            let previous = index > 0 ? words(lines[index - 1]) : []
            return previous.isEmpty || !previous.allSatisfy { word in partyWords.contains(word) }
        }
        for range in matches(#"(?<![A-Z0-9])GB ?\d{3} ?\d{4} ?\d{2}(?!\d)"#, in: joined) {
            let digits = ns.substring(with: range).filter(\.isNumber)
            if isIssuers(digits, at: range.location) { return make(key: "vat:" + digits, matchLocation: range.location) }
        }
        if let regex = try? NSRegularExpression(pattern: #"VAT (?:REG(?:ISTRATION)?\.? )?(?:NO|NUMBER)\.?[^A-Z0-9\n]{0,5}(\d{3} ?\d{4} ?\d{2})(?!\d)"#) {
            for match in regex.matches(in: joined, range: NSRange(location: 0, length: ns.length)) {
                let digits = ns.substring(with: match.range(at: 1)).filter(\.isNumber)
                if isIssuers(digits, at: match.range.location) { return make(key: "vat:" + digits, matchLocation: match.range.location) }
            }
        }
        // Company number.
        if let regex = try? NSRegularExpression(pattern: #"COMPANY (?:REGISTRATION )?(?:NO|NUMBER)[^A-Z0-9\n]{0,5}([A-Z0-9]{8})(?![A-Z0-9])"#),
           let match = regex.firstMatch(in: joined, range: NSRange(location: 0, length: ns.length)) {
            return make(key: "crn:" + ns.substring(with: match.range(at: 1)), matchLocation: match.range.location)
        }
        // First line that names a company.
        for line in lines {
            if let name = companyName(line) { return IssuerKey(key: "line:" + name, label: titled(name)) }
        }
        return nil
    }

    /// The line's words with letters ("N.º 123" → "N", "º"), digits dropped.
    private static func words(_ line: String) -> [String] {
        line.filter { !$0.isNumber }.split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Whether `line` names the person `name` (both as words): the whole name in order, or its
    /// first and last words ("ANA DEMO" for "Ana Maria Demo").
    private static func names(_ name: [String], in line: [String]) -> Bool {
        guard !name.isEmpty, line.count >= name.count else { return false }
        for start in 0...(line.count - name.count) where Array(line[start..<start + name.count]) == name { return true }
        guard name.count >= 2, let first = name.first, let last = name.last, let i = line.firstIndex(of: first) else { return false }
        return line[(i + 1)...].contains(last)
    }

    /// Whether the line only says what the document is: every word a title word or numbering
    /// ("TAX INVOICE", "FATURA N.º 123", "2ª VIA", "P60 END OF YEAR CERTIFICATE", "PAGE 1 OF 2").
    static func isTitleLine(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let meaningful = tokens.filter { token in
            if token.allSatisfy(\.isNumber) || titleWords.contains(token) { return false }
            let letters = token.filter { !$0.isNumber }
            return !titleWords.contains(letters)
        }
        return meaningful.isEmpty
    }

    /// The line as a company name: digits removed. Nil for document titles, page and date lines
    /// and field-label lines (NIF, VAT, company number...), which say nothing about who issued the document.
    private static func companyName(_ line: String) -> String? {
        let stripped = line.filter { !$0.isNumber }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Words only: punctuation and digits ("N.º 123", "1 OF 2") don't count.
        let words = words(line)
        guard stripped.filter(\.isLetter).count >= 4, let first = words.first else { return nil }
        let phrase = words.joined(separator: " ")
        // Titles with only numbering around them ("FATURA N.º 123", "TAX INVOICE") are not names;
        // "RECIBO VERDE LDA" is.
        if isTitleLine(line) { return nil }
        if partyWords.contains(where: phrase.contains) { return nil }
        if ["DATA", "DATE", "TOTAL", "IVA", "MORADA", "ADDRESS", "PAGE", "PAGINA"].contains(first) { return nil }
        let labelWords: Set<String> = ["NIF", "NIPC", "CONTRIBUINTE", "VAT"]
        if !labelWords.isDisjoint(with: words) { return nil }
        if phrase.contains("COMPANY NO") || phrase.contains("COMPANY NUMBER") || phrase.contains("COMPANY REGISTRATION") { return nil }
        return stripped
    }

    private static func titled(_ name: String) -> String {
        String(name.capitalized.prefix(40)).trimmingCharacters(in: .whitespaces)
    }

    private static func matches(_ pattern: String, in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }
}
