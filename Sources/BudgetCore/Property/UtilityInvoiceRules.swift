import GRDB
import Foundation

/// How to read one provider's invoices (plan phase 5 Task 2), stored as data on the provider
/// so a new layout is a settings change, not a code change. Labels and markers are matched
/// case- and accent-insensitively on the text with whitespace runs collapsed (`EvidenceText.normalized`);
/// number patterns are regular expressions on that same text, capture group 1 being the number.
public struct UtilityInvoiceRules: Codable, Equatable, Hashable, Sendable {
    /// Any of these in the text says the invoice is this provider's.
    public var textMarkers: [String]
    /// Any of these words in the file name says so too (a weaker hint: "LUZ", "AGUA").
    public var fileNameMarkers: [String]
    public var invoiceNumberPatterns: [String]
    /// The issue date is the first date after one of these; none found → the text's first date.
    public var issueDateLabels: [String]
    /// "start – end" after one of these ("12 de maio a 11 de julho 2026", "(2026-05-08 a 2026-08-06)").
    public var periodLabels: [String]
    /// The total is the amount right after one of these ("TOTAL 10,57", "Valor da Fatura: 10,57 €"),
    /// in label order; none right after any of them → the first amount after one. A minus sign
    /// before it ("Total -10,69 €") makes it a credit.
    public var amountLabels: [String]
    /// When one of these is in the text, its amount is owed to the customer: a refund (negative).
    /// Credit notes ("VALOR A CREDITAR 24,92€", "TOTAL EM CRÉDITO") are refunds too.
    public var refundLabels: [String]
    /// The payment due date is the first date after one of these (debits come on it): used to
    /// look for a debit of another amount when none matches.
    public var dueDateLabels: [String]

    public init(textMarkers: [String] = [], fileNameMarkers: [String] = [], invoiceNumberPatterns: [String] = [],
                issueDateLabels: [String] = [], periodLabels: [String] = [], amountLabels: [String] = [], refundLabels: [String] = [],
                dueDateLabels: [String] = []) {
        self.dueDateLabels = dueDateLabels
        self.textMarkers = textMarkers
        self.fileNameMarkers = fileNameMarkers
        self.invoiceNumberPatterns = invoiceNumberPatterns
        self.issueDateLabels = issueDateLabels
        self.periodLabels = periodLabels
        self.amountLabels = amountLabels
        self.refundLabels = refundLabels
    }

