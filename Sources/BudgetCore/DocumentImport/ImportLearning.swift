import Foundation
import GRDB

/// What the review's corrections teach and how the next import uses it. A correction (a kind,
/// an issuer's name, a link) drafts a rule on the item (`drafts`), keyed by the document's issuer
/// (`IssuerKey`); the drafts of applied items are learnt on Confirm import, inside the run
/// (`ImportApplier`), so Undo of the run takes them back. Next time a learnt kind recognises the
/// issuer's files after the built-in recognisers (`recogniser`), and a learnt name and link are
/// applied to each item read (`applyLinkRules`), each named on the item (`ImportItem.appliedRules`).
/// Disabled rules never apply; a rule whose record is gone is skipped.
public enum ImportLearning {
    /// The note of an item whose kind a built-in recogniser reads: a chosen kind isn't remembered.
    public static let recognisesItselfNote = "The app recognises these itself: the kind isn't remembered"

    // MARK: Drafts

    /// The rules `resolution` teaches about the item's issuer (`item` as the answer left it):
    /// `.chooseKind` → its kind; `.setIssuer` or `.confirmFigure(.issuer, …)` → its name; `.chooseLink` → the record, or for a
    /// transaction the merchant of its description (`MerchantKey.make`, from
    /// `transactionDescriptions`); `.linkTransactions` / `.addTransactionLink` → the merchant when
    /// exactly one transaction is linked (a split payment isn't a pattern);
    /// `.confirmFigureRemembering` → where the figure sits (`LearntFigures.label(for:)`: its label and
    /// occurrence, never the value; nothing when it can't be placed, nor on a kind whose positions
    /// aren't learnt, `LearntFigures.learns`); `.acceptModelReading` → the kind and name the
    /// model read, now the user's. Nothing else teaches,
    /// and nothing is drafted without an issuer key, nor for a bank's own letterhead
    /// (`IssuerKey.isBankLetterhead`: every letter the bank sends would match) — the correction
    /// still fixes this document. A merchant is drafted only when it names one (`isMerchantPattern`).
    public static func drafts(for item: ImportItem, resolution: ImportResolution, issuer: IssuerKey?,
                              transactionDescriptions: [Int64: String] = [:]) -> [ImportRuleDraft] {
        guard let issuer, !IssuerKey.isBankLetterhead(issuer) else { return [] }
        let key = ImportRuleKind.matchKey(issuer: issuer)
        func draft(_ kind: ImportRuleKind, _ action: some Encodable, _ label: String, key: String = key) -> [ImportRuleDraft] {
            guard let json = encode(action) else { return [] }
            return [ImportRuleDraft(kind: kind, key: key, matchLabel: issuer.label, actionJSON: json, actionLabel: label)]
        }
        func paidBy(_ id: Int64) -> [ImportRuleDraft] {
            guard let description = transactionDescriptions[id] else { return [] }
            let merchant = MerchantKey.make(description)
            guard isMerchantPattern(merchant, description: description) else { return [] }
            return draft(.link, LinkAction(descriptionKey: merchant), "Paid by “\(merchant)”",
                         key: ImportRuleKind.linkKey(issuer: issuer, family: .transaction))
        }
        let linked = item.links.filter { $0.entity.type == .transaction && $0.confidence == .certain }
        switch resolution {
        case .chooseKind(let kind):
            return draft(.documentKind, DocumentKindAction(kind: kind), "Kind: \(kind.displayName)")
        case .chooseCustomKind(let customKey):
            // Named by the item as read (its placement's custom kind); a kind made in this review
            // gets its id at Confirm import (`pendingKindId`).
            guard let custom = item.placement?.customKind, custom.key == customKey else { return [] }
            switch customKey {
            case .saved(let id):
                return draft(.documentKind, DocumentKindAction(kind: .other, customKindId: id), "Kind: \(custom.name)")
            case .pending(let id):
                guard let json = encode(DocumentKindAction(kind: .other)) else { return [] }
                return [ImportRuleDraft(kind: .documentKind, key: key, matchLabel: issuer.label, actionJSON: json,
                                        actionLabel: "Kind: \(custom.name)", pendingKindId: id)]
            }
        case .setIssuer(let name), .confirmFigure(.issuer, .text(let name)), .confirmFigureRemembering(.issuer, .text(let name)):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : draft(.issuer, IssuerAction(name: trimmed), "Name: \(trimmed)")
        case .chooseLink(let entity):
            if entity.type == .transaction { return paidBy(entity.id) }
            let link = item.links.first { $0.entity == entity }
            return draft(.link, LinkAction(entity: entity, role: link?.role), "Link to \(link?.label ?? "\(entity.type.displayName) #\(entity.id)")",
                         key: ImportRuleKind.linkKey(issuer: issuer, family: .record))
        case .linkTransactions(let ids):
            return ids.count == 1 ? paidBy(ids[0]) : []
        case .addTransactionLink(let id):
            return linked.count == 1 && linked[0].entity.id == id ? paidBy(id) : []
        case .acceptModelReading:
            // What the model read, accepted: its kind (as the item is now recognised) and the issuer's name.
            var drafts: [ImportRuleDraft] = []
            if item.recognition.confidence == .certain, let kind = DocumentIdentity.documentKind(of: item.recognition.kind), kind != .other {
                drafts += draft(.documentKind, DocumentKindAction(kind: kind), "Kind: \(kind.displayName)")
            }
            if let fact = item.facts.first(where: { $0.field == .issuer && $0.source == .user }), case .text(let name) = fact.value {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { drafts += draft(.issuer, IssuerAction(name: trimmed), "Name: \(trimmed)") }
            }
            return drafts
        case .confirmFigureRemembering(let field, let value):
            guard LearntFigures.learns(item.recognition.kind), let text = item.file.text, let (label, occurrence) = LearntFigures.label(for: value, field: field, in: text),
                  let json = encode(FigurePositionAction(field: field, label: label, occurrence: occurrence)) else { return [] }
            return [ImportRuleDraft(kind: .figurePosition, key: ImportRuleKind.figurePositionKey(issuer: issuer, field: field),
                                    matchLabel: issuer.label, actionJSON: json, actionLabel: "\(field.displayName): after “\(label)”")]
        default:
            return []
        }
    }

