import Foundation
import GRDB

/// The areas the Missing documents centre groups by (step 20).
public enum MissingDocumentArea: String, CaseIterable, Sendable {
    case tax, tenancy, property

    public var title: String {
        switch self {
        case .tax: "Tax"
        case .tenancy: "Tenancy"
        case .property: "Property"
        }
    }
}

/// Where a row's demand comes from.
public enum MissingDocumentSource: String, Sendable {
    /// An evidence rule's item (`MissingEvidence`, as `TaxYearEvidence` reads it): attach a file to its record.
    case evidence
    /// A tenancy's utility payment with no invoice recorded (`UtilityBills`): Recharges takes the invoice.
    case utilityBill
    /// A document waiting for the statement that pays it (`WaitingDocuments`).
    case waitingPayment
}

/// One thing Mango expects a document for (or a payment for, `.waitingPayment`).
public struct MissingDocumentRow: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case missing
        /// A linked document counts for it.
        case have
        /// Marked not expected (its waiver), reversible.
        case notExpected
    }

    public var id: String
    public var area: MissingDocumentArea
    public var source: MissingDocumentSource
    public var state: State
    /// What is missing.
    public var title: String
    /// Why it is needed, or what it covers.
    public var detail: String?
    /// The tenancy's name (tenancy rows) or the property's: never a person's name.
    public var context: String?
    /// The period it covers, `[start, end)`.
    public var period: DateInterval?
    /// When it fell due: the end of its period, its date, else the end of its tax year.
    public var due: Date
    /// The UK tax years (start years) it belongs to; filters match any.
    public var taxYears: [Int]
    public var amountMinorUnits: Int?
    public var currency: Currency?
    /// "Portal das Finanças", "Employer": where it is usually found.
    public var usualSource: String?
    public var suggestedSiteKind: SavedSiteKind?
    /// A filed or paid year: shown, never changed from here.
    public var isFiledYear: Bool
    /// The viewer may attach a file to it (evidence rows, Edit on Documents, not a filed year).
    public var canAttach: Bool
    /// The viewer may mark it not expected (an evidence row, Edit on Documents and Property).
    public var canMarkNotExpected: Bool
    /// The checklist item behind an evidence row (attach, waive and the per-year panel use it).
    public var item: MissingEvidence.Item?
    public var tenancyId: Int64?
    public var propertyId: Int64?
    public var documentId: Int64?

    public var calendarYear: Int { UKTaxYear.utcCalendar.component(.year, from: due) }
    public func isOverdue(now: Date) -> Bool { state == .missing && due < now }
    public func isDueSoon(now: Date) -> Bool {
        state == .missing && due >= now && due < now.addingTimeInterval(MissingDocuments.dueSoonDays * 86_400)
    }
}

/// What the centre's filters narrow the rows to.
public struct MissingDocumentFilter: Equatable, Sendable {
    public enum Timing: Equatable, Sendable { case any, dueSoon, overdue }

    public var area: MissingDocumentArea?
    public var taxYear: Int?
    public var calendarYear: Int?
    public var timing: Timing = .any
    public var text = ""

    public init(area: MissingDocumentArea? = nil, taxYear: Int? = nil, calendarYear: Int? = nil, timing: Timing = .any, text: String = "") {
        self.area = area
        self.taxYear = taxYear
        self.calendarYear = calendarYear
        self.timing = timing
        self.text = text
    }
}

/// The Missing documents centre (step 20): every document Mango expects and doesn't have, across tax, tenancy and
/// property, not tied to one tax year. One query over the existing demand sources, no rules of its own:
/// - the evidence rules' items per tax year (`TaxYearEvidence.areas`: open and filed years, filed ones read-only);
/// - utility payments of a tenancy with no invoice (`UtilityBills`, stage missing invoice);
/// - documents waiting for the payment that settles them (`WaitingDocuments`).
/// A viewer sees only what her access shows (Documents for anything, Property for the property's and tenancy's rows,
/// each person's Tax for theirs). Tenancy rows are labelled by the tenancy's name, never the tenant's own.
public enum MissingDocuments {
    public static let dueSoonDays = 30.0

