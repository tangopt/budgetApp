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
        // A bank's own letter (an advice, a notice) names the bank and the client, never who is paid:
        // the creditor a debit advice names, else nobody.
        if isBankLetter(text) { return bankLetterIssuer(text) }
        let names = ownNIFs.filter { $0.hasPrefix(namePrefix) }.map { words(String($0.dropFirst(namePrefix.count))) }
        func namesOwn(_ line: String) -> Bool { names.contains(where: { Self.names($0, in: words(line)) }) }
        let lines = text.components(separatedBy: .newlines).map { EvidenceText.normalized($0) }
        // The addressee block: a greeting or one of ours, and the address lines under it.
        let addressee = addresseeLines(lines, namesOwn: namesOwn)
        func companyName(_ line: String) -> String? {
            guard let name = Self.companyName(line) else { return nil }
            return namesOwn(line) ? nil : name
        }
        func companyName(at index: Int) -> String? {
            addressee.contains(index) ? nil : companyName(lines[index])
        }
        func nearestLabel(lines: [String], to index: Int) -> String? {
            let candidates = lines.indices.compactMap { i in companyName(at: i).map { (i, $0) } }
            if let before = candidates.last(where: { $0.0 <= index }) { return titled(before.1) }
            return candidates.first.map { titled($0.1) }
        }
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
            let own = addressee.contains(line) ? nil : companyName(before).map(titled)
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
            // The client's number: in the addressee block or right under it, or beside a loan or
            // account number ("NIF: … / Empréstimo: …").
            if addressee.contains(index) || addressee.contains(index - 1) { continue }
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            if [lines[index], next].contains(where: { line in clientAccountWords.contains { words(line).starts(with: $0) } }) { continue }
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
        for index in lines.indices {
            if let name = companyName(at: index) { return IssuerKey(key: "line:" + name, label: titled(name)) }
        }
        return nil
    }

    // MARK: Greetings, addressees and bank letters

    /// Words a greeting or a form of address starts with ("Exmo(a). Senhor(a)", "Exmos. Senhores",
    /// "Ex.mo Sr.", "Caro cliente", "Dear Sir/Madam", "Dear Ana"): never who issued the document.
    static let salutationWords: Set<String> = [
        "EXMO", "EXMA", "EXMOS", "EXMAS", "CARO", "CARA", "CAROS", "CARAS", "PREZADO", "PREZADA",
        "PREZADOS", "PREZADAS", "ESTIMADO", "ESTIMADA", "ESTIMADOS", "ESTIMADAS", "SENHOR", "SENHORA", "SENHORES", "SENHORAS",
        "SR", "SRA", "SRS", "SRAS", "DEAR", "MR", "MRS", "MS", "MISS",
    ]

    /// Closing lines of a letter ("Com os nossos melhores cumprimentos", "Não carece de assinatura",
    /// "Yours sincerely"): never a name.
    static let closingWords: Set<String> = ["CUMPRIMENTOS", "ASSINATURA", "ATENCIOSAMENTE", "REGARDS", "SINCERELY", "FAITHFULLY"]

    /// Words of an address line: a street, a floor, a country.
    static let addressWords: Set<String> = [
        "RUA", "AV", "AVENIDA", "TRAVESSA", "LARGO", "PRACA", "ESTRADA", "ALAMEDA", "URB", "URBANIZACAO", "LOTE", "ANDAR", "DTO", "ESQ",
        "AVENUE", "ROAD", "RD", "STREET", "LANE", "CLOSE", "DRIVE", "GARDENS", "TERRACE", "CRESCENT", "SQUARE", "WAY", "FLAT", "APARTMENT",
        "PORTUGAL", "REINO", "UNIDO", "UNITED", "KINGDOM", "ESPANHA", "SPAIN", "ENGLAND",
    ]

    /// First words of a line naming the client's loan or account next to a number ("Empréstimo: …").
    static let clientAccountWords: [[String]] = [["EMPRESTIMO"], ["CONTA", "N"], ["CONTA", "NO"]]

    /// Whether the line is a greeting or a form of address ("EXMO(A). SENHOR(A)", "EX.MO SR.", "DEAR SIR/MADAM").
    static func isSalutation(_ line: String) -> Bool {
        let words = words(EvidenceText.normalized(line))
        guard let first = words.first else { return false }
        if salutationWords.contains(first) { return true }
        // "EX.MO", "EX.MA", "EX.MOS".
        return first == "EX" && words.count > 1 && ["MO", "MA", "MOS", "MAS"].contains(words[1])
    }

    /// Whether the line closes a letter ("COM OS NOSSOS MELHORES CUMPRIMENTOS").
    static func isClosing(_ line: String) -> Bool {
        !closingWords.isDisjoint(with: words(EvidenceText.normalized(line)))
    }

    /// Whether the line is part of an address: a street or country word, or a Portuguese or UK postcode.
    /// Words of a company's legal form or trade ("S.A.", "Lda", "Seguros", "(Portugal)"): a line
    /// with one names a company, never an address.
    static let companyFormWords: Set<String> = ["SA", "LDA", "LTD", "LIMITED", "PLC", "INC", "LLC", "GMBH", "UNIPESSOAL", "SGPS",
                                                "SEGUROS", "SEGURADORA", "COMPANHIA", "BANCO", "BANK"]

    /// Whether the line names a company by its form ("DEMO SEGUROS, S.A.", "DEMO (PORTUGAL) LDA").
    static func namesCompanyForm(_ line: String) -> Bool {
        let lineWords = words(line)
        if !companyFormWords.isDisjoint(with: lineWords) || line.contains("(PORTUGAL)") { return true }
        // "S.A." split into its letters.
        return zip(lineWords, lineWords.dropFirst()).contains { $0 == "S" && $1 == "A" }
    }

    static func isAddressLine(_ line: String) -> Bool {
        if namesCompanyForm(line) { return false }
        if !addressWords.isDisjoint(with: words(line)) { return true }
        return line.range(of: #"(?<!\d)\d{4}-\d{3}(?!\d)"#, options: .regularExpression) != nil
            || line.range(of: #"(?<![A-Z0-9])[A-Z]{1,2}\d[A-Z0-9]? ?\d[A-Z]{2}(?![A-Z0-9])"#, options: .regularExpression) != nil
    }

    /// The lines of the letter's addressee: each greeting and closing line, each line naming one
    /// of ours (`namesOwn`), and under a greeting or one of ours the address lines and bare place
    /// names that follow (up to six lines).
    static func addresseeLines(_ lines: [String], namesOwn: (String) -> Bool) -> Set<Int> {
        var found: Set<Int> = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard isSalutation(line) || isClosing(line) || namesOwn(line) else { index += 1; continue }
            found.insert(index)
            var next = index + 1
            if !isClosing(line) {
                while next < lines.count, next - index <= 6 {
                    let candidate = lines[next]
                    // A bare place name ("LISBOA") under the address.
                    let placeName = !candidate.contains(":") && words(candidate).count == 1 && candidate.filter(\.isNumber).isEmpty
                        && !namesCompanyForm(candidate)
                    guard isSalutation(candidate) || namesOwn(candidate) || isAddressLine(candidate) || placeName else { break }
                    found.insert(next)
                    next += 1
                }
            }
            index = max(next, index + 1)
        }
        return found
    }

    /// Phrases of a bank's own letter: its wording of a movement on the client's account, or its
    /// letterhead. A bank named as where a receipt is paid or who mediates a policy is not enough.
    static let bankLetterWording = ["QUEIRA M NOTAR", "QUEIRAM NOTAR", "QUEIRA NOTAR", "NA CONTA DE V EXA", "NA CONTA DE V EXAS", "NA CONTA DE VEXA"]
    static let bankLetterheads = ["BANCO BILBAO VIZCAYA ARGENTARIA S A SUCURSAL EM PORTUGAL"]

    /// Lines at each end of a letter that count as its head or foot.
    static let letterEnds = 5

    /// Whether the text is a bank's own letter (a debit or credit advice, a notice): the bank's
    /// wording of a movement on the client's account anywhere; or its letterhead in the letter's
    /// head or foot (`letterEnds` lines), or beside a greeting. A receipt or policy whose body names
    /// the bank as its mediator or where it is paid is not the bank's letter.
    public static func isBankLetter(_ text: String) -> Bool {
        if isBankMovementAdvice(text) { return true }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        func hasLetterhead(_ part: some Sequence<String>) -> Bool {
            let spaced = spacedWords(part.joined(separator: "\n"))
            return bankLetterheads.contains { spaced.contains(" \($0) ") }
        }
        guard hasLetterhead(lines) else { return false }
        if hasLetterhead(lines.prefix(letterEnds)) || hasLetterhead(lines.suffix(letterEnds)) { return true }
        return lines.contains(where: isSalutation)
    }

    /// Whether the text is a bank's advice of a movement on the client's account ("Queira(m) notar
    /// que, nesta data, efetuámos na conta de V.Exa(s)…"), whatever kind it was filed as.
    public static func isBankMovementAdvice(_ text: String) -> Bool {
        let spaced = spacedWords(text)
        return bankLetterWording.contains { spaced.contains(" \($0) ") }
    }

    /// Folded, uppercased, every run of punctuation and spaces one space, a space at each end.
    private static func spacedWords(_ text: String) -> String {
        " " + BBVADebitAdvice.folded(text).map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") + " "
    }

    /// The issuer of a bank's letter: the creditor a debit advice names (`BBVADebitAdvice`), keyed
    /// `creditor:<NAME>`; nil when it names none, or only a code, a bank or a greeting.
    static func bankLetterIssuer(_ text: String) -> IssuerKey? {
        guard let creditor = BBVADebitAdvice.parse(text)?.creditor, !isSalutation(creditor) else { return nil }
        let name = words(EvidenceText.normalized(creditor)).joined(separator: " ")
        guard name.filter(\.isLetter).count >= 4, !isTitleLine(name), !isBankName(name) else { return nil }
        return IssuerKey(key: "creditor:" + name, label: titled(name))
    }

    /// Words of an insurer or other business a bank's group runs under its name ("BBVA Seguros").
    static let bankGroupBusinessWords: Set<String> = ["SEGUROS", "SEGURO", "INSURANCE", "SEG", "VIDA"]
    /// Bank names that head a bank's letters.
    static let bankNames: Set<String> = ["BBVA", "HSBC", "BARCLAYS", "SANTANDER", "NATWEST", "LLOYDS", "MONZO", "REVOLUT", "MILLENNIUM",
                                         "BANKINTER", "NOVOBANCO", "ACTIVOBANK", "MONTEPIO", "CGD"]

    /// Whether `name` (normalised) names a bank itself ("BANCO BILBAO VIZCAYA ARGENTARIA", "BBVA
    /// (PORTUGAL)", "HSBC UK BANK PLC"), not a business of its group ("BBVA SEGUROS").
    static func isBankName(_ name: String) -> Bool {
        let named = Set(words(EvidenceText.normalized(name)))
        guard named.isDisjoint(with: bankGroupBusinessWords) else { return false }
        return !named.isDisjoint(with: ["BANCO", "BANK", "BANQUE"]) || !named.isDisjoint(with: bankNames)
    }

    /// Whether the issuer is a bank's own letterhead (keyed by its number or its name): no kind,
    /// name or link is learnt about it, since every letter the bank sends would match.
    public static func isBankLetterhead(_ issuer: IssuerKey) -> Bool {
        if issuer.key.hasPrefix("creditor:") { return false }
        return isBankName(issuer.label) || (isLineKey(issuer.key) && isBankName(String(issuer.key.dropFirst("line:".count))))
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
        if ["DATA", "DATE", "TOTAL", "IVA", "MORADA", "ADDRESS", "PAGE", "PAGINA", "ATCUD", "NIB", "IBAN", "SWIFT", "BIC",
            "APOLICE", "POLICY", "CONTRATO", "ASSUNTO", "SUBJECT", "PERIODO", "PERIOD"].contains(first) { return nil }
        // Codes and unreadable glyphs ("IT#ENC:A(BEVI"): never a name.
        if line.contains(where: { "#@*=<>{}[]|\\^~$%".contains($0) }) || line.filter({ $0 == "(" }).count != line.filter({ $0 == ")" }).count {
            return nil
        }
        if isSalutation(line) || isClosing(line) { return nil }
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
