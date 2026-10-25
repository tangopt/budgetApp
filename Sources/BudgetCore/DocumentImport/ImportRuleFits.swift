import Foundation

/// A value a rule change shows before or after: nothing, a word (a kind, a name, a link's
/// label) or a figure.
public enum ImportRuleChangeValue: Equatable, Sendable {
    case none
    case text(String)
    case figure(ImportFactValue)
}

/// One change a drafted rule would make on another document of the import, and the answer that
/// makes it (`resolution`): the one the user would give on that document.
public struct ImportRuleChange: Equatable, Sendable {
    public enum Aspect: Hashable, Sendable {
        case kind, name
        case link(ImportLinkFamily)
        case figure(ImportFigureField)
    }

    public var aspect: Aspect
    /// "Kind", "Name", "Link", "Paid by", a figure's name.
    public var label: String
    public var before: ImportRuleChangeValue
    public var after: ImportRuleChangeValue
    public var resolution: ImportResolution

    public init(aspect: Aspect, label: String, before: ImportRuleChangeValue, after: ImportRuleChangeValue, resolution: ImportResolution) {
        self.aspect = aspect
        self.label = label
        self.before = before
        self.after = after
        self.resolution = resolution
    }
}

/// Another document of the import a correction's rule fits, with what it would change there.
public struct ImportRuleFit: Equatable, Identifiable, Sendable {
    public var itemId: UUID
    public var documentName: String
    public var changes: [ImportRuleChange]
    public var id: UUID { itemId }

    public init(itemId: UUID, documentName: String, changes: [ImportRuleChange]) {
        self.itemId = itemId
        self.documentName = documentName
        self.changes = changes
    }
}

/// A drafted rule applied to another document of the review (`ImportPipeline.applyRule`), kept
/// in the plan's state so it can be undone while the review is open: the document (and its
/// children) and its per-item state before, the document after, what changed and the drafts the
/// answers added there. Dropped once the user answers on that document themselves.
struct ImportRuleChangeRecord: Equatable, Sendable {
    var sourceId: UUID
    var sourceName: String
    /// The source's drafts the change came from (an undo of the source that takes one of them
    /// back offers to undo this too).
    var sourceDrafts: [ImportRuleDraft]
    var before: [ImportItem]
    var state: ImportItemStateSnapshot
    var after: ImportItem
    var changes: [ImportRuleChange]
    var addedDrafts: [ImportRuleDraft]
}

/// The plan's state about some items (an item and its children), taken before a change and put
/// back by its undo.
struct ImportItemStateSnapshot: Equatable, Sendable {
    var ids: Set<UUID>
    var intents: [UUID: ImportIntent] = [:]
    var plannedIntents: [UUID: ImportIntent] = [:]
    var batchDuplicates: Set<UUID> = []
    var settled: [UUID: Set<String>] = [:]
    var chosenKinds: Set<UUID> = []
    var declinedRules: [UUID: Set<Int64>] = [:]
    var checks: [UUID: [ImportCheckTarget: ImportCheckRecord]] = [:]
    var checkAlls: [UUID: ImportCheckAllRecord] = [:]

    init(_ state: ImportPlanState, ids: Set<UUID>) {
        self.ids = ids
        intents = state.intents.filter { ids.contains($0.key) }
        plannedIntents = state.plannedIntents.filter { ids.contains($0.key) }
        batchDuplicates = state.batchDuplicates.intersection(ids)
        settled = state.settled.filter { ids.contains($0.key) }
        chosenKinds = state.chosenKinds.intersection(ids)
        declinedRules = state.declinedRules.filter { ids.contains($0.key) }
        checks = state.checks.filter { ids.contains($0.key) }
        checkAlls = state.checkAlls.filter { ids.contains($0.key) }
    }

