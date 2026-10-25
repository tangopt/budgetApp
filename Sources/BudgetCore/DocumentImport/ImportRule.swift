import Foundation
import GRDB

/// What a learnt import rule is about.
public enum ImportRuleKind: String, Codable, CaseIterable, Sendable {
    case statementAccount
    /// Documents from an issuer are of a given kind.
    case documentKind
    /// A name for an issuer.
    case issuer
    /// Documents from an issuer link to a record.
    case link
    /// Where on the page an issuer's figure sits.
    case figurePosition
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
    /// Set on insert, kept on update; nil for the CLI tools and for rules learnt before sign-in existed.
    public var createdByAppUserId: Int64?
    /// Set on insert and on every re-learn.
    public var lastLearntByAppUserId: Int64?

    public init(id: Int64? = nil, kind: ImportRuleKind, matchKey: String, matchLabel: String, actionJSON: String,
                actionLabel: String, isEnabled: Bool = true, createdAt: Date, lastUsedAt: Date? = nil, useCount: Int = 0,
                createdByAppUserId: Int64? = nil, lastLearntByAppUserId: Int64? = nil) {
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
        self.createdByAppUserId = createdByAppUserId
        self.lastLearntByAppUserId = lastLearntByAppUserId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let databaseTableName = "importRule"
}

/// The account chosen for a statement file signature.
public struct StatementAccountAction: Codable, Equatable, Sendable {
    public var accountId: Int64

    public init(accountId: Int64) { self.accountId = accountId }
}

/// The kind chosen for an issuer's documents.
public struct DocumentKindAction: Codable, Equatable, Sendable {
    public var kind: DocumentKind
    /// A custom kind (`customDocumentKind` id), with `kind` `.other`; absent from the JSON when nil,
    /// so rules learnt before custom kinds read the same.
    public var customKindId: Int64?

    public init(kind: DocumentKind, customKindId: Int64? = nil) {
        self.kind = kind
        self.customKindId = customKindId
    }

    /// The kind the rule files documents as.
    public var kindRef: DocumentKindRef {
        customKindId.map(DocumentKindRef.custom) ?? .builtIn(kind)
    }
}

/// The name chosen for an issuer.
public struct IssuerAction: Codable, Equatable, Sendable {
    public var name: String

    public init(name: String) { self.name = name }
}

/// Link to a fixed record (`entity`), or to the transaction whose `MerchantKey.make(description)` equals `descriptionKey`.
public struct LinkAction: Codable, Equatable, Sendable {
    public var entity: EvidenceEntity?
    public var role: String?
    public var descriptionKey: String?

    public init(entity: EvidenceEntity? = nil, role: String? = nil, descriptionKey: String? = nil) {
        self.entity = entity
        self.role = role
        self.descriptionKey = descriptionKey
    }
}

/// Where a figure sits: the label before it and which occurrence of that label.
public struct FigurePositionAction: Codable, Equatable, Sendable {
    public var field: ImportFigureField
    public var label: String
    public var occurrence: Int

    public init(field: ImportFigureField, label: String, occurrence: Int) {
        self.field = field
        self.label = label
        self.occurrence = occurrence
    }
}

/// What a learnt link points at: a fixed record, or the transactions of a merchant. An issuer has
/// at most one link rule of each (`ImportRuleKind.linkKey`), so choosing a payment never replaces
/// where its documents are filed.
public enum ImportLinkFamily: String, CaseIterable, Sendable {
    case record, transaction

    /// The family of a link action: a record when it names one, else a merchant's transactions.
    public static func of(_ action: LinkAction) -> ImportLinkFamily { action.entity == nil ? .transaction : .record }

    /// The family of a link to `entity`.
    public static func of(_ entity: EvidenceEntity) -> ImportLinkFamily { entity.type == .transaction ? .transaction : .record }
}

extension ImportRuleKind {
    /// The match key for a `documentKind` or `issuer` rule about `issuer` (a `link` rule's is `linkKey`).
    public static func matchKey(issuer: IssuerKey) -> String { issuer.key }

