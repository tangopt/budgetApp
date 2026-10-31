import Foundation
import Observation
import BudgetCore

/// What the check-and-link sheet needs from the engine (step 10, Task 8): `CheckAndLink` is the app's; tests give their
/// own. Reading and answering write nothing; only `save` does, through the device writer.
public protocol CheckAndLinking: Sendable {
    func propose(_ item: TrayItem, in tray: DownloadsTray, propertyId: Int64?) async throws -> CheckAndLinkProposal
    func choosePayment(_ transactionId: Int64?, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal
    func chooseKind(_ choice: ImportKindChoice, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal
    /// Any other answer the import reads (the iPhone's account picker: `.chooseAccount`).
    func answer(_ resolution: ImportResolution, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal
    func save(_ proposal: CheckAndLinkProposal, item: TrayItem, tray: DownloadsTray, writer: DeviceWriter,
              now: Date) async throws -> CheckAndLinkResult
    func discard(_ item: TrayItem?)
    /// Step 19: the checked bank statement imported here (`CheckAndLink.importStatement`).
    func importStatement(_ proposal: CheckAndLinkProposal, item: TrayItem, tray: DownloadsTray, writer: DeviceWriter,
                         importer: PadStatementImport, now: Date) async throws -> CheckAndLinkResult
}

extension CheckAndLinking {
    public func answer(_ resolution: ImportResolution, in proposal: CheckAndLinkProposal) async throws -> CheckAndLinkProposal { proposal }

    public func importStatement(_ proposal: CheckAndLinkProposal, item: TrayItem, tray: DownloadsTray, writer: DeviceWriter,
                                importer: PadStatementImport, now: Date) async throws -> CheckAndLinkResult {
        throw CheckAndLinkRefusal.macOnly("Bank statement")
    }
}

extension CheckAndLink: CheckAndLinking {}

/// What the browser needs to open the sheet: the engine, and the writer whose Edit decides whether Check is offered.
public struct CheckAndLinkSource: Sendable {
    public var engine: any CheckAndLinking
    public var writer: DeviceWriter
    /// Step 19: imports bank statements here under the household's import lease; nil: statements only go to the Mac.
    public var statements: PadStatementImport?

    public init(engine: any CheckAndLinking, writer: DeviceWriter, statements: PadStatementImport? = nil) {
        self.engine = engine
        self.writer = writer
        self.statements = statements
    }

    /// Check is offered with Edit on Property and Documents (a utility bill is recorded in the one and filed in the other).
    public func offersCheck() async -> Bool {
        CheckAndLinkModel.offersCheck(canEditProperty: await writer.canEdit(.property),
                                      canEditDocuments: await writer.canEdit(.documents))
    }
}

/// The sheet's words, apart from the engine's (`CheckAndLinkCopy`).
public enum CheckAndLinkSheetCopy {
    public static let title = "Check and link"
    public static let pinchToZoom = "Pinch to zoom"
    public static let readBadge = "read"
    public static let toCheckBadge = "to check"
    public static let linked = "Linked"
    public static let notThisOne = "Not this one? Search transactions"
    public static let noPaymentFound = "No payment found for this bill yet."
    public static let choosePayment = "Search transactions"
    public static let useThisOne = "Use this one"
    public static let noPaymentToLink = "Don't link a payment"
    public static let statementsOnTheMac = "Statements are imported on the Mac for now. Share this one to the Mac to import it there."
    public static let statementNote = "Save sends this statement to the Mac, which imports it."
    /// Step 19: the statement can be imported here.
    public static func importNote(rows: Int, skipped: Int) -> String {
        let added = "Import adds \(rows) new \(rows == 1 ? "row" : "rows") to this account"
        return skipped > 0 ? added + "; \(skipped) already in Mango \(skipped == 1 ? "is" : "are") skipped." : added + "."
    }
    public static let finishOnMacNote = "Finish on the Mac puts it on the Mac’s waiting list to import there."
    public static let sendToMacNote = "Send to the Mac sends this statement to the Mac, which imports it."

    /// Above the fields Save will count as checked.
    public static func checkBeforeSave(_ names: [String]) -> String {
        "Check \(names.joined(separator: ", ")) against the PDF. Saving counts \(names.count == 1 ? "it" : "them") as checked."
    }

    /// "Goes into October 2026's recharge statement, still a draft".
    public static func goesInto(month: String) -> String { "Goes into \(month)'s recharge statement, still a draft" }
    public static func goesOnNew(month: String) -> String { "Goes on a new \(month) recharge statement" }
    public static func alreadyOn(month: String) -> String { "Already on the \(month) recharge statement" }

    static func monthTitle(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: month)
    }
}

/// One line of the sheet's fields: its label, value, and whether it was read from the PDF or Save will count it as
/// checked ("to check": read by text recognition, from the file name or by the model).
public struct CheckRow: Equatable, Identifiable, Sendable {
    public enum Mark: Equatable, Sendable { case none, read, toCheck }

    public var label: String
    public var value: String
    /// A figure keeps one line; a name may truncate in the middle.
    public var isFigure: Bool
    public var mark: Mark
    /// The engine's names for what this row shows (`CheckAndLinkCheck.toCheck`).
    var covers: [String]
    public var id: String { label }
}

/// The check-and-link sheet's state (step 10, Task 8): the file read as the Mac's import reads it, the person's answers
/// (Paid by, Kind) and Save. Nothing is written until `save()`; a refusal is kept in `refusal` and the sheet stays
/// open with the file still in the tray. `cancel()` releases the planning copy and changes nothing.
@MainActor @Observable
public final class CheckAndLinkModel {
    public enum Phase: Equatable, Sendable {
        case reading
        case ready
        /// The file couldn't be read at all (the message says why).
        case failed(String)
        /// Saved (or sent to the Mac): the engine's summary.
        case saved(String)
    }

    public let item: TrayItem
    public private(set) var phase: Phase = .reading
    public private(set) var proposal: CheckAndLinkProposal?
    /// What the person changed in this sheet before Save ("Paid by", "Kind").
    public private(set) var edits: [String] = []
    /// Why Save didn't save, in plain words (shown with `PadRefusalBanner`); nil when it hasn't been refused.
    public var refusal: String?
    public private(set) var isWorking = false
    /// Step 19: what the sheet offers for a bank statement (nil: statements only go to the Mac, Save sends it).
    public private(set) var route: PadImportRoute?
    /// The household's admin, who may hand a statement to the Mac ("Finish on the Mac").
    public private(set) var canFinishOnMac = false
    /// The run a statement imported here made (Undo import).
    public private(set) var importedRunId: Int64?
    /// What Save did (the document it filed), for the iPhone's closing summary.
    public private(set) var savedResult: CheckAndLinkResult?

    @ObservationIgnored private let engine: (any CheckAndLinking)?
    @ObservationIgnored private let tray: DownloadsTray
    @ObservationIgnored private let writer: DeviceWriter?
    @ObservationIgnored private let propertyId: Int64?
    @ObservationIgnored private let statements: PadStatementImport?
    @ObservationIgnored private let now: () -> Date

    /// `propertyId`: the property the file was fetched for (a provider of another property is then asked about).
    /// `statements`: imports a bank statement here (step 19); nil: Save sends it to the Mac.
    public init(item: TrayItem, tray: DownloadsTray, engine: any CheckAndLinking, writer: DeviceWriter, propertyId: Int64? = nil,
                statements: PadStatementImport? = nil, now: @escaping () -> Date = { Date() }) {
        self.item = item
        self.tray = tray
        self.engine = engine
        self.writer = writer
        self.propertyId = propertyId
        self.statements = statements
        self.now = now
    }

    /// For the snapshot routes: a proposal, a refusal and (a statement) its route, as given.
    public init(item: TrayItem, tray: DownloadsTray, proposal: CheckAndLinkProposal, refusal: String? = nil,
                route: PadImportRoute? = nil, canFinishOnMac: Bool = false) {
        self.item = item
        self.tray = tray
        engine = nil
        writer = nil
        propertyId = nil
        statements = nil
        now = { Date() }
        self.proposal = proposal
        self.refusal = refusal
        self.route = route
        self.canFinishOnMac = canFinishOnMac
        phase = .ready
    }

    /// Check is offered only with Edit on Property and on Documents.
    nonisolated public static func offersCheck(canEditProperty: Bool, canEditDocuments: Bool) -> Bool {
        canEditProperty && canEditDocuments
    }

    /// The tray file the preview shows.
    public var fileURL: URL { tray.fileURL(for: item) }

    // MARK: Steps

    /// Reads the file (once).
    public func start() async {
        guard phase == .reading, let engine else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            proposal = try await engine.propose(item, in: tray, propertyId: propertyId)
            await refreshRoute()
            phase = .ready
        } catch {
            phase = .failed(Self.text(for: error))
        }
    }

    /// "Paid by" changed to another movement, or (nil) to none.
    public func choosePayment(_ transactionId: Int64?) async {
        guard let engine, let current = proposal, !isWorking else { return }
        await answer(edit: "Paid by") { try await engine.choosePayment(transactionId, in: current) }
    }

    /// The account picked for a bank statement that matched none (the iPhone's account list).
    public func chooseAccount(_ accountId: Int64) async {
        guard let engine, let current = proposal, !isWorking else { return }
        await answer(edit: "Account") { try await engine.answer(.chooseAccount(.current, accountId), in: current) }
        await refreshRoute()
    }

    /// The kind picked for a file nothing recognised.
    public func chooseKind(_ choice: ImportKindChoice) async {
        guard let engine, let current = proposal, !isWorking else { return }
        await answer(edit: "Kind") { try await engine.chooseKind(choice, in: current) }
    }

    private func answer(edit: String, _ body: () async throws -> CheckAndLinkProposal) async {
        isWorking = true
        defer { isWorking = false }
        do {
            proposal = try await body()
            if !edits.contains(edit) { edits.append(edit) }
            refusal = nil
        } catch {
            refusal = Self.text(for: error)
        }
    }

    /// Step 19: for a bank statement, what the sheet offers (import here, waiting for another device, offline, send to
    /// the Mac); read again after a refused import. Reads the lease; writes nothing.
    public func refreshRoute() async {
        guard let statements, let writer, case .statement(let statement)? = proposal else { return }
        route = await statements.route(accountId: statement.accountId, writer: writer)
        canFinishOnMac = (try? await writer.actor())?.isAdmin ?? false
    }

    /// Whether Import is offered as ready: a statement that may be imported here, read, nothing left to answer.
    public var canImport: Bool { route == .importHere && canSave }

    /// Why Import waits ("Mac is importing (started 10:42)…", "Connect to the internet to import"); nil otherwise.
    public var importWaitMessage: String? {
        switch route {
        case .heldBy(let name, let since): return PadStatementImportCopy.heldBy(name, since: since)
        case .offline: return PadStatementImportCopy.offline
        default: return nil
        }
    }

    /// Imports the statement here (step 19). True when it imported; a refusal stays in `refusal` (and a lease another
    /// device took, or a lost connection, updates the route).
    @discardableResult
    public func importStatement() async -> Bool {
        guard canImport, let engine, let writer, let statements, let proposal else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await engine.importStatement(proposal, item: item, tray: tray, writer: writer, importer: statements, now: now())
            refusal = nil
            importedRunId = result.importRunId
            phase = .saved(result.summary)
            return true
        } catch {
            refusal = Self.text(for: error)
            switch error as? PadImportRefusal {
            case .heldBy(let name, let since)?: route = .heldBy(deviceName: name, since: since)
            case .offline?: route = .offline
            case .noImportAccess?: route = .sendToMac
            case .foundChanges?:
                // Another device's import arrived: the statement is read again, the refusal kept above it.
                isWorking = false
                phase = .reading
                await start()
                refusal = PadStatementImportCopy.foundChanges
            case .stillSyncing?, nil: break
            }
            return false
        }
    }