    public struct Result: Equatable, Sendable {
        /// Missing and have rows together, oldest due first.
        public var rows: [MissingDocumentRow]
        public init(rows: [MissingDocumentRow]) { self.rows = rows }
        public var missing: [MissingDocumentRow] { rows.filter { $0.state == .missing } }
        public var notExpected: [MissingDocumentRow] { rows.filter { $0.state == .notExpected } }
        /// The sidebar badge.
        public var missingCount: Int { rows.filter { $0.state == .missing }.count }
    }

    /// Every row the viewer may see (nil: everything), from `earliest` through the tax year containing `now`.
    public static func read(db: Database, now: Date = Date(), viewer: AccessActor? = nil, earliest: UKTaxYear? = nil) throws -> Result {
        let current = UKTaxYear.containing(now)
        let first = min(earliest ?? UKTaxYear(startYear: 2023), current)
        let filed = try FiledYearGuard.filedYears(db: db)
        let access = try TaxYearEvidence.Visibility(db: db, viewer: viewer)
        guard access.documents else { return Result(rows: []) }
        var rows: [MissingDocumentRow] = []
        var seen: [String: Int] = [:]

        // Evidence rules, year by year; a record that spans years (a contract) is one row listing them.
        let properties = try Property.fetchAll(db)
        let propertyName = properties.count == 1 ? properties[0].name : nil
        let tenancies = Dictionary(uniqueKeysWithValues: try Tenancy.fetchAll(db).compactMap { t in t.id.map { ($0, t) } })
        let receiptTenancy = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, tenancyId FROM rentReceipt")
            .map { ($0["id"] as Int64, $0["tenancyId"] as Int64) })
        let canWaive = try viewer.map { try AccessPolicy.can($0, .edit, .property, db: db) } ?? true
        for startYear in first.startYear...current.startYear {
            let year = UKTaxYear(startYear: startYear)
            for area in try TaxYearEvidence.areas(db: db, taxYear: year, viewer: viewer) {
                for evidence in area.items {
                    if let index = seen[evidence.id] {
                        rows[index].taxYears.append(startYear)
                        continue
                    }
                    let item = evidence.item
                    let kind = placement(of: item, area: area.area)
                    var tenancyId: Int64?
                    switch item.target.entity.type {
                    case .tenancy: tenancyId = item.target.entity.id
                    case .rentReceipt: tenancyId = receiptTenancy[item.target.entity.id]
                    default: break
                    }
                    let isFiled = filed.contains(startYear)
                    let state: MissingDocumentRow.State = evidence.state == .missing ? .missing : (item.status == .waived ? .notExpected : .have)
                    seen[evidence.id] = rows.count
                    rows.append(MissingDocumentRow(
                        id: "evidence:\(evidence.id)", area: kind, source: .evidence, state: state, title: item.title,
                        detail: evidence.why,
                        context: tenancyId.flatMap { tenancies[$0]?.referenceLabel } ?? (kind == .tax ? nil : propertyName),
                        period: item.expectedPeriod,
                        due: item.expectedPeriod?.end ?? item.expectedDate ?? year.lastDay, taxYears: [startYear],
                        amountMinorUnits: item.expectedAmountMinorUnits, currency: item.currency, usualSource: evidence.source,
                        suggestedSiteKind: evidence.suggestedSiteKind, isFiledYear: isFiled,
                        canAttach: evidence.canLink && !isFiled,
                        canMarkNotExpected: evidence.canLink && canWaive && !isFiled && item.requirement.id != nil,
                        item: item, tenancyId: tenancyId, propertyId: tenancyId.flatMap { tenancies[$0]?.propertyId }))
                }
            }
        }

