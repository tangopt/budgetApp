import Foundation

/// What analysing a file proposes: metadata for `EvidenceLibrary.add` (kind, date, period,
/// amount, currency), and how readable the file is with the text read.
public struct EvidenceAnalysis: Equatable, Sendable {
    public var metadata: EvidenceMetadata
    public var textStatus: DocumentTextStatus
    public var extractedText: String?

    public init(metadata: EvidenceMetadata, textStatus: DocumentTextStatus, extractedText: String?) {
        self.metadata = metadata
        self.textStatus = textStatus
        self.extractedText = extractedText
    }

    /// Copies the proposal onto `document`: kind, dates, period, amount, currency and text.
    public func apply(to document: inout EvidenceDocument) {
        document.kind = metadata.kind
        document.docDate = metadata.docDate
        document.periodStart = metadata.periodStart
        document.periodEnd = metadata.periodEnd
        document.amountMinorUnits = metadata.amountMinorUnits
        document.currency = metadata.currency
        document.textStatus = textStatus
        document.extractedText = extractedText
    }
}

/// Reads a file (`EvidenceTextExtractor`), classifies it (`DocumentClassifier`) and extracts
/// its date, period and headline amount with each kind's labels ("TOTAL EUR:", "Montante
/// pago", "Tax Year to 5 April …"), falling back to the file name's date. Proposals only: the
/// user confirms them.
public enum EvidenceAnalyzer {
    public static func analyze(_ url: URL) -> EvidenceAnalysis {
        analyze(fileAt: url, named: url.lastPathComponent)
    }

    /// Analyses the file at `url` as if it were called `fileName` (a library copy stored under
    /// its hash is classified by its original name).
    public static func analyze(fileAt url: URL, named fileName: String) -> EvidenceAnalysis {
        // PDFKit and CoreGraphics autorelease a lot per file: drain it per file in a scan.
        let extraction = autoreleasepool { EvidenceTextExtractor.extract(from: url) }
        return analyze(text: extraction.text, textStatus: extraction.status, fileName: fileName)
    }

    public static func analyze(text: String?, textStatus: DocumentTextStatus, fileName: String) -> EvidenceAnalysis {
        let kind = DocumentClassifier.classify(text: text, fileName: fileName)
        var metadata = EvidenceMetadata(kind: kind)
        let body = text.map(EvidenceText.fold) ?? ""

        // Tax-year documents are dated by their period; a mortgage notice's period is found
        // around its date.
        let period: (start: Date, end: Date)?
        if taxYearKinds.contains(kind) {
            period = self.period(in: body, kind: kind, docDate: nil)
            metadata.docDate = period?.end ?? documentDate(in: body) ?? EvidenceDateParser.fileNameDate(fileName)
        } else {
            metadata.docDate = documentDate(in: body) ?? EvidenceDateParser.fileNameDate(fileName)
            period = self.period(in: body, kind: kind, docDate: metadata.docDate)
        }
        metadata.periodStart = period?.start
        metadata.periodEnd = period?.end

        if let amount = amount(in: body, kind: kind) {
            metadata.amountMinorUnits = amount.minorUnits
            metadata.currency = amount.currency ?? defaultCurrency(for: kind, text: body)
        }
        metadata.textStatus = textStatus
        metadata.extractedText = text
        return EvidenceAnalysis(metadata: metadata, textStatus: textStatus, extractedText: text)
    }

    // MARK: Amounts

