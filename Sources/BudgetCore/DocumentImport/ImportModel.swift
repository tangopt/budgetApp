import Foundation

/// What a file was recognised as.
public enum ImportKind: Hashable, Codable, Sendable {
    case rentReceiptsExport, rentReceiptPDF, transferAdvice, utilityInvoice
    case payrollForm(PayrollFormKind)
    case bankStatementCSV, bankStatementPDF, bbvaStatement
    case evidence(DocumentKind)
    case unknown

    public var displayName: String {
        switch self {
        case .rentReceiptsExport: return "Rent receipts export"
        case .rentReceiptPDF: return "Rent receipt"
        case .transferAdvice: return "Transfer advice"
        case .utilityInvoice: return "Utility invoice"
        case .payrollForm(let kind): return kind.displayName
        case .bankStatementCSV: return "Bank statement (CSV)"
        case .bankStatementPDF: return "Bank statement (PDF)"
        case .bbvaStatement: return "BBVA statement"
        case .evidence(let kind): return kind.displayName
        case .unknown: return "Unknown"
        }
    }
}

public enum ImportConfidence: String, Codable, Sendable {
    case certain, needsReview
}

public enum ImportFactSource: String, Codable, Sendable {
    case textLayer, ocr, fileName, intent, learntRule, model, user
    /// Taken from an existing record in the app (e.g. the amount of a matched bank credit).
    case matchedRecord

    /// Sources whose facts always need the user's eyes.
    public var alwaysNeedsReview: Bool { self == .ocr || self == .fileName || self == .model }
}

public enum ImportFigureField: String, Codable, CaseIterable, Sendable {
    case docDate, amount, currency, periodStart, periodEnd, invoiceNumber, receiptNumber, reference, issuer, person, taxYear, pay, taxDeducted

    public var displayName: String {
        switch self {
        case .docDate: return "Date"
        case .amount: return "Amount"
        case .currency: return "Currency"
        case .periodStart: return "Period start"
        case .periodEnd: return "Period end"
        case .invoiceNumber: return "Invoice number"
        case .receiptNumber: return "Receipt number"
        case .reference: return "Reference"
        case .issuer: return "Issuer"
        case .person: return "Person"
        case .taxYear: return "Tax year"
        case .pay: return "Pay"
        case .taxDeducted: return "Tax deducted"
        }
    }
}

public enum ImportFactValue: Equatable, Codable, Sendable {
    case date(Date), money(Int, Currency), text(String), year(Int)
}

public struct ImportFact: Equatable, Sendable {
    public var field: ImportFigureField
    public var value: ImportFactValue
    public var source: ImportFactSource
    public var confidence: ImportConfidence
    public var reason: String

    /// Facts read by OCR, from the file name or by the model are always `.needsReview`.
    public init(field: ImportFigureField, value: ImportFactValue, source: ImportFactSource,
                confidence: ImportConfidence, reason: String) {
        self.field = field
        self.value = value
        self.source = source
        self.confidence = source.alwaysNeedsReview ? .needsReview : confidence
        self.reason = reason
    }
}

public struct ImportRecognition: Equatable, Sendable {
    public var kind: ImportKind
    public var confidence: ImportConfidence
    public var reason: String

    public init(kind: ImportKind, confidence: ImportConfidence, reason: String) {
        self.kind = kind
        self.confidence = confidence
        self.reason = reason
    }
}

public struct ImportPlacement: Equatable, Sendable {
    public var metadata: EvidenceMetadata
    public var canonicalName: String

    public init(metadata: EvidenceMetadata, canonicalName: String) {
        self.metadata = metadata
        self.canonicalName = canonicalName
    }
}

public struct ProposedLink: Equatable, Sendable {
    public var entity: EvidenceEntity
    public var role: String?
    public var label: String
    public var confidence: ImportConfidence
    public var reasons: [String]
    public var madeByEffect: Bool
    /// Documents this one replaces on `entity` (from the intent): unlinked from it once the
    /// link is made (`ImportEffects.applyRecords`); they stay in the library.
    public var replacing: [Int64]

