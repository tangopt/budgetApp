import Foundation

/// The on-device model in the import (`DocumentModelReading`): what nothing built in and no learnt
/// rule recognises — `.unknown` or `.evidence(.other)` with text — is asked about, outside the
/// rolled-back write pass, off the main actor, at most `concurrentCalls` at once, each with a hard
/// timeout (no answer when it runs out). Its guess only proposes: a kind is the item's recognition
/// to check ("Proposed by the on-device model"), each figure a `.model` fact filling one the reader
/// didn't read, and the item asks "Check what the on-device model read" (`confirmModelReading`)
/// until no model fact or recognition is left — accepted (`.acceptModelReading`) or corrected.
/// An unavailable model says why on the item's "what is this?" question.
public enum ImportModelProposals {
    public static let recognitionReason = "Proposed by the on-device model"
    public static let issueId = "confirmModelReading"
    public static let issueReason = "Check what the on-device model read"
    /// A proposed kind the user accepted.
    public static let acceptedReason = "Proposed by the on-device model, checked by you"
    static let factReason = "Read by the on-device model"
    static let unknownKindIssueId = "unknownKind"

    /// Model calls at once.
    static let concurrentCalls = 2
    /// The per-document deadline (the reader has its own; this one holds for any reader).
    static let timeoutNanoseconds: UInt64 = 20 * 1_000_000_000

    /// "Asking the on-device model about <file>", the progress's current file.
    public static func progressText(_ fileName: String) -> String { "Asking the on-device model about \(fileName)" }

    /// Whether `issue` is the "what is this?" question of an item the model couldn't be asked
    /// about: its reason is the model's availability message (`DocumentModelAvailability`).
    public static func isUnavailableNotice(_ issue: ImportIssue) -> Bool {
        guard case .unknownKind = issue.kind else { return false }
        return DocumentModelAvailability.unavailableMessages.contains(issue.reason)
    }

    /// The kinds the model may name: a bank statement is read only by its readers (a layout to map).
    static var kinds: [DocumentKind] { DocumentKind.allCases.filter { $0 != .bankStatement } }

    /// What asking came to.
    enum Outcome: Equatable, Sendable {
        case guess(DocumentModelGuess)
        case unavailable(String)
        case noAnswer
    }

