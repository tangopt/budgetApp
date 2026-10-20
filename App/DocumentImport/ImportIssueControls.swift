// App/DocumentImport/ImportIssueControls.swift
import SwiftUI
import BudgetCore

/// One question about a document and exactly the answers it takes (`ImportResolutions`): what
/// its kind takes by default — a kind for "what is this?", one of the offered links, targets or
/// a figure — plus what the issue offers; every issue can also be left out of the import. An
/// item held by a filed return, a failed check or an unreadable file isn't asked this way: the
/// preview shows its `ImportHoldBanner`s and one "Leave out of this import".
struct ImportIssueControls: View {
    let item: ImportItem
    let issue: ImportIssue
    let targetNames: ImportTargetNames
    let resolve: (ImportResolution) -> Void

    static let leaveOutTitle = "Leave out of this import"

    var body: some View {
        if ImportResolutions.isFiledYearHold(issue) {
            // The preview shows holds itself (one Leave out for the item); shown alone, a hold
            // still offers only that.
            VStack(alignment: .leading, spacing: 6) {
                ImportHoldBanner(issue: issue)
                leaveOutButton
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(issue.reason.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                }
                .font(.callout)
                if !ImportResolutions.onlyLeavesOut(issue, in: item) {
                    answers
                }
                HStack(spacing: 6) {
                    if !ImportResolutions.onlyLeavesOut(issue, in: item) {
                        ForEach(Array(extraOffers.enumerated()), id: \.offset) { _, offer in
                            Button(title(of: offer)) { resolve(offer) }
                        }
                    }
                    leaveOutButton
                }
                .controlSize(.small)
            }
        }
    }

    private var leaveOutButton: some View {
        Button(Self.leaveOutTitle) { resolve(.leaveOut) }.controlSize(.small)
    }

    /// The answers the issue's kind takes, as controls.
    @ViewBuilder
    private var answers: some View {
        switch issue.kind {
        case .unknownKind(let proposed):
            ImportKindChooser(initial: proposed ?? .other, keep: nil, resolve: resolve)
                .id("\(item.id)-\(issue.id)")
        case .kindMismatch(let expected, let found):
            // "Keep as <found>" is its acknowledge, whether the kind takes it or the issue offers it.
            ImportKindChooser(initial: Self.documentKind(expected) ?? Self.documentKind(found) ?? .other,
                              keep: ImportResolutions.accepts(issue, .acknowledge) ? "Keep as \(found.displayName)" : nil,
                              resolve: resolve)
                .id("\(item.id)-\(issue.id)")
        case .confirmFigure(let field), .missingFigure(let field):
            ImportFigureEditor(field: field, current: item.facts.first { $0.field == field }?.value,
                               currency: Self.currency(of: item, field: field),
                               confirming: { if case .confirmFigure = issue.kind { return true } else { return false } }(),
                               resolve: resolve)
                // Its own state per issue and figure: never another figure's typed value.
                .id("\(item.id)-\(issue.id)-\(field.rawValue)")
        case .chooseLink(let candidates):
            if !candidates.isEmpty {
                ImportLinkChooser(candidates: candidates, resolve: resolve)
                    .id("\(item.id)-\(issue.id)")
            }
        case .chooseTarget(let kind, let options):
            if !options.isEmpty {
                ImportTargetChooser(kind: kind, options: options, names: targetNames, resolve: resolve)
                    .id("\(item.id)-\(issue.id)")
            }
        case .readerProblem, .statement, .filedYear:
            EmptyView()
        }
    }

    /// What the issue offers beyond its kind's controls (and leaving out, which is always last).
    private var extraOffers: [ImportResolution] {
        issue.offers.filter { offer in
            switch (offer, issue.kind) {
            case (.leaveOut, _): return false
            // The controls above already make these.
            case (.chooseLink(let entity), .chooseLink(let candidates)): return !candidates.contains { $0.entity == entity }
            case (.chooseKind, .unknownKind), (.chooseKind, .kindMismatch), (.acknowledge, .kindMismatch): return false
            case (.chooseTarget(let kind, let id), .chooseTarget(let asked, let options)): return !(kind == asked && options.contains(id))
            default: return true
            }
        }
    }