    public init(entity: EvidenceEntity, role: String? = nil, label: String, confidence: ImportConfidence,
                reasons: [String], madeByEffect: Bool = false, replacing: [Int64] = []) {
        self.entity = entity
        self.role = role
        self.label = label
        self.confidence = confidence
        self.reasons = reasons
        self.madeByEffect = madeByEffect
        self.replacing = replacing
    }
}

public enum ImportTargetKind: String, Sendable {
    case property, person, account, tenancy
    /// A utility provider (its invoice rules and property).
    case provider
}

/// What the user said the files are, when the entry point knows (plan 4 fills these in).
public struct ImportIntent: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public var entity: EvidenceEntity
        public var role: String?
        public var replacing: [Int64]

        public init(entity: EvidenceEntity, role: String? = nil, replacing: [Int64] = []) {
            self.entity = entity
            self.role = role
            self.replacing = replacing
        }
    }

    public var expected: ImportKind?
    public var propertyId: Int64?
    public var personId: Int64?
    public var accountId: Int64?
    public var taxYear: Int?
    public var target: Target?
    /// The utility provider whose invoice the files are (chosen in the review).
    public var providerId: Int64?

    public init(expected: ImportKind? = nil, propertyId: Int64? = nil, personId: Int64? = nil,
                accountId: Int64? = nil, taxYear: Int? = nil, target: Target? = nil, providerId: Int64? = nil) {
        self.expected = expected
        self.propertyId = propertyId
        self.personId = personId
        self.accountId = accountId
        self.taxYear = taxYear
        self.target = target
        self.providerId = providerId
    }

    public static let none = ImportIntent()
}

public enum ImportSection: String, CaseIterable, Sendable {
    case needsYou, ready, duplicates, leftOut
}

public struct ImportDuplicate: Equatable, Sendable {
    public enum Level: String, Sendable { case file, document, transactions }

    public var level: Level
    /// What it duplicates, as a whole sentence shown as it is ("Same file as a.pdf",
    /// "Already in the library as …", "3 rows already imported").
    public var of: String
    public var existingDocumentId: Int64?

    public init(level: Level, of: String, existingDocumentId: Int64? = nil) {
        self.level = level
        self.of = of
        self.existingDocumentId = existingDocumentId
    }
}

public struct LinkCandidate: Equatable, Sendable {
    public var entity: EvidenceEntity
    public var label: String
    public var reasons: [String]

    public init(entity: EvidenceEntity, label: String, reasons: [String]) {
        self.entity = entity
        self.label = label
        self.reasons = reasons
    }
}

public enum StatementIssue: Equatable, Sendable {
    case unknownAccount
    case noProfile(format: ImportFormat, accountId: Int64)
    case balanceMismatch(StatementMismatch)
    case unparsedLines([String])
}

public enum ImportIssueKind: Equatable, Sendable {
    case unknownKind(proposed: DocumentKind?)
    case kindMismatch(expected: ImportKind, found: ImportKind)
    case confirmFigure(ImportFigureField)
    case missingFigure(ImportFigureField)
    case chooseLink([LinkCandidate])
    case chooseTarget(ImportTargetKind, options: [Int64])
    case readerProblem(String)
    case filedYear(FiledYearImpact)
    case statement(StatementIssue)
}

public struct ImportIssue: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ImportIssueKind
    public var reason: String
    /// Resolutions the reader offers beyond the ones every issue of this kind has
    /// (e.g. `.fileWithoutLink` on a reader problem that is only a missing link).
    public var offers: [ImportResolution]
    /// Technical detail for a log or a bug report (e.g. the error behind a failed check); never shown as copy.
    public var detail: String?
    /// What "File the document only" (`.fileWithoutLink`) links the document to instead of its
    /// effect: for a corrected version of a recorded invoice or receipt, what the original is linked to.
    public var documentOnlyLinks: [ProposedLink]

    public init(id: String, kind: ImportIssueKind, reason: String, offers: [ImportResolution] = [], detail: String? = nil,
                documentOnlyLinks: [ProposedLink] = []) {
        self.id = id
        self.kind = kind
        self.reason = reason
        self.offers = offers
        self.detail = detail
        self.documentOnlyLinks = documentOnlyLinks
    }
}

public enum ImportResolution: Equatable, Sendable {
    case leaveOut
    case chooseKind(DocumentKind)
    case chooseLink(EvidenceEntity)
    case fileWithoutLink
    case confirmFigure(ImportFigureField, ImportFactValue)
    case chooseTarget(ImportTargetKind, Int64)
    case acknowledge
}

