// Sources/BudgetCore/DocumentImport/ImportReviewState.swift
import Foundation
import GRDB

// MARK: The review's state

/// The open plan as the review shows it — its sections, Ready's groups, each statement's
/// rows and the footer's counts — worked out once when the plan changes
/// (`ImportSession.plan`), so drawing the review never walks the plan.
public struct ImportReviewState: Sendable {
    /// A document's row: the item, the line under its title, its figure.
    public struct Row: Identifiable, Sendable {
        public let item: ImportItem
        /// The row's title when not the item's (a duplicate file's name).
        public var title: String? = nil
        public let detail: String?
        public let figure: ImportFactValue?
        /// A statement's row (a possible duplicate) shown indented under its statement.
        public var isIndented = false
        public var id: UUID { item.id }
    }

    /// A Ready group: its one-line summary and its documents.
    public struct Group: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let summary: String
        public let rows: [Row]
    }

    public let needsYou: [Row]
    public let ready: [Group]
    public let duplicates: [Row]
    public let leftOut: [Row]
    /// Every item by id (the preview's selection).
    public let items: [UUID: ImportItem]
    /// A statement's rows held apart from it (rows already imported), by the statement.
    public let children: [UUID: [ImportItem]]
    /// A statement's rows the checks ask about or the user answered (`StatementChecks.isRowChild`:
    /// possible duplicates, kept and skipped rows), by the statement: shown under it, never as
    /// documents of their own (a possible duplicate also as its own Needs-you row, indented).
    public let rows: [UUID: [ImportItem]]
    /// Left-out items that "Put back" brings back: not a statement's rows while the statement
    /// is out (they come back with it; Core refuses them alone).
    public let canPutBack: Set<UUID>
    public let readyCount: Int
    /// "4 ready · 2 need you · 1 duplicate".
    public let countsLine: String
    public let canConfirm: Bool
    public let ignoredFiles: [String]
    public let isEmpty: Bool

    public init(_ plan: ImportPlan) {
        var byId: [UUID: ImportItem] = [:]
        for item in plan.items { byId[item.id] = item }
        var bySection: [ImportSection: [ImportItem]] = [:]
        var children: [UUID: [ImportItem]] = [:]
        var rows: [UUID: [ImportItem]] = [:]
        var documents: [ImportItem] = []
        for item in plan.items {
            if let parentId = item.parentId, let parent = byId[parentId], StatementChecks.isRowChild(item, of: parent) {
                rows[parentId, default: []].append(item)
                continue
            }
            documents.append(item)
            bySection[item.section, default: []].append(item)
            if let parentId = item.parentId { children[parentId, default: []].append(item) }
        }
        items = byId
        self.children = children
        self.rows = rows
        // A statement's rows to keep or skip right under it, indented.
        var needsYou: [Row] = []
        for item in bySection[.needsYou] ?? [] {
            needsYou.append(Row(item: item, detail: item.needsYouReasons.first, figure: item.headlineFigure))
            for row in rows[item.id] ?? [] where row.section == .needsYou {
                needsYou.append(Row(item: row, detail: row.needsYouReasons.first, figure: nil, isIndented: true))
            }
        }
        // (A statement's rows wait only while it does: never without it, but shown if so.)
        let shown = Set(needsYou.map(\.id))
        for item in plan.items where item.section == .needsYou && !shown.contains(item.id) {
            if let parentId = item.parentId, rows[parentId]?.contains(where: { $0.id == item.id }) == true {
                needsYou.append(Row(item: item, detail: item.needsYouReasons.first, figure: nil, isIndented: true))
            }
        }
        self.needsYou = needsYou
        duplicates = (bySection[.duplicates] ?? []).map { Row(item: $0, title: $0.parentId == nil ? $0.file.fileName : $0.title, detail: $0.duplicate?.of, figure: nil) }
        canPutBack = Set((bySection[.leftOut] ?? []).filter { item in
            item.parentId.flatMap { byId[$0] }?.isLeftOut != true
        }.map(\.id))
        leftOut = (bySection[.leftOut] ?? []).map { Row(item: $0, detail: $0.recognition.kind.displayName, figure: $0.headlineFigure) }
        // Ready's groups and summaries without the statements' rows (a kept row is its statement's).
        ready = ImportPlan(items: documents).readyGroups.map { group in
            Group(id: group.id, title: group.title, summary: group.summary,
                  rows: group.itemIds.compactMap { byId[$0] }.map { Row(item: $0, detail: $0.readyDetail, figure: $0.headlineFigure) })
        }
        canConfirm = plan.canConfirm
        ignoredFiles = plan.ignoredFiles
        isEmpty = documents.isEmpty
        readyCount = bySection[.ready]?.count ?? 0
        countsLine = Self.countsLine(ready: readyCount, needsYou: needsYou.count,
                                     duplicates: duplicates.count, leftOut: leftOut.count)
    }

    /// Ready and Needs you always; duplicates and left out when there are any.
    public static func countsLine(ready: Int, needsYou: Int, duplicates: Int, leftOut: Int) -> String {
        var parts = ["\(ready) ready", "\(needsYou) need\(needsYou == 1 ? "s" : "") you"]
        if duplicates > 0 { parts.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s")") }
        if leftOut > 0 { parts.append("\(leftOut) left out") }
        return parts.joined(separator: " · ")
    }
}

