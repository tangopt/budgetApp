import Foundation
import Observation
import BudgetCore

/// An account the statement review's list offers when none was detected.
public struct PhoneImportAccount: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the iPhone's import needs from the app: the inbox, the Check & link engine, the writer, the household's
/// statement import (nil: statements go to the Mac), the accounts the picker offers and the count of new rows no
/// category holds. Tests and the snapshot routes give their own.
public struct PhoneImportSource: Sendable {
    public var inbox: ImportInbox
    public var engine: any CheckAndLinking
    public var writer: DeviceWriter
    public var statements: PadStatementImport?
    public var accounts: @Sendable () async -> [PhoneImportAccount]
    public var uncategorised: @Sendable ([Int64]) async -> Int

    public init(inbox: ImportInbox, engine: any CheckAndLinking, writer: DeviceWriter, statements: PadStatementImport? = nil,
                accounts: @escaping @Sendable () async -> [PhoneImportAccount] = { [] },
                uncategorised: @escaping @Sendable ([Int64]) async -> Int = { _ in 0 }) {
        self.inbox = inbox
        self.engine = engine
        self.writer = writer
        self.statements = statements
        self.accounts = accounts
        self.uncategorised = uncategorised
    }

    /// Whether this device's user is offered the statement import at all: the admin, or a member while
    /// `PadStatementImport.membersImport` is on. Documents are offered to everyone who may write them.
    public func offersStatementImport() async -> Bool {
        guard let actor = try? await writer.actor() else { return false }
        return actor.isAdmin || PadStatementImport.membersImport
    }
}

/// The words of the iPhone import.
public enum PhoneImportCopy {
    public static let title = "Import"
    public static let reading = "Reading"
    public static func readingFiles(_ count: Int) -> String { "Reading \(count) \(count == 1 ? "file" : "files")" }
    public static let cancel = "Cancel"
    public static let nextFile = "Next file"
    public static let notNow = "Not now"
    public static let chooseFromFiles = "Choose from Files"
    public static let cancelTitle = "Leave this import?"
    public static let cancelMessage = "What was already imported or saved stays. The files not yet done are not imported."
    public static let leave = "Leave import"
    public static let keepGoing = "Keep going"
    public static let cantRead = "Can’t read this file"
    public static let sendNote = "Send it to the Mac to import it there."
    public static let checkAgain = "Check again"
    public static let importDisabledNote = "The file stays here until you try again."
    public static let chooseAccount = "Choose the account"
    public static let detected = "Detected"
    public static let readFromFile = "Read"
    public static let toCheck = "To check"
    public static let done = "Done"
    public static let undoConfirmTitle = "Undo this import?"
    public static let notImported = "Not imported"
    public static func importRows(_ rows: Int) -> String { "Import \(rows) \(rows == 1 ? "row" : "rows")" }
    public static func newRowsTile(_ rows: Int) -> String { "\(rows) new \(rows == 1 ? "row" : "rows")" }
    public static func detectedFor(_ detected: String, preset: String) -> String {
        "This looks like the statement of \(detected), not \(preset)."
    }
    public static func useAccount(_ name: String) -> String { "Import to \(name)" }
    public static func sentToMac(_ count: Int) -> String { "\(count) sent to the Mac" }
}

/// One iPhone import: the files chosen in Files (or shared to Mango), read and sorted, then reviewed one at a time. A
/// statement is imported through the same engine as the iPad (`CheckAndLinkModel.importStatement`: the household's
/// import lease, `ImportApplier`), a document through Check & link's Save. Nothing is written until the person presses
/// that file's primary action. Cancel releases every copy.
@MainActor @Observable
public final class PhoneImportModel: Identifiable {
    public enum Stage: Equatable, Sendable {
        /// Copying the files in and reading each one.
        case reading
        /// One file at a time.
        case reviewing
        /// The closing summary.
        case done
    }

    /// Where the person started: Accounts (nothing preset), an account's page (that account), or a bill's "Add document"
    /// (documents only, linked to that bill).
    public struct Preset: Equatable, Sendable {
        public var accountId: Int64?
        public var accountName: String?
        public var documentsOnly: Bool
        /// What a document is linked to when it came from a bill or receipt ("Electricity, October").
        public var linkTitle: String?
        public var propertyId: Int64?