/// A UK bank statement's rows to add to its account (`ImportCoordinator.commit`), its closing
/// balance check, and the account's empty sort code / account number to fill from the file.
public struct UKStatementEffect: Equatable, Sendable {
    public var accountId: Int64
    public var sourceFileName: String
    /// The rows to add (duplicates of saved rows already left out), categorised by saved rules only.
    public var staged: [StagedTransaction]
    /// The closing balance checked on commit (never adjusted here).
    public var statement: StatementFinish?
    public var accountFill: StatementAccountFill?
    /// Rows an earlier statement of this import holds too (its staged rows): shown as already
    /// imported, and added with this statement only when no row with their fingerprint is
    /// saved by then (that statement was left out).
    public var batchOverlap: [StagedTransaction]

    public init(accountId: Int64, sourceFileName: String, staged: [StagedTransaction], statement: StatementFinish?,
                accountFill: StatementAccountFill?, batchOverlap: [StagedTransaction] = []) {
        self.accountId = accountId
        self.sourceFileName = sourceFileName
        self.staged = staged
        self.statement = statement
        self.accountFill = accountFill
        self.batchOverlap = batchOverlap
    }

    /// Every row as suggested, learning no rule (categorising beyond rules happens later in the
    /// Uncategorized screen); a row replacing a manual entry keeps that entry's note.
    public var decisions: [ImportDecision] { Self.decisions(for: staged) }

    static func decisions(for rows: [StagedTransaction]) -> [ImportDecision] {
        rows.map { ImportDecision(stagedId: $0.id, finalCategoryId: $0.suggestedCategoryId, learnRule: false, note: $0.replacesManual?.note) }
    }
}

/// What confirming an item does besides filing the document.
public enum ImportEffect: Equatable, Sendable {
    case file
    case rentReceiptsExport(propertyId: Int64, rows: [RentReceiptsExport.Row])
    case rentReceiptPDF(RentReceiptPDFs.Item)
    case transferAdvice(RentCreditEvidence.AdvicePlanItem)
    case utilityInvoice(UtilityInvoice)
    case payrollForm(PayrollFormImport.Confirmed)
    case ukStatement(UKStatementEffect)
    case none

    /// Whether applying it can move a figure that may sit on a filed return (anything beyond
    /// filing the document: a linked document can move a cost between years too).
    public var mayChangeTaxFigures: Bool {
        switch self {
        case .rentReceiptsExport, .utilityInvoice, .payrollForm, .ukStatement, .rentReceiptPDF, .transferAdvice: return true
        case .file, .none: return false
        }
    }
}

public struct ImportItem: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var file: ImportFile
    public var recognition: ImportRecognition
    public var title: String
    public var facts: [ImportFact]
    public var placement: ImportPlacement?
    public var links: [ProposedLink]
    public var effect: ImportEffect
    public var issues: [ImportIssue]
    public var duplicate: ImportDuplicate?
    public var informationChanges: [FiledYearImpact]
    public var parentId: UUID?
    public var isLeftOut: Bool
    public var groupKey: String
    /// Lines shown with the item that don't hold it back (e.g. "Not linked: no matching transaction yet").
    public var notes: [String]
    /// The utility provider the file was read as, kept for its duplicate identity (invoice
    /// number per provider) when its effect no longer records the invoice (a corrected version
    /// filed as a document only). Nil: the effect's provider, if any.
    public var identityProviderId: Int64?

    public init(id: UUID = UUID(), file: ImportFile, recognition: ImportRecognition, title: String,
                facts: [ImportFact] = [], placement: ImportPlacement? = nil, links: [ProposedLink] = [],
                effect: ImportEffect = .file, issues: [ImportIssue] = [], duplicate: ImportDuplicate? = nil,
                informationChanges: [FiledYearImpact] = [], parentId: UUID? = nil, isLeftOut: Bool = false,
                groupKey: String = "", notes: [String] = []) {
        self.id = id
        self.file = file
        self.recognition = recognition
        self.title = title
        self.facts = facts
        self.placement = placement
        self.links = links
        self.effect = effect
        self.issues = issues
        self.duplicate = duplicate
        self.informationChanges = informationChanges
        self.parentId = parentId
        self.isLeftOut = isLeftOut
        self.groupKey = groupKey
        self.notes = notes
    }

    /// Left out wins, then duplicate; otherwise anything unsure is Needs you.
    public var section: ImportSection {
        if isLeftOut { return .leftOut }
        if duplicate != nil { return .duplicates }
        return needsYouReasons.isEmpty ? .ready : .needsYou
    }

    /// Why the item is not ready, in the order issues, recognition, facts, links.
    public var needsYouReasons: [String] {
        var reasons = issues.map(\.reason)
        if recognition.confidence == .needsReview { reasons.append(recognition.reason) }
        for fact in facts where fact.confidence == .needsReview {
            switch fact.source {
            case .ocr: reasons.append("\(fact.field.displayName) read by text recognition: check it")
            case .fileName: reasons.append("\(fact.field.displayName) taken from the file name: check it")
            case .model: reasons.append("\(fact.field.displayName) suggested by the model: check it")
            default: reasons.append(fact.reason)
            }
        }
        // A link an issue already asks about (a choice offering it) says so once.
        let asked = Set(issues.flatMap { issue -> [EvidenceEntity] in
            if case .chooseLink(let candidates) = issue.kind { return candidates.map(\.entity) }
            return []
        })
        for link in links where link.confidence == .needsReview && !asked.contains(link.entity) {
            reasons.append("Link to \(link.label): check it")
        }
        return reasons
    }
}