    /// The figure a correction fixes by hand (`.confirmFigure`, `.confirmFigureRemembering`; an
    /// issuer's name is learnt as a name): its earlier position draft and the learnt position
    /// that read it are replaced.
    static func correctedFigure(_ resolution: ImportResolution) -> ImportFigureField? {
        switch resolution {
        case .confirmFigure(let field, _), .confirmFigureRemembering(let field, _): return field == .issuer ? nil : field
        default: return nil
        }
    }

    /// Bank prefixes and codes of a description ("SEPADD/", "DD ", "TRF", "PG", "MB"): they say how
    /// it was paid, not to whom.
    static let bankDescriptionWords: Set<String> = BBVADebitAdvice.descriptionStopwords
        .union(["DD", "PG", "MB", "SD", "GE", "TRANSFERENCIA", "TRANSFER", "DIRECT", "DEBIT", "STANDING", "ORDER", "SO", "BGC", "FPI", "FPO"])

    /// Whether a merchant key (`MerchantKey.make` of `description`) names a merchant: a word of
    /// three or more letters that isn't a bank's prefix or code or a generic word ("EDP", "MEO",
    /// "DEMO SEGUROS"), and a description that isn't only a short code and a long reference
    /// ("SMR 3402…": a reference that changes with every debit is never a pattern).
    static func isMerchantPattern(_ key: String, description: String) -> Bool {
        let words = EvidenceText.normalized(key).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { word in
                !word.contains(where: \.isNumber) && !bankDescriptionWords.contains(word)
                    && !MerchantKey.genericTokens.contains(word) && !MerchantKey.processorTokens.contains(word)
            }
        guard words.contains(where: { $0.filter(\.isLetter).count >= 3 }) else { return false }
        let tokens = EvidenceText.normalized(description).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let referenceOnly = tokens.count == 2 && tokens[0].count <= 3 && tokens[0].allSatisfy(\.isLetter)
            && tokens[1].allSatisfy(\.isNumber) && tokens[1].count >= 10
        return !referenceOnly
    }

