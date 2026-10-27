import Combine
import Foundation
import BudgetCore
import GRDB
import struct BudgetCore.Property

/// Every action the iPad's Profile screen offers (step 10, Task 16), each one of the Mac Profile tab's.
public enum PadProfileAction: String, CaseIterable, Sendable {
    case editDetails, deleteProperty
    case editAddress, findOnMap, adjustLocation
    case editOwners
    case linkAccount, changeRole, unlinkAccount
    case editMortgageTerms
    case addGroup, removeGroup
    case linkDocument, viewDocument, unlinkDocument

    public var title: String {
        switch self {
        case .editDetails: "Edit details"
        case .deleteProperty: "Delete property"
        case .editAddress: "Edit address"
        case .findOnMap: "Find on map"
        case .adjustLocation: "Adjust location"
        case .editOwners: "Edit owners"
        case .linkAccount: "Link account"
        case .changeRole: "Role"
        case .unlinkAccount: "Unlink account"
        case .editMortgageTerms: "Edit terms"
        case .addGroup: "Add group"
        case .removeGroup: "Remove group"
        case .linkDocument: "Link document"
        case .viewDocument: "Show in Documents"
        case .unlinkDocument: "Unlink document"
        }
    }

    /// Whether the action writes (hidden, not disabled, without Edit on Property). Find on map writes the location it finds.
    public var edits: Bool { self != .viewDocument }

    /// The icon button the action is drawn as in a row (the shared vocabulary); nil for the ones drawn otherwise.
    var rowAction: RowAction? {
        switch self {
        case .unlinkAccount, .removeGroup, .unlinkDocument: .unlink
        case .viewDocument: .view
        case .linkDocument: .linkDocument
        default: nil
        }
    }

    /// The Mac's Profile tab actions, by the name the Mac gives them, and the action that answers each here; nil for the two
    /// that stay on the Mac: a person's tax identifiers are kept in the Mac's database only, so people are added and edited
    /// there (the iPad's owners choose among them).
    static let macActions: [(mac: String, pad: PadProfileAction?)] = [
        ("Edit details", .editDetails),
        ("Edit…", .editDetails),
        ("Delete property…", .deleteProperty),
        ("Edit address", .editAddress),
        ("Find on map", .findOnMap),
        ("Several places match: pick one", .findOnMap),
        ("Place on map", .adjustLocation),
        ("Adjust location", .adjustLocation),
        ("Save location", .adjustLocation),
        ("Edit owners…", .editOwners),
        ("Edit person: name and tax identifiers", nil),
        ("New person…", nil),
        ("Link account…", .linkAccount),
        ("Role", .changeRole),
        ("Unlink account", .unlinkAccount),
        ("Edit mortgage terms", .editMortgageTerms),
        ("Add group", .addGroup),
        ("Remove group", .removeGroup),
        ("Add document…", .linkDocument),
        ("Open document", .viewDocument),
        ("Unlink document", .unlinkDocument),
    ]
}

/// The property's details as the form edits them: text as typed, built into the property on Save.
public struct PadPropertyDraft: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let existing: Property
    public var name: String
    public var country: String
    public var currency: Currency
    public var matrixArticle: String
    public var priceText: String
    public var hasPurchaseDate: Bool
    public var purchaseDate: Date?
    public var notes: String

    public init(_ property: Property) {
        existing = property
        name = property.name
        country = property.country
        currency = property.currency
        matrixArticle = property.matrixArticle ?? ""
        priceText = property.purchasePriceMinorUnits.map(Money.formatInput) ?? ""
        hasPurchaseDate = property.purchaseDate != nil
        purchaseDate = property.purchaseDate
        notes = property.notes ?? ""
    }

    public static func == (lhs: PadPropertyDraft, rhs: PadPropertyDraft) -> Bool { lhs.id == rhs.id }

    public var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The property the form describes, or why not.
    public func build(today: Date) -> Result<Property, MortgageTermsEditing.Problem> {
        let text = priceText.trimmingCharacters(in: .whitespaces)
        let price = text.isEmpty ? nil : Money.parseMinorUnits(text)
        if !text.isEmpty, price == nil { return .failure(.init(MortgageTermsEditing.invalidAmount(text))) }
        var property = existing
        property.name = name
        property.country = country
        property.currency = currency
        property.matrixArticle = matrixArticle
        property.purchasePriceMinorUnits = price
        property.purchaseDate = hasPurchaseDate ? (purchaseDate ?? today) : nil
        property.notes = notes
        return .success(property)
    }
}

