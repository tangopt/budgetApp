import Foundation
import GRDB

/// BBVA's advice of a debit from the account: a "Pagamentos – Serviços/Compras" payment or a
/// "Débito Direto" collection, read from its text (BBVA PDFs use glyph-named fonts, decoded by
/// `PDFGlyphTextExtractor` when the file is loaded). The letter mirrors the received-transfer
/// advice (`RentCreditEvidence.parseAdvice`): labels and values may be scattered, so every
/// amount is kept, and the labelled one when a label carries its value on the same line.
public enum BBVADebitAdvice {
    public struct Advice: Equatable, Sendable {
        /// The operation date (a "Data do movimento/operação" label first, else the letter's "Data:").
        public var date: Date
        /// Every non-zero amount the advice states, fees aside (commission, tax, stamp duty lines).
        public var amounts: Set<Int>
        /// The amount a "Montante/Importância/Valor" label carries (on its line, or alone on the
        /// next line after a bare label), else the only amount.
        public var amount: Int?
        /// The creditor or description ("Credor", "Beneficiário", "Descritivo", "Descrição").
        public var creditor: String?
        /// The payment entity ("Entidade": a services payment's entity code).
        public var entity: String?
        /// The payment reference or direct-debit mandate ("Referência", "Autorização", "Mandato").
        public var reference: String?

        /// The words of the creditor, entity and reference (folded, uppercased): what a debit's
        /// description may name — never the letter's boilerplate or the client's name.
        public var namedWords: Set<String> {
            Set([creditor, entity, reference].compactMap { $0 }.flatMap { value in
                value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            })
        }

        /// The creditor, entity and reference with spaces removed (spaced references joined).
        public var namedCompact: String {
            [creditor, entity, reference].compactMap { $0 }.joined().filter { $0.isLetter || $0.isNumber }
        }
    }

    /// Headings of a debit advice, on the text with punctuation as spaces.
    static let headings = [
        "PAGAMENTOS SERVICOS", "PAGAMENTO SERVICOS", "PAGAMENTOS DE SERVICOS", "PAGAMENTO DE SERVICOS",
        "SERVICOS E COMPRAS", "SERVICOS COMPRAS", "PAGAMENTOS COMPRAS", "PAGAMENTO DE COMPRAS", "PAGAMENTOS DE COMPRAS",
        "DEBITO DIRETO", "DEBITO DIRECTO", "DEBITOS DIRETOS", "DEBITOS DIRECTOS"
    ]
    /// The bank's own wording of an advice (as the received-transfer letter has it: "Queira(m)
    /// notar que, nesta data, efetuámos na conta de V.Exa(s)…"). A bare "BBVA" is not enough:
    /// BBVA Seguros receipts and invoices paid by direct debit at BBVA name the bank too.
    static let adviceWording = [
        "NA CONTA DE V EXA", "NA CONTA DE V EXAS", "NA CONTA DE VEXA", "NA SUA CONTA", "DEBITAMOS", "EFETUAMOS", "EFECTUAMOS",
        "QUEIRA M NOTAR", "QUEIRAM NOTAR", "QUEIRA NOTAR"
    ]
    /// Other documents that mention a direct debit or a payment: received transfers, state
    /// payments, invoices and receipts paid by direct debit, insurance documents, collection
    /// notices, statements.
    static let otherDocuments = [
        "TRANSFERENCIA RECEBIDA", "PAGAMENTOS AO ESTADO", "PAGAMENTO AO ESTADO", "PAGAMENTOS ESTADO",
        "FATURA RECIBO", "FACTURA RECIBO", "NOTA DE CREDITO", "TOTAL A PAGAR", "VALOR A PAGAR", "QUANTO TENHO A PAGAR",
        "APOLICE", "AVISO DE COBRANCA", "PATRIMONIO CONSOLIDADO", "AVISO DEBITO PRESTACAO", "AVISO DE DEBITO PRESTACAO"
    ]
    /// Other documents by a word's start ("Fatura nº", "Fatura n.º", "Fatura número", "Recibo nº").
    static let otherDocumentPrefixes = ["FATURA N", "FACTURA N", "RECIBO N"]
    /// Lines whose amount is a fee, never the debit's.
    static let feeWords = ["COMISSAO", "IMPOSTO", "SELO", "DESPESAS"]
    static let amountLabels = ["MONTANTE", "IMPORTANCIA", "VALOR"]