        public init(accountId: Int64? = nil, accountName: String? = nil, documentsOnly: Bool = false, linkTitle: String? = nil,
                    propertyId: Int64? = nil) {
            self.accountId = accountId
            self.accountName = accountName
            self.documentsOnly = documentsOnly
            self.linkTitle = linkTitle
            self.propertyId = propertyId
        }
    }

    /// What the statement screen offers for the file shown (the iPad's states, in the iPhone's words).
    public enum StatementCard: Equatable, Sendable {
        /// Import is offered ("Import 14 rows").
        case importReady(rows: Int)
        /// Every row is in Mango already: "Done with this file", no Import button.
        case allAlreadyIn(rows: Int)
        /// Another device holds the import lease; Import is visible and disabled.
        case heldByOther(message: String)
        case offline(message: String)
        /// This account's import is made on the Mac: "Send to the Mac" is the only action.
        case sendToMac
        /// A member while `membersImport` is off: no button, a note.
        case ownerImports
        /// The statement's account wasn't detected: pick one.
        case needsAccount
        /// The statement is for another account than the one the person started from: ask.
        case confirmAccount(detected: String, preset: String)
        /// Another problem holds it back (the engine's blockers); Import is shown disabled.
        case blocked
    }

    public let id = UUID()
    public let preset: Preset
    public private(set) var batch: PhoneImportBatch
    public private(set) var stage: Stage
    /// The engine's model for the file shown (nil for an unreadable file or the summary).
    public private(set) var review: CheckAndLinkModel?
    public private(set) var accountChoices: [PhoneImportAccount] = []
    /// New rows no category holds ("Review 4 uncategorised").
    public private(set) var uncategorised = 0
    /// Why Undo import was refused, in the Mac's words; shown in one sheet with Cancel the default.
    public var undoProblem: String?
    public private(set) var isUndone = false
    public private(set) var isWorking = false
    /// The person said the detected account is the right one (when the statement is another account's than the preset).
    public private(set) var confirmedDetected = false
    /// The picker's offered files, copied, and the files left for the next batch.
    public var overflowNote: String? { batch.overflowNote }

    @ObservationIgnored private let source: PhoneImportSource?
    @ObservationIgnored private var items: [UUID: TrayItem] = [:]

    public init(source: PhoneImportSource, preset: Preset = Preset()) {
        self.source = source
        self.preset = preset
        batch = PhoneImportBatch(files: [])
        stage = .reading
    }

    /// For the snapshot routes and previews: a batch at a stage, with the review model of the file shown.
    public init(batch: PhoneImportBatch, stage: Stage, review: CheckAndLinkModel? = nil, preset: Preset = Preset(),
                accountChoices: [PhoneImportAccount] = [], uncategorised: Int = 0, confirmedDetected: Bool = false) {
        source = nil
        self.preset = preset
        self.batch = batch
        self.stage = stage
        self.review = review
        self.accountChoices = accountChoices
        self.uncategorised = uncategorised
        self.confirmedDetected = confirmedDetected
    }

    // MARK: Reading

    /// Copies `urls` into the inbox (a security-scoped URL is released at once), reads each file and opens the first
    /// one that needs a look. `removing`: the incoming originals to delete once copied (a share's `Documents/Inbox`).
    public func start(urls: [URL], removing: [URL] = []) async {
        guard let source else { return }
        let intake = await Task.detached { source.inbox.add(urls) }.value
        for url in removing { try? FileManager.default.removeItem(at: url) }
        batch = PhoneImportBatch(intake)
        for case .file(let item) in intake.entries { items[item.id] = item }
        accountChoices = await source.accounts()
        stage = .reading
        await classifyAll(source)
        guard !batch.files.isEmpty else {
            stage = .done
            return
        }
        stage = .reviewing
        await openCurrent()
    }

