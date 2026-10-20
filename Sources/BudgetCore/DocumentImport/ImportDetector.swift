import Foundation

/// A rule that may recognise a file; the first to answer wins.
public typealias ImportRecogniser = @Sendable (ImportFile) -> ImportRecognition?

/// Says what a handed-in file is, with the reason. Rules run in a fixed order; later plans
/// insert theirs (BBVA first) or append (learnt rules, the model) before the fallback.
public struct ImportDetector: Sendable {
    public var recognisers: [ImportRecogniser]

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp"]

    public init(providers: [UtilityProvider]) {
        recognisers = [
            Self.rentReceiptsExport, Self.rentReceiptPDF, Self.transferAdvice, Self.payrollForm,
            Self.utilityInvoice(providers: providers), Self.bankStatement, Self.evidence
        ]
    }

    public func detect(_ file: ImportFile) -> ImportRecognition {
        for recogniser in recognisers {
            if let found = recogniser(file) { return found }
        }
        if file.fileExtension == "csv" {
            return ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "The file could not be read as text")
        }
        return ImportRecognition(kind: .unknown, confidence: .needsReview, reason: "Not recognised")
    }

    /// `kindMismatch` when the user said what the files are and this one is something else.
    public static func intentIssue(_ recognition: ImportRecognition, intent: ImportIntent) -> ImportIssue? {
        guard let expected = intent.expected, !matches(expected, recognition.kind) else { return nil }
        return ImportIssue(id: "kindMismatch", kind: .kindMismatch(expected: expected, found: recognition.kind),
                           reason: "Expected a \(expected.displayName), this looks like a \(recognition.kind.displayName)")
    }

    private static func matches(_ expected: ImportKind, _ found: ImportKind) -> Bool {
        if case .payrollForm = expected, case .payrollForm = found { return true }
        return expected == found
    }

    // MARK: Rules

    /// The text a rule may read: a leading byte order mark removed.
    private static func text(_ file: ImportFile) -> String? {
        guard var text = file.text else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// The classifier's kind from the text alone.
    private static func kindFromText(_ file: ImportFile) -> DocumentKind {
        guard let text = text(file), !text.isEmpty else { return .other }
        return DocumentClassifier.classify(text: text, fileName: "")
    }

    private static let rentReceiptsExport: ImportRecogniser = { file in
        guard file.fileExtension == "xlsx", let data = try? Data(contentsOf: file.url),
              let rows = try? RentReceiptsExport.parse(xlsx: data), !rows.isEmpty else { return nil }
        return ImportRecognition(kind: .rentReceiptsExport, confidence: .certain,
                                 reason: "Portal das Finanças receipts export (\(rows.count) rows)")
    }

    private static let rentReceiptPDF: ImportRecogniser = { file in
        guard let text = text(file), let parsed = RentReceiptPDFs.parse(text) else { return nil }
        return ImportRecognition(kind: .rentReceiptPDF, confidence: .certain,
                                 reason: "Rent receipt nº \(parsed.receiptNumber) of contract \(parsed.contractNumber)")
    }

    private static let transferAdvice: ImportRecogniser = { file in
        guard let text = text(file), let advice = RentCreditEvidence.parseAdvice(text) else { return nil }
        let parts = MonthRange.calendar.dateComponents([.year, .month, .day], from: advice.date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return ImportRecognition(kind: .transferAdvice, confidence: .certain, reason: "BBVA received-transfer advice of \(day)")
    }

    private static let payrollForm: ImportRecogniser = { file in
        let form: PayrollFormKind
        switch kindFromText(file) {
        case .p60: form = .p60
        case .p45: form = .p45
        case .p11d: form = .p11d
        default: return nil
        }
        return ImportRecognition(kind: .payrollForm(form), confidence: .certain, reason: "\(form.displayName) wording")
    }

    private static func utilityInvoice(providers: [UtilityProvider]) -> ImportRecogniser {
        { file in
            let kind = kindFromText(file)
            guard UtilityInvoiceIntake.isUtilityInvoice(text: text(file), fileName: file.fileName,
                                                        kind: kind,
                                                        providers: providers) else { return nil }
            let name = UtilityInvoiceReader.provider(text: text(file), fileName: file.fileName, providers: providers)?.name
            return ImportRecognition(kind: .utilityInvoice, confidence: .certain, reason: "Invoice of \(name ?? "a utility provider")")
        }
    }

    private static let bankStatement: ImportRecogniser = { file in
        if file.fileExtension == "csv" {
            guard text(file) != nil else { return nil }
            return ImportRecognition(kind: .bankStatementCSV, confidence: .certain, reason: "CSV file")
        }
        if file.fileExtension == "pdf", kindFromText(file) == .bankStatement {
            return ImportRecognition(kind: .bankStatementPDF, confidence: .certain, reason: "Bank statement wording")
        }
        return nil
    }

    private static let evidence: ImportRecogniser = { file in
        let fromText = kindFromText(file)
        if fromText != .other {
            return ImportRecognition(kind: .evidence(fromText), confidence: .certain, reason: "\(fromText.displayName) wording")
        }
        let fromName = DocumentClassifier.classify(text: nil, fileName: file.fileName)
        if fromName != .other {
            return ImportRecognition(kind: .evidence(fromName), confidence: .needsReview, reason: "Recognised from the file name only")
        }
        return nil
    }
}
