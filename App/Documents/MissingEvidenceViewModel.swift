// App/Documents/MissingEvidenceViewModel.swift
import Foundation
import BudgetCore
import struct BudgetCore.Category
import struct BudgetCore.Transaction
import GRDB
import SwiftUI

/// The Missing evidence screen (spec 2026-10-16 §7): the checklist for a UK tax year or a
/// custom range (`MissingEvidence.items`), kept current by observing the database while the
/// screen shows — links, waivers, documents, rules and transactions changed anywhere refresh
/// it. Adds files to the library and links them to an item's record at once, links existing
/// documents, waives items, and manages the rules. Owned by ContentView, so the period and
/// filters last while the app runs.
@MainActor
final class MissingEvidenceViewModel: ObservableObject {
    enum PeriodChoice: Hashable {
        case taxYear(Int)
        case custom
    }

    /// The checklist narrowed to one property's rules (from its Checks tab).
    struct PropertyFilter: Equatable, Sendable {
        let propertyId: Int64
        let name: String
    }

    /// What one observation reads: the rules, and the checklist they make.
    struct Snapshot: Equatable, Sendable {
        var requirements: [EvidenceRequirement]
        var items: [MissingEvidence.Item]
    }

    let dbQueue: DatabaseQueue
    let library: EvidenceLibrary

    @Published var periodChoice: PeriodChoice {
        didSet { if periodChoice != oldValue { restartObservation() } }
    }
    /// The custom range's first and last days (UTC midnights, like every stored day).
    @Published var customFirstDay: Date {
        didSet { if customFirstDay != oldValue, periodChoice == .custom { restartObservation() } }
    }
    @Published var customLastDay: Date {
        didSet { if customLastDay != oldValue, periodChoice == .custom { restartObservation() } }
    }
    /// The tax years offered, latest first.
    @Published private(set) var years: [UKTaxYear]
    @Published private(set) var requirements: [EvidenceRequirement] = []
    /// The whole checklist for the period (the filters don't change it).
    @Published private(set) var items: [MissingEvidence.Item] = [] {
        didSet {
            sources = MissingEvidence.bySource(items)
            refreshShown()
        }
    }
    /// The items shown, by source.
    @Published private(set) var groups: [MissingEvidence.SourceGroup] = []
    /// Every item of the period by source (whatever the filters show): each source's progress.
    @Published private(set) var sources: [MissingEvidence.SourceGroup] = []
    @Published private(set) var isLoading = true
    @Published var missingOnly = true {
        didSet { if missingOnly != oldValue { refreshShown() } }
    }
    @Published var queryText = "" {
        didSet { if queryText != oldValue { refreshShown() } }
    }
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    /// Only the items of rules concerning this property (`PropertyEvidence.relatedRequirementIds`).
    @Published var propertyFilter: PropertyFilter? {
        didSet { if propertyFilter != oldValue { restartObservation() } }
    }

    // The rule editor's choices.
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var categories: [Category] = []
    @Published private(set) var categoryGroups: [CategoryGroup] = []
    /// Property records' titles (`PropertyEvidence.entityTitles`).
    @Published private(set) var entityTitles: [EvidenceEntity: String] = [:]

    private var observationTask: Task<Void, Never>?
    private var demand = ObservationDemand()
    private var isActive: Bool { demand.isWanted }

    init(dbQueue: DatabaseQueue, library: EvidenceLibrary, now: Date = AppClock.now) {
        self.dbQueue = dbQueue
        self.library = library
        let current = UKTaxYear.containing(now)
        periodChoice = .taxYear(current.startYear)
        customFirstDay = current.start
        customLastDay = current.lastDay
        years = UKTaxYear.pickerYears(earliest: UKTaxYear(startYear: 2023), now: now)
    }

    // MARK: Lifecycle

    /// Starts observing (on appear): re-reads the choices and the tax years on offer.
    func start() { claim("screen") }

    /// Stops observing (on disappear), so imports elsewhere don't recompute the checklist.
    /// A sheet still holding a claim keeps it running.
    func stop() { release("screen") }