    /// Each file read in turn (the engine keeps one planning copy), only to sort it; the review reads it again.
    private func classifyAll(_ source: PhoneImportSource) async {
        for file in batch.files where file.kind == nil {
            guard let item = items[file.id] else { continue }
            do {
                let proposal = try await source.engine.propose(item, in: source.inbox.tray, propertyId: preset.propertyId)
                source.engine.discard(item)
                var kind = PhoneImportBatch.kind(of: proposal, fileExtension: item.fileExtension)
                var problem: String?
                if kind == .cantRead {
                    problem = ImportInboxCopy.photoStatement
                } else if kind == .statement && preset.documentsOnly {
                    kind = .cantRead
                    problem = PhoneImportCopy.statementsAreImportedFromAccounts
                }
                batch.setKind(kind, for: file.id, problem: problem)
            } catch {
                source.engine.discard(item)
                batch.setKind(.cantRead, for: file.id, problem: CheckAndLinkModel.text(for: error))
            }
        }
    }

    /// Opens the file shown: the engine reads it again as its own model.
    private func openCurrent() async {
        review?.cancel()
        review = nil
        confirmedDetected = false
        guard let source, let file = batch.currentFile, file.needsReview, file.kind != .cantRead, let item = items[file.id] else { return }
        let model = CheckAndLinkModel(item: item, tray: source.inbox.tray, engine: source.engine, writer: source.writer,
                                      propertyId: preset.propertyId, statements: source.statements)
        review = model
        await model.start()
    }

    // MARK: What the screens show

    public var currentFile: PhoneImportBatch.File? { batch.currentFile }

    /// The statement the review holds, when the file shown is one.
    public var statement: StatementImportSummary? {
        if case .statement(let summary)? = review?.proposal { return summary }
        return nil
    }

    /// The statement screen's state for the file shown.
    public var statementCard: StatementCard? {
        guard let review, let statement else { return nil }
        if statement.accountId == nil { return .needsAccount }
        if statement.rowsToAdd == 0, statement.alreadyImported > 0 || statement.check.duplicateOf != nil {
            return .allAlreadyIn(rows: statement.alreadyImported)
        }
        switch review.route {
        case .ownerImports?: return .ownerImports
        case .sendToMac?, nil: return .sendToMac
        case .offline?: return .offline(message: PadStatementImportCopy.offline)
        case .heldBy(let name, let since)?: return .heldByOther(message: PadStatementImportCopy.heldBy(name, since: since))
        case .importHere?: break
        }
        if let presetName = preset.accountName, let presetId = preset.accountId, let detected = statement.accountId, detected != presetId,
           !confirmedDetected {
            return .confirmAccount(detected: statement.accountName?.value ?? "another account", preset: presetName)
        }
        return review.canImport ? .importReady(rows: statement.rowsToAdd) : .blocked
    }

    /// Whether the primary on the statement screen can be pressed.
    public var canImportStatement: Bool {
        if case .importReady? = statementCard { return !isWorking && !(review?.isWorking ?? false) }
        return false
    }

    public var canSendToMac: Bool {
        statementCard == .sendToMac && review?.canSave == true && !isWorking
    }

    /// The document screen's primary is offered.
    public var canSaveDocument: Bool {
        guard let review, !isWorking, statement == nil else { return false }
        return review.canSave
    }

    /// "Already saved as <name>" when the document is in Mango.
    public var alreadySavedAs: String? {
        guard statement == nil else { return nil }
        return review?.proposal?.check.duplicateOf
    }

    // MARK: Actions on the file shown

    public func chooseAccount(_ accountId: Int64) async {
        await review?.chooseAccount(accountId)
    }

    public func confirmDetectedAccount() { confirmedDetected = true }

    /// Check again after Another device was importing or the connection was lost.
    public func checkAgain() async { await review?.refreshRoute() }

    /// Import the statement shown; on success the review moves to the next file. A refusal stays on the screen.
    public func importStatement() async {
        guard canImportStatement, let review, let file = currentFile, let summary = statement else { return }
        isWorking = true
        defer { isWorking = false }
        guard await review.importStatement(), let runId = review.importedRunId else { return }
        let accountName = summary.accountName?.value
        await settle(file.id, .imported(accountId: summary.accountId, accountName: accountName, rows: summary.rowsToAdd,
                                        skipped: summary.alreadyImported, runId: runId))
    }

