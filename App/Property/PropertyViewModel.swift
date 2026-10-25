// App/Property/PropertyViewModel.swift
import Foundation
import AppKit
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB

/// One property's page (spec 2026-10-16 §1): everything its tabs show, read in one
/// observation (so imports, edits and links made anywhere refresh it while it shows), and the
/// edits its sheets make. All the figures come from BudgetCore (`PropertyFinance`,
/// `PropertyCalendar`, `PropertyChecks`, `PropertyPage`).
@MainActor
final class PropertyViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case tenancies = "Tenancies"
        case recharges = "Recharges"
        case money = "Money"
        case calendar = "Calendar"
        case checks = "Checks"
        case profile = "Profile"
        var id: String { rawValue }
    }

    enum PeriodChoice: Hashable {
        case calendarYear(Int)
        case taxYear(Int)
        case custom
    }

    /// A category group, as the pickers list it.
    struct GroupInfo: Equatable, Identifiable, Sendable {
        let id: Int64
        let name: String
    }

    /// What the mortgage accounts owe at the end of a day, in the property's currency.
    struct LoanPoint: Equatable, Sendable {
        let date: Date
        let owedMinorUnits: Int
    }

    /// What one observation reads.
    struct Snapshot: Equatable, Sendable {
        var property: Property?
        var people: [Person] = []
        var owners: [PropertyOwner] = []
        var accounts: [Account] = []
        var propertyAccounts: [PropertyAccount] = []
        var groups: [GroupInfo] = []
        var groupIds: [Int64] = []
        var tenancies: [Tenancy] = []
        var rents: [Int64: [TenancyRent]] = [:]
        var receipts: [Int64: [TenancyReceiptRow]] = [:]
        /// Documents linked to each tenancy (its contract).
        var tenancyDocumentCounts: [Int64: Int] = [:]
        var summary: PropertySummary?
        /// The next twelve months.
        var obligations: [PropertyObligation] = []
        var checks: PropertyCheckReport?
        var documents: [EvidenceDocument] = []
        var categoryNames: [Int64: String] = [:]
        var hasEvidenceRules = false
        /// The loan at each month end since the mortgage accounts' first record, then today
        /// (Overview's loan chart).
        var loanHistory: [LoanPoint] = []
        /// The loan before its first record, estimated from the amount borrowed and the rules
        /// (`MortgageHistory`); nil without them.
        var loanEstimate: MortgageHistory.Estimate?
        /// How much of the amount borrowed is repaid today; nil without the amount.
        var loanProgress: MortgageHistory.Progress?
        /// The mortgage's terms (revision schedule, final instalment, balloon, rate), saved or default.
        var mortgageTerms: PropertyMortgageTerms?
        /// Where the loan's projection starts (`MortgageProjection.basis`) and the projection
        /// from today to the end; nil when there's no loan to project.
        var loanBasis: MortgageProjection.Basis?
        var loanProjection: MortgageProjection.Result?
        /// The rate in force, the next revision and instalment (`MortgageRate.status`).
        var rateStatus: MortgageRate.Status?
        /// The rates given for single periods (Mortgage terms…).
        var rateOverrides: [MortgageRateOverride] = []
        /// The current account (rent's) and the day of its latest transaction: how far its
        /// imports run, for the receipts' explanations.
        var currentAccountName: String?
        var currentAccountLastDay: Date?
    }

    /// What the side panel beside the page shows.
    enum SidePanel: Equatable {
        /// A month of the Cash flow by month chart (Overview, Money): its transactions.
        case month(DateInterval)
        /// A recharge statement (Recharges): its charges and the credits that paid it.
        case rechargeStatement(id: Int64, tenancyId: Int64)
        /// A month of the Recharges chart (its first day): invoices paid, statements, credits.
        case rechargeMonth(Date, tenancyId: Int64)
        /// A rent receipt (Tenancies): its details, the credits that paid it, its PDF.
        case receipt(id: Int64, tenancyId: Int64)
    }

    /// Bumped when the side panel changed recharges (its statement sheet closed), so the
    /// Recharges tab re-reads.
    @Published var rechargesRevision = 0

    /// How far the Outstanding loan chart reaches.
    enum LoanRange: String, CaseIterable, Identifiable {
        case soFar = "So far"
        /// Five years back and five on, around today.
        case fiveYears = "±5 years"
        case toTheEnd = "To the end"
        var id: String { rawValue }
    }

    let dbQueue: DatabaseQueue
    let library: EvidenceLibrary

    @Published var propertyId: Int64? {
        didSet { if propertyId != oldValue { selectedTenancyId = nil; sidePanel = nil; restartObservation() } }
    }
    @Published var tab: Tab = .overview {
        didSet { if tab != oldValue { closeSidePanelIfHidden() } }
    }
    /// The side panel open beside the page (Escape or ✕ closes it).
    @Published var sidePanel: SidePanel?
    @Published var loanRange: LoanRange = .soFar
    @Published var periodChoice: PeriodChoice {
        didSet { if periodChoice != oldValue { closeMonthPanel(); restartObservation() } }
    }
    /// The custom range's first and last days (UTC midnights).
    @Published var customFirstDay: Date {
        didSet { if customFirstDay != oldValue, periodChoice == .custom { closeMonthPanel(); restartObservation() } }
    }
    @Published var customLastDay: Date {
        didSet { if customLastDay != oldValue, periodChoice == .custom { closeMonthPanel(); restartObservation() } }
    }
    @Published var selectedTenancyId: Int64? {
        didSet {
            switch sidePanel {
            case let .rechargeStatement(_, tenancyId), let .rechargeMonth(_, tenancyId), let .receipt(_, tenancyId):
                if tenancyId != selectedTenancy?.id { sidePanel = nil }
            default: break
            }
        }
    }
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var isLoading = true
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    /// Called after a property is added (with its id) or deleted (nil), so the sidebar re-reads.
    var onPropertiesChanged: ((Int64?) -> Void)?

    private var observationTask: Task<Void, Never>?
    /// Re-reads at midnight, so "today" (checks, calendar, yields) moves on.
    private var dayObserver: NSObjectProtocol?
    private var isActive = false
    private let now: () -> Date

    /// Fetches the Euribor the mortgage follows when the page opens (nil in tests and snapshots).
    private let indexAutoFetch: InterestIndexAutoFetch?

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary, indexAutoFetch: InterestIndexAutoFetch? = nil,
         now: @escaping () -> Date = { AppClock.now }) {
        self.dbQueue = dbQueue
        self.library = library
        self.indexAutoFetch = indexAutoFetch
        self.now = now
        let today = now()
        let year = MonthRange.components(of: today).year
        periodChoice = .calendarYear(year)
        customFirstDay = MonthRange.of(year: year, month: 1).start
        customLastDay = PropertyDays.utcToday(today)
    }

    // MARK: Lifecycle

    func start() {
        isActive = true
        dayObserver = dayObserver ?? NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartObservation() }
        }
        restartObservation()
        indexAutoFetch?.run()
    }

    func stop() {
        isActive = false
        observationTask?.cancel()
        observationTask = nil
    }

    /// The years the period picker offers: from the property's first tenancy (or purchase) to
    /// next year, latest first.
    var years: [Int] {
        let current = MonthRange.components(of: now()).year
        let first = [snapshot.tenancies.map(\.startDate).min(), snapshot.property?.purchaseDate]
            .compactMap { $0 }.map { MonthRange.components(of: $0).year }.min() ?? current
        return Array(min(first, current)...(current + 1)).reversed()
    }

    var period: PropertyPeriod? {
        switch periodChoice {
        case let .calendarYear(year): return .calendarYear(year)
        case let .taxYear(year): return .ukTaxYear(UKTaxYear(startYear: year))
        case .custom:
            guard customFirstDay <= customLastDay else { return nil }
            return .custom(DateInterval(start: customFirstDay, end: PropertyDays.utcNextDay(customLastDay)))
        }
    }

    var property: Property? { snapshot.property }
    var currency: Currency { snapshot.property?.currency ?? .eur }

    var selectedTenancy: Tenancy? {
        let id = selectedTenancyId ?? currentTenancy?.id
        return snapshot.tenancies.first { $0.id == id }
    }

    /// The tenancy's rent in force today (else its latest).
    func rentInForce(_ tenancy: Tenancy) -> TenancyRent? {
        let today = PropertyDays.utcToday(now())
        let rents = snapshot.rents[tenancy.id ?? -1] ?? []
        return rents.last { $0.fromDate <= today } ?? rents.last
    }

    /// Whether the tenancy runs today.
    func isRunning(_ tenancy: Tenancy) -> Bool {
        tenancy.covers(PropertyDays.utcToday(now()))
    }

    /// The tenancy running today, else the latest.
    var currentTenancy: Tenancy? {
        let today = PropertyDays.utcToday(now())
        return snapshot.tenancies.last { $0.covers(today) } ?? snapshot.tenancies.last
    }

    func personName(_ id: Int64) -> String { snapshot.people.first { $0.id == id }?.name ?? "Person #\(id)" }
    func accountName(_ id: Int64) -> String { snapshot.accounts.first { $0.id == id }?.displayName ?? "Account #\(id)" }
    func groupName(_ id: Int64) -> String { snapshot.groups.first { $0.id == id }?.name ?? "Group #\(id)" }
    func account(_ id: Int64) -> Account? { snapshot.accounts.first { $0.id == id } }

    private func restartObservation() {
        observationTask?.cancel()
        observationTask = nil
        guard isActive, let propertyId else {
            snapshot = Snapshot()
            isLoading = false
            return
        }
        isLoading = true
        let period = period
        let today = PropertyDays.utcToday(now())
        let values = ValueObservation
            .tracking { db in try Self.read(db: db, propertyId: propertyId, period: period, today: today) }
            .removeDuplicates()
            .values(in: dbQueue)
        observationTask = Task { [weak self] in
            do {
                for try await snapshot in values {
                    guard let self, !Task.isCancelled else { return }
                    self.snapshot = snapshot
                    self.isLoading = false
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = "Couldn't read the property: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    nonisolated static func read(db: Database, propertyId: Int64, period: PropertyPeriod?, today: Date) throws -> Snapshot {
        var snapshot = Snapshot()
        guard let property = try Property.fetchOne(db, key: propertyId) else { return snapshot }
        snapshot.property = property
        snapshot.people = try People.all(db: db)
        snapshot.owners = try Properties.owners(db: db, propertyId: propertyId)
        snapshot.accounts = try Account.fetchAll(db).sortedForDisplay()
        snapshot.propertyAccounts = try Properties.accounts(db: db, propertyId: propertyId)
        snapshot.groups = try CategoryGroup.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
            .compactMap { group in group.id.map { GroupInfo(id: $0, name: group.name) } }
        snapshot.groupIds = try Properties.categoryGroupIds(db: db, propertyId: propertyId)
        snapshot.tenancies = try Tenancies.all(db: db, propertyId: propertyId)
        for tenancy in snapshot.tenancies {
            snapshot.rents[tenancy.id!] = try Tenancies.rents(db: db, tenancyId: tenancy.id!)
            snapshot.receipts[tenancy.id!] = try PropertyPage.receiptRows(db: db, tenancyId: tenancy.id!)
        }
        snapshot.tenancyDocumentCounts = try EvidenceLinks.linkCounts(db: db, .tenancy)
        if let period {
            snapshot.summary = try PropertyFinance.summary(db: db, propertyId: propertyId, period: period, today: today)
            snapshot.checks = try PropertyChecks.run(db: db, propertyId: propertyId, period: period.interval, today: today)
        }
        // `today` is already the stored (UTC) day.
        let end = MonthRange.calendar.date(byAdding: .month, value: 12, to: today)!
        snapshot.obligations = try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: today, to: end, today: today)
        snapshot.documents = try EvidenceLinks.documents(db: db, for: .property(propertyId))
        snapshot.categoryNames = Dictionary(uniqueKeysWithValues: try Category.fetchAll(db).compactMap { c in c.id.map { ($0, c.name) } })
        snapshot.hasEvidenceRules = try PropertyEvidence.defaultRules(db: db, propertyId: propertyId).isEmpty
        let mortgageIds = snapshot.propertyAccounts.filter { $0.role == .mortgage }.map(\.accountId)
        snapshot.mortgageTerms = try MortgageTerms.terms(db: db, propertyId: propertyId)
        snapshot.loanEstimate = try MortgageHistory.estimate(db: db, propertyId: propertyId)
        // With an estimate, the history reaches back to where it ends (the day before the
        // first instalment paid into the loan), however long ago.
        let anchorDay = snapshot.loanEstimate.map { MonthRange.calendar.date(byAdding: .day, value: -1, to: $0.anchor.paidOn)! }
        snapshot.loanHistory = try loanHistory(db: db, property: property, accountIds: mortgageIds, today: today, reachingBack: anchorDay)
        if let terms = snapshot.mortgageTerms, let owed = snapshot.loanHistory.last?.owedMinorUnits {
            snapshot.loanProgress = MortgageHistory.progress(terms: terms, owedMinorUnits: owed, today: today)
        }
        snapshot.loanBasis = try MortgageProjection.basis(db: db, propertyId: propertyId, today: today)
        snapshot.loanProjection = snapshot.loanBasis.map { MortgageProjection.project($0.input) }
        snapshot.rateStatus = try MortgageRate.status(db: db, propertyId: propertyId, today: today)
        snapshot.rateOverrides = try MortgageRate.overrides(db: db, propertyId: propertyId)
        if let current = snapshot.propertyAccounts.first(where: { $0.role == .current }) {
            snapshot.currentAccountName = snapshot.accounts.first { $0.id == current.accountId }?.displayName
            snapshot.currentAccountLastDay = try Transaction.filter(Column("accountId") == current.accountId)
                .select(GRDB.max(Column("date")), as: Date.self).fetchOne(db)
        }
        return snapshot
    }

    /// The most month ends the loan chart reads (ten years).
    nonisolated static let loanHistoryMonths = 120

    /// What `accountIds` (the mortgage) owe at the end of each month from their first record
    /// (at most `loanHistoryMonths` back, or `reachingBack` when earlier) and at the end of `today`, read by
    /// `PropertyFinance.loanBalances` (the rule of `PropertyFinance.balance`, which gives the
    /// summary's outstanding loan).
    nonisolated static func loanHistory(db: Database, property: Property, accountIds: [Int64], today: Date,
                                        reachingBack: Date? = nil) throws -> [LoanPoint] {
        guard !accountIds.isEmpty else { return [] }
        let firstSnapshot = try BalanceSnapshot.filter(accountIds.contains(Column("accountId")))
            .select(GRDB.min(Column("date")), as: Date.self).fetchOne(db)
        let firstTransaction = try Transaction.filter(accountIds.contains(Column("accountId")))
            .select(GRDB.min(Column("date")), as: Date.self).fetchOne(db)
        guard let first = [firstSnapshot, firstTransaction].compactMap({ $0 }).min() else { return [] }
        let calendar = MonthRange.calendar
        let earliest = min(calendar.date(byAdding: .month, value: -loanHistoryMonths, to: today)!, reachingBack ?? .distantFuture)
        let start = max(calendar.startOfDay(for: first), earliest)
        guard start <= today else { return [] }
        var days = [start]
        var month = MonthRange.components(of: start)
        while true {
            let lastDay = calendar.startOfDay(for: MonthRange.of(year: month.year, month: month.month).end)
            if lastDay >= today { break }
            if lastDay > start { days.append(lastDay) }
            month = MonthRange.components(of: calendar.date(byAdding: .month, value: 1, to: MonthRange.of(year: month.year, month: month.month).start)!)
        }
        if today > start { days.append(today) }
        let balances = try PropertyFinance.loanBalances(db: db, property: property, accountIds: accountIds, days: days)
        return zip(days, balances).map { LoanPoint(date: $0, owedMinorUnits: $1.native) }
    }

    // MARK: Editing

    /// Runs a write; the error's text when it fails (the sheets show it).
    @discardableResult
    func write(_ body: (Database) throws -> Void) -> String? {
        do {
            try dbQueue.write { db in try body(db) }
            return nil
        } catch {
            return PropertyMessages.text(for: error)
        }
    }

    // MARK: Through the filed-year check (plan Task 14)

    /// The screen's edits of what the rental accounts read; its question shows on the Property screen.
    let filedYearGate = FiledYearGate()

    /// `body` through the filed-year check, off the main thread (`gate`: a sheet's; nil: the
    /// screen's). `done` gets the result; Cancel calls nothing. The observation shows what changed.
    func checked<T>(_ edit: String, scope: FiledYearEditCheck.Scope = .everyYear, gate: FiledYearGate? = nil,
                    _ body: @escaping (Database) throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        (gate ?? filedYearGate).run(dbQueue, edit: edit, scope: scope, body, done: done)
    }

    /// `checked`, its error's text to `done` (default: the screen's banner).
    func checkedWrite(_ edit: String, gate: FiledYearGate? = nil, _ body: @escaping (Database) throws -> Void,
                      done: ((String?) -> Void)? = nil) {
        let done = done ?? { [weak self] message in self?.errorMessage = message }
        checked(edit, gate: gate, body) { result in done(result.failure.map(PropertyMessages.text(for:))) }
    }

    /// The property's name for the question ("Property A").
    private var propertyName: String { property?.name ?? "the property" }

    func saveProperty(_ property: Property, gate: FiledYearGate, done: @escaping (Result<Int64, Error>) -> Void) {
        // A new property has no owners or categories yet: it moves nothing.
        checked("\(property.name) edited", scope: property.id == nil ? FiledYearEditCheck.Scope() : .everyYear, gate: gate, { db in
            var property = property
            try Properties.save(db: db, &property)
            return property.id!
        }, done: done)
    }

    func deleteProperty() {
        guard let propertyId else { return }
        checkedWrite("\(propertyName) deleted", { db in _ = try Properties.delete(db: db, id: propertyId) }) { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
            if message == nil {
                self.propertyId = nil
                self.onPropertiesChanged?(nil)
            }
        }
    }

    func savePerson(_ person: Person) -> Result<Person, Error> {
        Result {
            try dbQueue.write { db in
                var person = person
                try People.save(db: db, &person)
                return person
            }
        }
    }

    func setOwners(_ owners: [PropertyOwner], gate: FiledYearGate, done: @escaping (String?) -> Void) {
        guard let propertyId else { return done(nil) }
        checkedWrite("Owners of \(propertyName) changed", gate: gate, { db in
            _ = try Properties.setOwners(db: db, propertyId: propertyId, owners)
        }, done: done)
    }

    func setAccount(_ accountId: Int64, role: PropertyAccountRole, gate: FiledYearGate? = nil, done: ((String?) -> Void)? = nil) {
        guard let propertyId else { return (done ?? { _ in })(nil) }
        checkedWrite("Account of \(propertyName) set as \(role.rawValue)", gate: gate, { db in
            _ = try Properties.setAccount(db: db, propertyId: propertyId, accountId: accountId, role: role)
        }, done: done)
    }

    func removeAccount(_ accountId: Int64) {
        guard let propertyId else { return }
        checkedWrite("Account removed from \(propertyName)") { db in
            _ = try Properties.removeAccount(db: db, propertyId: propertyId, accountId: accountId)
        }
    }

    /// The stored values of an index (the Mortgage terms sheet's preview of the rate).
    func rateSeries(_ index: InterestIndex) -> MortgageRate.Series {
        (try? dbQueue.read { db in try MortgageRate.Series.load(db: db, index: index) }) ?? MortgageRate.Series(index: index)
    }

    /// Saves the mortgage's terms and the rates given for single periods (Profile ▸ Mortgage
    /// terms…): the overrides listed replace the stored ones.
    func saveMortgageTerms(_ terms: PropertyMortgageTerms, overrides: [MortgageRateOverride]) -> String? {
        write { db in
            try MortgageTerms.save(db: db, terms)
            let kept = Set(overrides.map { MonthRange.calendar.startOfDay(for: $0.periodStart) })
            for existing in try MortgageRate.overrides(db: db, propertyId: terms.propertyId) where !kept.contains(existing.periodStart) {
                try MortgageRate.removeOverride(db: db, propertyId: terms.propertyId, periodStart: existing.periodStart)
            }
            for given in overrides {
                try MortgageRate.setOverride(db: db, propertyId: terms.propertyId, periodStart: given.periodStart, ratePercent: given.ratePercent, note: given.note)
            }
        }
    }

    func addGroup(_ groupId: Int64) {
        guard let propertyId else { return }
        checkedWrite("Category group added to \(propertyName)") { db in
            try Properties.addCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: groupId)
        }
    }

    func removeGroup(_ groupId: Int64) {
        guard let propertyId else { return }
        checkedWrite("Category group removed from \(propertyName)") { db in
            _ = try Properties.removeCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: groupId)
        }
    }

    /// Saves the tenancy and its rent history together.
    func saveTenancy(_ tenancy: Tenancy, rents: [TenancyRent]) -> String? {
        var saved: Int64?
        let error = write { db in
            var tenancy = tenancy
            try Tenancies.save(db: db, &tenancy)
            _ = try Tenancies.setRents(db: db, tenancyId: tenancy.id!, rents)
            saved = tenancy.id
        }
        if error == nil, let saved { selectedTenancyId = saved }
        return error
    }

    func deleteTenancy(_ id: Int64) -> String? {
        let error = write { db in _ = try Tenancies.delete(db: db, id: id) }
        if error == nil, selectedTenancyId == id { selectedTenancyId = nil }
        return error
    }

    /// Links rent credits to receipts (`RentReceiptMatching.match`) and says what it did.
    func matchCredits() {
        guard let propertyId else { return }
        checked("Rent credits matched to receipts", { db in try RentReceiptMatching.match(db: db, propertyId: propertyId) }) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let result):
                self.errorMessage = nil
                self.infoMessage = "Linked \(result.created.count) credit\(result.created.count == 1 ? "" : "s"). "
                    + "\(result.unmatchedReceipts.count) receipt\(result.unmatchedReceipts.count == 1 ? "" : "s") and "
                    + "\(result.unmatchedCredits.count) credit\(result.unmatchedCredits.count == 1 ? "" : "s") remain unmatched."
            case .failure(let error):
                self.errorMessage = PropertyMessages.text(for: error)
            }
        }
    }

    func unlinkPayment(_ payment: RentReceiptPayment) {
        checkedWrite("Rent credit unlinked from its receipt") { db in
            _ = try RentReceiptMatching.unlink(db: db, receiptId: payment.rentReceiptId, transactionId: payment.transactionId)
        }
    }

    func seedEvidenceRules() {
        guard let propertyId else { return }
        do {
            let added = try dbQueue.write { db in try PropertyEvidence.seedRules(db: db, propertyId: propertyId) }
            infoMessage = added.isEmpty ? "The property's evidence rules are already there."
                : "Added \(added.count) evidence rule\(added.count == 1 ? "" : "s"): one PDF per rent receipt, one contract per tenancy."
        } catch {
            errorMessage = PropertyMessages.text(for: error)
        }
    }

    // MARK: Documents

    func unlinkDocument(_ document: EvidenceDocument, from entity: EvidenceEntity) {
        guard let id = document.id else { return }
        do {
            _ = try library.unlink(id, from: entity)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func documents(for entity: EvidenceEntity) -> [EvidenceDocument] {
        (try? library.documents(for: entity)) ?? []
    }

    /// A record's linked documents, read off the main thread (a side panel's).
    func loadDocuments(for entity: EvidenceEntity) async -> [EvidenceDocument] {
        let library = library
        return await Task.detached(priority: .userInitiated) { (try? library.documents(for: entity)) ?? [] }.value
    }

    /// Opens a library document by id (an invoice's PDF).
    func openDocument(id: Int64) {
        if let document = try? library.database.read({ db in try EvidenceDocument.fetchOne(db, key: id) }) { open(document) }
    }

    /// Where a library document's file is (for Quick Look and the thumbnail).
    func fileURL(for document: EvidenceDocument) -> URL {
        library.fileURL(for: document)
    }

    /// A tenancy's receipt row as the Tenancies table shows it.
    func receiptRow(_ id: Int64, tenancyId: Int64) -> TenancyReceiptRow? {
        snapshot.receipts[tenancyId]?.first { $0.receipt.id == id }
    }

    /// Opens a library document in Preview (its default app when Preview can't be found).
    func openInPreview(_ document: EvidenceDocument) {
        let url = library.fileURL(for: document)
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in self.errorMessage = "Couldn't open \(document.displayName) in Preview: \(error.localizedDescription)" }
        }
    }

    func open(_ document: EvidenceDocument) {
        NSWorkspace.shared.open(library.fileURL(for: document))
    }

    // MARK: Side panel

    /// The month panel opened from a Cash flow chart: the summary's month starting at
    /// `start` (clipped to the period), or closed when it's the one already open.
    func toggleMonth(_ start: Date) {
        guard let month = snapshot.summary?.months.first(where: { $0.start == start }) else { return }
        let interval = DateInterval(start: month.start, end: month.end)
        sidePanel = sidePanel == .month(interval) ? nil : .month(interval)
    }

    /// The open month's start, for the charts' highlight.
    var openMonthStart: Date? {
        if case let .month(interval) = sidePanel { return interval.start }
        return nil
    }

    private func closeMonthPanel() {
        if case .month = sidePanel { sidePanel = nil }
    }

    /// Closes a panel whose tab is no longer showing.
    private func closeSidePanelIfHidden() {
        switch sidePanel {
        case .month: if ![.overview, .money].contains(tab) { sidePanel = nil }
        case .rechargeStatement, .rechargeMonth: if tab != .recharges { sidePanel = nil }
        case .receipt: if tab != .tenancies { sidePanel = nil }
        case nil: break
        }
    }

    /// The transactions behind a month's cash flow, counted as the chart counts them.
    func monthBreakdown(_ interval: DateInterval) -> PropertyMonthBreakdown? {
        guard let propertyId else { return nil }
        do {
            return try dbQueue.read { db in try PropertyFinance.monthBreakdown(db: db, propertyId: propertyId, interval: interval) }
        } catch {
            // Read while the panel draws: the panel says it couldn't.
            return nil
        }
    }

    /// Opens a recharges panel, or closes it when it's the one open.
    func toggleSidePanel(_ panel: SidePanel) {
        sidePanel = sidePanel == panel ? nil : panel
    }

    func rechargeStatementDetail(_ id: Int64) -> RechargeStatementDetail? {
        try? dbQueue.read { db in try RechargeDetails.statement(db: db, statementId: id) }
    }

    func rechargeMonthDetail(_ month: Date, tenancyId: Int64) -> RechargeMonthDetail? {
        let today = PropertyDays.utcToday(now())
        return try? dbQueue.read { db in try RechargeDetails.month(db: db, tenancyId: tenancyId, month: month, today: today) }
    }

    // MARK: Drill-down

    func transactions(_ drillDown: PropertyDrillDown) -> [EvidenceTransactionInfo] {
        guard let propertyId, let interval = period?.interval else { return [] }
        do {
            return try dbQueue.read { db in
                let accounts = Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a) } })
                return try PropertyPage.transactions(db: db, propertyId: propertyId, period: interval, drillDown: drillDown).map { transaction in
                    let account = accounts[transaction.accountId]
                    return EvidenceTransactionInfo(transaction: transaction, accountName: account?.displayName ?? "",
                                                   currency: account?.currency ?? .gbp,
                                                   categoryName: transaction.categoryId.flatMap { snapshot.categoryNames[$0] })
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }
}