    func title(of offer: ImportResolution) -> String {
        switch offer {
        case .acknowledge:
            if case .kindMismatch(_, let found) = issue.kind { return "Keep as \(found.displayName)" }
            if issue.id == ImportDuplicates.correctedVersionIssueId { return "Import as the newer version" }
            return "Got it"
        case .fileWithoutLink:
            let documentOnly = [UtilityInvoiceImportReader.documentOnlyIssueId, ImportDuplicates.correctedVersionIssueId].contains(issue.id)
            return documentOnly ? "File the document only" : "File without a link"
        case .chooseKind(let kind): return "File as \(kind.displayName)"
        case .chooseLink(let entity): return "Link to \(entity.type.displayName.lowercased()) #\(entity.id)"
        case .confirmFigure(let field, _): return "Use this \(field.displayName.lowercased())"
        case .chooseTarget(let kind, let id): return "Use \(targetNames.name(kind, id))"
        case .leaveOut: return Self.leaveOutTitle
        case .linkTransactions(let ids): return ids.count == 1 ? "Link to this transaction" : "Link to these \(ids.count) transactions"
        case .addTransactionLink: return "Link to this transaction too"
        case .unlink: return "Unlink"
        }
    }

    /// The document kind an import kind files as, when it is one of the library's.
    static func documentKind(_ kind: ImportKind) -> DocumentKind? {
        switch kind {
        case .evidence(let kind): return kind
        case .payrollForm(.p60): return .p60
        case .payrollForm(.p45): return .p45
        case .payrollForm(.p11d): return .p11d
        case .utilityInvoice: return .utilityInvoice
        case .bankStatementCSV, .bankStatementPDF, .bbvaStatement: return .bankStatement
        case .rentReceiptPDF: return .rentReceipt
        default: return nil
        }
    }

    /// The currency an amount is entered in: the document's, else pounds for a payroll form, else euros.
    static func currency(of item: ImportItem, field: ImportFigureField) -> Currency {
        for fact in item.facts {
            if case .money(_, let currency) = fact.value { return currency }
        }
        if let currency = item.placement?.metadata.currency { return currency }
        if case .payrollForm = item.recognition.kind { return .gbp }
        return field == .pay || field == .taxDeducted ? .gbp : .eur
    }
}

// MARK: Answers

/// "What is this?": the library's kinds by name, and "Use this kind" (with "Keep as …" when
/// the file may stay what it was recognised as).
struct ImportKindChooser: View {
    let keep: String?
    let resolve: (ImportResolution) -> Void
    @State private var kind: DocumentKind

    private static let kinds = DocumentKind.allCases.sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }

    init(initial: DocumentKind, keep: String?, resolve: @escaping (ImportResolution) -> Void) {
        self.keep = keep
        self.resolve = resolve
        _kind = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker("Kind", selection: $kind) {
                ForEach(Self.kinds, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            Button("Use this kind") { resolve(.chooseKind(kind)) }
            if let keep {
                Button(keep) { resolve(.acknowledge) }
            }
        }
        .controlSize(.small)
    }
}

/// A figure to check or enter: a day, an amount, a tax year or text, and "Confirm" / "Use this".
struct ImportFigureEditor: View {
    enum Kind { case date, money, year, text }

    let field: ImportFigureField
    let currency: Currency
    let confirming: Bool
    let resolve: (ImportResolution) -> Void
    @State private var date: Date
    @State private var amount: String
    @State private var year: Int
    @State private var text: String

