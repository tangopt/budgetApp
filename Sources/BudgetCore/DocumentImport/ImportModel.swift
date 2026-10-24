import Foundation

/// What a file was recognised as.
public enum ImportKind: Hashable, Codable, Sendable {
    case rentReceiptsExport, rentReceiptPDF, transferAdvice, utilityInvoice
    case payrollForm(PayrollFormKind)
    case bankStatementCSV, bankStatementPDF, bbvaStatement
    case evidence(DocumentKind)
    /// A custom kind (spec 2026-10-24 §2), saved or pending in the review: read like
    /// `.evidence(.other)`, then named and filed as the custom kind.
    case customEvidence(CustomKindKey)
    case unknown

    /// The kind's name; a custom kind's needs the catalog and the review's pending kinds
    /// (`ImportKindNames`): here "Custom kind".
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
        case .customEvidence: return "Custom kind"
        case .unknown: return "Unknown"
        }
    }

    /// The custom kind it is, if it is one.
    public var customKindKey: CustomKindKey? {
        if case .customEvidence(let key) = self { return key }
        return nil
    }
}

/// A custom kind as the review knows it: saved (`customDocumentKind` id) or created in this
/// review and saved only at Confirm (`PendingDocumentKind.id`).
public enum CustomKindKey: Hashable, Codable, Sendable {
    case saved(Int64)
    case pending(UUID)

    /// The saved kind's id (nil for a pending one).
    public var savedId: Int64? {
        if case .saved(let id) = self { return id }
        return nil
    }

    /// The kind token the duplicate rules compare: `"custom:<id>"`, `"pending:<uuid>"`.
    var token: String {
        switch self {
        case .saved(let id): return "custom:\(id)"
        case .pending(let id): return "pending:\(id.uuidString)"
        }
    }
}

/// A kind made with "New kind…" in the review: part of the plan until Confirm inserts it
/// (Discard forgets it).
public struct PendingDocumentKind: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var area: DocumentArea

    public init(id: UUID = UUID(), name: String, area: DocumentArea) {
        self.id = id
        self.name = name
        self.area = area
    }
}

/// A custom kind's name and area as an item is named and filed with them.
public struct ImportCustomKind: Equatable, Sendable {
    public var key: CustomKindKey
    public var name: String
    public var area: DocumentArea

    public init(key: CustomKindKey, name: String, area: DocumentArea) {
        self.key = key
        self.name = name
        self.area = area
    }
}

/// The custom kinds a review can name: the saved ones in use (`DocumentKindCatalog`) and the
/// review's pending ones.
public struct ImportKindNames: Equatable, Sendable {
    public var kinds: [CustomKindKey: ImportCustomKind]

    public init(catalog: DocumentKindCatalog, pending: [PendingDocumentKind]) {
        var kinds: [CustomKindKey: ImportCustomKind] = [:]
        for kind in catalog.customKinds {
            guard let id = kind.id else { continue }
            kinds[.saved(id)] = ImportCustomKind(key: .saved(id), name: kind.name, area: kind.area)
        }
        for kind in pending { kinds[.pending(kind.id)] = ImportCustomKind(key: .pending(kind.id), name: kind.name, area: kind.area) }
        self.kinds = kinds
    }

    public init(_ kinds: [CustomKindKey: ImportCustomKind] = [:]) {
        self.kinds = kinds
    }

    public subscript(key: CustomKindKey) -> ImportCustomKind? { kinds[key] }

    /// The kind's name: a custom kind's from the catalog or the review, else its own.
    public func displayName(_ kind: ImportKind) -> String {
        if case .customEvidence(let key) = kind, let custom = kinds[key] { return custom.name }
        return kind.displayName
    }

    /// The names by duplicate token (`CustomKindKey.token`), for the duplicate wording.
    var byToken: [String: String] {
        Dictionary(uniqueKeysWithValues: kinds.map { ($0.key.token, $0.value.name) })
    }
}

