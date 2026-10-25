import Foundation

/// "Remember for this issuer": where a figure sits on an issuer's layout — the label before it
/// and which occurrence of that label (`FigurePositionAction`), never the value. Learnt from a
/// figure the user corrected and ticked (`label(for:)`, drafted by `ImportLearning.drafts`), read
/// on the issuer's next documents by the readers (`read`, `values`, `apply`): the learnt reading
/// overrides the built-in one; a label no longer on the page leaves the built-in reading, to check.
/// Only money and date figures have a position (not a statement's own figures), and only on
/// evidence documents and utility invoices (overriding the built-in reading) and payroll forms
/// (filling a figure the form reader didn't find); never on rent receipt PDFs, transfer advices
/// or statements, whose figures are matched to records.
public enum LearntFigures {
    /// Characters before the value a label is taken from (back to the line break).
    static let labelReach = 60
    /// Characters after the label the value is looked for in.
    static let valueReach = 120
    static let maxLabelWords = 4

    /// The note of an item whose corrected figure couldn't be placed (nothing is learnt).
    public static let notPlacedNote = "Couldn't find where this figure sits: it is fixed for this document only"
    /// The note of an item with no issuer key to remember a figure for.
    public static let noIssuerNote = "No issuer to remember it for: it is fixed for this document only"
    /// The note of an item of a kind whose figures aren't remembered.
    public static let notLearntKindNote = "Figures of this kind of document aren't remembered: it is fixed for this document only"
    /// The notes saying a corrected figure is fixed for this document only (shown with the figures).
    public static let fixedNotes: Set<String> = [notPlacedNote, noIssuerNote, notLearntKindNote]

    /// Whether figure positions are learnt from and read on documents of `kind`.
    public static func learns(_ kind: ImportKind) -> Bool {
        switch kind {
        case .evidence, .customEvidence, .utilityInvoice, .payrollForm: return true
        default: return false
        }
    }

    /// Whether "Remember for this issuer" is offered for `field` on `item`: the item has an issuer
    /// key, its kind's positions are learnt, the figure is money or a date (not a statement's), and
    /// — a payroll form's positions only filling what its reader didn't find — on a payroll form
    /// only a figure the reader missed (none, one read at a learnt position, or one the user entered).
    public static func offersRemembering(_ item: ImportItem, field: ImportFigureField, issuer: IssuerKey?) -> Bool {
        guard issuer != nil, learns(item.recognition.kind), isPositional(field), !ImportResolutions.isStatement(item) else { return false }
        guard case .payrollForm = item.recognition.kind, let fact = item.facts.first(where: { $0.field == field }) else { return true }
        return fact.source == .learntRule || (fact.source == .user && fact.reason == ImportResolutions.enteredReason)
    }

    /// Why a ticked figure of `item` isn't remembered (nil: it is — `drafts` holds its position).
    static func notRememberedNote(_ item: ImportItem, field: ImportFigureField, issuer: IssuerKey?, drafts: [ImportRuleDraft]) -> String? {
        if issuer == nil { return noIssuerNote }
        if !learns(item.recognition.kind) { return notLearntKindNote }
        let placed = drafts.contains { $0.kind == .figurePosition && ImportLearning.decode(FigurePositionAction.self, $0.actionJSON)?.field == field }
        return placed ? nil : notPlacedNote
    }

    /// The reason of a figure read at a learnt position.
    public static func readReason(_ label: String) -> String { "Learnt position: after “\(label)”" }

    /// The note of a learnt position whose label isn't on the document.
    public static func notFoundNote(_ label: String) -> String { "Learnt position not found (after “\(label)”)" }

    // MARK: Learning

    /// The label before `value` in `text` and which occurrence of it that is (0-based). The value
    /// is looked for in the forms the parsers read (money `1.234,56`, `1234,56`, `1,234.56`,
    /// `1234.56`; dates `dd/MM/yyyy`, `dd-MM-yyyy`, `yyyy-MM-dd`, `dd.MM.yyyy`), its first
    /// occurrence in the text (whitespace runs as single spaces, line by line); the label is the
    /// last 1–4 words with letters before it on its line (within 60 characters; trailing `:`,
    /// currency signs and spaces trimmed). Nil when the value isn't there, the figure isn't money
    /// or a date, no word with letters is before it, or the position wouldn't read the value back
    /// (`read`: another number sits between the label and it, "IVA 23% 9,66 42,10").
    /// Amounts grouped by plain spaces ("30 000,00 €") aren't among the forms: not learnable.
    public static func label(for value: ImportFactValue, field: ImportFigureField, in text: String) -> (label: String, occurrence: Int)? {
        guard isPositional(field), ImportResolutions.fits(value, field) else { return nil }
        let patterns = forms(of: value).map { NSRegularExpression.escapedPattern(for: $0) }
        guard !patterns.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"(?<!\d)(?<!\d[.,])(?:"# + patterns.joined(separator: "|") + #")(?!\d)(?![.,]\d)"#)
        else { return nil }
        let lines = normalizedLines(text)
        let body = lines.joined(separator: "\n") as NSString
        var lineStart = 0
        for line in lines {
            defer { lineStart += (line as NSString).length + 1 }
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            guard let (label, offset) = labelBefore(match.range.location, in: ns) else { return nil }
            // The label's earlier occurrences, found as `read` finds them.
            let preceding = EvidenceText.fold(body.substring(to: lineStart + offset)) as NSString
            let occurrence = EvidenceAnalyzer.occurrences(of: EvidenceText.fold(label), in: preceding).count
            // The position must read the figure back.
            let action = FigurePositionAction(field: field, label: label, occurrence: occurrence)
            guard let back = read(action, field: field, in: text, defaultCurrency: currency(of: value)), same(back, value) else { return nil }
            return (label, occurrence)
        }
        return nil
    }

