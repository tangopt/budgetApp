import Foundation

/// A rule that may recognise a file; the first to answer wins.
public typealias ImportRecogniser = @Sendable (ImportFile) -> ImportRecognition?

/// Says what a handed-in file is, with the reason. Rules run in a fixed order; later plans
/// insert theirs (BBVA first) or append (learnt rules, the model) before the fallback.
public struct ImportDetector: Sendable {
    public var recognisers: [ImportRecogniser]

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp"]

    /// The built-in recognisers, then `learnt` (`ImportLearning.recogniser`: a certain built-in
    /// recognition always wins), then the file-name fallback.
    public init(providers: [UtilityProvider], learnt: [ImportRecogniser] = []) {
        recognisers = Self.builtIn(providers: providers) + learnt + [Self.evidenceFromFileName]
    }

    /// The built-in recognisers, in order (before any learnt one).
    private static func builtIn(providers: [UtilityProvider]) -> [ImportRecogniser] {
        [Self.bbvaStatement, Self.rentReceiptsExport, Self.rentReceiptPDF, Self.transferAdvice, Self.bbvaDebitAdvice, Self.payrollForm,
         Self.utilityInvoice(providers: providers), Self.bankStatement, Self.evidence]
    }

    /// Whether a built-in recogniser reads `file` (sure or to check): a learnt kind would never
    /// be asked about it, so none is learnt.
    public static func recognisesItself(_ file: ImportFile, providers: [UtilityProvider]) -> Bool {
        builtIn(providers: providers).contains { $0(file) != nil }
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
        guard let expected = intent.expected, !matches(expected, recognition.kind, byDocumentKind: intent.expectedByDocumentKind) else { return nil }
        return ImportIssue(id: "kindMismatch", kind: .kindMismatch(expected: expected, found: recognition.kind),
                           reason: mismatchReason(expected: expected, found: recognition.kind))
    }

    /// "Expected a <kind>, this looks like a <kind>"; when both kinds have the same name (the
    /// importer's own kind and the library's evidence kind of it), the expected one by what sets
    /// it apart: "Expected the portal's rent receipt, this looks like another rent receipt".
    public static func mismatchReason(expected: ImportKind, found: ImportKind) -> String {
        if found == .unknown { return "Expected a \(expected.displayName), but this file isn't recognised" }
        guard expected.displayName.lowercased() == found.displayName.lowercased() else {
            return "Expected a \(expected.displayName), this looks like a \(found.displayName)"
        }
        return "Expected \(specificName(expected)), this looks like another \(lowercasedName(found))"
    }

    /// A kind by what sets it apart from the kind of the same name.
    private static func specificName(_ kind: ImportKind) -> String {
        switch kind {
        case .rentReceiptPDF: return "the portal's rent receipt"
        case .utilityInvoice: return "a utility invoice the importer can read"
        case .payrollForm(let form): return "a \(form.displayName) the payroll reader can read"
        case .evidence: return "a \(lowercasedName(kind)) document for the library"
        default: return "a \(lowercasedName(kind))"
        }
    }

    /// The kind's name in a sentence (form names such as P60 keep their capitals).
    private static func lowercasedName(_ kind: ImportKind) -> String {
        switch kind {
        case .payrollForm(let form): return form.displayName
        case .evidence(let kind) where [.p60, .p45, .p11d].contains(kind): return kind.displayName
        default: return kind.displayName.lowercased()
        }
    }

