import Foundation

public enum ImportResolutionError: Error, Equatable {
    /// No item of the plan has this id.
    case itemNotFound(UUID)
    /// Nothing on the item offers this resolution (or the value doesn't fit the figure).
    case notOffered(ImportResolution)
}

/// The user's answers to an item's questions, as pure edits of the item. Only offered
/// resolutions are taken: what an issue lists in `offers`, plus what every issue of its kind
/// takes (a kind for "what is this?", one of the offered links, targets or figures). A held
/// filed year (`.filedYear`, `"filed-check"`) takes only what it offers: leave out.
public enum ImportResolutions {
    /// The edited item, or `nil` when the item must be read again by its reader (`.chooseKind`,
    /// `.chooseTarget`). `issueId` answers one issue only; without it the resolution answers
    /// every issue that takes it (`.acknowledge`: the first). Throws `notOffered` otherwise.
    ///
    /// - `.leaveOut`: in or out of the import (again: back in).
    /// - `.acknowledge`: the issue is dropped.
    /// - `.chooseLink`: the link becomes certain ("Chosen by you"), the other candidates go; a
    ///   utility invoice's debit becomes the chosen transaction.
    /// - `.fileWithoutLink`: the issue goes with the links it questioned (and an effect's link);
    ///   on a corrected version, the document is filed only, linked where its original is.
    /// - `.confirmFigure`: the fact becomes the user's (`.user`, `.certain`); the placement and
    ///   the effect's figure follow.
    public static func apply(_ resolution: ImportResolution, to item: ImportItem, issueId: String? = nil) throws -> ImportItem? {
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
            guard !accepting.isEmpty || (issueId == nil && item.recognition.confidence == .needsReview) else { throw refuse() }
            return nil

        case .chooseTarget:
            guard !accepting.isEmpty else { throw refuse() }
            return nil

        case .acknowledge:
            guard let first = accepting.first, let index = edited.issues.firstIndex(of: first) else { throw refuse() }
            edited.issues.remove(at: index)
            return edited

        case .confirmFigure(let field, let value):
            guard fits(value, field) else { throw refuse() }
            let unsure = item.facts.contains { $0.field == field && $0.confidence == .needsReview }
            guard !accepting.isEmpty || (issueId == nil && unsure) else { throw refuse() }
            edited.issues.removeAll { accepting.contains($0) }
            let existed = edited.facts.contains { $0.field == field }
            edited.facts.removeAll { $0.field == field }
            edited.facts.append(ImportFact(field: field, value: value, source: .user, confidence: .certain,
                                           reason: existed ? "Checked by you" : "Entered by you"))
            if edited.placement != nil {
                edited.placement = ImportNaming.placement(kind: edited.recognition.kind, facts: edited.facts, file: edited.file,
                                                          persons: item.placement?.metadata.persons ?? [])
            }
            edited.effect = effect(edited.effect, with: field, value)
            return edited

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
            if let corrected = accepting.first(where: { $0.id == ImportDuplicates.correctedVersionIssueId }) {
                // A corrected version of a recorded invoice or receipt, filed only: linked where
                // the original is, recording nothing (its figures stay as recorded).
                edited.issues.removeAll { issue in
                    switch issue.kind {
                    case .missingFigure, .chooseLink, .chooseTarget(.provider, _), .chooseTarget(.property, _): return true
                    default: return transactionId(inIssueId: issue.id) != nil
                    }
                }
                // Still that invoice for the duplicate pass: a copy of it is a copy.
                if case .utilityInvoice(let invoice) = item.effect { edited.identityProviderId = invoice.providerId }
                edited.effect = .file
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
    /// The issue of a file that couldn't be read, and the placeholder hash it gets.
    static let unreadableIssueId = "unreadable"
    static let unreadableHashPrefix = "unreadable:"

    static func isUnreadable(_ item: ImportItem) -> Bool {
        item.file.sha256.hasPrefix(unreadableHashPrefix) || item.issues.contains { $0.id == unreadableIssueId }
    }
    static let withoutLinkNote = "Not linked: you chose to file it without a link"

    /// Whether the item is a corrected version filed as a document only (its note says so).
    static func isFiledAsCorrectedVersion(_ item: ImportItem) -> Bool {
        item.effect == .file && item.notes.contains(correctedVersionNote(item.recognition.kind))
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
        case (.unknownKind, .chooseKind), (.kindMismatch, .chooseKind), (.kindMismatch, .acknowledge):
            return true
        case (.confirmFigure(let field), .confirmFigure(let chosen, let value)), (.missingFigure(let field), .confirmFigure(let chosen, let value)):
            return field == chosen && fits(value, chosen)
        case (.chooseLink(let candidates), .chooseLink(let entity)):
            return candidates.contains { $0.entity == entity }
        case (.chooseTarget(let kind, let options), .chooseTarget(let chosen, let id)):
            return kind == chosen && options.contains(id)
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

    /// Whether the value is of the figure's type.
    static func fits(_ value: ImportFactValue, _ field: ImportFigureField) -> Bool {
        switch (field, value) {
        case (.docDate, .date), (.periodStart, .date), (.periodEnd, .date): return true
        case (.amount, .money), (.pay, .money), (.taxDeducted, .money): return true
        case (.taxYear, .year): return true
        case (.currency, .text), (.invoiceNumber, .text), (.receiptNumber, .text), (.reference, .text), (.issuer, .text),
             (.person, .text): return true
        default: return false
        }
    }

    /// The effect with a confirmed figure: a utility invoice's or a payroll form's own field.
    private static func effect(_ effect: ImportEffect, with field: ImportFigureField, _ value: ImportFactValue) -> ImportEffect {
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
            case (.docDate, .date(let date)) where confirmed.kind == .p45: confirmed.leavingDate = date
            default: break
            }
            return .payrollForm(confirmed)
        default:
            return effect
        }
    }
}