    // MARK: Reading

    /// The figure at `action`'s position in `text`: the `occurrence`-th match of the label (case
    /// and accents ignored), then the first value of the field's type within 120 characters
    /// after it (money without a currency sign: `defaultCurrency`). Nil when either isn't there.
    public static func read(_ action: FigurePositionAction, field: ImportFigureField, in text: String,
                            defaultCurrency: Currency = .eur) -> ImportFactValue? {
        guard isPositional(field), !action.label.isEmpty, action.occurrence >= 0 else { return nil }
        let body = EvidenceText.fold(normalizedLines(text).joined(separator: "\n")) as NSString
        let found = EvidenceAnalyzer.occurrences(of: EvidenceText.fold(action.label), in: body)
        guard action.occurrence < found.count else { return nil }
        let window = EvidenceAnalyzer.window(after: found[action.occurrence], in: body, length: valueReach)
        if isMoney(field) {
            return EvidenceAmountParser.amounts(in: window).first.map { .money($0.minorUnits, $0.currency ?? defaultCurrency) }
        }
        return EvidenceDateParser.dates(in: window).first.map { .date($0.date) }
    }

    /// The enabled learnt positions of the file's issuer (`context.learntFigures`, issuer keyed
    /// with `context.knownParties`), one per field, each with its reading (nil: label not found).
    static func readings(_ file: ImportFile, context: ImportContext,
                         defaultCurrency: (ImportFigureField) -> Currency = { _ in .eur }) -> [Reading] {
        guard !context.learntFigures.isEmpty, let text = file.text,
              let issuer = IssuerKey.derive(text: text, fileName: file.fileName, ownNIFs: context.knownParties) else { return [] }
        var readings: [Reading] = []
        for rule in context.learntFigures where rule.isEnabled && rule.kind == .figurePosition && rule.id != nil {
            guard let action = ImportLearning.decode(FigurePositionAction.self, rule.actionJSON), isPositional(action.field),
                  rule.matchKey == ImportRuleKind.figurePositionKey(issuer: issuer, field: action.field),
                  !readings.contains(where: { $0.action.field == action.field }) else { continue }
            readings.append(Reading(rule: rule, action: action,
                                    value: read(action, field: action.field, in: text, defaultCurrency: defaultCurrency(action.field))))
        }
        return readings
    }

    /// The figures read at learnt positions, for a reader to read with before it matches.
    static func values(_ readings: [Reading]) -> [ImportFigureField: ImportFactValue] {
        var values: [ImportFigureField: ImportFactValue] = [:]
        for reading in readings {
            if let value = reading.value { values[reading.action.field] = value }
        }
        return values
    }

    /// The item with its issuer's learnt positions applied (a reader's last step): a figure read
    /// there replaces the built-in one (`.learntRule`, certain — to check when the file was read
    /// by text recognition, or the rule is keyed by a first line — "Learnt position: after “<label>”"), answers its missing-figure
    /// question and sets the effect's figure (as a confirmed figure does), the rule named in
    /// `appliedRules`; a label not found leaves the built-in figure, to check ("Learnt position
    /// not found (after “<label>”)", a note when there is no such figure). The user's, the
    /// intent's and a matched record's figures stay. Children, statements, unreadable and
    /// unknown files, and kinds whose positions aren't learnt (`learns`), are left as read.
    /// `readings`: the reader's (`readings(_:context:)`, read once), a payroll form's only the ones it filled.
    static func apply(to item: inout ImportItem, readings: [Reading]) {
        guard !readings.isEmpty, item.parentId == nil, !ImportResolutions.isStatement(item), !ImportResolutions.isUnreadable(item),
              learns(item.recognition.kind) else { return }
        var changed = false
        for reading in readings {
            let field = reading.action.field
            let index = item.facts.firstIndex { $0.field == field }
            let builtIn = index.map { item.facts[$0] }
            if let builtIn, [.user, .intent, .matchedRecord].contains(builtIn.source) { continue }
            guard var value = reading.value else {
                let note = notFoundNote(reading.action.label)
                if let index {
                    item.facts[index].confidence = .needsReview
                    item.facts[index].reason = note
                }
                if (builtIn == nil || builtIn!.source.alwaysNeedsReview), !item.notes.contains(note) { item.notes.append(note) }
                continue
            }
            // A credit note's figure keeps its sign.
            if case .money(let minor, let currency) = value, case .money(let read, _)? = builtIn?.value, read < 0 {
                value = .money(-abs(minor), currency)
            }
            let ocr = item.file.usedOCR || builtIn?.source == .ocr
            // An issuer known only by its first line: the position is suggested, to check.
            let line = IssuerKey.isLineKey(reading.rule.matchKey)
            let reason = line ? IssuerKey.lineKeyReason(readReason(reading.action.label), line: reading.rule.matchLabel) : readReason(reading.action.label)
            let fact = ImportFact(field: field, value: value, source: .learntRule, confidence: ocr || line ? .needsReview : .certain, reason: reason)
            if let index { item.facts[index] = fact } else { item.facts.append(fact) }
            item.issues.removeAll { $0.kind == .missingFigure(field) }
            item.effect = ImportResolutions.effect(item.effect, with: field, value)
            item.appliedRules.append(ImportRuleUse(ruleId: reading.rule.id!, kind: .figurePosition, label: reason))
            changed = true
        }
        if changed, item.placement != nil {
            item.placement = ImportNaming.placement(kind: item.recognition.kind, facts: item.facts, file: item.file,
                                                    persons: item.placement?.metadata.persons ?? [],
                                                customKind: item.placement?.customKind)
        }
    }

