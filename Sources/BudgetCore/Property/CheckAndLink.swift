import Foundation
import GRDB

// MARK: What the sheet shows

/// Where a field's value came from: read from the PDF (its text, text recognition, its file name, an issuer's learnt
/// positions), typed or checked by the user, or known from Mango's records (the provider's property, the account a
/// statement belongs to). The sheet marks `.read` fields "read".
public enum FieldOrigin: String, Equatable, Sendable {
    case read
    case typed
    case known

    init(_ source: ImportFactSource) {
        switch source {
        case .textLayer, .ocr, .fileName, .learntRule, .model: self = .read
        case .user: self = .typed
        case .intent, .matchedRecord: self = .known
        }
    }
}

/// One field of a checked file, with where it came from.
public struct CheckedValue<Value: Equatable & Sendable>: Equatable, Sendable {
    public var value: Value
    public var origin: FieldOrigin
    /// Read by text recognition, from the file name or by the model: to look at before Save (Save counts as checked).
    public var needsCheck: Bool

    public init(value: Value, origin: FieldOrigin, needsCheck: Bool = false) {
        self.value = value
        self.origin = origin
        self.needsCheck = needsCheck
    }
}

/// A bank movement that may have paid a bill: the one suggested ("Paid by"), or another the user can pick instead.
public struct PaymentSuggestion: Equatable, Identifiable, Sendable {
    public var transactionId: Int64
    public var description: String
    public var date: Date
    public var amountMinorUnits: Int
    public var currency: Currency
    /// Why it fits ("Booked on 2023-03-20 for exactly €100.00; its description is Demo Power's").
    public var reasons: [String]
    public var id: Int64 { transactionId }

    public init(transactionId: Int64, description: String, date: Date, amountMinorUnits: Int, currency: Currency, reasons: [String]) {
        self.transactionId = transactionId
        self.description = description
        self.date = date
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.reasons = reasons
    }
}

/// A tenancy's part of a utility bill and the recharge statement it goes on (`Recharges.share`, the rule the bills
/// grid and Add to recharge use). Named by the tenancy, never the tenant.
public struct TenantShare: Equatable, Sendable {
    public var tenancyId: Int64
    public var tenancyName: String
    public var amountMinorUnits: Int
    /// "17 of 60 days in the tenancy" when prorated.
    public var note: String?
    /// The month the bill falls in (its payment's, else its issue date's).
    public var month: Date
    /// The tenancy's draft statement it joins (its latest, a draft for this month or later); nil: a new statement
    /// for `statementMonth`, or (`alreadyOnStatement`) the one it is on.
    public var joinsStatement: Int64?
    public var statementMonth: Date
    /// A recorded invoice already on a statement (a document attached to it): that statement, any status.
    public var alreadyOnStatement: Bool

    public init(tenancyId: Int64, tenancyName: String, amountMinorUnits: Int, note: String? = nil, month: Date,
                joinsStatement: Int64? = nil, statementMonth: Date, alreadyOnStatement: Bool = false) {
        self.tenancyId = tenancyId
        self.tenancyName = tenancyName
        self.amountMinorUnits = amountMinorUnits
        self.note = note
        self.month = month
        self.joinsStatement = joinsStatement
        self.statementMonth = statementMonth
        self.alreadyOnStatement = alreadyOnStatement
    }
}

/// What every checked file carries: what holds it back, and the review it came from (the Mac's import plan).
public struct CheckAndLinkCheck: Equatable, Sendable {
    /// "Invoice FT 1/23 of Demo Power, 5 Mar 2023", "BBVA statement 2026-02", or the file's name.
    public var title: String
    public var fileName: String
    /// What must be answered before Save: the Mac's Needs you reasons, the figures to check aside (Save checks them)
    /// and a filed year aside (`filedYears`).
    public var blockers: [String]
    /// Lines that don't hold it back ("Not linked: no matching debit yet").
    public var notes: [String]
    /// The file, or every row of the statement, is in Mango already: Save refuses (`alreadyInMango`).
    public var duplicateOf: String?
    /// Filed or paid years ("2022/23") saving it would change: Save is refused inline, the Mac can make it.
    public var filedYears: [String]
    /// What Save counts as checked: the figures read by text recognition, from the file name or by the model, and a
    /// recognition to check ("Amount", "Kind"). The sheet must show each of them (with its `needsCheck` field) before
    /// Save: pressing Save is the user's tick, as "Check it" is on the Mac.
    public var toCheck: [String]
    /// The user picked the kind (`chooseKind`).
    public var kindChosen: Bool
    var plan: ImportPlan
    var itemId: UUID

    public var canSave: Bool { blockers.isEmpty && duplicateOf == nil }

    /// For the sheet's previews and tests: a check with no plan behind it (the engine makes the real ones, which Save
    /// needs; a check made here can't be saved by `CheckAndLink`).
    public init(title: String, fileName: String, blockers: [String] = [], notes: [String] = [], duplicateOf: String? = nil,
                filedYears: [String] = [], toCheck: [String] = [], kindChosen: Bool = false) {
        self.title = title
        self.fileName = fileName
        self.blockers = blockers
        self.notes = notes
        self.duplicateOf = duplicateOf
        self.filedYears = filedYears
        self.toCheck = toCheck
        self.kindChosen = kindChosen
        plan = ImportPlan(items: [])
        itemId = UUID()
    }