/// One kind the review's chooser offers (built-ins, saved custom kinds, then the review's
/// pending ones), with its label.
public struct ImportKindChoice: Hashable, Sendable {
    public var kind: ImportKind
    public var label: String

    public init(kind: ImportKind, label: String) {
        self.kind = kind
        self.label = label
    }

    /// The answer that files an item as it.
    public var resolution: ImportResolution? {
        switch kind {
        case .evidence(let builtIn): return .chooseKind(builtIn)
        case .customEvidence(let key): return .chooseCustomKind(key)
        default: return nil
        }
    }

    /// The label of the choice `name` would repeat, ignoring case, accents and surrounding spaces
    /// (as "New kind…" refuses it, `ImportResolutionError.kindNameTaken`); nil when it is free or blank.
    public static func takenName(_ name: String, among choices: [ImportKindChoice]) -> String? {
        let key = DocumentKindCatalog.key(name)
        guard !key.isEmpty else { return nil }
        return choices.first { DocumentKindCatalog.key($0.label) == key }?.label
    }

    /// The built-in kinds by name, the saved custom kinds by name, then `pending` by name.
    public static func choices(catalog: DocumentKindCatalog, pending: [PendingDocumentKind]) -> [ImportKindChoice] {
        func ordered(_ a: ImportKindChoice, _ b: ImportKindChoice) -> Bool { a.label.localizedStandardCompare(b.label) == .orderedAscending }
        let builtIns = DocumentKind.allCases.map { ImportKindChoice(kind: .evidence($0), label: $0.displayName) }.sorted(by: ordered)
        let saved = catalog.customKinds.compactMap { kind in kind.id.map { ImportKindChoice(kind: .customEvidence(.saved($0)), label: kind.name) } }
        let review = pending.map { ImportKindChoice(kind: .customEvidence(.pending($0.id)), label: $0.name) }.sorted(by: ordered)
        return builtIns + saved + review
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
    case docDate, amount, currency, periodStart, periodEnd, invoiceNumber, receiptNumber, reference, issuer, person, taxYear, pay, taxDeducted, taxCode
    /// A statement's opening and closing balances, its row count, and its preview lines
    /// (a BBVA statement's mortgage instalments and fund).
    case openingBalance, closingBalance, rows, instalments, fund
    /// A utility invoice's customer-account balance, debited instead of its own value (it
    /// includes earlier invoices or credits): kept apart from the amount.
    case accountTotal

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
        case .taxCode: return "Tax code"
        case .openingBalance: return "Opening balance"
        case .closingBalance: return "Closing balance"
        case .rows: return "Rows"
        case .instalments: return "Instalments"
        case .fund: return "Fund"
        case .accountTotal: return "Account total debited"
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
    /// A model figure the user accepted (`.user` now): kept when the item is read again, as the
    /// reader can't read it (`ImportModelProposals.carry`).
    public var fromModel = false

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
    /// The learnt `documentKind` rule that recognised the file (`ImportLearning.recogniser`), if one did.
    public var ruleId: Int64?
    /// The kind is the on-device model's guess (`ImportModelProposals`): to check while
    /// `.needsReview`, the user's once accepted.
    public var proposedByModel = false

    public init(kind: ImportKind, confidence: ImportConfidence, reason: String, ruleId: Int64? = nil) {
        self.kind = kind
        self.confidence = confidence
        self.reason = reason
        self.ruleId = ruleId
    }
}

/// A learnt rule applied to an item, named on it ("Learnt: Demo Power → Utility invoice");
/// marked used on Confirm import.
public struct ImportRuleUse: Equatable, Sendable {
    public var ruleId: Int64
    public var kind: ImportRuleKind
    public var label: String