public struct ImportReadyGroup: Equatable, Identifiable, Sendable {
    /// The group key.
    public var id: String
    public var title: String
    public var summary: String
    public var itemIds: [UUID]

    public init(id: String, title: String, summary: String, itemIds: [UUID]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.itemIds = itemIds
    }
}

public struct ImportPlan: Equatable, Sendable {
    public var items: [ImportItem]
    public var ignoredFiles: [String]
    /// What the pipeline remembers between resolutions (`ImportPipeline`).
    var state = ImportPlanState()

    public init(items: [ImportItem], ignoredFiles: [String] = []) {
        self.items = items
        self.ignoredFiles = ignoredFiles
    }

    public func items(in section: ImportSection) -> [ImportItem] {
        items.filter { $0.section == section }
    }

    /// Ready items grouped by group key, in order of first appearance.
    public var readyGroups: [ImportReadyGroup] {
        var order: [String] = []
        var byKey: [String: [ImportItem]] = [:]
        for item in items(in: .ready) {
            if byKey[item.groupKey] == nil { order.append(item.groupKey) }
            byKey[item.groupKey, default: []].append(item)
        }
        return order.map { key in
            let members = byKey[key] ?? []
            return ImportReadyGroup(id: key, title: key, summary: Self.summary(members), itemIds: members.map(\.id))
        }
    }

