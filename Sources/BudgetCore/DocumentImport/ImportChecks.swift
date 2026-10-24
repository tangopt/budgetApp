import Foundation

/// What a "Check it" ticks off in place: one figure, or what the document was recognised as.
public enum ImportCheckTarget: Hashable, Sendable {
    case figure(ImportFigureField)
    case recognition
}

/// A "Check it" ticked off, kept in the plan's state (`ImportPlanState.checks`) so it can be undone
/// while the review is open: the item before and after (the whole item comes back when nothing
/// else changed since), and what the check changed (put back one by one otherwise).
struct ImportCheckRecord: Equatable, Sendable {
    var before: ImportItem
    var after: ImportItem
    var priorFact: ImportFact?
    var priorRecognition: ImportRecognition?
    /// The questions the check answered (a question about that figure, the model's question).
    var removedIssues: [ImportIssue]
    /// The rules the check teaches (a model kind or issuer name checked): gone with the undo.
    var addedDrafts: [ImportRuleDraft]
}

/// "Mark all as checked" on one document: the item before and after (the whole item comes back
/// when nothing changed since), and the ticks it made, in order (each with its own record in
/// `ImportPlanState.checks`, so each can still be taken back on its own).
struct ImportCheckAllRecord: Equatable, Sendable {
    var before: ImportItem
    var after: ImportItem
    var targets: [ImportCheckTarget]
}

/// "Check it" ticked off without retyping (`.markChecked`) and un-ticked (`.unmarkChecked`): a
/// figure or a recognition to check — read by text recognition, from the file name or by the
/// on-device model — becomes the user's, certain ("Checked by you"), as confirming the same value
/// would; checking a model field accepts that field (its kind and issuer name drafted as
/// `.acceptModelReading` drafts them). Never on an item held by a filed year, a failed check or
/// an unreadable file, nor on a left-out or duplicate one (`ImportResolutions.isCorrectable`).
public enum ImportChecks {
    public static let checkedReason = "Checked by you"

    /// Whether `target` on `item` can be ticked off: it waits to be checked.
    public static func canMark(_ target: ImportCheckTarget, on item: ImportItem) -> Bool {
        (try? marked(target, on: item)) != nil
    }

    /// Every "Check it" on the item that can be ticked off now: its recognition, then its figures to
    /// check (in the item's order). Never a question that needs a choice (which debit, which
    /// account, import anyway, keep or skip, a kind mismatch): those aren't checks. Empty on a held item.
    public static func tickable(_ item: ImportItem) -> [ImportCheckTarget] {
        var targets: [ImportCheckTarget] = []
        if canMark(.recognition, on: item) { targets.append(.recognition) }
        for fact in item.facts where fact.confidence == .needsReview && canMark(.figure(fact.field), on: item) {
            targets.append(.figure(fact.field))
        }
        return targets
    }

    /// Whether "Mark all as checked" is offered: two checks or more (one has its own pill).
    public static func canMarkAll(_ item: ImportItem) -> Bool { tickable(item).count >= 2 }

    /// `item` with `target` ticked off (nil: nothing to tick off there). Drafts are added by the pipeline.
    static func marked(_ target: ImportCheckTarget, on item: ImportItem) throws -> ImportItem {
        let refused = ImportResolutionError.notOffered(.markChecked(target))
        guard ImportResolutions.isCorrectable(item) else { throw refused }
        var edited = item
        switch target {
        case .figure(let field):
            guard let index = item.facts.firstIndex(where: { $0.field == field }) else { throw refused }
            let prior = item.facts[index]
            guard prior.confidence == .needsReview, !ImportResolutions.isStatementFigure(field), !ImportResolutions.isStatement(item),
                  ImportResolutions.takes(prior.value, field, on: item) else { throw refused }
            var fact = ImportFact(field: field, value: prior.value, source: .user, confidence: .certain, reason: checkedReason)
            fact.fromModel = prior.source == .model
            edited.facts[index] = fact
            edited.issues.removeAll { $0.kind == .confirmFigure(field) || $0.kind == .missingFigure(field) }
            edited.effect = ImportResolutions.effect(edited.effect, with: field, prior.value)
        case .recognition:
            guard item.recognition.confidence == .needsReview, item.recognition.kind != .unknown else { throw refused }
            edited.recognition.confidence = .certain
            edited.recognition.reason = item.recognition.proposedByModel ? ImportModelProposals.acceptedReason : checkedReason
        }
        if edited.placement != nil {
            edited.placement = ImportNaming.placement(kind: edited.recognition.kind, facts: edited.facts, file: edited.file,
                                                      persons: item.placement?.metadata.persons ?? [],
                                                customKind: item.placement?.customKind)
        }
        ImportModelProposals.settle(&edited)
        return edited
    }