    /// The draft kinds an answer replaces on the item (its earlier drafts of that kind, and the
    /// learnt rule of that kind it overrides): a kind for a kind, a name for a name, every link
    /// change for the links. Empty: the answer teaches nothing.
    static func replacedKinds(by resolution: ImportResolution) -> Set<ImportRuleKind> {
        switch resolution {
        case .chooseKind, .chooseCustomKind, .createKind: return [.documentKind]
        case .setIssuer, .confirmFigure(.issuer, _), .confirmFigureRemembering(.issuer, _): return [.issuer]
        case .chooseLink, .linkTransactions, .addTransactionLink, .unlink, .fileWithoutLink: return [.link]
        default: return []
        }
    }

    /// The link families an answer replaces on the item (its earlier link drafts of that family,
    /// and the learnt link rule of that family it overrides): a record choice the record link, a
    /// payment the merchant; filing without a link, or unlinking, the families of the links it
    /// dropped (`before` → `after`).
    static func replacedLinkFamilies(by resolution: ImportResolution, before: ImportItem, after: ImportItem) -> Set<ImportLinkFamily> {
        switch resolution {
        case .chooseLink(let entity), .unlink(let entity): return [ImportLinkFamily.of(entity)]
        case .linkTransactions, .addTransactionLink: return [.transaction]
        case .fileWithoutLink:
            let kept = Set(after.links.map(\.entity))
            return Set(before.links.filter { !kept.contains($0.entity) }.map { ImportLinkFamily.of($0.entity) })
        default: return []
        }
    }

    /// The family of a link draft (nil for other kinds).
    static func linkFamily(_ draft: ImportRuleDraft) -> ImportLinkFamily? {
        guard draft.kind == .link else { return nil }
        return ImportRuleKind.linkIssuerKey(draft.key).family
            ?? decode(LinkAction.self, draft.actionJSON).map(ImportLinkFamily.of)
    }

    /// `drafts` each naming the learnt rule (of `rules`, every one) it will replace (`replaces`:
    /// that rule's action label), when one exists that does something else (`ImportRuleStore.existing`).
    static func namingReplaced(_ drafts: [ImportRuleDraft], rules: [ImportRule]) -> [ImportRuleDraft] {
        drafts.map { draft in
            var named = draft
            let rule = ImportRuleStore.existing(in: rules, kind: draft.kind, key: draft.key)
            // A kind made in this review is never what a rule does already.
            named.replaces = rule.flatMap { $0.actionJSON == draft.actionJSON && draft.pendingKindId == nil ? nil : $0.actionLabel }
            return named
        }
    }

    /// The drafts of a run that are learnt (`learnable`), and a note for each issuer and family
    /// whose items in the run drafted different things: none of those is learnt.
    static func learnable(_ drafts: [ImportRuleDraft]) -> (drafts: [ImportRuleDraft], notes: [String]) {
        struct Slot: Hashable { let kind: ImportRuleKind; let key: String }
        var actions: [Slot: Set<String>] = [:]
        for draft in drafts { actions[Slot(kind: draft.kind, key: draft.key), default: []].insert(draft.actionIdentity) }
        var notes: [String] = [], noted: Set<Slot> = []
        var kept: [ImportRuleDraft] = []
        for draft in drafts {
            let slot = Slot(kind: draft.kind, key: draft.key)
            if actions[slot]?.count ?? 0 > 1 {
                if noted.insert(slot).inserted {
                    notes.append("Not learnt: different choices for \(draft.matchLabel) (\(ImportRuleEditing.kindLabel(draft.kind))) in this import")
                }
            } else if !kept.contains(where: { $0.kind == draft.kind && $0.key == draft.key }) {
                kept.append(draft)
            }
        }
        return (kept, notes)
    }

    /// The drafts `item` still carries (`isCarried`), its linked transactions' descriptions read from `db`.
    static func carried(_ drafts: [ImportRuleDraft], by item: ImportItem, db: Database) throws -> [ImportRuleDraft] {
        guard !drafts.isEmpty else { return drafts }
        let ids = item.links.filter { $0.entity.type == .transaction }.map(\.entity.id)
        var descriptions: [Int64: String] = [:]
        for transaction in try Transaction.fetchAll(db, keys: Set(ids)) {
            if let id = transaction.id { descriptions[id] = transaction.rawDescription }
        }
        return drafts.filter { isCarried($0, by: item, descriptions: descriptions) }
    }