    /// Whether a file recognised so is asked: unknown or "other", not by a learnt rule, with text.
    static func asks(_ file: ImportFile, _ recognition: ImportRecognition) -> Bool {
        guard recognition.kind == .unknown || recognition.kind == .evidence(.other), recognition.ruleId == nil,
              let text = file.text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the recognition is the model's, not yet checked.
    public static func isProposed(_ recognition: ImportRecognition) -> Bool {
        recognition.proposedByModel && recognition.confidence == .needsReview
    }

    /// The recognition a guessed kind gives the file (nil: no kind guessed).
    static func recognition(for guess: DocumentModelGuess, file: ImportFile) -> ImportRecognition? {
        guess.kind.map { kind in
            var recognition = ImportRecognition(kind: ImportResolutions.importKind(for: kind, fileExtension: file.fileExtension),
                                                confidence: .needsReview, reason: recognitionReason)
            recognition.proposedByModel = true
            return recognition
        }
    }

    /// Whether the guess says anything usable (an amount needs its currency).
    static func isUsable(_ guess: DocumentModelGuess) -> Bool {
        guess.kind != nil || guess.issuer != nil || guess.docDate != nil || guess.reference != nil
            || (guess.amountMinorUnits != nil && guess.currency != nil)
    }

    /// The model asked about one file. Unavailable (before or while reading) says why; a timeout,
    /// an empty guess or any other failure is no answer; cancelling the task cancels it.
    static func ask(_ reader: any DocumentModelReading, file: ImportFile,
                    timeoutNanoseconds: UInt64 = timeoutNanoseconds) async throws -> Outcome {
        let text = file.text ?? "", name = file.fileName
        do {
            let guess = try await HardTimeout.run(nanoseconds: timeoutNanoseconds) {
                try await reader.read(text: text, fileName: name, kinds: kinds)
            }
            guard let guess, isUsable(guess) else { return .noAnswer }
            return .guess(guess)
        } catch DocumentModelReadError.unavailable(let message) {
            return .unavailable(message)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .noAnswer
        }
    }

    /// The item read again (`ImportPipeline.reread`) with what the model read on `before`, without
    /// asking it again: the figures the user accepted, written again as the user's where the
    /// reader didn't read them (`write`: the effect, the "missing" question), and the ones still
    /// to check as `.model` facts (`apply`).
    static func carry(from before: ImportItem, to item: ImportItem) -> ImportItem {
        var item = item
        for fact in before.facts where fact.source == .user && fact.fromModel && !item.facts.contains(where: { $0.field == fact.field })
            && ImportResolutions.takes(fact.value, fact.field, on: item) {
            write(fact, into: &item)
        }
        // A figure the user accepted that didn't fit is asked again as that figure.
        for issue in before.issues where issue.id.hasPrefix("confirmFigure.") && !item.issues.contains(where: { $0.id == issue.id }) {
            guard case .confirmFigure(let field) = issue.kind, issue.reason == unfitReason(field),
                  before.facts.contains(where: { $0.field == field && $0.source == .model }) else { continue }
            item.issues.append(issue)
        }
        item = apply(.guess(carried(by: before)), to: item)
        replace(&item)
        return item
    }

    /// The model's figures an item still carries to check, as its guess.
    static func carried(by item: ImportItem) -> DocumentModelGuess {
        var guess = DocumentModelGuess()
        for fact in item.facts where fact.source == .model {
            switch (fact.field, fact.value) {
            case (.issuer, .text(let name)): guess.issuer = name
            case (.docDate, .date(let date)): guess.docDate = date
            case (.amount, .money(let minor, let currency)): (guess.amountMinorUnits, guess.currency) = (minor, currency)
            case (.reference, .text(let reference)): guess.reference = reference
            default: break
            }
        }
        return guess
    }

    /// The item with what asking came to (its recognition already the guessed kind's, if any):
    /// the guess's figures the reader didn't read as `.model` facts, and the issue while a model
    /// fact or recognition waits; an unavailable model's message as the reason of its "what is
    /// this?" question.
    static func apply(_ outcome: Outcome, to item: ImportItem) -> ImportItem {
        var item = item
        switch outcome {
        case .noAnswer:
            break
        case .unavailable(let message):
            guard item.recognition.kind == .unknown || item.recognition.kind == .evidence(.other) else { break }
            if let index = item.issues.firstIndex(where: { if case .unknownKind = $0.kind { return true } else { return false } }) {
                item.issues[index].reason = message
            } else {
                item.issues.append(ImportIssue(id: unknownKindIssueId, kind: .unknownKind(proposed: nil), reason: message))
            }
        case .guess(let guess):
            func add(_ field: ImportFigureField, _ value: ImportFactValue?) {
                guard let value, !item.facts.contains(where: { $0.field == field }) else { return }
                item.facts.append(ImportFact(field: field, value: value, source: .model, confidence: .needsReview, reason: factReason))
            }
            add(.docDate, guess.docDate.map(ImportFactValue.date))
            if let amount = guess.amountMinorUnits, let currency = guess.currency { add(.amount, .money(amount, currency)) }
            add(.issuer, guess.issuer.map(ImportFactValue.text))
            add(.reference, guess.reference.map(ImportFactValue.text))
            replace(&item)
            if waits(item), !item.issues.contains(where: { $0.id == issueId }) {
                item.issues.append(ImportIssue(id: issueId, kind: .confirmModelReading, reason: issueReason))
            }
        }
        return item
    }

    /// Whether something the model proposed still waits on the item for its question: a proposed
    /// kind, or a model figure no figure question already asks about (one that didn't fit).
    static func waits(_ item: ImportItem) -> Bool {
        let asked = Set(item.issues.compactMap { issue -> ImportFigureField? in
            switch issue.kind {
            case .confirmFigure(let field), .missingFigure(let field): return field
            default: return nil
            }
        })
        return isProposed(item.recognition) || item.facts.contains { $0.source == .model && !asked.contains($0.field) }
    }

    /// The issue gone once nothing the model proposed waits (each field corrected or accepted).
    static func settle(_ item: inout ImportItem) {
        if !waits(item) { item.issues.removeAll { $0.id == issueId } }
    }

    /// Every `.model` fact the item takes (`ImportResolutions.takes`, as a confirmed figure) and a
    /// proposed recognition the user's, certain (`write`); the issue resolved. A value that
    /// doesn't fit (a payroll form's reference that isn't a PAYE reference) is not written: it
    /// stays a model figure to check, asked as a figure question.
    static func accept(_ item: ImportItem) -> ImportItem {
        var item = item
        var unfit: [ImportFigureField] = []
        for fact in item.facts where fact.source == .model {
            if ImportResolutions.takes(fact.value, fact.field, on: item) { write(fact, into: &item) } else { unfit.append(fact.field) }
        }
        if isProposed(item.recognition) {
            item.recognition.confidence = .certain
            item.recognition.reason = acceptedReason
        }
        item.issues.removeAll { $0.id == issueId }
        for field in unfit where !item.issues.contains(where: { $0.kind == .confirmFigure(field) || $0.kind == .missingFigure(field) }) {
            item.issues.append(ImportIssue(id: "confirmFigure.\(field.rawValue)", kind: .confirmFigure(field),
                                           reason: unfitReason(field)))
        }
        replace(&item)
        return item
    }

    /// "Reference read by the on-device model doesn't fit: check it".
    static func unfitReason(_ field: ImportFigureField) -> String {
        "\(field.displayName) read by the on-device model doesn't fit: check it"
    }

    /// A model figure written as the user's (`fromModel`): the effect's figure follows, and the
    /// question saying it is missing goes.
    private static func write(_ fact: ImportFact, into item: inout ImportItem) {
        var accepted = ImportFact(field: fact.field, value: fact.value, source: .user, confidence: .certain, reason: "Checked by you")
        accepted.fromModel = true
        item.facts.removeAll { $0.field == fact.field }
        item.facts.append(accepted)
        item.effect = ImportResolutions.effect(item.effect, with: fact.field, fact.value)
        item.issues.removeAll { $0.kind == .missingFigure(fact.field) }
    }

    /// The item's placement (its name) from its facts now.
    private static func replace(_ item: inout ImportItem) {
        guard item.placement != nil else { return }
        item.placement = ImportNaming.placement(kind: item.recognition.kind, facts: item.facts, file: item.file,
                                                persons: item.placement?.metadata.persons ?? [],
                                                customKind: item.placement?.customKind)
    }
}
