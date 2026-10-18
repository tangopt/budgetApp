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
    }

    let dbQueue: DatabaseQueue
    let library: EvidenceLibrary

    @Published var propertyId: Int64? {
        didSet { if propertyId != oldValue { selectedTenancyId = nil; restartObservation() } }
    }
    @Published var tab: Tab = .overview
    @Published var periodChoice: PeriodChoice {
        didSet { if periodChoice != oldValue { restartObservation() } }
    }
    /// The custom range's first and last days (UTC midnights).
    @Published var customFirstDay: Date {
        didSet { if customFirstDay != oldValue, periodChoice == .custom { restartObservation() } }
    }
    @Published var customLastDay: Date {
        didSet { if customLastDay != oldValue, periodChoice == .custom { restartObservation() } }
    }
    @Published var selectedTenancyId: Int64?
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

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary, now: @escaping () -> Date = { AppClock.now }) {
        self.dbQueue = dbQueue
        self.library = library
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
        snapshot.loanHistory = try loanHistory(db: db, property: property, accountIds: mortgageIds, today: today)
        return snapshot
    }

    /// The most month ends the loan chart reads (ten years).
    nonisolated static let loanHistoryMonths = 120

    /// What `accountIds` (the mortgage) owe at the end of each month from their first record
    /// (at most `loanHistoryMonths` back) and at the end of `today`, read by
    /// `PropertyFinance.loanBalances` (the rule of `PropertyFinance.balance`, which gives the
    /// summary's outstanding loan).
    nonisolated static func loanHistory(db: Database, property: Property, accountIds: [Int64], today: Date) throws -> [LoanPoint] {
        guard !accountIds.isEmpty else { return [] }
        let firstSnapshot = try BalanceSnapshot.filter(accountIds.contains(Column("accountId")))
            .select(GRDB.min(Column("date")), as: Date.self).fetchOne(db)
        let firstTransaction = try Transaction.filter(accountIds.contains(Column("accountId")))
            .select(GRDB.min(Column("date")), as: Date.self).fetchOne(db)
        guard let first = [firstSnapshot, firstTransaction].compactMap({ $0 }).min() else { return [] }
        let calendar = MonthRange.calendar
        let earliest = calendar.date(byAdding: .month, value: -loanHistoryMonths, to: today)!
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

    func saveProperty(_ property: Property) -> Result<Int64, Error> {
        Result {
            try dbQueue.write { db in
                var property = property
                try Properties.save(db: db, &property)
                return property.id!
            }
        }
    }

    func deleteProperty() -> String? {
        guard let propertyId else { return nil }
        let error = write { db in _ = try Properties.delete(db: db, id: propertyId) }
        if error == nil {
            self.propertyId = nil
            onPropertiesChanged?(nil)
        }
        return error
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

    func setOwners(_ owners: [PropertyOwner]) -> String? {
        guard let propertyId else { return nil }
        return write { db in _ = try Properties.setOwners(db: db, propertyId: propertyId, owners) }
    }

    func setAccount(_ accountId: Int64, role: PropertyAccountRole) -> String? {
        guard let propertyId else { return nil }
        return write { db in _ = try Properties.setAccount(db: db, propertyId: propertyId, accountId: accountId, role: role) }
    }

    func removeAccount(_ accountId: Int64) {
        guard let propertyId else { return }
        errorMessage = write { db in _ = try Properties.removeAccount(db: db, propertyId: propertyId, accountId: accountId) }
    }

    func addGroup(_ groupId: Int64) {
        guard let propertyId else { return }
        errorMessage = write { db in try Properties.addCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: groupId) }
    }

    func removeGroup(_ groupId: Int64) {
        guard let propertyId else { return }
        errorMessage = write { db in _ = try Properties.removeCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: groupId) }
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
        do {
            let result = try dbQueue.write { db in try RentReceiptMatching.match(db: db, propertyId: propertyId) }
            errorMessage = nil
            infoMessage = "Linked \(result.created.count) credit\(result.created.count == 1 ? "" : "s"). "
                + "\(result.unmatchedReceipts.count) receipt\(result.unmatchedReceipts.count == 1 ? "" : "s") and "
                + "\(result.unmatchedCredits.count) credit\(result.unmatchedCredits.count == 1 ? "" : "s") remain unmatched."
        } catch {
            errorMessage = PropertyMessages.text(for: error)
        }
    }

    func unlinkPayment(_ payment: RentReceiptPayment) {
        errorMessage = write { db in
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

    // MARK: Receipts import

    /// Reads the portal export (off the main thread) and previews the import.
    func previewImport(_ url: URL) async -> Result<ReceiptsImportPreview, Error> {
        guard let propertyId else { return .failure(PropertyError.propertyNotFound) }
        let dbQueue = dbQueue
        return await Task.detached(priority: .userInitiated) {
            Result {
                let data = try EvidenceFiles.withAccess(url) { try Data(contentsOf: url) }
                let rows = try RentReceiptsExport.parse(xlsx: data)
                let report = try dbQueue.write { db in try RentReceiptImport.preview(db: db, propertyId: propertyId, rows: rows) }
                return ReceiptsImportPreview(fileName: url.lastPathComponent, rows: rows, report: report)
            }
        }.value
    }

    /// Imports the previewed rows and matches credits.
    func applyImport(_ preview: ReceiptsImportPreview) -> String? {
        guard let propertyId else { return nil }
        do {
            let (report, matched) = try dbQueue.write { db in
                let report = try RentReceiptImport.run(db: db, propertyId: propertyId, rows: preview.rows)
                let matched = try RentReceiptMatching.match(db: db, propertyId: propertyId)
                return (report, matched)
            }
            infoMessage = "Imported \(preview.fileName): \(report.createdReceipts) new, \(report.updatedReceipts) updated, "
                + "\(report.cancelledReceipts) cancelled. Linked \(matched.created.count) credit\(matched.created.count == 1 ? "" : "s")."
            errorMessage = nil
            return nil
        } catch {
            return PropertyMessages.text(for: error)
        }
    }

    // MARK: Documents

    /// Adds files to the library and links them to `entity`. A tenancy's file is its contract
    /// and a receipt's its PDF (whatever the classifier would say), so the property's evidence
    /// rules count them.
    func addDocuments(_ urls: [URL], to entity: EvidenceEntity, role: String?) {
        let kind: DocumentKind? = switch entity.type {
        case .tenancy: .rentContract
        case .rentReceipt: .rentReceipt
        default: nil
        }
        let (files, folders) = EvidenceFiles.files(urls)
        infoMessage = EvidenceFiles.skippedMessage(folders)
        guard !files.isEmpty else { return }
        let library = library
        Task {
            let failures = await Task.detached(priority: .userInitiated) { () -> [String] in
                var failures: [String] = []
                for url in files {
                    do {
                        let metadata = kind.map { EvidenceMetadata(kind: $0) } ?? EvidenceMetadata()
                        let result = try EvidenceFiles.withAccess(url) { try library.addAnalyzing(url, metadata: metadata) }
                        guard let id = result.document.id else { continue }
                        if let kind, result.document.kind != kind {
                            // Already in the library under another kind: it's this record's now.
                            try library.database.write { db in
                                try db.execute(sql: "UPDATE document SET kind = ? WHERE id = ?", arguments: [kind.rawValue, id])
                            }
                        }
                        _ = try library.link(id, to: entity, role: role)
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return failures
            }.value
            errorMessage = failures.isEmpty ? nil : "Couldn't add " + failures.joined(separator: "; ")
        }
    }

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

    func open(_ document: EvidenceDocument) {
        NSWorkspace.shared.open(library.fileURL(for: document))
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

/// What the import sheet shows before applying.
struct ReceiptsImportPreview: Sendable {
    let fileName: String
    let rows: [RentReceiptsExport.Row]
    let report: RentReceiptImport.Report

    var contractCount: Int { Set(rows.map(\.contractNumber)).count }
}

/// Readable text for the property area's errors.
enum PropertyMessages {
    static func text(for error: Error) -> String {
        switch error {
        case let error as PropertyError: return text(error)
        case let error as RentReceiptsExport.ExportError: return text(error)
        case let error as RentPaymentError: return text(error)
        case is ZipArchiveReader.ZipError, is XLSXReader.XLSXError: return "That file isn't a readable .xlsx spreadsheet."
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

    static func text(_ error: RentReceiptsExport.ExportError) -> String {
        switch error {
        case .missingColumns: return "That spreadsheet doesn't look like the Portal das Finanças receipts export (no contract, receipt, period, value and status columns)."
        case let .badValue(row, column, value): return "Row \(row): “\(value)” isn't a valid \(column)."
        case let .missingValue(row, column): return "Row \(row) has no \(column)."
        case let .duplicateReceipt(row, contract, receipt): return "Row \(row) repeats receipt \(receipt) of contract \(contract)."
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
        "\(months(tenancy.depositMonths)) deposit, \(months(tenancy.advanceRentMonths)) advance rent"
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
