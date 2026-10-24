import Foundation

/// A custom kind as the Kinds sheet lists it: its name, area and how many documents it has.
public struct CustomKindRow: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var name: String
    public var area: DocumentArea
    public var documents: Int

    public init(id: Int64, name: String, area: DocumentArea, documents: Int) {
        self.id = id
        self.name = name
        self.area = area
        self.documents = documents
    }
}

/// The Kinds sheet's staged changes (spec 2026-10-24 §2): renames (name and area) and merges,
/// nothing written until Save applies `edits` with `CustomDocumentKinds.save` in one write.
/// `problem` says before Save what Save would refuse (a taken or empty name, a kind merged into
/// itself); a Save that would change a filed year is only known when it is tried.
public struct CustomKindsDraft: Equatable, Sendable {
    /// The kinds as read, by name.
    public let rows: [CustomKindRow]
    private var changes: [Int64: KindEdit.Change] = [:]

    public init(rows: [CustomKindRow]) {
        self.rows = rows
    }

    private func row(_ id: Int64) -> CustomKindRow? { rows.first { $0.id == id } }

    /// The kinds as read, for the checks (the catalog Save checks against).
    private var catalog: DocumentKindCatalog {
        DocumentKindCatalog(customKinds: rows.map { CustomDocumentKind(id: $0.id, name: $0.name, area: $0.area, createdAt: .distantPast) })
    }

    // MARK: Staging

    /// Stages a rename; back to the kind's own name and area, it is no change.
    public mutating func rename(_ id: Int64, name: String, area: DocumentArea) {
        guard let row = row(id) else { return }
        if name.trimmingCharacters(in: .whitespacesAndNewlines) == row.name && area == row.area {
            changes[id] = nil
        } else {
            changes[id] = .rename(name: name, area: area)
        }
    }

    /// Stages a merge into `target` (it replaces the kind's rename).
    public mutating func merge(_ id: Int64, into target: DocumentKindRef) {
        guard row(id) != nil, target != .custom(id) else { return }
        changes[id] = .merge(into: target)
    }

    /// Drops the kind's staged change.
    public mutating func revert(_ id: Int64) {
        changes[id] = nil
    }

    // MARK: Reading

    public var hasChanges: Bool { !changes.isEmpty }

    /// What Save applies, in the list's order.
    public var edits: [KindEdit] {
        rows.compactMap { row in changes[row.id].map { KindEdit(kindId: row.id, change: $0) } }
    }

    /// Why Save would be refused, as Save words it; nil when it can be tried.
    public var problem: String? {
        do {
            try CustomDocumentKinds.check(edits, catalog: catalog)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public var canSave: Bool { hasChanges && problem == nil }

    /// The name the kind will have (its own while it merges away).
    public func name(of id: Int64) -> String {
        if case let .rename(name, _)? = changes[id] { return name }
        return row(id)?.name ?? ""
    }

    public func area(of id: Int64) -> DocumentArea {
        if case let .rename(_, area)? = changes[id] { return area }
        return row(id)?.area ?? .other
    }

    /// The kind it is staged to merge into.
    public func mergeTarget(of id: Int64) -> DocumentKindRef? {
        if case let .merge(target)? = changes[id] { return target }
        return nil
    }

    /// A kind's name as the sheet shows it: a custom kind by its staged name.
    public func label(_ ref: DocumentKindRef) -> String {
        switch ref {
        case .builtIn(let kind): return kind.displayName
        case .custom(let id): return row(id) == nil ? catalog.displayName(ref) : name(of: id)
        }
    }

    /// "Merges into Repair bill", "Renamed from Boiler service", "Moved from Property"; nil when unchanged.
    public func status(of id: Int64) -> String? {
        guard let row = row(id), let change = changes[id] else { return nil }
        switch change {
        case .merge(let target): return "Merges into \(label(target))"
        case let .rename(name, area):
            if name.trimmingCharacters(in: .whitespacesAndNewlines) != row.name { return "Renamed from \(row.name)" }
            return area != row.area ? "Moved from \(row.area.libraryArea)" : nil
        }
    }

    /// What the kind can merge into: the built-in kinds by name, then the other custom kinds not
    /// merged away, by their staged names.
    public func mergeTargets(for id: Int64) -> [(ref: DocumentKindRef, label: String)] {
        func ordered(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
        let builtIns = DocumentKind.allCases.map { (ref: DocumentKindRef.builtIn($0), label: $0.displayName) }.sorted { ordered($0.label, $1.label) }
        let custom = rows.filter { $0.id != id && mergeTarget(of: $0.id) == nil }
            .map { (ref: DocumentKindRef.custom($0.id), label: name(of: $0.id)) }.sorted { ordered($0.label, $1.label) }
        return builtIns + custom
    }

    /// "Saved. 3 documents, 1 learnt rule and 2 evidence rules changed." ("Saved." when nothing else changed).
    public static func savedMessage(_ result: KindSaveResult) -> String {
        func count(_ n: Int, _ one: String) -> String? { n == 0 ? nil : "\(n) \(one)\(n == 1 ? "" : "s")" }
        let parts = [count(result.documentsChanged, "document"), count(result.rulesChanged, "learnt rule"),
                     count(result.requirementsChanged, "evidence rule")].compactMap { $0 }
        guard let last = parts.last else { return "Saved." }
        let list = parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
        return "Saved. \(list) changed."
    }
}