/// The owners as the form edits them: every row saved together, so the shares are checked as a whole.
public struct PadOwnersDraft: Equatable, Identifiable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: UUID
        public var personId: Int64?
        public var shareText: String
        public var from: Date?
        public var to: Date?

        public init(id: UUID = UUID(), personId: Int64? = nil, shareText: String = "100", from: Date? = nil, to: Date? = nil) {
            self.id = id
            self.personId = personId
            self.shareText = shareText
            self.from = from
            self.to = to
        }
    }

    public let id = UUID()
    public let propertyId: Int64
    public var rows: [Row]

    public init(propertyId: Int64, owners: [PropertyOwner]) {
        self.propertyId = propertyId
        rows = owners.map {
            Row(personId: $0.personId, shareText: PadProfileModel.percent($0.shareBasisPoints).replacingOccurrences(of: "%", with: ""),
                from: $0.fromDate, to: $0.toDate)
        }
        if rows.isEmpty { rows = [Row()] }
    }

    public static func == (lhs: PadOwnersDraft, rhs: PadOwnersDraft) -> Bool { lhs.id == rhs.id && lhs.rows == rhs.rows }

    /// The ownership rows, or the Mac's words for what's missing.
    public func build() -> Result<[PropertyOwner], MortgageTermsEditing.Problem> {
        var owners: [PropertyOwner] = []
        for row in rows {
            guard let personId = row.personId else { return .failure(.init("Choose a person on every row (or remove it).")) }
            guard let share = Decimal(string: row.shareText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) else {
                return .failure(.init("“\(row.shareText)” isn't a percentage."))
            }
            let basisPoints = NSDecimalNumber(decimal: share * 100).rounding(accordingToBehavior: nil).intValue
            owners.append(PropertyOwner(propertyId: propertyId, personId: personId, shareBasisPoints: basisPoints, fromDate: row.from, toDate: row.to))
        }
        return .success(owners)
    }
}

/// The iPad Profile screen's state (step 10, Task 16): the property's details, address and map location, owners, linked
/// accounts with their roles, category groups, documents, and the mortgage's terms with the rate they give now — and every
/// edit the Mac's Profile tab makes, through `PadWriteModel` (filed years checked; a refusal under the card it was made
/// on). People are only chosen here: they are added and edited on the Mac, where their tax identifiers are kept.
@MainActor
public final class PadProfileModel: ObservableObject {
    public struct Group: Equatable, Identifiable, Sendable {
        public var id: Int64
        public var name: String
    }

    public struct Snapshot: Equatable, Sendable {
        public var property: Property?
        public var people: [Person]
        public var owners: [PropertyOwner]
        public var accounts: [Account]
        public var propertyAccounts: [PropertyAccount]
        public var groups: [Group]
        public var groupIds: [Int64]
        public var documents: [EvidenceDocument]
        /// Each document's kind as the library names it, by id.
        public var documentKinds: [Int64: String]
        public var terms: PropertyMortgageTerms?
        public var rateStatus: MortgageRate.Status?
        public var rateOverrides: [MortgageRateOverride]
        /// Each index's stored values, for the terms form's rate now.
        public var series: [InterestIndex: MortgageRate.Series]

        public static let empty = Snapshot(property: nil, people: [], owners: [], accounts: [], propertyAccounts: [], groups: [], groupIds: [],
                                           documents: [], documentKinds: [:], terms: nil, rateStatus: nil, rateOverrides: [], series: [:])
    }

    /// The cards a refusal can show under.
    public enum Card: String, Sendable {
        case details, address, map, owners, accounts, groups, documents, mortgage
        var rowId: String { "profile-\(rawValue)" }
    }

    @Published public private(set) var snapshot: Snapshot = .empty
    /// What the last action did, when it says something.
    @Published public private(set) var info: String?