        // Utility payments no invoice accounts for: Recharges takes the invoice (the tenancy's own name labels them).
        if access.property {
            for tenancy in tenancies.values.sorted(by: { ($0.startDate, $0.id ?? 0) < ($1.startDate, $1.id ?? 0) }) {
                guard let tenancyId = tenancy.id else { continue }
                let grid = try UtilityBills.read(db: db, propertyId: tenancy.propertyId, tenancyId: tenancyId)
                for bill in grid.bills where bill.stage == .missingInvoice {
                    let monthEnd = UKTaxYear.utcCalendar.date(byAdding: .month, value: 1, to: bill.month) ?? bill.month
                    let year = UKTaxYear.containing(bill.month).startYear
                    rows.append(MissingDocumentRow(
                        id: "utility:\(tenancyId):\(bill.id)", area: .tenancy, source: .utilityBill, state: .missing,
                        title: "\(bill.providerName) bill", detail: "A payment with no invoice recorded; the tenancy's recharge needs it.",
                        context: tenancy.referenceLabel, period: DateInterval(start: bill.month, end: monthEnd),
                        due: bill.payments.first?.date ?? monthEnd, taxYears: [year], amountMinorUnits: bill.amountMinorUnits,
                        currency: nil, usualSource: bill.providerName, suggestedSiteKind: nil, isFiledYear: false,
                        canAttach: false, canMarkNotExpected: false, item: nil, tenancyId: tenancyId, propertyId: tenancy.propertyId))
                }
            }
        }