    init(field: ImportFigureField, current: ImportFactValue?, currency: Currency, confirming: Bool,
         resolve: @escaping (ImportResolution) -> Void) {
        self.field = field
        self.confirming = confirming
        self.resolve = resolve
        var currency = currency
        var date = PayCalendar.utcDay(sameDayAs: AppClock.now, in: .current)
        var amount = ""
        var year = UKTaxYear.containing(AppClock.now).startYear
        var text = ""
        switch current {
        case .date(let value): date = value
        case .money(let value, let valueCurrency):
            amount = Money.formatInput(value)
            currency = valueCurrency
        case .year(let value): year = value
        case .text(let value): text = value
        case nil: break
        }
        self.currency = currency
        _date = State(initialValue: date)
        _amount = State(initialValue: amount)
        _year = State(initialValue: year)
        _text = State(initialValue: text)
    }

    /// The figure's type (as `ImportResolutions` takes it).
    static func kind(of field: ImportFigureField) -> Kind {
        switch field {
        case .docDate, .periodStart, .periodEnd: return .date
        case .amount, .pay, .taxDeducted: return .money
        case .taxYear: return .year
        case .currency, .invoiceNumber, .receiptNumber, .reference, .issuer, .person: return .text
        }
    }

    private var value: ImportFactValue? {
        switch Self.kind(of: field) {
        case .date: return .date(date)
        case .money: return Money.parseMinorUnits(amount).map { .money($0, currency) }
        case .year: return .year(year)
        case .text:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
    }

    private var years: [Int] {
        let current = UKTaxYear.containing(AppClock.now).startYear
        return Array(Set(Array((current - 8)...(current + 1)) + [year])).sorted(by: >)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(field.displayName).foregroundStyle(.secondary).lineLimit(1)
            switch Self.kind(of: field) {
            case .date:
                DatePicker(field.displayName, selection: utcDay($date), displayedComponents: .date)
                    .labelsHidden()
            case .money:
                MoneyField(field.displayName, text: $amount, currency: currency, width: 100)
            case .year:
                Picker(field.displayName, selection: $year) {
                    ForEach(years, id: \.self) { Text(UKTaxYear(startYear: $0).label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            case .text:
                TextField(field.displayName, text: $text)
                    .textFieldStyle(.roundedBorder)
            }
            Button(confirming ? "Confirm" : "Use this") {
                if let value { resolve(.confirmFigure(field, value)) }
            }
            .disabled(value == nil)
        }
        .controlSize(.small)
        .font(.callout)
    }
}

/// "Which one?" among the offered records: each with why it was offered, and "Link to this".
struct ImportLinkChooser: View {
    let candidates: [LinkCandidate]
    let resolve: (ImportResolution) -> Void
    @State private var chosen: EvidenceEntity?

    init(candidates: [LinkCandidate], resolve: @escaping (ImportResolution) -> Void) {
        self.candidates = candidates
        self.resolve = resolve
        _chosen = State(initialValue: candidates.first?.entity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Link to", selection: $chosen) {
                ForEach(candidates, id: \.entity) { candidate in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.label.figuresUnbroken)
                        if !candidate.reasons.isEmpty {
                            Text(candidate.reasons.joined(separator: " · ").figuresUnbroken)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(candidate.entity))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Button("Link to this") {
                guard let chosen, candidates.contains(where: { $0.entity == chosen }) else { return }
                resolve(.chooseLink(chosen))
            }
            .controlSize(.small)
        }
        .font(.callout)
    }
}

/// Which property, person, account, tenancy or provider the document is for.
struct ImportTargetChooser: View {
    let kind: ImportTargetKind
    let options: [Int64]
    let names: ImportTargetNames
    let resolve: (ImportResolution) -> Void
    @State private var chosen: Int64

    init(kind: ImportTargetKind, options: [Int64], names: ImportTargetNames, resolve: @escaping (ImportResolution) -> Void) {
        self.kind = kind
        self.options = options
        self.names = names
        self.resolve = resolve
        _chosen = State(initialValue: options.first ?? 0)
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker(kind.rawValue.capitalized, selection: $chosen) {
                ForEach(options, id: \.self) { Text(names.name(kind, $0)).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            Button("Use this") { resolve(.chooseTarget(kind, chosen)) }
        }
        .controlSize(.small)
    }
}

// MARK: Checks without a question

/// What holds an item back without an issue of its own — a figure read by text recognition,
/// from the file name or by the model, a kind recognised without certainty, a link to check —
/// with the answers `ImportResolutions` takes for it (answering the item, not one issue).
struct ImportItemChecks: View {
    let item: ImportItem
    let resolve: (ImportResolution) -> Void

    /// Figures to check that no issue already asks about.
    private var facts: [ImportFact] {
        let asked = Set(item.issues.compactMap { issue -> ImportFigureField? in
            switch issue.kind {
            case .confirmFigure(let field), .missingFigure(let field): return field
            default: return nil
            }
        })
        return item.facts.filter { $0.confidence == .needsReview && !asked.contains($0.field) }
    }

    /// Whether the kind is unsure and no issue asks it.
    private var asksKind: Bool {
        item.recognition.confidence == .needsReview && !item.issues.contains { issue in
            switch issue.kind {
            case .unknownKind, .kindMismatch: return true
            default: return false
            }
        }
    }

    /// Links to check that no "which one?" offers.
    private var links: [ProposedLink] {
        let asked = Set(item.issues.flatMap { issue -> [EvidenceEntity] in
            if case .chooseLink(let candidates) = issue.kind { return candidates.map(\.entity) }
            return []
        })
        return item.links.filter { $0.confidence == .needsReview && !asked.contains($0.entity) }
    }

    var body: some View {
        let facts = facts, links = links
        if asksKind || !facts.isEmpty || !links.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if asksKind {
                    check(item.recognition.reason) {
                        ImportKindChooser(initial: ImportIssueControls.documentKind(item.recognition.kind) ?? .other,
                                          keep: nil, resolve: resolve)
                    }
                }
                ForEach(facts, id: \.field) { fact in
                    check(Self.reason(fact)) {
                        ImportFigureEditor(field: fact.field, current: fact.value,
                                           currency: ImportIssueControls.currency(of: item, field: fact.field),
                                           confirming: true, resolve: resolve)
                            // Its own state per figure: confirming one never hands its value to the next.
                            .id("\(item.id)-\(fact.field.rawValue)")
                    }
                }
                ForEach(links, id: \.entity) { link in
                    check("Link to \(link.label): check it") {
                        Button("Keep this link") { resolve(.chooseLink(link.entity)) }
                            .controlSize(.small)
                    }
                }
                // Once for the item (it drops every unsure link), and only when no question
                // already offers it.
                if !links.isEmpty, !item.issues.contains(where: { ImportResolutions.accepts($0, .fileWithoutLink) }) {
                    Button("File without a link") { resolve(.fileWithoutLink) }
                        .controlSize(.small)
                }
            }
        }
    }

    /// As `ImportItem.needsYouReasons` words it.
    static func reason(_ fact: ImportFact) -> String {
        switch fact.source {
        case .ocr: return "\(fact.field.displayName) read by text recognition: check it"
        case .fileName: return "\(fact.field.displayName) taken from the file name: check it"
        case .model: return "\(fact.field.displayName) suggested by the model: check it"
        default: return fact.reason
        }
    }

    private func check<Controls: View>(_ reason: String, @ViewBuilder controls: () -> Controls) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(reason.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            .font(.callout)
            controls()
        }
    }
}

/// A filed-year hold: the return it would change and how (headline and explanation lines),
/// or why the check couldn't be made. Leaving the item out is its only answer (shown once, by
/// the preview).
struct ImportHoldBanner: View {
    let issue: ImportIssue

    var body: some View {
        InlineBanner(.warning) {
            VStack(alignment: .leading, spacing: 4) {
                if case .filedYear(let impact) = issue.kind {
                    Text(impact.headline.figuresUnbroken).fontWeight(.medium)
                    ForEach(Array(impact.explanation.enumerated()), id: \.offset) { _, line in
                        Text(line.figuresUnbroken).foregroundStyle(.secondary)
                    }
                } else {
                    Text(issue.reason.figuresUnbroken).fontWeight(.medium)
                }
            }
        }
    }
}
