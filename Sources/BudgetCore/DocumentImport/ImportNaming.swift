import Foundation

/// Decides where a recognised document is filed in the evidence library: its canonical name
/// and library metadata, from the kind, the facts read and the file itself.
public enum ImportNaming {
    public static func placement(kind: ImportKind, facts: [ImportFact], file: ImportFile, persons: [String]) -> ImportPlacement {
        let docDate = date(.docDate, facts)
        let periodStart = date(.periodStart, facts)
        let periodEnd = date(.periodEnd, facts)
        let money = facts.first { $0.field == .amount }.flatMap { fact -> (Int, Currency)? in
            if case .money(let amount, let currency) = fact.value { return (amount, currency) }
            return nil
        }
        let currency = money?.1 ?? facts.first { $0.field == .currency }.flatMap { fact -> Currency? in
            if case .text(let code) = fact.value { return Currency(rawValue: code.lowercased()) }
            return nil
        }
        let issuer = text(.issuer, facts)
        let reference = text(.reference, facts)
        var period: (start: Date, end: Date)?
        if let periodStart { period = (periodStart, periodEnd ?? periodStart) }
        var nameDate: Date = docDate ?? periodStart ?? file.sourceModifiedAt ?? Date(timeIntervalSince1970: 0)
        if case .payrollForm = kind, docDate == nil, let end = taxYearEnd(facts) { nameDate = end }

        var documentKind = DocumentKind.other
        var name: String?
        func build(area: String, type: String, detail: String?, precision: EvidenceNaming.DatePrecision = .day,
                   withPeriod: Bool = false, withAmount: Bool = true) -> String {
            EvidenceNaming.canonicalName(date: nameDate, precision: precision, area: area, type: type, detail: detail,
                                         period: withPeriod ? period : nil,
                                         amountMinorUnits: withAmount ? money?.0 : nil, currency: withAmount ? money?.1 : nil)
        }

        switch kind {
        case .rentReceiptsExport:
            name = build(area: "Rent", type: "Receipts export", detail: reference, withAmount: false)
        case .rentReceiptPDF:
            documentKind = .rentReceipt
            if let contract = reference, let receipt = text(.receiptNumber, facts) {
                let parsed = RentReceiptPDFs.Parsed(contractNumber: contract, receiptNumber: receipt, issueDate: docDate,
                                                    periodStart: periodStart, periodEnd: periodEnd,
                                                    amountMinorUnits: money?.0)
                name = RentReceiptPDFs.canonicalName(parsed)
            }
            if name == nil { name = build(area: "Rent", type: "Receipt", detail: reference, withPeriod: true) }
        case .transferAdvice:
            documentKind = .bankTransferProof
            name = build(area: "Bank", type: "Transfer received", detail: nil)
        case .utilityInvoice:
            documentKind = .utilityInvoice
            name = build(area: "Utilities", type: (money?.0 ?? 0) < 0 ? "Credit note" : "Invoice", detail: issuer,
                         withPeriod: true)
        case .payrollForm(let form):
            documentKind = form == .p60 ? .p60 : form == .p45 ? .p45 : .p11d
            let detail = [issuer, taxYearLabel(facts)].compactMap { $0 }.joined(separator: " ")
            name = build(area: "Tax", type: form.displayName, detail: detail, precision: .year, withAmount: false)
        case .evidence(let evidenceKind):
            documentKind = evidenceKind
            name = build(area: area(of: evidenceKind), type: evidenceKind.displayName, detail: issuer, withPeriod: true)
        case .bankStatementCSV, .bankStatementPDF, .bbvaStatement:
            documentKind = .bankStatement
            name = build(area: "Bank", type: "Statement", detail: reference ?? issuer, precision: .month, withPeriod: true,
                         withAmount: false)
        case .unknown:
            name = build(area: "Other", type: "Document", detail: nil)
        }

        let canonical = name ?? ""
        let metadata = EvidenceMetadata(kind: documentKind, docDate: docDate, periodStart: periodStart, periodEnd: periodEnd,
                                        amountMinorUnits: money?.0, currency: currency, persons: persons,
                                        canonicalName: canonical, sourceFolderId: file.sourceFolderId,
                                        sourceRelativePath: file.sourceRelativePath, sourceModifiedAt: file.sourceModifiedAt,
                                        textStatus: file.textStatus, extractedText: file.text)
        return ImportPlacement(metadata: metadata, canonicalName: canonical)
    }

    /// The library area of a document kind.
    static func area(of kind: DocumentKind) -> String {
        switch kind {
        case .mortgageNotice, .mortgageInterestStatement, .mortgageContract, .insuranceReceipt, .insurancePolicy, .imiNotice,
             .imiPayment, .condominioReceipt, .rentReceipt, .rentContract, .utilityInvoice, .accountantInvoice, .legalInvoice,
             .courtFee, .lettingAgentFee, .propertyDeed, .certificate:
            return "Property"
        case .p60, .p45, .p11d, .taxCodeNotice, .hmrcPaymentProof, .sa302, .taxReturn: return "Tax UK"
        case .ptIRSDeclaration, .ptIRSAssessment, .ptIRSPaymentNote, .ptIRSPaymentProof: return "Tax PT"
        case .bankTransferProof, .bankStatement: return "Bank"
        case .other: return "Other"
        }
    }

    private static func date(_ field: ImportFigureField, _ facts: [ImportFact]) -> Date? {
        for fact in facts where fact.field == field {
            if case .date(let date) = fact.value { return date }
        }
        return nil
    }

    private static func text(_ field: ImportFigureField, _ facts: [ImportFact]) -> String? {
        for fact in facts where fact.field == field {
            if case .text(let value) = fact.value, !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
        }
        return nil
    }

    /// 1 January of the year a tax year (by starting year) ends in.
    private static func taxYearEnd(_ facts: [ImportFact]) -> Date? {
        for fact in facts where fact.field == .taxYear {
            if case .year(let start) = fact.value {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                return calendar.date(from: DateComponents(year: start + 1, month: 1, day: 1))
            }
        }
        return nil
    }

    /// `2024/25` from a tax-year fact holding the starting year.
    private static func taxYearLabel(_ facts: [ImportFact]) -> String? {
        for fact in facts where fact.field == .taxYear {
            if case .year(let start) = fact.value { return String(format: "%d/%02d", start, (start + 1) % 100) }
        }
        return nil
    }
}
