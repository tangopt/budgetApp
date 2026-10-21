import GRDB
import Foundation

/// The evidence of a rent credit (the tenant's bank transfer), linked to the transaction itself
/// so it shows its paperclip wherever transactions are listed:
/// - the Portal das Finanças receipt PDF of every receipt the credit paid (`rentReceiptPayment`),
///   role "Rent receipt";
/// - the bank's own advice of the transfer received (BBVA "TRANSFERÊNCIA RECEBIDA" letter),
///   matched by date, amount and the statement reference, role "Payment proof".
public enum RentCreditEvidence {
    /// The role of a receipt PDF on the credit that paid it.
    public static let receiptRole = "Rent receipt"
    /// The role of the bank's advice on its credit (the one the initial import used).
    public static let adviceRole = "Payment proof"

    // MARK: Receipt PDFs on credits

    /// A receipt document linked to a credit.
    public struct ReceiptDocumentLink: Equatable, Sendable {
        public var documentId: Int64
        public var transactionId: Int64
        public var rentReceiptId: Int64
    }

    /// Links the rent-receipt documents of each receipt to the credits that pay it (active
    /// payment links with rent), skipping pairs already linked. `receiptIds`: only these
    /// receipts (`nil`: every receipt). Returns the links made. Idempotent.
    @discardableResult
    public static func linkReceiptDocuments(db: Database, receiptIds: [Int64]? = nil) throws -> [ReceiptDocumentLink] {
        var sql = """
            SELECT DISTINCT dl.documentId, p.transactionId, p.rentReceiptId
            FROM rentReceiptPayment p
            JOIN documentLink dl ON dl.entityType = ? AND dl.entityId = p.rentReceiptId
            JOIN document d ON d.id = dl.documentId AND d.kind = ?
            WHERE p.isDismissed = 0 AND p.rentMinorUnits > 0
              AND NOT EXISTS (SELECT 1 FROM documentLink t WHERE t.documentId = dl.documentId
                              AND t.entityType = ? AND t.entityId = p.transactionId)
            """
        var arguments: StatementArguments = [EvidenceEntityType.rentReceipt.rawValue, DocumentKind.rentReceipt.rawValue,
                                             EvidenceEntityType.transaction.rawValue]
        if let receiptIds {
            guard !receiptIds.isEmpty else { return [] }
            sql += " AND p.rentReceiptId IN (\(receiptIds.map { _ in "?" }.joined(separator: ",")))"
            arguments += StatementArguments(receiptIds)
        }
        sql += " ORDER BY p.rentReceiptId, p.transactionId, dl.documentId"
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        var made: [ReceiptDocumentLink] = []
        var seen: Set<[Int64]> = []
        for row in rows {
            let link = ReceiptDocumentLink(documentId: row[0], transactionId: row[1], rentReceiptId: row[2])
            // One receipt PDF may pay into a credit through two receipts' links: link it once.
            guard seen.insert([link.documentId, link.transactionId]).inserted else { continue }
            try EvidenceLinks.link(db: db, documentId: link.documentId, to: .transaction(link.transactionId), role: receiptRole)
            made.append(link)
        }
        return made
    }

    /// Receipt-role links that no PDF-carrying active payment supports any more go by
    /// themselves: SQL triggers (`registerRentCreditEvidenceMigration`) fire when a payment link is
    /// deleted, dismissed or loses its rent, and when a receipt's document link goes (Replace PDF,
    /// unlinking in Documents or Missing evidence, a receipt, tenancy or property deleted, a
    /// cancellation in the portal import). Links the user made by hand under any other role stay.
    ///
    /// The user's own changes: a receipt-role link removed by hand from a transaction comes back
    /// the next time this runs for that receipt (a match that pays it, a manual payment link,
    /// a PDF added to it, the one-off tool); giving the link another role makes it the user's,
    /// and the triggers then leave it alone.
    static let receiptLinkSupported = """
        EXISTS (SELECT 1 FROM rentReceiptPayment p
                JOIN documentLink dl ON dl.entityType = 'rentReceipt' AND dl.entityId = p.rentReceiptId
                WHERE p.transactionId = documentLink.entityId AND p.isDismissed = 0 AND p.rentMinorUnits > 0
                  AND dl.documentId = documentLink.documentId)
        """

    // MARK: Payers