    /// Labels whose next amount is the headline, per kind, most specific first.
    static func amountLabels(for kind: DocumentKind) -> [String] {
        switch kind {
        case .mortgageNotice: return ["TOTAL EUR", "TOTAL DO RECIBO"]
        case .insuranceReceipt: return ["PREMIO TOTAL", "RECEBEMOS O VALOR DE", "TOTAL A PAGAR E DE", "TOTAL A PAGAR", "MONTANTE", "TOTAL:", "TOTAL"]
        case .imiPayment, .ptIRSPaymentProof: return ["MONTANTE PAGO", "MONTANTE", "IMPORTANCIA PAGA", "VALOR PAGO", "VALOR"]
        case .imiNotice, .ptIRSPaymentNote: return ["IMPORTANCIA A PAGAR", "VALOR A PAGAR", "MONTANTE"]
        case .ptIRSAssessment: return ["VALOR A PAGAR", "VALOR A REEMBOLSAR", "IMPORTANCIA A PAGAR"]
        case .condominioReceipt: return ["TOTAL RECEBIDO", "TOTAL", "MONTANTE"]
        case .rentReceipt: return ["IMPORTANCIA RECEBIDA", "VALOR DA RENDA", "IMPORTANCIA", "QUANTIA DE", "VALOR"]
        case .courtFee: return ["MONTANTE PAGO", "MONTANTE", "IMPORTANCIA A PAGAR", "VALOR"]
        case .lettingAgentFee: return ["FOI LIQUIDADO", "TOTAL A PAGAR", "TOTAL DOCUMENTO"]
        case .accountantInvoice, .legalInvoice:
            return ["TOTALGBP", "TOTAL GBP", "TOTAL EUR", "QUANTIA DE", "TOTAL A PAGAR", "TOTAL DOCUMENTO", "TOTAL"]
        case .utilityInvoice: return ["QUANTO TENHO A PAGAR", "VALOR A PAGAR", "TOTAL A PAGAR", "MONTANTE", "TOTAL"]
        case .bankTransferProof: return ["MONTANTE", "IMPORTANCIA", "VALOR"]
        case .hmrcPaymentProof: return ["AMOUNT"]
        default: return []
        }
    }

    /// Labels that follow their amount, per kind.
    static func amountLabelsAfterValue(for kind: DocumentKind) -> [String] {
        kind == .imiNotice ? ["MES DE PAGAMENTO"] : []
    }

    /// Kinds whose amounts are too many to guess a headline from without a label (tax forms,
    /// policies, mortgage notices listing capital and balances).
    static let labelledAmountOnly: Set<DocumentKind> = [
        .mortgageNotice, .mortgageInterestStatement, .mortgageContract, .insurancePolicy, .p60, .p45, .p11d, .sa302,
        .taxReturn, .taxCodeNotice, .ptIRSDeclaration, .ptIRSAssessment, .bankStatement, .rentContract, .propertyDeed,
        .certificate, .other
    ]

