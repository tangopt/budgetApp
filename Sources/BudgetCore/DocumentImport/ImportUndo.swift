import GRDB
import Foundation

/// Why an import run can't be undone as it stands.
public enum ImportUndoConflict: Equatable, Sendable {
    /// A row the run wrote was edited since (the columns whose value is no longer what the run left).
    case changedSince(table: String, rowId: Int64, columns: [String])
    /// A row the run wrote was deleted since.
    case removedSince(table: String, rowId: Int64)
    /// A row the run deleted exists again.
    case recreatedSince(table: String, rowId: Int64)
    /// A later run, not undone, wrote the same row: undo that one first.
    case laterImport(runId: Int64, table: String, rowId: Int64)
    /// A row the run didn't add points at a row it added (`dependent` is `"<table> <rowid>"`).
    case dependsOnIt(table: String, rowId: Int64, dependent: String)
    /// Undoing would change a figure of a filed (or paid) return.
    case filedYear(FiledYearImpact)

    public var message: String {
        switch self {
        case .changedSince(let table, let rowId, let columns):
            let names = columns.map(ImportUndo.columnLabel).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return "\(ImportUndo.tableLabel(table)) \(rowId) was changed since (\(names.joined(separator: ", ")))"
        case .removedSince(let table, let rowId):
            return "\(ImportUndo.tableLabel(table)) \(rowId) was removed since"
        case .recreatedSince(let table, let rowId):
            return "\(ImportUndo.tableLabel(table)) \(rowId) was added again since"
        case .laterImport(let runId, let table, let rowId):
            return "\(ImportUndo.tableLabel(table)) \(rowId) was changed by a later import (\(runId)); undo that one first"
        case .dependsOnIt(let table, let rowId, let dependent):
            let parts = dependent.split(separator: " ", maxSplits: 1).map(String.init)
            let other = parts.count == 2 ? "\(ImportUndo.tableLabel(parts[0])) \(parts[1])" : dependent
            return "\(other) depends on \(ImportUndo.tableLabel(table)) \(rowId)"
        case .filedYear(let impact):
            return impact.headline
        }
    }
}

public enum ImportUndoError: Error, Equatable {
    case refused([ImportUndoConflict])
    case alreadyUndone
    case runNotFound
}

public struct ImportUndoResult: Equatable, Sendable {
    public var rowsRemoved: Int
    public var rowsRestored: Int
    public var filesRemoved: Int
    /// What the undo left as it is, and why (a learnt rule changed since the run).
    public var notes: [String]

    public init(rowsRemoved: Int, rowsRestored: Int, filesRemoved: Int, notes: [String] = []) {
        self.rowsRemoved = rowsRemoved
        self.rowsRestored = rowsRestored
        self.filesRemoved = filesRemoved
        self.notes = notes
    }
}

/// Reverts everything an import run wrote, from its change log (`ImportChange`), in one write —
/// or refuses, writing nothing, when something changed since that undoing would overwrite or
/// break, or when it would move a filed return. Learnt import rules (`importRule`) are lenient:
/// what happened to them since (a later run used one, the Rules page edited or deleted one)
/// never refuses the undo; a rule is put back only while it is as the run left it (being used
/// since is not a change), else
/// it is left as it is and the result says so (`notes`) — its use count given back regardless,
/// as far as it goes.
public enum ImportUndo {
    private struct RowKey: Hashable {
        let table: String
        let rowId: Int64
    }

    // MARK: Netting

    /// One change per (table, rowid): the first `beforeJSON` and the last `afterJSON`, as an
    /// insert (nothing before), update (both) or delete (nothing after); a row the run added and
    /// removed again drops out. Ordered by the last change's `seq`.
    static func netChanges(_ changes: [ImportChange]) -> [ImportChange] {
        var order: [RowKey] = []
        var groups: [RowKey: [ImportChange]] = [:]
        for change in changes.sorted(by: { $0.seq < $1.seq }) {
            let key = RowKey(table: change.tableName, rowId: change.rowId)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(change)
        }
        let net: [ImportChange] = order.compactMap { key in
            let group = groups[key]!
            let first = group.first!, last = group.last!
            let before = first.beforeJSON, after = last.afterJSON
            let operation: ImportChangeOperation
            switch (before, after) {
            case (nil, nil): return nil
            case (nil, _): operation = .insert
            case (_, nil): operation = .delete
            default: operation = .update
            }
            return ImportChange(id: last.id, runId: first.runId, seq: last.seq, tableName: key.table, rowId: key.rowId,
                                operation: operation, beforeJSON: before, afterJSON: after)
        }
        return net.sorted { $0.seq < $1.seq }
    }

