import Foundation

/// Proposes a document's kind from its text and file name, by ordered rules (first match
/// wins): the text's rules first — they are specific to each issuer's wording — then the file
/// name's, for files without readable text or with wording no rule knows. The user confirms.
public enum DocumentClassifier {
    /// A rule: the kind, and the test on the normalized text (`EvidenceText.normalized`).
    struct Rule {
        let kind: DocumentKind
        let test: (Subject) -> Bool
    }

    /// What rules look at: the normalized text, and the same without spaces (some PDFs drop
    /// them: "TOTALGBP").
    struct Subject {
        let text: String
        let squashed: String

        /// The text's first lines (normalized each), where a title is.
        let firstLines: [String]

        init(_ raw: String) {
            text = EvidenceText.normalized(raw)
            squashed = text.replacingOccurrences(of: " ", with: "")
            firstLines = Array(raw.split(whereSeparator: \.isNewline).lazy.map { EvidenceText.normalized(String($0)) }.filter { !$0.isEmpty }.prefix(6))
        }

        func has(_ needles: String...) -> Bool {
            needles.contains { text.contains($0) }
        }

        func hasSquashed(_ needles: String...) -> Bool {
            needles.contains { squashed.contains($0.replacingOccurrences(of: " ", with: "")) }
        }

        func matches(_ regex: NSRegularExpression) -> Bool {
            regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }

        /// The first `length` characters, as a subject of their own.
        func top(_ length: Int) -> Subject { Subject(normalized: String(text.prefix(length))) }

        private init(normalized: String) {
            text = normalized
            squashed = normalized.replacingOccurrences(of: " ", with: "")
            firstLines = []
        }

        /// The tax code of a Portuguese payment reference (`104 700 000 000 001` → 104: IRS;
        /// 111: IMI; 702: court fees), if one appears.
        var stateReferencePrefix: String? {
            let source = text as NSString
            guard let match = Patterns.stateReference.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
            return String(source.substring(with: match.range).prefix(3))
        }

        var isIMI: Bool { matches(Patterns.imi) || has("IMPOSTO MUNICIPAL SOBRE IMOVEIS") || stateReferencePrefix == "111" }
        var isIRS: Bool { matches(Patterns.irs) || stateReferencePrefix == "104" }
    }