    /// `state` with what it says of `removing` (the items now) replaced by the snapshot.
    func restore(into state: inout ImportPlanState, removing: Set<UUID>) {
        let all = removing.union(ids)
        state.intents = state.intents.filter { !all.contains($0.key) }.merging(intents) { _, old in old }
        state.plannedIntents = state.plannedIntents.filter { !all.contains($0.key) }.merging(plannedIntents) { _, old in old }
        state.batchDuplicates = state.batchDuplicates.subtracting(all).union(batchDuplicates)
        state.settled = state.settled.filter { !all.contains($0.key) }.merging(settled) { _, old in old }
        state.chosenKinds = state.chosenKinds.subtracting(all).union(chosenKinds)
        state.declinedRules = state.declinedRules.filter { !all.contains($0.key) }.merging(declinedRules) { _, old in old }
        state.checks = state.checks.filter { !all.contains($0.key) }.merging(checks) { _, old in old }
        state.checkAlls = state.checkAlls.filter { !all.contains($0.key) }.merging(checkAlls) { _, old in old }
    }
}

/// "This rule also fits N other documents in this import": the rules a correction drafts (a kind,
/// an issuer's name, a link to a record or a merchant, where a figure sits) checked against the
/// other documents of the same review, before Confirm import. A document fits when it has the
/// same issuer key (`ImportRuleKind.matchKey` / `linkKey` / `figurePositionKey`), takes
/// corrections (`ImportResolutions.isCorrectable`: never left out, a duplicate, held by a filed
/// year or unreadable), isn't a statement or a statement's row, and the rule would change
/// something the user hasn't answered there themselves:
///
/// - a kind: the document is read as another kind, and no built-in recogniser reads its file
///   (the learnt kind wouldn't apply next time either), and the user didn't choose or check its
///   kind → `.chooseKind`;
/// - a name: the document takes a name and its issuer isn't the user's or already that name →
///   `.setIssuer`;
/// - a record link: the document has no certain link of that type and offers the record (a
///   "which one?" candidate, or a link to check) → `.chooseLink`;
/// - a merchant: exactly one "which one?" transaction is the merchant's for the document's
///   amount, read for sure (as the learnt rule chooses it next time) → `.chooseLink`;
/// - a figure's position: re-reading the document's own text there (`LearntFigures.read`) gives
///   another value than its figure, which isn't the user's, the intent's or a record's (a
///   payroll form's only when its reader found none) → `.confirmFigure`.
///
/// Applying a fit is the user's answers given on that document, through the one resolution path.
public enum ImportRuleFits {
    /// What the passes need beyond the plan, read from the planning copy: each document's
    /// issuer key, the documents a built-in recogniser reads, and the transactions the "which
    /// one?" questions offer.
    struct Context: Sendable {
        struct Payment: Sendable {
            var merchant: String
            var amountMinorUnits: Int
            var currency: Currency?
        }

        var issuers: [UUID: IssuerKey] = [:]
        var recognisesItself: Set<UUID> = []
        var payments: [Int64: Payment] = [:]
        /// The custom kinds' names now (saved and the review's new ones).
        var kindNames = ImportKindNames()
    }

    /// The draft kinds a fit applies (the remembered statement account isn't about an issuer).
    static let appliedKinds: Set<ImportRuleKind> = [.documentKind, .issuer, .link, .figurePosition]

    /// The reasons a recognition carries when the user chose or checked it.
    private static let userRecognitionReasons: Set<String> = [ImportResolutions.chosenReason, ImportChecks.checkedReason,
                                                               ImportModelProposals.acceptedReason]

    /// The source's own drafts a fit applies: the corrections made on it, not ones a rule from
    /// another document added (`ImportRuleChangeRecord.addedDrafts`). None on a source that
    /// doesn't take corrections (left out, a duplicate, held).
    static func drafts(of source: ImportItem, in plan: ImportPlan) -> [ImportRuleDraft] {
        guard source.parentId == nil, ImportResolutions.isCorrectable(source) else { return [] }
        let added = plan.state.ruleChanges[source.id]?.addedDrafts ?? []
        return source.ruleDrafts.filter { draft in appliedKinds.contains(draft.kind) && !added.contains { same($0, draft) } }
    }