/// The names a "which one?" question offers: properties, people, accounts, tenancies and
/// utility providers, by id.
public struct ImportTargetNames: Equatable, Sendable {
    public var names: [ImportTargetKind: [Int64: String]] = [:]

    public func name(_ kind: ImportTargetKind, _ id: Int64) -> String {
        if let name = names[kind]?[id] { return name }
        switch kind {
        case .property: return "Property #\(id)"
        case .person: return "Person #\(id)"
        case .account: return "Account #\(id)"
        case .tenancy: return "Tenancy #\(id)"
        case .provider: return "Provider #\(id)"
        case .invoice: return "Invoice #\(id)"
        }
    }

    public static func read(_ db: Database) throws -> ImportTargetNames {
        func byId<T>(_ records: [T], _ id: KeyPath<T, Int64?>, _ name: (T) -> String) -> [Int64: String] {
            var result: [Int64: String] = [:]
            for record in records { if let key = record[keyPath: id] { result[key] = name(record) } }
            return result
        }
        let properties = try Property.fetchAll(db)
        let propertyNames = byId(properties, \.id, \.name)
        let providers = try UtilityProvider.fetchAll(db)
        return ImportTargetNames(names: [
            .property: propertyNames,
            .person: byId(try Person.fetchAll(db), \.id, \.name),
            .account: byId(try Account.fetchAll(db), \.id, \.displayName),
            .tenancy: byId(try Tenancy.fetchAll(db), \.id, \.referenceLabel),
            // "EDP · Flat 1": a provider's name alone may be shared by two properties.
            .provider: byId(providers, \.id) { provider in
                propertyNames[provider.propertyId].map { "\(provider.name) · \($0)" } ?? provider.name
            },
            // "€12.30 · 2019-01-01 – 2019-01-31 · no document" (`Recharges.choiceLabel`).
            .invoice: byId(try UtilityInvoice.fetchAll(db), \.id) { invoice in
                let provider = providers.first { $0.id == invoice.providerId }
                return Recharges.choiceLabel(invoice, currency: properties.first { $0.id == provider?.propertyId }?.currency ?? .eur)
            }
        ])
    }
}

// MARK: Figures

extension ImportItem {
    /// The figure a row shows: the amount (or pay), else the date or period start, else the tax year.
    public var headlineFigure: ImportFactValue? {
        for field in [ImportFigureField.amount, .pay, .docDate, .periodStart, .taxYear] {
            if let fact = facts.first(where: { $0.field == field }) { return fact.value }
        }
        return nil
    }

    /// A Ready row's line: its first note, else what it links to, else where it's filed.
    public var readyDetail: String? {
        // A link the user chose is named first, with the others ("Links to Flat 1 · THE GOLDEN SPOON").
        let chosen = links.contains { $0.reasons.contains(ImportResolutions.chosenReasonText) }
        if !chosen, let note = notes.first { return note }
        if !links.isEmpty { return "Links to " + links.map(\.label).joined(separator: " · ") }
        if let note = notes.first { return note }
        return placement.map { "Filed as \($0.canonicalName)" }
    }
}
