import GRDB
import Foundation

/// What makes two files the same document, whatever their bytes.
///
/// Strong identities — `"atcud:<code>"`, `"invoice:<providerId>:<number>"`,
/// `"receipt:<contract>:<number>"`, `"payroll:<form>:<taxYear>:<employer>:<personId>"` — make a
/// copy of the same kind (role) a duplicate. Weak keys — `"ref:<payment reference>"` (9+ digits)
/// and `"ida:<role>:<issuer>:<yyyyMMdd>:<amount minor>"` (kind + issuer + date + amount) — only
/// ever ask the user.
public enum DocumentIdentity {
    /// A money figure a document holds.
    struct Figure: Equatable {
        /// Sign-free.
        var amount: Int
        var currency: Currency?
    }

    /// A document's identity: its keys and the figures that corroborate or veto a weak match.
    struct Identity {
        /// Full strong keys ("atcud:…").
        var strong: Set<String> = []
        /// Full weak keys ("ref:…", "ida:…").
        var weak: Set<String> = []
        /// The kind-based `ida:` key (matches only where one side names no issuer).
        var kindKey: String?
        /// The kind it is filed as: `"<DocumentKind.rawValue>"` for a built-in kind.
        var kindToken: String?
        /// The part it plays (`ImportDuplicates.claimRole`): what "the same kind" compares.
        var role: String?
        var day: String?
        /// The period it covers ("yyyyMMdd"…"yyyyMMdd"), when it states one.
        var period: ClosedRange<String>?
        /// The issuer as written (for the wording).
        var issuerName: String?
        /// The currency of its amount, when known (for the wording).
        var currency: Currency?
        /// Sign-free.
        var amount: Int?
        /// Normalised.
        var issuer: String?
        /// The money figures it holds (sign-free; currency nil when unknown): what a strong match
        /// is checked against, so a corrected version (another amount, pay or tax) isn't taken
        /// for a copy. A library document's own figures come first, then its record's.
        var figures: [ImportFigureField: Figure] = [:]

        var keys: Set<String> { strong.union(weak) }

        /// The values of each strong identity type ("atcud" → codes).
        var strongByType: [String: Set<String>] {
            Dictionary(grouping: strong, by: { String($0.prefix { $0 != ":" }) }).mapValues(Set.init)
        }

        mutating func merge(_ other: Identity) {
            strong.formUnion(other.strong)
            weak.formUnion(other.weak)
            kindKey = kindKey ?? other.kindKey
            kindToken = kindToken ?? other.kindToken
            role = role ?? other.role
            day = day ?? other.day
            period = period ?? other.period
            amount = amount ?? other.amount
            issuer = issuer ?? other.issuer
            issuerName = issuerName ?? other.issuerName
            currency = currency ?? other.currency
            figures.merge(other.figures) { own, _ in own }
        }
    }

    /// Every key of the document: the strong ones, `"ref:…"`, and `"ida:…"` twice — by role and
    /// issuer with the amount's sign (a credit note is not the invoice) when an issuer fact
    /// exists, and by role alone, sign-free (library documents store amounts sign-free).
    /// Statements (checked by their transactions), receipts exports, unknown files and `.other`
    /// documents have none.
    public static func keys(kind: ImportKind, text: String?, facts: [ImportFact], providerId: Int64?, personId: Int64? = nil) -> Set<String> {
        identity(kind: kind, text: text, facts: facts, providerId: providerId, personId: personId).keys
    }