    /// `holder` (the screen, or a sheet it presents) needs the live checklist and rules.
    func claim(_ holder: String) {
        let wasActive = isActive
        demand.set(holder, wanted: true)
        if !wasActive {
            loadReferenceData()
            restartObservation()
        } else if observationTask == nil {
            restartObservation()
        }
    }

    func release(_ holder: String) {
        guard !demand.set(holder, wanted: false) else { return }
        observationTask?.cancel()
        observationTask = nil
    }

    func loadReferenceData() {
        do {
            let (accounts, categories, groups, earliest, titles) = try dbQueue.read { db in
                (try Account.fetchAll(db), try Category.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db),
                 try CategoryGroup.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db),
                 try Date.fetchOne(db, sql: "SELECT MIN(date) FROM transaction_"), try PropertyEvidence.entityTitles(db: db))
            }
            entityTitles = titles
            self.accounts = accounts.sortedForDisplay()
            self.categories = categories
            categoryGroups = groups
            let first = min(UKTaxYear(startYear: 2023), earliest.map(UKTaxYear.containing) ?? UKTaxYear(startYear: 2023))
            years = UKTaxYear.pickerYears(earliest: first, now: AppClock.now)
        } catch {
            errorMessage = "Couldn't load accounts and categories: \(error.localizedDescription)"
        }
    }

    /// The period the checklist covers, or nil when the custom range ends before it starts.
    var period: DateInterval? {
        switch periodChoice {
        case let .taxYear(startYear): return UKTaxYear(startYear: startYear).interval
        case .custom: return MissingEvidence.period(from: customFirstDay, through: customLastDay)
        }
    }

    /// "Tax year 2025/26", or "1 Jan 2025 – 31 Mar 2025".
    var periodTitle: String {
        switch periodChoice {
        case let .taxYear(startYear): return "Tax year \(UKTaxYear(startYear: startYear).label)"
        case .custom: return "\(DocumentFormat.day(customFirstDay)) – \(DocumentFormat.day(customLastDay))"
        }
    }

    var progress: MissingEvidence.Progress { MissingEvidence.progress(items) }

    /// A source's progress over the whole period (a group shown under a filter holds only
    /// some of its items).
    func progress(source: String) -> MissingEvidence.Progress {
        sources.first { $0.source == source }?.progress ?? MissingEvidence.Progress()
    }

    private func restartObservation() {
        observationTask?.cancel()
        observationTask = nil
        guard isActive else { return }
        guard let period else {
            items = []
            isLoading = false
            return
        }
        isLoading = true
        let propertyId = propertyFilter?.propertyId
        let values = ValueObservation
            .tracking { db -> Snapshot in
                let requirements = try EvidenceRequirements.all(db: db)
                var items = try MissingEvidence.items(db: db, period: period, requirements: requirements)
                if let propertyId {
                    let related = try PropertyEvidence.relatedRequirementIds(db: db, propertyId: propertyId)
                    items = items.filter { $0.requirement.id.map(related.contains) ?? false }
                }
                return Snapshot(requirements: requirements, items: items)
            }
            .removeDuplicates()
            .values(in: dbQueue)
        observationTask = Task { [weak self] in
            do {
                for try await snapshot in values {
                    guard let self, !Task.isCancelled else { return }
                    self.requirements = snapshot.requirements
                    self.items = snapshot.items
                    self.isLoading = false
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = "Couldn't read the checklist: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    private func refreshShown() {
        groups = MissingEvidence.bySource(MissingEvidence.filtered(items, missingOnly: missingOnly, text: queryText))
    }

    /// Whether the filters hide everything there is.
    var filtersHideEverything: Bool { groups.isEmpty && !items.isEmpty }

    // MARK: Adding and linking

    /// Links a library document to the item's record (Link existing…), filling in its kind
    /// or period, in one write. Returns what happened, for the caller to show.
    func link(documentId: Int64, to item: MissingEvidence.Item) -> Result<String, Error> {
        Result { try Self.linkFillingIn(library: library, documentId: documentId, item: item) }
    }

    func unlink(documentId: Int64, from item: MissingEvidence.Item) {
        do {
            try library.unlink(documentId, from: item.target.entity)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Links, fills in what's missing for the item (one write), and describes what happened.
    nonisolated private static func linkFillingIn(library: EvidenceLibrary, documentId: Int64,
                                                  item: MissingEvidence.Item) throws -> String {
        let outcome = try library.database.write { db in try MissingEvidence.link(db: db, documentId: documentId, to: item) }
        let name = outcome.document.displayName
        var note = "Linked “\(name)”."
        if !outcome.filled.isEmpty { note += " Set its \(outcome.filled.joined(separator: " and ")) — change it in Documents if that's wrong." }
        if let shortfall = outcome.shortfall {
            note += " It doesn't count for this item yet: \(shortfall). Fix its details in Documents."
        }
        return note
    }

    // MARK: Waivers

    /// Marks the item not available; the error's text when refused.
    func waive(_ item: MissingEvidence.Item, reason: EvidenceWaiverReason, note: String?) -> String? {
        guard let requirementId = item.requirement.id else { return "The rule no longer exists." }
        do {
            _ = try dbQueue.write { db in try EvidenceRequirements.waive(db: db, requirementId: requirementId, target: item.target, reason: reason, note: note) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeWaiver(_ item: MissingEvidence.Item) {
        guard let requirementId = item.requirement.id else { return }
        do {
            _ = try dbQueue.write { db in try EvidenceRequirements.removeWaiver(db: db, requirementId: requirementId, target: item.target) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Transactions

    /// The item's transaction (transaction scopes), for Show.
    func transaction(for item: MissingEvidence.Item) -> Transaction? {
        guard item.target.entity.type == .transaction else { return nil }
        return try? dbQueue.read { db in try Transaction.fetchOne(db, key: item.target.entity.id) }
    }

    // MARK: Export

    /// The whole checklist for the period (whatever the filters show) as Markdown.
    func markdown() -> String? {
        guard let period else { return nil }
        return MissingEvidence.markdown(items: items, title: "Missing evidence — \(periodTitle)", period: period)
    }

    var exportFileName: String {
        switch periodChoice {
        case let .taxYear(startYear): return "Missing evidence \(UKTaxYear(startYear: startYear).label.replacingOccurrences(of: "/", with: "-"))"
        case .custom: return "Missing evidence"
        }
    }

    // MARK: Rules

    /// Saves a rule; the error's text when refused.
    func save(_ requirement: EvidenceRequirement) -> String? {
        var requirement = requirement
        do {
            try dbQueue.write { db in try EvidenceRequirements.save(db: db, &requirement) }
            return nil
        } catch let error as EvidenceRequirementError {
            switch error {
            case .blankName: return "Give the rule a name."
            case .noMatchingCriteria: return "Pick at least one category or account, or enter text the description contains."
            case .invalidActiveRange: return "The rule must start before it ends."
            case .requirementNotFound: return "The rule no longer exists."
            case .unsupportedRecordType: return "Only rent receipts and tenancies can be covered record by record."
            }
        } catch {
            return error.localizedDescription
        }
    }

    func deleteRequirement(_ id: Int64) {
        do {
            _ = try dbQueue.write { db in try EvidenceRequirements.delete(db: db, id: id) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The rules Set up property rules… would add (nothing is saved).
    func propertyRulesPreview(groupId: Int64, mortgageAccountIds: [Int64]) -> Result<[EvidenceRequirement], Error> {
        Result { try dbQueue.read { db in try EvidenceRequirementDefaults.propertyRules(db: db, categoryGroupId: groupId, mortgageAccountIds: mortgageAccountIds) } }
    }

    func seedPropertyRules(groupId: Int64, mortgageAccountIds: [Int64]) -> Result<[EvidenceRequirement], Error> {
        Result { try dbQueue.write { db in try EvidenceRequirementDefaults.seedPropertyRules(db: db, categoryGroupId: groupId, mortgageAccountIds: mortgageAccountIds) } }
    }

    // MARK: Describing rules

    func accountName(_ id: Int64) -> String { accounts.first { $0.id == id }?.displayName ?? "Account #\(id)" }
    func categoryName(_ id: Int64) -> String { categories.first { $0.id == id }?.name ?? "Category #\(id)" }
    func groupName(_ id: Int64) -> String { categoryGroups.first { $0.id == id }?.name ?? "Group #\(id)" }

    func entityName(_ entity: EvidenceEntity) -> String {
        switch entity.type {
        case .account: return accountName(entity.id)
        case .category: return categoryName(entity.id)
        case .transaction: return "Transaction #\(entity.id)"
        case .property, .person, .tenancy, .rentReceipt:
            return entityTitles[entity] ?? "\(entity.type.displayName) #\(entity.id)"
        case .taxYear, .taxManualItem, .employment, .employmentIncome, .hmrcPayment, .otherIncome, .pensionContribution, .taxPolicyReceipt, .other:
            return "\(entity.type.displayName) #\(entity.id)"
        }
    }

    /// "Every payment in IMI", "One document per month for BBVA", …
    func scopeSummary(_ requirement: EvidenceRequirement) -> String {
        let direction: String
        switch requirement.direction {
        case .outflows: direction = "payment"
        case .inflows: direction = "credit"
        case .any: direction = "transaction"
        }
        var text: String
        switch requirement.scope {
        case let .transactionsInCategory(categoryId):
            text = "Every \(direction) in \(categoryName(categoryId))"
        case let .transactionsInCategoryGroup(groupId):
            text = "Every \(direction) in the \(groupName(groupId)) group"
        case let .transactionsMatching(categoryIds, accountIds, descriptionContains):
            var criteria: [String] = []
            if !categoryIds.isEmpty { criteria.append("in " + categoryIds.map(categoryName).joined(separator: " or ")) }
            if !accountIds.isEmpty { criteria.append("on " + accountIds.map(accountName).joined(separator: " or ")) }
            if let text = descriptionContains { criteria.append("described “\(text)”") }
            text = "Every \(direction) " + criteria.joined(separator: ", ")
        case let .periodic(entity, every):
            text = "One document per \(every.rawValue) for \(entityName(entity))"
        case let .single(entity):
            text = "One document for \(entityName(entity))"
        case let .recordsOfProperty(_, recordType):
            text = recordType == .tenancy ? "One contract per tenancy" : "One document per rent receipt"
        case let .personalIncomeRecords(record):
            text = record.ruleDescription
        }
        if requirement.scope.isTransactionScope, !requirement.excludedAccountIds.isEmpty {
            text += ", except on " + requirement.excludedAccountIds.map(accountName).joined(separator: " or ")
        }
        return text
    }

    /// "From 6 Apr 2023 until 5 Apr 2025", or nil when always active.
    static func activeRange(_ requirement: EvidenceRequirement) -> String? {
        let lastDay = requirement.activeTo.map { $0.addingTimeInterval(-86_400) }
        switch (requirement.activeFrom, lastDay) {
        case let (from?, to?): return "From \(DocumentFormat.day(from)) until \(DocumentFormat.day(to))"
        case let (from?, nil): return "From \(DocumentFormat.day(from))"
        case let (nil, to?): return "Until \(DocumentFormat.day(to))"
        default: return nil
        }
    }

    static func kindsText(_ kinds: [DocumentKind]) -> String {
        kindsText(names: kinds.map(\.displayName))
    }

    /// An item's kinds by name (custom kinds included); none = any document.
    static func kindsText(names: [String]) -> String {
        names.isEmpty ? "Any document" : names.joined(separator: " or ")
    }

    /// The usual sources the rules name, for the editor's suggestions.
    var knownSources: [String] {
        let defaults = ["BBVA app", "Portal das Finanças", "Condomínio administrator", "Insurer", "Accountant", "Lawyer / court",
                        "Employer", "HMRC", "Utility provider", "Supplier"]
        let named = requirements.compactMap(\.usualSource)
        var seen = Set<String>()
        return (named + defaults).filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

extension View {
    /// Keeps the Missing evidence observation alive while this sheet shows (the screen behind
    /// it may report a disappear once the sheet covers it).
    func keepsEvidenceObserved(_ viewModel: MissingEvidenceViewModel, as holder: String) -> some View {
        onAppear { viewModel.claim(holder) }
            .onDisappear { viewModel.release(holder) }
    }
}