    public let property: PadPropertyModel
    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader
    private let today: () -> Date
    private var generation = 0
    private var isPreloaded = false
    private var forwarding: AnyCancellable?

    public init(property: PadPropertyModel, write: PadWriteModel, dbQueue: any DatabaseReader, today: @escaping () -> Date) {
        self.property = property
        self.write = write
        self.dbQueue = dbQueue
        self.today = today
        forwarding = property.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Reading

    public func preload(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        isPreloaded = true
    }

    public func reload() async {
        guard !isPreloaded else { return }
        await read()
    }

    private func read() async {
        generation += 1
        let mine = generation
        guard let propertyId = property.property?.id else {
            snapshot = .empty
            return
        }
        let day = utcToday
        let reader = dbQueue
        guard let read = try? await reader.read({ db in try Self.read(db, propertyId: propertyId, today: day) }), mine == generation else { return }
        snapshot = read
    }

    public nonisolated static func readNow(_ dbQueue: any DatabaseReader, propertyId: Int64?, today: Date) -> Snapshot {
        guard let propertyId else { return .empty }
        return (try? dbQueue.read { db in try read(db, propertyId: propertyId, today: MonthRange.calendar.startOfDay(for: today)) }) ?? .empty
    }

    nonisolated static func read(_ db: Database, propertyId: Int64, today: Date) throws -> Snapshot {
        guard let property = try Property.fetchOne(db, key: propertyId) else { return .empty }
        var series: [InterestIndex: MortgageRate.Series] = [:]
        for index in InterestIndex.allCases { series[index] = try MortgageRate.Series.load(db: db, index: index) }
        let documents = try EvidenceLinks.documents(db: db, for: .property(propertyId))
        let catalog = try DocumentKindCatalog.load(db: db)
        return Snapshot(
            property: property,
            people: try People.all(db: db),
            owners: try Properties.owners(db: db, propertyId: propertyId),
            accounts: try Account.fetchAll(db).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
            propertyAccounts: try Properties.accounts(db: db, propertyId: propertyId),
            groups: try CategoryGroup.fetchAll(db).compactMap { group in group.id.map { Group(id: $0, name: group.name) } }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            groupIds: try Properties.categoryGroupIds(db: db, propertyId: propertyId),
            documents: documents,
            documentKinds: Dictionary(uniqueKeysWithValues: documents.compactMap { d in d.id.map { ($0, catalog.displayName(of: d)) } }),
            terms: try MortgageTerms.terms(db: db, propertyId: propertyId),
            rateStatus: try MortgageRate.status(db: db, propertyId: propertyId, today: today),
            rateOverrides: try MortgageRate.overrides(db: db, propertyId: propertyId),
            series: series)
    }

    /// Today as a stored day (UTC midnight).
    var utcToday: Date { MonthRange.calendar.startOfDay(for: today()) }
    public var currency: Currency { snapshot.property?.currency ?? .eur }

    // MARK: Words

    public func personName(_ id: Int64) -> String { snapshot.people.first { $0.id == id }?.name ?? "Person #\(id)" }
    public func accountName(_ id: Int64) -> String { snapshot.accounts.first { $0.id == id }?.displayName ?? "Account #\(id)" }
    public func groupName(_ id: Int64) -> String { snapshot.groups.first { $0.id == id }?.name ?? "Group #\(id)" }

    /// "50%", "33.34%".
    public nonisolated static func percent(_ basisPoints: Int) -> String {
        basisPoints % 100 == 0 ? "\(basisPoints / 100)%" : String(format: "%.2f%%", Double(basisPoints) / 100)
    }

    /// The Mac's words for an account's role.
    public nonisolated static func role(_ role: PropertyAccountRole) -> String {
        switch role {
        case .current: "Current (rent and costs)"
        case .mortgage: "Mortgage"
        case .deposit: "Tenant deposit held"
        case .other: "Other"
        }
    }

    /// The mortgage card's facts, as the Mac's Mortgage panel words them.
    public struct MortgageFacts: Equatable, Sendable {
        public var rate: String
        public var rateIsSet: Bool
        public var nextRevision: String
        /// "Every 3 months on 1 Jan, 1 Apr, 1 Jul and 1 Oct".
        public var schedule: String
        public var nextInstalment: String?
        public var instalments: String?
        public var finalInstalment: String?
        public var balloonMinorUnits: Int?
    }

    public var mortgage: MortgageFacts {
        let terms = snapshot.terms ?? PropertyMortgageTerms(propertyId: snapshot.property?.id ?? 0)
        let status = snapshot.rateStatus
        let rate: String
        if let current = status?.current {
            rate = current.explanation
        } else if terms.hasRateRules {
            rate = "No \(terms.rateIndex?.displayName ?? "index") fixing stored for this period yet"
        } else {
            rate = "Add the loan's rules with Edit terms (index and spread)"
        }
        let schedule = MortgageTerms.scheduleText(terms.revisionMonths)
        let capitalized = schedule.prefix(1).uppercased() + schedule.dropFirst()
        let revision = status?.nextRevision.map { PhoneDateFormat.day($0) } ?? "—"
        var instalment: String?
        if let amount = status?.nextInstalmentMinorUnits, let due = status?.nextDue {
            instalment = "\(Money.format(amount, currency: currency)) due \(PhoneDateFormat.day(due))"
        }
        let instalments = terms.totalInstalments.map { total in
            "\(total) in all" + (status?.remainingInstalments.map { " · \($0) left" } ?? "")
        }
        return MortgageFacts(rate: rate, rateIsSet: status?.current != nil, nextRevision: revision, schedule: capitalized, nextInstalment: instalment,
                             instalments: instalments, finalInstalment: terms.effectiveFinalInstalmentDate.map { PhoneDateFormat.day($0) },
                             balloonMinorUnits: terms.balloonMinorUnits)
    }

    // MARK: What is offered

    /// What a card offers: everything with Edit on Property; with View, only what reads.
    public func actions(for card: Card) -> [PadProfileAction] {
        let all: [PadProfileAction]
        switch card {
        case .details: all = [.editDetails, .deleteProperty]
        case .address: all = [.editAddress]
        case .map: all = [.findOnMap, .adjustLocation]
        case .owners: all = [.editOwners]
        case .accounts: all = [.linkAccount, .changeRole, .unlinkAccount]
        case .groups: all = [.addGroup, .removeGroup]
        case .documents: all = [.linkDocument, .viewDocument, .unlinkDocument]
        case .mortgage: all = [.editMortgageTerms]
        }
        return all.filter { write.canEdit || !$0.edits }
    }

    public func message(for card: Card) -> String? { write.message(for: card.rowId) }

    /// The groups not yet the property's.
    public var availableGroups: [Group] { snapshot.groups.filter { !snapshot.groupIds.contains($0.id) } }

    /// The accounts not yet linked.
    public var availableAccounts: [Account] {
        let linked = Set(snapshot.propertyAccounts.map(\.accountId))
        return snapshot.accounts.filter { !linked.contains($0.id ?? -1) }
    }

    /// Library documents that could be linked to the property: those not linked yet, latest first.
    public func documentCandidates() async -> [EvidenceDocument] {
        let own = Set(snapshot.documents.compactMap(\.id))
        return (try? await dbQueue.read { db in
            try EvidenceDocument.order(Column("docDate").desc).fetchAll(db).filter { $0.id.map { !own.contains($0) } ?? false }
        }) ?? []
    }

    // MARK: Writes: details, owners, accounts, groups

    private var propertyName: String { snapshot.property?.name ?? "the property" }

    /// A form for the property's details.
    public func detailsDraft() -> PadPropertyDraft? { snapshot.property.map(PadPropertyDraft.init) }

    @discardableResult
    public func save(_ draft: PadPropertyDraft) async -> Bool {
        let property: Property
        switch draft.build(today: utcToday) {
        case .success(let built): property = built
        case .failure(let problem):
            write.refuse(rowId: Card.details.rowId, message: problem.message)
            return false
        }
        return await perform(.details, edit: "\(property.name) edited", scope: .everyYear) { db in
            var property = property
            try Properties.save(db: db, &property)
        }
    }

    /// Deletes the property: its owners, account and group links, tenancies, rents, receipts and their credit links go.
    @discardableResult
    public func deleteProperty() async -> Bool {
        guard let id = snapshot.property?.id else { return false }
        let deleted = await perform(.details, edit: "\(propertyName) deleted", scope: .everyYear, refresh: false) { db in
            _ = try Properties.delete(db: db, id: id)
        }
        if deleted {
            snapshot = .empty
            await property.reload()
        }
        return deleted
    }

    public func ownersDraft() -> PadOwnersDraft? {
        snapshot.property?.id.map { PadOwnersDraft(propertyId: $0, owners: snapshot.owners) }
    }

    @discardableResult
    public func save(_ draft: PadOwnersDraft) async -> Bool {
        let owners: [PropertyOwner]
        switch draft.build() {
        case .success(let built): owners = built
        case .failure(let problem):
            write.refuse(rowId: Card.owners.rowId, message: problem.message)
            return false
        }
        let propertyId = draft.propertyId
        return await perform(.owners, edit: "Owners of \(propertyName) changed", scope: .everyYear) { db in
            _ = try Properties.setOwners(db: db, propertyId: propertyId, owners)
        }
    }

    /// Links `accountId` with `role`, or gives a linked account another role.
    @discardableResult
    public func setAccount(_ accountId: Int64, role: PropertyAccountRole) async -> Bool {
        guard let propertyId = snapshot.property?.id else { return false }
        return await perform(.accounts, edit: "Account of \(propertyName) set as \(role.rawValue)", scope: .everyYear) { db in
            _ = try Properties.setAccount(db: db, propertyId: propertyId, accountId: accountId, role: role)
        }
    }

    @discardableResult
    public func unlinkAccount(_ accountId: Int64) async -> Bool {
        guard let propertyId = snapshot.property?.id else { return false }
        return await perform(.accounts, edit: "Account removed from \(propertyName)", scope: .everyYear) { db in
            _ = try Properties.removeAccount(db: db, propertyId: propertyId, accountId: accountId)
        }
    }

    @discardableResult
    public func addGroup(_ groupId: Int64) async -> Bool {
        guard let propertyId = snapshot.property?.id else { return false }
        return await perform(.groups, edit: "Category group added to \(propertyName)", scope: .everyYear) { db in
            try Properties.addCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: groupId)
        }
    }