/// Readable text for the property area's errors.
enum PropertyMessages {
    static func text(for error: Error) -> String {
        switch error {
        case let error as PropertyError: return text(error)
        case let error as RentPaymentError: return text(error)
        case let error as MortgageTermsError: return text(error)
        default: return error.localizedDescription
        }
    }

    static func text(_ error: PropertyError) -> String {
        switch error {
        case .blankName: return "Enter a name."
        case .duplicateName: return "That name is already used."
        case .invalidCountry: return "Use a two-letter country code, e.g. PT."
        case .personNotFound: return "That person no longer exists."
        case .propertyNotFound: return "The property no longer exists."
        case .accountNotFound: return "That account no longer exists."
        case .categoryGroupNotFound: return "That category group no longer exists."
        case .tenancyNotFound: return "The tenancy no longer exists."
        case .personIsOwner: return "That person owns a share of a property: remove the ownership first."
        case .invalidShare: return "Each share must be more than 0% and at most 100%."
        case .invalidDateRange: return "An end date is before its start date."
        case .overlappingOwnership: return "One person's ownership periods overlap."
        case let .sharesDoNotSumToWhole(date, total):
            let when = date.map { "On \(DocumentFormat.day($0))" } ?? "Before the first start date"
            return "\(when) the shares add up to \(PropertyFormat.percent(total)), not 100%."
        case .blankReference: return "Enter the tenancy's reference."
        case .duplicateContractNumber: return "Another tenancy of this property has that contract number."
        case .negativeMonths: return "Months can't be negative."
        case .negativeAmount: return "Amounts can't be negative."
        case .duplicateRentDate: return "Two rents start on the same day."
        case .blankReceiptNumber: return "Enter the receipt number."
        case .duplicateReceiptNumber: return "That receipt number is already used for this tenancy."
        case .invalidWithholding: return "The withholding can't be more than the rent."
        case let .invalidEmail(text): return "“\(text)” isn't an email address."
        }
    }