    /// Stored rules missing a list (older or hand-edited data) read it as empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textMarkers = try container.decodeIfPresent([String].self, forKey: .textMarkers) ?? []
        fileNameMarkers = try container.decodeIfPresent([String].self, forKey: .fileNameMarkers) ?? []
        invoiceNumberPatterns = try container.decodeIfPresent([String].self, forKey: .invoiceNumberPatterns) ?? []
        issueDateLabels = try container.decodeIfPresent([String].self, forKey: .issueDateLabels) ?? []
        periodLabels = try container.decodeIfPresent([String].self, forKey: .periodLabels) ?? []
        amountLabels = try container.decodeIfPresent([String].self, forKey: .amountLabels) ?? []
        refundLabels = try container.decodeIfPresent([String].self, forKey: .refundLabels) ?? []
        dueDateLabels = try container.decodeIfPresent([String].self, forKey: .dueDateLabels) ?? []
    }

    /// These rules with `other`'s entries each list lacks appended (stored rules brought up to
    /// a newer preset without losing the user's edits or changing their order).
    public func merging(_ other: UtilityInvoiceRules) -> UtilityInvoiceRules {
        func union(_ mine: [String], _ theirs: [String]) -> [String] { mine + theirs.filter { !mine.contains($0) } }
        return UtilityInvoiceRules(
            textMarkers: union(textMarkers, other.textMarkers), fileNameMarkers: union(fileNameMarkers, other.fileNameMarkers),
            invoiceNumberPatterns: union(invoiceNumberPatterns, other.invoiceNumberPatterns),
            issueDateLabels: union(issueDateLabels, other.issueDateLabels), periodLabels: union(periodLabels, other.periodLabels),
            amountLabels: union(amountLabels, other.amountLabels), refundLabels: union(refundLabels, other.refundLabels),
            dueDateLabels: union(dueDateLabels, other.dueDateLabels))
    }

    /// For providers without their own rules: common Portuguese invoice labels.
    public static let generic = UtilityInvoiceRules(
        invoiceNumberPatterns: [#"FATURA N\S*\s*([A-Z0-9]+(?: [A-Z0-9]+)?/\d+)"#, #"FATURA:\s*([A-Z0-9]+(?: [A-Z0-9]+)?/\d+)"#, atcud],
        issueDateLabels: ["DATA DE EMISSAO", "EMITIDO A", "EMITIDA A", "DATA:"],
        periodLabels: ["PERIODO DE FATURACAO", "PERIODO DE CONSUMO", "PERIODO DE FORNECIMENTO"],
        amountLabels: ["VALOR A PAGAR", "QUANTO TENHO A PAGAR", "TOTAL A PAGAR", "VALOR DA FATURA", "VALOR TOTAL", "TOTAL"],
        refundLabels: ["VALOR A RECEBER", "A SEU FAVOR", "QUANTO VOU RECEBER", "VALOR A CREDITAR", "TOTAL EM CREDITO", "TOTAL A CREDITAR"],
        dueDateLabels: ["DATA LIMITE DE PAGAMENTO", "DATA-LIMITE DE PAGAMENTO", "DATA DE VENCIMENTO", "PAGAR ATE"])

    /// The document's unique code every Portuguese invoice prints ("ATCUD:ABCD1234-123"): the
    /// fallback number.
    public static let atcud = #"ATCUD:\s*([A-Z0-9]+-\d+)"#

    /// A starting point per common provider (brand words for detection only); the user edits them.
    public struct Preset: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var kind: UtilityKind
        public var bankDescriptionPattern: String
        public var rules: UtilityInvoiceRules
    }

    public static let presets: [Preset] = [
        Preset(name: "EDP", kind: .electricity, bankDescriptionPattern: "EDP COM", rules: UtilityInvoiceRules(
            textMarkers: ["EDP COMERCIAL", "EDP.PT"], fileNameMarkers: ["LUZ", "ELETRICIDADE", "ELECTRICIDADE", "EDP"],
            invoiceNumberPatterns: [#"FATURA N\S*\s*([A-Z]{2}\d{4} [A-Z0-9]+/\d+)"#, atcud],
            issueDateLabels: ["DOCUMENTO EMITIDO A", "EMITIDO A"],
            periodLabels: ["PERIODO DE FATURACAO"],
            amountLabels: ["QUANTO TENHO A PAGAR", "VALOR A PAGAR"],
            refundLabels: ["QUANTO VOU RECEBER", "VALOR A RECEBER"])),
        Preset(name: "Municipal water (SIMAR)", kind: .water, bankDescriptionPattern: "SIMAR", rules: UtilityInvoiceRules(
            textMarkers: ["SIMAR"], fileNameMarkers: ["AGUA"],
            invoiceNumberPatterns: [#"(?<![\d/])(\d{5}/\d{8})(?![\d/])"#, atcud],
            issueDateLabels: [],
            periodLabels: ["LITROS (", "PERIODO DE CONSUMO"],
            amountLabels: ["VALOR DA FATURA", "VALOR TOTAL", "TOTAL"],
            refundLabels: ["VALOR A RECEBER", "VALOR A CREDITAR"],
            dueDateLabels: ["LIMITE DE PAGAMENTO DA FATURA:"])),
        Preset(name: "Natural gas (CUR)", kind: .gas, bankDescriptionPattern: "GDL CUR|LISBOAGAS", rules: UtilityInvoiceRules(
            textMarkers: ["CURGASNATURAL", "LISBOAGAS", "BALCAO DIGITAL CUR"], fileNameMarkers: ["GAS"],
            invoiceNumberPatterns: [#"FATURA:\s*([A-Z]{2} [A-Z0-9]+/\d+)"#, #"FATURA (FT \d+/\d+) DE"#, #"N\S*\s*DOCUMENTO:\s*(\d+)"#, atcud],
            issueDateLabels: ["DATA:", "FATURA FT", "NOTA DE CREDITO NC"],
            periodLabels: ["PERIODO DE FATURACAO", "PERIODO FACTURADO"],
            amountLabels: ["VALOR A PAGAR", "TOTAL"],
            refundLabels: ["VALOR A RECEBER", "A SEU FAVOR", "VALOR A CREDITAR", "TOTAL EM CREDITO"],
            dueDateLabels: ["DATA LIMITE DE PAGAMENTO", "DATA-LIMITE DE PAGAMENTO"]))
    ]
}

public extension UtilityProvider {
    /// Its rules, else the generic ones.
    var effectiveRules: UtilityInvoiceRules { invoiceRules ?? .generic }

    /// Whether a bank description is this provider's: any `|`-separated part of
    /// `bankDescriptionPattern`, case- and accent-insensitively.
    func matchesBankDescription(_ description: String) -> Bool {
        guard let pattern = bankDescriptionPattern else { return false }
        let text = EvidenceText.normalized(description)
        return pattern.split(separator: "|").map { EvidenceText.normalized(String($0)) }.contains { !$0.isEmpty && text.contains($0) }
    }
}

/// What reading an invoice found (any field may be missing: the user completes it).
public struct UtilityInvoiceReading: Equatable, Sendable {
    public var providerId: Int64?
    public var invoiceNumber: String?
    public var issueDate: Date?
    public var periodStart: Date?
    public var periodEnd: Date?
    /// Negative for a refund.
    public var amountMinorUnits: Int?
    /// When the debit is due (the rules' due-date labels).
    public var dueDate: Date?
    /// The customer account's balance the invoice prints apart from its own value (an older
    /// water layout: earlier unpaid invoices included), which is what gets debited.
    public var accountTotalMinorUnits: Int?
    /// Why the amount read must be checked (it is the account balance and the invoice's own
    /// value couldn't be told for sure).
    public var amountReviewNote: String?

    public init(providerId: Int64? = nil, invoiceNumber: String? = nil, issueDate: Date? = nil, periodStart: Date? = nil,
                periodEnd: Date? = nil, amountMinorUnits: Int? = nil, dueDate: Date? = nil, accountTotalMinorUnits: Int? = nil) {
        self.dueDate = dueDate
        self.accountTotalMinorUnits = accountTotalMinorUnits
        self.providerId = providerId
        self.invoiceNumber = invoiceNumber
        self.issueDate = issueDate
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.amountMinorUnits = amountMinorUnits
    }
}

/// Reads utility invoices with their provider's rules.
public enum UtilityInvoiceReader {
    /// The provider whose text markers the text has; when several providers' do (a portal
    /// screenshot listing them all), the one the file name names, else the one marked most.
    /// Without text markers, the provider the file name names.
    public static func provider(text: String?, fileName: String, providers: [UtilityProvider]) -> UtilityProvider? {
        let body = (text.map(EvidenceText.normalized) ?? "") as NSString
        let words = Set(EvidenceText.normalized((fileName as NSString).deletingPathExtension)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func named(_ provider: UtilityProvider) -> Bool {
            provider.effectiveRules.fileNameMarkers.contains { words.contains(EvidenceText.normalized($0)) }
        }
        let marked = providers.map { provider in
            (provider, provider.effectiveRules.textMarkers.map(EvidenceText.normalized).filter { !$0.isEmpty }
                .reduce(0) { $0 + EvidenceAnalyzer.occurrences(of: $1, in: body).count })
        }.filter { $0.1 > 0 }
        if marked.count == 1 { return marked[0].0 }
        if marked.count > 1 {
            return marked.first { named($0.0) }?.0 ?? marked.max { $0.1 < $1.1 }?.0
        }
        return providers.first(where: named)
    }

    public static func read(text: String?, fileName: String, providers: [UtilityProvider]) -> UtilityInvoiceReading {
        let provider = provider(text: text, fileName: fileName, providers: providers)
        var reading = read(text: text, fileName: fileName, rules: provider?.effectiveRules ?? .generic)
        reading.providerId = provider?.id
        return reading
    }

    public static func read(text: String?, fileName: String, rules: UtilityInvoiceRules) -> UtilityInvoiceReading {
        var reading = UtilityInvoiceReading()
        // Invoices are a few pages: a huge text is cut, so patterns stay cheap.
        let body = text.map { EvidenceText.normalized(String($0.prefix(maxTextLength))) } ?? ""
        guard !body.isEmpty else {
            reading.issueDate = EvidenceDateParser.fileNameDate(fileName)
            return reading
        }
        let source = body as NSString
        reading.invoiceNumber = invoiceNumber(in: body, patterns: rules.invoiceNumberPatterns)
        reading.issueDate = labelled(rules.issueDateLabels, in: source, length: 40) { EvidenceDateParser.dates(in: $0).first?.date }
            ?? EvidenceDateParser.firstDate(in: body) ?? EvidenceDateParser.fileNameDate(fileName)
        if let period = labelled(rules.periodLabels, in: source, length: 90, period) {
            reading.periodStart = period.start
            reading.periodEnd = period.end
        }
        reading.dueDate = labelled(rules.dueDateLabels, in: source, length: 40) { EvidenceDateParser.dates(in: $0).first?.date }
        // A refund label's amount (right after it, else the first after it; even zero) is owed
        // back only when not zero.
        if let refund = labelledAmount(rules.refundLabels, in: source, positiveOnly: false), refund != 0 {
            reading.amountMinorUnits = -abs(refund)
        } else {
            reading.amountMinorUnits = labelledAmount(rules.amountLabels, in: source, positiveOnly: true)
            separateAccountTotal(&reading, in: body)
        }
        return reading
    }

    // MARK: Account balance

    /// The customer account's balance some layouts print beside the invoice's own value: "Valor
    /// da Conta Cliente em 06.07.2017 103.19", "o valor de 103.19€ será debitado" (capture group
    /// 1 on the normalized text).
    static let accountTotalPatterns: [NSRegularExpression] = [
        #"VALOR DA CONTA CLIENTE(?: EM \d{1,4}[./-]\d{1,2}[./-]\d{1,4})?\s*:?\s*(\d[\d.,]*\d)"#,
        #"VALOR DE\s*(\d[\d.,]*\d)\s*(?:€|EUR)?\s*SERA DEBITADO"#
    ].map { try! NSRegularExpression(pattern: $0) }

    /// The invoice's own value printed apart from the account balance: the first amount after
    /// the "VALOR TOTAL" column heading, else the € value in the header after the tax number.
    private static let headerValue = try! NSRegularExpression(pattern: #"FISCAL\s*:?\s*\d{9}\s*€\s*(\d[\d.,]*\d)"#)

    static func accountTotal(in body: String) -> Int? {
        firstCapturedAmount(accountTotalPatterns, in: body)
    }

    private static func firstCapturedAmount(_ patterns: [NSRegularExpression], in body: String) -> Int? {
        let text = body as NSString
        for pattern in patterns {
            for match in pattern.matches(in: body, range: NSRange(location: 0, length: text.length)) {
                if let found = EvidenceAmountParser.amount(text.substring(with: match.range(at: 1))), found.minorUnits > 0 {
                    return found.minorUnits
                }
            }
        }
        return nil
    }

    /// When the text shows the account balance (it includes earlier invoices: what is debited)
    /// and the amount read is that balance:
    /// - an explicit invoice value ("Valor da Fatura") equal to it: nothing earlier is owed;
    /// - else the invoice's own value replaces it only when the header € value and the first
    ///   "VALOR TOTAL" column figure agree and the balance is strictly greater;
    /// - else the amount is kept, to be checked (`amountReviewNote`), unless every own value
    ///   printed equals it.
    /// The balance is kept apart whenever it is greater than the amount.
    public static let amountReviewNote = "The amount read is the account total, which may include earlier invoices: check the invoice's own value"

    static func separateAccountTotal(_ reading: inout UtilityInvoiceReading, in body: String) {
        guard let total = accountTotal(in: body) else { return }
        let source = body as NSString
        if let amount = reading.amountMinorUnits, amount == total,
           labelledAmount(["VALOR DA FATURA"], in: source, positiveOnly: true) != total {
            let column = labelled(["VALOR TOTAL"], in: source, length: 70, positiveAmount)
            let header = firstCapturedAmount([headerValue], in: body)
            if let column, let header, column == header, column < total {
                reading.amountMinorUnits = column
            } else {
                let printed = [column, header].compactMap { $0 }
                if printed.isEmpty || printed.contains(where: { $0 != amount }) {
                    reading.amountReviewNote = amountReviewNote
                }
            }
        }
        if let amount = reading.amountMinorUnits, amount > 0, amount < total {
            reading.accountTotalMinorUnits = total
        }
    }

    /// The amount right after one of the labels (only spaces, `:`, a currency or a minus sign
    /// between: negative with the sign), trying the labels in order; else the first (positive,
    /// when `positiveOnly`) amount in the 70 characters after one, as before.
    static func labelledAmount(_ labels: [String], in text: NSString, positiveOnly: Bool) -> Int? {
        for label in labels {
            let key = EvidenceText.normalized(label)
            guard !key.isEmpty else { continue }
            for range in EvidenceAnalyzer.occurrences(of: key, in: text) where isWord(range, in: text) {
                let window = EvidenceAnalyzer.window(after: range, in: text, length: 70)
                guard let first = EvidenceAmountParser.amounts(in: window).first else { continue }
                let gap = (window as NSString).substring(to: first.range.location)
                let rest = gap.trimmingCharacters(in: CharacterSet(charactersIn: " :€-−").union(.whitespaces))
                guard rest.isEmpty || rest == "EUR" else { continue }
                if positiveOnly && first.minorUnits == 0 { continue }
                return gap.contains("-") || gap.contains("−") ? -first.minorUnits : first.minorUnits
            }
        }
        return labelled(labels, in: text, length: 70, positiveOnly ? positiveAmount : firstAmount)
    }

    /// Whether the label found at `range` is a word of its own (not "TOTAL" inside "SUBTOTAL").
    static func isWord(_ range: NSRange, in text: NSString) -> Bool {
        func isLetter(_ index: Int) -> Bool {
            guard index >= 0, index < text.length, let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return CharacterSet.letters.contains(scalar)
        }
        return !isLetter(range.location - 1) && !isLetter(range.location + range.length)
    }

    /// The first value `parse` finds in the window after any occurrence of the labels, in label order.
    static func labelled<T>(_ labels: [String], in text: NSString, length: Int, _ parse: (String) -> T?) -> T? {
        for label in labels {
            let key = EvidenceText.normalized(label)
            guard !key.isEmpty else { continue }
            for range in EvidenceAnalyzer.occurrences(of: key, in: text) {
                if let value = parse(EvidenceAnalyzer.window(after: range, in: text, length: length)) { return value }
            }
        }
        return nil
    }

    static let maxTextLength = 200_000

    static func firstAmount(_ window: String) -> Int? {
        EvidenceAmountParser.amounts(in: window).first?.minorUnits
    }

    static func positiveAmount(_ window: String) -> Int? {
        EvidenceAmountParser.amounts(in: window).first { $0.minorUnits > 0 }?.minorUnits
    }

    static func invoiceNumber(in body: String, patterns: [String]) -> String? {
        let range = NSRange(location: 0, length: (body as NSString).length)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: body, range: range), match.numberOfRanges > 1,
                  match.range(at: 1).location != NSNotFound else { continue }
            return (body as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static let separator = try! NSRegularExpression(pattern: #"\s(?:A|ATE|-|–)\s"#)
    private static let dayMonthAtEnd = try! NSRegularExpression(pattern: #"(\d{1,2})\s*(?:DE\s+)?(\p{L}{3,9})\.?\s*$"#)

    /// "start a end" at the start of `window`: a full start date, or a day and month taking the
    /// end's year (the year before when the month is later than the end's).
    static func period(_ window: String) -> (start: Date, end: Date)? {
        let text = window as NSString
        guard let split = separator.firstMatch(in: window, range: NSRange(location: 0, length: min(text.length, 40))) else { return nil }
        let left = text.substring(to: split.range.location)
        let right = text.substring(from: split.range.location + split.range.length)
        guard let endFound = EvidenceDateParser.dates(in: right).first, endFound.range.location <= 3 else { return nil }
        let end = endFound.date
        var start = EvidenceDateParser.dates(in: left).last?.date
        if start == nil, let match = dayMonthAtEnd.firstMatch(in: left, range: NSRange(location: 0, length: (left as NSString).length)) {
            let day = Int((left as NSString).substring(with: match.range(at: 1)))
            let month = EvidenceDateParser.months[EvidenceText.fold((left as NSString).substring(with: match.range(at: 2))).lowercased()]
            if let day, let month {
                let calendar = EvidenceText.utcCalendar
                let endYear = calendar.component(.year, from: end)
                let endMonth = calendar.component(.month, from: end)
                start = EvidenceDateParser.makeDate(year: month > endMonth ? endYear - 1 : endYear, month: month, day: day)
            }
        }
        guard let start, start <= end, PropertyFinance.days(start, end) <= 400 else { return nil }
        return (start, end)
    }
}

func registerUtilityInvoiceRulesMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addUtilityProviderInvoiceRules") { db in
        try db.alter(table: "utilityProvider") { t in
            t.add(column: "invoiceRules", .text)
        }
    }
}