    @discardableResult
    public func removeGroup(_ groupId: Int64) async -> Bool {
        guard let propertyId = snapshot.property?.id else { return false }
        return await perform(.groups, edit: "Category group removed from \(propertyName)", scope: .everyYear) { db in
            _ = try Properties.removeCategoryGroup(db: db, propertyId: propertyId, categoryGroupId: groupId)
        }
    }

    // MARK: Writes: documents

    @discardableResult
    public func linkDocument(_ documentId: Int64) async -> Bool {
        guard let propertyId = snapshot.property?.id else { return false }
        return await perform(.documents, origin: .documentLink, edit: "Document linked", scope: FiledYearEditCheck.Scope()) { db in
            _ = try EvidenceLinks.link(db: db, documentId: documentId, to: .property(propertyId), role: nil)
        }
    }

    @discardableResult
    public func unlinkDocument(_ documentId: Int64) async -> Bool {
        guard let propertyId = snapshot.property?.id else { return false }
        return await perform(.documents, origin: .documentLink, edit: "Document unlinked", scope: FiledYearEditCheck.Scope()) { db in
            _ = try EvidenceLinks.unlink(db: db, documentId: documentId, from: .property(propertyId))
        }
    }

    // MARK: Writes: address and location

    /// Saves the address; what it means for the map pin (`PropertyLocationPlan`) is the caller's: `clearingLocation` drops
    /// a pin found for the old address. Checked against filed years only when the country changes (the one field the tax
    /// figures read).
    @discardableResult
    public func saveAddress(_ address: PropertyAddress, clearingLocation: Bool) async -> Bool {
        guard let current = snapshot.property, let id = current.id else { return false }
        let changesCountry = Properties.addressChangesCountry(address, of: current)
        return await perform(.address, edit: "\(current.name) address edited", scope: changesCountry ? .everyYear : FiledYearEditCheck.Scope()) { db in
            try Properties.saveAddress(db: db, propertyId: id, address, clearingLocation: clearingLocation, includingCountry: changesCountry)
        }
    }