    /// Words of bank descriptions and advices that never name a payer: banking and transfer
    /// terms, rent words, bank names, months (Portuguese and English), titles.
    static let payerStopwords: Set<String> = [
        "TRANSFERENCIA", "TRANSFERENCIAS", "TRANSFER", "TRANSF", "RECEBIDA", "RECEBIDO", "EMITIDA", "CREDITO", "DEBITO",
        "ORDEM", "ORDENANTE", "BENEFICIARIO", "PAGAMENTO", "PAYMENT", "REFERENCIA", "REFERENCE", "IMPORTANCIA", "MOVIMENTO",
        "DESPESAS", "SEPA", "INSTANTANEA", "IMEDIATA", "CONTA", "CLIENTE", "BANCO", "BANCARIA", "PORTUGAL", "LISBOA",
        "RENDA", "RENDAS", "ALUGUER", "ARRENDAMENTO", "RENTAL", "CONDOMINIO", "RECIBO", "TENANT", "LANDLORD",
        "BBVA", "BANKINTER", "MILLENNIUM", "SANTANDER", "NOVOBANCO", "ACTIVOBANK", "MONTEPIO", "CAIXA", "REVOLUT", "WISE",
        "JANEIRO", "FEVEREIRO", "MARCO", "ABRIL", "MAIO", "JUNHO", "JULHO", "AGOSTO", "SETEMBRO", "OUTUBRO", "NOVEMBRO",
        "DEZEMBRO", "JANUARY", "FEBRUARY", "MARCH", "APRIL", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER",
        "SENHOR", "SENHORA", "SENHORES", "EXMOS",
    ]

    /// The name words of a bank description: letters only, six or more, stopwords left out
    /// ("0099REF0001 TENANTXYZ" → TENANTXYZ; "0010TRF600… TENANTAB" → TENANTAB), folded and uppercased.
    static func payerWords(_ description: String) -> Set<String> {
        let folded = EvidenceText.fold(description).uppercased()
        let words: [String] = folded.split(whereSeparator: { (c: Character) in !c.isLetter && !c.isNumber }).map(String.init)
        return Set(words.filter { (word: String) in
            word.count >= 6 && word.allSatisfy { $0.isLetter } && !payerStopwords.contains(word)
        })
    }

    /// Banks cut a payer's name to this many letters in a description ("TENANTAB" for "TENANTABC").
    static let truncatedNameLength = 8