    init(title: String, fileName: String, blockers: [String], notes: [String], duplicateOf: String?, filedYears: [String],
         toCheck: [String], kindChosen: Bool, plan: ImportPlan, itemId: UUID) {
        self.title = title
        self.fileName = fileName
        self.blockers = blockers
        self.notes = notes
        self.duplicateOf = duplicateOf
        self.filedYears = filedYears
        self.toCheck = toCheck
        self.kindChosen = kindChosen
        self.plan = plan
        self.itemId = itemId
    }
}

/// A utility bill read from a downloaded PDF, with its payment and what it means for the tenant.
public struct UtilityBillFields: Equatable, Sendable {
    public var check: CheckAndLinkCheck
    public var kind: DocumentKind = .utilityInvoice
    public var provider: CheckedValue<Int64>?
    public var providerName: String?
    public var propertyId: Int64?
    public var propertyName: String?
    public var currency: Currency
    public var periodStart: CheckedValue<Date>?
    public var periodEnd: CheckedValue<Date>?
    public var amount: CheckedValue<Int>?
    public var issueDate: CheckedValue<Date>?
    public var invoiceNumber: CheckedValue<String>?
    /// The payment suggested (`UtilityInvoiceIntake.bestPayment`, through the Mac's reader); change it with
    /// `CheckAndLink.choosePayment`.
    public var paidBy: PaymentSuggestion?
    /// What it can be changed to: the reader's choices when it asks, else the bill's payment candidates.
    public var paymentChoices: [PaymentSuggestion]
    public var tenantShares: [TenantShare]
    /// Recorded already without its document: Save attaches it (no figure of the invoice changes).
    public var attachesToInvoice: Int64?

    public init(check: CheckAndLinkCheck, kind: DocumentKind = .utilityInvoice, provider: CheckedValue<Int64>? = nil,
                providerName: String? = nil, propertyId: Int64? = nil, propertyName: String? = nil, currency: Currency,
                periodStart: CheckedValue<Date>? = nil, periodEnd: CheckedValue<Date>? = nil, amount: CheckedValue<Int>? = nil,
                issueDate: CheckedValue<Date>? = nil, invoiceNumber: CheckedValue<String>? = nil, paidBy: PaymentSuggestion? = nil,
                paymentChoices: [PaymentSuggestion] = [], tenantShares: [TenantShare] = [], attachesToInvoice: Int64? = nil) {
        self.check = check
        self.kind = kind
        self.provider = provider
        self.providerName = providerName
        self.propertyId = propertyId
        self.propertyName = propertyName
        self.currency = currency
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.amount = amount
        self.issueDate = issueDate
        self.invoiceNumber = invoiceNumber
        self.paidBy = paidBy
        self.paymentChoices = paymentChoices
        self.tenantShares = tenantShares
        self.attachesToInvoice = attachesToInvoice
    }

    public var tenantShare: TenantShare? { tenantShares.first }
    /// The draft recharge statement (its id) the bill joins; nil: a new statement, or no tenancy shares it.
    public var joinsStatement: Int64? { tenantShare?.joinsStatement }
}

/// A BBVA statement read from a downloaded PDF, as statement import (the Mac's) would add it.
public struct StatementImportSummary: Equatable, Sendable {
    public var check: CheckAndLinkCheck
    public var accountId: Int64?
    public var accountName: CheckedValue<String>?
    public var currency: Currency
    public var periodStart: CheckedValue<Date>?
    public var periodEnd: CheckedValue<Date>?
    public var openingBalance: CheckedValue<Int>?
    public var closingBalance: CheckedValue<Int>?
    /// New rows Save adds, and rows already in Mango (skipped).
    public var rowsToAdd: Int
    public var alreadyImported: Int
    /// "1 instalment: interest €112.53, capital €700.00"; "Fund: +€50.00, value €1,060.50".
    public var instalments: String?
    public var fund: String?
    /// The Mac's statement checks that hold it (the closing balance against the saved data, the account, possible
    /// duplicates, lines it couldn't read): each a blocker too.
    public var checks: [String]
    public var balanceMatches: Bool

    public init(check: CheckAndLinkCheck, accountId: Int64? = nil, accountName: CheckedValue<String>? = nil, currency: Currency,
                periodStart: CheckedValue<Date>? = nil, periodEnd: CheckedValue<Date>? = nil,
                openingBalance: CheckedValue<Int>? = nil, closingBalance: CheckedValue<Int>? = nil, rowsToAdd: Int = 0,
                alreadyImported: Int = 0, instalments: String? = nil, fund: String? = nil, checks: [String] = [],
                balanceMatches: Bool = true) {
        self.check = check
        self.accountId = accountId
        self.accountName = accountName
        self.currency = currency
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.openingBalance = openingBalance
        self.closingBalance = closingBalance
        self.rowsToAdd = rowsToAdd
        self.alreadyImported = alreadyImported
        self.instalments = instalments
        self.fund = fund
        self.checks = checks
        self.balanceMatches = balanceMatches
    }
}