    static func text(_ error: MortgageTermsError) -> String {
        switch error {
        case .invalidRevisionMonths: return "Choose at least one month the rate is revised in."
        case .negativeBalloon: return "The balloon can't be negative."
        case .invalidRate: return "Enter a rate between 0% and 50%."
        case .invalidSpread: return "Enter a spread between −5% and 20%."
        case .invalidCount: return "Enter between 1 and 1,200 instalments (and 0–10 business days, 0–6 decimals)."
        case .finalBeforeFirst: return "The final instalment is before the first."
        case .invalidAmountBorrowed: return "The amount borrowed must be more than the balloon."
        }
    }

    static func text(_ error: RentPaymentError) -> String {
        switch error {
        case .receiptNotFound: return "The receipt no longer exists."
        case .transactionNotFound: return "The transaction no longer exists."
        case .notACredit: return "Only credits pay rent."
        case .negativeAmount: return "Amounts can't be negative."
        case .nothingAllocated: return "Nothing would be linked."
        case .overAllocated: return "That's more than is left of the credit."
        case .exceedsReceipt: return "That's more rent than the receipt received."
        case .receiptCancelled: return "Cancelled receipts take no payments."
        }
    }
}

/// Formatting for the property screens.
enum PropertyFormat {
    /// "50%", "33.34%".
    static func percent(_ basisPoints: Int) -> String {
        basisPoints % 100 == 0 ? "\(basisPoints / 100)%" : String(format: "%.2f%%", Double(basisPoints) / 100)
    }

