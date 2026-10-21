import Foundation

public enum ImportResolutionError: Error, Equatable {
    /// No item of the plan has this id.
    case itemNotFound(UUID)
    /// Nothing on the item offers this resolution (or the value doesn't fit the figure).
    case notOffered(ImportResolution)
    /// A transaction chosen to link to doesn't exist.
    case transactionNotFound(Int64)
    /// Import anyway needs a reason that isn't blank.
    case reasonRequired
}

/// The user's answers to an item's questions, as pure edits of the item. Only offered
/// resolutions are taken: what an issue lists in `offers`, plus what every issue of its kind
/// takes (a kind for "what is this?", one of the offered links, targets or figures). A held
/// filed year (`.filedYear`, `"filed-check"`) takes only what it offers: leave out.
public enum ImportResolutions {
    /// The edited item, or `nil` when the item must be read again by its reader (`.chooseKind`,
    /// `.chooseTarget`, `.chooseAccount`, `.saveProfile`). `issueId` answers one issue only; without it the resolution answers
    /// every issue that takes it (`.acknowledge`: the first). Throws `notOffered` otherwise.
    ///
    /// - `.leaveOut`: in or out of the import (again: back in).
    /// - `.acknowledge`: the issue is dropped.
    /// - `.chooseLink`: the link becomes certain ("Chosen by you"), the other candidates go; a
    ///   utility invoice's debit becomes the chosen transaction.
    /// - `.fileWithoutLink`: the issue goes with the links it questioned (and an effect's link);
    ///   on a corrected version, the document is filed only, linked where its original is.
    /// - `.confirmFigure`: the fact becomes the user's (`.user`, `.certain`); the placement and
    ///   the effect's figure follow. Never on a bank statement, nor for a statement's figures
    ///   (opening and closing balance, rows, instalments, fund). `.confirmFigureRemembering`: the same.
    /// - `.setIssuer`: the issuer fact becomes the user's name (`.user`, "Named by you"); never on
    ///   a statement, never blank.
    /// - `.acceptModelReading`: the model's facts and proposed kind become the user's
    ///   (`ImportModelProposals.accept`); correcting a model figure instead (`.confirmFigure`,
    ///   `.setIssuer`) resolves the model's question once no model figure or kind is left.
    /// - `.linkTransactions`, `.addTransactionLink`, `.unlink`: the item's transaction links as
    ///   the user set them (`withTransactionLinks`); `transactions` names each chosen
    ///   transaction that exists (`transactionNotFound` otherwise).
    ///
    /// Corrections (a kind, a figure, a target, links) are taken on any item that is not held
    /// (a filed return, a failed check, an unreadable file: only leaving out), left out or a
    /// duplicate — Ready ones too, not only where a question asks (`isCorrectable`).
    public static func apply(_ resolution: ImportResolution, to item: ImportItem, issueId: String? = nil,
                             transactions: [EvidenceEntity: String] = [:]) throws -> ImportItem? {
        // A file that couldn't be read has nothing to answer: only leaving it out.
        guard resolution == .leaveOut || !isUnreadable(item) else { throw ImportResolutionError.notOffered(resolution) }
        let targeted = item.issues.filter { issueId == nil || $0.id == issueId }
        guard issueId == nil || !targeted.isEmpty else { throw ImportResolutionError.notOffered(resolution) }
        let accepting = targeted.filter { accepts($0, resolution) }
        func refuse() -> ImportResolutionError { .notOffered(resolution) }
        var edited = item

        switch resolution {
        case .leaveOut:
            edited.isLeftOut.toggle()
            return edited

        case .chooseKind:
            guard !accepting.isEmpty || (issueId == nil && (item.recognition.confidence == .needsReview || isCorrectable(item))) else {
                throw refuse()
            }
            return nil

        case .chooseTarget(let kind, _):
            // A correction changes only the target the item's reader reads.
            guard !accepting.isEmpty || (issueId == nil && isCorrectable(item) && correctableTarget(of: item) == kind) else { throw refuse() }
            return nil

        case .linkTransactions(let ids):
            guard issueId == nil, isCorrectable(item), !ids.isEmpty, Set(ids).count == ids.count else { throw refuse() }
            return try withTransactionLinks(item, ids, chosen: Set(ids), labels: transactions)

        case .addTransactionLink(let id):
            guard issueId == nil, isCorrectable(item) else { throw refuse() }
            // The certain transaction links stay (an invoice's own payment first); unsure ones
            // the user didn't keep go, as a "which one?" answered.
            let kept = item.links.filter { $0.entity.type == .transaction && $0.confidence == .certain && $0.entity.id != id }
                .sorted { $0.madeByEffect && !$1.madeByEffect }.map(\.entity.id)
            return try withTransactionLinks(item, kept + [id], chosen: [id], labels: transactions)

        case .unlink(let entity):
            guard issueId == nil, isCorrectable(item), let link = item.links.first(where: { $0.entity == entity }) else { throw refuse() }
            return try unlinked(item, link)

        case .chooseAccount:
            guard !accepting.isEmpty else { throw refuse() }
            return nil

        case .setIssuer(let name):
            // The issuer named by the user: this document's issuer fact (learnt for the issuer on Confirm import).
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isStatement(item), !accepting.isEmpty || (issueId == nil && takesIssuerName(item)) else { throw refuse() }
            edited.issues.removeAll { accepting.contains($0) }
            edited.facts.removeAll { $0.field == .issuer }
            edited.facts.append(ImportFact(field: .issuer, value: .text(trimmed), source: .user, confidence: .certain, reason: "Named by you"))
            if edited.placement != nil {
                edited.placement = ImportNaming.placement(kind: edited.recognition.kind, facts: edited.facts, file: edited.file,
                                                          persons: item.placement?.metadata.persons ?? [])
            }
            edited.effect = effect(edited.effect, with: .issuer, .text(trimmed))
            ImportModelProposals.settle(&edited)
            return edited

        case .importAnyway(let reason):
            // A closing balance that doesn't match, imported anyway: the reason is kept.
            guard !accepting.isEmpty else { throw refuse() }
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ImportResolutionError.reasonRequired }
            edited.issues.removeAll { accepting.contains($0) }
            edited.resolutionNote = trimmed
            return edited

        case .keepRow, .skipRow:
            // A possible duplicate row answered (the pipeline drops a skipped row from its statement).
            guard !accepting.isEmpty else { throw refuse() }
            edited.issues.removeAll { accepting.contains($0) }
            return edited

        case .saveProfile:
            // The statement read again with the layout mapped (saved on Confirm import).
            guard !accepting.isEmpty else { throw refuse() }
            return nil

        case .acknowledge:
            guard let first = accepting.first, let index = edited.issues.firstIndex(of: first) else { throw refuse() }
            edited.issues.remove(at: index)
            return edited

        case .confirmFigureRemembering(let field, let value):
            // Fixed as a confirmed figure; what it teaches is drafted by the pipeline (`ImportLearning.drafts`).
            return try apply(.confirmFigure(field, value), to: item, issueId: issueId, transactions: transactions)

        case .confirmFigure(let field, var value):
            // An issuer's name is kept trimmed (as its learnt rule is), never blank.
            if field == .issuer, case .text(let name) = value {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw refuse() }
                value = .text(trimmed)
            }
            // A statement's figures are what its rows and balances say: never typed over.
            guard takes(value, field, on: item), !isStatementFigure(field), !isStatement(item) else { throw refuse() }
            let unsure = item.facts.contains { $0.field == field && $0.confidence == .needsReview }
            guard !accepting.isEmpty || (issueId == nil && (unsure || isCorrectable(item))) else { throw refuse() }
            edited.issues.removeAll { accepting.contains($0) }
            let existed = edited.facts.contains { $0.field == field }
            edited.facts.removeAll { $0.field == field }
            edited.facts.append(ImportFact(field: field, value: value, source: .user, confidence: .certain,
                                           reason: existed ? "Checked by you" : enteredReason))
            if edited.placement != nil {
                edited.placement = ImportNaming.placement(kind: edited.recognition.kind, facts: edited.facts, file: edited.file,
                                                          persons: item.placement?.metadata.persons ?? [])
            }
            edited.effect = effect(edited.effect, with: field, value)
            // A model figure corrected: the model's reading resolved field by field.
            ImportModelProposals.settle(&edited)
            return edited

