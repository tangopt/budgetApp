import GRDB
import Foundation

/// One staged change in the Kinds sheet (spec 2026-10-24 §2): rename a custom kind (name and
/// area) or merge it into another kind, built-in or custom.
public struct KindEdit: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case rename(name: String, area: DocumentArea)
        case merge(into: DocumentKindRef)
    }

    public var kindId: Int64
    public var change: Change

    public init(kindId: Int64, change: Change) {
        self.kindId = kindId
        self.change = change
    }
}

/// What a Kinds sheet Save changed besides the kinds themselves.
public struct KindSaveResult: Equatable, Sendable {
    /// Documents re-filed (a merge) or renamed (their canonical name's `<Area> - <Name>`).
    public var documentsChanged: Int
    /// Learnt `documentKind` rules re-pointed or relabelled.
    public var rulesChanged: Int
    /// Evidence rules that accepted a merged kind and now accept its target.
    public var requirementsChanged: Int

    public init(documentsChanged: Int = 0, rulesChanged: Int = 0, requirementsChanged: Int = 0) {
        self.documentsChanged = documentsChanged
        self.rulesChanged = rulesChanged
        self.requirementsChanged = requirementsChanged
    }
}

/// Making, renaming and merging custom kinds (spec 2026-10-24 §2). Built-in kinds can't be
/// renamed or merged; a custom kind's name can't be a built-in's or another custom kind's,
/// ignoring case and accents.
public enum CustomDocumentKinds {
    public enum Failure: Error, Equatable, LocalizedError {
        case emptyName
        /// The name of the kind (built-in or custom) that already has it, ignoring case and accents.
        case nameTaken(String)
        case notFound(Int64)
        case mergeIntoItself

        public var errorDescription: String? {
            switch self {
            case .emptyName: return "Give the kind a name."
            case .nameTaken(let name): return "There's already a kind called \u{201C}\(name)\u{201D}."
            case .notFound: return "That kind no longer exists. Close the sheet and open it again."
            case .mergeIntoItself: return "A kind can't be merged into itself."
            }
        }
    }

    /// Inserts a custom kind, its name trimmed, in the caller's write.
    @discardableResult
    public static func create(db: Database, name: String, area: DocumentArea, now: Date) throws -> CustomDocumentKind {
        let name = try checkedName(name)
        if let builtIn = builtInNamed(name) { throw Failure.nameTaken(builtIn.displayName) }
        if let existing = try DocumentKindCatalog.load(db: db).custom(named: name) { throw Failure.nameTaken(existing.name) }
        var kind = CustomDocumentKind(name: name, area: area, createdAt: now)
        try kind.insert(db)
        return kind
    }