    /// "3.25%".
    static func yield(_ value: Double?) -> String {
        value.map { String(format: "%.2f%%", $0 * 100) } ?? "—"
    }

    /// "2 months deposit, 1 month advance rent".
    static func held(_ tenancy: Tenancy) -> String {
        "\(months(tenancy.depositMonths).unbroken) deposit, \(months(tenancy.advanceRentMonths).unbroken) advance rent"
    }

    /// "1 month", "2 months".
    static func months(_ count: Int) -> String { "\(count) month\(count == 1 ? "" : "s")" }

    static func period(_ start: Date, _ end: Date?) -> String {
        end.map { "\(DocumentFormat.day(start)) – \(DocumentFormat.day($0))" } ?? "From \(DocumentFormat.day(start))"
    }

    static func role(_ role: PropertyAccountRole) -> String {
        switch role {
        case .current: return "Current (rent and costs)"
        case .mortgage: return "Mortgage"
        case .deposit: return "Tenant deposit held"
        case .other: return "Other"
        }
    }

    static func obligation(_ kind: PropertyObligationKind) -> String {
        switch kind {
        case .imiInstalment: return "building.columns"
        case .ptIncomeTaxReturn, .ukSelfAssessmentJanuary, .ukSelfAssessmentJuly: return "doc.text"
        case .mortgageRateReset: return "percent"
        case .mortgageInstalment: return "house"
        case .insuranceRenewal: return "shield"
        case .recurringCost: return "repeat"
        }
    }
}

enum PropertyDays {
    /// Today's UTC day (00:00 UTC of the user's local calendar day).
    static func utcToday(_ now: Date) -> Date { PayCalendar.utcDay(sameDayAs: now, in: .current) }
    static func utcNextDay(_ day: Date) -> Date { MonthRange.calendar.date(byAdding: .day, value: 1, to: day)! }
}
