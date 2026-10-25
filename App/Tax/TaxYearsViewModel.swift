// App/Tax/TaxYearsViewModel.swift
import Foundation
import AppKit
import UniformTypeIdentifiers
import BudgetCore
import struct BudgetCore.Transaction
import struct BudgetCore.Category
import GRDB

/// The Tax years screen (plan phase 3 Task 4): the people's UK tax years, and one year's page —
/// rental accounts, settings, manual items, missing evidence and export. Everything it shows
/// comes from BudgetCore (`TaxOverview`, `RentalAccounts`, `AccountantTemplate`,
/// `RentalAccountsPDF`, `TaxEvidencePack`), read in one observation while the screen shows.
@MainActor
final class TaxYearsViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case income = "Income"
        case accounts = "Rental accounts"
        case taxReturn = "Return"
        case calculation = "Calculation"
        case filing = "Filing"
        case settings = "Settings"
        case manualItems = "Manual items"
        case missingEvidence = "Missing evidence"
        case export = "Export"
        var id: String { rawValue }

        /// The tabs that show the computed return (computed only while one of them shows).
        var needsSelfAssessment: Bool { [.taxReturn, .calculation, .filing].contains(self) }
    }

    /// The year on show.
    struct Selection: Hashable, Sendable {
        let personId: Int64
        let startYear: Int
    }

    struct Snapshot: Equatable, Sendable {
        var rows: [TaxOverview.YearRow] = []
        var page: TaxOverview.YearPage?
    }

    let dbQueue: DatabaseQueue
    let library: EvidenceLibrary
    private let rateFetcher: HMRCRateFetching
    /// Fetches the ended years' missing HMRC rates whenever the screen appears.
    private let rateAutoFetch: HMRCRateAutoFetch?

    @Published var selection: Selection? {
        didSet { if selection != oldValue { propertyId = nil; restartObservation() } }
    }
    /// The property of the page (a person owning several picks one).
    @Published var propertyId: Int64? {
        didSet { if propertyId != oldValue { restartObservation() } }
    }
    @Published var tab: Tab = .accounts {
        didSet {
            if tab != .calculation { focusedStep = nil }
            if tab.needsSelfAssessment != oldValue.needsSelfAssessment { restartObservation() }
        }
    }

    /// A Return box's drill-down: the calculation step to highlight and scroll to. Each
    /// request is new, so asking for the same step again scrolls again.
    struct StepRequest: Equatable {
        let title: String
        let id = UUID()
    }

    @Published var focusedStep: StepRequest?
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var isLoading = true
    @Published private(set) var isFetchingRate = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?


    private var observationTask: Task<Void, Never>?
    private var isActive = false

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary, rateFetcher: HMRCRateFetching = HMRCTradeTariffRateFetcher(),
         rateAutoFetch: HMRCRateAutoFetch? = nil) {
        self.dbQueue = dbQueue
        self.library = library
        self.rateFetcher = rateFetcher
        self.rateAutoFetch = rateAutoFetch
    }

    var page: TaxOverview.YearPage? { snapshot.page }
    var accounts: RentalAccounts.Result? { snapshot.page?.accounts }

    // MARK: Lifecycle

    func start() {
        isActive = true
        restartObservation()
        // In the background, each time the screen appears: the rates the ended years lack. Cheap
        // when there's nothing to do — one run at a time, each year asked for at most once a day.
        rateAutoFetch?.run()
    }

    /// The year's rates HMRCRates.fetchMissing stored, for the page's note.
    var automaticallyFetchedRates: [HMRCRate] { page?.rates.filter(\.isFetchedAutomatically) ?? [] }

    func stop() {
        isActive = false
        observationTask?.cancel()
        observationTask = nil
    }

    private func restartObservation() {
        observationTask?.cancel()
        observationTask = nil
        guard isActive else { return }
        isLoading = true
        let selection = selection, propertyId = propertyId, includeSelfAssessment = tab.needsSelfAssessment
        let values = ValueObservation
            .tracking { db in try Self.read(db: db, selection: selection, propertyId: propertyId, includeSelfAssessment: includeSelfAssessment) }
            .removeDuplicates()
            .values(in: dbQueue)
        observationTask = Task { [weak self] in
            do {
                for try await snapshot in values {
                    guard let self, !Task.isCancelled else { return }
                    self.snapshot = snapshot
                    self.isLoading = false
                    // The first year on show: the latest one in the list.
                    if self.selection == nil, let first = snapshot.rows.first, let personId = first.person.id {
                        self.selection = Selection(personId: personId, startYear: first.year.startYear)
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = "Couldn't read the tax years: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    nonisolated static func read(db: Database, selection: Selection?, propertyId: Int64?, includeSelfAssessment: Bool) throws -> Snapshot {
        var snapshot = Snapshot()
        snapshot.rows = try TaxOverview.rows(db: db, now: AppClock.now)
        if let selection {
            snapshot.page = try TaxOverview.page(db: db, personId: selection.personId, startYear: selection.startYear, propertyId: propertyId,
                                                 rows: snapshot.rows, includeSelfAssessment: includeSelfAssessment, now: AppClock.now)
        }
        return snapshot
    }

    // MARK: Editing

    /// Runs a write; the error's text when it fails.
    @discardableResult
    func write(_ body: (Database) throws -> Void) -> String? {
        do {
            try dbQueue.write { db in try body(db) }
            return nil
        } catch {
            return TaxMessages.text(for: error)
        }
    }

    /// Taking a year away from filed or paid goes through the filed-year check (plan Task 14): the
    /// rental accounts read the status, and the year stops being protected. Marking it filed or
    /// paid writes straight away.
    func setStatus(_ status: TaxYearStatus) {
        guard let selection else { return }
        let current = snapshot.rows.first { $0.year.startYear == selection.startYear && $0.person.id == selection.personId }?.status
        let write: (Database) throws -> Void = { db in
            try TaxOverview.setStatus(db: db, startYear: selection.startYear, personId: selection.personId, status: status)
        }
        guard current == .filed || current == .paid else {
            errorMessage = self.write(write)
            return
        }
        let label = UKTaxYear(startYear: selection.startYear).label
        checked(edit: "\(label) set to \(status.displayName.lowercased())", scope: .from(year: selection.startYear), write)
    }

    /// Stores a manual rate (pounds per unit, or units per £1 as HMRC publishes it), through the
    /// filed-year check (`gate` asks when it would change a filed return).
    func setRate(currencyCode: String, unitsPerPound: Double, gate: FiledYearGate, done: @escaping (String?) -> Void) {
        guard let selection else { return done(nil) }
        guard unitsPerPound > 0 else { return done("Enter a rate above zero.") }
        let label = UKTaxYear(startYear: selection.startYear).label
        checked(edit: "\(currencyCode) rate for \(label) entered by hand", scope: .from(year: selection.startYear), gate: gate, { db in
            try HMRCRates.set(db: db, startYear: selection.startYear, currencyCode: currencyCode, gbpPerUnit: 1 / unitsPerPound,
                              unitsPerPound: unitsPerPound, source: .manual, notes: "Entered by hand")
        }, done: done)
    }

    func removeRate(currencyCode: String) {
        guard let selection else { return }
        let label = UKTaxYear(startYear: selection.startYear).label
        checked(edit: "\(currencyCode) rate for \(label) removed", scope: .from(year: selection.startYear)) { db in
            _ = try HMRCRates.remove(db: db, startYear: selection.startYear, currencyCode: currencyCode)
        }
    }

    /// Whether the year on show is filed or paid (by anyone): HMRC's rate isn't fetched for it.
    var selectedYearIsFiled: Bool {
        guard let selection else { return false }
        return snapshot.rows.contains { $0.year.startYear == selection.startYear && ($0.status == .filed || $0.status == .paid) }
    }

    /// Fetches HMRC's published average for the year; a manual or filed-return rate stays
    /// unless `replace`.
    func fetchRate(replace: Bool) {
        guard let selection, !SnapshotMode.isActive else { return }
        let year = UKTaxYear(startYear: selection.startYear)
        // A filed or paid year's figures stay as filed (plan Task 14): its rate is entered by hand.
        guard !selectedYearIsFiled else {
            infoMessage = "\(year.label) is filed, so HMRC's rate isn't fetched for it: its figures stay as filed. Enter a rate by hand to change it."
            return
        }
        isFetchingRate = true
        Task {
            let rates = await rateFetcher.fetchAverageRates(for: year)
            isFetchingRate = false
            guard let rates else {
                errorMessage = "Couldn't fetch HMRC's average rates for \(year.label) (offline, or not published yet)."
                return
            }
            guard rates.contains(where: { $0.currencyCode == "EUR" }) else {
                errorMessage = "HMRC's average rates for \(year.label) have no EUR rate: enter it by hand."
                return
            }
            var stored: [HMRCRate] = []
            errorMessage = write { db in
                stored = try HMRCRates.storePublished(db: db, startYear: selection.startYear, rates: rates, codes: ["EUR"], replaceAll: replace)
            }
            if errorMessage == nil {
                infoMessage = stored.isEmpty ? "The year's EUR rate was kept (entered by hand or from a filed return)."
                    : "HMRC's average EUR rate for \(year.label) stored."
            }
        }
    }

    /// Sets (or with nil removes) a split, through the filed-year check (`gate`: the sheet's; nil: the screen's).
    func setSplit(expenseType: TaxExpenseType?, shareBasisPoints: Int?, gate: FiledYearGate? = nil,
                  done: ((String?) -> Void)? = nil) {
        guard let selection, let propertyId = page?.property?.id else { return (done ?? { _ in })(nil) }
        let name = expenseType?.displayName ?? "every type"
        let edit = shareBasisPoints.map { "Split for \(name) set to \(PropertyFormat.percent($0))" } ?? "Split for \(name) removed"
        checked(edit: edit, scope: .from(year: selection.startYear), gate: gate, { db in
            try TaxSplits.set(db: db, startYear: selection.startYear, personId: selection.personId, propertyId: propertyId,
                              expenseType: expenseType, shareBasisPoints: shareBasisPoints)
        }, done: done)
    }

    /// Sets a type's rule for every year or this year; `nil` removes the stored one at that
    /// scope. Saving for every year also drops this year's override, so the year follows it.
    /// Through the filed-year check (`gate`: the sheet's): a rule of every year reaches every year.
    func setRule(_ type: TaxExpenseType, rule: TaxAttributionRuleKind?, thisYearOnly: Bool, coverMonths: Int?,
                 gate: FiledYearGate, done: @escaping (String?) -> Void) {
        guard let selection else { return done(nil) }
        let year = thisYearOnly ? selection.startYear : nil
        let scope: FiledYearEditCheck.Scope = thisYearOnly ? .from(year: selection.startYear) : .everyYear
        let edit = "Rule for \(type.displayName) " + (rule.map { "set to \($0.displayName)" } ?? "removed")
            + (thisYearOnly ? " for \(UKTaxYear(startYear: selection.startYear).label)" : " for every year")
        checked(edit: edit, scope: scope, gate: gate, { db in
            if let rule {
                try TaxAttributionRules.set(db: db, expenseType: type, startYear: year, rule: rule, defaultCoverMonths: coverMonths)
                if !thisYearOnly { _ = try TaxAttributionRules.remove(db: db, expenseType: type, startYear: selection.startYear) }
            } else {
                _ = try TaxAttributionRules.remove(db: db, expenseType: type, startYear: year)
            }
        }, done: done)
    }

    func setCategoryType(categoryId: Int64, _ type: TaxExpenseType?) {
        let name = page?.categoryTypes.first { $0.category.id == categoryId }?.category.name ?? "a category"
        checked(edit: "Tax line of \(name) set to \(type?.displayName ?? "its suggestion")", scope: .everyYear) { db in
            try TaxExpenseTypeMap.set(db: db, categoryId: categoryId, expenseType: type)
        }
    }

    func confirmSuggestedTypes() {
        guard let propertyId = page?.property?.id else { return }
        checked(edit: "Suggested tax lines confirmed", scope: .everyYear) { db in _ = try TaxExpenseTypeMap.seed(db: db, propertyId: propertyId) }
    }

    /// Saves a manual item through the filed-year check (`gate`: the sheet's).
    func saveManualItem(_ item: TaxManualItem, documents: EvidenceLinkChanges, gate: FiledYearGate, done: @escaping (String?) -> Void) {
        let edit = (item.id == nil ? "Manual item “\(item.label)” added" : "Manual item “\(item.label)” edited")
        let scope = FiledYearEditCheck.Scope(manualItemIds: item.id.map { [$0] } ?? [], years: [item.startYear])
        checked(edit: edit, scope: scope, gate: gate, { db in
            var item = item
            try TaxManualItems.save(db: db, &item, documents: documents)
        }, done: done)
    }

    /// Deletes a manual item through the filed-year check (the screen's gate asks).
    func deleteManualItem(_ id: Int64, label: String = "") {
        checked(edit: "Manual item “\(label)” deleted", scope: FiledYearEditCheck.Scope(manualItemIds: [id])) { db in
            _ = try TaxManualItems.delete(db: db, id: id)
        }
    }

    /// The screen's edits through the filed-year check (plan Task 14); its question shows on the Tax screen.
    let filedYearGate = FiledYearGate()

    /// A write through the filed-year check, off the main thread: `done` gets the error's text, or
    /// nil once saved (default: the screen's banner); Cancel calls nothing. The screen's
    /// observation shows what was written.
    func checked(edit: String, scope: FiledYearEditCheck.Scope, gate: FiledYearGate? = nil,
                 _ body: @escaping (Database) throws -> Void, done: ((String?) -> Void)? = nil) {
        let done = done ?? { [weak self] message in self?.errorMessage = message }
        (gate ?? filedYearGate).run(dbQueue, edit: edit, scope: scope, body) { result in
            done(result.failure.map(TaxMessages.text(for:)))
        }
    }

    /// Marks a source "deductible, not claimed" in the year on show (or claims it again).
    /// Through the filed-year check (`gate`: the sources sheet's): on a filed year it moves the
    /// filed line, so it asks (Save anyway or Cancel) and Save anyway notes it.
    func setNotClaimed(_ reference: RentalAccounts.SourceReference, notClaimed: Bool, gate: FiledYearGate, done: @escaping (String?) -> Void) {
        guard let selection else { return done(nil) }
        let label = UKTaxYear(startYear: selection.startYear).label
        checked(edit: notClaimed ? "Marked not claimed in \(label)" : "Claimed again in \(label)", scope: .from(year: selection.startYear),
                gate: gate, { db in
            try TaxNotClaimedSources.set(db: db, startYear: selection.startYear, reference: reference, notClaimed: notClaimed,
                                         notes: notClaimed ? "Marked in the app" : nil)
        }, done: done)
    }

    // MARK: Drill-down

    /// A source's record, for Show.
    func transaction(_ id: Int64) -> EvidenceTransactionInfo? {
        try? dbQueue.read { db -> EvidenceTransactionInfo? in
            guard let transaction = try Transaction.fetchOne(db, key: id) else { return nil }
            let account = try Account.fetchOne(db, key: transaction.accountId)
            let category = try transaction.categoryId.flatMap { try Category.fetchOne(db, key: $0) }
            return EvidenceTransactionInfo(transaction: transaction, accountName: account?.displayName ?? "",
                                           currency: account?.currency ?? .gbp, categoryName: category?.name)
        }
    }

    func receipt(_ id: Int64) -> RentReceipt? {
        try? dbQueue.read { db in try RentReceipt.fetchOne(db, key: id) }
    }

    func documents(_ ids: [Int64]) -> [EvidenceDocument] {
        ids.compactMap { try? library.document(id: $0) }
    }

    func documents(for entity: EvidenceEntity) -> [EvidenceDocument] {
        (try? library.documents(for: entity)) ?? []
    }

    func open(_ document: EvidenceDocument) {
        NSWorkspace.shared.open(library.fileURL(for: document))
    }

    // MARK: Export

    /// The accountant's template for the person on show, via a save panel.
    func exportTemplate() {
        guard let selection, let page, let propertyId = page.property?.id else { return }
        let year = UKTaxYear(startYear: selection.startYear)
        let name = AccountantTemplate.fileName(taxYear: year, personName: page.row.person.name)
        do {
            let data = try dbQueue.read { db in
                try AccountantTemplate.xlsx(db: db, taxYear: year, personId: selection.personId, propertyId: propertyId)
            }
            save(data, suggestedName: name, type: UTType(filenameExtension: "xlsx") ?? .data)
        } catch {
            errorMessage = "Couldn't make the template: \(TaxMessages.text(for: error))"
        }
    }

    func exportPDF() {
        guard let page, let accounts = page.accounts, let property = page.property else { return }
        let data = RentalAccountsPDF.data(accounts: accounts, personName: page.row.person.name, propertyName: property.name)
        let name = TaxFileNames.rentalAccountsPDF(year: accounts.taxYear, personName: page.row.person.name)
        save(data, suggestedName: name, type: .pdf)
    }

    /// Copies the year's documents into a new folder (one subfolder per line) in a chosen
    /// folder, off the main thread. Never removes or replaces a file: an existing folder of
    /// that name gets a " (2)" sibling, and a clash inside fails the export.
    func exportEvidencePack() {
        guard let page, let accounts = page.accounts else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "Choose where to put the evidence folder."
        // Nothing is written if Mango locked while the panel was open.
        guard panel.runModal() == .OK, let parent = panel.url, SessionModel.appCanActOnData else { return }
        let files: [TaxEvidencePack.File]
        do {
            files = try dbQueue.read { db in try TaxEvidencePack.files(db: db, accounts: accounts, taxYearId: page.row.taxYearId) }
        } catch {
            errorMessage = "Couldn't list the evidence: \(error.localizedDescription)"
            return
        }
        guard !files.isEmpty else {
            infoMessage = "No documents are linked to this year's figures yet."
            return
        }
        let baseName = TaxEvidencePack.folderName(year: accounts.taxYear, personName: page.row.person.name)
        let library = library
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    try EvidenceFiles.withAccess(parent) {
                        let manager = FileManager.default
                        var root = parent.appendingPathComponent(baseName, isDirectory: true)
                        var counter = 2
                        while manager.fileExists(atPath: root.path) {
                            root = parent.appendingPathComponent("\(baseName) (\(counter))", isDirectory: true)
                            counter += 1
                        }
                        for file in files {
                            guard let document = try library.document(id: file.documentId) else { continue }
                            let folder = root.appendingPathComponent(file.folder, isDirectory: true)
                            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                            // copyItem fails on an existing file: nothing is ever overwritten.
                            try manager.copyItem(at: library.fileURL(for: document), to: folder.appendingPathComponent(file.fileName))
                        }
                        return root
                    }
                }
            }.value
            switch outcome {
            case let .success(root):
                infoMessage = "Copied \(files.count) document\(files.count == 1 ? "" : "s") to “\(root.lastPathComponent)”."
                NSWorkspace.shared.activateFileViewerSelecting([root])
            case let .failure(error):
                errorMessage = "Couldn't export the evidence: \(error.localizedDescription)"
            }
        }
    }

    private func save(_ data: Data, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        // Nothing is written if Mango locked while the panel was open.
        guard panel.runModal() == .OK, let url = panel.url, SessionModel.appCanActOnData else { return }
        do {
            try data.write(to: url, options: .atomic)
            infoMessage = "Saved “\(url.lastPathComponent)”."
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Readable text for the tax screens' errors.
enum TaxMessages {
    static func text(for error: Error) -> String {
        switch error {
        case let error as TaxError: return text(error)
        case let error as PropertyError: return PropertyMessages.text(error)
        default: return error.localizedDescription
        }
    }

    static func text(_ error: TaxError) -> String {
        switch error {
        case .personNotFound: return "That person no longer exists."
        case .propertyNotFound: return "The property no longer exists."
        case .categoryNotFound: return "That category no longer exists."
        case .taxYearNotFound: return "That tax year no longer exists."
        case .invalidShare: return "A share must be between 0% and 100%."
        case .blankLabel: return "Enter a description."
        case .negativeAmount: return "Amounts can't be negative."
        case .invalidRate: return "Enter a rate above zero."
        case .invalidCurrencyCode: return "Use a three-letter currency code, e.g. EUR."
        case .invalidCoverMonths: return "Cover months must be 1 or more."
        case .transactionNotFound: return "That transaction no longer exists."
        case .invalidInstalment: return "The instalment number must be between 1 and the number of instalments."
        case .invalidCoverPeriod: return "The cover must end after it starts."
        case .notAnOwner: return "That person doesn't own the property on the payment's date."
        case .notClaimable: return "Only a cost of a deductible line (an expense or the mortgage interest) can be marked not claimed."
        case .sourceNotFound: return "That source no longer exists."
        case .notASourceOfTheYear: return "That source doesn't feed this year's rental accounts."
        case .invalidWindowShift: return "Only one year's rule with months (quota, cover or policy year) can move its window, by 11 months at most."
        case .itemsExceedPayment: return "The payment's items add up to more than the payment."
        }
    }
}

/// Formatting for the tax screens.
enum TaxFormat {
    static func status(_ status: TaxYearStatus) -> String { status.displayName }

    static func statusImage(_ status: TaxYearStatus) -> String {
        switch status {
        case .preparing: return "pencil.circle"
        case .ready: return "checkmark.circle"
        case .filed: return "paperplane.circle"
        case .paid: return "checkmark.seal"
        }
    }

    /// The status pill's tone: preparing not started, ready under way, filed and paid done.
    static func statusTone(_ status: TaxYearStatus) -> StatusPill.Tone {
        switch status {
        case .preparing: return .neutral
        case .ready: return .accent
        case .filed, .paid: return .positive
        }
    }

    /// Every deadline of the year, for a tooltip.
    static func deadlines(_ year: UKTaxYear) -> String {
        let d = year.deadlines
        return "\(year.label): online return and balancing payment by \(DocumentFormat.day(d.onlineReturnAndBalancingPayment)), "
            + "second payment on account by \(DocumentFormat.day(d.secondPaymentOnAccount)), "
            + "paper return by \(DocumentFormat.day(d.paperReturn))."
    }

    /// "1.1655 EUR per £1".
    static func unitsPerPound(_ rate: HMRCRate) -> String {
        String(format: "%.4f %@ per £1", rate.unitsPerPound ?? 1 / rate.gbpPerUnit, rate.currencyCode)
    }

    /// "£0.8580 per euro".
    static func poundsPerUnit(_ rate: HMRCRate) -> String {
        let unit = rate.currencyCode == "EUR" ? "euro" : rate.currencyCode
        return String(format: "£%.4f per %@", rate.gbpPerUnit, unit)
    }

    /// The rate's source as a pill's title and tone: a filed return's rate done, HMRC's
    /// published one (fetched by hand or automatically) under way, one entered by hand neutral.
    static func sourcePill(_ rate: HMRCRate) -> (title: String, tone: StatusPill.Tone, systemImage: String?) {
        if rate.isFetchedAutomatically { return ("Fetched automatically", .accent, "arrow.down.circle") }
        switch rate.source {
        case .filedReturn: return ("Filed return", .positive, nil)
        case .hmrcPublished: return ("HMRC published", .accent, nil)
        case .manual: return ("Entered by hand", .neutral, nil)
        }
    }

    static func rate(_ rate: HMRCRate) -> String {
        let units = rate.unitsPerPound ?? 1 / rate.gbpPerUnit
        return String(format: "%.4f %@ per £1 (£%.4f)", units, rate.currencyCode, rate.gbpPerUnit)
    }

    /// The rate's source, noting one fetched automatically.
    static func source(of rate: HMRCRate) -> String {
        rate.isFetchedAutomatically ? "HMRC published, fetched automatically" : source(rate.source)
    }

    static func source(_ source: HMRCRateSource) -> String {
        switch source {
        case .filedReturn: return "from a filed return"
        case .hmrcPublished: return "HMRC published"
        case .manual: return "entered by hand"
        }
    }
}