    /// Applies the Kinds sheet's staged edits, all or none, in the caller's one write. When a kind
    /// has several edits the last one counts. A rename rewrites the `<Area> - <Name>` after the
    /// date in its documents' canonical names (names the user changed are left alone) and
    /// relabels the learnt rules that file as it. A merge (followed to its end when the target is
    /// merged too) re-files the documents under the target, re-points learnt rules, makes evidence
    /// rules accept the target instead, and deletes the kind.
    @discardableResult
    public static func save(db: Database, edits: [KindEdit]) throws -> KindSaveResult {
        guard !edits.isEmpty else { return KindSaveResult() }
        let catalog = try DocumentKindCatalog.load(db: db)
        var changes: [Int64: KindEdit.Change] = [:]
        for edit in edits {
            guard catalog.custom(id: edit.kindId) != nil else { throw Failure.notFound(edit.kindId) }
            changes[edit.kindId] = edit.change
        }

        // The name and area every surviving kind ends with.
        var final: [Int64: (name: String, area: DocumentArea)] = [:]
        for kind in catalog.customKinds {
            guard let id = kind.id else { continue }
            final[id] = (kind.name, kind.area)
        }
        var renamed: [Int64] = []
        for (id, change) in changes.sorted(by: { $0.key < $1.key }) {
            guard case let .rename(name, area) = change else { continue }
            final[id] = (try checkedName(name), area)
            renamed.append(id)
        }

        // Where each merged kind ends up.
        var targets: [Int64: DocumentKindRef] = [:]
        for (id, change) in changes.sorted(by: { $0.key < $1.key }) {
            guard case .merge = change else { continue }
            var seen: Set<Int64> = [id], current = id
            while case let .merge(into) = changes[current] {
                guard case let .custom(next) = into else {
                    targets[id] = into
                    break
                }
                guard catalog.custom(id: next) != nil else { throw Failure.notFound(next) }
                guard seen.insert(next).inserted else { throw Failure.mergeIntoItself }
                current = next
            }
            if targets[id] == nil { targets[id] = .custom(current) }
        }
        for id in targets.keys { final.removeValue(forKey: id) }

        // Renamed names must be free among the kinds that remain and the built-ins.
        for id in renamed where final[id] != nil {
            let name = final[id]!.name
            if let builtIn = builtInNamed(name) { throw Failure.nameTaken(builtIn.displayName) }
            let key = DocumentKindCatalog.key(name)
            if let other = final.first(where: { $0.key != id && DocumentKindCatalog.key($0.value.name) == key }) {
                throw Failure.nameTaken(other.value.name)
            }
        }

        func label(_ ref: DocumentKindRef) -> (name: String, area: String) {
            switch ref {
            case .builtIn(let kind): return (kind.displayName, ImportNaming.area(of: kind))
            case .custom(let id):
                let kind = final[id]!
                return (kind.name, kind.area.libraryArea)
            }
        }
        let renamedSet = Set(renamed.filter { final[$0] != nil })
        let affected = renamedSet.union(targets.keys)
        var result = KindSaveResult()

        // Documents.
        if !affected.isEmpty {
            let documents = try EvidenceDocument.filter(affected.contains(Column("customKindId"))).fetchAll(db)
            for var document in documents {
                guard let id = document.customKindId else { continue }
                let before = document
                let old = (catalog.displayName(.custom(id)), catalog.libraryArea(.custom(id)))
                let target = targets[id] ?? .custom(id)
                switch target {
                case .builtIn(let kind):
                    document.kind = kind
                    document.customKindId = nil
                case .custom(let targetId):
                    document.kind = .other
                    document.customKindId = targetId
                }
                let new = label(target)
                if let name = document.canonicalName, let rewritten = rewrite(name, from: old, to: new) {
                    document.canonicalName = rewritten
                }
                if document != before {
                    try document.update(db)
                    result.documentsChanged += 1
                }
            }
        }

        // Learnt rules.
        for var rule in try ImportRule.filter(Column("kind") == ImportRuleKind.documentKind.rawValue).fetchAll(db) {
            guard let action = ImportLearning.decode(DocumentKindAction.self, rule.actionJSON),
                  let id = action.customKindId, affected.contains(id) else { continue }
            let before = rule
            let target = targets[id] ?? .custom(id)
            let newAction: DocumentKindAction
            switch target {
            case .builtIn(let kind): newAction = DocumentKindAction(kind: kind)
            case .custom(let targetId): newAction = DocumentKindAction(kind: .other, customKindId: targetId)
            }
            if newAction != action, let json = ImportLearning.encode(newAction) { rule.actionJSON = json }
            rule.actionLabel = "Kind: \(label(target).name)"
            if rule != before {
                try rule.update(db)
                result.rulesChanged += 1
            }
        }

        // Evidence rules.
        if !targets.isEmpty {
            for var requirement in try EvidenceRequirement.fetchAll(db) where requirement.customKindIds.contains(where: { targets[$0] != nil }) {
                var customKindIds: [Int64] = [], kinds = requirement.kinds
                for id in requirement.customKindIds {
                    switch targets[id] ?? .custom(id) {
                    case .builtIn(let kind): if !kinds.contains(kind) { kinds.append(kind) }
                    case .custom(let targetId): if !customKindIds.contains(targetId) { customKindIds.append(targetId) }
                    }
                }
                requirement.kinds = kinds
                requirement.customKindIds = customKindIds
                try requirement.update(db)
                result.requirementsChanged += 1
            }
        }

        // The kinds: merged ones go, then renames — through a placeholder name first, so two
        // kinds can swap names and a merged kind's name can be taken.
        for id in targets.keys { _ = try CustomDocumentKind.deleteOne(db, key: id) }
        let renaming = renamed.compactMap { id -> CustomDocumentKind? in
            guard let kind = catalog.custom(id: id), let new = final[id], kind.name != new.name || kind.area != new.area else { return nil }
            return kind
        }
        for var kind in renaming where kind.name != final[kind.id!]!.name {
            kind.name = "\u{1}renaming \(kind.id!)"
            try kind.update(db)
        }
        for var kind in renaming {
            let new = final[kind.id!]!
            kind.name = new.name
            kind.area = new.area
            try kind.update(db)
        }
        return result
    }

    // MARK: Helpers

    private static func checkedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        return trimmed
    }

    private static func builtInNamed(_ name: String) -> DocumentKind? {
        let key = DocumentKindCatalog.key(name)
        return DocumentKind.allCases.first { DocumentKindCatalog.key($0.displayName) == key }
    }

    /// `name` with the `<Area> - <Name>` right after its date replaced, or nil when the name
    /// doesn't have it there (the user named it otherwise).
    static func rewrite(_ name: String, from old: (name: String, area: String), to new: (name: String, area: String)) -> String? {
        guard let dateEnd = name.range(of: " - ") else { return nil }
        let needle = " - \(old.area) - \(old.name)"
        guard let range = name.range(of: needle, options: [.anchored, .caseInsensitive], range: dateEnd.lowerBound..<name.endIndex) else { return nil }
        let rest = name[range.upperBound...]
        guard rest.isEmpty || rest.hasPrefix(" - ") else { return nil }
        return name.replacingCharacters(in: range, with: " - \(new.area) - \(new.name)")
    }
}