/// Any other document: its kind (the picker when nothing recognised it), what was read, and what it links to.
public struct DocumentFields: Equatable, Sendable {
    public var check: CheckAndLinkCheck
    public var kind: ImportKind
    public var kindName: String
    public var kindOrigin: FieldOrigin
    /// Nothing recognised it: pick its kind (`CheckAndLink.chooseKind`) from `kindChoices`.
    public var needsKind: Bool
    public var kindChoices: [ImportKindChoice]
    public var issuer: CheckedValue<String>?
    public var date: CheckedValue<Date>?
    public var periodStart: CheckedValue<Date>?
    public var periodEnd: CheckedValue<Date>?
    public var amount: CheckedValue<Int>?
    public var currency: Currency?
    /// What Save links it to ("Bank A · 2023-03-20 · DEMO PWR DD 123").
    public var links: [String]

    public init(check: CheckAndLinkCheck, kind: ImportKind, kindName: String, kindOrigin: FieldOrigin = .read, needsKind: Bool = false,
                kindChoices: [ImportKindChoice] = [], issuer: CheckedValue<String>? = nil, date: CheckedValue<Date>? = nil,
                periodStart: CheckedValue<Date>? = nil, periodEnd: CheckedValue<Date>? = nil, amount: CheckedValue<Int>? = nil,
                currency: Currency? = nil, links: [String] = []) {
        self.check = check
        self.kind = kind
        self.kindName = kindName
        self.kindOrigin = kindOrigin
        self.needsKind = needsKind
        self.kindChoices = kindChoices
        self.issuer = issuer
        self.date = date
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.amount = amount
        self.currency = currency
        self.links = links
    }
}

/// A downloaded file checked: proposed like any import on the Mac, saved only on Save.
public enum CheckAndLinkProposal: Equatable, Sendable {
    case utilityBill(UtilityBillFields)
    case statement(StatementImportSummary)
    case document(DocumentFields)

    public var check: CheckAndLinkCheck {
        switch self {
        case .utilityBill(let fields): fields.check
        case .statement(let summary): summary.check
        case .document(let fields): fields.check
        }
    }
}

/// What Save did.
public struct CheckAndLinkResult: Equatable, Sendable {
    /// The library document the file became (synced like any other); nil for a statement sent to the Mac.
    public var documentId: Int64?
    /// The utility invoice recorded, or the recorded one it was attached to.
    public var invoiceId: Int64?
    /// A bank statement: kept on the waiting list (its row, `ImportWaitingFile`) for the Mac to import with its lease
    /// and import run. Nil when it was waiting already.
    public var sentToMac: Bool
    public var waitingFileId: Int64?
    /// "Saved <title>", or "Sent to the Mac to import".
    public var summary: String

    public init(documentId: Int64?, invoiceId: Int64? = nil, sentToMac: Bool = false, waitingFileId: Int64? = nil, summary: String) {
        self.documentId = documentId
        self.invoiceId = invoiceId
        self.sentToMac = sentToMac
        self.waitingFileId = waitingFileId
        self.summary = summary
    }
}

/// Why Save didn't save (nothing written, the file stays in the tray). Filed years, permissions and link guards keep
/// their own errors (`DeviceWriteRefusal`, `AccessDenied`, `EvidenceLinkGuard.Failure`).
public enum CheckAndLinkRefusal: Error, Equatable, LocalizedError {
    case needsAnswer([String])
    case alreadyInMango(String)
    case outdated(String)
    case macOnly(String)
    case notInTray
    /// A statement on a member's iPad: her kept files stay in her own zone, which the Mac doesn't import from.
    case statementNeedsAdmin

    public var errorDescription: String? {
        switch self {
        case .needsAnswer(let reasons): CheckAndLinkCopy.needsAnswer(reasons)
        case .alreadyInMango(let of): CheckAndLinkCopy.alreadyInMango(of)
        case .outdated(let detail): CheckAndLinkCopy.outdated(detail)
        case .macOnly(let kind): CheckAndLinkCopy.macOnly(kind)
        case .notInTray: CheckAndLinkCopy.notInTray
        case .statementNeedsAdmin: CheckAndLinkCopy.statementNeedsAdmin
        }
    }
}

// MARK: The engine

/// Check-and-link (step 10 Task 7): a PDF in the iPad's Downloads tray read and proposed exactly as the Mac's import
/// reads a dropped file — `ImportPipeline` on a copy of the database: the detector and readers (a utility invoice by
/// its provider's rules and `UtilityInvoiceIntake`, matched to the debit that paid it; a BBVA statement staged and
/// checked by `StatementChecks`), the duplicate pass and the filed-year guard. Nothing is written until Save.
///
/// The user's answers go through the pipeline too (`answer`, `choosePayment`, `chooseKind`). Save files the document
/// and applies the item's records as the Mac's importer does (`ImportApplier.filing`/`fileDocument`,
/// `ImportEffects.applyRecords`, the follow-on matching), in one write through `DeviceWriter.writeCheckingFiledYears`:
/// a change to a filed return, a missing permission (every area the save touches, checked before anything is
/// written) or a link guard refuses it whole, and the file stays in the tray. There is no import run (the iPad takes
/// no import lease): the rows are the iPad's edits, synced and re-validated by the Mac like any other.
///
/// A bank statement is never imported here: Save keeps it on the household's waiting list (`ImportWaitingList`, the
/// files kept for later, synced with their sealed copy), and the Mac imports it with its lease and import run.
///
/// The figures still to check (`CheckAndLinkCheck.toCheck`) count as checked by Save: the sheet must show each one.
///
/// One file at a time per engine (its pipeline keeps one planning copy).
public struct CheckAndLink: @unchecked Sendable {
    // @unchecked: `ImportPipeline` holds classes with constant state.
    private let dbQueue: DatabaseQueue
    private let library: EvidenceLibrary
    private let pipeline: ImportPipeline
    /// Where a tray file is copied under its own name to be read (the tray stores it under its id).
    private let stagingRoot: URL
    /// The files kept for later, where a bank statement goes for the Mac to import.
    private let waiting: ImportWaitingList
    #if DEBUG
    /// Test seam: runs in Save's write right after the document is filed.
    var afterDocumentFiled: (@Sendable () throws -> Void)?
    #endif