    /// Undoes the import just made here (its run), under the lease. A refusal stays in `refusal`.
    public func undoImport() async {
        guard let runId = importedRunId, let writer, let statements, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await statements.undo(runId: runId, writer: writer, now: now())
            refusal = nil
            importedRunId = nil
            phase = .saved(PadStatementImportCopy.undone(result))
        } catch {
            refusal = Self.text(for: error)
        }
    }

    /// Whether Save is offered as ready: read, nothing left to answer, not already in Mango, not working.
    public var canSave: Bool {
        phase == .ready && !isWorking && (proposal?.check.canSave ?? false)
    }

    /// Saves (the only call that writes). True when it saved; a refusal stays in `refusal`, the sheet stays open and the
    /// tray item stays.
    @discardableResult
    public func save() async -> Bool {
        guard canSave, let engine, let writer, let proposal else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await engine.save(proposal, item: item, tray: tray, writer: writer, now: now())
            refusal = nil
            savedResult = result
            phase = .saved(result.summary)
            return true
        } catch {
            refusal = Self.text(for: error)
            return false
        }
    }

    /// The sheet closed without saving: the planning copy released, nothing else changes.
    public func cancel() {
        engine?.discard(item)
    }

    nonisolated static func text(for error: Error) -> String {
        if let refusal = error as? CheckAndLinkRefusal, refusal == .statementNeedsAdmin { return CheckAndLinkSheetCopy.statementsOnTheMac }
        return PadWriteModel.text(for: error)
    }

    // MARK: What the sheet shows

    /// The kind of file, for the sheet's heading.
    public var isStatement: Bool {
        if case .statement? = proposal { return true }
        return false
    }

    /// The names of the fields Save will count as checked (`CheckAndLinkCheck.toCheck`).
    public var toCheckNames: [String] { proposal?.check.toCheck ?? [] }

    /// "The document": the fields read from the file, each marked "read" (from the PDF) or "to check".
    public var rows: [CheckRow] {
        guard let proposal else { return [] }
        let toCheck = proposal.check.toCheck
        func mark(_ values: [(origin: FieldOrigin, needsCheck: Bool)?], covers: [String]) -> CheckRow.Mark {
            let present = values.compactMap { $0 }
            if present.contains(where: \.needsCheck) || covers.contains(where: toCheck.contains) { return .toCheck }
            return present.contains { $0.origin == .read } ? .read : .none
        }
        func row<T>(_ label: String, _ value: CheckedValue<T>?, covers: [String], figure: Bool = false,
                    _ text: (T) -> String) -> CheckRow? {
            guard let value else { return nil }
            return CheckRow(label: label, value: text(value.value), isFigure: figure,
                            mark: mark([(value.origin, value.needsCheck)], covers: covers), covers: covers)
        }
        func period(_ start: CheckedValue<Date>?, _ end: CheckedValue<Date>?) -> CheckRow? {
            guard start != nil || end != nil else { return nil }
            let text: String
            switch (start, end) {
            case let (start?, end?): text = "\(PhoneDateFormat.day(start.value)) – \(PhoneDateFormat.day(end.value))"
            case let (start?, nil): text = PhoneDateFormat.day(start.value)
            default: text = PhoneDateFormat.day(end?.value)
            }
            return CheckRow(label: "Period", value: text.unbroken, isFigure: true,
                            mark: mark([start.map { ($0.origin, $0.needsCheck) }, end.map { ($0.origin, $0.needsCheck) }],
                                       covers: ["Period start", "Period end"]),
                            covers: ["Period start", "Period end"])
        }
        func kind(_ name: String, origin: FieldOrigin) -> CheckRow {
            CheckRow(label: "Kind", value: name, isFigure: false,
                     mark: toCheck.contains("Kind") ? .toCheck : (origin == .read ? .read : .none), covers: ["Kind"])
        }
        func plain(_ label: String, _ value: String?) -> CheckRow? {
            value.map { CheckRow(label: label, value: $0, isFigure: false, mark: .none, covers: []) }
        }
        switch proposal {
        case .utilityBill(let bill):
            let currency = bill.currency
            return [
                kind("Utility invoice", origin: .known),
                bill.provider.flatMap { value in
                    bill.providerName.map {
                        CheckRow(label: "Provider", value: $0, isFigure: false,
                                 mark: mark([(value.origin, value.needsCheck)], covers: ["Issuer"]), covers: ["Issuer"])
                    }
                },
                plain("Property", bill.propertyName),
                period(bill.periodStart, bill.periodEnd),
                row("Amount", bill.amount, covers: ["Amount"], figure: true) { Money.format($0, currency: currency) },
                row("Issued", bill.issueDate, covers: ["Date"], figure: true) { PhoneDateFormat.day($0) },
                row("Invoice no.", bill.invoiceNumber, covers: ["Invoice number"]) { $0 },
            ].compactMap { $0 }
        case .statement(let statement):
            let currency = statement.currency
            return [
                kind("Bank statement", origin: .read),
                row("Account", statement.accountName, covers: ["Reference"]) { $0 },
                period(statement.periodStart, statement.periodEnd),
                row("Opening balance", statement.openingBalance, covers: ["Opening balance"], figure: true) { Money.format($0, currency: currency) },
                row("Closing balance", statement.closingBalance, covers: ["Closing balance"], figure: true) { Money.format($0, currency: currency) },
                CheckRow(label: "New rows", value: String(statement.rowsToAdd), isFigure: true, mark: .none, covers: []),
                statement.alreadyImported > 0
                    ? CheckRow(label: "Already in Mango", value: String(statement.alreadyImported), isFigure: true, mark: .none, covers: [])
                    : nil,
                plain("Instalments", statement.instalments),
                plain("Fund", statement.fund),
            ].compactMap { $0 }
        case .document(let document):
            let currency = document.currency ?? .eur
            return [
                kind(document.kindName, origin: document.kindOrigin),
                row("From", document.issuer, covers: ["Issuer"]) { $0 },
                period(document.periodStart, document.periodEnd),
                row("Amount", document.amount, covers: ["Amount"], figure: true) { Money.format($0, currency: currency) },
                row("Date", document.date, covers: ["Date"], figure: true) { PhoneDateFormat.day($0) },
            ].compactMap { $0 }
        }
    }

    /// Names Save will tick that no row above shows (the banner names them too, so none is silent).
    public var unshownChecks: [String] {
        let shown = Set(rows.filter { $0.mark == .toCheck }.flatMap(\.covers))
        return toCheckNames.filter { !shown.contains($0) }
    }

    /// The utility bill's tenant share and where it goes, as lines for the Recharge block; empty for other files.
    public var rechargeLines: [(amount: Int, currency: Currency, who: String, note: String?, goes: String)] {
        guard case .utilityBill(let bill)? = proposal else { return [] }
        return bill.tenantShares.map { share in
            let month = CheckAndLinkSheetCopy.monthTitle(share.statementMonth)
            let goes = share.alreadyOnStatement ? CheckAndLinkSheetCopy.alreadyOn(month: month)
                : share.joinsStatement == nil ? CheckAndLinkSheetCopy.goesOnNew(month: month)
                : CheckAndLinkSheetCopy.goesInto(month: month)
            return (share.amountMinorUnits, bill.currency, share.tenancyName, share.note, goes)
        }
    }

    /// The payments "Search transactions" offers, the current one first.
    public var paymentChoices: [PaymentSuggestion] {
        guard case .utilityBill(let bill)? = proposal else { return [] }
        return bill.paymentChoices
    }
}