    /// Every place `label` appears in `text` (case-insensitive, searched in `text` itself so the
    /// ranges index the same string the windows are cut from).
    static func occurrences(of label: String, in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: label, options: [.caseInsensitive], range: search)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            let next = found.location + found.length
            search = NSRange(location: next, length: text.length - next)
        }
        return ranges
    }

    /// Up to `length` characters of `text` after `range`.
    static func window(after range: NSRange, in text: NSString, length: Int = 120) -> String {
        let start = range.location + range.length
        return text.substring(with: NSRange(location: start, length: min(length, text.length - start)))
    }

    static func amount(in body: String, kind: DocumentKind) -> EvidenceAmountParser.Found? {
        guard !body.isEmpty else { return nil }
        let text = body as NSString
        for label in amountLabels(for: kind) {
            for found in occurrences(of: label, in: text) {
                if let amount = EvidenceAmountParser.amounts(in: window(after: found, in: text)).first(where: { $0.minorUnits > 0 }) { return amount }
            }
        }
        // Labels printed after their amount (the IMI notice's "250,00 / Mês de pagamento").
        for label in amountLabelsAfterValue(for: kind) {
            guard let found = occurrences(of: label, in: text).first else { continue }
            let start = max(0, found.location - 60)
            let before = text.substring(with: NSRange(location: start, length: found.location - start))
            if let amount = EvidenceAmountParser.amounts(in: before).last(where: { $0.minorUnits > 0 }) { return amount }
        }
        guard !labelledAmountOnly.contains(kind) else { return nil }
        // The largest amount marked with a currency, bar the issuer's share capital.
        return EvidenceAmountParser.amounts(in: body).filter { amount in
            guard amount.currency != nil else { return false }
            let start = max(0, amount.range.location - 30)
            let before = text.substring(with: NSRange(location: start, length: amount.range.location - start)).uppercased()
            return !before.contains("CAPITAL")
        }.max { $0.minorUnits < $1.minorUnits }
    }

    static let ukKinds: Set<DocumentKind> = [.p60, .p45, .p11d, .taxCodeNotice, .hmrcPaymentProof, .sa302, .taxReturn]
    /// Dated by the end of the tax year they cover.
    static let taxYearKinds: Set<DocumentKind> = [.p60, .p11d, .sa302, .taxReturn]

    static func defaultCurrency(for kind: DocumentKind, text: String) -> Currency {
        if ukKinds.contains(kind) { return .gbp }
        let pounds = text.filter { $0 == "£" }.count + text.components(separatedBy: "GBP").count - 1
        let euros = text.filter { $0 == "€" }.count + text.components(separatedBy: "EUR").count - 1
        return pounds > euros ? .gbp : .eur
    }

    // MARK: Dates

    /// Labels whose next date is the document's own date, most specific first.
    static let dateLabels = [
        "DATA DE PAGAMENTO", "DATA PROCESSAMENTO", "DATA DE PROCESSAMENTO", "DATA DE EMISSAO", "DATA DE LIQUIDACAO",
        "DOCUMENTO EMITIDO A", "EMITIDO A", "EMITIDO EM", "INVOICE DATE", "INVOICEDATE", "DATA:", "DATA :", "DATA VALOR", "DATE", "DATA"
    ]

    /// What a date label can be followed by that isn't the document's date.
    static let otherDates = ["OF BIRTH", "DE NASCIMENTO", "DE VALIDADE", "DE VALIDITY", "OF EXPIRY"]

    static func documentDate(in body: String) -> Date? {
        guard !body.isEmpty else { return nil }
        let text = body as NSString
        for label in dateLabels {
            // A named label is followed by its date; bare "DATA:" can be followed by other
            // fields first (BBVA's layout).
            let reach = label.contains(" ") && !label.hasSuffix(":") ? 40 : 120
            for found in occurrences(of: label, in: text) {
                var after = window(after: found, in: text, length: reach)
                // Up to the next date label: that date is the other label's.
                if let next = after.range(of: #"\bDAT[AE]\b"#, options: [.regularExpression, .caseInsensitive]) {
                    after = String(after[..<next.lowerBound])
                }
                let lead = after.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if otherDates.contains(where: lead.hasPrefix) { continue }
                if let date = EvidenceDateParser.firstDate(in: after) { return date }
            }
        }
        // "Lisboa, 12 de outubro de 2025"-style letters, then the first date at all.
        return EvidenceDateParser.firstDate(in: body)
    }

    // MARK: Periods

    private static let rangeSeparator = try! NSRegularExpression(pattern: #"^\s*(?:\d{1,2}:\d{2}(?::\d{2})?)?\s*(?:a|/|-|–|to|ate|ao|até)\s*$"#, options: [.caseInsensitive])
    private static let wordRange = try! NSRegularExpression(
        pattern: #"(\d{1,2})\s*(?:de\s+)?(\p{L}{3,9})(?:\s*(?:de\s+)?(\d{4}))?\s+(?:a|to|ate|-)\s+(\d{1,2})\s*(?:de\s+)?(\p{L}{3,9})\s*(?:de\s+)?(\d{4})"#,
        options: [.caseInsensitive])

    static func period(in text: String, kind: DocumentKind, docDate: Date?) -> (start: Date, end: Date)? {
        guard !text.isEmpty else { return nil }
        if ukKinds.contains(kind), let year = ukTaxYearEnd(in: text) {
            return (ukDate(year - 1, 4, 6), ukDate(year, 4, 5))
        }
        if kind == .mortgageNotice { return mortgagePeriod(in: text, docDate: docDate) }
        if let range = explicitRange(in: text) { return range }
        if [.imiNotice, .imiPayment, .ptIRSDeclaration, .ptIRSAssessment, .ptIRSPaymentNote, .ptIRSPaymentProof].contains(kind),
           let year = labelledYear(in: text) {
            return (ukDate(year, 1, 1), ukDate(year, 12, 31))
        }
        return nil
    }

    /// How far from the notice's date its interest period's ends can be.
    static let mortgageReach: TimeInterval = 45 * 86_400

    /// A mortgage notice's interest period, ending on the debit's value date: the end is the
    /// date next to "DATA FIM" (BBVA prints it just before or after the label) when not before
    /// the notice's date, else the first date after it (or the notice's date itself); the start is the latest date before both,
    /// within 45 days (other dates on a notice — the loan's start, a rate's — are ignored).
    static func mortgagePeriod(in body: String, docDate: Date?) -> (start: Date, end: Date)? {
        let found = EvidenceDateParser.dates(in: body)
        guard let anchor = docDate ?? found.first?.date else { return nil }
        let near = found.filter { abs($0.date.timeIntervalSince(anchor)) <= mortgageReach }
        let text = body as NSString
        var end: Date?
        if let label = occurrences(of: "DATA FIM", in: text).first {
            let labelled = near.min { distance($0.range, label) < distance($1.range, label) }
            // Labels and values can be printed apart: one before the notice's date is the start's.
            if let labelled, distance(labelled.range, label) <= 40, labelled.date >= anchor { end = labelled.date }
        }
        end = end ?? near.map(\.date).filter { $0 > anchor }.min() ?? anchor
        guard let end else { return nil }
        let earliest = min(anchor, end)
        guard let start = near.map(\.date).filter({ $0 < earliest && end.timeIntervalSince($0) <= mortgageReach }).max() else { return nil }
        return (start, end)
    }

    private static func distance(_ a: NSRange, _ b: NSRange) -> Int {
        if a.location + a.length <= b.location { return b.location - (a.location + a.length) }
        if b.location + b.length <= a.location { return a.location - (b.location + b.length) }
        return 0
    }

    /// The first "date a date" / "date / date" / "12 de setembro a 11 de novembro 2022" range.
    static func explicitRange(in text: String) -> (start: Date, end: Date)? {
        let source = text as NSString
        let dates = EvidenceDateParser.dates(in: text)
        for (first, second) in zip(dates, dates.dropFirst()) {
            let gapStart = first.range.location + first.range.length
            guard second.range.location >= gapStart else { continue }
            let gap = source.substring(with: NSRange(location: gapStart, length: second.range.location - gapStart))
            if rangeSeparator.firstMatch(in: gap, range: NSRange(location: 0, length: (gap as NSString).length)) != nil,
               first.date <= second.date {
                return (first.date, second.date)
            }
        }
        if let match = wordRange.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) {
            func group(_ index: Int) -> String? {
                let r = match.range(at: index)
                return r.location == NSNotFound ? nil : source.substring(with: r)
            }
            let months = EvidenceDateParser.months
            if let endDay = group(4).flatMap({ Int($0) }), let endMonth = group(5).flatMap({ months[$0.lowercased()] }),
               let endYear = group(6).flatMap({ Int($0) }), let startDay = group(1).flatMap({ Int($0) }),
               let startMonth = group(2).flatMap({ months[$0.lowercased()] }) {
                let startYear = group(3).flatMap { Int($0) } ?? (startMonth > endMonth ? endYear - 1 : endYear)
                if let start = EvidenceDateParser.makeDate(year: startYear, month: startMonth, day: startDay),
                   let end = EvidenceDateParser.makeDate(year: endYear, month: endMonth, day: endDay), start <= end {
                    return (start, end)
                }
            }
        }
        return nil
    }

    /// The year a UK tax-year document ends in: "Tax Year to 5 April 2024", "year ended 5 April
    /// 2024", "for 2023-24", "2023 to 2024".
    static func ukTaxYearEnd(in text: String) -> Int? {
        let source = text as NSString
        let all = NSRange(location: 0, length: source.length)
        for match in yearEndedPattern.matches(in: text, range: all) {
            if let year = Int(source.substring(with: match.range(at: 1))), (1990...2100).contains(year) { return year }
        }
        for match in yearSpanPattern.matches(in: text, range: all) {
            guard let start = Int(source.substring(with: match.range(at: 1))), let endRaw = Int(source.substring(with: match.range(at: 2))) else { continue }
            let end = endRaw < 100 ? (start / 100) * 100 + endRaw : endRaw
            if end == start + 1, (1990...2100).contains(end) { return end }
        }
        return nil
    }

    private static let yearEndedPattern = try! NSRegularExpression(pattern: #"(?:year\s*to|year\s*ended)\s*5\s*April\s*(\d{4})"#, options: [.caseInsensitive])
    private static let yearSpanPattern = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4})\s*(?:-|/|to)\s*(\d{2}|\d{4})(?!\d)"#, options: [.caseInsensitive])
    private static let labelledYearPattern = try! NSRegularExpression(
        pattern: #"(?:ANO DE IMPOSTO|ANO DOS RENDIMENTOS|EXERCICIO|IRS|IMI)\s*:?\s*(\d{4})(?!\d)"#, options: [.caseInsensitive])

    /// A Portuguese tax document's year: "ANO DE IMPOSTO 2016", "Exercício 2023", "IRS 2023".
    static func labelledYear(in text: String) -> Int? {
        let source = text as NSString
        guard let match = labelledYearPattern.firstMatch(in: text, range: NSRange(location: 0, length: source.length)),
              let year = Int(source.substring(with: match.range(at: 1))), (1990...2100).contains(year) else { return nil }
        return year
    }

    private static func ukDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        EvidenceDateParser.makeDate(year: year, month: month, day: day)!
    }
}