        case .acceptModelReading:
            guard !accepting.isEmpty else { throw refuse() }
            return ImportModelProposals.accept(item)

        case .markChecked(let target):
            // The undo record is the pipeline's (`ImportPipeline.resolve`); this is the tick alone.
            guard issueId == nil else { throw refuse() }
            return try ImportChecks.marked(target, on: item)

        case .setBenefits(let rows):
            // A P11D's benefit rows: its effect's benefits, and their total the user's figure.
            guard issueId == nil, isCorrectable(item), case .payrollForm(var confirmed) = item.effect, confirmed.kind == .p11d,
                  rows.allSatisfy({ $0.cashEquivalentMinorUnits >= 0 }) else { throw refuse() }
            confirmed.benefits = rows
            edited.effect = .payrollForm(confirmed)
            edited.facts.removeAll { $0.field == .amount }
            edited.issues.removeAll { $0.kind == .confirmFigure(.amount) || $0.kind == .missingFigure(.amount) || $0.id == noBenefitsIssueId }
            if rows.isEmpty {
                // Every row removed: saving it removes the employment's earlier P11D benefits.
                edited.issues.append(ImportIssue(id: noBenefitsIssueId, kind: .readerProblem(noBenefitsWarning), reason: noBenefitsWarning,
                                                 offers: [.acknowledge]))
            } else {
                // The reader's "No benefits found" no longer holds.
                edited.issues.removeAll { $0.reason.hasPrefix("No benefits found") }
                let total = rows.reduce(0) { $0 + $1.cashEquivalentMinorUnits }
                edited.facts.append(ImportFact(field: .amount, value: .money(total, .gbp), source: .user, confidence: .certain,
                                               reason: benefitsReason))
            }
            // Filed with the total the rows give (as a corrected figure is).
            if edited.placement != nil {
                edited.placement = ImportNaming.placement(kind: edited.recognition.kind, facts: edited.facts, file: edited.file,
                                                          persons: item.placement?.metadata.persons ?? [])
            }
            return edited