    private static func netChanges(db: Database, runId: Int64) throws -> [ImportChange] {
        netChanges(try ImportChange.filter(Column("runId") == runId).order(Column("seq")).fetchAll(db))
    }

    // MARK: Conflicts

    /// Why the run can't be undone now; empty when it can. Row conflicts come first; the filed
    /// year check (which reverts in a savepoint that is rolled back, so `db` must be writable)
    /// runs only when there are none, since reverting over conflicting rows may not be possible.
    public static func conflicts(db: Database, runId: Int64) throws -> [ImportUndoConflict] {
        try conflicts(db: db, runId: runId, net: netChanges(db: db, runId: runId))
    }

    /// `conflicts(db:runId:)` in a write transaction that is always rolled back.
    public static func conflicts(dbQueue: DatabaseQueue, runId: Int64) throws -> [ImportUndoConflict] {
        var found: [ImportUndoConflict] = []
        try dbQueue.inTransaction { db in
            found = try conflicts(db: db, runId: runId)
            return .rollback
        }
        return found
    }

    private static func conflicts(db: Database, runId: Int64, net: [ImportChange]) throws -> [ImportUndoConflict] {
        var found: [ImportUndoConflict] = []
        let later = try laterTouches(db: db, runId: runId)
        for change in net {
            let key = RowKey(table: change.tableName, rowId: change.rowId)
            // Learnt rules never refuse an undo (`revertRule`).
            if key.table == ImportRule.databaseTableName { continue }
            if let laterRun = later[key] {
                found.append(.laterImport(runId: laterRun, table: key.table, rowId: key.rowId))
                continue
            }
            let current = try ImportChangeCapture.rowJSON(db: db, table: key.table, rowId: key.rowId)
            switch change.operation {
            case .insert:
                guard let current else { found.append(.removedSince(table: key.table, rowId: key.rowId)); continue }
                guard current != change.afterJSON else { continue }
                let now = try values(db: db, current, table: key.table), after = try values(db: db, change.afterJSON, table: key.table)
                // Only what the run left: a column added since (a later migration) isn't a change.
                let columns = try columnNames(db: db, key.table).filter { after[$0] != nil && now[$0] != after[$0] }
                if !columns.isEmpty { found.append(.changedSince(table: key.table, rowId: key.rowId, columns: columns)) }
            case .update:
                guard let current else { found.append(.removedSince(table: key.table, rowId: key.rowId)); continue }
                let now = try values(db: db, current, table: key.table)
                let before = try values(db: db, change.beforeJSON, table: key.table)
                let after = try values(db: db, change.afterJSON, table: key.table)
                let columns = try columnNames(db: db, key.table).filter { after[$0] != nil && before[$0] != after[$0] && now[$0] != after[$0] }
                if !columns.isEmpty { found.append(.changedSince(table: key.table, rowId: key.rowId, columns: columns)) }
            case .delete:
                if current != nil { found.append(.recreatedSince(table: key.table, rowId: key.rowId)) }
            }
        }
        let foreignKeys = try userForeignKeys(db: db)
        found += try dependents(db: db, net: net, foreignKeys: foreignKeys)
        found += try missingReferences(db: db, net: net, foreignKeys: foreignKeys)
        var unique: [ImportUndoConflict] = []
        for conflict in found where !unique.contains(conflict) { unique.append(conflict) }
        guard unique.isEmpty else { return unique }
        return try filedYearConflicts(db: db, runId: runId, net: net)
    }