    /// A draft with its action decoded once (per source, not per document checked).
    struct Rule: Sendable {
        enum Action: Sendable {
            /// The kind filed as (a built-in or custom one), its name and the answer that chooses it.
            case kind(DocumentKindTarget)
            case name(String)
            case link(LinkAction, ImportLinkFamily)
            case figure(FigurePositionAction)
        }

        var key: String
        var action: Action
    }

    /// `drafts` decoded (a draft that doesn't decode, or of a kind not applied, is dropped).
    static func rules(_ drafts: [ImportRuleDraft]) -> [Rule] {
        drafts.compactMap { draft in
            switch draft.kind {
            case .documentKind:
                guard let action = ImportLearning.decode(DocumentKindAction.self, draft.actionJSON) else { return nil }
                return Rule(key: draft.key, action: .kind(DocumentKindTarget(action: action, pendingKindId: draft.pendingKindId)))
            case .issuer:
                return ImportLearning.decode(IssuerAction.self, draft.actionJSON).map { Rule(key: draft.key, action: .name($0.name)) }
            case .link:
                return ImportLearning.decode(LinkAction.self, draft.actionJSON).map { Rule(key: draft.key, action: .link($0, ImportLinkFamily.of($0))) }
            case .figurePosition:
                return ImportLearning.decode(FigurePositionAction.self, draft.actionJSON).map { Rule(key: draft.key, action: .figure($0)) }
            case .statementAccount:
                return nil
            }
        }
    }

    /// The other documents the source's drafts fit, in the plan's order.
    static func fits(from sourceId: UUID, in plan: ImportPlan, context: Context) -> [ImportRuleFit] {
        guard let source = plan.items.first(where: { $0.id == sourceId }) else { return [] }
        return fits(from: source, rules: rules(drafts(of: source, in: plan)), in: plan, context: context)
    }

    private static func fits(from source: ImportItem, rules: [Rule], in plan: ImportPlan, context: Context) -> [ImportRuleFit] {
        guard !rules.isEmpty else { return [] }
        return plan.items.compactMap { item in
            item.id == source.id ? nil : fit(of: item, rules: rules, plan: plan, context: context)
        }
    }

    /// Every source's fits (the documents with drafts of their own), by source; each source's
    /// drafts decoded once.
    static func allFits(in plan: ImportPlan, context: Context) -> [UUID: [ImportRuleFit]] {
        var result: [UUID: [ImportRuleFit]] = [:]
        for item in plan.items {
            let rules = rules(drafts(of: item, in: plan))
            guard !rules.isEmpty else { continue }
            let fits = fits(from: item, rules: rules, in: plan, context: context)
            if !fits.isEmpty { result[item.id] = fits }
        }
        return result
    }

    /// What `rules` would change on `item` (nil: nothing, or the item doesn't take it).
    static func fit(of item: ImportItem, rules: [Rule], plan: ImportPlan, context: Context) -> ImportRuleFit? {
        guard item.parentId == nil, ImportResolutions.isCorrectable(item), !ImportResolutions.isStatement(item),
              let issuer = context.issuers[item.id] else { return nil }
        var changes: [ImportRuleChange] = []
        for rule in rules {
            guard let change = change(rule, on: item, issuer: issuer, plan: plan, context: context),
                  !changes.contains(where: { $0.aspect == change.aspect }) else { continue }
            changes.append(change)
        }
        guard !changes.isEmpty else { return nil }
        // A kind first (the document is read again), then its name, links and figures.
        changes.sort { order($0.aspect) < order($1.aspect) }
        return ImportRuleFit(itemId: item.id, documentName: item.file.fileName, changes: changes)
    }

    private static func order(_ aspect: ImportRuleChange.Aspect) -> Int {
        switch aspect {
        case .kind: return 0
        case .name: return 1
        case .link(.record): return 2
        case .link(.transaction): return 3
        case .figure: return 4
        }
    }