        case .unmarkChecked, .markAllChecked, .unmarkAllChecked:
            // Only the pipeline ticks several at once or takes ticks back (it keeps what was there before).
            throw refuse()

        case .chooseLink(let entity):
            let unsure = item.links.contains { $0.entity == entity && $0.confidence == .needsReview }
            guard !accepting.isEmpty || (issueId == nil && unsure) else { throw refuse() }
            let candidates = accepting.flatMap { issue -> [LinkCandidate] in
                if case .chooseLink(let offered) = issue.kind { return offered }
                return []
            }
            let others = Set(candidates.map(\.entity)).subtracting([entity])
            edited.issues.removeAll { accepting.contains($0) }
            edited.links.removeAll { others.contains($0.entity) }
            var invoice: UtilityInvoice?
            if case .utilityInvoice(let proposed) = edited.effect, entity.type == .transaction {
                invoice = proposed
                invoice?.transactionId = entity.id
                edited.effect = .utilityInvoice(invoice!)
            }
            if let index = edited.links.firstIndex(where: { $0.entity == entity }) {
                edited.links[index].confidence = .certain
                if !edited.links[index].reasons.contains(chosenReason) { edited.links[index].reasons.append(chosenReason) }
                if invoice != nil { edited.links[index].madeByEffect = true }
            } else {
                let candidate = candidates.first { $0.entity == entity }
                let role = item.recognition.kind == .transferAdvice ? RentCreditEvidence.adviceRole : nil
                edited.links.append(ProposedLink(entity: entity, role: role, label: candidate?.label ?? "\(entity.type.displayName) #\(entity.id)",
                                                 confidence: .certain, reasons: (candidate?.reasons ?? []) + [chosenReason],
                                                 madeByEffect: invoice != nil))
            }
            return edited

