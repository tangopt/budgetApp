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
///
/// A merge reaches every device, including documents filed under the merged kind elsewhere meanwhile:
/// - into a custom kind: the merged kind's record becomes a sync redirect to the target (`SyncMerge.redirect`),
///   so references to it resolve to the target, and a device that still has both re-files its own rows
///   (`absorbIncomingMerge`) before dropping the merged one;
/// - into a built-in kind: there's no record to redirect to, so the merged kind stays as a retired row
///   naming the built-in (`mergedIntoKind`); every device re-files what still names it after each sync
///   apply (`settleRetired`).
/// Re-filing done because of an incoming change is tracked, so documents only one device had reach the others.
public enum CustomDocumentKinds {
    public enum Failure: Error, Equatable, LocalizedError {
        case emptyName
        /// The name of the kind (built-in or custom) that already has it, ignoring case and accents.
        case nameTaken(String)
        case notFound(Int64)
        case mergeIntoItself
        /// The Save would change a filed or paid return: the years ("2024/25") and the documents it re-files.
        case changesFiledYear(years: [String], documents: [String])

        public var errorDescription: String? {
            switch self {
            case .emptyName: return "Give the kind a name."
            case .nameTaken(let name): return "There's already a kind called \u{201C}\(name)\u{201D}."
            case .notFound: return "That kind no longer exists. Close the sheet and open it again."
            case .mergeIntoItself: return "A kind can't be merged into itself."
            case let .changesFiledYear(years, documents):
                let which = years.count == 1 ? "the filed \(years[0]) return" : "the filed \(years.joined(separator: ", ")) returns"
                let named = documents.isEmpty ? "" : " Documents involved: \(documents.joined(separator: "; "))."
                return "Not saved: this would change \(which).\(named)"
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
    /// rules accept the target instead, and removes the kind (see the type's note for sync).
    /// A Save that would move a figure on a filed or paid return (a document re-filed as an
    /// invoice is dated by the invoice) is refused whole with `changesFiledYear`.
    @discardableResult
    public static func save(db: Database, edits: [KindEdit], now: Date = Date()) throws -> KindSaveResult {
        guard !edits.isEmpty else { return KindSaveResult() }
        let plan = try Plan(db: db, edits: edits)
        let baseline = try FiledYearSyncCheck.baseline(db: db)
        var outcome = Outcome()
        var impacts: [FiledYearImpact] = []
        try db.inSavepoint {
            impacts = try FiledYearSyncCheck.impacts(db: db, baseline: baseline) {
                outcome = try write(db: db, plan: plan, now: now)
            }
            return impacts.isEmpty ? .commit : .rollback
        }
        guard impacts.isEmpty else {
            let years = Set(impacts.map(\.startYear)).sorted().map { UKTaxYear(startYear: $0).label }
            throw Failure.changesFiledYear(years: years, documents: outcome.refiled)
        }
        return outcome.result
    }

    // MARK: Sync

    /// An incoming redirect merged custom kind `oldId` into `targetId` while this device had rows of both:
    /// re-files what names `oldId` here under the target (tracked, so documents only this device filed that
    /// way reach the others), then drops `oldId`'s row and identity, leaving the redirect. Inside the sync apply.
    static func absorbIncomingMerge(db: Database, from oldId: Int64, into targetId: Int64, oldUUID: String, targetUUID: String,
                                    deviceUser: String?, now: Date) throws {
        let catalog = try DocumentKindCatalog.load(db: db)
        let oldKind = try CustomDocumentKind.fetchOne(db, key: oldId)
        var plan = Plan(catalog: catalog)
        plan.targets[oldId] = .custom(targetId)
        if let oldKind { plan.old[oldId] = (oldKind.retiredFromName, oldKind.area.libraryArea) }
        _ = try SyncChangeTracker.trackingWrites(db: db) { try repoint(db: db, plan: plan) }
        let zone = try String.fetchOne(db, sql: "SELECT zone FROM syncRecord WHERE uuid = ?", arguments: [oldUUID]) ?? SyncRecordStore.householdZone
        _ = try CustomDocumentKind.deleteOne(db, key: oldId)
        try SyncMerge.retire(uuid: oldUUID, table: CustomDocumentKind.databaseTableName, localId: oldId, zone: zone, deletedBy: deviceUser, now: now, db: db)
        try SyncMerge.redirect(oldUUID, to: targetUUID, table: CustomDocumentKind.databaseTableName, localId: oldId, zone: zone,
                               by: deviceUser, now: now, db: db)
    }

    /// Re-files what still names a retired kind (merged into a built-in) under that built-in: after a sync
    /// apply brought the retirement, or a document or rule filed under the kind elsewhere meanwhile. Tracked.
    @discardableResult
    static func settleRetired(db: Database) throws -> KindSaveResult {
        guard try db.tableExists(CustomDocumentKind.databaseTableName) else { return KindSaveResult() }
        let retired = try CustomDocumentKind.filter(Column("mergedIntoKind") != nil).fetchAll(db)
        guard !retired.isEmpty else { return KindSaveResult() }
        var plan = Plan(catalog: try DocumentKindCatalog.load(db: db))
        for kind in retired {
            guard let id = kind.id, let target = kind.mergedIntoKind else { continue }
            plan.targets[id] = .builtIn(target)
            plan.old[id] = (kind.retiredFromName, kind.area.libraryArea)
        }
        return try SyncChangeTracker.trackingWrites(db: db) { try repoint(db: db, plan: plan).result }
    }

    // MARK: The plan

    /// What a Save does, checked before anything is written.
    struct Plan {
        let catalog: DocumentKindCatalog
        /// The name and area every remaining custom kind ends with.
        var final: [Int64: (name: String, area: DocumentArea)] = [:]
        /// The name and library area each affected kind has now (what canonical names say).
        var old: [Int64: (name: String, area: String)] = [:]
        /// Renamed kinds (those whose name or area changes).
        var renamed: [Int64] = []
        /// Where each merged kind ends up.
        var targets: [Int64: DocumentKindRef] = [:]

        init(catalog: DocumentKindCatalog) {
            self.catalog = catalog
            for kind in catalog.customKinds {
                guard let id = kind.id else { continue }
                final[id] = (kind.name, kind.area)
                old[id] = (kind.name, kind.area.libraryArea)
            }
        }

        init(db: Database, edits: [KindEdit]) throws {
            self.init(catalog: try DocumentKindCatalog.load(db: db))
            var changes: [Int64: KindEdit.Change] = [:]
            for edit in edits {
                guard catalog.custom(id: edit.kindId) != nil else { throw Failure.notFound(edit.kindId) }
                changes[edit.kindId] = edit.change
            }
            for (id, change) in changes.sorted(by: { $0.key < $1.key }) {
                guard case let .rename(name, area) = change else { continue }
                final[id] = (try checkedName(name), area)
                renamed.append(id)
            }
            for (id, change) in changes.sorted(by: { $0.key < $1.key }) {
                guard case .merge = change else { continue }
                var seen: Set<Int64> = [id], current = id
                var target: DocumentKindRef?
                while case let .merge(into) = changes[current] {
                    guard case let .custom(next) = into else {
                        target = into
                        break
                    }
                    guard catalog.custom(id: next) != nil else { throw Failure.notFound(next) }
                    guard seen.insert(next).inserted else { throw Failure.mergeIntoItself }
                    current = next
                }
                targets[id] = target ?? .custom(current)
            }
            for id in targets.keys { final.removeValue(forKey: id) }
            renamed = renamed.filter { final[$0] != nil }
            // Renamed names must be free among the kinds that remain and the built-ins.
            for id in renamed {
                guard let name = final[id]?.name else { continue }
                if let builtIn = builtInNamed(name) { throw Failure.nameTaken(builtIn.displayName) }
                let key = DocumentKindCatalog.key(name)
                if let other = final.first(where: { $0.key != id && DocumentKindCatalog.key($0.value.name) == key }) {
                    throw Failure.nameTaken(other.value.name)
                }
            }
        }

        /// The kind a document of `id` ends as.
        func target(of id: Int64) -> DocumentKindRef { targets[id] ?? .custom(id) }

        /// What canonical names and rule labels call `ref` after the Save: its name, its area, and the type
        /// word a canonical name uses (Other documents are named "Other - Document", as imports name them).
        func label(_ ref: DocumentKindRef) -> (name: String, area: String, type: String) {
            switch ref {
            case .builtIn(let kind):
                return (kind.displayName, ImportNaming.area(of: kind), kind == .other ? "Document" : kind.displayName)
            case .custom(let id):
                if let kind = final[id] { return (kind.name, kind.area.libraryArea, kind.name) }
                return (catalog.displayName(ref), catalog.libraryArea(ref), catalog.displayName(ref))
            }
        }

        /// Kinds whose documents and rules change.
        var affected: Set<Int64> { Set(renamed).union(targets.keys) }
    }

    struct Outcome {
        var result = KindSaveResult()
        /// The documents re-filed under another kind, by name.
        var refiled: [String] = []
    }

    // MARK: Writing

    private static func write(db: Database, plan: Plan, now: Date) throws -> Outcome {
        let outcome = try repoint(db: db, plan: plan)
        let table = CustomDocumentKind.databaseTableName
        // The kinds: merged ones go (a redirect for a custom target, a retired row for a built-in one), then
        // renames, through a placeholder name first so two kinds can swap names and a merged kind's name
        // can be taken.
        for (id, target) in plan.targets.sorted(by: { $0.key < $1.key }) {
            guard var kind = try CustomDocumentKind.fetchOne(db, key: id) else { continue }
            switch target {
            case .custom(let targetId):
                let oldUUID = try SyncRecordStore.existingUUID(table: table, localId: id, db: db)
                let record = try oldUUID.flatMap { try Row.fetchOne(db, sql: "SELECT zone, systemFields FROM syncRecord WHERE uuid = ?", arguments: [$0]) }
                _ = try CustomDocumentKind.deleteOne(db, key: id)
                if let oldUUID, let targetUUID = try SyncRecordStore.existingUUID(table: table, localId: targetId, db: db) {
                    // The server's version of the merged kind is replaced by the redirect.
                    try SyncMerge.redirect(oldUUID, to: targetUUID, table: table, localId: id, zone: record?["zone"] ?? SyncRecordStore.householdZone,
                                           by: nil, now: now, systemFields: record?["systemFields"], db: db)
                    // Sent as the redirect rather than a delete (`SyncTranslator.outgoing`).
                    try SyncMerge.queue(uuid: oldUUID, table: table, localId: id, kind: .update, db: db)
                }
            case .builtIn(let builtIn):
                kind.name = "\(kind.name)\(CustomDocumentKind.retiredMarker)\(UUID().uuidString)"
                kind.mergedIntoKind = builtIn
                try kind.update(db)
            }
        }
        let renaming = try plan.renamed.compactMap { id -> CustomDocumentKind? in
            guard let kind = try CustomDocumentKind.fetchOne(db, key: id), let new = plan.final[id],
                  kind.name != new.name || kind.area != new.area else { return nil }
            return kind
        }
        for var kind in renaming {
            guard let id = kind.id, kind.name != plan.final[id]?.name else { continue }
            kind.name = "\(CustomDocumentKind.retiredMarker)renaming \(id)"
            try kind.update(db)
        }
        for var kind in renaming {
            guard let id = kind.id, let new = plan.final[id] else { continue }
            kind.name = new.name
            kind.area = new.area
            try kind.update(db)
        }
        return outcome
    }

    /// Re-files documents, learnt rules and evidence rules as `plan` says (the kinds themselves aren't touched).
    private static func repoint(db: Database, plan: Plan) throws -> Outcome {
        let affected = plan.affected
        var outcome = Outcome()
        guard !affected.isEmpty else { return outcome }

        // Documents.
        for var document in try EvidenceDocument.filter(affected.contains(Column("customKindId"))).fetchAll(db) {
            guard let id = document.customKindId else { continue }
            let before = document
            let target = plan.target(of: id)
            switch target {
            case .builtIn(let kind):
                document.kind = kind
                document.customKindId = nil
            case .custom(let targetId):
                document.kind = .other
                document.customKindId = targetId
            }
            let new = plan.label(target)
            if let old = plan.old[id], let name = document.canonicalName,
               let rewritten = rewrite(name, from: (old.name, old.area), to: (new.type, new.area)) {
                document.canonicalName = rewritten
            }
            if document != before {
                try document.update(db)
                outcome.result.documentsChanged += 1
                if document.kindRef != before.kindRef { outcome.refiled.append(document.displayName) }
            }
        }

        // Learnt rules.
        for var rule in try ImportRule.filter(Column("kind") == ImportRuleKind.documentKind.rawValue).fetchAll(db) {
            guard let action = ImportLearning.decode(DocumentKindAction.self, rule.actionJSON),
                  let id = action.customKindId, affected.contains(id) else { continue }
            let before = rule
            let target = plan.target(of: id)
            let newAction: DocumentKindAction
            switch target {
            case .builtIn(let kind): newAction = DocumentKindAction(kind: kind)
            case .custom(let targetId): newAction = DocumentKindAction(kind: .other, customKindId: targetId)
            }
            if newAction != action, let json = ImportLearning.encode(newAction) { rule.actionJSON = json }
            rule.actionLabel = "Kind: \(plan.label(target).name)"
            if rule != before {
                try rule.update(db)
                outcome.result.rulesChanged += 1
            }
        }

        // Evidence rules.
        guard !plan.targets.isEmpty else { return outcome }
        for var requirement in try EvidenceRequirement.fetchAll(db) where requirement.customKindIds.contains(where: { plan.targets[$0] != nil }) {
            var customKindIds: [Int64] = [], kinds = requirement.kinds
            for id in requirement.customKindIds {
                switch plan.target(of: id) {
                case .builtIn(let kind): if !kinds.contains(kind) { kinds.append(kind) }
                case .custom(let targetId): if !customKindIds.contains(targetId) { customKindIds.append(targetId) }
                }
            }
            requirement.kinds = kinds
            requirement.customKindIds = customKindIds
            try requirement.update(db)
            outcome.result.requirementsChanged += 1
        }
        return outcome
    }

    // MARK: Helpers

    private static func checkedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        guard !trimmed.contains(CustomDocumentKind.retiredMarker) else { throw Failure.emptyName }
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