    /// The rules checking `target` teaches: a model kind (as `.chooseKind`) or a model issuer
    /// name (as `.setIssuer`), as accepting the model's reading would.
    static func drafts(_ target: ImportCheckTarget, before: ImportItem, after: ImportItem, issuer: IssuerKey?) -> [ImportRuleDraft] {
        switch target {
        case .recognition:
            guard before.recognition.proposedByModel, let kind = DocumentIdentity.documentKind(of: after.recognition.kind), kind != .other else { return [] }
            return ImportLearning.drafts(for: after, resolution: .chooseKind(kind), issuer: issuer)
        case .figure(.issuer):
            guard before.facts.first(where: { $0.field == .issuer })?.source == .model,
                  case .text(let name)? = after.facts.first(where: { $0.field == .issuer })?.value else { return [] }
            return ImportLearning.drafts(for: after, resolution: .setIssuer(name), issuer: issuer)
        case .figure:
            return []
        }
    }

    /// Whether `target` on `item` is still as the check left it (so it can be un-ticked).
    static func isStillChecked(_ record: ImportCheckRecord, _ target: ImportCheckTarget, on item: ImportItem) -> Bool {
        guard ImportResolutions.isCorrectable(item) else { return false }
        switch target {
        case .figure(let field):
            guard let prior = record.priorFact, let fact = item.facts.first(where: { $0.field == field }) else { return false }
            return fact.source == .user && fact.reason == checkedReason && fact.value == prior.value
        case .recognition:
            guard let prior = record.priorRecognition else { return false }
            return item.recognition.kind == prior.kind && item.recognition.confidence == .certain
                && item.recognition.reason == record.after.recognition.reason
        }
    }

    /// `item` with the check undone: the item as it was when nothing changed since, else the
    /// target, its questions and its drafts put back.
    static func unmarked(_ record: ImportCheckRecord, _ target: ImportCheckTarget, on item: ImportItem) -> ImportItem {
        if item == record.after { return record.before }
        var restored = item
        switch target {
        case .figure(let field):
            if let prior = record.priorFact, let index = restored.facts.firstIndex(where: { $0.field == field }) {
                restored.facts[index] = prior
                restored.effect = ImportResolutions.effect(restored.effect, with: field, prior.value)
            }
        case .recognition:
            if let prior = record.priorRecognition { restored.recognition = prior }
        }
        for issue in record.removedIssues where !restored.issues.contains(where: { $0.id == issue.id }) {
            restored.issues.append(issue)
        }
        restored.ruleDrafts.removeAll { record.addedDrafts.contains($0) }
        // What the model read waits again (its question answered meanwhile, "Use these"): asked again.
        if ImportModelProposals.waits(restored), !restored.issues.contains(where: { $0.kind == .confirmModelReading }) {
            restored.issues.append(record.before.issues.first { $0.kind == .confirmModelReading }
                ?? ImportIssue(id: ImportModelProposals.issueId, kind: .confirmModelReading, reason: ImportModelProposals.issueReason))
        }
        if restored.placement != nil {
            restored.placement = ImportNaming.placement(kind: restored.recognition.kind, facts: restored.facts, file: restored.file,
                                                        persons: item.placement?.metadata.persons ?? [],
                                                customKind: item.placement?.customKind)
        }
        return restored
    }
}

extension ImportPlan {
    /// Whether "Mark all as checked" was used on the item and some of its ticks can still be taken back (`.unmarkAllChecked`).
    public func isMarkedAllChecked(_ itemId: UUID) -> Bool {
        guard let all = state.checkAlls[itemId] else { return false }
        return all.targets.contains { isMarkedChecked(itemId, $0) }
    }

    /// Whether `target` of the item was ticked off in this review and can be un-ticked (`.unmarkChecked`).
    public func isMarkedChecked(_ itemId: UUID, _ target: ImportCheckTarget) -> Bool {
        guard let record = state.checks[itemId]?[target], let item = items.first(where: { $0.id == itemId }) else { return false }
        return ImportChecks.isStillChecked(record, target, on: item)
    }
}