        case .fileWithoutLink:
            let unsure = item.links.filter { $0.confidence == .needsReview }
            guard !accepting.isEmpty || (issueId == nil && !unsure.isEmpty) else { throw refuse() }
            var dropped = Set(issueId == nil ? unsure.map(\.entity) : [])
            for issue in accepting {
                if case .chooseLink(let candidates) = issue.kind { dropped.formUnion(candidates.map(\.entity)) }
                if let id = transactionId(inIssueId: issue.id) { dropped.insert(.transaction(id)) }
            }
            edited.issues.removeAll { accepting.contains($0) }
            if let corrected = accepting.first(where: { ImportDuplicates.isCorrectedVersion($0.id) }) {
                // A corrected version of a recorded invoice or receipt, filed only: linked where
                // the original is, recording nothing (its figures stay as recorded); attached to
                // a recorded invoice that has no document.
                edited.issues.removeAll { issue in
                    switch issue.kind {
                    case .missingFigure, .chooseLink, .chooseTarget(.provider, _), .chooseTarget(.property, _): return true
                    default: return transactionId(inIssueId: issue.id) != nil
                    }
                }
                // Still that invoice for the duplicate pass: a copy of it is a copy.
                if case .utilityInvoice(let invoice) = item.effect { edited.identityProviderId = invoice.providerId }
                edited.effect = corrected.documentOnlyEffect ?? .file
                edited.links = corrected.documentOnlyLinks
                let note = correctedVersionNote(item.recognition.kind)
                if !edited.notes.contains(note) { edited.notes.append(note) }
                return edited
            }
            if accepting.contains(where: { $0.id == UtilityInvoiceImportReader.documentOnlyIssueId }) {
                // "File the document only": no invoice record, so its missing figures and
                // provider or property don't matter any more.
                edited.issues.removeAll { issue in
                    switch issue.kind {
                    case .missingFigure, .chooseTarget(.provider, _), .chooseTarget(.property, _): return true
                    default: return false
                    }
                }
                edited.links.removeAll { $0.entity.type == .transaction }
                edited.effect = .file
                if !edited.notes.contains(UtilityInvoiceImportReader.documentOnlyNote) {
                    edited.notes.append(UtilityInvoiceImportReader.documentOnlyNote)
                }
                return edited
            }
            let removed = edited.links.filter { dropped.contains($0.entity) }
            edited.links.removeAll { dropped.contains($0.entity) }
            switch edited.effect {
            case .utilityInvoice(var invoice):
                if let id = invoice.transactionId, dropped.contains(.transaction(id)) {
                    invoice.transactionId = nil
                    edited.effect = .utilityInvoice(invoice)
                }
            case .transferAdvice:
                // The advice's effect is its link to the credit: without it only the document is filed.
                if removed.contains(where: \.madeByEffect) {
                    edited.effect = .file
                    edited.links.removeAll(where: \.madeByEffect)
                }
            default:
                break
            }
            if !edited.links.contains(where: { $0.entity.type == .transaction }), !edited.notes.contains(withoutLinkNote) {
                edited.notes.append(withoutLinkNote)
            }
            return edited
        }
    }

    static let chosenReason = "Chosen by you"
    /// The reason of a figure the user entered where none was read.
    static let enteredReason = "Entered by you"
    /// A P11D's total as the benefit rows the user set give it (`.setBenefits`): its own reason, so
    /// a "Check it" ticked before isn't taken for still standing (and undone over the edited rows).
    public static let benefitsReason = "Benefits set by you"
    /// A P11D left with no benefit rows (`.setBenefits([])`): a warning to acknowledge.
    static let noBenefitsIssueId = "noBenefits"
    public static let noBenefitsWarning = "No benefits: the earlier benefits for this employment will be removed"
    /// The reason a link or a choice made by the user carries.
    public static var chosenReasonText: String { chosenReason }

    /// Whether the item takes corrections beyond its questions: not held (a filed-year hold,
    /// a failed check, an unreadable file), not left out, not a duplicate.
    public static func isCorrectable(_ item: ImportItem) -> Bool {
        !item.isLeftOut && item.duplicate == nil && !isUnreadable(item) && !item.issues.contains { onlyLeavesOut($0, in: item) }
    }

    /// Whether the item takes an issuer's name from the user (`.setIssuer` as a correction): a
    /// correctable document that isn't a bank statement (staged, or recognised as one).
    public static func takesIssuerName(_ item: ImportItem) -> Bool {
        guard isCorrectable(item), !isStatement(item) else { return false }
        return ![.bankStatementCSV, .bankStatementPDF, .bbvaStatement].contains(item.recognition.kind)
    }

    /// The target a correction can change on the item (`.chooseTarget`), when its reader reads
    /// one: an invoice's provider, a payroll form's person, a statement's account, a rent
    /// receipt's tenancy, a receipts export's property.
    public static func correctableTarget(of item: ImportItem) -> ImportTargetKind? {
        switch item.recognition.kind {
        case .utilityInvoice: return .provider
        case .payrollForm: return .person
        case .bankStatementCSV, .bankStatementPDF: return .account
        case .rentReceiptPDF: return .tenancy
        case .rentReceiptsExport: return .property
        default: return nil
        }
    }

    /// The transactions a link change names (each must exist).
    public static func chosenTransactions(_ resolution: ImportResolution) -> [Int64] {
        switch resolution {
        case .linkTransactions(let ids): return ids
        case .addTransactionLink(let id): return [id]
        default: return []
        }
    }

    /// The item linked to the transactions `ids`, in order, instead of its transaction links
    /// (its other links stay). `chosen`: the ones the user picked now — certain, "Chosen by
    /// you" — the others kept as they were. Every linked transaction is one of the document's
    /// payments, with equal standing: a utility invoice records exactly one as its debit
    /// (`transactionId`), several as plain payment links (none its own); a transfer advice keeps
    /// its credits when all are still chosen (else only the document is filed, linked as the
    /// advice of each chosen credit). The "which one?" questions about transactions are answered.
    static func withTransactionLinks(_ item: ImportItem, _ ids: [Int64], chosen: Set<Int64>,
                                     labels: [EvidenceEntity: String]) throws -> ImportItem {
        var edited = item
        let previous = item.links.filter { $0.entity.type == .transaction }
        edited.issues.removeAll { issue in
            if case .chooseLink(let candidates) = issue.kind {
                return !candidates.isEmpty && candidates.allSatisfy { $0.entity.type == .transaction }
            }
            return false
        }
        edited.links.removeAll { $0.entity.type == .transaction }
        var adviceRole: String?
        if case .transferAdvice = item.effect {
            adviceRole = RentCreditEvidence.adviceRole
            let credits = Set(previous.filter(\.madeByEffect).map(\.entity.id))
            if !credits.isSubset(of: Set(ids)) { edited.effect = .file }
        }
        for id in ids {
            let entity = EvidenceEntity.transaction(id)
            let before = previous.first { $0.entity == entity }
            if chosen.contains(id) || before == nil {
                guard let label = labels[entity] else { throw ImportResolutionError.transactionNotFound(id) }
                var link = before ?? ProposedLink(entity: entity, role: adviceRole, label: label, confidence: .certain, reasons: [])
                link.label = label
                link.confidence = .certain
                if !link.reasons.contains(chosenReason) { link.reasons.append(chosenReason) }
                edited.links.append(link)
            } else if var link = before {
                link.confidence = .certain
                edited.links.append(link)
            }
        }
        // An advice filed as a document only: its credits are plain links (as its advice).
        if item.recognition.kind == .transferAdvice, edited.effect == .file {
            for i in edited.links.indices { edited.links[i].madeByEffect = false }
        }
        withPayments(&edited)
        edited.notes.removeAll { $0.hasPrefix("Not linked:") }
        return edited
    }

    /// The item without `link`. A utility invoice's debit unlinked: the one transaction left,
    /// if exactly one, becomes its debit. An advice's credit or a rent receipt PDF's receipt
    /// unlinked: only the document is filed (the advice's other credits stay linked as its
    /// advice). A link the effect itself makes otherwise (a payroll form's employment) isn't
    /// removed this way: leave the item out or change its target.
    static func unlinked(_ item: ImportItem, _ link: ProposedLink) throws -> ImportItem {
        guard canUnlink(link, in: item) else { throw ImportResolutionError.notOffered(.unlink(link.entity)) }
        var edited = item
        if link.madeByEffect, item.effect.isLinking {
            edited.effect = .file
            for i in edited.links.indices { edited.links[i].madeByEffect = false }
        }
        edited.links.removeAll { $0.entity == link.entity }
        edited.issues.removeAll { issue in
            if case .chooseLink(let candidates) = issue.kind { return candidates.allSatisfy { $0.entity == link.entity } }
            return false
        }
        if case .utilityInvoice(var invoice) = edited.effect, invoice.transactionId == link.entity.id, link.entity.type == .transaction {
            invoice.transactionId = nil
            edited.effect = .utilityInvoice(invoice)
        }
        withPayments(&edited)
        if link.entity.type == .transaction, !edited.links.contains(where: { $0.entity.type == .transaction }),
           !edited.notes.contains(withoutLinkNote) {
            edited.notes.append(withoutLinkNote)
        }
        return edited
    }

    /// Whether "Unlink" takes the link off the item: any link of a correctable item, except
    /// one its effect makes that isn't a link of its own (a payroll form's employment).
    public static func canUnlink(_ link: ProposedLink, in item: ImportItem) -> Bool {
        guard isCorrectable(item), item.links.contains(where: { $0.entity == link.entity }) else { return false }
        guard link.madeByEffect else { return true }
        if case .utilityInvoice = item.effect { return true }
        return item.effect.isLinking
    }

    /// A utility invoice's payments after the user changed its links: exactly one certain
    /// transaction link is the invoice's debit (`transactionId`, made by recording it); with
    /// several, each is a plain payment link and the invoice records none of them (the
    /// invoice's payments are then its document's linked debits, `Recharges.payments`).
    private static func withPayments(_ item: inout ImportItem) {
        guard case .utilityInvoice(var invoice) = item.effect else { return }
        let payments = item.links.indices.filter { item.links[$0].entity.type == .transaction && item.links[$0].confidence == .certain }
        for i in payments { item.links[i].madeByEffect = false }
        if payments.count == 1, let only = payments.first {
            invoice.transactionId = item.links[only].entity.id
            item.links[only].madeByEffect = true
        } else {
            invoice.transactionId = nil
        }
        item.effect = .utilityInvoice(invoice)
    }
    /// The issue of a file that couldn't be read, and the placeholder hash it gets.
    static let unreadableIssueId = "unreadable"
    static let unreadableHashPrefix = "unreadable:"

    static func isUnreadable(_ item: ImportItem) -> Bool {
        item.file.sha256.hasPrefix(unreadableHashPrefix) || item.issues.contains { $0.id == unreadableIssueId }
    }
    static let withoutLinkNote = "Not linked: you chose to file it without a link"

    /// Whether the item is a corrected version filed as a document only (its note says so).
    static func isFiledAsCorrectedVersion(_ item: ImportItem) -> Bool {
        let filedOnly: Bool
        switch item.effect {
        case .file, .attachToInvoice: filedOnly = true
        default: filedOnly = false
        }
        return filedOnly && item.notes.contains(correctedVersionNote(item.recognition.kind))
    }

    /// The note of a corrected version filed as a document only.
    static func correctedVersionNote(_ kind: ImportKind) -> String {
        let record: String
        switch kind {
        case .utilityInvoice: record = "invoice"
        case .rentReceiptPDF: record = "receipt"
        default: record = "record"
        }
        return "Recorded figures unchanged: correct the \(record) on its screen if needed"
    }

    /// A filed-year hold: the item would change a filed (or paid) return, or that couldn't be
    /// checked (`FiledYearGuard`). Leaving it out is its only answer.
    public static func isFiledYearHold(_ issue: ImportIssue) -> Bool {
        if case .filedYear = issue.kind { return true }
        return issue.id == FiledYearGuard.checkFailedIssueId
    }

    /// Whether leaving the item out is the only answer the issue takes: a filed-year hold, or
    /// any issue of a file that couldn't be read.
    public static func onlyLeavesOut(_ issue: ImportIssue, in item: ImportItem) -> Bool {
        isFiledYearHold(issue) || isUnreadable(item)
    }

    /// Whether `issue` takes `resolution`: what it offers, else what its kind takes. Filed-year
    /// holds take only what they offer.
    public static func accepts(_ issue: ImportIssue, _ resolution: ImportResolution) -> Bool {
        if issue.offers.contains(resolution) { return true }
        if case .filedYear = issue.kind { return false }
        if issue.id == FiledYearGuard.checkFailedIssueId { return false }
        switch (issue.kind, resolution) {
        case (.unknownKind, .chooseKind), (.kindMismatch, .chooseKind), (.kindMismatch, .acknowledge), (.confirmModelReading, .acceptModelReading):
            return true
        case (.confirmFigure(let field), .confirmFigure(let chosen, let value)), (.missingFigure(let field), .confirmFigure(let chosen, let value)):
            return field == chosen && fits(value, chosen)
        case (.confirmFigure(let field), .confirmFigureRemembering(let chosen, let value)),
             (.missingFigure(let field), .confirmFigureRemembering(let chosen, let value)):
            return field == chosen && fits(value, chosen)
        case (.confirmFigure(.issuer), .setIssuer), (.missingFigure(.issuer), .setIssuer):
            return true
        case (.chooseLink(let candidates), .chooseLink(let entity)):
            return candidates.contains { $0.entity == entity }
        case (.chooseTarget(let kind, let options), .chooseTarget(let chosen, let id)):
            return kind == chosen && options.contains(id)
        case (.statement(.balanceMismatch), .importAnyway), (.statement(.possibleDuplicate), .keepRow), (.statement(.possibleDuplicate), .skipRow):
            return true
        case (.statement(.noProfile(let format, let accountId)), .saveProfile(let profile)),
             (.statement(.remap(let format, let accountId)), .saveProfile(let profile)):
            // A layout for the statement's own account and format.
            return profile.accountId == accountId && profile.format == format
        default:
            return false
        }
    }

    /// The import kind a chosen document kind is read as.
    static func importKind(for kind: DocumentKind, fileExtension: String) -> ImportKind {
        switch kind {
        case .p60: return .payrollForm(.p60)
        case .p45: return .payrollForm(.p45)
        case .p11d: return .payrollForm(.p11d)
        case .utilityInvoice: return .utilityInvoice
        case .bankStatement: return fileExtension == "csv" ? .bankStatementCSV : .bankStatementPDF
        default: return .evidence(kind)
        }
    }

    /// The transaction a duplicate-pass issue is about ("transactionHasDocument.<id>", "sharedTransaction.<id>").
    static func transactionId(inIssueId id: String) -> Int64? {
        for prefix in ["transactionHasDocument.", "sharedTransaction."] where id.hasPrefix(prefix) {
            return Int64(id.dropFirst(prefix.count))
        }
        return nil
    }

    /// A bank statement's own figures (read from it, checked by its rows: never confirmed by hand).
    static func isStatementFigure(_ field: ImportFigureField) -> Bool {
        [.openingBalance, .closingBalance, .rows, .instalments, .fund].contains(field)
    }

    /// Whether the item is a staged bank statement (UK or BBVA).
    static func isStatement(_ item: ImportItem) -> Bool {
        switch item.effect {
        case .ukStatement, .bbvaStatement: return true
        default: return false
        }
    }

    /// Whether the value is of the figure's type.
    static func fits(_ value: ImportFactValue, _ field: ImportFigureField) -> Bool {
        switch (field, value) {
        case (.docDate, .date), (.periodStart, .date), (.periodEnd, .date): return true
        case (.amount, .money), (.pay, .money), (.taxDeducted, .money): return true
        case (.taxYear, .year): return true
        case (.openingBalance, .money), (.closingBalance, .money), (.accountTotal, .money): return true
        case (.rows, .text), (.instalments, .text), (.fund, .text): return true
        case (.currency, .text), (.invoiceNumber, .text), (.receiptNumber, .text), (.reference, .text), (.issuer, .text),
             (.person, .text), (.taxCode, .text): return true
        default: return false
        }
    }

    /// Whether the item takes the value as the figure (confirmed by the user, or the model's
    /// accepted): of the figure's type (`fits`) and, for a payroll form's reference, a PAYE
    /// reference like 123/AB456 (its form couldn't be saved otherwise).
    static func takes(_ value: ImportFactValue, _ field: ImportFigureField, on item: ImportItem) -> Bool {
        guard fits(value, field) else { return false }
        guard field == .reference, case .payrollForm = item.recognition.kind, case .text(let reference) = value else { return true }
        do {
            _ = try Employments.normalizedPAYEReference(reference)
            return true
        } catch {
            return false
        }
    }

    /// The effect with a confirmed figure: a utility invoice's or a payroll form's own field.
    static func effect(_ effect: ImportEffect, with field: ImportFigureField, _ value: ImportFactValue) -> ImportEffect {
        switch effect {
        case .utilityInvoice(var invoice):
            switch (field, value) {
            case (.amount, .money(let amount, _)): invoice.amountMinorUnits = amount
            case (.docDate, .date(let date)): invoice.issueDate = date
            case (.periodStart, .date(let date)): invoice.periodStart = date
            case (.periodEnd, .date(let date)): invoice.periodEnd = date
            case (.invoiceNumber, .text(let number)): invoice.invoiceNumber = number
            default: break
            }
            return .utilityInvoice(invoice)
        case .payrollForm(var confirmed):
            switch (field, value) {
            case (.issuer, .text(let employer)): confirmed.employerName = employer
            case (.taxYear, .year(let year)): confirmed.startYear = year
            case (.reference, .text(let reference)): confirmed.payeReference = reference
            case (.pay, .money(let pay, _)): confirmed.payMinorUnits = pay
            case (.taxDeducted, .money(let tax, _)): confirmed.taxDeductedMinorUnits = tax
            case (.taxCode, .text(let code)): confirmed.taxCode = code
            case (.docDate, .date(let date)) where confirmed.kind == .p45: confirmed.leavingDate = date
            default: break
            }
            return .payrollForm(confirmed)
        default:
            return effect
        }
    }
}
