import GRDB
import Foundation

/// A UK tax year: 6 April to 5 April (spec §0, §7). Dates are UTC days, like every stored day.
public struct UKTaxYear: Hashable, Comparable, Sendable {
    /// The calendar year it starts in: 2025 for 2025/26.
    public let startYear: Int

    public init(startYear: Int) {
        self.startYear = startYear
    }

    /// The tax year a day falls in (5 April belongs to the year ending then).
    public static func containing(_ date: Date) -> UKTaxYear {
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year!
        let beforeStart = parts.month! < 4 || (parts.month! == 4 && parts.day! < 6)
        return UKTaxYear(startYear: beforeStart ? year - 1 : year)
    }

    /// 6 April of `startYear`, 00:00 UTC.
    public var start: Date { Self.utcCalendar.date(from: DateComponents(year: startYear, month: 4, day: 6))! }
    /// 6 April of the next year, 00:00 UTC: the exclusive end.
    public var end: Date { Self.utcCalendar.date(from: DateComponents(year: startYear + 1, month: 4, day: 6))! }
    /// 5 April of the next year: the last day.
    public var lastDay: Date { Self.utcCalendar.date(from: DateComponents(year: startYear + 1, month: 4, day: 5))! }
    /// `[start, end)`.
    public var interval: DateInterval { DateInterval(start: start, end: end) }
    /// "2025/26".
    public var label: String { String(format: "%d/%02d", startYear, (startYear + 1) % 100) }

    public static func < (lhs: UKTaxYear, rhs: UKTaxYear) -> Bool { lhs.startYear < rhs.startYear }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

/// The missing-evidence checklist (spec §7): what each requirement expects in a period,
/// whether a linked document already satisfies it, and progress by usual source.
public enum MissingEvidence {
    /// What an item needs a document for: a transaction (no slot), or a record for a slot
    /// (periodic) or for good (single, no slot). Documents dropped on an item link to `entity`.
    public struct Target: Hashable, Sendable {
        public var entity: EvidenceEntity
        public var slot: DateInterval?

        public init(entity: EvidenceEntity, slot: DateInterval? = nil) {
            self.entity = entity
            self.slot = slot
        }

        public static func transaction(_ id: Int64) -> Target { Target(entity: .transaction(id)) }
    }

    public enum Status: String, Codable, Sendable {
        case missing
        case satisfied
        /// Marked "not available" (or another reason): counts as done.
        case waived
    }

    public struct Item: Identifiable, Equatable, Sendable {
        /// Stable across runs: requirement, target and slot.
        public var id: String
        public var requirement: EvidenceRequirement
        public var target: Target
        /// The built-in kinds that satisfy it (see `expectedKindRefs` for every kind).
        public var expectedKinds: [DocumentKind]
        /// Any of these satisfies it, built-ins first; empty = any document.
        public var expectedKindRefs: [DocumentKindRef]
        /// `expectedKindRefs`' names, custom kinds as the catalog names them.
        public var expectedKindNames: [String]
        /// The transaction's date (transaction scopes).
        public var expectedDate: Date?
        /// The transaction's amount, sign-free, in `currency` (transaction scopes).
        public var expectedAmountMinorUnits: Int?
        public var currency: Currency?
        /// The slot a periodic item covers (`[start, end)`).
        public var expectedPeriod: DateInterval?
        /// The transaction's description, or the requirement's name.
        public var title: String
        public var categoryName: String?
        public var accountName: String?
        public var usualSource: String?
        public var status: Status
        /// Linked documents of an expected kind (and, for periodic items, inside the slot).
        public var satisfyingDocuments: [EvidenceDocumentSummary]
        public var waiver: EvidenceWaiver?
        /// Documents linked to its record that don't count for it (another kind; for a periodic
        /// item, of its kind but with no date or period), the side panel's "why" (`attached`).
        public var otherDocuments: [EvidenceDocumentSummary] = []

        /// The group the checklist shows it in.
        public var sourceName: String { usualSource ?? MissingEvidence.otherSourceName }
        public var isDone: Bool { status != .missing }
    }

    /// Done/missing counts; waived items count as done.
    public struct Progress: Equatable, Sendable {
        public var total = 0
        public var satisfied = 0
        public var waived = 0

        public init(total: Int = 0, satisfied: Int = 0, waived: Int = 0) {
            self.total = total
            self.satisfied = satisfied
            self.waived = waived
        }