    static func identity(kind: ImportKind, text: String?, facts: [ImportFact], providerId: Int64?, personId: Int64?) -> Identity {
        var identity = Identity()
        guard let token = kindToken(of: kind), token != DocumentKind.bankStatement.rawValue, token != DocumentKind.other.rawValue else { return identity }
        let role = ImportDuplicates.claimRole(token: token, text: text)
        identity.kindToken = token
        identity.role = role
        if let text, !text.isEmpty {
            let source = text as NSString
            for match in atcudPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                identity.strong.insert("atcud:\(source.substring(with: match.range(at: 1)).uppercased())")
            }
            for reference in EvidenceMatcher.paymentReferences(in: text) { identity.weak.insert("ref:\(reference)") }
        }
        if let providerId, let number = textFact(.invoiceNumber, facts).map(compact), !number.isEmpty {
            identity.strong.insert("invoice:\(providerId):\(number)")
        }
        if let contract = textFact(.reference, facts).map(compact), let number = textFact(.receiptNumber, facts).map(compact),
           !contract.isEmpty, !number.isEmpty {
            identity.strong.insert("receipt:\(contract):\(number)")
        }
        identity.issuer = textFact(.issuer, facts).map(normalisedIssuer).flatMap { $0.isEmpty ? nil : $0 }
        if identity.issuer != nil { identity.issuerName = textFact(.issuer, facts) }
        if case .payrollForm(let form) = kind, let personId, let employer = identity.issuer, let year = yearFact(facts) {
            identity.strong.insert(payrollKey(form: form.rawValue, year: year, employer: employer, personId: personId))
        }
        identity.day = dateFact(facts).map(dayKey)
        identity.period = period(facts)
        let signed = signedAmountFact(facts)
        identity.amount = signed.map(abs)
        identity.currency = moneyFact(.amount, facts)?.currency
        for field in DocumentIdentity.comparedFigures {
            if let value = moneyFact(field, facts) { identity.figures[field] = Figure(amount: abs(value.amount), currency: value.currency) }
        }
        if let day = identity.day, let signed {
            if let issuer = identity.issuer { identity.weak.insert("ida:\(role):\(issuer):\(day):\(signed)") }
            let kindKey = "ida:\(role):\(day):\(abs(signed))"
            identity.weak.insert(kindKey)
            identity.kindKey = kindKey
        }
        return identity
    }

    static func payrollKey(form: String, year: Int, employer: String, personId: Int64) -> String {
        "payroll:\(form):\(year):\(employer):\(personId)"
    }

    /// The kind token of a recognised file (`"<DocumentKind.rawValue>"`); `nil` for receipts
    /// exports and unknown files.
    static func kindToken(of kind: ImportKind) -> String? {
        documentKind(of: kind)?.rawValue
    }

    /// The period the facts state ("yyyyMMdd"…"yyyyMMdd"): start and end, either alone a single day.
    static func period(_ facts: [ImportFact]) -> ClosedRange<String>? {
        func date(_ field: ImportFigureField) -> String? {
            for fact in facts where fact.field == field {
                if case .date(let date) = fact.value { return dayKey(date) }
            }
            return nil
        }
        switch (date(.periodStart), date(.periodEnd)) {
        case let (start?, end?): return min(start, end)...max(start, end)
        case let (start?, nil): return start...start
        case let (nil, end?): return end...end
        default: return nil
        }
    }

    /// "2023-03-05" for "20230305".
    static func isoDay(fromKey key: String) -> String {
        guard key.count == 8 else { return key }
        let chars = Array(key)
        return "\(String(chars[0..<4]))-\(String(chars[4..<6]))-\(String(chars[6..<8]))"
    }

    /// The library kind a recognised file is filed as; `nil` for receipts exports and unknown files.
    static func documentKind(of kind: ImportKind) -> DocumentKind? {
        switch kind {
        case .rentReceiptPDF: return .rentReceipt
        case .transferAdvice: return .bankTransferProof
        case .utilityInvoice: return .utilityInvoice
        case .payrollForm(let form): return form.documentKind
        case .bankStatementCSV, .bankStatementPDF, .bbvaStatement: return .bankStatement
        case .evidence(let documentKind): return documentKind
        case .rentReceiptsExport, .unknown: return nil
        }
    }

    /// "20230305".
    static func dayKey(_ date: Date) -> String {
        PropertyDates.isoDay(date).replacingOccurrences(of: "-", with: "")
    }

    static func dateFact(_ facts: [ImportFact]) -> Date? {
        for fact in facts where fact.field == .docDate {
            if case .date(let date) = fact.value { return date }
        }
        return nil
    }

    static func signedAmountFact(_ facts: [ImportFact]) -> Int? {
        for fact in facts where fact.field == .amount {
            if case .money(let amount, _) = fact.value { return amount }
        }
        return nil
    }

    /// Whether `text` prints `number` as a whole number ("FT 1/23" in "Invoice FT 1/23,", not
    /// in "FT 1/234"), its spaces optional, any case.
    static func prints(_ number: String, in text: String) -> Bool {
        let parts = number.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty,
              let pattern = try? NSRegularExpression(pattern: "(?<![A-Z0-9/])" + parts.joined(separator: #"\s*"#) + "(?![A-Z0-9/])",
                                                     options: [.caseInsensitive]) else { return false }
        return pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// The money figures a strong match is checked against.
    static let comparedFigures: [ImportFigureField] = [.amount, .pay, .taxDeducted]

    static func moneyFact(_ field: ImportFigureField, _ facts: [ImportFact]) -> (amount: Int, currency: Currency)? {
        for fact in facts where fact.field == field {
            if case .money(let amount, let currency) = fact.value { return (amount, currency) }
        }
        return nil
    }

    static func yearFact(_ facts: [ImportFact]) -> Int? {
        for fact in facts where fact.field == .taxYear {
            if case .year(let year) = fact.value { return year }
        }
        return nil
    }

    /// Folded, lower case, letters and digits only ("Démo Power" → "demopower").
    static func normalisedIssuer(_ name: String) -> String {
        String(EvidenceText.fold(name).lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// Upper case, no whitespace ("ft 1/23" → "FT1/23").
    static func compact(_ text: String) -> String {
        String(text.uppercased().filter { !$0.isWhitespace })
    }

    static func textFact(_ field: ImportFigureField, _ facts: [ImportFact]) -> String? {
        for fact in facts where fact.field == field {
            if case .text(let text) = fact.value { return text }
        }
        return nil
    }

    private static let atcudPattern = try! NSRegularExpression(pattern: #"(?i:ATCUD)\s*:?\s*([A-Z0-9]{8,}-\d+)"#)
}

/// Documents by identity key: the library's (from their text, kind, date and amount, and the
/// invoices, rent receipts and payroll forms recorded with them), built once per plan, or the
/// earlier items of a batch.
public struct DocumentIdentityIndex {
    struct Entry {
        var documentId: Int64?
        var label: String
        var identity: DocumentIdentity.Identity
        /// The batch item it is (not for the library's documents).
        var itemId: UUID? = nil
    }

    enum Match {
        /// A strong identity: the same document.
        case same(Entry)
        /// Only a weak key: possibly the same document.
        case possible(Entry)
    }

    private var entries: [String: [Entry]] = [:]
    /// Payment references printed by more than one document: they identify none.
    private var sharedReferences: Set<String> = []
    /// Library documents by hash: id and display name.
    private(set) var byHash: [String: (documentId: Int64, label: String)] = [:]

    init() {}

    public static func load(db: Database) throws -> DocumentIdentityIndex {
        var index = DocumentIdentityIndex()
        var documents: [Int64: Entry] = [:]
        var order: [Int64] = []
        for document in try EvidenceDocument.fetchAll(db) {
            guard let id = document.id else { continue }
            index.byHash[document.sha256] = (id, document.displayName)
            var facts: [ImportFact] = []
            if let date = document.docDate {
                facts.append(ImportFact(field: .docDate, value: .date(date), source: .matchedRecord, confidence: .certain, reason: ""))
            }
            if let amount = document.amountMinorUnits {
                facts.append(ImportFact(field: .amount, value: .money(amount, document.currency ?? .eur), source: .matchedRecord,
                                        confidence: .certain, reason: ""))
            }
            for (field, date) in [(ImportFigureField.periodStart, document.periodStart), (.periodEnd, document.periodEnd)] {
                if let date { facts.append(ImportFact(field: field, value: .date(date), source: .matchedRecord, confidence: .certain, reason: "")) }
            }
            var identity = DocumentIdentity.identity(kind: .evidence(document.kind), text: document.extractedText, facts: facts,
                                                     providerId: nil, personId: nil)
            // The amount as the document states it (its currency unknown when it has none).
            identity.figures[.amount] = document.amountMinorUnits.map { DocumentIdentity.Figure(amount: abs($0), currency: document.currency) }
            identity.currency = document.currency
            documents[id] = Entry(documentId: id, label: document.displayName, identity: identity)
            order.append(id)
        }
        func enrich(_ documentId: Int64, _ change: (inout DocumentIdentity.Identity) -> Void) {
            guard documents[documentId] != nil else { return }
            change(&documents[documentId]!.identity)
        }
        // Recorded utility invoices: number per provider, provider + date + signed amount.
        let providers = Dictionary(uniqueKeysWithValues: try UtilityProvider.fetchAll(db).compactMap { provider in
            provider.id.map { ($0, (key: DocumentIdentity.normalisedIssuer(provider.name), name: provider.name)) }
        })
        for invoice in try UtilityInvoice.filter(Column("documentId") != nil).fetchAll(db) {
            guard let documentId = invoice.documentId else { continue }
            enrich(documentId) { identity in
                if let number = invoice.invoiceNumber.map(DocumentIdentity.compact), !number.isEmpty {
                    identity.strong.insert("invoice:\(invoice.providerId):\(number)")
                }
                let day = DocumentIdentity.dayKey(invoice.issueDate)
                if let provider = providers[invoice.providerId], !provider.key.isEmpty {
                    let role = identity.role ?? DocumentKind.utilityInvoice.rawValue
                    identity.issuer = provider.key
                    identity.issuerName = provider.name
                    identity.weak.insert("ida:\(role):\(provider.key):\(day):\(invoice.amountMinorUnits)")
                }
                identity.day = identity.day ?? day
                identity.amount = identity.amount ?? abs(invoice.amountMinorUnits)
                identity.figures[.amount] = identity.figures[.amount] ?? DocumentIdentity.Figure(amount: abs(invoice.amountMinorUnits), currency: nil)
            }
        }
        // A corrected version of a recorded invoice filed as a document only: an invoice
        // document linked to the invoice's debit (or a debit paying it in parts) that prints its number (as a whole number) is
        // that invoice too (with its own figures), so a copy of it is a copy. Never another
        // recorded invoice's own document, nor a credit note.
        for row in try Row.fetchAll(db, sql: """
            WITH paid(invoiceId, transactionId) AS (
                SELECT id, transactionId FROM utilityInvoice WHERE transactionId IS NOT NULL
                UNION SELECT i.id, pay.entityId FROM utilityInvoice i
                JOIN documentLink pay ON pay.documentId = i.documentId AND pay.entityType = ?
                JOIN transaction_ t ON t.id = pay.entityId AND t.amountMinorUnits < 0
                WHERE i.transactionId IS NULL)
            SELECT DISTINCT dl.documentId, i.providerId, i.invoiceNumber, d.extractedText FROM utilityInvoice i
            JOIN paid p ON p.invoiceId = i.id
            JOIN documentLink dl ON dl.entityType = ? AND dl.entityId = p.transactionId
            JOIN document d ON d.id = dl.documentId
            WHERE i.invoiceNumber IS NOT NULL AND i.amountMinorUnits >= 0 AND d.kind = ?
              AND dl.documentId NOT IN (SELECT documentId FROM utilityInvoice WHERE documentId IS NOT NULL)
            """, arguments: [EvidenceEntityType.transaction.rawValue, EvidenceEntityType.transaction.rawValue,
                             DocumentKind.utilityInvoice.rawValue]) {
            let number: String = row[2], providerId: Int64 = row[1]
            let text: String? = row[3]
            guard let text, DocumentIdentity.prints(number, in: text) else { continue }
            enrich(row[0]) { $0.strong.insert("invoice:\(providerId):\(DocumentIdentity.compact(number))") }
        }
        // Rent receipts with a linked document: receipt number per contract.
        for row in try Row.fetchAll(db, sql: """
            SELECT dl.documentId, t.contractNumber, r.receiptNumber, r.amountMinorUnits FROM documentLink dl
            JOIN rentReceipt r ON r.id = dl.entityId JOIN tenancy t ON t.id = r.tenancyId
            WHERE dl.entityType = ? AND t.contractNumber IS NOT NULL
            """, arguments: [EvidenceEntityType.rentReceipt.rawValue]) {
            let contract = DocumentIdentity.compact(row[1]), number = DocumentIdentity.compact(row[2])
            let amount: Int? = row[3]
            enrich(row[0]) { identity in
                identity.strong.insert("receipt:\(contract):\(number)")
                if let amount { identity.figures[.amount] = identity.figures[.amount] ?? DocumentIdentity.Figure(amount: abs(amount), currency: nil) }
            }
        }
        // Payroll forms linked to the pay-and-tax row or the employment they gave (`PayrollFormImport.apply`).
        let forms = [DocumentKind.p60, .p45, .p11d].map(\.rawValue)
        for row in try Row.fetchAll(db, sql: """
            SELECT dl.documentId, d.kind, e.startYear, e.employerName, e.personId, i.payMinorUnits, i.taxDeductedMinorUnits FROM documentLink dl
            JOIN document d ON d.id = dl.documentId
            JOIN employmentIncome i ON i.id = dl.entityId JOIN employment e ON e.id = i.employmentId
            WHERE dl.entityType = ? AND d.kind IN (?, ?, ?)
            UNION ALL
            SELECT dl.documentId, d.kind, e.startYear, e.employerName, e.personId, NULL, NULL FROM documentLink dl
            JOIN document d ON d.id = dl.documentId JOIN employment e ON e.id = dl.entityId
            WHERE dl.entityType = ? AND d.kind IN (?, ?, ?)
            """, arguments: StatementArguments([EvidenceEntityType.employmentIncome.rawValue] + forms + [EvidenceEntityType.employment.rawValue] + forms)) {
            let employer = DocumentIdentity.normalisedIssuer(row[3])
            guard !employer.isEmpty else { continue }
            let key = DocumentIdentity.payrollKey(form: row[1], year: row[2], employer: employer, personId: row[4])
            let pay: Int? = row[5], tax: Int? = row[6]
            let employerName: String = row[3]
            enrich(row[0]) { identity in
                identity.strong.insert(key)
                if identity.issuer == nil { identity.issuerName = employerName }
                identity.issuer = identity.issuer ?? employer
                // The stored pay and tax of the employment the form gave.
                if let pay { identity.figures[.pay] = DocumentIdentity.Figure(amount: abs(pay), currency: .gbp) }
                if let tax { identity.figures[.taxDeducted] = DocumentIdentity.Figure(amount: abs(tax), currency: .gbp) }
            }
        }
        for id in order { if let entry = documents[id] { index.add(entry) } }
        return index
    }

    /// Adds `entry` under each of its keys; a payment reference a second document prints
    /// identifies neither from then on.
    mutating func add(_ entry: Entry) {
        for key in entry.identity.keys {
            if key.hasPrefix("ref:"), let held = entries[key], held.contains(where: { $0.label != entry.label || $0.documentId != entry.documentId }) {
                sharedReferences.insert(key)
            }
            entries[key, default: []].append(entry)
        }
    }

    /// The document `identity` is: one sharing a strong identity, else one sharing a weak key
    /// that nothing vetoes. Internal (not the brief's public `match(_ keys:)`): a weak key can
    /// only be judged with the item's figures and strong identities.
    func match(_ identity: DocumentIdentity.Identity) -> Match? {
        sameDocument(identity).map(Match.same) ?? possibleDocument(identity).map(Match.possible)
    }

    /// The entry of the same role sharing a strong identity with `identity`, the strongest first.
    func sameDocument(_ identity: DocumentIdentity.Identity) -> Entry? {
        for key in DocumentIdentityIndex.strongestFirst(identity.strong) {
            if let entry = entries[key]?.first(where: { $0.identity.role == identity.role }) { return entry }
        }
        return nil
    }

    /// Strong keys, the strongest type first (ATCUD, invoice, receipt, payroll).
    static func strongestFirst(_ keys: Set<String>) -> [String] {
        let order = ["atcud:", "invoice:", "receipt:", "payroll:"]
        func rank(_ key: String) -> Int { order.firstIndex { key.hasPrefix($0) } ?? order.count }
        return keys.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    /// Every entry sharing a strong identity with `identity`, the strongest key first, each once
    /// (of any kind: the caller compares roles).
    func sameDocuments(_ identity: DocumentIdentity.Identity) -> [Entry] {
        var found: [Entry] = []
        for key in DocumentIdentityIndex.strongestFirst(identity.strong) {
            for entry in entries[key] ?? [] where !found.contains(where: { $0.documentId == entry.documentId && $0.label == entry.label }) {
                found.append(entry)
            }
        }
        return found
    }

    /// The entry sharing a weak key with `identity` that nothing vetoes (`excluding`: library
    /// documents never offered). Only of the same role (the keys hold it) and period.
    func possibleDocument(_ identity: DocumentIdentity.Identity, excluding: Set<Int64> = []) -> Entry? {
        let own = identity.strongByType
        for key in identity.weak.sorted(by: { ($0.hasPrefix("ref:") ? 1 : 0, $0) < ($1.hasPrefix("ref:") ? 1 : 0, $1) }) {
            guard !sharedReferences.contains(key) else { continue }
            for entry in entries[key] ?? [] where entry.documentId.map(excluding.contains) != true {
                let other = entry.identity
                // Two different values of the same strong identity: two documents.
                if own.contains(where: { type, values in other.strongByType[type].map { $0.isDisjoint(with: values) } ?? false }) { continue }
                if let issuer = identity.issuer, let otherIssuer = other.issuer, issuer != otherIssuer { continue }
                // The kind stands for the issuer only where one side names none (either way round).
                if key == identity.kindKey, identity.issuer != nil, other.issuer != nil { continue }
                // Of another kind (role) or another period: another document.
                guard identity.role == other.role else { continue }
                if let period = identity.period, let otherPeriod = other.period, !period.overlaps(otherPeriod) { continue }
                if key.hasPrefix("ref:") {
                    // Corroboration only: same kind, date and amount, all known.
                    guard let role = identity.role, let day = identity.day, let amount = identity.amount,
                          role == other.role, day == other.day, amount == other.amount else { continue }
                }
                return entry
            }
        }
        return nil
    }
}

/// The batch-level duplicate pass over a plan's items, after the readers.
public enum ImportDuplicates {
    /// An alert only for an identical file or a document of the same kind (`claimRole`) and
    /// period, worded with what it compares. In order: same hash as a library document (`.file`
    /// "Identical file: already in the library as <name>"), as an earlier item (`.file` "Identical
    /// file: same as <file> in this import"), a strong identity of a library document or an
    /// earlier item of the same kind (`.document` "Duplicate of <name>: the same <kind>, <ATCUD|
    /// invoice number|receipt number|form> <value>") — always naming the original, never a copy.
    /// A strong identity shared with a document of another kind is a note only ("Refers to
    /// <name>: same ATCUD <code>"). A weak key only (kind + issuer + date + amount, payment
    /// reference) is a Needs-you issue "Possibly a duplicate of <name>: also <a kind> from
    /// <issuer> dated <day> for <amount>".
    /// Of the documents of its kind sharing a strong identity (the library's, then the batch's), the first
    /// whose money figures (amount, pay, tax, with their currency) agree is the one this
    /// copies. When every one differs from what it holds — the document's own figures, else the
    /// recorded invoice or receipt's, the stored pay and tax — it is a Needs-you "Possibly a
    /// corrected version of <the newest>: …": a payroll form may be imported as the newer
    /// version (acknowledge); any other document only filed, linked where the original is
    /// (`.fileWithoutLink`), or left out. The same file (hash) is a copy whatever it says; the
    /// library documents the item replaces (`ProposedLink.replacing`) are never its original.
    /// A bank statement (UK or BBVA) whose file is already in the library is a duplicate only
    /// when its layout isn't waiting to be mapped (`StatementChecks.awaitsMapping`), it adds
    /// nothing (`StatementChecks.writesSomething`: a mapping to save counts) and contradicts nothing saved
    /// (`StatementChecks.keepsFromDuplicates`: pure questions and filed-year holds aside); otherwise it is imported as any statement — its rows are what the batch's
    /// later statements of the account count as imported — with the note "Document already in
    /// the library as <name>", and filing it returns that document. A second copy of a
    /// statement in the batch (checked before the library) is a duplicate unless it holds rows.
    /// Two items attaching their document to the same recorded invoice: the later one is a copy
    /// of the earlier (`.document` "Duplicate of <file>: the same utility invoice, invoice number <n>").
    /// The first of a pair stays as it was; items a reader already marked, child rows and
    /// left-out items are left alone. Then transaction claims: a certain link to a transaction
    /// that already has a document of the same kind and period (in the library or this import)
    /// needs the user's go ("Possibly a duplicate: <name> is also <a kind> dated <day> on this
    /// transaction", `sameKindOnTransaction.<id>`), as does a rent contract certain of a tenancy
    /// that already has one (a tenancy's addenda never claim it); items of one kind and different
    /// periods automatically linked (certain) to one transaction become "check the link"
    /// questions (`checkLink.<id>`), never for links the user chose.
    /// `library`: the library's index when already read from `db` (the pipeline reads it once
    /// per planning copy); else it is read here.
    /// What a later item may copy: a library document, or an item of the batch (`itemId`).
    private struct Original {
        var label: String
        var documentId: Int64?
        var itemId: UUID?

        init(label: String, documentId: Int64?, itemId: UUID? = nil) {
            self.label = label
            self.documentId = documentId
            self.itemId = itemId
        }

        /// "Identical file: already in the library as <name>" / "Identical file: same as <file> in this import".
        func identicalFile() -> ImportDuplicate {
            let sentence = documentId != nil ? "Identical file: already in the library as \(label)" : "Identical file: same as \(label) in this import"
            return ImportDuplicate(level: .file, of: sentence, existingDocumentId: documentId, originalItemId: documentId == nil ? itemId : nil)
        }

        /// "Duplicate of <name>: <what>" ("the same insurance receipt, ATCUD …").
        func sameDocument(_ what: String) -> ImportDuplicate {
            ImportDuplicate(level: .document, of: "Duplicate of \(label): \(what)", existingDocumentId: documentId,
                            originalItemId: documentId == nil ? itemId : nil)
        }
    }

    public static func annotate(_ items: [ImportItem], db: Database, library: DocumentIdentityIndex? = nil) throws -> [ImportItem] {
        let library = try library ?? DocumentIdentityIndex.load(db: db)
        var batch = DocumentIdentityIndex()
        /// Hash → the original's name, library id and (when in the batch only) item.
        var batchFiles: [String: Original] = [:]
        /// Recorded invoice → the item of the batch attaching its document (`.attachToInvoice`).
        var attaching: [Int64: Original] = [:]
        var result = items
        // A left-out item isn't imported: it is no one's original (nor checked itself).
        for i in result.indices where result[i].parentId == nil && !result[i].isLeftOut {
            // A statement's note of an earlier pass is said again below when it still holds.
            let isStatement = StatementChecks.accountId(of: result[i]) != nil
            // A statement whose layout is still to be mapped is answered, never skipped (Edit
            // column mapping… with the file already imported saves the mapping).
            let awaitsMapping = StatementChecks.awaitsMapping(result[i])
            if isStatement || awaitsMapping { result[i].notes.removeAll { $0.hasPrefix(libraryNotePrefix) } }
            result[i].notes.removeAll { $0 == libraryInvoiceNote || $0.hasPrefix(refersToNotePrefix) }
            let item = result[i]
            let identity = DocumentIdentity.identity(kind: item.recognition.kind, text: item.file.text, facts: item.facts,
                                                     providerId: providerId(item), personId: personId(item))
            var original = Original(label: item.file.fileName, documentId: nil, itemId: item.id)
            if let duplicate = item.duplicate {
                // A reader's duplicate is registered as the library document it names; one
                // naming none isn't an original for later items.
                guard let id = duplicate.existingDocumentId, let name = library.name(of: id) else { continue }
                original = Original(label: name, documentId: id)
            } else if isStatement, let earlier = batchFiles[item.file.sha256] {
                // A second copy of a statement (of a library file too) adds nothing: the first
                // holds its rows, estimates and valuation. One that still holds rows (never,
                // while the first is in the import) isn't a copy.
                if !StatementChecks.holdsRows(item) {
                    result[i].duplicate = earlier.identicalFile()
                }
                original = earlier
            } else if let found = library.byHash[item.file.sha256] {
                if awaitsMapping || isStatement && (StatementChecks.writesSomething(item) || item.issues.contains(where: StatementChecks.keepsFromDuplicates)) {
                    // The statement reader decides: rows, legs, an estimate or a valuation still
                    // to add (or saved data it contradicts) make it a statement like any other,
                    // filed as the library's document (the library returns it: no second copy).
                    result[i].notes.append("\(libraryNotePrefix)\(found.label)")
                } else if try recordsNewInvoice(item, on: found.documentId, db: db) {
                    // A utility invoice in the library not recorded yet (Utility invoices… "From
                    // library"): read again and recorded on that document (the library returns it)
                    // — once: a second copy of the file in the batch is that one's.
                    if let earlier = batchFiles[item.file.sha256] {
                        result[i].duplicate = earlier.identicalFile()
                    } else {
                        result[i].notes.append(libraryInvoiceNote)
                    }
                } else {
                    result[i].duplicate = Original(label: found.label, documentId: found.documentId).identicalFile()
                }
                original = Original(label: found.label, documentId: found.documentId)
            } else if let earlier = batchFiles[item.file.sha256] {
                result[i].duplicate = earlier.identicalFile()
                original = earlier
            } else {
                // Strong before weak. Of the documents sharing a strong identity (the library's,
                // then the batch's), the first whose figures agree is the one this copies; when
                // every one differs, it is possibly a corrected version of the newest.
                // The documents the item replaces on its record (Replace PDF…) aren't what it copies.
                // Only a document of the same kind (role) is what it copies: one of another kind
                // sharing a code (a receipt quoting its invoice's ATCUD) is a note.
                let replaced = Set(item.links.flatMap(\.replacing))
                let libraryAll = library.sameDocuments(identity).filter { $0.documentId.map(replaced.contains) != true }
                let batchAll = batch.sameDocuments(identity)
                let libraryStrong = libraryAll.filter { $0.identity.role == identity.role }
                let batchStrong = batchAll.filter { $0.identity.role == identity.role }
                let strong = libraryStrong + batchStrong
                if let copied = strong.first(where: { changes(from: $0, to: item).isEmpty }) {
                    let copy = Original(label: copied.label, documentId: copied.documentId, itemId: copied.itemId)
                    result[i].duplicate = copy.sameDocument(sameDocumentWording(identity, copied, facts: item.facts))
                    original = copy
                } else if let newest = batchStrong.last ?? libraryStrong.max(by: { ($0.documentId ?? 0) < ($1.documentId ?? 0) }) {
                    // Another amount, pay or tax than every original holds: the user decides
                    // (and the filed-year guard still sees it).
                    result[i].issues.append(try correctedVersion(of: newest, item: item, db: db))
                } else {
                    for entry in libraryAll + batchAll where entry.identity.role != identity.role {
                        guard let key = sharedStrongKey(identity, entry.identity) else { continue }
                        let shared = describe(strongKey: key, facts: item.facts)
                        let note = "\(refersToNotePrefix)\(entry.label): same \(shared.name) \(shared.value)"
                        if !result[i].notes.contains(note) { result[i].notes.append(note) }
                    }
                    if let entry = library.possibleDocument(identity, excluding: replaced) ?? batch.possibleDocument(identity) {
                        let reason = possibleDuplicateReason(identity, entry)
                        result[i].issues.append(ImportIssue(id: "possibleDuplicate", kind: .readerProblem(reason), reason: reason,
                                                            offers: [.acknowledge, .leaveOut]))
                    }
                }
            }
            if result[i].duplicate == nil, case .attachToInvoice(let invoiceId) = item.effect {
                // A recorded invoice takes one document: another file of it in the batch is a copy.
                if let earlier = attaching[invoiceId] {
                    let number = try UtilityInvoice.fetchOne(db, key: invoiceId)?.invoiceNumber.flatMap { $0.isEmpty ? nil : $0 }
                    let kind = lowered(DocumentKind.utilityInvoice.displayName)
                    result[i].duplicate = earlier.sameDocument(number.map { "the same \(kind), invoice number \($0)" } ?? "the same \(kind)")
                    result[i].issues.removeAll { $0.id == "possibleDuplicate" }
                } else {
                    attaching[invoiceId] = original
                }
            }
            if batchFiles[item.file.sha256] == nil { batchFiles[item.file.sha256] = original }
            batch.add(.init(documentId: original.documentId, label: original.label, identity: identity,
                            itemId: original.documentId == nil ? original.itemId : nil))
        }
        // A changed source-folder file takes its previous version's links before the claims are checked.
        for i in result.indices { result[i] = try ImportPipeline.withPreviousVersion(result[i], db: db) }
        try annotateClaims(&result, db: db)
        return result
    }

    /// The note of an item sharing a code with a document of another kind ("Refers to <name>:
    /// same ATCUD <code>"): not a duplicate.
    public static let refersToNotePrefix = "Refers to "

    /// The strong key `identity` shares with `other`, the strongest first.
    static func sharedStrongKey(_ identity: DocumentIdentity.Identity, _ other: DocumentIdentity.Identity) -> String? {
        DocumentIdentityIndex.strongestFirst(identity.strong.intersection(other.strong)).first
    }

    /// What a strong key compares, as shown: ("ATCUD", "ABCD1234-77"), ("invoice number", "FT 1/23"),
    /// ("receipt number", "12"), ("form", "P60 2022-23"). A number as the file prints it when its facts hold it.
    static func describe(strongKey key: String, facts: [ImportFact]) -> (name: String, value: String) {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func shown(_ field: ImportFigureField, _ compact: String) -> String {
            DocumentIdentity.textFact(field, facts).flatMap { DocumentIdentity.compact($0) == compact ? $0 : nil } ?? compact
        }
        switch parts.first {
        case "atcud": return ("ATCUD", parts.dropFirst().joined(separator: ":"))
        case "invoice": return ("invoice number", shown(.invoiceNumber, parts.dropFirst(2).joined(separator: ":")))
        case "receipt": return ("receipt number", shown(.receiptNumber, parts.last ?? ""))
        case "payroll":
            let form = parts.count > 1 ? parts[1] : ""
            let name = DocumentKind(rawValue: form)?.displayName ?? form.uppercased()
            guard parts.count > 2, let year = Int(parts[2]) else { return ("form", name) }
            return ("form", "\(name) \(year)-\(String(format: "%02d", (year + 1) % 100))")
        default: return ("code", key)
        }
    }

    /// "the same insurance receipt, ATCUD ABCD1234-77".
    static func sameDocumentWording(_ identity: DocumentIdentity.Identity, _ entry: DocumentIdentityIndex.Entry, facts: [ImportFact]) -> String {
        let kind = lowered(kindName(identity.role ?? entry.identity.role))
        guard let key = sharedStrongKey(identity, entry.identity) else { return "the same \(kind)" }
        let shared = describe(strongKey: key, facts: facts)
        return "the same \(kind), \(shared.name) \(shared.value)"
    }

    /// "Possibly a duplicate of <name>: also an insurance receipt from <issuer> dated 2023-03-05 for €120.00"
    /// (what is unknown left out).
    static func possibleDuplicateReason(_ identity: DocumentIdentity.Identity, _ entry: DocumentIdentityIndex.Entry) -> String {
        var reason = "Possibly a duplicate of \(entry.label): also \(article(kindName(entry.identity.role ?? identity.role)))"
        if let issuer = identity.issuerName ?? entry.identity.issuerName { reason += " from \(issuer)" }
        if let day = identity.day ?? entry.identity.day { reason += " dated \(DocumentIdentity.isoDay(fromKey: day))" }
        if let amount = identity.amount ?? entry.identity.amount {
            reason += " for \(Money.format(amount, currency: identity.currency ?? entry.identity.currency ?? .eur))"
        }
        return reason
    }

    /// A kind token's name ("Insurance receipt").
    static func kindName(_ token: String?) -> String {
        guard let token else { return DocumentKind.other.displayName }
        return DocumentKind(rawValue: token)?.displayName ?? token
    }

    /// The note of a utility invoice whose file is already in the library but isn't recorded as
    /// an invoice yet: read again and recorded on that document.
    public static let libraryInvoiceNote = "Already in the library: record it as an invoice"

    /// The note of a statement whose file is already in the library but still adds something:
    /// "Document already in the library as <name>".
    public static let libraryNotePrefix = "Document already in the library as "

    /// Id of the issue of an item sharing a strong identity with a document whose figures differ.
    public static let correctedVersionIssueId = "correctedVersion"
    /// Id of the utility invoice reader's own "Possibly a corrected version" (another amount for
    /// a period recorded without a number, `Recharges.recordedForPeriod`): not the pass's, so the
    /// pass never strips it.
    public static let recordedCorrectedVersionIssueId = "correctedVersion.recorded"

    /// Whether the issue is a "Possibly a corrected version" (the pass's or the invoice reader's).
    public static func isCorrectedVersion(_ issueId: String) -> Bool {
        issueId == correctedVersionIssueId || issueId == recordedCorrectedVersionIssueId
    }

    /// How `item`'s money figures differ from those `entry` holds ("Pay £39,840.00 →
    /// £40,840.00"): only figures both have are compared, and another currency is another
    /// figure. None: `item` copies `entry`.
    static func changes(from entry: DocumentIdentityIndex.Entry, to item: ImportItem) -> [String] {
        DocumentIdentity.comparedFigures.compactMap { field -> String? in
            guard let held = entry.identity.figures[field], let read = DocumentIdentity.moneyFact(field, item.facts) else { return nil }
            let heldCurrency = held.currency ?? read.currency
            guard held.amount != abs(read.amount) || heldCurrency != read.currency else { return nil }
            return "\(field.displayName) \(Money.format(held.amount, currency: heldCurrency)) → \(Money.format(abs(read.amount), currency: read.currency))"
        }
    }

    /// "Possibly a corrected version of <name>: …". A payroll form may be imported as the newer
    /// version (its pay and tax replace the stored ones); any other document is filed only,
    /// linked where the original is (a recorded invoice or receipt is never recorded twice).
    static func correctedVersion(of entry: DocumentIdentityIndex.Entry, item: ImportItem, db: Database) throws -> ImportIssue {
        let reason = "Possibly a corrected version of \(entry.label): \(changes(from: entry, to: item).joined(separator: ", "))"
        if case .payrollForm = item.recognition.kind {
            return ImportIssue(id: correctedVersionIssueId, kind: .readerProblem(reason), reason: reason, offers: [.acknowledge, .leaveOut])
        }
        var links: [ProposedLink] = []
        if let documentId = entry.documentId {
            var entities = try DocumentLink.filter(Column("documentId") == documentId).order(Column("id")).fetchAll(db).map { ($0.entity, $0.role) }
            // A recorded invoice's document is linked to its debit through the invoice.
            for transactionId in try Int64.fetchAll(db, sql: "SELECT transactionId FROM utilityInvoice WHERE documentId = ? AND transactionId IS NOT NULL",
                                                    arguments: [documentId])
            where !entities.contains(where: { $0.0 == .transaction(transactionId) }) {
                entities.append((.transaction(transactionId), nil))
            }
            for (entity, role) in entities where try EvidenceLinks.entityExists(db: db, entity) {
                links.append(ProposedLink(entity: entity, role: role, label: try entityLabel(db: db, entity), confidence: .certain,
                                          reasons: ["\(entry.label) is linked to it"]))
            }
        }
        return ImportIssue(id: correctedVersionIssueId, kind: .readerProblem(reason), reason: reason, offers: [.fileWithoutLink, .leaveOut],
                           documentOnlyLinks: links)
    }

    /// Whether confirming `item` — the file of library document `documentId` — would record a
    /// utility invoice (or could, once its provider is chosen) and no invoice is recorded on that document yet.
    static func recordsNewInvoice(_ item: ImportItem, on documentId: Int64, db: Database) throws -> Bool {
        guard item.recognition.kind == .utilityInvoice else { return false }
        let records: Bool
        if case .utilityInvoice = item.effect {
            records = true
        } else {
            records = item.issues.contains { $0.id == UtilityInvoiceImportReader.documentOnlyIssueId }
        }
        guard records else { return false }
        return try UtilityInvoice.filter(Column("documentId") == documentId).fetchCount(db) == 0
    }

    private static func providerId(_ item: ImportItem) -> Int64? {
        if case .utilityInvoice(let invoice) = item.effect { return invoice.providerId }
        return item.identityProviderId
    }

    private static func personId(_ item: ImportItem) -> Int64? {
        if case .payrollForm(let confirmed) = item.effect, confirmed.personId > 0 { return confirmed.personId }
        return nil
    }

    /// The library kind of an item that will be imported as a document (not a statement,
    /// duplicate, left out or row).
    private static func claimingKind(_ item: ImportItem) -> DocumentKind? {
        guard item.parentId == nil, item.duplicate == nil, !item.isLeftOut,
              let kind = DocumentIdentity.documentKind(of: item.recognition.kind), kind != .bankStatement else { return nil }
        return kind
    }

    /// The part a document plays on its transaction, as a kind token: the bank's proof of the
    /// movement (a debit advice or transfer proof, or the bank's advice of the movement filed
    /// under another kind, `IssuerKey.isBankMovementAdvice`) or the underlying receipt or invoice
    /// (its kind). A receipt and the bank's advice of its debit share a transaction by nature;
    /// two of one part may not. A mortgage notice and receipt are the bank's own letters (worded
    /// as advices of the movement) yet each its own part: a notice and a receipt of one
    /// instalment are a pair. What "the same kind" compares for every duplicate rule.
    public static func claimRole(token: String, text: String?) -> String {
        let own: Set<DocumentKind> = [.bankDebitAdvice, .bankTransferProof, .mortgageNotice, .mortgageReceipt]
        if let kind = DocumentKind(rawValue: token), own.contains(kind) { return token }
        if let text, IssuerKey.isBankMovementAdvice(text) { return DocumentKind.bankDebitAdvice.rawValue }
        return token
    }

    /// The id prefix of "That tenancy already has a rent contract" (the tenancy's id follows).
    static let tenancyHasContractPrefix = "tenancyHasContract."
    /// The id prefix of "Possibly a duplicate: <name> is also <a kind> dated <day> on this transaction".
    public static let sameKindOnTransactionPrefix = "sameKindOnTransaction."
    /// The id prefix of "<a> and <b> — both <kind>, <period a> and <period b> — were matched to the same transaction".
    public static let checkLinkPrefix = "checkLink."

    /// The day and the period a document states: two of one kind are the same document's when
    /// their periods overlap (both stating one), else when they are of the same day.
    struct ClaimPeriod {
        var day: String?
        var period: ClosedRange<String>?

        init(facts: [ImportFact]) {
            day = DocumentIdentity.dateFact(facts).map(DocumentIdentity.dayKey)
            period = DocumentIdentity.period(facts)
        }

        init(document: EvidenceDocument) {
            day = document.docDate.map(DocumentIdentity.dayKey)
            var facts: [ImportFact] = []
            for (field, date) in [(ImportFigureField.periodStart, document.periodStart), (.periodEnd, document.periodEnd)] {
                if let date { facts.append(ImportFact(field: field, value: .date(date), source: .matchedRecord, confidence: .certain, reason: "")) }
            }
            period = DocumentIdentity.period(facts)
        }

        func isSame(as other: ClaimPeriod) -> Bool {
            if let period, let otherPeriod = other.period { return period.overlaps(otherPeriod) }
            guard let day else { return false }
            return day == other.day
        }

        private var periodText: String? {
            period.map { $0.lowerBound == $0.upperBound ? DocumentIdentity.isoDay(fromKey: $0.lowerBound)
                : "\(DocumentIdentity.isoDay(fromKey: $0.lowerBound)) to \(DocumentIdentity.isoDay(fromKey: $0.upperBound))" }
        }

        /// What "dated …" says: its day, else its period.
        var dated: String { day.map(DocumentIdentity.isoDay(fromKey:)) ?? periodText ?? "undated" }
        /// Its period, else its day ("2023-01-01 to 2023-01-31", "2023-03-05", "undated").
        var described: String { periodText ?? day.map(DocumentIdentity.isoDay(fromKey:)) ?? "undated" }
    }

    private struct Claimant {
        var item: Int
        var link: Int
        var role: String
        var period: ClaimPeriod
    }

    private struct Claim: Hashable {
        var transactionId: Int64
        var role: String
    }

    private static func annotateClaims(_ items: inout [ImportItem], db: Database) throws {
        func role(_ i: Int) -> String? {
            claimingKind(items[i]).map { claimRole(token: $0.rawValue, text: items[i].file.text) }
        }
        // A certain link to a transaction that already has a document of the same kind (role)
        // and period: in the library, or another item of this import linked to it (certain or not).
        for i in items.indices {
            // A corrected version filed only is linked where its original is, on purpose.
            guard let kind = claimingKind(items[i]), let ownRole = role(i), !ImportResolutions.isFiledAsCorrectedVersion(items[i]) else { continue }
            let period = ClaimPeriod(facts: items[i].facts)
            for link in items[i].links where link.entity.type == .transaction && link.confidence == .certain {
                // Never the item's own file, already in the library (read again to be recorded), nor a
                // document the link replaces there (a previous version, a replaced PDF). Of the same
                // part (`claimRole`), whatever kind each was filed as: a receipt beside the bank's
                // advice of its debit is normal, the same advice filed again under another kind is not.
                var existing = try EvidenceLinks.documents(db: db, for: link.entity)
                    .first { document in
                        claimRole(token: document.kind.rawValue, text: document.extractedText) == ownRole
                            && document.sha256 != items[i].file.sha256 && !link.replacing.contains(document.id ?? 0)
                            && ClaimPeriod(document: document).isSame(as: period)
                    }.map { (name: $0.displayName, period: ClaimPeriod(document: $0)) }
                if existing == nil {
                    existing = items.indices.first { j in
                        guard j != i, role(j) == ownRole else { return false }
                        return items[j].links.contains { $0.entity == link.entity } && ClaimPeriod(facts: items[j].facts).isSame(as: period)
                    }.map { (name: items[$0].file.fileName, period: ClaimPeriod(facts: items[$0].facts)) }
                }
                guard let existing else { continue }
                let reason = "Possibly a duplicate: \(existing.name) is also \(article(kindName(ownRole))) dated \(existing.period.dated) on this transaction"
                items[i].issues.append(ImportIssue(id: "\(sameKindOnTransactionPrefix)\(link.entity.id)", kind: .readerProblem(reason), reason: reason,
                                                   offers: [.acknowledge, .fileWithoutLink]))
            }
            // A contract certain of a tenancy that already has one (in the library, or another item
            // of this import): two contracts of one tenancy ask. Its addenda never claim it.
            for link in items[i].links where kind == .rentContract && link.entity.type == .tenancy && link.confidence == .certain {
                var existing = try EvidenceLinks.documents(db: db, for: link.entity)
                    .first { $0.kind == .rentContract && $0.sha256 != items[i].file.sha256 && !link.replacing.contains($0.id ?? 0) }?.displayName
                if existing == nil {
                    existing = items.indices.first { j in
                        j != i && claimingKind(items[j]) == .rentContract && items[j].links.contains { $0.entity == link.entity }
                    }.map { items[$0].file.fileName }
                }
                guard let existing else { continue }
                let reason = "That tenancy already has a rent contract (\(existing))"
                items[i].issues.append(ImportIssue(id: "\(tenancyHasContractPrefix)\(link.entity.id)", kind: .readerProblem(reason), reason: reason,
                                                   offers: [.acknowledge, .fileWithoutLink]))
            }
        }
        // Items of one kind (role) and different periods certain of the same transaction: not
        // duplicates, but one of the automatic links is likely wrong. Links the user chose never ask.
        var claimants: [Claim: [Claimant]] = [:]
        var order: [Claim] = []
        for i in items.indices {
            guard let ownRole = role(i) else { continue }
            let period = ClaimPeriod(facts: items[i].facts)
            for (l, link) in items[i].links.enumerated() where link.entity.type == .transaction && link.confidence == .certain {
                let claim = Claim(transactionId: link.entity.id, role: ownRole)
                if claimants[claim] == nil { order.append(claim) }
                claimants[claim, default: []].append(Claimant(item: i, link: l, role: ownRole, period: period))
            }
        }
        func chosen(_ claimant: Claimant) -> Bool {
            items[claimant.item].links[claimant.link].reasons.contains(ImportResolutions.chosenReason)
        }
        for claim in order {
            guard let claiming = claimants[claim], claiming.count >= 2 else { continue }
            let asking = claiming.compactMap { own -> (Claimant, Claimant)? in
                guard !chosen(own),
                      let other = claiming.first(where: { $0.item != own.item && !chosen($0) && !$0.period.isSame(as: own.period) }) else { return nil }
                return (own, other)
            }
            for (own, other) in asking {
                let link = items[own.item].links[own.link]
                let reason = "\(items[own.item].file.fileName) and \(items[other.item].file.fileName) — both \(plural(lowered(kindName(claim.role)))), "
                    + "\(own.period.described) and \(other.period.described) — were matched to the same transaction"
                items[own.item].links[own.link].confidence = .needsReview
                items[own.item].issues.append(ImportIssue(id: "\(checkLinkPrefix)\(claim.transactionId)",
                                                          kind: .chooseLink([LinkCandidate(entity: link.entity, label: link.label, reasons: link.reasons)]),
                                                          reason: reason, offers: [.fileWithoutLink]))
            }
        }
    }

    /// "an insurance receipt", "a P60", "an IMI notice": lower case unless an acronym leads.
    static func article(_ name: String) -> String {
        let shown = lowered(name)
        let isAcronym = shown.count >= 2 && shown.prefix(2).allSatisfy { $0.isUppercase || $0.isNumber }
        let first = shown.first.map(String.init) ?? ""
        // "a utility invoice": a "you" sound takes "a".
        let youSound = ["uni", "uti", "use", "usu", "eu"].contains { shown.hasPrefix($0) }
        let vowelSound = isAcronym ? "AEFHILMNORSX".contains(first) : "aeiou".contains(first) && !youSound
        return (vowelSound ? "an " : "a ") + shown
    }

    /// "insurance receipt", "P60", "IMI notice": a kind's name lower case unless an acronym leads.
    static func lowered(_ name: String) -> String {
        let isAcronym = name.count >= 2 && name.prefix(2).allSatisfy { $0.isUppercase || $0.isNumber }
        return isAcronym ? name : name.prefix(1).lowercased() + name.dropFirst()
    }

    /// "insurance receipts", "stamp duties", "P60s".
    static func plural(_ name: String) -> String {
        if name.hasSuffix("y"), let before = name.dropLast().last, !"aeiou".contains(before) { return name.dropLast() + "ies" }
        if name.hasSuffix("s") || name.hasSuffix("x") || name.hasSuffix("ch") || name.hasSuffix("sh") { return name + "es" }
        return name + "s"
    }
}

extension DocumentIdentityIndex {
    /// A library document's display name, by id.
    func name(of documentId: Int64) -> String? {
        byHash.values.first { $0.documentId == documentId }?.label
    }
}
