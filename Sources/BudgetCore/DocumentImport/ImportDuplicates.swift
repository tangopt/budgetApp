import GRDB
import Foundation

/// What makes two files the same document, whatever their bytes.
///
/// Strong identities — `"atcud:<code>"`, `"invoice:<providerId>:<number>"`,
/// `"receipt:<contract>:<number>"`, `"payroll:<form>:<taxYear>:<employer>:<personId>"` — make a
/// copy a duplicate. Weak keys — `"ref:<payment reference>"` (9+ digits) and
/// `"ida:<issuer>:<yyyyMMdd>:<amount minor>"` (issuer + date + amount) — only ever ask the user.
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
        var kind: DocumentKind?
        var day: String?
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
            kind = kind ?? other.kind
            day = day ?? other.day
            amount = amount ?? other.amount
            issuer = issuer ?? other.issuer
            figures.merge(other.figures) { own, _ in own }
        }
    }

    /// Every key of the document: the strong ones, `"ref:…"`, and `"ida:…"` twice — by issuer
    /// with the amount's sign (a credit note is not the invoice) when an issuer fact exists,
    /// and by the document kind, sign-free (library documents store amounts sign-free).
    /// Statements (checked by their transactions), receipts exports, unknown files and `.other`
    /// documents have none.
    public static func keys(kind: ImportKind, text: String?, facts: [ImportFact], providerId: Int64?, personId: Int64? = nil) -> Set<String> {
        identity(kind: kind, text: text, facts: facts, providerId: providerId, personId: personId).keys
    }

    static func identity(kind: ImportKind, text: String?, facts: [ImportFact], providerId: Int64?, personId: Int64?) -> Identity {
        var identity = Identity()
        guard let documentKind = documentKind(of: kind), documentKind != .bankStatement, documentKind != .other else { return identity }
        identity.kind = documentKind
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
        if case .payrollForm(let form) = kind, let personId, let employer = identity.issuer, let year = yearFact(facts) {
            identity.strong.insert(payrollKey(form: form.rawValue, year: year, employer: employer, personId: personId))
        }
        identity.day = dateFact(facts).map(dayKey)
        let signed = signedAmountFact(facts)
        identity.amount = signed.map(abs)
        for field in DocumentIdentity.comparedFigures {
            if let value = moneyFact(field, facts) { identity.figures[field] = Figure(amount: abs(value.amount), currency: value.currency) }
        }
        if let day = identity.day, let signed {
            if let issuer = identity.issuer { identity.weak.insert("ida:\(issuer):\(day):\(signed)") }
            let kindKey = "ida:\(documentKind.rawValue):\(day):\(abs(signed))"
            identity.weak.insert(kindKey)
            identity.kindKey = kindKey
        }
        return identity
    }

    static func payrollKey(form: String, year: Int, employer: String, personId: Int64) -> String {
        "payroll:\(form):\(year):\(employer):\(personId)"
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

    private static func textFact(_ field: ImportFigureField, _ facts: [ImportFact]) -> String? {
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
            var identity = DocumentIdentity.identity(kind: .evidence(document.kind), text: document.extractedText, facts: facts,
                                                     providerId: nil, personId: nil)
            // The amount as the document states it (its currency unknown when it has none).
            identity.figures[.amount] = document.amountMinorUnits.map { DocumentIdentity.Figure(amount: abs($0), currency: document.currency) }
            documents[id] = Entry(documentId: id, label: document.displayName, identity: identity)
            order.append(id)
        }
        func enrich(_ documentId: Int64, _ change: (inout DocumentIdentity.Identity) -> Void) {
            guard documents[documentId] != nil else { return }
            change(&documents[documentId]!.identity)
        }
        // Recorded utility invoices: number per provider, provider + date + signed amount.
        let providers = Dictionary(uniqueKeysWithValues: try UtilityProvider.fetchAll(db).compactMap { provider in
            provider.id.map { ($0, DocumentIdentity.normalisedIssuer(provider.name)) }
        })
        for invoice in try UtilityInvoice.filter(Column("documentId") != nil).fetchAll(db) {
            guard let documentId = invoice.documentId else { continue }
            enrich(documentId) { identity in
                if let number = invoice.invoiceNumber.map(DocumentIdentity.compact), !number.isEmpty {
                    identity.strong.insert("invoice:\(invoice.providerId):\(number)")
                }
                let day = DocumentIdentity.dayKey(invoice.issueDate)
                if let issuer = providers[invoice.providerId], !issuer.isEmpty {
                    identity.issuer = issuer
                    identity.weak.insert("ida:\(issuer):\(day):\(invoice.amountMinorUnits)")
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
            enrich(row[0]) { identity in
                identity.strong.insert(key)
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

    /// The entry sharing a strong identity with `identity`, the strongest first.
    func sameDocument(_ identity: DocumentIdentity.Identity) -> Entry? {
        let order = ["atcud:", "invoice:", "receipt:", "payroll:"]
        func rank(_ key: String) -> Int { order.firstIndex { key.hasPrefix($0) } ?? order.count }
        for key in identity.strong.sorted(by: { (rank($0), $0) < (rank($1), $1) }) {
            if let entry = entries[key]?.first { return entry }
        }
        return nil
    }

    /// Every entry sharing a strong identity with `identity`, the strongest key first, each once.
    func sameDocuments(_ identity: DocumentIdentity.Identity) -> [Entry] {
        let order = ["atcud:", "invoice:", "receipt:", "payroll:"]
        func rank(_ key: String) -> Int { order.firstIndex { key.hasPrefix($0) } ?? order.count }
        var found: [Entry] = []
        for key in identity.strong.sorted(by: { (rank($0), $0) < (rank($1), $1) }) {
            for entry in entries[key] ?? [] where !found.contains(where: { $0.documentId == entry.documentId && $0.label == entry.label }) {
                found.append(entry)
            }
        }
        return found
    }

    /// The entry sharing a weak key with `identity` that nothing vetoes.
    func possibleDocument(_ identity: DocumentIdentity.Identity) -> Entry? {
        let own = identity.strongByType
        for key in identity.weak.sorted(by: { ($0.hasPrefix("ref:") ? 1 : 0, $0) < ($1.hasPrefix("ref:") ? 1 : 0, $1) }) {
            guard !sharedReferences.contains(key) else { continue }
            for entry in entries[key] ?? [] {
                let other = entry.identity
                // Two different values of the same strong identity: two documents.
                if own.contains(where: { type, values in other.strongByType[type].map { $0.isDisjoint(with: values) } ?? false }) { continue }
                if let issuer = identity.issuer, let otherIssuer = other.issuer, issuer != otherIssuer { continue }
                // The kind stands for the issuer only where one side names none (either way round).
                if key == identity.kindKey, identity.issuer != nil, other.issuer != nil { continue }
                if key.hasPrefix("ref:") {
                    // Corroboration only: same kind, date and amount, all known.
                    guard let kind = identity.kind, let day = identity.day, let amount = identity.amount,
                          kind == other.kind, day == other.day, amount == other.amount else { continue }
                }
                return entry
            }
        }
        return nil
    }
}

/// The batch-level duplicate pass over a plan's items, after the readers.
public enum ImportDuplicates {
    /// In order: same hash as a library document (`.file` "Already in the library as <name>"),
    /// as an earlier item (`.file` "Same file as <file>"), a strong identity of a library document
    /// (`.document` "Same document as <name>"), of an earlier item (`.document` "Same document as
    /// <file>") — always naming the original, never a copy. A weak key only (issuer + date +
    /// amount, payment reference) is a Needs-you issue "Possibly the same document as <name>".
    /// Of the documents sharing a strong identity (the library's, then the batch's), the first
    /// whose money figures (amount, pay, tax, with their currency) agree is the one this
    /// copies. When every one differs from what it holds — the document's own figures, else the
    /// recorded invoice or receipt's, the stored pay and tax — it is a Needs-you "Possibly a
    /// corrected version of <the newest>: …": a payroll form may be imported as the newer
    /// version (acknowledge); any other document only filed, linked where the original is
    /// (`.fileWithoutLink`), or left out. The same file (hash) is a copy whatever it says.
    /// The first of a pair stays as it was; items a reader already marked, child rows and
    /// left-out items are left alone. Then transaction claims: items of one kind certain of the same transaction
    /// all need the user, and a certain link to a transaction that already has a document of
    /// the same kind (in the library or this import) needs the user's go.
    /// `library`: the library's index when already read from `db` (the pipeline reads it once
    /// per planning copy); else it is read here.
    public static func annotate(_ items: [ImportItem], db: Database, library: DocumentIdentityIndex? = nil) throws -> [ImportItem] {
        let library = try library ?? DocumentIdentityIndex.load(db: db)
        var batch = DocumentIdentityIndex()
        /// Hash → the original's name and library id.
        var batchFiles: [String: (label: String, documentId: Int64?)] = [:]
        var result = items
        // A left-out item isn't imported: it is no one's original (nor checked itself).
        for i in result.indices where result[i].parentId == nil && !result[i].isLeftOut {
            let item = result[i]
            let identity = DocumentIdentity.identity(kind: item.recognition.kind, text: item.file.text, facts: item.facts,
                                                     providerId: providerId(item), personId: personId(item))
            var original: (label: String, documentId: Int64?) = (item.file.fileName, nil)
            if let duplicate = item.duplicate {
                // A reader's duplicate is registered as the library document it names; one
                // naming none isn't an original for later items.
                guard let id = duplicate.existingDocumentId, let name = library.name(of: id) else { continue }
                original = (name, id)
            } else if let found = library.byHash[item.file.sha256] {
                result[i].duplicate = ImportDuplicate(level: .file, of: "Already in the library as \(found.label)", existingDocumentId: found.documentId)
                original = (found.label, found.documentId)
            } else if let earlier = batchFiles[item.file.sha256] {
                result[i].duplicate = ImportDuplicate(level: .file, of: "Same file as \(earlier.label)", existingDocumentId: earlier.documentId)
                original = earlier
            } else {
                // Strong before weak. Of the documents sharing a strong identity (the library's,
                // then the batch's), the first whose figures agree is the one this copies; when
                // every one differs, it is possibly a corrected version of the newest.
                let libraryStrong = library.sameDocuments(identity), batchStrong = batch.sameDocuments(identity)
                let strong = libraryStrong + batchStrong
                if let copied = strong.first(where: { changes(from: $0, to: item).isEmpty }) {
                    result[i].duplicate = ImportDuplicate(level: .document, of: "Same document as \(copied.label)", existingDocumentId: copied.documentId)
                    original = (copied.label, copied.documentId)
                } else if let newest = batchStrong.last ?? libraryStrong.max(by: { ($0.documentId ?? 0) < ($1.documentId ?? 0) }) {
                    // Another amount, pay or tax than every original holds: the user decides
                    // (and the filed-year guard still sees it).
                    result[i].issues.append(try correctedVersion(of: newest, item: item, db: db))
                } else if let entry = library.possibleDocument(identity) ?? batch.possibleDocument(identity) {
                    let reason = "Possibly the same document as \(entry.label)"
                    result[i].issues.append(ImportIssue(id: "possibleDuplicate", kind: .readerProblem(reason), reason: reason,
                                                        offers: [.acknowledge, .leaveOut]))
                }
            }
            if batchFiles[item.file.sha256] == nil { batchFiles[item.file.sha256] = original }
            batch.add(.init(documentId: original.documentId, label: original.label, identity: identity))
        }
        try annotateClaims(&result, db: db)
        return result
    }

    /// Id of the issue of an item sharing a strong identity with a document whose figures differ.
    public static let correctedVersionIssueId = "correctedVersion"

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

    private struct Claim: Hashable {
        var transactionId: Int64
        var kind: DocumentKind
    }

    private static func annotateClaims(_ items: inout [ImportItem], db: Database) throws {
        // Items of one kind certain of the same transaction: the user decides (an invoice and
        // its transfer proof on one debit is normal).
        var claimants: [Claim: [(item: Int, link: Int)]] = [:]
        var order: [Claim] = []
        for i in items.indices {
            guard let kind = claimingKind(items[i]) else { continue }
            for (l, link) in items[i].links.enumerated() where link.entity.type == .transaction && link.confidence == .certain {
                let claim = Claim(transactionId: link.entity.id, kind: kind)
                if claimants[claim] == nil { order.append(claim) }
                claimants[claim, default: []].append((i, l))
            }
        }
        for claim in order {
            guard let claiming = claimants[claim], claiming.count >= 2 else { continue }
            let reason = "\(claiming.count) documents in this import claim the same transaction"
            for (i, l) in claiming {
                let link = items[i].links[l]
                items[i].links[l].confidence = .needsReview
                items[i].issues.append(ImportIssue(id: "sharedTransaction.\(claim.transactionId)",
                                                   kind: .chooseLink([LinkCandidate(entity: link.entity, label: link.label, reasons: link.reasons)]),
                                                   reason: reason, offers: [.fileWithoutLink]))
            }
        }
        // A certain link to a transaction that already has a document of the same kind: in the
        // library, or another item of this import linked to it (certain or not).
        for i in items.indices {
            // A corrected version filed only is linked where its original is, on purpose.
            guard let kind = claimingKind(items[i]), !ImportResolutions.isFiledAsCorrectedVersion(items[i]) else { continue }
            for link in items[i].links where link.entity.type == .transaction && link.confidence == .certain {
                var existing = try EvidenceLinks.documents(db: db, for: link.entity).first { $0.kind == kind }?.displayName
                if existing == nil {
                    existing = items.indices.first { j in
                        j != i && claimingKind(items[j]) == kind && items[j].links.contains { $0.entity == link.entity }
                    }.map { items[$0].file.fileName }
                }
                guard let existing else { continue }
                let reason = "That transaction already has \(article(kind.displayName)) (\(existing))"
                items[i].issues.append(ImportIssue(id: "transactionHasDocument.\(link.entity.id)", kind: .readerProblem(reason), reason: reason,
                                                   offers: [.acknowledge, .fileWithoutLink]))
            }
        }
    }

    /// "an insurance receipt", "a P60", "an IMI notice": lower case unless an acronym leads.
    static func article(_ name: String) -> String {
        let isAcronym = name.count >= 2 && name.prefix(2).allSatisfy { $0.isUppercase || $0.isNumber }
        let shown = isAcronym ? name : name.prefix(1).lowercased() + name.dropFirst()
        let first = shown.first.map(String.init) ?? ""
        let vowelSound = isAcronym ? "AEFHILMNORSX".contains(first) : "aeiou".contains(first)
        return (vowelSound ? "an " : "a ") + shown
    }
}

extension DocumentIdentityIndex {
    /// A library document's display name, by id.
    func name(of documentId: Int64) -> String? {
        byHash.values.first { $0.documentId == documentId }?.label
    }
}