    struct Reading {
        var rule: ImportRule
        var action: FigurePositionAction
        var value: ImportFactValue?
    }

    // MARK: Helpers

    private static func currency(of value: ImportFactValue) -> Currency {
        if case .money(_, let currency) = value { return currency }
        return .eur
    }

    /// The same figure (money by its size: the sign and currency are the document's).
    private static func same(_ a: ImportFactValue, _ b: ImportFactValue) -> Bool {
        if case .money(let x, _) = a, case .money(let y, _) = b { return abs(x) == abs(y) }
        return a == b
    }

    /// Money and date figures (not a statement's own).
    static func isPositional(_ field: ImportFigureField) -> Bool {
        isMoney(field) || [.docDate, .periodStart, .periodEnd].contains(field)
    }

    private static func isMoney(_ field: ImportFigureField) -> Bool {
        [.amount, .pay, .taxDeducted].contains(field)
    }

    /// The text line by line, whitespace runs as single spaces.
    private static func normalizedLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    }

    /// The forms the parsers read `value` in.
    private static func forms(of value: ImportFactValue) -> [String] {
        switch value {
        case .money(let minor, _):
            let units = abs(minor) / 100
            let cents = String(format: "%02d", abs(minor) % 100)
            var groups: [String] = []
            var rest = units
            repeat {
                groups.insert(rest >= 1000 ? String(format: "%03d", rest % 1000) : String(rest % 1000), at: 0)
                rest /= 1000
            } while rest > 0
            let plain = String(units)
            var forms: [String] = []
            for form in [groups.joined(separator: ".") + "," + cents, plain + "," + cents,
                         groups.joined(separator: ",") + "." + cents, plain + "." + cents] where !forms.contains(form) {
                forms.append(form)
            }
            return forms
        case .date(let date):
            let parts = EvidenceText.utcCalendar.dateComponents([.year, .month, .day], from: date)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { return [] }
            let dd = String(format: "%02d", d), mm = String(format: "%02d", m), yyyy = String(format: "%04d", y)
            return ["\(dd)/\(mm)/\(yyyy)", "\(dd)-\(mm)-\(yyyy)", "\(yyyy)-\(mm)-\(dd)", "\(dd).\(mm).\(yyyy)"]
        case .text, .year:
            return []
        }
    }

    /// The label before `location` on `line` and where it starts on the line (UTF-16).
    private static func labelBefore(_ location: Int, in line: NSString) -> (String, Int)? {
        let start = max(0, location - labelReach)
        var prefix = line.substring(with: NSRange(location: start, length: location - start)) as NSString
        var base = start
        // Cut mid-word at the reach: that word isn't whole.
        if start > 0, !line.substring(with: NSRange(location: start - 1, length: 1)).allSatisfy(\.isWhitespace) {
            let space = prefix.rangeOfCharacter(from: .whitespaces).location
            guard space != NSNotFound else { return nil }
            base += space + 1
            prefix = prefix.substring(from: space + 1) as NSString
        }
        // Words with their places; the trailing ones without letters (a sign, "(1):") are skipped.
        guard let regex = try? NSRegularExpression(pattern: #"\S+"#) else { return nil }
        var words = regex.matches(in: prefix as String, range: NSRange(location: 0, length: prefix.length)).map(\.range)
        while let last = words.last, !prefix.substring(with: last).contains(where: \.isLetter) { words.removeLast() }
        var kept: [NSRange] = []
        while let last = words.last, kept.count < maxLabelWords, prefix.substring(with: last).contains(where: \.isLetter) {
            kept.insert(last, at: 0)
            words.removeLast()
        }
        guard let first = kept.first, let end = kept.last else { return nil }
        let label = prefix.substring(with: NSRange(location: first.location, length: end.location + end.length - first.location))
            .trimmingCharacters(in: CharacterSet(charactersIn: " :€£$"))
        guard label.contains(where: \.isLetter) else { return nil }
        return (label, base + first.location)
    }
}