    /// Whether the item still carries the correction `draft` came from (after a reread): its kind
    /// is the draft's, its issuer fact is the user's name, its record link is certain, or its one
    /// certain transaction link is the merchant's (`descriptions`: the item's linked transactions).
    static func isCarried(_ draft: ImportRuleDraft, by item: ImportItem, descriptions: [Int64: String]) -> Bool {
        switch draft.kind {
        case .documentKind:
            if let pending = draft.pendingKindId { return item.recognition.kind == .customEvidence(.pending(pending)) }
            guard let action = decode(DocumentKindAction.self, draft.actionJSON) else { return false }
            return ImportResolutions.importKind(for: action.kindRef, fileExtension: item.file.fileExtension) == item.recognition.kind
        case .issuer:
            guard let action = decode(IssuerAction.self, draft.actionJSON) else { return false }
            return item.facts.contains { $0.field == .issuer && $0.source == .user && $0.value == .text(action.name) }
        case .link:
            guard let action = decode(LinkAction.self, draft.actionJSON) else { return false }
            if action.entity != nil { return carriesLink(action, item: item, descriptions: descriptions) }
            // A merchant is learnt from one payment only.
            let linked = item.links.filter { $0.entity.type == .transaction && $0.confidence == .certain }
            return linked.count == 1 && carriesLink(action, item: item, descriptions: descriptions)
        case .figurePosition:
            // The figure is still the user's.
            guard let action = decode(FigurePositionAction.self, draft.actionJSON) else { return false }
            return item.facts.contains { $0.field == action.field && $0.source == .user }
        case .statementAccount:
            return true
        }
    }

    /// Whether the item has the link `action` makes, certain: its record, or a transaction of its
    /// merchant (`descriptions`: the item's linked transactions).
    static func carriesLink(_ action: LinkAction, item: ImportItem, descriptions: [Int64: String]) -> Bool {
        let certain = item.links.filter { $0.confidence == .certain }
        if let entity = action.entity { return certain.contains { $0.entity == entity } }
        guard let key = action.descriptionKey else { return false }
        return certain.contains { link in
            link.entity.type == .transaction && descriptions[link.entity.id].map(MerchantKey.make) == key
        }
    }

    /// `drafts` as an answer leaves them on `item`: no kind when a built-in recogniser reads the
    /// file (`recognisesItself`; the item says so, `recognisesItselfNote`), each naming the rule it
    /// replaces (`namingReplaced`).
    static func finishing(_ drafts: [ImportRuleDraft], on item: inout ImportItem, recognisesItself: Bool, rules: [ImportRule]) -> [ImportRuleDraft] {
        var drafts = drafts
        if recognisesItself, drafts.contains(where: { $0.kind == .documentKind }) {
            drafts.removeAll { $0.kind == .documentKind }
            if !item.notes.contains(recognisesItselfNote) { item.notes.append(recognisesItselfNote) }
        }
        return namingReplaced(drafts, rules: rules)
    }

    // MARK: Recognising