    /// Stores the pin found with Apple Maps (`.lookedUp`) or placed by hand (`.adjusted`); it moves no tax figure.
    @discardableResult
    public func setLocation(_ coordinate: PropertyCoordinate?, source: PropertyLocationSource) async -> Bool {
        guard let id = snapshot.property?.id else { return false }
        return await perform(.map, edit: "Location of \(propertyName) set", scope: FiledYearEditCheck.Scope()) { db in
            try Properties.setLocation(db: db, propertyId: id, coordinate, source: source)
        }
    }

    // MARK: Writes: mortgage terms

    /// A form for the terms, from what is stored.
    public func mortgageForm() -> MortgageTermsEditing.Form? {
        guard let id = snapshot.property?.id else { return nil }
        return MortgageTermsEditing.Form(terms: snapshot.terms ?? PropertyMortgageTerms(propertyId: id), overrides: snapshot.rateOverrides)
    }

    /// The stored values of `index`, for the form's rate now.
    public func series(_ index: InterestIndex) -> MortgageRate.Series {
        snapshot.series[index] ?? MortgageRate.Series(index: index)
    }

    /// Where a refusal of the terms' Save shows: inside the form, which stays open.
    static let mortgageFormRow = "profile-mortgage-form"

    /// The form's Save: its checks, then the terms and the rates given through the writer (filed years checked). False
    /// with the problem or the refusal kept under the form; nothing is saved then.
    @discardableResult
    public func saveMortgage(_ form: MortgageTermsEditing.Form) async -> Bool {
        let day = utcToday
        if let problem = form.validate(today: day).first {
            write.refuse(rowId: Self.mortgageFormRow, message: problem.message)
            return false
        }
        let terms = form.terms(today: day)
        let overrides = form.overrides
        let saved = await write.perform(rowId: Self.mortgageFormRow, origin: .edit, edit: MortgageTermsEditing.edit,
                                        scope: MortgageTermsEditing.scope) { db in
            do {
                try MortgageTermsEditing.apply(db: db, terms: terms, overrides: overrides)
            } catch let error as MortgageTermsError {
                throw MortgageTermsEditing.Problem(MortgageTermsEditing.message(error))
            }
        }
        if saved { await refresh() }
        return saved
    }