    /// The change `rule` makes on `item` (whose issuer is `issuer`), nil when it changes nothing there.
    static func change(_ rule: Rule, on item: ImportItem, issuer: IssuerKey, plan: ImportPlan,
                       context: Context) -> ImportRuleChange? {
        switch rule.action {
        case .kind(let target):
            guard rule.key == ImportRuleKind.matchKey(issuer: issuer) else { return nil }
            let kind = target.importKind(fileExtension: item.file.fileExtension)
            let chosen = plan.state.chosenKinds.contains(item.id)
                || (item.recognition.confidence == .certain && userRecognitionReasons.contains(item.recognition.reason))
            guard kind != item.recognition.kind, !chosen, !context.recognisesItself.contains(item.id) else { return nil }
            let before = item.kindName
            return ImportRuleChange(aspect: .kind, label: "Kind", before: .text(before),
                                    after: .text(target.name(in: context.kindNames)), resolution: target.resolution)

        case .name(let name):
            guard rule.key == ImportRuleKind.matchKey(issuer: issuer), ImportResolutions.takesIssuerName(item) else { return nil }
            let fact = item.facts.first { $0.field == .issuer }
            guard fact?.source != .user, fact?.value != .text(name) else { return nil }
            var before = ImportRuleChangeValue.none
            if case .text(let read)? = fact?.value { before = .text(read) }
            return ImportRuleChange(aspect: .name, label: "Name", before: before, after: .text(name), resolution: .setIssuer(name))

        case .link(let action, let family):
            guard rule.key == ImportRuleKind.linkKey(issuer: issuer, family: family) else { return nil }
            if let entity = action.entity { return recordLink(entity, on: item) }
            return action.descriptionKey.flatMap { merchantLink($0, on: item, context: context) }

        case .figure(let action):
            guard rule.key == ImportRuleKind.figurePositionKey(issuer: issuer, field: action.field) else { return nil }
            return figure(action, on: item)
        }
    }

    /// The record a learnt link files the document under, when the document offers it and has
    /// no certain link of that type (the learnt rule defers to one).
    private static func recordLink(_ entity: EvidenceEntity, on item: ImportItem) -> ImportRuleChange? {
        guard !item.links.contains(where: { $0.entity.type == entity.type && $0.confidence == .certain }) else { return nil }
        let offered = item.issues.lazy.compactMap { issue -> LinkCandidate? in
            guard ImportResolutions.accepts(issue, .chooseLink(entity)), case .chooseLink(let candidates) = issue.kind else { return nil }
            return candidates.first { $0.entity == entity }
        }.first
        // A link of that type waiting to be checked is what the rule settles.
        let pending = item.links.first { $0.entity.type == entity.type && $0.confidence == .needsReview }
        let unsure = item.links.first { $0.entity == entity && $0.confidence == .needsReview }
        guard let label = offered?.label ?? unsure?.label else { return nil }
        return ImportRuleChange(aspect: .link(.record), label: "Link", before: pending.map { .text("To check: \($0.label)") } ?? .none,
                                after: .text(label), resolution: .chooseLink(entity))
    }

    /// The one "which one?" transaction that is the merchant's for the document's amount read for
    /// sure (as `ImportLearning.applyLinkRules` chooses it).
    private static func merchantLink(_ merchant: String, on item: ImportItem, context: Context) -> ImportRuleChange? {
        guard !item.linksToTransaction,
              let fact = item.facts.first(where: { $0.field == .amount && $0.confidence == .certain && !$0.source.alwaysNeedsReview }),
              case .money(let minor, let currency) = fact.value else { return nil }
        for issue in item.issues {
            guard case .chooseLink(let candidates) = issue.kind, !candidates.isEmpty,
                  candidates.allSatisfy({ $0.entity.type == .transaction }) else { continue }
            let paying = candidates.filter { candidate in
                guard let payment = context.payments[candidate.entity.id] else { return false }
                return payment.merchant == merchant && abs(payment.amountMinorUnits) == abs(minor) && payment.currency == currency
            }
            guard paying.count == 1, let chosen = paying.first else { return nil }
            return ImportRuleChange(aspect: .link(.transaction), label: "Paid by", before: .none, after: .text(chosen.label),
                                    resolution: .chooseLink(chosen.entity))
        }
        return nil
    }