    /// The kind the user declared, when a shortcut expects a plain evidence kind (Add contract…
    /// → rent contract) and nothing recognised the file (unknown, "other", or the file name
    /// only): that kind, certain, "You added it as a <kind> from <entry point>". Nil for a file
    /// recognised as anything else (a `kindMismatch`), and for kinds with an effect (payroll
    /// forms, utility invoices, statements, rent receipts): their readers must read them.
    /// `read`: whether the file's text layer was read (not OCR, not unreadable); otherwise the
    /// declared kind is to check ("Not read: check it's the <kind>").
    public static func declared(_ recognition: ImportRecognition, intent: ImportIntent, read: Bool = true) -> ImportRecognition? {
        // Payroll forms, utility invoices and statements read as their own kinds; a rent receipt as the portal's PDF.
        guard case .evidence(let kind)? = intent.expected, kind != .other, kind != .rentReceipt,
              case .evidence = ImportResolutions.importKind(for: kind, fileExtension: "") else { return nil }
        // A learnt rule's kind is the user's own answer: never overridden.
        guard recognition.ruleId == nil else { return nil }
        let unrecognised: Bool
        switch recognition.kind {
        case .unknown, .evidence(.other): unrecognised = true
        case .evidence: unrecognised = recognition.confidence == .needsReview && !recognition.proposedByModel
        default: unrecognised = false
        }
        guard unrecognised else { return nil }
        // Certain only when its text was read and says nothing else; a scan or an unreadable file
        // may be anything (an unreadable P60 never goes Ready as a contract).
        guard read else {
            return ImportRecognition(kind: .evidence(kind), confidence: .needsReview, reason: "Not read: check it's the \(kind.displayName)")
        }
        let from = intent.entryPoint.map { " from \($0)" } ?? ""
        return ImportRecognition(kind: .evidence(kind), confidence: .certain, reason: "You added it as a \(kind.displayName)\(from)")
    }

    private static func matches(_ expected: ImportKind, _ found: ImportKind, byDocumentKind: Bool) -> Bool {
        if byDocumentKind, let kind = DocumentIdentity.documentKind(of: expected), kind != .other,
           DocumentIdentity.documentKind(of: found) == kind { return true }
        if case .payrollForm = expected, case .payrollForm = found { return true }
        // A rent receipt not in the portal's layout is still a rent receipt (Receipt ▸ Add/Replace
        // PDF…): filed as evidence and linked to the receipt the user picked.
        if Set([expected, found]) == Set([.rentReceiptPDF, .evidence(.rentReceipt)]) { return true }
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

    /// A BBVA Portugal "extrato global": a PDF whose text says EXTRATO, BBVA and PERÍODO DE
    /// (ignoring accents and case), with the month of its period.
    private static let bbvaStatement: ImportRecogniser = { file in
        guard file.fileExtension == "pdf", let text = text(file) else { return nil }
        let options: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive]
        guard ["EXTRATO", "BBVA", "PERÍODO DE"].allSatisfy({ text.range(of: $0, options: options) != nil }) else { return nil }
        let folded = text.folding(options: options, locale: nil)
        var month = ""
        if let range = folded.range(of: #"periodo de (\d{4})/(\d{2})/"#, options: .regularExpression) {
            let digits = folded[range].filter(\.isNumber)
            month = " " + digits.prefix(4) + "-" + digits.dropFirst(4).prefix(2)
        }
        // Read by text recognition: to check (`BBVAStatementReader.prepare` reads the glyphs again).
        return ImportRecognition(kind: .bbvaStatement, confidence: file.usedOCR ? .needsReview : .certain, reason: "BBVA extrato global" + month)
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

    /// A BBVA debit advice ("Pagamentos – Serviços/Compras", "Débito Direto"): before utility
    /// invoices, whose providers it names as the creditor; filed as a bank debit advice.
    private static let bbvaDebitAdvice: ImportRecogniser = { file in
        guard let text = text(file), let advice = BBVADebitAdvice.parse(text) else { return nil }
        return ImportRecognition(kind: .evidence(.bankDebitAdvice), confidence: file.usedOCR ? .needsReview : .certain,
                                 reason: "BBVA debit advice of \(PropertyDates.isoDay(advice.date))")
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
        return nil
    }

    /// The last resort: the kind the file name suggests, to check.
    private static let evidenceFromFileName: ImportRecogniser = { file in
        let fromName = DocumentClassifier.classify(text: nil, fileName: file.fileName)
        if fromName != .other {
            return ImportRecognition(kind: .evidence(fromName), confidence: .needsReview, reason: "Recognised from the file name only")
        }
        return nil
    }
}