    /// The learnt kinds as a recogniser (`ImportDetector`, after the built-in ones and before the
    /// file-name fallback): the file's issuer with an enabled `documentKind` rule is that kind,
    /// certain (to check when the file was read by text recognition, or when the issuer is known
    /// only by its first line: "… Learnt from the first line “<line>”: check it"), "Learnt: <issuer> → <kind>",
    /// the rule on the recognition (`ruleId`).
    /// A rule naming a custom kind that's gone (`catalog`: the kinds in use) is skipped.
    public static func recogniser(rules: [ImportRule], ownNIFs: Set<String>, catalog: DocumentKindCatalog = DocumentKindCatalog(customKinds: [])) -> ImportRecogniser {
        var byKey: [String: (rule: ImportRule, kind: DocumentKindRef, name: String)] = [:]
        for rule in rules where rule.isEnabled && rule.kind == .documentKind && rule.id != nil && byKey[rule.matchKey] == nil {
            guard let action = decode(DocumentKindAction.self, rule.actionJSON) else { continue }
            if let id = action.customKindId {
                guard let custom = catalog.custom(id: id) else { continue }
                byKey[rule.matchKey] = (rule, .custom(id), custom.name)
            } else {
                byKey[rule.matchKey] = (rule, .builtIn(action.kind), action.kind.displayName)
            }
        }
        let learnt = byKey
        return { file in
            guard !learnt.isEmpty, let issuer = IssuerKey.derive(text: file.text, fileName: file.fileName, ownNIFs: ownNIFs),
                  let (rule, kind, name) = learnt[ImportRuleKind.matchKey(issuer: issuer)] else { return nil }
            // Keyed by a first line (no number): the kind is suggested, to check.
            let line = IssuerKey.isLineKey(rule.matchKey)
            let reason = "Learnt: \(rule.matchLabel) → \(name)"
            return ImportRecognition(kind: ImportResolutions.importKind(for: kind, fileExtension: file.fileExtension),
                                     confidence: file.usedOCR || line ? .needsReview : .certain,
                                     reason: line ? IssuerKey.lineKeyReason(reason, line: rule.matchLabel) : reason, ruleId: rule.id)
        }
    }

    // MARK: Applying

    /// The item with the learnt rules about its issuer applied, each named in `appliedRules`:
    /// the `documentKind` rule that recognised it; an `issuer` rule names its issuer fact
    /// (`.learntRule`, when it has none); a `link` rule with a record links to it, certain,
    /// "Learnt: <issuer> documents go to <label>" (not when it has a certain link of that type
    /// already); a `link` rule with a merchant makes the one "which one?" candidate whose
    /// transaction has that merchant and the document's amount (currency included, read certain:
    /// never one to check — text recognition, file name, model) the certain link ("Learnt: <issuer> is paid by “<merchant>”"; its date need not fit) — with
    /// several (or none of the amount) the question stays, the merchant's candidates first,
    /// naming the rule. Children, statements and unreadable files are left as read; a rule
    /// whose record no longer exists, or that is disabled, is skipped.
    /// `ownNIFs`: the known parties (`IssuerKey.knownParties`), read from `db` when nil.
    /// `declined`: rules the user overrode on this item (an unlinked learnt link): not applied again.
    public static func applyLinkRules(_ item: ImportItem, rules: [ImportRule], db: Database,
                                      ownNIFs: Set<String>? = nil, declined: Set<Int64> = []) throws -> ImportItem {
        var item = item
        if let id = item.recognition.ruleId, !declined.contains(id), !item.appliedRules.contains(where: { $0.ruleId == id }) {
            item.appliedRules.append(ImportRuleUse(ruleId: id, kind: .documentKind, label: item.recognition.reason))
        }
        guard item.parentId == nil, !ImportResolutions.isStatement(item), !ImportResolutions.isUnreadable(item) else { return item }
        let enabled = rules.filter { rule in
            guard rule.isEnabled, let id = rule.id, !declined.contains(id) else { return false }
            return rule.kind == .issuer || rule.kind == .link
        }
        guard !enabled.isEmpty else { return item }
        let own = try ownNIFs ?? IssuerKey.knownParties(db: db)
        guard let issuer = IssuerKey.derive(text: item.file.text, fileName: item.file.fileName, ownNIFs: own) else { return item }
        let key = ImportRuleKind.matchKey(issuer: issuer)

        if let rule = enabled.first(where: { $0.kind == .issuer && $0.matchKey == key }),
           let action = decode(IssuerAction.self, rule.actionJSON), !item.facts.contains(where: { $0.field == .issuer }) {
            let label = "Learnt: \(rule.matchLabel) is named \(action.name)"
            let line = IssuerKey.isLineKey(rule.matchKey)
            item.facts.append(ImportFact(field: .issuer, value: .text(action.name), source: .learntRule, confidence: line ? .needsReview : .certain,
                                         reason: line ? IssuerKey.lineKeyReason(label, line: rule.matchLabel) : label))
            if item.placement != nil {
                item.placement = ImportNaming.placement(kind: item.recognition.kind, facts: item.facts, file: item.file,
                                                        persons: item.placement?.metadata.persons ?? [],
                                                customKind: item.placement?.customKind)
            }
            item.appliedRules.append(ImportRuleUse(ruleId: rule.id!, kind: .issuer, label: label))
        }

        // One link rule per family: the record, then the merchant.
        for family in ImportLinkFamily.allCases {
            guard let rule = linkRule(family, issuerKey: key, in: enabled), let action = decode(LinkAction.self, rule.actionJSON) else { continue }
            if let entity = action.entity {
                try linkEntity(&item, entity, role: action.role, rule: rule, db: db)
            } else if let merchant = action.descriptionKey {
                try linkMerchant(&item, merchant, rule: rule, db: db)
            }
        }
        return item
    }