    /// Whether two words name the same payer: the same word, or one cut at
    /// `truncatedNameLength` letters and the other starting with it.
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        return short.count == truncatedNameLength && long.hasPrefix(short)
    }

    /// Whether two sets of payer words share a name (`sameWord`).
    static func samePayer(_ a: Set<String>, _ b: Set<String>) -> Bool {
        a.contains { word in b.contains { sameWord(word, $0) } }
    }

    /// The payer words of each tenancy: from the descriptions of the credits that paid its
    /// receipts (active links with rent).
    static func tenancyPayers(db: Database) throws -> [Int64: Set<String>] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT r.tenancyId, t.rawDescription FROM rentReceiptPayment p
            JOIN rentReceipt r ON r.id = p.rentReceiptId JOIN transaction_ t ON t.id = p.transactionId
            WHERE p.isDismissed = 0 AND p.rentMinorUnits > 0
            """)
        var payers: [Int64: Set<String>] = [:]
        for row in rows {
            payers[row[0], default: []].formUnion(payerWords(row[1]))
        }
        return payers
    }

    // MARK: Bank advices

    /// A bank's advice of a transfer received, as read from its text.
    public struct Advice: Equatable, Sendable {
        /// The advice's date (the day the bank credited the account).
        public var date: Date
        /// Every non-zero amount the advice states (the transfer's among them: the layout
        /// scatters labels and values, so which is which isn't read).
        public var amounts: Set<Int>
        /// The text with whitespace removed and uppercased, to look for a statement reference.
        public var compactText: String
    }

    private static let datePattern = try! NSRegularExpression(pattern: #"DATA:\s*(\d{4}-\d{2}-\d{2})"#)
    private static let moneyPattern = try! NSRegularExpression(pattern: #"(?<![\d.,])(\d{1,3}(?:\.\d{3})*,\d{2}|\d+,\d{2})(?![\d,])"#)

    /// Reads a BBVA "TRANSFERÊNCIA RECEBIDA" advice; `nil` for any other text (an advice of a
    /// transfer sent, a statement, a letter).
    public static func parseAdvice(_ text: String) -> Advice? {
        let folded = EvidenceText.fold(text).uppercased()
        guard folded.contains("TRANSFERENCIA RECEBIDA") else { return nil }
        let range = NSRange(folded.startIndex..., in: folded)
        guard let match = datePattern.firstMatch(in: folded, range: range), let dateRange = Range(match.range(at: 1), in: folded),
              let date = RentReceiptPDFs.day(String(folded[dateRange])) else { return nil }
        let amounts = Set(moneyPattern.matches(in: folded, range: range).compactMap { found -> Int? in
            guard let r = Range(found.range(at: 1), in: folded) else { return nil }
            return RentReceiptPDFs.cents(String(folded[r]))
        }.filter { $0 > 0 })
        guard !amounts.isEmpty else { return nil }
        let compact = String(folded.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
        return Advice(date: date, amounts: amounts, compactText: compact)
    }

    /// Where an advice comes from: a library document, or a file to add.
    public enum AdviceSource: Equatable, Sendable {
        case document(Int64)
        case file(URL)
    }

    public struct AdviceInput: Equatable, Sendable {
        public var source: AdviceSource
        /// The file's or document's name, for the report.
        public var name: String
        public var sha256: String
        public var advice: Advice
        /// For a file: its text, kept on the document added.
        public var text: String?
        public var textStatus: DocumentTextStatus

        public init(source: AdviceSource, name: String, sha256: String, advice: Advice, text: String? = nil,
                    textStatus: DocumentTextStatus = .unknown) {
            self.source = source
            self.name = name
            self.sha256 = sha256
            self.advice = advice
            self.text = text
            self.textStatus = textStatus
        }
    }

    /// The received-transfer advices already in the library, oldest first.
    public static func libraryAdvices(db: Database) throws -> [AdviceInput] {
        try libraryAdvices(db: db, cache: AdviceCache())
    }

    /// What `libraryAdvices` read of each document (by id and content), so repeated calls in
    /// one pass (the filed-year guard runs the follow-on matching once per item) read and parse
    /// each document's text once. Not thread-safe: one pass, one connection.
    public final class AdviceCache {
        struct Key: Hashable {
            var id: Int64
            var sha256: String
        }
        private var advices: [Key: Advice?] = [:]
        /// Documents whose text was parsed (tests).
        public private(set) var parses = 0
        /// The bank debit advices read in the same pass (`BBVADebitAdvice.linkLibraryAdvices`).
        public let debitAdvices = BBVADebitAdvice.Cache()

        public init() {}

        /// The document's advice: from the cache, else `text()` parsed (and remembered).
        func advice(_ key: Key, text: () throws -> String?) rethrows -> Advice? {
            if let cached = advices[key] { return cached }
            parses += 1
            let advice = try text().flatMap(RentCreditEvidence.parseAdvice)
            advices[key] = .some(advice)
            return advice
        }
    }

    /// `libraryAdvices`, reading only the text of documents `cache` hasn't seen.
    static func libraryAdvices(db: Database, cache: AdviceCache) throws -> [AdviceInput] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, sha256, COALESCE(canonicalName, originalFileName) AS name FROM document
            WHERE extractedText IS NOT NULL ORDER BY docDate, id
            """)
        return try rows.compactMap { row -> AdviceInput? in
            let key = AdviceCache.Key(id: row["id"], sha256: row["sha256"])
            let found = try cache.advice(key) {
                try String.fetchOne(db, sql: "SELECT extractedText FROM document WHERE id = ?", arguments: [key.id])
            }
            guard let advice = found else { return nil }
            return AdviceInput(source: .document(key.id), name: row["name"], sha256: key.sha256, advice: advice)
        }
    }

    public enum AdviceOutcome: Equatable, Sendable {
        /// Matched a tenant credit: to link.
        case link
        /// Its credit already has it.
        case alreadyLinked
        /// No credit of the property on that date and amount (not imported yet, or another account).
        case noCredit
        /// Matched a credit that isn't from a tenant (an own transfer, a refund): not linked.
        case notRent
        /// More than one credit fits equally: left for review.
        case ambiguous
        /// The same file as another advice (in the library and the folder): handled once.
        case duplicate
        /// A credit fits the date and amount, but neither its statement reference nor its payer's
        /// name is in the advice: not linked.
        case unconfirmed
        /// The advice's document is already linked to another transaction: not linked again.
        case conflict
        /// Another copy of an advice its credit already has (a re-scanned or re-saved file): not linked.
        case copyOfLinked
    }

    public struct AdvicePlanItem: Equatable, Sendable {
        public var input: AdviceInput
        public var outcome: AdviceOutcome
        /// The credit the advice is for: one transaction, or the parts of one transfer the
        /// statement import split (same day and reference, e.g. rent and deposit).
        public var credits: [Transaction] = []
        /// For a `.link` or `.alreadyLinked` file: the library document with the same content, if any.
        public var documentId: Int64?
        public var category: String?
        /// For an `.ambiguous` item: the other credits (each one transfer, split parts together)
        /// the planner weighed equally with `credits`.
        public var alternatives: [[Transaction]] = []
        /// For an `.ambiguous` item made by two advices claiming one credit: the other advice's name.
        public var competingAdvices: [String] = []

        public var credit: Transaction? { credits.first }
        public var amountMinorUnits: Int { credits.reduce(0) { $0 + $1.amountMinorUnits } }
    }

    /// Days before and after the advice's date a credit may be booked.
    public static let adviceDaysBefore = 1
    public static let adviceDaysAfter = 3

    /// Matches each advice to a credit on the property's current accounts: booked between
    /// `adviceDaysBefore` days before and `adviceDaysAfter` after the advice's date, for one of
    /// the amounts it states (or, failing that, the parts of one transfer — same day, same
    /// description — adding up to it); a credit whose statement reference (its description's
    /// first word) appears in the advice wins, then the closest date. A matched credit is linked
    /// only when it's a tenant's: a rent credit (category or payment link), or one whose payer
    /// paid a receipt. One advice per credit.
    public static func planAdvices(db: Database, propertyId: Int64, inputs: [AdviceInput]) throws -> [AdvicePlanItem] {
        let accountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .current).map(\.accountId)
        guard !accountIds.isEmpty else { return inputs.map { AdvicePlanItem(input: $0, outcome: .noCredit) } }
        let credits = try Transaction.filter(accountIds.contains(Column("accountId")) && Column("amountMinorUnits") > 0)
            .order(Column("date"), Column("id")).fetchAll(db)
        let byAmount = Dictionary(grouping: credits, by: \.amountMinorUnits)
        let byDay = Dictionary(grouping: credits, by: { PropertyDates.day($0.date) })
        let rentIds = Set(try RentReceiptMatching.candidateCredits(db: db, propertyId: propertyId).compactMap(\.id))
            .union(try Int64.fetchAll(db, sql: "SELECT transactionId FROM rentReceiptPayment WHERE isDismissed = 0"))
        let payers = try tenancyPayers(db: db).values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let categories = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, name FROM category")
            .map { ($0[0] as Int64, $0[1] as String) })
        let calendar = MonthRange.calendar

        var items: [AdvicePlanItem] = []
        var seenHashes: Set<String> = []
        var claimed: [Int64: Int] = [:] // credit id → item index
        for input in inputs {
            guard seenHashes.insert(input.sha256).inserted else {
                items.append(AdvicePlanItem(input: input, outcome: .duplicate))
                continue
            }
            let day = PropertyDates.day(input.advice.date)
            let days = (-adviceDaysBefore...adviceDaysAfter).map { calendar.date(byAdding: .day, value: $0, to: day)! }
            let from = days.first!, to = days.last!
            var candidates: [[Transaction]] = input.advice.amounts.flatMap { byAmount[$0] ?? [] }.filter {
                let d = PropertyDates.day($0.date)
                return from <= d && d <= to
            }.map { [$0] }
            if candidates.isEmpty {
                // One transfer split into parts by the import (rent and deposit, say).
                for d in days {
                    for (_, parts) in Dictionary(grouping: byDay[d] ?? [], by: \.rawDescription) where parts.count > 1 {
                        if input.advice.amounts.contains(parts.reduce(0) { $0 + $1.amountMinorUnits }) { candidates.append(parts) }
                    }
                }
            }
            func referenced(_ credit: Transaction) -> Bool {
                guard let first = credit.rawDescription.split(separator: " ").first, first.count >= 6 else { return false }
                return input.advice.compactText.contains(EvidenceText.fold(String(first)).uppercased())
            }
            /// The advice names the credit: its reference, or its payer's name.
            func confirmed(_ parts: [Transaction]) -> Bool {
                parts.contains { part in
                    referenced(part) || payerWords(part.rawDescription).contains { input.advice.compactText.contains($0) }
                }
            }
            func distance(_ credit: Transaction) -> Int {
                abs(calendar.dateComponents([.day], from: day, to: PropertyDates.day(credit.date)).day ?? 0)
            }
            func ordered(_ credits: [Transaction]) -> [Transaction] {
                // The rent part first (it names the category).
                credits.sorted { (rentIds.contains($0.id!) ? 0 : 1, $0.id!) < (rentIds.contains($1.id!) ? 0 : 1, $1.id!) }
            }
            guard !candidates.isEmpty else {
                items.append(AdvicePlanItem(input: input, outcome: .noCredit))
                continue
            }
            let ranked = candidates.filter(confirmed)
                .map { (credits: $0, key: (referenced($0[0]) ? 0 : 1, distance($0[0]))) }.sorted { $0.key < $1.key }
            guard let best = ranked.first else {
                let closest = candidates.min { distance($0[0]) < distance($1[0]) }!
                items.append(AdvicePlanItem(input: input, outcome: .unconfirmed, credits: ordered(closest),
                                            category: closest[0].categoryId.flatMap { categories[$0] }))
                continue
            }
            let parts = ordered(best.credits)
            let partIds = Set(parts.map { $0.id! })
            var item = AdvicePlanItem(input: input, outcome: .link, credits: parts,
                                      category: parts[0].categoryId.flatMap { categories[$0] })
            if ranked.count > 1 && ranked[1].key == best.key {
                item.outcome = .ambiguous
                item.alternatives = ranked.dropFirst().filter { $0.key == best.key }.map { ordered($0.credits) }
                items.append(item)
                continue
            }
            let isTenant = parts.contains { rentIds.contains($0.id!) || samePayer(payerWords($0.rawDescription), payers) }
            if !isTenant {
                item.outcome = .notRent
                items.append(item)
                continue
            }
            let documentId: Int64? = switch input.source {
            case .document(let id): id
            case .file: try Int64.fetchOne(db, sql: "SELECT id FROM document WHERE sha256 = ?", arguments: [input.sha256])
            }
            item.documentId = documentId
            if let documentId {
                let linkedTo = Set(try Int64.fetchAll(db, sql: "SELECT entityId FROM documentLink WHERE documentId = ? AND entityType = ?",
                                                      arguments: [documentId, EvidenceEntityType.transaction.rawValue]))
                if !linkedTo.subtracting(partIds).isEmpty {
                    item.outcome = .conflict
                    items.append(item)
                    continue
                }
                if partIds.isSubset(of: linkedTo) { item.outcome = .alreadyLinked }
            }
            if item.outcome == .link {
                // The credit already has another advice: this is a copy of it.
                let others = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM documentLink WHERE entityType = ? AND role = ? AND documentId != ?
                      AND entityId IN (\(parts.map { _ in "?" }.joined(separator: ",")))
                    """, arguments: StatementArguments([EvidenceEntityType.transaction.rawValue, adviceRole, documentId ?? -1] as [any DatabaseValueConvertible])
                        + StatementArguments(parts.map { $0.id! })) ?? 0
                if others > 0 {
                    item.outcome = .copyOfLinked
                    items.append(item)
                    continue
                }
            }
            if let other = parts.lazy.compactMap({ claimed[$0.id!] }).first {
                if items[other].outcome == .alreadyLinked {
                    // A re-scanned copy of an advice already linked.
                    item.outcome = .copyOfLinked
                } else if item.outcome == .alreadyLinked {
                    items[other].outcome = .copyOfLinked
                } else {
                    // Two new advices for one credit: neither is linked.
                    items[other].outcome = .ambiguous
                    item.outcome = .ambiguous
                    items[other].competingAdvices.append(item.input.name)
                    item.competingAdvices.append(items[other].input.name)
                }
                items.append(item)
                continue
            }
            for part in parts { claimed[part.id!] = items.count }
            items.append(item)
        }
        return items
    }

    public struct AdviceApplied: Equatable, Sendable {
        /// Files added to the library.
        public var added = 0
        /// Advices linked to their credit.
        public var linked = 0
        /// Documents whose missing amount (or a zero) was set to the credit's.
        public var amountsSet = 0
        /// Stored copies placed in the library (remove them if the transaction rolls back).
        public var placedFiles: [URL] = []
    }

    /// Links the advice document to each part of its credit (role `adviceRole`) and gives it
    /// the credit's amount when it has none (or zero); returns 1 when the amount was set.
    static func linkAdvice(db: Database, documentId: Int64, credits: [Transaction]) throws -> Int {
        for part in credits {
            guard let creditId = part.id else { throw ImportEffectsError.incompleteEffect("Transfer advice credit not saved") }
            try EvidenceLinks.link(db: db, documentId: documentId, to: .transaction(creditId), role: adviceRole)
        }
        try db.execute(sql: "UPDATE document SET amountMinorUnits = ? WHERE id = ? AND (amountMinorUnits IS NULL OR amountMinorUnits = 0)",
                       arguments: [credits.reduce(0) { $0 + $1.amountMinorUnits }, documentId])
        return db.changesCount
    }

    /// Links the plan's `.link` advices that are library documents to their credits (files not
    /// yet in the library are `applyAdvices`'s); returns how many were linked.
    static func linkLibraryAdvices(db: Database, plan: [AdvicePlanItem]) throws -> Int {
        var linked = 0
        for item in plan where item.outcome == .link && !item.credits.isEmpty {
            guard case .document(let documentId) = item.input.source else { continue }
            _ = try linkAdvice(db: db, documentId: documentId, credits: item.credits)
            linked += 1
        }
        return linked
    }

    /// Adds (files not yet in the library) and links the plan's `.link` advices to their
    /// credits, inside the caller's transaction. A file is added as a bank transfer proof under
    /// the source folder holding it (when there is one), noted on that folder's scan record.
    public static func applyAdvices(db: Database, plan: [AdvicePlanItem], library: EvidenceLibrary, now: Date = Date()) throws -> AdviceApplied {
        var applied = AdviceApplied()
        let folders = try SourceFolder.fetchAll(db)
        do {
            for item in plan where item.outcome == .link {
                guard !item.credits.isEmpty else { continue }
                let amount = item.amountMinorUnits
                var documentId = item.documentId
                if documentId == nil, case .file(let url) = item.input.source {
                    var metadata = EvidenceMetadata(kind: .bankTransferProof, docDate: item.input.advice.date,
                                                    amountMinorUnits: amount, currency: .eur,
                                                    canonicalName: EvidenceNaming.canonicalName(
                                                        date: item.input.advice.date, area: "Rent", type: "Received",
                                                        detail: "bank credit advice", amountMinorUnits: amount,
                                                        currency: .eur),
                                                    textStatus: item.input.textStatus, extractedText: item.input.text)
                    // The deepest source folder holding the file, symbolic links resolved.
                    let path = TaxRegression.resolvedPath(url.path)
                    let folder = folders.map { (folder: $0, root: TaxRegression.resolvedPath($0.path)) }
                        .filter { path.hasPrefix($0.root + "/") }
                        .max { $0.root.count < $1.root.count }
                    if let folder {
                        metadata.sourceFolderId = folder.folder.id
                        metadata.sourceRelativePath = String(path.dropFirst(folder.root.count + 1))
                        metadata.sourceModifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    }
                    let staged = try library.add(db: db, url, metadata: metadata, analysis: nil, now: now)
                    if let placed = staged.placedFile { applied.placedFiles.append(placed) }
                    documentId = staged.result.document.id
                    if staged.result.isNew { applied.added += 1 }
                    if let folder, let documentId {
                        try db.execute(sql: "UPDATE sourceFile SET documentId = ? WHERE folderId = ? AND sha256 = ? AND documentId IS NULL",
                                       arguments: [documentId, folder.folder.id, item.input.sha256])
                    }
                }
                guard let documentId else { continue }
                applied.amountsSet += try linkAdvice(db: db, documentId: documentId, credits: item.credits)
                applied.linked += 1
            }
        } catch {
            for url in applied.placedFiles { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return applied
    }
}

// MARK: One-off run

extension RentCreditEvidence {
    /// What `run` did, per property, for the report.
    public struct RunResult: Equatable, Sendable {
        public struct PropertyResult: Equatable, Sendable {
            public var propertyName: String
            /// Active payment links before the run.
            public var linksBefore: Int
            public var matching: RentReceiptMatching.Result
            /// Receipt PDFs linked to credits (the matching's and the earlier links').
            public var receiptDocuments: [ReceiptDocumentLink]
            public var advices: [AdvicePlanItem]
            public var applied: AdviceApplied
        }
        public var properties: [PropertyResult] = []
        /// Folder PDFs that aren't received-transfer advices.
        public var otherFiles = 0
    }

    /// Links, inside the caller's transaction, for every property with tenancies: unpaid
    /// receipts to their credits (`RentReceiptMatching.match`, the date pass included), every
    /// receipt PDF to the credits that paid it, and the received-transfer advices (the
    /// library's, then `files` not yet in it) to their credits. Idempotent.
    public static func run(db: Database, library: EvidenceLibrary, files: [AdviceInput], otherFiles: Int = 0,
                           options: RentReceiptMatching.Options = .init(), now: Date = Date()) throws -> RunResult {
        var result = RunResult(otherFiles: otherFiles)
        let propertyIds = try Int64.fetchAll(db, sql: "SELECT DISTINCT propertyId FROM tenancy ORDER BY propertyId")
        var pending = try libraryAdvices(db: db) + files
        var placed: [URL] = []
        do {
            for propertyId in propertyIds {
                guard let property = try Property.fetchOne(db, key: propertyId) else { continue }
                let before = try RentReceiptPayment.active.fetchCount(db)
                let matching = try RentReceiptMatching.match(db: db, propertyId: propertyId, options: options)
                let documents = matching.receiptDocumentLinks + (try linkReceiptDocuments(db: db))
                let plan = try planAdvices(db: db, propertyId: propertyId, inputs: pending)
                let applied = try applyAdvices(db: db, plan: plan, library: library, now: now)
                placed += applied.placedFiles
                let done = Set(plan.filter { $0.outcome == .link || $0.outcome == .alreadyLinked }.map(\.input.sha256))
                pending.removeAll { done.contains($0.sha256) }
                result.properties.append(.init(propertyName: property.name, linksBefore: before, matching: matching,
                                               receiptDocuments: documents, advices: plan, applied: applied))
            }
        } catch {
            for url in placed { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return result
    }

    /// The run's report: links by amount and by date, receipts without a credit, credits
    /// without a receipt, receipt PDFs linked, advices linked and not.
    public static func report(db: Database, _ result: RunResult) throws -> String {
        let receipts = Dictionary(uniqueKeysWithValues: try RentReceipt.fetchAll(db).map { ($0.id!, $0) })
        let tenancies = Dictionary(uniqueKeysWithValues: try Tenancy.fetchAll(db).map { ($0.id!, $0) })
        var transactions: [Int64: Transaction] = [:]
        func credit(_ id: Int64) throws -> Transaction? {
            if let t = transactions[id] { return t }
            let t = try Transaction.fetchOne(db, key: id)
            transactions[id] = t
            return t
        }
        func day(_ date: Date?) -> String { RentReceiptPDFs.dayText(date) }
        func money(_ minor: Int) -> String { RentReceiptPDFs.moneyText(minor) }
        func receiptText(_ receipt: RentReceipt) -> String {
            "\(tenancies[receipt.tenancyId]?.referenceLabel ?? "?") receipt \(receipt.receiptNumber) "
                + "(\(day(receipt.periodStart)) – \(day(receipt.periodEnd)), \(money(receipt.amountReceivedMinorUnits)), received \(day(receipt.receiptDate)))"
        }
        func creditText(_ t: Transaction) -> String { "\(day(t.date)) “\(t.rawDescription)” \(money(t.amountMinorUnits))" }

        var out = ""
        for property in result.properties {
            let m = property.matching
            let datedIds = Set(m.byDate.compactMap(\.id))
            let byAmount = m.created.filter { !datedIds.contains($0.id!) }
            out += "== \(property.propertyName) ==\n"
            out += "Payment links before: \(property.linksBefore) (all made by amount or by hand before this tool)\n"
            out += "Receipts linked now by amount: \(Set(byAmount.map(\.rentReceiptId)).count) (\(byAmount.count) link(s))\n"
            out += "Receipts linked now by date (the credit's amount ≠ rent + allowed recharges): \(Set(m.byDate.map(\.rentReceiptId)).count)\n"
            for link in m.created.sorted(by: { ($0.rentReceiptId, $0.transactionId) < ($1.rentReceiptId, $1.transactionId) }) {
                guard let receipt = receipts[link.rentReceiptId], let t = try credit(link.transactionId) else { continue }
                out += "  [\(datedIds.contains(link.id!) ? "date" : "amount")] \(receiptText(receipt)) ← \(creditText(t)): rent \(money(link.rentMinorUnits))"
                    + (link.otherMinorUnits > 0 ? " + other \(money(link.otherMinorUnits))" : "") + "\n"
            }
            out += "\nReceipts without a (full) credit: \(m.unmatchedReceipts.count)\n"
            for receipt in m.unmatchedReceipts { out += "  \(receiptText(receipt))\n" }
            out += "\nRent credits without a receipt: \(m.unmatchedCredits.count)\n"
            for t in m.unmatchedCredits { out += "  \(creditText(t))\n" }

            out += "\nReceipt PDFs linked to their credits: \(property.receiptDocuments.count)\n"
            for link in property.receiptDocuments {
                guard let receipt = receipts[link.rentReceiptId], let t = try credit(link.transactionId) else { continue }
                let name = try String.fetchOne(db, sql: "SELECT COALESCE(canonicalName, originalFileName) FROM document WHERE id = ?",
                                               arguments: [link.documentId]) ?? "?"
                out += "  \(name) → \(creditText(t)) [\(tenancies[receipt.tenancyId]?.referenceLabel ?? "?") \(receipt.receiptNumber)]\n"
            }

            let advices = property.advices
            func count(_ o: AdviceOutcome) -> Int { advices.filter { $0.outcome == o }.count }
            out += "\nBBVA received-transfer advices found: \(advices.count) "
                + "(library \(advices.filter { if case .document = $0.input.source { true } else { false } }.count), "
                + "folders \(advices.filter { if case .file = $0.input.source { true } else { false } }.count))\n"
            out += "  linked now: \(property.applied.linked) (added to the library: \(property.applied.added), amounts set: \(property.applied.amountsSet))\n"
            out += "  already linked: \(count(.alreadyLinked)); no credit in the app: \(count(.noCredit)); not a tenant credit: \(count(.notRent)); "
                + "ambiguous: \(count(.ambiguous)); unconfirmed: \(count(.unconfirmed)); linked elsewhere: \(count(.conflict)); "
                + "copies of a linked advice: \(count(.copyOfLinked)); duplicate files: \(count(.duplicate))\n"
            if result.otherFiles > 0 { out += "  folder PDFs that aren't received-transfer advices (ignored): \(result.otherFiles)\n" }
            for outcome in [AdviceOutcome.link, .alreadyLinked, .noCredit, .notRent, .ambiguous, .unconfirmed, .conflict, .copyOfLinked,
                            .duplicate] {
                let items = advices.filter { $0.outcome == outcome }
                guard !items.isEmpty else { continue }
                out += "  -- \(adviceLabel(outcome)) --\n"
                for item in items.sorted(by: { ($0.input.advice.date, $0.input.name) < ($1.input.advice.date, $1.input.name) }) {
                    let amounts = item.input.advice.amounts.sorted(by: >).prefix(3).map(money).joined(separator: ", ")
                    out += "  \(day(item.input.advice.date)) \(item.input.name)"
                    if !item.credits.isEmpty {
                        out += " → " + item.credits.map(creditText).joined(separator: " + ") + (item.category.map { " [\($0)]" } ?? "")
                    } else {
                        out += " (amounts \(amounts))"
                    }
                    out += "\n"
                }
            }
            out += "\n"
        }
        return out
    }

    static func adviceLabel(_ outcome: AdviceOutcome) -> String {
        switch outcome {
        case .link: "linked"
        case .alreadyLinked: "already linked"
        case .noCredit: "no credit in the app (date ±, amount)"
        case .notRent: "matched a credit that isn't a tenant's (not linked)"
        case .ambiguous: "ambiguous (not linked)"
        case .duplicate: "same file as a library advice (handled once)"
        case .unconfirmed: "date and amount fit, but the advice names neither the reference nor the payer (not linked)"
        case .conflict: "already linked to another transaction (not linked again)"
        case .copyOfLinked: "another copy of an advice its credit already has (not linked)"
        }
    }
}

/// The triggers that keep the receipt PDFs on credits in step (see `RentCreditEvidence.receiptLinkSupported`).
func registerRentCreditEvidenceMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("rentCreditEvidenceTriggers") { db in
        let role = RentCreditEvidence.receiptRole.replacingOccurrences(of: "'", with: "''")
        let supported = RentCreditEvidence.receiptLinkSupported
        func prune(_ scope: String) -> String {
            "DELETE FROM documentLink WHERE entityType = 'transaction' AND role = '\(role)' AND \(scope) AND NOT \(supported);"
        }
        try db.execute(sql: """
            CREATE TRIGGER rentReceiptPayment_delete_receiptDocuments AFTER DELETE ON rentReceiptPayment
            BEGIN \(prune("entityId = OLD.transactionId")) END;
            CREATE TRIGGER rentReceiptPayment_update_receiptDocuments AFTER UPDATE OF isDismissed, rentMinorUnits ON rentReceiptPayment
            BEGIN \(prune("entityId = OLD.transactionId")) END;
            CREATE TRIGGER documentLink_delete_receiptDocuments AFTER DELETE ON documentLink WHEN OLD.entityType = 'rentReceipt'
            BEGIN \(prune("documentId = OLD.documentId")) END;
            """)
    }
}