    /// The refusal kept under the terms' form.
    public var mortgageFormMessage: String? { write.message(for: Self.mortgageFormRow) }

    // MARK: Writing

    private func perform(_ card: Card, origin: WriteOrigin = .edit, edit: String, scope: FiledYearEditCheck.Scope, refresh: Bool = true,
                         _ body: @escaping @Sendable (Database) throws -> Void) async -> Bool {
        let saved = await write.perform(rowId: card.rowId, origin: origin, edit: edit, scope: scope) { db in
            do {
                try body(db)
            } catch let error as PropertyError {
                throw MortgageTermsEditing.Problem(Self.text(error))
            }
        }
        if saved, refresh { await self.refresh() }
        return saved
    }

    private func refresh() async {
        isPreloaded = false
        await property.reload()
        await read()
    }

    /// The Mac's words for what a Profile edit refuses.
    nonisolated static func text(_ error: PropertyError) -> String {
        switch error {
        case .blankName: return "Enter a name."
        case .duplicateName: return "That name is already used."
        case .invalidCountry: return "Use a two-letter country code, e.g. PT."
        case .personNotFound: return "That person no longer exists."
        case .propertyNotFound: return "The property no longer exists."
        case .accountNotFound: return "That account no longer exists."
        case .categoryGroupNotFound: return "That category group no longer exists."
        case .invalidShare: return "Each share must be more than 0% and at most 100%."
        case .invalidDateRange: return "An end date is before its start date."
        case .overlappingOwnership: return "One person's ownership periods overlap."
        case let .sharesDoNotSumToWhole(date, total):
            let when = date.map { "On \(PhoneDateFormat.day($0))" } ?? "Before the first start date"
            return "\(when) the shares add up to \(percent(total)), not 100%."
        case .invalidLocation: return "That map location isn't valid."
        default: return error.message ?? DeviceWriteCopy.notSaved
        }
    }
}
