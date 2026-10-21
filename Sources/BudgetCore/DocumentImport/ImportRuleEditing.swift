import Foundation
import GRDB

/// A learnt import rule as the Rules page lists it ("Import rules" tab).
public struct ImportRuleRow: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var kind: ImportRuleKind
    /// "Document type", "Issuer name", "Link", "Figure position", "Statement account".
    public var kindLabel: String
    /// What the rule matches: the issuer, or the statement file's signature.
    public var when: String
    /// What it does, naming the record as it is called now (the name it was learnt with when it's gone).
    public var then: String
    public var useCount: Int
    public var lastUsedAt: Date?
    public var isEnabled: Bool
    /// Its account or record no longer exists: every applier skips it.
    public var targetMissing: Bool

    public init(id: Int64, kind: ImportRuleKind, kindLabel: String, when: String, then: String, useCount: Int,
                lastUsedAt: Date?, isEnabled: Bool, targetMissing: Bool) {
        self.id = id
        self.kind = kind
        self.kindLabel = kindLabel
        self.when = when
        self.then = then
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.isEnabled = isEnabled
        self.targetMissing = targetMissing
    }
}

/// A new action for a learnt rule, from the Rules page's Edit Rule sheet: one per kind (a link
/// either to a record or to a merchant's transactions).
public enum ImportRuleEdit: Equatable, Hashable, Sendable {
    case account(Int64)
    case documentKind(DocumentKind)
    case issuerName(String)
    case link(EvidenceEntity)
    case merchant(String)
    case figureLabel(String)
}

public enum ImportRuleEditError: Error, Equatable {
    case notFound
    /// The edit doesn't suit the rule's kind.
    case wrongKind
    case blank
    /// A name, merchant or label with no letter in it ("123", "—").
    case noLetters
    /// The account or record chosen doesn't exist.
    case missingTarget
}

/// A record a learnt link can be pointed at in the Edit Rule sheet.
public struct ImportRuleTarget: Equatable, Hashable, Identifiable, Sendable {
    public var entity: EvidenceEntity
    public var label: String
    public var id: EvidenceEntity { entity }

    public init(entity: EvidenceEntity, label: String) {
        self.entity = entity
        self.label = label
    }
}