    /// The figure read again at a remembered position on the document's own text, when it differs.
    private static func figure(_ action: FigurePositionAction, on item: ImportItem) -> ImportRuleChange? {
        let field = action.field
        guard LearntFigures.learns(item.recognition.kind), !ImportResolutions.isStatementFigure(field), let text = item.file.text else { return nil }
        let fact = item.facts.first { $0.field == field }
        if let fact, [.user, .intent, .matchedRecord].contains(fact.source) { return nil }
        // A payroll form's positions only fill what its reader didn't find.
        if case .payrollForm = item.recognition.kind, let fact, fact.source != .learntRule { return nil }
        var currency = Currency.eur
        if case .money(_, let read)? = fact?.value { currency = read }
        guard var value = LearntFigures.read(action, field: field, in: text, defaultCurrency: currency) else { return nil }
        // A credit note's figure keeps its sign.
        if case .money(let minor, let read) = value, case .money(let was, _)? = fact?.value, was < 0 { value = .money(-abs(minor), read) }
        guard value != fact?.value, ImportResolutions.takes(value, field, on: item) else { return nil }
        return ImportRuleChange(aspect: .figure(field), label: field.displayName, before: fact.map { .figure($0.value) } ?? .none,
                                after: .figure(value), resolution: .confirmFigure(field, value))
    }

    // MARK: Still applied

    /// Whether every change of `record` still holds on `item` as the rule left it.
    static func isStillApplied(_ record: ImportRuleChangeRecord, on item: ImportItem) -> Bool {
        record.changes.allSatisfy { change in
            switch change.aspect {
            case .kind:
                return item.recognition.kind == record.after.recognition.kind
            case .name:
                return item.facts.first { $0.field == .issuer }?.value == record.after.facts.first { $0.field == .issuer }?.value
            case .link:
                guard case .chooseLink(let entity) = change.resolution else { return false }
                return item.links.contains { $0.entity == entity && $0.confidence == .certain }
            case .figure(let field):
                return item.facts.first { $0.field == field }?.value == record.after.facts.first { $0.field == field }?.value
            }
        }
    }

    /// The same rule (kind, key and action; not the rule it names as replaced).
    static func same(_ a: ImportRuleDraft, _ b: ImportRuleDraft) -> Bool {
        a.kind == b.kind && a.key == b.key && a.actionJSON == b.actionJSON
    }
}

extension ImportPlan {
    /// The item's own drafts its rules are applied to the other documents with (`ImportRuleFits.drafts(of:in:)`).
    public func appliedRuleDrafts(of itemId: UUID) -> [ImportRuleDraft] {
        guard let item = items.first(where: { $0.id == itemId }) else { return [] }
        return ImportRuleFits.drafts(of: item, in: self)
    }

    /// The document whose rule changed the item, and its name, while that change can be undone
    /// ("Changed by your rule from <name>").
    public func ruleChangeSource(of itemId: UUID) -> (id: UUID, name: String)? {
        guard let record = state.ruleChanges[itemId], let item = items.first(where: { $0.id == itemId }),
              ImportRuleFits.isStillApplied(record, on: item) else { return nil }
        return (record.sourceId, record.sourceName)
    }

    /// The documents the source's rule changed that can still be undone, in the plan's order.
    public func ruleChangedItems(from sourceId: UUID) -> [UUID] {
        items.filter { ruleChangeSource(of: $0.id)?.id == sourceId }.map(\.id)
    }