    /// The match key for a `link` rule about `issuer`: one per family (`"<issuer>#record"`,
    /// `"<issuer>#transaction"`). Rules learnt before had the bare issuer key (`linkIssuerKey`).
    public static func linkKey(issuer: IssuerKey, family: ImportLinkFamily) -> String { linkKey(issuer.key, family: family) }

    static func linkKey(_ issuerKey: String, family: ImportLinkFamily) -> String { "\(issuerKey)#\(family.rawValue)" }

    /// The issuer key of a `link` rule's match key and its family when the key names one (nil: a
    /// bare key learnt before families, whose family is its action's).
    public static func linkIssuerKey(_ matchKey: String) -> (issuer: String, family: ImportLinkFamily?) {
        for family in ImportLinkFamily.allCases where matchKey.hasSuffix("#" + family.rawValue) {
            return (String(matchKey.dropLast(family.rawValue.count + 1)), family)
        }
        return (matchKey, nil)
    }

    /// The family of a `link` rule: its key's, else its action's.
    static func linkFamily(_ rule: ImportRule) -> ImportLinkFamily? {
        if let family = linkIssuerKey(rule.matchKey).family { return family }
        return ImportLearning.decode(LinkAction.self, rule.actionJSON).map(ImportLinkFamily.of)
    }

    /// The match key for a `figurePosition` rule: one per issuer and field.
    public static func figurePositionKey(issuer: IssuerKey, field: ImportFigureField) -> String {
        "\(issuer.key)#\(field.rawValue)"
    }
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
                             action: some Encodable, actionLabel: String, now: Date, by appUserId: Int64? = nil) throws -> ImportRule {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(action), as: UTF8.self)
        return try learn(db: db, kind: kind, key: key, matchLabel: matchLabel, actionJSON: json, actionLabel: actionLabel, now: now, by: appUserId)
    }

    /// The rule a new one for `kind` and `key` replaces, enabled or not: the same pair, or for a
    /// family-keyed link the issuer's bare-keyed link rule of that family (learnt before families).
    public static func existing(db: Database, kind: ImportRuleKind, key: String) throws -> ImportRule? {
        existing(in: try ImportRule.filter(Column("kind") == kind.rawValue).fetchAll(db), kind: kind, key: key)
    }

    /// `existing(db:kind:key:)` among `rules`.
    public static func existing(in rules: [ImportRule], kind: ImportRuleKind, key: String) -> ImportRule? {
        let ofKind = rules.filter { $0.kind == kind }
        if let same = ofKind.first(where: { $0.matchKey == key }) { return same }
        let (issuer, family) = ImportRuleKind.linkIssuerKey(key)
        guard kind == .link, let family else { return nil }
        return ofKind.first { $0.matchKey == issuer && ImportRuleKind.linkFamily($0) == family }
    }

    /// `learn` with the action already encoded (a draft's, `ImportRuleDraft`). A bare-keyed link
    /// rule of the same family takes the family key. `appUserId`: who taught it; a new rule keeps
    /// them as its creator, and a replaced one only as the last to teach it.
    @discardableResult
    public static func learn(db: Database, kind: ImportRuleKind, key: String, matchLabel: String,
                             actionJSON json: String, actionLabel: String, now: Date, by appUserId: Int64? = nil) throws -> ImportRule {
        if var existing = try existing(db: db, kind: kind, key: key) {
            existing.matchKey = key
            existing.matchLabel = matchLabel
            existing.actionJSON = json
            existing.actionLabel = actionLabel
            existing.isEnabled = true
            if let appUserId { existing.lastLearntByAppUserId = appUserId }
            try existing.update(db)
            return existing
        }
        var rule = ImportRule(kind: kind, matchKey: key, matchLabel: matchLabel, actionJSON: json,
                              actionLabel: actionLabel, createdAt: now,
                              createdByAppUserId: appUserId, lastLearntByAppUserId: appUserId)
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