/// The Rules page's learnt import rules: listed, edited (the action and its label only; the
/// match stays), switched off and on, deleted. These are the user's own changes outside an
/// import run, written straight away like transaction-rule edits. A rule whose account or
/// record is gone is flagged (`targetMissing`); the appliers already skip it
/// (`UKStatementReader.remembered`, `BBVAStatementReader`, `ImportLearning.applyLinkRules`).
public enum ImportRuleEditing {
    /// A name, merchant or figure label as saved: trimmed, and with at least one letter
    /// (`ImportRuleEditError.blank`, `.noLetters` otherwise). The Edit Rule sheet's Save uses it too.
    public static func checkedText(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportRuleEditError.blank }
        guard trimmed.unicodeScalars.contains(where: CharacterSet.letters.contains) else { throw ImportRuleEditError.noLetters }
        return trimmed
    }

    /// Whether `checkedText` accepts `value`.
    public static func isValidText(_ value: String) -> Bool { (try? checkedText(value)) != nil }

    public static func kindLabel(_ kind: ImportRuleKind) -> String {
        switch kind {
        case .documentKind: return "Document type"
        case .issuer: return "Issuer name"
        case .link: return "Link"
        case .figurePosition: return "Figure position"
        case .statementAccount: return "Statement account"
        }
    }

    /// Every learnt rule, oldest first.
    public static func rows(db: Database) throws -> [ImportRuleRow] {
        try ImportRuleStore.all(db: db).compactMap { rule in
            guard let id = rule.id else { return nil }
            let missing = try targetMissing(db: db, rule)
            return ImportRuleRow(id: id, kind: rule.kind, kindLabel: kindLabel(rule.kind), when: rule.matchLabel,
                                 then: missing ? rule.actionLabel : try currentLabel(db: db, rule) ?? rule.actionLabel,
                                 useCount: rule.useCount, lastUsedAt: rule.lastUsedAt, isEnabled: rule.isEnabled, targetMissing: missing)
        }
    }

    /// Whether the rule's account (a statement account) or record (a link) no longer exists.
    public static func targetMissing(db: Database, _ rule: ImportRule) throws -> Bool {
        switch rule.kind {
        case .statementAccount:
            guard let action = ImportLearning.decode(StatementAccountAction.self, rule.actionJSON) else { return false }
            return try !Account.exists(db, key: action.accountId)
        case .link:
            guard let entity = ImportLearning.decode(LinkAction.self, rule.actionJSON)?.entity else { return false }
            return try !EvidenceLinks.entityExists(db: db, entity)
        case .documentKind, .issuer, .figurePosition:
            return false
        }
    }

    public static func setEnabled(db: Database, id: Int64, _ enabled: Bool) throws {
        guard var rule = try ImportRule.fetchOne(db, key: id) else { throw ImportRuleEditError.notFound }
        rule.isEnabled = enabled
        try rule.update(db)
    }

    public static func delete(db: Database, id: Int64) throws {
        guard try ImportRule.deleteOne(db, key: id) else { throw ImportRuleEditError.notFound }
    }

    /// Replaces the rule's action and its label; its match, use and on/off stay.
    public static func update(db: Database, id: Int64, actionJSON: String, actionLabel: String) throws {
        guard var rule = try ImportRule.fetchOne(db, key: id) else { throw ImportRuleEditError.notFound }
        rule.actionJSON = actionJSON
        rule.actionLabel = actionLabel
        try rule.update(db)
    }

    /// The sheet's edit, checked against the rule's kind and encoded with its label (what the
    /// user doesn't edit kept: a link's role while it points at the same kind of record, a
    /// figure's field and occurrence).
    public static func update(db: Database, id: Int64, edit: ImportRuleEdit) throws {
        guard let rule = try ImportRule.fetchOne(db, key: id) else { throw ImportRuleEditError.notFound }
        let (json, label) = try encode(db: db, edit, for: rule)
        try update(db: db, id: id, actionJSON: json, actionLabel: label)
    }

    /// The rule's action as an edit, to open the sheet with; nil when it can't be read.
    public static func currentEdit(_ rule: ImportRule) -> ImportRuleEdit? {
        switch rule.kind {
        case .statementAccount:
            return ImportLearning.decode(StatementAccountAction.self, rule.actionJSON).map { .account($0.accountId) }
        case .documentKind:
            return ImportLearning.decode(DocumentKindAction.self, rule.actionJSON).map { .documentKind($0.kind) }
        case .issuer:
            return ImportLearning.decode(IssuerAction.self, rule.actionJSON).map { .issuerName($0.name) }
        case .link:
            guard let action = ImportLearning.decode(LinkAction.self, rule.actionJSON) else { return nil }
            if let entity = action.entity { return .link(entity) }
            return action.descriptionKey.map { .merchant($0) }
        case .figurePosition:
            return ImportLearning.decode(FigurePositionAction.self, rule.actionJSON).map { .figureLabel($0.label) }
        }
    }

    /// The records a learnt link can go to: properties, their tenancies, accounts — and the
    /// rule's own record (`current`) when it is none of those and still exists.
    public static func linkTargets(db: Database, current: EvidenceEntity? = nil) throws -> [ImportRuleTarget] {
        var targets: [ImportRuleTarget] = []
        for property in try Properties.all(db: db) {
            guard let propertyId = property.id else { continue }
            targets.append(ImportRuleTarget(entity: EvidenceEntity(type: .property, id: propertyId), label: property.name))
            for tenancy in try Tenancies.all(db: db, propertyId: propertyId) {
                guard let tenancyId = tenancy.id else { continue }
                let entity = EvidenceEntity(type: .tenancy, id: tenancyId)
                targets.append(ImportRuleTarget(entity: entity, label: try entityLabel(db: db, entity)))
            }
        }
        for account in try Account.order(Column("name").collating(.localizedCaseInsensitiveCompare), Column("id")).fetchAll(db) {
            guard let accountId = account.id else { continue }
            targets.append(ImportRuleTarget(entity: .account(accountId), label: account.displayName))
        }
        if let current, !targets.contains(where: { $0.entity == current }), try EvidenceLinks.entityExists(db: db, current) {
            targets.insert(ImportRuleTarget(entity: current, label: try entityLabel(db: db, current)), at: 0)
        }
        return targets
    }

    // MARK: Private

    /// "Account: <name>" / "Link to <title>" as the record is called now; nil for the kinds
    /// with no record (their stored label stands).
    private static func currentLabel(db: Database, _ rule: ImportRule) throws -> String? {
        switch rule.kind {
        case .statementAccount:
            guard let action = ImportLearning.decode(StatementAccountAction.self, rule.actionJSON),
                  let account = try Account.fetchOne(db, key: action.accountId) else { return nil }
            return "Account: \(account.displayName)"
        case .link:
            guard let entity = ImportLearning.decode(LinkAction.self, rule.actionJSON)?.entity else { return nil }
            return "Link to \(try entityLabel(db: db, entity))"
        case .documentKind, .issuer, .figurePosition:
            return nil
        }
    }

    private static func encode(db: Database, _ edit: ImportRuleEdit, for rule: ImportRule) throws -> (String, String) {
        func json(_ action: some Encodable) throws -> String {
            guard let json = ImportLearning.encode(action) else { throw ImportRuleEditError.wrongKind }
            return json
        }
        func text(_ value: String) throws -> String { try checkedText(value) }
        switch (rule.kind, edit) {
        case (.statementAccount, .account(let accountId)):
            guard let account = try Account.fetchOne(db, key: accountId) else { throw ImportRuleEditError.missingTarget }
            return (try json(StatementAccountAction(accountId: accountId)), "Account: \(account.displayName)")
        case (.documentKind, .documentKind(let kind)):
            return (try json(DocumentKindAction(kind: kind)), "Kind: \(kind.displayName)")
        case (.issuer, .issuerName(let name)):
            let name = try text(name)
            return (try json(IssuerAction(name: name)), "Name: \(name)")
        case (.link, .link(let entity)):
            guard try EvidenceLinks.entityExists(db: db, entity) else { throw ImportRuleEditError.missingTarget }
            // A role is a role on that kind of record: pointed at another kind, it doesn't carry over.
            let old = ImportLearning.decode(LinkAction.self, rule.actionJSON)
            let role = old?.entity?.type == entity.type ? old?.role : nil
            return (try json(LinkAction(entity: entity, role: role)), "Link to \(try entityLabel(db: db, entity))")
        case (.link, .merchant(let merchant)):
            let merchant = MerchantKey.make(try text(merchant))
            return (try json(LinkAction(descriptionKey: merchant)), "Paid by “\(merchant)”")
        case (.figurePosition, .figureLabel(let label)):
            let label = try text(label)
            guard let old = ImportLearning.decode(FigurePositionAction.self, rule.actionJSON) else { throw ImportRuleEditError.wrongKind }
            return (try json(FigurePositionAction(field: old.field, label: label, occurrence: old.occurrence)),
                    "\(old.field.displayName): after “\(label)”")
        default:
            throw ImportRuleEditError.wrongKind
        }
    }
}