    /// `waitingRoot`: nil, `Waiting` beside the library's folder (as `SyncDocumentFiles` syncs it).
    public init(dbQueue: DatabaseQueue, library: EvidenceLibrary, waitingRoot: URL? = nil,
                stagingRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("MangoCheckAndLink", isDirectory: true)) {
        self.dbQueue = dbQueue
        self.library = library
        self.stagingRoot = stagingRoot
        waiting = ImportWaitingList(root: waitingRoot ?? library.root.deletingLastPathComponent().appendingPathComponent("Waiting", isDirectory: true),
                                    database: library.database)
        pipeline = ImportPipeline(dbQueue: dbQueue, library: library, categorizationService: CategorizationService(categorizer: ImportDryRun.NoSuggestions()))
    }

    /// Reads tray file `item` as the Mac's import would; `propertyId`: the property it was fetched for (a provider of
    /// another property is then asked about), nil for the provider's.
    public func propose(_ item: TrayItem, in tray: DownloadsTray, propertyId: Int64? = nil) async throws -> CheckAndLinkProposal {
        let url = try stage(item, from: tray)
        pipeline.discardPlanningCopy()
        let plan = try await pipeline.plan([url], intent: ImportIntent(propertyId: propertyId))
        return try await proposal(plan, kindChosen: false)
    }