    public init(ruleId: Int64, kind: ImportRuleKind, label: String) {
        self.ruleId = ruleId
        self.kind = kind
        self.label = label
    }
}

/// A rule a correction in the review would teach (`ImportLearning.drafts`): learnt on Confirm
/// import, inside the run (`ImportRuleStore.learn`), only for applied items.
public struct ImportRuleDraft: Equatable, Sendable {
    public var kind: ImportRuleKind
    public var key: String
    public var matchLabel: String
    public var actionJSON: String
    public var actionLabel: String
    /// The action of the learnt rule this draft will replace (its label), when there is one that
    /// does something else: "Will remember … (replaces: …)".
    public var replaces: String?
    /// A `documentKind` draft for a kind made in this review: its action names no kind yet
    /// (`{"kind":"other"}`); Confirm import fills in the id the kind is saved with.
    public var pendingKindId: UUID?

    public init(kind: ImportRuleKind, key: String, matchLabel: String, actionJSON: String, actionLabel: String, replaces: String? = nil,
                pendingKindId: UUID? = nil) {
        self.kind = kind
        self.key = key
        self.matchLabel = matchLabel
        self.actionJSON = actionJSON
        self.actionLabel = actionLabel
        self.replaces = replaces
        self.pendingKindId = pendingKindId
    }

    /// What the draft does, as compared between drafts: its action, and the pending kind it names.
    var actionIdentity: String {
        pendingKindId.map { "\(actionJSON)#pending:\($0.uuidString)" } ?? actionJSON
    }
}

public struct ImportPlacement: Equatable, Sendable {
    public var metadata: EvidenceMetadata
    public var canonicalName: String
    /// The custom kind it is filed as (its name and area), kept so the placement can be worked
    /// out again from the facts (`ImportNaming.placement(customKind:)`).
    public var customKind: ImportCustomKind?

    public init(metadata: EvidenceMetadata, canonicalName: String, customKind: ImportCustomKind? = nil) {
        self.metadata = metadata
        self.canonicalName = canonicalName
        self.customKind = customKind
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
    /// A recorded utility invoice: the one a document of it is attached to.
    case invoice
}

/// What the user said the files are, when the entry point knows (`ImportShortcut.intent`).
/// Intents are per file: each item keeps the one of the call that brought it (`ImportPlan.intent(of:)`).
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
    /// The recorded utility invoice a file is a document of (chosen in the review when several
    /// fit): attached to it, never recorded again.
    public var invoiceId: Int64?
    /// The accounts chosen in the review for a statement's current account, mortgage or fund
    /// (`ImportResolution.chooseAccount`); learnt for files like it on Confirm import.
    public var statementAccounts: [StatementAccountRole: Int64]
    /// The layout mapped in the review for a statement's account (`ImportResolution.saveProfile`):
    /// read with it, saved on Confirm import.
    public var statementProfile: ImportProfile?
    /// "Edit column mapping…": the statement's saved mapping is asked again, prefilled
    /// (`StatementIssue.remap`), until one is mapped in the review (`statementProfile`).
    public var remapStatement: Bool
    /// The shortcut the files came from (`ImportShortcut.entryPoint`), when one did.
    public var entryPoint: String?
    /// `expected` names a library document kind (`.evidence`) that any reader's kind of that
    /// document matches (Missing evidence ▸ Add: a P60 read by the payroll reader is the P60 the
    /// item asks for; a BBVA extrato or a CSV is a bank statement).
    public var expectedByDocumentKind = false
    /// The name of the custom kind `expected` names (set when the files are planned), for the
    /// mismatch wording ("Expected a <name>…").
    public var expectedKindName: String?
    /// The period the target record asks a document for (`[start, end)`; Missing evidence ▸ Add's
    /// slot): a filed document without period facts gets it (`ImportPipeline.withIntentPeriod`).
    public var period: DateInterval?

    public init(expected: ImportKind? = nil, propertyId: Int64? = nil, personId: Int64? = nil,
                accountId: Int64? = nil, taxYear: Int? = nil, target: Target? = nil, providerId: Int64? = nil,
                statementAccounts: [StatementAccountRole: Int64] = [:], statementProfile: ImportProfile? = nil,
                remapStatement: Bool = false, entryPoint: String? = nil) {
        self.expected = expected
        self.propertyId = propertyId
        self.personId = personId
        self.accountId = accountId
        self.taxYear = taxYear
        self.target = target
        self.providerId = providerId
        self.statementAccounts = statementAccounts
        self.statementProfile = statementProfile
        self.remapStatement = remapStatement
        self.entryPoint = entryPoint
    }