    /// "Send to the Mac" for a statement this device can't import.
    public func sendToMac() async {
        guard canSendToMac, let review, let file = currentFile else { return }
        isWorking = true
        defer { isWorking = false }
        guard await review.save() else { return }
        await settle(file.id, .sentToMac)
    }

    /// "Save and link" for a document.
    public func saveDocument() async {
        guard canSaveDocument, let review, let file = currentFile, let proposal = review.proposal else { return }
        isWorking = true
        defer { isWorking = false }
        guard await review.save() else { return }
        await settle(file.id, .saved(documentId: review.savedResult?.documentId, title: proposal.check.title,
                                     linked: Self.isLinked(proposal)))
    }

    /// Whether Save links the document to a payment or record.
    static func isLinked(_ proposal: CheckAndLinkProposal) -> Bool {
        switch proposal {
        case .utilityBill(let bill): bill.paidBy != nil
        case .document(let document): !document.links.isEmpty
        case .statement: false
        }
    }

    /// "Done with this file": every row was in Mango (or the document is), so nothing is written.
    public func doneWithFile() async {
        guard let file = currentFile else { return }
        let rows = statement?.alreadyImported ?? 0
        await settle(file.id, .alreadyInMango(rows: rows))
    }

    /// "Not now": the file stays out of the totals, listed as not imported.
    public func skipCurrent() async {
        guard let file = currentFile else { return }
        await settle(file.id, .notImported)
    }

    /// "Next file" on the card of a file Mango can't read.
    public func nextFile() async {
        guard let file = currentFile else { return }
        let more = batch.acknowledgeUnreadable(file.id)
        await afterAdvance(more)
    }

    /// The swipe to another file still waiting.
    public func select(_ index: Int) async {
        guard batch.files.indices.contains(index), index != batch.current else { return }
        batch.select(index)
        await openCurrent()
    }

    private func settle(_ id: UUID, _ outcome: PhoneImportBatch.Outcome) async {
        let more = batch.finish(id, outcome)
        await afterAdvance(more)
    }

    private func afterAdvance(_ more: Bool) async {
        if more {
            await openCurrent()
        } else {
            review?.cancel()
            review = nil
            await finish()
        }
    }

    // MARK: Closing

    private func finish() async {
        if let source { uncategorised = await source.uncategorised(batch.undoRunIds) }
        stage = .done
    }

    /// Whether leaving needs a question: something was already imported or saved.
    public var needsLeaveConfirmation: Bool {
        batch.files.contains {
            switch $0.outcome {
            case .imported, .saved, .sentToMac: true
            default: false
            }
        }
    }

    /// Cancel, or Done: the review closed and every copy that wasn't used released.
    public func close() {
        review?.cancel()
        review = nil
        guard let source else { return }
        source.inbox.release(items.values.map { $0 })
        items = [:]
    }

    /// Undo import is offered when the household's statement import can run it (snapshot models always show it).
    var canUndoRuns: Bool { source == nil || source?.statements != nil }

    /// "Undo import": the statement rows this batch imported are removed (documents stay saved), each run under the
    /// household's lease. A refusal (a row edited since, a later import, a filed year) stays in `undoProblem`.
    public func undoImport() async {
        guard let source, let statements = source.statements, !isWorking else { return }
        let runs = batch.undoRunIds
        guard !runs.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        var undone: [Int64] = []
        for run in runs {
            do {
                _ = try await statements.undo(runId: run, writer: source.writer)
                undone.append(run)
            } catch {
                undoProblem = CheckAndLinkModel.text(for: error)
                break
            }
        }
        batch.markUndone(undone)
        if undone.count == runs.count {
            undoProblem = nil
            isUndone = true
        }
    }
}

extension PhoneImportCopy {
    public static let statementsAreImportedFromAccounts = "This is a bank statement. Import it from Accounts."
}