    /// For each row a later, not-undone run wrote: the earliest such run.
    private static func laterTouches(db: Database, runId: Int64) throws -> [RowKey: Int64] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.tableName, c.rowId, MIN(c.runId) FROM importChange c JOIN importRun r ON r.id = c.runId
            WHERE c.runId > ? AND r.undoneAt IS NULL GROUP BY c.tableName, c.rowId
            """, arguments: [runId])
        var result: [RowKey: Int64] = [:]
        for row in rows { result[RowKey(table: row[0], rowId: row[1])] = row[2] }
        return result
    }

    /// Rows outside the run's net inserts that point at a row it inserted: by a declared foreign
    /// key, or by `entityType` / `entityId` (a document link, an evidence waiver). A row the run
    /// updated counts unless the undo restores all of its pointing columns.
    private static func dependents(db: Database, net: [ImportChange], foreignKeys allKeys: [ForeignKey]) throws -> [ImportUndoConflict] {
        let inserted = net.filter { $0.operation == .insert }
        guard !inserted.isEmpty else { return [] }
        let insertedKeys = Set(inserted.map { RowKey(table: $0.tableName, rowId: $0.rowId) })
        var updatedColumns: [RowKey: Set<String>] = [:]
        for change in net where change.operation == .update {
            let before = try values(db: db, change.beforeJSON, table: change.tableName)
            let after = try values(db: db, change.afterJSON, table: change.tableName)
            updatedColumns[RowKey(table: change.tableName, rowId: change.rowId)] = Set(before.keys.filter { before[$0] != after[$0] })
        }
        func isDependent(_ key: RowKey, via columns: [String]) -> Bool {
            if insertedKeys.contains(key) { return false }
            if let restored = updatedColumns[key], Set(columns).isSubset(of: restored) { return false }
            return true
        }

        let foreignKeys = Dictionary(grouping: allKeys) { $0.parent.lowercased() }
        let entityTypes = Dictionary(uniqueKeysWithValues: entityTables.map { ($0.value.lowercased(), $0.key) })
        let pointing = try entityPointingTables(db: db)

        var found: [ImportUndoConflict] = []
        for change in inserted {
            let parent = change.tableName
            guard try ImportChangeCapture.rowJSON(db: db, table: parent, rowId: change.rowId) != nil else { continue }
            for fk in foreignKeys[parent.lowercased()] ?? [] {
                let selected = fk.destination.map(quoted).joined(separator: ", ")
                guard let parentRow = try Row.fetchOne(db, sql: "SELECT \(selected) FROM \(quoted(parent)) WHERE rowid = ?",
                                                       arguments: [change.rowId]) else { continue }
                let condition = fk.origin.map { "\(quoted($0)) = ?" }.joined(separator: " AND ")
                let arguments = StatementArguments(fk.destination.indices.map { parentRow[$0] as DatabaseValue })
                let children = try Int64.fetchAll(db, sql: "SELECT rowid FROM \(quoted(fk.child)) WHERE \(condition) ORDER BY rowid",
                                                  arguments: arguments)
                for childId in children where isDependent(RowKey(table: fk.child, rowId: childId), via: fk.origin) {
                    found.append(.dependsOnIt(table: parent, rowId: change.rowId, dependent: "\(fk.child) \(childId)"))
                }
            }
            if let type = entityTypes[parent.lowercased()] {
                for table in pointing {
                    let rows = try Int64.fetchAll(db, sql: "SELECT rowid FROM \(quoted(table)) WHERE entityType = ? AND entityId = ? ORDER BY rowid",
                                                  arguments: [type.rawValue, change.rowId])
                    for rowId in rows where isDependent(RowKey(table: table, rowId: rowId), via: ["entityType", "entityId"]) {
                        found.append(.dependsOnIt(table: parent, rowId: change.rowId, dependent: "\(table) \(rowId)"))
                    }
                }
            }
        }
        return found
    }

    /// The user tables pointing at a record by `entityType` and `entityId` (document links,
    /// evidence waivers), the document links first.
    private static func entityPointingTables(db: Database) throws -> [String] {
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .filter { !bookkeepingTables.contains($0) }
        let pointing = try tables.filter { table in
            let columns = Set(try db.columns(in: table).map(\.name))
            return columns.contains("entityType") && columns.contains("entityId")
        }
        return pointing.sorted { ($0 == DocumentLink.databaseTableName ? 0 : 1, $0) < ($1 == DocumentLink.databaseTableName ? 0 : 1, $1) }
    }

    private struct ForeignKey {
        let child: String
        let parent: String
        let origin: [String]
        let destination: [String]
    }

    /// Tables that hold no user data and are never pointed at by it.
    static let bookkeepingTables: Set<String> = ["grdb_migrations", "importRun", "importChange", "importRunFile"]

    /// The declared foreign keys of every user table — tracked or not (an untracked forecast row
    /// pointing at an imported category must block the undo, not be cascaded or nulled).
    private static func userForeignKeys(db: Database) throws -> [ForeignKey] {
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .filter { !bookkeepingTables.contains($0) }
        return try tables.flatMap { child in
            try db.foreignKeys(on: child).map {
                ForeignKey(child: child, parent: $0.destinationTable, origin: $0.mapping.map(\.origin), destination: $0.mapping.map(\.destination))
            }
        }
    }

    /// Rows the undo restores (re-inserted, or columns put back) that would point at a row that
    /// is gone since — by a declared foreign key or a document link — unless this same undo
    /// re-inserts it. Each missing row is reported as `removedSince`.
    private static func missingReferences(db: Database, net: [ImportChange], foreignKeys: [ForeignKey]) throws -> [ImportUndoConflict] {
        var reinserted: [String: [[String: DatabaseValue]]] = [:]
        for change in net where change.operation == .delete {
            var row = try values(db: db, change.beforeJSON, table: change.tableName)
            row["rowid"] = change.rowId.databaseValue
            reinserted[change.tableName.lowercased(), default: []].append(row)
        }
        let byChild = Dictionary(grouping: foreignKeys) { $0.child.lowercased() }
        var found: [ImportUndoConflict] = []
        for change in net where change.operation != .insert {
            let before = try values(db: db, change.beforeJSON, table: change.tableName)
            let restored: Set<String>
            if change.operation == .delete {
                restored = Set(before.keys)
            } else {
                let after = try values(db: db, change.afterJSON, table: change.tableName)
                restored = Set(before.keys.filter { before[$0] != after[$0] })
            }
            for fk in byChild[change.tableName.lowercased()] ?? [] where !restored.isDisjoint(with: fk.origin) {
                let wanted = fk.origin.map { before[$0] ?? .null }
                guard !wanted.contains(where: \.isNull) else { continue }
                let condition = fk.destination.map { "\(quoted($0)) = ?" }.joined(separator: " AND ")
                let present = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(quoted(fk.parent)) WHERE \(condition))",
                                                arguments: StatementArguments(wanted)) ?? false
                let comesBack = (reinserted[fk.parent.lowercased()] ?? []).contains { row in
                    zip(fk.destination, wanted).allSatisfy { row[$0.0] == $0.1 }
                }
                if !present && !comesBack {
                    found.append(.removedSince(table: fk.parent, rowId: Int64.fromDatabaseValue(wanted[0]) ?? 0))
                }
            }
            if change.tableName == DocumentLink.databaseTableName,
               change.operation == .delete || !restored.isDisjoint(with: ["entityType", "entityId"]),
               let rawType = String.fromDatabaseValue(before["entityType"] ?? .null),
               let type = EvidenceEntityType(rawValue: rawType),
               let entityId = Int64.fromDatabaseValue(before["entityId"] ?? .null),
               let table = entityTables[type] {
                let present = try EvidenceLinks.entityExists(db: db, EvidenceEntity(type: type, id: entityId))
                let comesBack = (reinserted[table.lowercased()] ?? []).contains { $0["rowid"] == entityId.databaseValue }
                if !present && !comesBack { found.append(.removedSince(table: table, rowId: entityId)) }
            }
        }
        return found
    }

    /// The table of each entity type a document can link to (as `EvidenceLinks.entityExists`).
    static let entityTables: [EvidenceEntityType: String] = [
        .transaction: Transaction.databaseTableName, .account: Account.databaseTableName, .category: Category.databaseTableName,
        .property: Property.databaseTableName, .person: Person.databaseTableName, .tenancy: Tenancy.databaseTableName,
        .rentReceipt: RentReceipt.databaseTableName, .taxYear: TaxYear.databaseTableName,
        .taxManualItem: TaxManualItem.databaseTableName, .employment: Employment.databaseTableName,
        .employmentIncome: EmploymentIncome.databaseTableName, .hmrcPayment: HMRCPayment.databaseTableName,
        .otherIncome: OtherIncome.databaseTableName, .pensionContribution: PensionContribution.databaseTableName,
        .taxPolicyReceipt: TaxPolicyReceipt.databaseTableName,
    ]

    /// Reverts the run in a savepoint that is rolled back, and reports each filed or paid year
    /// whose return figures would move.
    private static func filedYearConflicts(db: Database, runId: Int64, net: [ImportChange]) throws -> [ImportUndoConflict] {
        let closedYears = try TaxYear.filter([TaxYearStatus.filed.rawValue, TaxYearStatus.paid.rawValue].contains(Column("status"))).fetchCount(db)
        guard closedYears > 0, !net.isEmpty else { return [] }
        let summary = try ImportRun.fetchOne(db, key: runId)?.summary
        var impacts: [FiledYearImpact] = []
        try db.inSavepoint {
            let before = try TaxFigures.snapshot(db: db)
            _ = try revert(db: db, net: net)
            let after = try TaxFigures.snapshot(db: db, years: before.values.keys.map(\.startYear))
            impacts = FiledYearImpact.impacts(before: before, after: after, causes: ["Undo import: \(summary ?? String(runId))"])
            return .rollback
        }
        return impacts.map(ImportUndoConflict.filedYear)
    }

    // MARK: Undo

    /// Reverts the run in one write (or refuses), refreshes the auto forecast, then removes the
    /// stored copies of the documents it removed that no other document has.
    public static func undo(dbQueue: DatabaseQueue, library: EvidenceLibrary, runId: Int64, now: Date = Date()) throws -> ImportUndoResult {
        let (outcome, rowsRemoved, rowsRestored) = try dbQueue.write { db -> (Reverted, Int, Int) in
            guard var run = try ImportRun.fetchOne(db, key: runId) else { throw ImportUndoError.runNotFound }
            guard run.undoneAt == nil else { throw ImportUndoError.alreadyUndone }
            let net = try netChanges(db: db, runId: runId)
            let found = try conflicts(db: db, runId: runId, net: net)
            guard found.isEmpty else { throw ImportUndoError.refused(found) }
            let outcome = try revert(db: db, net: net)
            run.undoneAt = now
            run.undoSummary = (["Removed \(outcome.removed) row\(outcome.removed == 1 ? "" : "s"), restored \(outcome.restored)"] + outcome.notes)
                .joined(separator: ". ")
            try run.update(db)
            // The auto forecast reads every transaction: refreshed as after any import.
            try AutoForecastGenerator.refresh(db: db)
            return (outcome, outcome.removed, outcome.restored)
        }
        var filesRemoved = 0
        let stillStored = try dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT sha256 FROM document"))
        }
        let fileManager = FileManager.default
        for document in outcome.removedDocuments where !stillStored.contains(document.sha256) {
            let url = library.fileURL(for: document)
            if fileManager.fileExists(atPath: url.path), (try? fileManager.removeItem(at: url)) != nil { filesRemoved += 1 }
        }
        return ImportUndoResult(rowsRemoved: rowsRemoved, rowsRestored: rowsRestored, filesRemoved: filesRemoved, notes: outcome.notes)
    }

    private struct Reverted {
        var removed = 0
        var restored = 0
        var removedDocuments: [EvidenceDocument] = []
        var notes: [String] = []
    }

    /// Walks the net changes newest first: deletes inserted rows, puts updated columns back to
    /// their values before the run, re-inserts deleted rows with their rowid. Foreign keys are
    /// checked at commit, so a parent and its cascaded children come back in any order.
    private static func revert(db: Database, net: [ImportChange]) throws -> Reverted {
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        var outcome = Reverted()
        for change in net.sorted(by: { $0.seq > $1.seq }) {
            let table = quoted(change.tableName)
            if change.tableName == ImportRule.databaseTableName {
                if change.operation != .delete {
                    try revertRule(db: db, change, into: &outcome)
                    continue
                }
                // A rule the run removed that exists again: left as it is.
                if try ImportChangeCapture.rowJSON(db: db, table: change.tableName, rowId: change.rowId) != nil { continue }
            }
            switch change.operation {
            case .insert:
                if change.tableName == EvidenceDocument.databaseTableName, let document = try EvidenceDocument.fetchOne(db, key: change.rowId) {
                    outcome.removedDocuments.append(document)
                }
                try db.execute(sql: "DELETE FROM \(table) WHERE rowid = ?", arguments: [change.rowId])
                if db.changesCount > 0 { outcome.removed += 1 }
            case .update:
                let before = try values(db: db, change.beforeJSON, table: change.tableName)
                let after = try values(db: db, change.afterJSON, table: change.tableName)
                let columns = try columnNames(db: db, change.tableName).filter { before[$0] != after[$0] }
                guard !columns.isEmpty else { continue }
                let assignments = columns.map { "\(quoted($0)) = ?" }.joined(separator: ", ")
                var arguments = StatementArguments(columns.map { before[$0] ?? .null })
                arguments += [change.rowId]
                try db.execute(sql: "UPDATE \(table) SET \(assignments) WHERE rowid = ?", arguments: arguments)
                outcome.restored += 1
            case .delete:
                let before = try values(db: db, change.beforeJSON, table: change.tableName)
                let columns = try columnNames(db: db, change.tableName).filter { before[$0] != nil }
                var names = columns.map(quoted)
                var arguments = StatementArguments(columns.map { before[$0]! })
                if try db.primaryKey(change.tableName).rowIDColumn == nil {
                    names.insert("rowid", at: 0)
                    arguments = StatementArguments([change.rowId]) + arguments
                }
                let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
                try db.execute(sql: "INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(placeholders))", arguments: arguments)
                outcome.restored += 1
            }
        }
        return outcome
    }

    /// The columns a learnt rule's use changes (`ImportRuleStore.markUsed`).
    private static let ruleUseColumns: Set<String> = ["useCount", "lastUsedAt"]

    /// Who taught a learnt rule: not part of what it does, so a later re-learn that only changes
    /// them doesn't make the rule "changed since".
    private static let ruleAttributionColumns: Set<String> = ["createdByAppUserId", "lastLearntByAppUserId"]

    /// A learnt rule the run added or changed, reverted leniently: removed or put back only while
    /// it is as the run left it (its use since — `useCount`, `lastUsedAt` — doesn't count); else
    /// left as it is (gone: nothing to do; changed: noted,
    /// "Kept the learnt rule “<issuer> → <action>”: it changed since this import"), the uses the
    /// run added given back as far as they go (the count never below zero; the last use put back
    /// while it is still the run's).
    private static func revertRule(db: Database, _ change: ImportChange, into outcome: inout Reverted) throws {
        let table = quoted(change.tableName)
        guard let current = try ImportChangeCapture.rowJSON(db: db, table: change.tableName, rowId: change.rowId) else { return }
        let now = try values(db: db, current, table: change.tableName)
        let before = try values(db: db, change.beforeJSON, table: change.tableName)
        let after = try values(db: db, change.afterJSON, table: change.tableName)
        let columns = try columnNames(db: db, change.tableName)
        // Being used since (a later run's `markUsed`) is not a change: only the rule itself counts.
        let unchanged = columns.allSatisfy { ruleUseColumns.contains($0) || ruleAttributionColumns.contains($0) || after[$0] == nil || now[$0] == after[$0] }
        let changedByRun = Set(columns.filter { before[$0] != after[$0] })
        func note() {
            let label = (String.fromDatabaseValue(now["matchLabel"] ?? .null) ?? "?") + " → " + (String.fromDatabaseValue(now["actionLabel"] ?? .null) ?? "?")
            outcome.notes.append("Kept the learnt rule “\(label)”: it changed since this import")
        }
        if change.operation == .insert {
            guard unchanged else { return note() }
            try db.execute(sql: "DELETE FROM \(table) WHERE rowid = ?", arguments: [change.rowId])
            if db.changesCount > 0 { outcome.removed += 1 }
            return
        }
        var restore: [String: DatabaseValue] = [:]
        if unchanged {
            for column in changedByRun.subtracting(ruleUseColumns) { restore[column] = before[column] ?? .null }
        } else if !changedByRun.isSubset(of: ruleUseColumns) {
            note()
        }
        // The run's own uses given back, as far as they go.
        let added = (Int64.fromDatabaseValue(after["useCount"] ?? .null) ?? 0) - (Int64.fromDatabaseValue(before["useCount"] ?? .null) ?? 0)
        if added > 0, let count = Int64.fromDatabaseValue(now["useCount"] ?? .null) {
            restore["useCount"] = max(0, count - added).databaseValue
        }
        if changedByRun.contains("lastUsedAt"), now["lastUsedAt"] == after["lastUsedAt"] {
            restore["lastUsedAt"] = before["lastUsedAt"] ?? .null
        }
        guard !restore.isEmpty else { return }
        let names = restore.keys.sorted()
        var arguments = StatementArguments(names.map { restore[$0]! })
        arguments += [change.rowId]
        try db.execute(sql: "UPDATE \(table) SET \(names.map { "\(quoted($0)) = ?" }.joined(separator: ", ")) WHERE rowid = ?", arguments: arguments)
        outcome.restored += 1
    }

    // MARK: JSON values

    /// The column values of a captured row of `table`, as stored: `json_each` keeps SQLite's
    /// types; BLOB columns were captured as hex and REAL values as 17-digit text
    /// (`ImportChangeCapture`), and are decoded back.
    private static func values(db: Database, _ json: String?, table: String) throws -> [String: DatabaseValue] {
        guard let json else { return [:] }
        let blobs = try ImportChangeCapture.blobColumns(db: db, table: table)
        let reals = try ImportChangeCapture.realColumns(db: db, table: table)
        var result: [String: DatabaseValue] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, value FROM json_each(?)", arguments: [json]) {
            let column: String = row[0]
            var value: DatabaseValue = row[1]
            if case .string(let text) = value.storage {
                if blobs.contains(column) {
                    value = blob(fromHex: text) ?? value
                } else if reals.contains(column), let number = Double(text) {
                    value = number.databaseValue
                }
            }
            result[column] = value
        }
        return result
    }

    private static func columnNames(db: Database, _ table: String) throws -> [String] {
        try db.columns(in: table).map(\.name)
    }

    private static func blob(fromHex hex: String) -> DatabaseValue? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes).databaseValue
    }

    private static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Describing

    /// A row as the user knows it: a transaction as `"<date> <description> <amount>"`, a
    /// document by its canonical name or file name, anything else as `"<Table> <rowid>"`.
    public static func describe(db: Database, table: String, rowId: Int64) throws -> String {
        switch table {
        case Transaction.databaseTableName:
            if let transaction = try Transaction.fetchOne(db, key: rowId) {
                let currency = try Account.fetchOne(db, key: transaction.accountId)?.currency ?? .gbp
                return "\(EvidenceInitialImport.day(transaction.date)) \(transaction.rawDescription) \(Money.format(transaction.amountMinorUnits, currency: currency))"
            }
        case EvidenceDocument.databaseTableName:
            if let document = try EvidenceDocument.fetchOne(db, key: rowId) { return document.displayName }
        default:
            break
        }
        return "\(tableLabel(table)) \(rowId)"
    }

    /// `"transaction_"` → `"Transaction"`, `"documentLink"` → `"Document link"`.
    static func tableLabel(_ table: String) -> String {
        let words = camelWords(table.trimmingCharacters(in: CharacterSet(charactersIn: "_")))
        guard let first = words.first else { return table }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// `"categoryId"` → `"category"`, `"categorizedBy"` → `"categorized by"`.
    static func columnLabel(_ column: String) -> String {
        var name = column
        if name.count > 2, name.hasSuffix("Id") { name.removeLast(2) }
        return camelWords(name).joined(separator: " ")
    }

    private static func camelWords(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in name {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = ""
            }
            if character == "_" {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            current.append(contentsOf: character.lowercased())
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