        // Documents waiting for the statement that pays them.
        let waiting = try WaitingDocuments.states(db: db, now: now).filter { $0.value == .waiting }.keys.sorted()
        for documentId in waiting {
            guard let document = try EvidenceDocument.fetchOne(db, key: documentId) else { continue }
            let links = try DocumentLink.filter(Column("documentId") == documentId).fetchAll(db)
            let isProperty = links.contains { [.property, .tenancy, .rentReceipt].contains($0.entityType) }
            if isProperty, !access.property { continue }
            let anchor = WaitingDocuments.anchor(document)
            rows.append(MissingDocumentRow(
                id: "waiting:\(documentId)", area: isProperty ? .property : .tax, source: .waitingPayment, state: .missing,
                title: "Payment for \(document.displayName)", detail: "Filed before its statement; it links itself when the payment arrives.",
                context: isProperty ? propertyName : nil, period: nil, due: anchor, taxYears: [UKTaxYear.containing(anchor).startYear],
                amountMinorUnits: document.amountMinorUnits, currency: document.currency, usualSource: nil, suggestedSiteKind: nil,
                isFiledYear: false, canAttach: false, canMarkNotExpected: false, item: nil, tenancyId: nil, propertyId: nil,
                documentId: documentId))
        }
        return Result(rows: rows.sorted(by: dueOrder))
    }

    /// The tenancy's records (contract, rent receipts) are Tenancy; the property's other costs Property; the rest Tax.
    static func placement(of item: MissingEvidence.Item, area: EvidenceAreaKind) -> MissingDocumentArea {
        switch item.target.entity.type {
        case .tenancy, .rentReceipt: return .tenancy
        default: break
        }
        if Set(item.expectedKinds).isSubset(of: [.rentContract, .tenancyAddendum, .rentReceipt]), !item.expectedKinds.isEmpty { return .tenancy }
        return area == .lisbonFlat ? .property : .tax
    }

    // MARK: Filtering and ordering

    /// Oldest due first, then title, then id.
    static func dueOrder(_ lhs: MissingDocumentRow, _ rhs: MissingDocumentRow) -> Bool {
        if lhs.due != rhs.due { return lhs.due < rhs.due }
        if lhs.title != rhs.title { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// The missing rows matching `filter`, in their order. Search matches the title, context, source, detail and kinds' names
    /// (case- and accent-insensitive, every word), or an amount equal to the row's.
    public static func missing(_ rows: [MissingDocumentRow], filter: MissingDocumentFilter, now: Date = Date()) -> [MissingDocumentRow] {
        select(rows, state: .missing, filter: filter, now: now)
    }

    /// The rows marked not expected matching `filter`.
    public static func notExpected(_ rows: [MissingDocumentRow], filter: MissingDocumentFilter, now: Date = Date()) -> [MissingDocumentRow] {
        select(rows, state: .notExpected, filter: filter, now: now)
    }

    private static func select(_ rows: [MissingDocumentRow], state: MissingDocumentRow.State, filter: MissingDocumentFilter,
                               now: Date) -> [MissingDocumentRow] {
        let terms = filter.text.split(whereSeparator: \.isWhitespace).map { word in
            (folded: fold(String(word)), amount: TransactionSearch.amountToken(String(word)))
        }
        return rows.filter { row in
            guard row.state == state else { return false }
            if let area = filter.area, row.area != area { return false }
            if let year = filter.taxYear, !row.taxYears.contains(year) { return false }
            if let year = filter.calendarYear, row.calendarYear != year { return false }
            switch filter.timing {
            case .any: break
            case .dueSoon: if !row.isDueSoon(now: now) { return false }
            case .overdue: if !row.isOverdue(now: now) { return false }
            }
            guard !terms.isEmpty else { return true }
            let haystack = fold([row.title, row.context ?? "", row.usualSource ?? "", row.detail ?? "", row.area.title,
                                 row.item?.expectedKindNames.joined(separator: " ") ?? ""].joined(separator: "\u{1}"))
            return terms.allSatisfy { term in (term.amount != nil && row.amountMinorUnits == term.amount) || haystack.contains(term.folded) }
        }
    }

    /// Per area, the rows' counts (the page's group headings and the area filter).
    public static func counts(_ rows: [MissingDocumentRow]) -> [MissingDocumentArea: Int] {
        Dictionary(grouping: rows.filter { $0.state == .missing }, by: \.area).mapValues(\.count)
    }

    /// The tax years and calendar years the rows span, latest first (the filters' choices).
    public static func taxYears(_ rows: [MissingDocumentRow]) -> [Int] { Array(Set(rows.flatMap(\.taxYears))).sorted(by: >) }
    public static func calendarYears(_ rows: [MissingDocumentRow]) -> [Int] { Array(Set(rows.map(\.calendarYear))).sorted(by: >) }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: Not expected

    /// Marks an evidence row not expected, with a reason (its waiver); the caller's write holds the access check.
    @discardableResult
    public static func markNotExpected(db: Database, row: MissingDocumentRow, reason: EvidenceWaiverReason = .notAvailable,
                                       note: String? = nil) throws -> Bool {
        guard row.canMarkNotExpected, let item = row.item, let requirementId = item.requirement.id else { return false }
        _ = try EvidenceRequirements.waive(db: db, requirementId: requirementId, target: item.target, reason: reason, note: note)
        return true
    }

    /// Puts a not-expected evidence row back among the missing ones.
    @discardableResult
    public static func restore(db: Database, row: MissingDocumentRow) throws -> Bool {
        guard row.state == .notExpected, row.canMarkNotExpected, let item = row.item, let requirementId = item.requirement.id else { return false }
        return try EvidenceRequirements.removeWaiver(db: db, requirementId: requirementId, target: item.target)
    }

    // MARK: Open site

    /// The saved site "Open site" goes to for a row: of its suggested kind, the one named like a part of its usual source
    /// ("HMRC / bank": HMRC's, else the bank's), else the first of that kind; nil when none of that kind is saved.
    public static func site(kind: SavedSiteKind?, source: String?, in sites: [SavedSite]) -> SavedSite? {
        guard let kind else { return nil }
        let ofKind = sites.filter { $0.kind == kind }
        for part in (source ?? "").split(separator: "/").map({ fold(String($0)).trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            if let named = ofKind.first(where: { let site = fold($0.name).trimmingCharacters(in: .whitespaces); return site.contains(part) || part.contains(site) }) {
                return named
            }
        }
        return ofKind.first
    }

    public static func site(for row: MissingDocumentRow, in sites: [SavedSite]) -> SavedSite? {
        site(kind: row.suggestedSiteKind, source: row.usualSource, in: sites)
    }
}