    /// "3 rent receipts → linked to their receipts", "2 utility invoices → 1 linked, 1 filed
    /// unlinked", "1 receipts export → 2 receipts, 1 cancelled", "2 transfer advices → linked to
    /// their credits", "1 P60 → employment 2022/23", "1 statement → 3 transactions", "2 insurance
    /// receipt documents → filed"; any other mix "<n> files".
    static func summary(_ members: [ImportItem]) -> String {
        let n = members.count
        func count(_ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        let kinds = members.map(\.recognition.kind)

        let statements = members.compactMap { item -> UKStatementEffect? in
            if case .ukStatement(let effect) = item.effect { return effect }
            return nil
        }
        if !statements.isEmpty, statements.count == n {
            let rows = statements.reduce(0) { $0 + $1.staged.count }
            return "\(count("statement", "statements")) → \(rows) transaction\(rows == 1 ? "" : "s")"
        }
        if kinds.allSatisfy({ $0 == .rentReceiptPDF }) {
            return n == 1 ? "1 rent receipt → linked to its receipt" : "\(n) rent receipts → linked to their receipts"
        }
        if kinds.allSatisfy({ $0 == .utilityInvoice }) {
            let linked = members.filter { item in
                if case .utilityInvoice(let invoice) = item.effect { return invoice.transactionId != nil }
                return false
            }.count
            let invoices = count("utility invoice", "utility invoices")
            if linked == n { return n == 1 ? "1 utility invoice → linked to its debit" : "\(invoices) → linked to their debits" }
            if linked == 0 { return "\(invoices) → filed unlinked" }
            return "\(invoices) → \(linked) linked, \(n - linked) filed unlinked"
        }
        if kinds.allSatisfy({ $0 == .rentReceiptsExport }) {
            let rows = members.flatMap { item -> [RentReceiptsExport.Row] in
                if case .rentReceiptsExport(_, let rows) = item.effect { return rows }
                return []
            }
            let cancelled = rows.filter { $0.status == .cancelled }.count
            return "\(count("receipts export", "receipts exports")) → \(rows.count) receipt\(rows.count == 1 ? "" : "s")"
                + (cancelled > 0 ? ", \(cancelled) cancelled" : "")
        }
        if kinds.allSatisfy({ $0 == .transferAdvice }) {
            return n == 1 ? "1 transfer advice → linked to its credit" : "\(n) transfer advices → linked to their credits"
        }
        let forms = kinds.compactMap { kind -> PayrollFormKind? in
            if case .payrollForm(let form) = kind { return form }
            return nil
        }
        if forms.count == n {
            var names: [String] = []
            for form in forms where !names.contains(form.displayName) { names.append(form.displayName) }
            var years: [Int] = []
            for item in members {
                var year: Int?
                if case .payrollForm(let confirmed) = item.effect { year = confirmed.startYear }
                if year == nil, case .year(let fact)? = item.facts.first(where: { $0.field == .taxYear })?.value { year = fact }
                if let year, !years.contains(year) { years.append(year) }
            }
            let what = "\(n) \(names.joined(separator: "/"))\(n > 1 && names.count == 1 ? "s" : "")"
            let labels = years.sorted().map { UKTaxYear(startYear: $0).label }
            return labels.isEmpty ? "\(what) → employment" : "\(what) → employment\(labels.count > 1 ? "s" : "") \(labels.joined(separator: ", "))"
        }
        let documentKinds = kinds.compactMap { kind -> DocumentKind? in
            if case .evidence(let documentKind) = kind { return documentKind }
            return nil
        }
        if documentKinds.count == n, let first = documentKinds.first {
            let named = documentKinds.allSatisfy { $0 == first } ? Self.lowercasedName(first.displayName) + " " : ""
            return "\(n) \(named)document\(n == 1 ? "" : "s") → filed"
        }
        return count("file", "files")
    }

    /// "insurance receipt", "IMI notice": lower case unless an acronym leads.
    private static func lowercasedName(_ name: String) -> String {
        let isAcronym = name.count >= 2 && name.prefix(2).allSatisfy { $0.isUppercase || $0.isNumber }
        return isAcronym ? name : name.prefix(1).lowercased() + name.dropFirst()
    }

    /// Nothing waits for the user and something is ready.
    public var canConfirm: Bool {
        items(in: .needsYou).isEmpty && !items(in: .ready).isEmpty
    }
}

/// What the pipeline keeps with a plan so that resolutions can re-read items and re-run the
/// batch checks: each item's intent, the batch duplicate pass's marks and what the user
/// acknowledged of them, and the items whose kind the user chose.
struct ImportPlanState: Equatable, Sendable {
    /// The intent each item was read with (a chosen target added to it).
    var intents: [UUID: ImportIntent] = [:]
    /// The intent each item was planned with (the entry point's shortcut), before any target
    /// was chosen in the review: what a new kind is read with.
    var plannedIntents: [UUID: ImportIntent] = [:]
    /// Items the duplicate pass (not their reader) marked as duplicates.
    var batchDuplicates: Set<UUID> = []
    /// Duplicate-pass issue ids the user settled, per item (the pass would raise them again).
    var settled: [UUID: Set<String>] = [:]
    /// Items whose kind the user chose (no intent mismatch is raised on them).
    var chosenKinds: Set<UUID> = []
}

extension ImportItem {
    /// Whether the filed-year guard holds the item (a filed return would move, or it couldn't
    /// be checked against them): its only resolution is to leave it out.
    public var isHeldByFiledYear: Bool {
        issues.contains { issue in
            if case .filedYear = issue.kind { return true }
            return issue.id == FiledYearGuard.checkFailedIssueId
        }
    }
}