    /// The issuer's `link` rule of `family`: the family-keyed one, else a bare-keyed one (learnt
    /// before families) whose action is of that family.
    static func linkRule(_ family: ImportLinkFamily, issuerKey: String, in rules: [ImportRule]) -> ImportRule? {
        let links = rules.filter { $0.kind == .link }
        return links.first { $0.matchKey == ImportRuleKind.linkKey(issuerKey, family: family) }
            ?? links.first { $0.matchKey == issuerKey && ImportRuleKind.linkFamily($0) == family }
    }

    /// A learnt record link: certain, unless the record is gone or the item already has a certain
    /// link of that type (the user's target, a reader's). A "which one?" offering it is answered as
    /// the user would (`ImportResolutions.apply(.chooseLink)`), the rule as its reason. A rule keyed
    /// by a first line only suggests it, to check: the link to check, or first in the question.
    private static func linkEntity(_ item: inout ImportItem, _ entity: EvidenceEntity, role: String?, rule: ImportRule, db: Database) throws {
        guard try EvidenceLinks.entityExists(db: db, entity),
              !item.links.contains(where: { $0.entity.type == entity.type && $0.confidence == .certain }) else { return }
        let label = try entityLabel(db: db, entity)
        var reason = "Learnt: \(rule.matchLabel) documents go to \(label)"
        let asking = item.issues.first { issue in
            if case .chooseLink(let candidates) = issue.kind { return candidates.contains { $0.entity == entity } }
            return false
        }
        if IssuerKey.isLineKey(rule.matchKey) {
            reason = IssuerKey.lineKeyReason(reason, line: rule.matchLabel)
            if let asking, case .chooseLink(let candidates) = asking.kind, let index = item.issues.firstIndex(of: asking) {
                item.issues[index].kind = .chooseLink(suggesting([entity], first: candidates, reason: reason))
                return
            }
            if let index = item.links.firstIndex(where: { $0.entity == entity }) {
                if !item.links[index].reasons.contains(reason) { item.links[index].reasons.append(reason) }
            } else {
                item.links.append(ProposedLink(entity: entity, role: role, label: label, confidence: .needsReview, reasons: [reason]))
            }
            item.appliedRules.append(ImportRuleUse(ruleId: rule.id!, kind: .link, label: reason))
            return
        }
        if asking != nil || item.links.contains(where: { $0.entity == entity }) {
            try choose(&item, entity, issueId: asking?.id, reason: reason)
        } else {
            item.links.append(ProposedLink(entity: entity, role: role, label: label, confidence: .certain, reasons: [reason]))
        }
        item.appliedRules.append(ImportRuleUse(ruleId: rule.id!, kind: .link, label: reason))
    }