        public var done: Int { satisfied + waived }
        public var missing: Int { total - done }
        /// 0…1; 1 when there's nothing to do.
        public var fractionDone: Double { total == 0 ? 1 : Double(done) / Double(total) }
        /// Rounded down, so 100% means everything is done.
        public var percentDone: Int { total == 0 ? 100 : done * 100 / total }
    }

    public struct SourceGroup: Equatable, Sendable {
        public var source: String
        public var items: [Item]
        public var progress: Progress
    }

    /// The group name of items without a usual source.
    public static let otherSourceName = "Other"

    // MARK: Items

    /// The checklist for a UK tax year.
    public static func items(db: Database, taxYear: UKTaxYear, requirements: [EvidenceRequirement]? = nil) throws -> [Item] {
        try items(db: db, period: taxYear.interval, requirements: requirements)
    }

    /// The checklist for `period` (`[start, end)`) from `requirements` (all stored ones by
    /// default), sorted by source, then date or slot, then requirement and title. A custom kind a
    /// rule names that no longer exists (or hasn't arrived) is left out of it.
    public static func items(db: Database, period: DateInterval, requirements: [EvidenceRequirement]? = nil) throws -> [Item] {
        let catalog = try DocumentKindCatalog.load(db: db)
        let requirements = try (requirements ?? EvidenceRequirements.all(db: db)).map { $0.knowingOnly(catalog) }
        let accounts = Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a) } })
        let categoryNames = Dictionary(uniqueKeysWithValues: try Category.fetchAll(db).compactMap { c in c.id.map { ($0, c.name) } })
        let waivers = try EvidenceWaiver.fetchAll(db)
        var waiverByKey: [String: EvidenceWaiver] = [:]
        for waiver in waivers {
            let target = Target(entity: waiver.entity, slot: waiver.slotStart.map { DateInterval(start: $0, duration: 0) })
            waiverByKey[waiverKey(requirementId: waiver.requirementId, target: target)] = waiver
        }
        var linked = LinkedDocuments(db: db)

        var result: [Item] = []
        for requirement in requirements {
            guard let requirementId = requirement.id, let window = requirement.activeWindow(in: period) else { continue }
            func waiver(_ target: Target) -> EvidenceWaiver? { waiverByKey[waiverKey(requirementId: requirementId, target: target)] }

            switch requirement.scope {
            case .transactionsInCategory, .transactionsInCategoryGroup, .transactionsMatching:
                let transactions = try Self.transactions(db: db, requirement: requirement, from: window.start, to: window.end)
                for transaction in transactions {
                    guard let transactionId = transaction.id else { continue }
                    let target = Target.transaction(transactionId)
                    let all = try linked.documents(for: target.entity)
                    let documents = all.filter { requirement.accepts($0.kindRef) }
                    let account = accounts[transaction.accountId]
                    result.append(item(requirement: requirement, catalog: catalog, target: target, documents: documents, linked: all, waiver: waiver(target),
                                       date: transaction.date, amount: abs(transaction.amountMinorUnits), currency: account?.currency,
                                       period: nil, title: transaction.rawDescription,
                                       categoryName: transaction.categoryId.flatMap { categoryNames[$0] }, accountName: account?.displayName))
                }
            case let .periodic(entity, every):
                let linkedToEntity = try linked.documents(for: entity)
                let all = linkedToEntity.filter { requirement.accepts($0.kindRef) }
                for slot in slots(of: period, every: every) where slot.start < window.end && slot.end > window.start {
                    let target = Target(entity: entity, slot: slot)
                    let documents = all.filter { covers($0, slot: slot) }
                    // Another slot's documents aren't this slot's to explain.
                    let here = linkedToEntity.filter { !isAttachedElsewhereNotHere($0, slot: slot) }
                    result.append(item(requirement: requirement, catalog: catalog, target: target, documents: documents, linked: here, waiver: waiver(target),
                                       date: nil, amount: nil, currency: nil, period: slot, title: requirement.name,
                                       categoryName: nil, accountName: nil))
                }
            case let .single(entity):
                let target = Target(entity: entity)
                let all = try linked.documents(for: entity)
                let documents = all.filter { requirement.accepts($0.kindRef) }
                result.append(item(requirement: requirement, catalog: catalog, target: target, documents: documents, linked: all, waiver: waiver(target),
                                   date: nil, amount: nil, currency: nil, period: nil, title: requirement.name,
                                   categoryName: nil, accountName: nil))
            case let .personalIncomeRecords(record):
                let records = try PersonalIncomeEvidence.records(db: db, kind: record, overlapping: DateInterval(start: window.start, end: window.end))
                for record in records {
                    let target = Target(entity: record.entity)
                    var all: [EvidenceDocumentSummary] = []
                    for entity in record.documentEntities {
                        for document in try linked.documents(for: entity) where !all.contains(where: { $0.id == document.id }) {
                            all.append(document)
                        }
                    }
                    let documents = all.filter { requirement.accepts($0.kindRef) }
                    result.append(item(requirement: requirement, catalog: catalog, target: target, documents: documents, linked: all, waiver: waiver(target),
                                       date: record.date, amount: record.amountMinorUnits, currency: record.amountMinorUnits == nil ? nil : .gbp,
                                       period: record.period, title: record.title, categoryName: nil, accountName: nil))
                }
            case let .recordsOfProperty(propertyId, recordType):
                let records = try PropertyEvidence.records(db: db, propertyId: propertyId, type: recordType,
                                                           overlapping: DateInterval(start: window.start, end: window.end))
                for record in records {
                    let target = Target(entity: record.entity)
                    let all = try linked.documents(for: record.entity)
                    let documents = all.filter { requirement.accepts($0.kindRef) }
                    result.append(item(requirement: requirement, catalog: catalog, target: target, documents: documents, linked: all, waiver: waiver(target),
                                       date: record.date, amount: record.amountMinorUnits, currency: record.currency, period: record.period,
                                       title: record.title, categoryName: nil, accountName: nil))
                }
            }
        }
        return result.sorted(by: itemOrder)
    }

    /// The slots of `period`, laid out from its start (a tax year's months run 6th to 5th),
    /// the last one cut at the period's end.
    public static func slots(of period: DateInterval, every: EvidencePeriodicity) -> [DateInterval] {
        let calendar = UKTaxYear.utcCalendar
        var slots: [DateInterval] = []
        var index = 0
        while true {
            guard let start = calendar.date(byAdding: .month, value: index * every.months, to: period.start), start < period.end else { break }
            let next = calendar.date(byAdding: .month, value: (index + 1) * every.months, to: period.start) ?? period.end
            slots.append(DateInterval(start: start, end: min(next, period.end)))
            index += 1
        }
        return slots
    }

    /// Whether a document belongs to a slot: its covered period (`periodStart`…`periodEnd`,
    /// whole days) covers at least half the slot, or lies at least half inside it; without
    /// a period, its date falls in the slot.
    static func covers(_ document: EvidenceDocumentSummary, slot: DateInterval) -> Bool {
        covers(periodStart: document.periodStart, periodEnd: document.periodEnd, docDate: document.docDate, slot: slot)
    }

    static func covers(periodStart: Date?, periodEnd: Date?, docDate: Date?, slot: DateInterval) -> Bool {
        if let periodStart {
            let lastDay = max(periodEnd ?? periodStart, periodStart)
            let end = UKTaxYear.utcCalendar.date(byAdding: .day, value: 1, to: lastDay)!
            let overlap = min(end, slot.end).timeIntervalSince(max(periodStart, slot.start))
            guard overlap > 0 else { return false }
            return overlap * 2 >= slot.duration || overlap * 2 >= end.timeIntervalSince(periodStart)
        }
        if let date = docDate { return date >= slot.start && date < slot.end }
        return false
    }

    // MARK: Progress and grouping

    public static func progress(_ items: [Item]) -> Progress {
        var progress = Progress(total: items.count)
        for item in items {
            switch item.status {
            case .satisfied: progress.satisfied += 1
            case .waived: progress.waived += 1
            case .missing: break
            }
        }
        return progress
    }

    /// The items by usual source, sources alphabetically with "Other" last; items keep their order.
    public static func bySource(_ items: [Item]) -> [SourceGroup] {
        var order: [String] = []
        var grouped: [String: [Item]] = [:]
        for item in items {
            if grouped[item.sourceName] == nil { order.append(item.sourceName) }
            grouped[item.sourceName, default: []].append(item)
        }
        return order.sorted(by: sourceOrder).map { SourceGroup(source: $0, items: grouped[$0]!, progress: progress(grouped[$0]!)) }
    }

    // MARK: Export

    /// The checklist as Markdown: a heading with overall progress, then a section per
    /// source with a task-list line per item (done items ticked; waived ones struck through
    /// with their reason; satisfied ones naming their documents).
    public static func markdown(items: [Item], title: String, period: DateInterval) -> String {
        let overall = progress(items)
        let lastDay = UKTaxYear.utcCalendar.date(byAdding: .day, value: -1, to: period.end) ?? period.end
        var lines = ["# \(escape(title))", "",
                     "Period \(day(period.start)) to \(day(lastDay)) · \(overall.done) of \(overall.total) done (\(overall.percentDone)%) · \(overall.missing) missing"]
        for group in bySource(items) {
            lines += ["", "## \(escape(group.source)) — \(group.progress.done) of \(group.progress.total) done", ""]
            for item in group.items { lines.append(markdownLine(item)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func markdownLine(_ item: Item) -> String {
        var parts: [String] = []
        if let date = item.expectedDate { parts.append(day(date)) }
        if let slot = item.expectedPeriod {
            let last = UKTaxYear.utcCalendar.date(byAdding: .day, value: -1, to: slot.end) ?? slot.end
            parts.append("\(day(slot.start)) to \(day(last))")
        }
        parts.append(escape(item.title))
        if let amount = item.expectedAmountMinorUnits, let currency = item.currency { parts.append(Money.format(amount, currency: currency)) }
        if let category = item.categoryName, category != item.title { parts.append(escape(category)) }
        if let account = item.accountName { parts.append(escape(account)) }
        let what = parts.joined(separator: " · ")
        let needs = item.expectedKindNames.isEmpty ? "any document" : item.expectedKindNames.joined(separator: " or ")
        switch item.status {
        case .missing:
            return "- [ ] \(what) — needs \(needs)"
        case .satisfied:
            return "- [x] \(what) — \(item.satisfyingDocuments.map { escape($0.displayName) }.joined(separator: "; "))"
        case .waived:
            let reason = item.waiver?.reason == .other ? "waived" : "not available"
            let note = item.waiver?.note.map { ": \(escape($0))" } ?? ""
            return "- [x] ~~\(what)~~ — \(reason)\(note)"
        }
    }

    // MARK: Helpers

    /// `linked`: every document attached to the record that may concern the item (those not in
    /// `documents` become its `otherDocuments`).
    private static func item(requirement: EvidenceRequirement, catalog: DocumentKindCatalog, target: Target, documents: [EvidenceDocumentSummary],
                             linked: [EvidenceDocumentSummary], waiver: EvidenceWaiver?,
                             date: Date?, amount: Int?, currency: Currency?, period: DateInterval?, title: String,
                             categoryName: String?, accountName: String?) -> Item {
        let status: Status = !documents.isEmpty ? .satisfied : (waiver != nil ? .waived : .missing)
        return Item(id: itemId(requirementId: requirement.id ?? 0, target: target), requirement: requirement, target: target,
                    expectedKinds: requirement.kinds, expectedKindRefs: requirement.kindRefs,
                    expectedKindNames: requirement.kindRefs.map(catalog.displayName), expectedDate: date, expectedAmountMinorUnits: amount, currency: currency,
                    expectedPeriod: period, title: title, categoryName: categoryName, accountName: accountName,
                    usualSource: requirement.usualSource, status: status, satisfyingDocuments: documents, waiver: waiver,
                    otherDocuments: linked.filter { document in !documents.contains { $0.id == document.id } })
    }

    static func itemId(requirementId: Int64, target: Target) -> String {
        "\(requirementId):\(waiverKey(requirementId: requirementId, target: target))"
    }

    private static func waiverKey(requirementId: Int64, target: Target) -> String {
        let slot = target.slot.map { String(Int64($0.start.timeIntervalSince1970)) } ?? "-"
        return "\(requirementId)/\(target.entity.type.rawValue)/\(target.entity.id)/\(slot)"
    }

    private static func transactions(db: Database, requirement: EvidenceRequirement, from: Date, to: Date) throws -> [Transaction] {
        // Transfers count once, as sent: an active link's incoming leg needs no evidence.
        var clauses = ["date >= ?", "date < ?", Transaction.budgetFacingCondition()]
        var arguments: [any DatabaseValueConvertible] = [from, to]
        if !requirement.excludedAccountIds.isEmpty {
            clauses.append("accountId NOT IN (\(requirement.excludedAccountIds.map { _ in "?" }.joined(separator: ",")))")
            arguments += requirement.excludedAccountIds.map { $0 as any DatabaseValueConvertible }
        }
        switch requirement.scope {
        case let .transactionsInCategory(categoryId):
            clauses.append("categoryId = ?")
            arguments.append(categoryId)
        case let .transactionsInCategoryGroup(groupId):
            clauses.append("categoryId IN (SELECT id FROM category WHERE groupId = ?)")
            arguments.append(groupId)
        case let .transactionsMatching(categoryIds, accountIds, text):
            let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !categoryIds.isEmpty || !accountIds.isEmpty || !text.isEmpty else { return [] }
            if !categoryIds.isEmpty {
                clauses.append("categoryId IN (\(categoryIds.map { _ in "?" }.joined(separator: ",")))")
                arguments += categoryIds.map { $0 as any DatabaseValueConvertible }
            }
            if !accountIds.isEmpty {
                clauses.append("accountId IN (\(accountIds.map { _ in "?" }.joined(separator: ",")))")
                arguments += accountIds.map { $0 as any DatabaseValueConvertible }
            }
            if !text.isEmpty {
                let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                clauses.append("rawDescription LIKE ? ESCAPE '\\'")
                arguments.append("%\(escaped)%")
            }
        case .periodic, .single, .recordsOfProperty, .personalIncomeRecords:
            return []
        }
        switch requirement.direction {
        case .outflows: clauses.append("amountMinorUnits < 0")
        case .inflows: clauses.append("amountMinorUnits > 0")
        case .any: break
        }
        return try Transaction.fetchAll(db, sql: "SELECT * FROM transaction_ WHERE \(clauses.joined(separator: " AND ")) ORDER BY date, id",
                                        arguments: StatementArguments(arguments))
    }

    /// Linked document summaries by record, loaded per entity type on first use.
    private struct LinkedDocuments {
        let db: Database
        var byType: [EvidenceEntityType: [Int64: [EvidenceDocumentSummary]]] = [:]

        init(db: Database) {
            self.db = db
        }

        mutating func documents(for entity: EvidenceEntity) throws -> [EvidenceDocumentSummary] {
            if byType[entity.type] == nil {
                let rows = try Row.fetchAll(db, sql: "SELECT entityId, documentId FROM documentLink WHERE entityType = ? ORDER BY id",
                                            arguments: [entity.type.rawValue])
                let documentIds = Set(rows.map { $0[1] as Int64 })
                let summaries = try EvidenceDocumentSummary.filter(keys: Array(documentIds)).fetchAll(db)
                let byId = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
                var map: [Int64: [EvidenceDocumentSummary]] = [:]
                for row in rows {
                    if let document = byId[row[1] as Int64] { map[row[0] as Int64, default: []].append(document) }
                }
                for key in map.keys {
                    map[key]!.sort { ($0.docDate ?? .distantFuture, $0.id) < ($1.docDate ?? .distantFuture, $1.id) }
                }
                byType[entity.type] = map
            }
            return byType[entity.type]?[entity.id] ?? []
        }
    }

    private static func sourceOrder(_ lhs: String, _ rhs: String) -> Bool {
        if (lhs == otherSourceName) != (rhs == otherSourceName) { return rhs == otherSourceName }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private static func itemOrder(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.sourceName != rhs.sourceName { return sourceOrder(lhs.sourceName, rhs.sourceName) }
        let lDate = lhs.expectedDate ?? lhs.expectedPeriod?.start ?? .distantPast
        let rDate = rhs.expectedDate ?? rhs.expectedPeriod?.start ?? .distantPast
        if lDate != rDate { return lDate < rDate }
        if lhs.requirement.name != rhs.requirement.name { return lhs.requirement.name.localizedCaseInsensitiveCompare(rhs.requirement.name) == .orderedAscending }
        if lhs.title != rhs.title { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
        return lhs.id < rhs.id
    }

    static func day(_ date: Date) -> String {
        let parts = UKTaxYear.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Markdown-safe text: line breaks flattened; emphasis, links, code, headings, tables
    /// and HTML escaped.
    static func escape(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        for character in ["\\", "*", "_", "~", "[", "]", "`", "#", "|", "<", ">"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result
    }
}
