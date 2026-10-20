import Foundation
import GRDB

/// What a learnt import rule is about. Plan 3 adds more kinds.
public enum ImportRuleKind: String, Codable, CaseIterable, Sendable {
    case statementAccount
}

/// Something the app learnt from a confirmed import, so the next one needs one decision fewer.
public struct ImportRule: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var kind: ImportRuleKind
    public var matchKey: String
    /// Shown: "CSV with columns Date, Description, Amount".
    public var matchLabel: String
    public var actionJSON: String
    /// Shown: "Account: Everyday Current".
    public var actionLabel: String
    public var isEnabled: Bool
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(id: Int64? = nil, kind: ImportRuleKind, matchKey: String, matchLabel: String, actionJSON: String,
                actionLabel: String, isEnabled: Bool = true, createdAt: Date, lastUsedAt: Date? = nil, useCount: Int = 0) {
        self.id = id
        self.kind = kind
        self.matchKey = matchKey
        self.matchLabel = matchLabel
        self.actionJSON = actionJSON
        self.actionLabel = actionLabel
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let databaseTableName = "importRule"
}

/// The account chosen for a statement file signature.
public struct StatementAccountAction: Codable, Equatable, Sendable {
    public var accountId: Int64

    public init(accountId: Int64) { self.accountId = accountId }
}

public enum ImportRuleStore {
    /// The enabled rule for `kind` and `key`, if any.
    public static func rule(db: Database, kind: ImportRuleKind, key: String) throws -> ImportRule? {
        try ImportRule
            .filter(Column("kind") == kind.rawValue && Column("matchKey") == key && Column("isEnabled") == true)
            .fetchOne(db)
    }

    /// Saves the choice for `kind` and `key`: one row per pair, replaced and re-enabled when it exists.
    @discardableResult
    public static func learn(db: Database, kind: ImportRuleKind, key: String, matchLabel: String,
                             action: some Encodable, actionLabel: String, now: Date) throws -> ImportRule {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(action), as: UTF8.self)
        if var existing = try ImportRule
            .filter(Column("kind") == kind.rawValue && Column("matchKey") == key).fetchOne(db) {
            existing.matchLabel = matchLabel
            existing.actionJSON = json
            existing.actionLabel = actionLabel
            existing.isEnabled = true
            try existing.update(db)
            return existing
        }
        var rule = ImportRule(kind: kind, matchKey: key, matchLabel: matchLabel, actionJSON: json,
                              actionLabel: actionLabel, createdAt: now)
        try rule.insert(db)
        return rule
    }

    public static func markUsed(db: Database, ids: [Int64], now: Date) throws {
        for id in Set(ids) {
            guard var rule = try ImportRule.fetchOne(db, key: id) else { continue }
            rule.useCount += 1
            rule.lastUsedAt = now
            try rule.update(db)
        }
    }

    public static func all(db: Database) throws -> [ImportRule] {
        try ImportRule.order(Column("createdAt"), Column("id")).fetchAll(db)
    }
}

/// Identifies "the same kind of statement file" across downloads, so the account chosen once is remembered.
public enum StatementSignature {
    /// CSV: the header row. PDF: the first two lines, digits removed. BBVA: the current account's digits
    /// (read with `BBVAStatementParser`, as the BBVA reader does). Nil when the file can't be told apart.
    public static func key(for file: ImportFile, kind: ImportKind) -> (key: String, label: String)? {
        guard let text = file.text else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch kind {
        case .bankStatementCSV:
            guard let header = lines.first else { return nil }
            let cells = header.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\""))) }
            let key = "csv:" + cells.map { $0.lowercased() }.joined(separator: "|")
            return (key, "CSV with columns " + cells.joined(separator: ", "))
        case .bankStatementPDF:
            // Lines that are empty once digits are removed carry no identity; skip them.
            let meaningful: [(original: String, normalised: String)] = lines.compactMap { line in
                let normalised = String(line.unicodeScalars.filter { !CharacterSet.decimalDigits.contains($0) }.map(Character.init))
                    .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return normalised.isEmpty ? nil : (line, normalised)
            }
            guard let first = meaningful.first else { return nil }
            return ("pdf:" + meaningful.prefix(2).map(\.normalised).joined(separator: "|"), "PDF starting “" + first.original + "”")
        case .bbvaStatement:
            guard let account = (try? BBVAStatementParser.parse(text))?.currentAccount else { return nil }
            let digits = account.filter(\.isNumber)
            guard !digits.isEmpty else { return nil }
            return ("bbva:" + digits, "BBVA statement of account …" + digits.suffix(4))
        default:
            return nil
        }
    }
}

func registerImportRuleMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createImportRule") { db in
        try db.create(table: "importRule") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("kind", .text).notNull()
            t.column("matchKey", .text).notNull()
            t.column("matchLabel", .text).notNull()
            t.column("actionJSON", .text).notNull()
            t.column("actionLabel", .text).notNull()
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("createdAt", .datetime).notNull()
            t.column("lastUsedAt", .datetime)
            t.column("useCount", .integer).notNull().defaults(to: 0)
            t.uniqueKey(["kind", "matchKey"])
        }
    }
}