    public static let none = ImportIntent()

    /// Why a file is linked to the intent's target (`label`): "You added it from <entry point>",
    /// or "You added it to <label>" when no shortcut is named.
    func targetReason(label: String) -> String {
        entryPoint.map { "You added it from \($0)" } ?? "You added it to \(label)"
    }
}

public enum ImportSection: String, CaseIterable, Sendable {
    case needsYou, ready, duplicates, leftOut
}

public struct ImportDuplicate: Equatable, Sendable {
    public enum Level: String, Sendable { case file, document, transactions }

    public var level: Level
    /// What it duplicates, as a whole sentence shown as it is ("Identical file: same as a.pdf in this import",
    /// "Identical file: already in the library as …", "3 rows already imported").
    public var of: String
    public var existingDocumentId: Int64?
    /// The item of the same import it duplicates, when its original is in the batch and not yet
    /// in the library: Confirm import gives it that item's document (a source folder's record).
    public var originalItemId: UUID?

    public init(level: Level, of: String, existingDocumentId: Int64? = nil, originalItemId: UUID? = nil) {
        self.level = level
        self.of = of
        self.existingDocumentId = existingDocumentId
        self.originalItemId = originalItemId
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

/// Which of a statement's accounts: the current account its rows are on, or the mortgage or
/// fund its instalments and subscriptions are the other side of.
public enum StatementAccountRole: String, Codable, Sendable {
    case current, mortgage, fund
}

public enum StatementIssue: Equatable, Sendable {
    case unknownAccount
    case noProfile(format: ImportFormat, accountId: Int64)
    case balanceMismatch(StatementMismatch)
    case unparsedLines([String])
    /// The statement's mortgage instalments or fund have no account to go to.
    case unknownLinkedAccount(StatementAccountRole)
    /// A row that looks like a saved one of another import (Task 5).
    case possibleDuplicate(existingTransactionId: Int64, existingLabel: String)
    /// An instalment debit without its settled receipt, or a receipt without its debit.
    case instalmentMismatch(String)
    /// A fund movement without its subscription debit (or the reverse), or a fund already
    /// valued on the period end at another balance.
    case fundMismatch(String)
    /// "Edit column mapping…": the saved mapping asked again (offered as `.saveProfile` to start
    /// from), answered with the mapping set up in the review.
    case remap(format: ImportFormat, accountId: Int64)
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
    /// The on-device model proposed what the document is or says (`ImportModelProposals`): its
    /// `.model` facts and recognition wait for the user — accepted (`.acceptModelReading`) or
    /// corrected field by field.
    case confirmModelReading
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
    /// What "File the document only" does besides filing it (nil: nothing): for a corrected
    /// version of a recorded invoice without a document, attaches it to that invoice.
    public var documentOnlyEffect: ImportEffect?

    public init(id: String, kind: ImportIssueKind, reason: String, offers: [ImportResolution] = [], detail: String? = nil,
                documentOnlyLinks: [ProposedLink] = [], documentOnlyEffect: ImportEffect? = nil) {
        self.id = id
        self.kind = kind
        self.reason = reason
        self.offers = offers
        self.detail = detail
        self.documentOnlyLinks = documentOnlyLinks
        self.documentOnlyEffect = documentOnlyEffect
    }
}

public enum ImportResolution: Equatable, Sendable {
    case leaveOut
    case chooseKind(DocumentKind)
    /// A custom kind, saved or pending in the review (spec 2026-10-24 §2).
    case chooseCustomKind(CustomKindKey)
    /// "New kind…": a pending kind added to the plan, then chosen as `.chooseCustomKind(.pending(id))`.
    /// Refused when a built-in, a saved custom kind or another pending kind has the name
    /// (ignoring case and accents): `ImportResolutionError.kindNameTaken`.
    case createKind(name: String, area: DocumentArea)
    case chooseLink(EvidenceEntity)
    case fileWithoutLink
    case confirmFigure(ImportFigureField, ImportFactValue)
    case chooseTarget(ImportTargetKind, Int64)
    case acknowledge
    /// A P11D's benefit rows as the user set them (kind and amount per row, rows added or
    /// removed): the payroll effect's benefits; counts as checking the benefits.
    case setBenefits([PayrollFormExtraction.Benefit])
    /// The account for a statement's role (`unknownAccount`: `.current`; `unknownLinkedAccount`).
    case chooseAccount(StatementAccountRole, Int64)
    /// Import a statement whose closing balance doesn't match, with the user's reason (Task 5).
    case importAnyway(reason: String)
    /// Keep or skip a possible duplicate row (Task 5).
    case keepRow
    case skipRow
    /// Read the statement with this (not yet saved) profile (Task 6).
    case saveProfile(ImportProfile)
    /// The document's transactions become these (one or more, the user's choice from a
    /// search), replacing the transaction links proposed; all of them are its payments.
    case linkTransactions([Int64])
    /// One more transaction the user chose, beside the item's certain links (the unsure
    /// transaction links it didn't keep are dropped, and its "which one?" questions about
    /// transactions answered, as with `.linkTransactions`).
    case addTransactionLink(Int64)
    /// A link (proposed or chosen) removed.
    case unlink(EvidenceEntity)
    /// The issuer's name, as the user gave it (learnt for the issuer on Confirm import).
    case setIssuer(String)
    /// `.confirmFigure`, and "Remember for this issuer": where the figure sits on the page (its
    /// label, never the value) is learnt for the issuer on Confirm import (`LearntFigures`).
    case confirmFigureRemembering(ImportFigureField, ImportFactValue)
    /// What the on-device model read, taken as it is: its facts and kind become the user's
    /// (learnt for the issuer on Confirm import).
    case acceptModelReading
    /// A "Check it" ticked off without retyping (`ImportChecks`): the figure or recognition
    /// becomes the user's, "Checked by you".
    case markChecked(ImportCheckTarget)
    /// A tick taken back while the review is open: exactly what was there before.
    case unmarkChecked(ImportCheckTarget)
    /// Every "Check it" of the document ticked off at once (`ImportChecks.tickable`): never a
    /// question that needs a choice.
    case markAllChecked
    /// The ticks "Mark all as checked" made, taken back together.
    case unmarkAllChecked
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
    /// Rows the user skipped in the review (possible duplicates): not added.
    public var skipped: [StagedTransaction]
    /// The fingerprints of the statement's rows already saved (certain duplicates): the saved
    /// rows they match are never another row's lookalike (`StatementChecks`).
    public var certainDuplicates: [String] = []
    /// The account chosen in the review for files like this one (`StatementSignature`): learnt
    /// on Confirm import, inside the run.
    public var learnAccount: LearntAccount?
    /// The layout mapped in the review: saved on Confirm import, before the rows.
    public var profileToSave: ImportProfile?
    /// The learnt rule that named the account: marked used on Confirm import.
    public var rememberedRuleId: Int64?

    /// A statement file signature's key and label, and the account chosen for it.
    public struct LearntAccount: Equatable, Sendable {
        public var key: String
        public var label: String
        public var accountId: Int64

        public init(key: String, label: String, accountId: Int64) {
            self.key = key
            self.label = label
            self.accountId = accountId
        }
    }

    public init(accountId: Int64, sourceFileName: String, staged: [StagedTransaction], statement: StatementFinish?,
                accountFill: StatementAccountFill?, skipped: [StagedTransaction] = []) {
        self.accountId = accountId
        self.sourceFileName = sourceFileName
        self.staged = staged
        self.statement = statement
        self.accountFill = accountFill
        self.skipped = skipped
    }

    /// Every row as suggested, learning no rule (categorising beyond rules happens later in the
    /// Uncategorized screen); a row replacing a manual entry keeps that entry's note.
    public var decisions: [ImportDecision] { Self.decisions(for: staged) }

    static func decisions(for rows: [StagedTransaction]) -> [ImportDecision] {
        rows.map { ImportDecision(stagedId: $0.id, finalCategoryId: $0.suggestedCategoryId, learnRule: false, note: $0.replacesManual?.note) }
    }
}

/// A BBVA Portugal "extrato global": the current account's new rows (certain duplicates left
/// out, categorised by saved rules and transfer legs only), the instalments and subscriptions
/// paired on them (`movementIndex` indexes `staged`), the closing balance checked, and the
/// accounts chosen in the review, learnt on Confirm import.
public struct BBVAStatementEffect: Equatable, Sendable {
    public var statement: BBVAStatementParser.Statement
    public var currentAccountId: Int64
    public var loanAccountId: Int64?
    public var fundAccountId: Int64?
    public var staged: [StagedTransaction]
    public var instalments: [BBVAStatementLegs.InstalmentMatch]
    public var fundPairs: [BBVAStatementLegs.FundPair]
    public var closing: StatementClosing
    public var sourceFileName: String
    public var learnAccounts: [StatementAccountRole: Int64]
    /// Interest rows the fund/mortgage tool estimated ("Mortgage interest (derived)") for an
    /// instalment already imported, whose receipt on this statement splits it otherwise: each
    /// replaced by the receipt's split on Confirm import (the item asks first: "Replace the estimate?").
    public var estimates: [Estimate]
    /// What the earlier statements of the import (same mortgage, not left out) move the loan by
    /// on their receipts' days, counted in this statement's mortgage check while they aren't
    /// saved (`StatementChecks.recheck`), as `batchRows` is for the current account.
    public var batchLoan: [BatchLoanRow]
    /// Rows the user skipped in the review (possible duplicates): not added, no legs.
    public var skipped: [StagedTransaction] = []
    /// The fingerprints of the statement's rows already saved (as `UKStatementEffect.certainDuplicates`).
    public var certainDuplicates: [String] = []
    /// The learnt rules that named its accounts: marked used on Confirm import.
    public var rememberedRuleIds: [Int64] = []
    /// The fund's Market movement on the period end that confirming it adds (none valued that
    /// day yet, and the saved balance with its fund legs isn't the statement's value): an
    /// otherwise fully imported statement still adds it.
    public var marketMovementMinorUnits: Int?

    /// An earlier statement's net move of the loan on a receipt's day: an instalment's
    /// +capital (its debit's `fingerprint` on `accountId` saved means it's written) or an
    /// estimate's replacement (`estimateId` no longer the derived row means it's written).
    public struct BatchLoanRow: Equatable, Sendable {
        public var date: Date
        public var amountMinorUnits: Int
        public var accountId: Int64
        public var fingerprint: String?
        public var estimateId: Int64?

        public init(date: Date, amountMinorUnits: Int, accountId: Int64, fingerprint: String? = nil, estimateId: Int64? = nil) {
            self.date = date
            self.amountMinorUnits = amountMinorUnits
            self.accountId = accountId
            self.fingerprint = fingerprint
            self.estimateId = estimateId
        }
    }

    /// A saved estimated interest row and the receipt that settles its instalment.
    public struct Estimate: Equatable, Sendable {
        public var transactionId: Int64
        public var receipt: BBVAStatementParser.LoanReceipt

        public init(transactionId: Int64, receipt: BBVAStatementParser.LoanReceipt) {
            self.transactionId = transactionId
            self.receipt = receipt
        }
    }

    public init(statement: BBVAStatementParser.Statement, currentAccountId: Int64, loanAccountId: Int64?, fundAccountId: Int64?,
                staged: [StagedTransaction], instalments: [BBVAStatementLegs.InstalmentMatch], fundPairs: [BBVAStatementLegs.FundPair],
                closing: StatementClosing, sourceFileName: String, learnAccounts: [StatementAccountRole: Int64] = [:],
                estimates: [Estimate] = [], batchLoan: [BatchLoanRow] = []) {
        self.statement = statement
        self.currentAccountId = currentAccountId
        self.loanAccountId = loanAccountId
        self.fundAccountId = fundAccountId
        self.staged = staged
        self.instalments = instalments
        self.fundPairs = fundPairs
        self.closing = closing
        self.sourceFileName = sourceFileName
        self.learnAccounts = learnAccounts
        self.estimates = estimates
        self.batchLoan = batchLoan
    }
}

/// What confirming an item does besides filing the document.
public enum ImportEffect: Equatable, Sendable {
    case file
    case rentReceiptsExport(propertyId: Int64, rows: [RentReceiptsExport.Row])
    case rentReceiptPDF(RentReceiptPDFs.Item)
    case transferAdvice(RentCreditEvidence.AdvicePlanItem)
    case utilityInvoice(UtilityInvoice)
    /// The document attached to a utility invoice already recorded without one (its
    /// `documentId`): no figure of the invoice changes (`UtilityInvoiceIntake.attach`).
    case attachToInvoice(invoiceId: Int64)
    case payrollForm(PayrollFormImport.Confirmed)
    case ukStatement(UKStatementEffect)
    case bbvaStatement(BBVAStatementEffect)
    case none

    /// Whether the effect is only a link of the document (a rent receipt PDF to its receipt, an
    /// advice to its credits): without the link only the document is filed.
    public var isLinking: Bool {
        switch self {
        case .rentReceiptPDF, .transferAdvice: return true
        default: return false
        }
    }

    /// Whether applying it can move a figure that may sit on a filed return (anything beyond
    /// filing the document: a linked document can move a cost between years too).
    public var mayChangeTaxFigures: Bool {
        switch self {
        case .rentReceiptsExport, .utilityInvoice, .attachToInvoice, .payrollForm, .ukStatement, .bbvaStatement, .rentReceiptPDF, .transferAdvice:
            return true
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
    /// The user's reason for an answer that needs one (a statement imported anyway despite its
    /// closing balance), kept with the run on Confirm import (`ImportPlan.resolutionReasons`).
    public var resolutionNote: String? = nil
    /// The learnt rules that shaped the item (its kind, issuer, links): marked used on Confirm import.
    public var appliedRules: [ImportRuleUse] = []
    /// The rules the user's corrections teach: learnt on Confirm import when the item is applied.
    public var ruleDrafts: [ImportRuleDraft] = []

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
    /// The kinds made with "New kind…" in this review: inserted first at Confirm, forgotten on Discard.
    public var pendingKinds: [PendingDocumentKind] = []
    /// Whether a document of the review is filed as a saved custom kind: only then can a kind merged
    /// or deleted since make Confirm fail and the review be read again (`ImportPipeline.rereadingChangedKinds`).
    public var usesSavedCustomKinds: Bool {
        items.contains { item in
            guard item.parentId == nil, case .customEvidence(.saved) = item.recognition.kind else { return false }
            return true
        }
    }
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
        let bbva = members.compactMap { item -> BBVAStatementEffect? in
            if case .bbvaStatement(let effect) = item.effect { return effect }
            return nil
        }
        if !bbva.isEmpty, bbva.count == n {
            let rows = bbva.reduce(0) { $0 + $1.staged.count }
            let months = bbva.map(\.statement.label).sorted()
            let span = months.first == months.last ? months[0] : "\(months[0])–\(months[months.count - 1])"
            return "\(count("BBVA statement", "BBVA statements")) \(span) → \(rows) transaction\(rows == 1 ? "" : "s")"
        }
        if kinds.allSatisfy({ $0 == .rentReceiptPDF }) {
            return n == 1 ? "1 rent receipt → linked to its receipt" : "\(n) rent receipts → linked to their receipts"
        }
        if kinds.allSatisfy({ $0 == .utilityInvoice }) {
            // Linked as the importer counts it: its debit, or the debits it is linked to (paid in parts).
            let linked = members.filter { item in
                if case .utilityInvoice(let invoice) = item.effect { return invoice.transactionId != nil || item.linksToTransaction }
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
        // A custom kind by the name it is filed under.
        let documentKinds = members.compactMap { item -> String? in
            switch item.recognition.kind {
            case .evidence(let documentKind): return documentKind.displayName
            case .customEvidence: return item.kindName
            default: return nil
            }
        }
        if documentKinds.count == n, let first = documentKinds.first {
            let named = documentKinds.allSatisfy { $0 == first } ? Self.lowercasedName(first) + " " : ""
            let linked = members.filter(\.linksToTransaction).count
            let links = linked == 0 ? "" : (n == 1 ? ", linked to its transaction" : linked == n ? ", linked to their transactions" : ", \(linked) linked to transactions")
            return "\(n) \(named)document\(n == 1 ? "" : "s") → filed" + links
        }
        return count("file", "files")
    }

    /// "insurance receipt", "IMI notice": lower case unless an acronym leads.
    private static func lowercasedName(_ name: String) -> String {
        let isAcronym = name.count >= 2 && name.prefix(2).allSatisfy { $0.isUppercase || $0.isNumber }
        return isAcronym ? name : name.prefix(1).lowercased() + name.dropFirst()
    }

    /// The user's reasons per item (`ImportItem.resolutionNote`), for `ImportApplier.apply(reasons:)`.
    public var resolutionReasons: [UUID: String] {
        var reasons: [UUID: String] = [:]
        for item in items where !item.isLeftOut {
            if let note = item.resolutionNote { reasons[item.id] = note }
        }
        return reasons
    }

    /// The intent the item is read with: its shortcut's (the call that brought the file, kept
    /// when files are added to the review), with what the user chose in the review added.
    public func intent(of itemId: UUID) -> ImportIntent {
        state.intents[itemId] ?? .none
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
    /// Per account, the fingerprints of the rows the user skipped (possible duplicates): left out
    /// of every statement of the account each time they are staged.
    var skippedRows: [Int64: Set<String>] = [:]
    /// Per item, the learnt rules the user overrode (a learnt link unlinked, a learnt kind or name
    /// changed): not applied again when the item is read again.
    var declinedRules: [UUID: Set<Int64>] = [:]
    /// The on-device model's guess per file hash (`ImportModelProposals`): a file of the plan
    /// is never asked twice.
    var modelGuesses: [String: DocumentModelGuess] = [:]
    /// Per item, the "Check it"s ticked off in this review (`ImportChecks`), to take back.
    var checks: [UUID: [ImportCheckTarget: ImportCheckRecord]] = [:]
    /// Per item, the last "Mark all as checked" (`ImportChecks`), to take back together.
    var checkAlls: [UUID: ImportCheckAllRecord] = [:]
    /// Per item, the change a rule drafted on another document made there (`ImportRuleFits`), to take back.
    var ruleChanges: [UUID: ImportRuleChangeRecord] = [:]
}

extension ImportItem {
    /// The name of the kind it is recognised as: a custom kind's as it is filed (its placement).
    public var kindName: String {
        if case .customEvidence = recognition.kind, let custom = placement?.customKind { return custom.name }
        return recognition.kind.displayName
    }

    /// Whether confirming it links the document to a transaction (a certain link).
    public var linksToTransaction: Bool {
        links.contains { $0.entity.type == .transaction && $0.confidence == .certain }
    }

    /// Whether the filed-year guard holds the item (a filed return would move, or it couldn't
    /// be checked against them): its only resolution is to leave it out.
    public var isHeldByFiledYear: Bool {
        issues.contains { issue in
            if case .filedYear = issue.kind { return true }
            return issue.id == FiledYearGuard.checkFailedIssueId
        }
    }
}