    /// The documents whose rule change an undo on the source (`.unmarkChecked`, `.unmarkAllChecked`)
    /// takes the rule of: the tick drafted a rule they were changed by. Empty: nothing to ask.
    public func ruleChangesUndoneWith(_ resolution: ImportResolution, on sourceId: UUID) -> [UUID] {
        var records: [ImportCheckRecord] = []
        switch resolution {
        case .unmarkChecked(let target):
            guard isMarkedChecked(sourceId, target), let record = state.checks[sourceId]?[target] else { return [] }
            records = [record]
        case .unmarkAllChecked:
            guard isMarkedAllChecked(sourceId), let all = state.checkAlls[sourceId] else { return [] }
            records = all.targets.compactMap { state.checks[sourceId]?[$0] }
        default:
            return []
        }
        let taken = records.flatMap(\.addedDrafts)
        guard !taken.isEmpty else { return [] }
        return ruleChangedItems(from: sourceId).filter { id in
            state.ruleChanges[id]?.sourceDrafts.contains { draft in taken.contains { ImportRuleFits.same($0, draft) } } == true
        }
    }
}

/// The per-file facts the rule fits need that depend only on the file and the planning copy's
/// fixed data (the known parties, the utility providers): its issuer key and whether a built-in
/// recogniser reads it. Worked out once per file (its hash and name) for the planning session,
/// so checking the fits again after every change of the plan doesn't read every file again.
final class ImportRuleFitCache: @unchecked Sendable {
    // @unchecked: every field is guarded by `lock`.
    private let lock = NSLock()
    private var parties: Set<String>?
    private var providers: [UtilityProvider] = []
    private var entries: [String: (issuer: IssuerKey?, recognisesItself: Bool)] = [:]
    private var worked = 0

    /// How many files were worked out (tests).
    var derivations: Int { lock.withLock { worked } }

    /// The file's issuer key and whether a built-in recogniser reads it, worked out once while
    /// `ownNIFs` and `providers` stay the same.
    func entry(for file: ImportFile, ownNIFs: Set<String>, providers: [UtilityProvider]) -> (issuer: IssuerKey?, recognisesItself: Bool) {
        let key = file.sha256 + "|" + file.fileName
        if let found = lock.withLock({ () -> (issuer: IssuerKey?, recognisesItself: Bool)? in
            if parties != ownNIFs || self.providers != providers {
                parties = ownNIFs
                self.providers = providers
                entries = [:]
            }
            return entries[key]
        }) { return found }
        let made = (issuer: IssuerKey.derive(text: file.text, fileName: file.fileName, ownNIFs: ownNIFs),
                    recognisesItself: ImportDetector.recognisesItself(file, providers: providers))
        lock.withLock {
            entries[key] = made
            worked += 1
        }
        return made
    }
}

/// The kind a `documentKind` draft files as: built-in, saved custom, or made in this review.
struct DocumentKindTarget: Sendable {
    var ref: DocumentKindRef
    var pendingKindId: UUID?

    init(action: DocumentKindAction, pendingKindId: UUID?) {
        ref = action.kindRef
        self.pendingKindId = pendingKindId
    }

    /// The kind's name now (`names`: the catalog's and the review's new kinds).
    func name(in names: ImportKindNames) -> String {
        if let pendingKindId { return names.displayName(.customEvidence(.pending(pendingKindId))) }
        switch ref {
        case .builtIn(let kind): return kind.displayName
        case .custom(let id): return names.displayName(.customEvidence(.saved(id)))
        }
    }

    func importKind(fileExtension: String) -> ImportKind {
        if let pendingKindId { return .customEvidence(.pending(pendingKindId)) }
        return ImportResolutions.importKind(for: ref, fileExtension: fileExtension)
    }

    var resolution: ImportResolution {
        if let pendingKindId { return .chooseCustomKind(.pending(pendingKindId)) }
        switch ref {
        case .builtIn(let kind): return .chooseKind(kind)
        case .custom(let id): return .chooseCustomKind(.saved(id))
        }
    }
}