    private static let labelledDate = try! NSRegularExpression(
        pattern: #"(DATA[A-Z .\-]{0,30}?)\s*:\s*(\d{4}-\d{2}-\d{2}|\d{2}[-/.]\d{2}[-/.]\d{4})"#)
    private static let anyDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4}-\d{2}-\d{2}|\d{2}[-/.]\d{2}[-/.]\d{4})(?!\d)"#)
    private static let moneyPattern = try! NSRegularExpression(pattern: #"(?<![\d.,])(\d{1,3}(?:\.\d{3})*,\d{2}|\d+,\d{2})(?![\d,])"#)

    /// Folded and uppercased, the ordinal indicators as letters ("Nº" → "NO").
    static func folded(_ text: String) -> String {
        EvidenceText.fold(text).uppercased().replacingOccurrences(of: "º", with: "O").replacingOccurrences(of: "ª", with: "A")
    }

    /// Reads a BBVA debit advice; `nil` for any other text.
    public static func parse(_ text: String) -> Advice? {
        let folded = folded(text)
        let spaced = " " + folded.map { $0.isLetter || $0.isNumber ? $0 : " " }.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ") + " "
        func has(_ phrases: [String]) -> Bool { phrases.contains { spaced.contains(" \($0) ") } }
        guard has(headings), has(adviceWording), !has(otherDocuments),
              !otherDocumentPrefixes.contains(where: { spaced.contains(" \($0)") }) else { return nil }
        // A mortgage instalment ("prestação" of a loan); a "prestação de serviços" is not one.
        guard !(has(["PRESTACAO", "PRESTACOES"]) && has(["EMPRESTIMO", "CREDITO HABITACAO", "CREDITO A HABITACAO"])) else { return nil }
        let words = Set(spaced.split(separator: " ").map(String.init))
        guard !(words.contains("EXTRATO") && words.contains("SALDO")) else { return nil }
        guard let date = operationDate(folded) else { return nil }

        let lines = folded.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        func money(_ line: String) -> [Int] {
            moneyPattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { found -> Int? in
                Range(found.range(at: 1), in: line).flatMap { RentReceiptPDFs.cents(String(line[$0])) }
            }.filter { $0 > 0 }
        }
        let amounts = Set(lines.filter { line in !feeWords.contains { line.contains($0) } }.flatMap(money))
        guard !amounts.isEmpty else { return nil }

        var labelled: Int?
        for (index, line) in lines.enumerated() where amountLabels.contains(where: { line.hasPrefix($0) }) {
            if let first = money(line).first { labelled = first; break }
            // A bare label ("MONTANTE:"): its value alone on the next line.
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            let bare = next.replacingOccurrences(of: "EUR", with: "").replacingOccurrences(of: "€", with: "").trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":"), money(next).count == 1, let value = RentReceiptPDFs.cents(bare), value > 0 {
                labelled = value
                break
            }
        }
        let creditor = value(in: lines, labels: ["CREDOR", "BENEFICIARIO", "DESCRITIVO", "DESCRICAO"])
        let entity = value(in: lines, labels: ["ENTIDADE"])
        let reference = value(in: lines, labels: ["REFERENCIA", "AUTORIZACAO", "MANDATO", "REF."], needsDigit: true)
        return Advice(date: date, amounts: amounts, amount: labelled ?? (amounts.count == 1 ? amounts.first : nil),
                      creditor: creditor, entity: entity, reference: reference)
    }

    /// The first date after a "Data … do movimento / operação / débito / valor" label, else the
    /// first labelled date, else the first date.
    private static func operationDate(_ folded: String) -> Date? {
        let range = NSRange(folded.startIndex..., in: folded)
        var first: Date?
        for match in labelledDate.matches(in: folded, range: range) {
            guard let labelRange = Range(match.range(at: 1), in: folded), let dateRange = Range(match.range(at: 2), in: folded),
                  let date = day(String(folded[dateRange])) else { continue }
            let label = folded[labelRange]
            if ["MOVIMENTO", "OPERACAO", "DEBITO", "VALOR"].contains(where: { label.contains($0) }) { return date }
            if first == nil { first = date }
        }
        if let first { return first }
        return anyDate.firstMatch(in: folded, range: range).flatMap { Range($0.range(at: 1), in: folded) }
            .flatMap { day(String(folded[$0])) }
    }

    /// "2024-03-04", "04-03-2024", "04/03/2024" or "04.03.2024".
    static func day(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { "-/.".contains($0) }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] > 31 ? EvidenceDateParser.makeDate(year: parts[0], month: parts[1], day: parts[2])
            : EvidenceDateParser.makeDate(year: parts[2], month: parts[1], day: parts[0])
    }

    /// The value after the first of `labels` (in order of preference) that starts a line and
    /// carries one after its colon.
    private static func value(in lines: [String], labels: [String], needsDigit: Bool = false) -> String? {
        for label in labels {
            for line in lines where line.hasPrefix(label) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let found = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if found.isEmpty || (needsDigit && !found.contains(where: \.isNumber)) { continue }
                return found
            }
        }
        return nil
    }

    // MARK: Matching

    /// Words of a bank description that never identify a payment.
    static let descriptionStopwords: Set<String> = RentCreditEvidence.payerStopwords.union([
        "SEPADD", "SEPA", "DEBITO", "DEBITOS", "DIRETO", "DIRECTO", "COMPRA", "COMPRAS", "SERVICOS", "SERVICO", "SERV",
        "PAGAMENTOS", "PAGAMENTO", "PAGT", "PAGTO", "COBRANCA", "EUR", "CARTAO", "TRANSF",
        // Three-letter abbreviations of bank descriptions (a payee's three letters still count).
        "PAG", "SEG", "LDA", "TRF", "COM", "DES", "REF", "NUM", "CTA", "MOV", "SEP", "ADC", "MBW", "TPA", "COB", "DEB", "SER"
    ])

    /// The word of `description` the advice names: a word of three or more letters, or of four
    /// or more letters and digits (stopwords aside), among the creditor's, entity's and
    /// reference's words, or a number of five or more digits in them; `nil` when none.
    public static func namedWord(_ description: String, in advice: Advice) -> String? {
        let folded = folded(description)
        let named = advice.namedWords, compact = advice.namedCompact
        let tokens = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for token in tokens where !descriptionStopwords.contains(token)
            && (token.count >= 4 || (token.count == 3 && token.allSatisfy(\.isLetter))) {
            if token.allSatisfy(\.isNumber) {
                if token.count >= 5, compact.contains(token) { return token }
            } else if named.contains(token) {
                return token
            }
        }
        return nil
    }

    // MARK: Debits

    /// Days between the advice's date and its debit's booking.
    public static let dayWindow = 2

    /// The debits that may be the advice's: one of its amounts (the labelled one when read),
    /// booked within `dayWindow` days of its date, on a BBVA account when one is known (an
    /// account whose name or alias says BBVA), nearest first; `named` those whose description
    /// names the creditor, entity or reference (`namedWord`).
    public static func debits(db: Database, advice: Advice) throws -> (all: [Transaction], named: [(Transaction, String)]) {
        let amounts = advice.amount.map { [$0] } ?? Array(advice.amounts)
        let slack = TimeInterval(dayWindow) * 86_400 + 12 * 3_600
        let from = advice.date.addingTimeInterval(-slack), to = advice.date.addingTimeInterval(slack)
        let bbva = Set(try Account.fetchAll(db).filter { account in
            [account.name, account.alias ?? ""].contains { folded($0).contains("BBVA") }
        }.compactMap(\.id))
        let all = try Transaction
            .filter(amounts.map { -$0 }.contains(Column("amountMinorUnits")))
            .fetchAll(db)
            .filter { $0.date >= from && $0.date <= to && (bbva.isEmpty || bbva.contains($0.accountId)) }
            .sorted { (abs($0.date.timeIntervalSince(advice.date)), $0.id ?? 0) < (abs($1.date.timeIntervalSince(advice.date)), $1.id ?? 0) }
        let named = all.compactMap { debit in namedWord(debit.rawDescription, in: advice).map { (debit, $0) } }
        return (all, named)
    }

    /// What one pass read of each library advice (by id and content), so the filed-year guard's
    /// repeated follow-ons parse each document's text once. Not thread-safe: one pass, one connection.
    public final class Cache {
        struct Key: Hashable {
            var id: Int64
            var sha256: String
        }
        private var advices: [Key: Advice?] = [:]
        /// Documents whose text was parsed (tests).
        public private(set) var parses = 0

        public init() {}

        func advice(_ key: Key, text: () throws -> String?) rethrows -> Advice? {
            if let cached = advices[key] { return cached }
            parses += 1
            let advice = try text().flatMap(BBVADebitAdvice.parse)
            advices[key] = advice
            return advice
        }
    }

    /// Links the bank debit advices in the library that have no transaction yet to their debit,
    /// when exactly one debit fits and names it (`debits`) and that debit has no debit advice
    /// already; the others stay as they are (the user links them). Returns the links made.
    @discardableResult
    public static func linkLibraryAdvices(db: Database, cache: Cache = Cache()) throws -> [(documentId: Int64, transactionId: Int64)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT d.id, d.sha256 FROM document d
            WHERE d.kind = ? AND NOT EXISTS (SELECT 1 FROM documentLink l WHERE l.documentId = d.id AND l.entityType = ?)
            ORDER BY d.id
            """, arguments: [DocumentKind.bankDebitAdvice.rawValue, EvidenceEntityType.transaction.rawValue])
        var made: [(documentId: Int64, transactionId: Int64)] = []
        for row in rows {
            let id: Int64 = row[0], sha: String = row[1]
            let advice = try cache.advice(Cache.Key(id: id, sha256: sha)) {
                try String.fetchOne(db, sql: "SELECT extractedText FROM document WHERE id = ?", arguments: [id])
            }
            guard let advice else { continue }
            let named = try debits(db: db, advice: advice).named
            guard named.count == 1, let transactionId = named[0].0.id else { continue }
            let taken = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM documentLink l JOIN document d ON d.id = l.documentId
                               WHERE l.entityType = ? AND l.entityId = ? AND d.kind = ?)
                """, arguments: [EvidenceEntityType.transaction.rawValue, transactionId, DocumentKind.bankDebitAdvice.rawValue]) ?? false
            guard !taken else { continue }
            try EvidenceLinks.link(db: db, documentId: id, to: .transaction(transactionId))
            made.append((id, transactionId))
        }
        return made
    }
}