    /// The proposal with the user's answer (`ImportPipeline.resolve`: the item read again where it must be, the
    /// duplicate pass and the filed-year guard run again).
    public func answer(_ resolution: ImportResolution, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal {
        let check = proposal.check
        let plan = try await pipeline.resolve(check.plan, itemId: check.itemId, resolution)
        var chosen = check.kindChosen
        switch resolution {
        case .chooseKind, .chooseCustomKind: chosen = true
        default: break
        }
        return try await self.proposal(plan, kindChosen: chosen)
    }

    /// "Paid by" changed: another movement (`transactionId`), or none (filed and recorded without its payment).
    public func choosePayment(_ transactionId: Int64?, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal {
        guard let item = proposal.check.plan.items.first(where: { $0.id == proposal.check.itemId }) else { return proposal }
        let asks = item.issues.first { if case .chooseLink = $0.kind { return true } else { return false } }
        let current = item.links.first { $0.entity.type == .transaction && $0.confidence == .certain }?.entity
        guard let transactionId else {
            if asks != nil { return try await answer(.fileWithoutLink, in: proposal) }
            guard let current else { return proposal }
            return try await answer(.unlink(current), in: proposal)
        }
        if current == .transaction(transactionId) { return proposal }
        if case .chooseLink(let candidates)? = asks?.kind, candidates.contains(where: { $0.entity == .transaction(transactionId) }) {
            return try await answer(.chooseLink(.transaction(transactionId)), in: proposal)
        }
        return try await answer(.linkTransactions([transactionId]), in: proposal)
    }

    /// The kind picked for a document nothing recognised (or recognised otherwise): read again as it.
    public func chooseKind(_ choice: ImportKindChoice, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal {
        guard let resolution = choice.resolution else { return proposal }
        return try await answer(resolution, in: proposal)
    }

    /// Releases the planning copy (the sheet closed without saving).
    public func discard(_ item: TrayItem? = nil) {
        pipeline.discardPlanningCopy()
        if let item { try? FileManager.default.removeItem(at: stagingFolder(item)) }
    }

    // MARK: Save

    /// Saves the checked file: the document filed and its records applied as the Mac's importer does, in one write
    /// through `writer` (`writeCheckingFiledYears`, every protected year checked); a bank statement kept on the waiting
    /// list for the Mac instead (`sendToMac`). Then the tray item is discarded. Refused (`CheckAndLinkRefusal`,
    /// `DeviceWriteRefusal`, `AccessDenied`, `EvidenceLinkGuard.Failure`): nothing is written, the library copy is
    /// removed and the item stays in the tray.
    public func save(_ proposal: CheckAndLinkProposal, item trayItem: TrayItem, tray: DownloadsTray, writer: DeviceWriter,
                     now: Date = Date()) async throws -> CheckAndLinkResult {
        let check = proposal.check
        if let of = check.duplicateOf { throw CheckAndLinkRefusal.alreadyInMango(of) }
        let items = Self.applied(check.plan, rootId: check.itemId)
        guard let root = items.first else { throw CheckAndLinkRefusal.notInTray }
        let reasons = items.flatMap(\.needsYouReasons)
        guard reasons.isEmpty else { throw CheckAndLinkRefusal.needsAnswer(reasons) }
        let url = try stage(trayItem, from: tray)
        guard url.standardizedFileURL.path == root.file.url.standardizedFileURL.path else { throw CheckAndLinkRefusal.outdated("the file was read from elsewhere") }
        if Self.isStatement(root) { return try await sendToMac(root, url: url, item: trayItem, tray: tray, writer: writer, now: now) }
        let (area, origin) = try Self.writeArea(root)

        let library = library
        #if DEBUG
        let hook = afterDocumentFiled
        #else
        let hook: (@Sendable () throws -> Void)? = nil
        #endif
        let placed = PlacedFiles()
        let confirmedBy = try await writer.actor()?.appUserId
        do {
            let result = try await writer.writeCheckingFiledYears(area, origin: origin, edit: CheckAndLinkCopy.edit(root.title),
                                                                  scope: .everyYear) { db -> CheckAndLinkResult in
                try ImportApplier.checkKinds(db: db, items, pending: [])
                try ImportApplier.checkCurrent(db: db, items)
                // Every area the save touches, before anything is written: its record's (checked by the writer), the
                // document's, and Property when the follow-on matching runs (never skipped for want of it).
                var touched: Set<Int64>? = []
                for item in items {
                    if touched != nil, let more = try ImportEffects.touchedPropertyIds(db: db, item: item) {
                        touched?.formUnion(more)
                    } else {
                        touched = nil
                    }
                }
                for needed in Self.areas(area, touched: touched) {
                    try ActorWrite.perform(orAdmin: nil, area: needed, db: db) {}
                }
                let filing = ImportApplier.filing(for: root, folders: [], newKinds: [:], kindsNow: try DocumentKindCatalog.load(db: db))
                // The document and its links are Documents' (as on the Mac).
                let documentId = try ActorWrite.perform(orAdmin: nil, area: .documents, origin: .documentLink, db: db) {
                    var files: [URL] = []
                    defer { placed.append(files) }
                    return try ImportApplier.fileDocument(db: db, item: root, url: url, filing: filing, library: library, now: now, placed: &files)
                }
                try hook?()
                for item in items {
                    try ImportEffects.applyRecords(db: db, item: item, documentId: documentId, importRunId: nil, confirmedBy: confirmedBy)
                }
                // Every property's matching where the Mac's would run all of it; transfers aren't matched (no new rows).
                try ImportEffects.followOns(db: db, propertyIds: try touched ?? Set(Property.fetchAll(db).compactMap(\.id)))
                return try Self.result(db: db, root: root, documentId: documentId)
            }
            tray.discard(trayItem)
            discard(trayItem)
            return result
        } catch {
            _ = try? library.removeOrphanedFiles(placedFiles: placed.urls)
            switch error {
            case ImportApplyError.planOutdated(let detail): throw CheckAndLinkRefusal.outdated(detail)
            case ImportApplyError.notConfirmable: throw CheckAndLinkRefusal.outdated("its kind changed")
            default: throw error
            }
        }
    }

    /// The areas Save needs Edit on, in the order they are checked: the record's, Documents (the document and its
    /// links), then Property when follow-on matching runs (`touched` nil: every property; else those named).
    static func areas(_ area: AccessArea, touched: Set<Int64>?) -> [AccessArea] {
        var areas = [area]
        if !areas.contains(.documents) { areas.append(.documents) }
        if touched.map({ !$0.isEmpty }) ?? true, !areas.contains(.property) { areas.append(.property) }
        return areas
    }

    /// A bank statement (BBVA or UK): never imported on the iPad (no import lease). Kept on the waiting list — the
    /// copy placed, its row written through `writer` (Import's area) — for the Mac to import; only the household
    /// admin's kept files reach the Mac (a member's stay in her own zone). The tray item goes once the row is written.
    private func sendToMac(_ root: ImportItem, url: URL, item trayItem: TrayItem, tray: DownloadsTray, writer: DeviceWriter,
                           now: Date) async throws -> CheckAndLinkResult {
        guard let actor = try await writer.actor() else { throw DeviceWriteRefusal.notLinkedYet }
        guard actor.isAdmin else { throw CheckAndLinkRefusal.statementNeedsAdmin }
        let file = SetAsideFile(url: url, fileName: root.file.fileName, sha256: root.file.sha256, byteCount: root.file.byteCount,
                                text: root.file.text, textStatus: root.file.textStatus, reason: CheckAndLinkCopy.sentReason,
                                recognisedAs: root.recognition.kind.displayName)
        let edit = CheckAndLinkCopy.edit(root.title)
        let kept = try await waiting.keep(file, now: now) { body in
            try await writer.writeCheckingFiledYears(.import, origin: .edit, edit: edit, scope: FiledYearEditCheck.Scope(), body)
        }
        if let failure = kept.failed.first { throw CheckAndLinkRefusal.outdated(failure.reason) }
        tray.discard(trayItem)
        discard(trayItem)
        return CheckAndLinkResult(documentId: nil, invoiceId: nil, sentToMac: true, waitingFileId: kept.kept.first?.id,
                                  summary: CheckAndLinkCopy.sentToMac)
    }

    /// A bank statement, read (staged) or only recognised (no account yet).
    static func isStatement(_ item: ImportItem) -> Bool {
        switch item.effect {
        case .bbvaStatement, .ukStatement: return true
        default: break
        }
        switch item.recognition.kind {
        case .bbvaStatement, .bankStatementPDF, .bankStatementCSV: return true
        default: return false
        }
    }

    /// The items Save applies: the file's item and its children that add something (a statement's already-imported
    /// rows are a duplicate child), each as Save confirms it — a filed-year hold left to the writer's check (which
    /// refuses it), its figures and recognition to check ticked off (`ImportChecks`). Their Needs you reasons are
    /// what still holds Save back.
    static func applied(_ plan: ImportPlan, rootId: UUID) -> [ImportItem] {
        plan.items.filter { $0.id == rootId || ($0.parentId == rootId && $0.duplicate == nil && !$0.isLeftOut) }.map(confirmed)
    }

    static func confirmed(_ item: ImportItem) -> ImportItem {
        var item = item
        item.issues.removeAll { if case .filedYear = $0.kind { return true } else { return false } }
        for target in ImportChecks.tickable(item) {
            if let ticked = try? ImportChecks.marked(target, on: item) { item = ticked }
        }
        return item
    }

    /// The area Save writes in (its record's) and its origin. Mac-only: a payroll form (tax), a rent receipts export.
    /// (Statements go to the Mac before this.)
    static func writeArea(_ item: ImportItem) throws -> (AccessArea, WriteOrigin) {
        switch item.effect {
        case .utilityInvoice, .attachToInvoice: return (.property, .propertyMatching)
        case .file, .none, .rentReceiptPDF, .transferAdvice: return (.documents, .documentLink)
        case .bbvaStatement, .ukStatement, .payrollForm, .rentReceiptsExport: throw CheckAndLinkRefusal.macOnly(item.recognition.kind.displayName)
        }
    }

    private static func result(db: Database, root: ImportItem, documentId: Int64) throws -> CheckAndLinkResult {
        var invoiceId: Int64?
        switch root.effect {
        case .utilityInvoice:
            invoiceId = try Int64.fetchOne(db, sql: "SELECT id FROM utilityInvoice WHERE documentId = ? ORDER BY id DESC", arguments: [documentId])
        case .attachToInvoice(let id): invoiceId = id
        default: break
        }
        return CheckAndLinkResult(documentId: documentId, invoiceId: invoiceId, sentToMac: false, waitingFileId: nil,
                                  summary: CheckAndLinkCopy.saved(root.title))
    }

    /// The copies `fileDocument` placed, for removal when the write rolls back.
    private final class PlacedFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        func append(_ urls: [URL]) { lock.withLock { stored += urls } }
        var urls: [URL] { lock.withLock { stored } }
    }

    // MARK: Staging

    private func stagingFolder(_ item: TrayItem) -> URL {
        stagingRoot.appendingPathComponent(item.id.uuidString, isDirectory: true)
    }

    /// The tray file copied (again) under its own name, which the readers read (a provider's file-name markers) and
    /// the library keeps as the original name.
    private func stage(_ item: TrayItem, from tray: DownloadsTray) throws -> URL {
        guard tray.items().contains(where: { $0.id == item.id }) else { throw CheckAndLinkRefusal.notInTray }
        let source = tray.fileURL(for: item)
        guard FileManager.default.fileExists(atPath: source.path) else { throw CheckAndLinkRefusal.notInTray }
        let folder = stagingFolder(item)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = (DownloadsTray.displayName(item.fileName) as NSString).lastPathComponent
        if name.isEmpty || name.hasPrefix(".") { name = "Download.pdf" }
        if (name as NSString).pathExtension.lowercased() != "pdf" { name += ".pdf" }
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    // MARK: Reading the plan

    private func proposal(_ plan: ImportPlan, kindChosen: Bool) async throws -> CheckAndLinkProposal {
        guard let root = plan.items.first(where: { $0.parentId == nil }) else { throw CheckAndLinkRefusal.notInTray }
        return try await dbQueue.read { db in try Self.proposal(db: db, plan: plan, root: root, itemId: root.id, kindChosen: kindChosen) }
    }

    static func proposal(db: Database, plan: ImportPlan, root: ImportItem, itemId: UUID, kindChosen: Bool) throws -> CheckAndLinkProposal {
        let confirmedItems = applied(plan, rootId: itemId)
        let children = plan.items.filter { $0.parentId == itemId }
        var filedYears: [String] = []
        for issue in root.issues {
            if case .filedYear(let impact) = issue.kind {
                let label = UKTaxYear(startYear: impact.startYear).label
                if !filedYears.contains(label) { filedYears.append(label) }
            }
        }
        let check = CheckAndLinkCheck(title: root.title, fileName: root.file.fileName,
                                      blockers: root.duplicate == nil ? confirmedItems.flatMap(\.needsYouReasons) : [],
                                      notes: root.notes, duplicateOf: root.duplicate?.of, filedYears: filedYears.sorted(),
                                      toCheck: toCheck(root), kindChosen: kindChosen, plan: plan, itemId: itemId)
        switch (root.effect, root.recognition.kind) {
        case (.bbvaStatement, _), (.ukStatement, _), (_, .bbvaStatement), (_, .bankStatementPDF), (_, .bankStatementCSV):
            return .statement(try statement(db: db, root: root, children: children, check: check))
        case (.utilityInvoice, _), (.attachToInvoice, _), (_, .utilityInvoice):
            return .utilityBill(try utilityBill(db: db, root: root, check: check))
        default:
            return .document(try document(db: db, root: root, check: check))
        }
    }

    /// The checks Save ticks on `item` (`confirmed`), by name.
    static func toCheck(_ item: ImportItem) -> [String] {
        var held = item
        held.issues.removeAll { if case .filedYear = $0.kind { return true } else { return false } }
        return ImportChecks.tickable(held).map { target in
            switch target {
            case .figure(let field): field.displayName
            case .recognition: "Kind"
            }
        }
    }

    private static func fact<T: Equatable & Sendable>(_ item: ImportItem, _ field: ImportFigureField,
                                                      _ value: (ImportFactValue) -> T?) -> CheckedValue<T>? {
        guard let fact = item.facts.first(where: { $0.field == field }), let found = value(fact.value) else { return nil }
        return CheckedValue(value: found, origin: FieldOrigin(fact.source), needsCheck: fact.confidence == .needsReview)
    }

    private static func date(_ value: ImportFactValue) -> Date? { if case .date(let date) = value { date } else { nil } }
    private static func money(_ value: ImportFactValue) -> Int? { if case .money(let minor, _) = value { minor } else { nil } }
    private static func text(_ value: ImportFactValue) -> String? { if case .text(let text) = value { text } else { nil } }
    private static func currency(_ item: ImportItem, _ field: ImportFigureField) -> Currency? {
        guard case .money(_, let currency)? = item.facts.first(where: { $0.field == field })?.value else { return nil }
        return currency
    }

    private static func suggestion(db: Database, _ transactionId: Int64, reasons: [String]) throws -> PaymentSuggestion? {
        guard let transaction = try Transaction.fetchOne(db, key: transactionId) else { return nil }
        let currency = try Account.fetchOne(db, key: transaction.accountId)?.currency ?? .eur
        return PaymentSuggestion(transactionId: transactionId, description: transaction.rawDescription, date: transaction.date,
                                 amountMinorUnits: transaction.amountMinorUnits, currency: currency, reasons: reasons)
    }

    // MARK: Utility bills

    private static func utilityBill(db: Database, root: ImportItem, check: CheckAndLinkCheck) throws -> UtilityBillFields {
        var invoice: UtilityInvoice?
        var attaches: Int64?
        switch root.effect {
        case .utilityInvoice(let read): invoice = read
        case .attachToInvoice(let id):
            attaches = id
            invoice = try UtilityInvoice.fetchOne(db, key: id)
        default: break
        }
        let providerId = invoice?.providerId ?? root.identityProviderId
        let provider = try providerId.flatMap { try UtilityProvider.fetchOne(db, key: $0) }
        let intended = check.plan.state.intents[root.id]?.propertyId
        let property = try (provider?.propertyId ?? intended).flatMap { try Property.fetchOne(db, key: $0) }
        let currency = property?.currency ?? currency(root, .amount) ?? .eur
        let issuer = root.facts.first { $0.field == .issuer }
        var fields = UtilityBillFields(
            check: check,
            provider: providerId.map { CheckedValue(value: $0, origin: issuer.map { FieldOrigin($0.source) } ?? .known,
                                                    needsCheck: issuer?.confidence == .needsReview) },
            providerName: provider?.name, propertyId: property?.id, propertyName: property?.name, currency: currency,
            periodStart: fact(root, .periodStart, date), periodEnd: fact(root, .periodEnd, date), amount: fact(root, .amount, money),
            issueDate: fact(root, .docDate, date), invoiceNumber: fact(root, .invoiceNumber, text),
            paidBy: nil, paymentChoices: [], tenantShares: [], attachesToInvoice: attaches)

        // Paid by: the certain payment link (the reader's, or the user's); the choices the reader asks about, else the
        // bill's payment candidates.
        if let link = root.links.first(where: { $0.entity.type == .transaction && $0.confidence == .certain }) {
            fields.paidBy = try suggestion(db: db, link.entity.id, reasons: link.reasons)
        }
        var choices: [PaymentSuggestion] = []
        for issue in root.issues {
            guard case .chooseLink(let candidates) = issue.kind else { continue }
            for candidate in candidates where candidate.entity.type == .transaction {
                if let found = try suggestion(db: db, candidate.entity.id, reasons: candidate.reasons) { choices.append(found) }
            }
        }
        if choices.isEmpty, let read = invoice, let propertyId = property?.id {
            for transaction in try UtilityInvoiceIntake.paymentCandidates(db: db, propertyId: propertyId, provider: provider,
                                                                          amountMinorUnits: read.amountMinorUnits, issueDate: read.issueDate,
                                                                          excludingInvoice: read.id) {
                if let id = transaction.id, let found = try suggestion(db: db, id, reasons: []) { choices.append(found) }
            }
        }
        if let paid = fields.paidBy, !choices.contains(where: { $0.id == paid.id }) { choices.insert(paid, at: 0) }
        fields.paymentChoices = choices

        if var read = invoice, let propertyId = property?.id {
            read.transactionId = fields.paidBy?.transactionId ?? (attaches != nil ? read.transactionId : nil)
            fields.tenantShares = try tenantShares(db: db, invoice: read, propertyId: propertyId)
        }
        return fields
    }

    /// Each tenancy's part of the invoice (`Recharges.share` on its recharge date) and the statement it goes on: the
    /// tenancy's latest when it is a draft for the bill's month or later (as Add to recharge places it), else a new
    /// one for that month; a recorded invoice already on one of the tenancy's statements stays there.
    private static func tenantShares(db: Database, invoice: UtilityInvoice, propertyId: Int64) throws -> [TenantShare] {
        let day = try Recharges.rechargeDate(db: db, invoice)
        let parts = MonthRange.components(of: day)
        let month = MonthRange.of(year: parts.year, month: parts.month).start
        var shares: [TenantShare] = []
        for tenancy in try Tenancy.filter(Column("propertyId") == propertyId).order(Column("startDate"), Column("id")).fetchAll(db) {
            guard let tenancyId = tenancy.id, let share = Recharges.share(of: invoice, rechargeDate: day, tenancy: tenancy) else { continue }
            let statements = try Recharges.statements(db: db, tenancyId: tenancyId)
            var joins: Int64?
            var statementMonth = month
            var alreadyOn = false
            if let invoiceId = invoice.id,
               let on = try RechargeStatement.fetchOne(db, sql: """
                   SELECT rechargeStatement.* FROM rechargeStatement JOIN rechargeLine ON rechargeLine.statementId = rechargeStatement.id
                   WHERE rechargeStatement.tenancyId = ? AND rechargeLine.invoiceId = ?
                   """, arguments: [tenancyId, invoiceId]) {
                joins = on.id
                statementMonth = on.month
                alreadyOn = true
            } else if let latest = statements.first, latest.status == .draft, latest.month >= month {
                joins = latest.id
                statementMonth = latest.month
            }
            shares.append(TenantShare(tenancyId: tenancyId, tenancyName: tenancy.referenceLabel, amountMinorUnits: share.amount,
                                      note: share.note, month: month, joinsStatement: joins, statementMonth: statementMonth,
                                      alreadyOnStatement: alreadyOn))
        }
        return shares
    }

    // MARK: Statements

    private static func statement(db: Database, root: ImportItem, children: [ImportItem], check: CheckAndLinkCheck) throws -> StatementImportSummary {
        var accountId: Int64?
        var rows = 0
        var already = 0
        switch root.effect {
        case .bbvaStatement(let effect):
            accountId = effect.currentAccountId
            rows = effect.staged.count
            already = effect.certainDuplicates.count
        case .ukStatement(let effect):
            accountId = effect.accountId
            rows = effect.staged.count
            already = effect.certainDuplicates.count
        default: break
        }
        let account = try accountId.flatMap { try Account.fetchOne(db, key: $0) }
        let reference = root.facts.first { $0.field == .reference }
        let checks = root.issues.filter { if case .statement = $0.kind { return true } else { return false } }.map(\.reason)
        let mismatch = root.issues.contains { if case .statement(.balanceMismatch) = $0.kind { return true } else { return false } }
        return StatementImportSummary(
            check: check, accountId: accountId,
            accountName: (account?.displayName ?? reference.flatMap { text($0.value) }).map {
                CheckedValue(value: $0, origin: reference.map { FieldOrigin($0.source) } ?? .known, needsCheck: reference?.confidence == .needsReview)
            },
            currency: account?.currency ?? currency(root, .closingBalance) ?? .eur,
            periodStart: fact(root, .periodStart, date), periodEnd: fact(root, .periodEnd, date),
            openingBalance: fact(root, .openingBalance, money), closingBalance: fact(root, .closingBalance, money),
            rowsToAdd: rows, alreadyImported: already,
            instalments: fact(root, .instalments, text)?.value, fund: fact(root, .fund, text)?.value,
            checks: checks, balanceMatches: !mismatch && accountId != nil)
    }

    // MARK: Other documents

    private static func document(db: Database, root: ImportItem, check: CheckAndLinkCheck) throws -> DocumentFields {
        let catalog = try DocumentKindCatalog.load(db: db)
        let kind = root.recognition.kind
        let names = ImportKindNames(catalog: catalog, pending: check.plan.pendingKinds)
        let kindName = kind.customKindKey.flatMap { names[$0]?.name } ?? kind.displayName
        let needsKind = kind == .unknown || root.issues.contains { if case .unknownKind = $0.kind { return true } else { return false } }
        return DocumentFields(
            check: check, kind: kind, kindName: kindName, kindOrigin: check.kindChosen ? .typed : .read, needsKind: needsKind,
            kindChoices: ImportKindChoice.choices(catalog: catalog, pending: []),
            issuer: fact(root, .issuer, text), date: fact(root, .docDate, date), periodStart: fact(root, .periodStart, date),
            periodEnd: fact(root, .periodEnd, date), amount: fact(root, .amount, money), currency: currency(root, .amount),
            links: root.links.filter { $0.confidence == .certain }.map(\.label))
    }
}