    /// A learnt merchant link: the item's "which one?" about transactions answered when exactly
    /// one candidate is the merchant's for the document's certain amount; else its candidates
    /// reordered, the merchant's first.
    private static func linkMerchant(_ item: inout ImportItem, _ merchant: String, rule: ImportRule, db: Database) throws {
        // Keyed by a first line: never chosen, only suggested first.
        let line = IssuerKey.isLineKey(rule.matchKey)
        let base = "Learnt: \(rule.matchLabel) is paid by “\(merchant)”"
        let reason = line ? IssuerKey.lineKeyReason(base, line: rule.matchLabel) : base
        // Only an amount read for sure (never one to check) can make the link certain.
        let amount = item.facts.first { $0.field == .amount && $0.confidence == .certain && !$0.source.alwaysNeedsReview }
            .flatMap { fact -> (Int, Currency)? in
                if case .money(let minor, let currency) = fact.value { return (abs(minor), currency) }
                return nil
            }
        for issue in item.issues {
            guard case .chooseLink(let candidates) = issue.kind, !candidates.isEmpty,
                  candidates.allSatisfy({ $0.entity.type == .transaction }) else { continue }
            var merchants: [Int] = [], paying: [Int] = []
            for (c, candidate) in candidates.enumerated() {
                guard let transaction = try Transaction.fetchOne(db, key: candidate.entity.id),
                      MerchantKey.make(transaction.rawDescription) == merchant else { continue }
                merchants.append(c)
                if let (value, currency) = amount, abs(transaction.amountMinorUnits) == value,
                   try Account.fetchOne(db, key: transaction.accountId)?.currency == currency {
                    paying.append(c)
                }
            }
            guard !merchants.isEmpty else { continue }
            if paying.count == 1, !line {
                try choose(&item, candidates[paying[0]].entity, issueId: issue.id, reason: reason)
                item.appliedRules.append(ImportRuleUse(ruleId: rule.id!, kind: .link, label: reason))
            } else {
                // Several (or none of a sure amount, or a first line's rule): the user still picks, the merchant's first.
                let suggested = merchants.map { candidates[$0].entity }
                if let index = item.issues.firstIndex(of: issue) { item.issues[index].kind = .chooseLink(suggesting(suggested, first: candidates, reason: reason)) }
            }
            return
        }
    }

    /// `candidates` with the `suggested` ones first, each with `reason`.
    private static func suggesting(_ suggested: [EvidenceEntity], first candidates: [LinkCandidate], reason: String) -> [LinkCandidate] {
        let first = candidates.filter { suggested.contains($0.entity) }.map { candidate -> LinkCandidate in
            var candidate = candidate
            if !candidate.reasons.contains(reason) { candidate.reasons.append(reason) }
            return candidate
        }
        return first + candidates.filter { !suggested.contains($0.entity) }
    }

    /// `entity` chosen as the user would choose it (`ImportResolutions.apply(.chooseLink)`: the
    /// question answered, the other candidates' links dropped, an invoice's debit set), with the
    /// rule — not the user — as the reason.
    private static func choose(_ item: inout ImportItem, _ entity: EvidenceEntity, issueId: String?, reason: String) throws {
        guard let chosen = try ImportResolutions.apply(.chooseLink(entity), to: item, issueId: issueId) else { return }
        item = chosen
        if let index = item.links.firstIndex(where: { $0.entity == entity }) {
            item.links[index].reasons.removeAll { $0 == ImportResolutions.chosenReason }
            item.links[index].reasons.append(reason)
        }
        if entity.type == .transaction { item.notes.removeAll { $0.hasPrefix("Not linked:") } }
    }

    /// The enabled learnt rules about issuers (kind, name, link), for the passes that read items.
    static func enabledRules(db: Database) throws -> [ImportRule] {
        try ImportRule
            .filter(Column("isEnabled") == true)
            .filter([ImportRuleKind.documentKind, .issuer, .link].map(\.rawValue).contains(Column("kind")))
            .order(Column("id"))
            .fetchAll(db)
    }

    /// Every item read now with the learnt rules applied (`applyLinkRules`): before the duplicate
    /// pass and the filed-year guard of the same pass.
    /// `declined`: the learnt rules the user overrode on the item read again (not applied again).
    static func apply(_ items: [ImportItem], db: Database, declined: Set<Int64> = []) throws -> [ImportItem] {
        let rules = try enabledRules(db: db)
        guard !rules.isEmpty || items.contains(where: { $0.recognition.ruleId != nil }) else { return items }
        let own = try IssuerKey.knownParties(db: db)
        return try items.map { try applyLinkRules($0, rules: rules, db: db, ownNIFs: own, declined: declined) }
    }

    /// The enabled learnt figure positions, for the readers (`ImportContext.learntFigures`).
    static func figureRules(db: Database) throws -> [ImportRule] {
        try ImportRule
            .filter(Column("isEnabled") == true && Column("kind") == ImportRuleKind.figurePosition.rawValue)
            .order(Column("id"))
            .fetchAll(db)
    }

    // MARK: JSON

    static func encode(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