    /// The rules' regular expressions, compiled once.
    enum Patterns {
        static func make(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
        static let stateReference = make(#"(?<!\d)(?:1\d{2}|702)(?: ?\d{3}){4}(?!\d)"#)
        static let imi = make(#"(?<![A-Z])IMI(?![A-Z])"#)
        static let irs = make(#"(?<![A-Z])IRS(?![A-Z])"#)
        static let p11d = make(#"\bP11D\b"#)
        static let p45 = make(#"\bP45\b"#)
        static let p60 = make(#"\bE?P60\b"#)
        static let utilityIssuer = make(#"\b(EDP|GALP|SIMAR|SMAS|EPAL|ENDESA|IBERDROLA|GOLDENERGY)\b"#)
        static let fileP45 = make(#"P45(?!\d)"#)
        static let fileP60 = make(#"P60(?!\d)"#)
        static let fileDated = make(#"^\d{8}\b"#)
        static let fileMinutes = make(#"\b(ACTA|ATA)\b"#)
        static let fileUtility = make(#"\b(LUZ|GAS|AGUA|SMAS|EDP|ELECTRICITY|WATER)\b"#)
        static let fileCourt = make(#"\b(IGFEJ|TAXA DE JUSTICA|CUSTAS)\b"#)
        static let fileLetting = make(#"\b(LETTING|ERA|MEDIACAO)\b"#)
        /// An addendum's heading word; not a contract's clause about "any addendum" to it.
        static let addendum = make(#"(?<!QUALQUER )(?<!EVENTUAL )(?<!EVENTUAIS )(?<!NENHUM )\b(ADITAMENTO|ADENDA)S?\b"#)
        static let addendumTitle = make(#"(?<!QUALQUER )(?<!EVENTUAL )(?<!NENHUM )\b(ADITAMENTO|ADENDA) (AO|DO|DE) CONTRATO DE ARRENDAMENTO"#)
        static let fileAddendum = make(#"\b(ADITAMENTO|ADENDA|ADDENDUM)S?\b"#)
        /// A tenancy word in a file name, beside an addendum word.
        static let fileTenancy = make(#"\b(ARRENDAMENTO|CONTRATO|TENANCY|RENT|RENTAL|LEASE)\b"#)
    }

    /// Text rules, in order.
    static let textRules: [Rule] = [
        // UK tax and employment
        Rule(kind: .taxReturn) { $0.has("TAX RETURN FOR THE YEAR ENDED") },
        Rule(kind: .taxCodeNotice) { $0.has("TAX CODE NOTICE", "THIS IS TO TELL YOU YOUR TAX CODE") },
        Rule(kind: .sa302) {
            $0.has("SA302") || ($0.has("CALCULATION RESULT FOR", "TAX CALCULATION") && $0.has("HM REVENUE", "HMRC", "INCOME TAX"))
        },
        Rule(kind: .hmrcPaymentProof) {
            $0.has("SELF ASSESSMENT") && $0.has("PAYMENT COMPLETE", "PAYMENT REFERENCE", "PAY YOUR SELF ASSESSMENT")
        },
        Rule(kind: .p11d) { $0.matches(Patterns.p11d) && $0.has("EXPENSES AND BENEFITS") },
        Rule(kind: .p45) { $0.matches(Patterns.p45) && $0.has("LEAVING") },
        Rule(kind: .p60) { $0.matches(Patterns.p60) && $0.has("END OF YEAR CERTIFICATE") },
        // Tenancy. An addendum is headed so ("Aditamento" / "Adenda" ao contrato de arrendamento),
        // before the contract: an addendum is never read as the contract it amends.
        Rule(kind: .tenancyAddendum) {
            ($0.top(200).matches(Patterns.addendum) || $0.matches(Patterns.addendumTitle)) && $0.has("ARRENDAMENTO")
        },
        // A contract titled so (a line among the first opens with it), before the issuer rules its
        // clauses would trip (IMI, EDP, seguro, condomínio, advogado…); the documents that only
        // name one (an IRS annex, stamp duty, a debit's description) aren't titled so.
        Rule(kind: .rentContract) { isRentContractTitle($0) },
        // Provisional: written from the portal's receipt title; no real receipt seen yet.
        Rule(kind: .rentReceipt) { $0.has("RECIBO DE RENDA") },
        // Bank documents that list other issuers' names (a statement's movements, a transfer's
        // beneficiary), before the issuer rules below.
        Rule(kind: .bankStatement) { $0.top(400).has("EXTRATO") && $0.top(400).has("SALDO", "MOVIMENTOS") },
        // BBVA's monthly "Extrato Global" opens with messages and adverts, not the word.
        Rule(kind: .bankStatement) { $0.top(400).has("PATRIMONIO CONSOLIDADO") && $0.top(400).has("PERIODO DE") },
        Rule(kind: .bankTransferProof) {
            $0.has("TIPO DE OPERACAO: TRANSFERENCIA", "TIPO DE OPERACAO : TRANSFERENCIA")
                || ($0.top(400).has("COMPROVATIVO") && $0.top(400).has("TRANSFERENCIA"))
        },
        // Portuguese taxes
        Rule(kind: .ptIRSAssessment) { $0.has("DEMONSTRACAO DE LIQUIDACAO DE IRS") },
        Rule(kind: .ptIRSDeclaration) { $0.has("DECLARACAO DE RENDIMENTOS") && $0.isIRS },
        // The tax authority's receipt for an IMI payment, before the notes of payment.
        Rule(kind: .imiPayment) { isTaxAuthorityReceipt($0) && $0.isIMI },
        // Notes of payment (their instructions mention "Pagamentos ao Estado") before payments.
        Rule(kind: .imiNotice) { $0.has("IMPOSTO MUNICIPAL SOBRE IMOVEIS") || ($0.has("NOTA DE COBRANCA") && $0.isIMI) },
        Rule(kind: .ptIRSPaymentNote) { $0.has("NOTA DE COBRANCA", "DOCUMENTO DE COBRANCA") && $0.isIRS },
        Rule(kind: .courtFee) {
            $0.has("IGFEJ", "TAXA DE JUSTICA", "CUSTAS JUDICIAIS") || (isStatePayment($0) && $0.stateReferencePrefix == "702")
        },
        Rule(kind: .imiPayment) { isStatePayment($0) && $0.isIMI },
        Rule(kind: .ptIRSPaymentProof) { isStatePayment($0) && $0.isIRS },
        // Mortgage
        Rule(kind: .mortgageInterestStatement) { $0.has("ENCARGOS COM IMOVE") },
        // The receipt after the debit is headed so; the notice before it never is.
        Rule(kind: .mortgageReceipt) { $0.has("RECIBO DE EMPRESTIMO") },
        Rule(kind: .mortgageNotice) {
            $0.has("AVISO DEBITO PRESTACAO", "AVISO DE DEBITO PRESTACAO")
                || ($0.has("PRESTACAO") && $0.has("EMPRESTIMO", "CREDITO HABITACAO") && $0.has("AVISO"))
        },
        // A receipt without its heading: the receipt's total on a loan account's letter.
        Rule(kind: .mortgageReceipt) { $0.has("TOTAL DO RECIBO") && $0.has("EMPRESTIMO", "CREDITO HABITACAO") },
        // Building (a condomínio's receipt can list the building's insurance), then insurance.
        Rule(kind: .condominioReceipt) { $0.has("CONDOMINIO") && $0.has("RECIBO N", "RECEBEMOS", "AVISO DE DEBITO", "QUOTA") },
        // A policy says so near the top, and isn't a receipt (receipts mention the conditions too).
        Rule(kind: .insurancePolicy) {
            let top = $0.top(800)
            return top.has("CONDICOES PARTICULARES", "CONDICOES GERAIS", "DOCUMENTO DE INFORMACAO SOBRE O PRODUTO DE SEGUROS",
                           "CONDICOES DE RENOVACAO", "ATA ADICIONAL", "ACTA ADICIONAL")
                && !top.has("FATURA/RECIBO", "FATURA-RECIBO", "FATURA RECIBO", "AVISO DE DEBITO", "AVISO DE PAGAMENTO", "TOTAL A PAGAR")
        },
        Rule(kind: .insuranceReceipt) {
            $0.has("BBVA SEGUROS", "BBVASEG", "TRANQUILIDADE", "GENERALI SEGUROS", "MAPFRE", "SEGURADORAS UNIDAS",
                   "FIDELIDADE", "ALLIANZ", "SEGURO VIDA", "MULTI-RISCO", "MULTIRRISCOS")
        },
        // Services
        Rule(kind: .lettingAgentFee) { $0.has("MEDIACAO IMOBILIARIA", "MEDIACAO DE ARRENDAMENTO", "COMISSAO DE MEDIACAO", "LETTING AGENT") },
        Rule(kind: .legalInvoice) { $0.has("ADVOGAD", "SOLICITADOR") },
        Rule(kind: .accountantInvoice) {
            $0.hasSquashed("CONTABILIDADE", "CONTABILISTA", "ASSISTENCIA FISCAL", "TAX ADVISER", "ACCOUNTANT", "SELF ASSESSMENT TAX")
                && $0.hasSquashed("FATURA", "FACTURA", "INVOICE", "RECIBO")
        },
        Rule(kind: .utilityInvoice) {
            $0.matches(Patterns.utilityIssuer)
                || $0.has("LISBOAGAS", "LISBOA GAS", "SERVICOS INTERMUNICIPALIZADOS", "AGUAS DO", "CONSUMO [KWH]", "CONSUMO [M3]")
        },
        // A bare "Fatura-Recibo" says nothing about what it's for: left to the file name or `other`.
        Rule(kind: .bankTransferProof) { $0.has("TRANSFERENCIA") },
        Rule(kind: .bankStatement) { $0.has("EXTRATO") && $0.has("SALDO", "MOVIMENTOS") }
    ]

    /// File-name rules, in order (the name normalized like the text).
    static let fileNameRules: [Rule] = [
        Rule(kind: .sa302) { $0.has("SA302") },
        Rule(kind: .taxReturn) { $0.has("APPROVAL", "TAX RETURN") },
        Rule(kind: .hmrcPaymentProof) { $0.has("PAYMENT COMPLETE", "HMRC PAYMENT") },
        Rule(kind: .p11d) { $0.has("P11D") },
        Rule(kind: .p45) { $0.matches(Patterns.fileP45) },
        Rule(kind: .p60) { $0.matches(Patterns.fileP60) },
        Rule(kind: .taxCodeNotice) { $0.has("TAX CODE") },
        // An addendum of a tenancy ("Aditamento contrato"), not of a mortgage or a policy.
        Rule(kind: .tenancyAddendum) { $0.matches(Patterns.fileAddendum) && $0.matches(Patterns.fileTenancy) },
        Rule(kind: .rentReceipt) { $0.has("RECIBO DE RENDA", "RECIBOS DE RENDA", "RECIBO RENDA", "RENT RECEIPT") },
        Rule(kind: .ptIRSDeclaration) { $0.isIRS && $0.has("DECLARACAO", "MOD 3", "MODELO 3") },
        Rule(kind: .ptIRSAssessment) { $0.isIRS && $0.has("LIQUIDACAO") },
        Rule(kind: .ptIRSPaymentProof) { $0.isIRS && $0.has("PAGAMENTO RECIBO", "COMPROVATIVO") },
        Rule(kind: .ptIRSPaymentNote) { $0.isIRS && $0.has("NOTA", "PAGAMENTO") },
        Rule(kind: .imiPayment) { $0.isIMI && ($0.has("PAGAMENTO", "COMPROVATIVO") || $0.matches(Patterns.fileDated)) },
        Rule(kind: .imiNotice) { $0.isIMI },
        // "Prestacao - Recibo 193:480": the receipt of instalment 193 of 480.
        Rule(kind: .mortgageReceipt) { $0.has("PRESTACAO", "EMPRESTIMO") && $0.has("RECIBO") },
        Rule(kind: .mortgageNotice) { $0.has("PRESTACAO") },
        Rule(kind: .insurancePolicy) { $0.has("CONDICOES") || $0.matches(Patterns.fileMinutes) },
        Rule(kind: .insuranceReceipt) { $0.has("SEG MR", "SEG VIDA", "SEGURO", "FATURA_RECIBO_", "INSURANCE") },
        Rule(kind: .condominioReceipt) { $0.has("CONDOMINIO") },
        Rule(kind: .courtFee) { $0.matches(Patterns.fileCourt) },
        Rule(kind: .lettingAgentFee) { $0.matches(Patterns.fileLetting) },
        Rule(kind: .legalInvoice) { $0.has("LEGAL FEE", "ADVOGAD") },
        Rule(kind: .accountantInvoice) { $0.has("ACCOUNTANCY", "CONTABILIDADE", "ACCOUNTANT") },
        Rule(kind: .utilityInvoice) { $0.matches(Patterns.fileUtility) },
        Rule(kind: .bankTransferProof) { $0.has("TRANSFERENCIA", "TRANSFER") },
        Rule(kind: .bankStatement) { $0.has("EXTRATO", "STATEMENT") }
    ]

    /// A payment to the Portuguese state: BBVA's "Pagamentos ao Estado" advice, or the tax
    /// authority's receipt titled "Comprovativo de pagamento".
    static func isStatePayment(_ subject: Subject) -> Bool {
        subject.has("PAGAMENTOS AO ESTADO", "PAGAMENTO AO ESTADO", "PAGAMENTOS - ESTADO", "PAGAMENTOS-ESTADO") || isTaxAuthorityReceipt(subject)
    }

    /// How far into the text a contract's title starts (characters).
    static let contractTitleReach = 100
    /// How much of the text's start is checked for wording that isn't a contract's (characters).
    static let contractTitleSurroundings = 150

    /// A tenancy contract's title: a line among the first that opens with "Contrato de
    /// arrendamento", within the first words; not a finance lease, with no tax, building,
    /// insurance, debit or payment wording in its first 150 characters.
    static func isRentContractTitle(_ subject: Subject) -> Bool {
        guard subject.firstLines.contains(where: { $0.hasPrefix("CONTRATO DE ARRENDAMENTO") }),
              let range = subject.text.range(of: "CONTRATO DE ARRENDAMENTO"),
              subject.text.distance(from: subject.text.startIndex, to: range.lowerBound) <= contractTitleReach else { return false }
        // The title's own surroundings only: a contract's clauses mention all of these.
        let top = subject.top(contractTitleSurroundings)
        if top.isIRS || top.isIMI { return false }
        return !top.has("CONDOMINIO", "SEGURO", "FINANCEIRO", "DEBITO", "PAGAMENTO", "REFERENCIA", "VALOR A PAGAR",
                        "FATURA", "FACTURA", "RECIBO", "INVOICE", "COMPROVATIVO", "NOTA DE COBRANCA", "DOCUMENTO DE COBRANCA")
    }

    static let duc = Patterns.make(#"\bDUC\b"#)

    /// The tax authority's "Comprovativo de pagamento" (titled so near the top).
    static func isTaxAuthorityReceipt(_ subject: Subject) -> Bool {
        subject.top(300).has("COMPROVATIVO DE PAGAMENTO")
            && (subject.has("AUTORIDADE TRIBUTARIA", "PORTAL DAS FINANCAS", "DOCUMENTO UNICO DE COBRANCA") || subject.matches(duc))
    }

    public static func classify(text: String?, fileName: String) -> DocumentKind {
        if let text, !text.isEmpty {
            let subject = Subject(text)
            if let rule = textRules.first(where: { $0.test(subject) }) { return rule.kind }
        }
        // `_` and `-` separate words in file names ("IRS_2023-Declaracao").
        let name = ((fileName as NSString).deletingPathExtension)
        let subject = Subject(name.replacingOccurrences(of: "-", with: " - "))
        let underscored = Subject(name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " - "))
        if let rule = fileNameRules.first(where: { $0.test(subject) || $0.test(underscored) }) { return rule.kind }
        return .other
    }
}
