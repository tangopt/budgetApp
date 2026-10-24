// App/DocumentImport/ImportIssueControls.swift
import SwiftUI
import BudgetCore

/// One question about a document and exactly the answers it takes (`ImportResolutions`): what
/// its kind takes by default — a kind for "what is this?", one of the offered links, targets or
/// a figure — plus what the issue offers; the item can also be left out of the import (one
/// "Leave out of this import" after all its questions, drawn by the preview). An item held by
/// a filed return, a failed check or an unreadable file isn't asked this way: the preview shows
/// its `ImportHoldBanner`s and one "Leave out of this import".
struct ImportIssueControls: View {
    let item: ImportItem
    let issue: ImportIssue
    let targetNames: ImportTargetNames
    /// The accounts by id (a statement's account picker and its layout wizard).
    var accounts: [Int64: Account] = [:]
    /// Why the last answer to this question wasn't taken (shown with it).
    var answerProblem: String? = nil
    /// The document's issuer key, if it has one: "Remember for this issuer" is offered only then.
    var issuer: IssuerKey? = nil
    /// An answer for the item rather than this question (a model figure corrected field by
    /// field); nil: `resolve`.
    var resolveItem: ((ImportResolution) -> Void)? = nil
    /// A kind's name, a custom kind's (saved or new in this review) included (`ImportSession.kindLabel`).
    var kindLabel: (ImportKind) -> String = { $0.displayName }
    let resolve: (ImportResolution) -> Void

    @Environment(\.theme) private var theme

    static let leaveOutTitle = "Leave out of this import"

    /// "What is this?" or "Expected …, this looks like …": answered with the kind chooser.
    private var isKindQuestion: Bool {
        switch issue.kind {
        case .unknownKind, .kindMismatch: return true
        default: return false
        }
    }
    /// A BBVA statement's "Replace the estimate?" question (`BBVAStatementReader`).
    static let estimateIssuePrefix = "instalmentMismatch.estimate."

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
                if ImportModelProposals.isUnavailableNotice(issue) {
                    // Why the on-device model wasn't asked: the kind is the user's to choose.
                    InlineBanner(.info, issue.reason)
                } else {
                    Label {
                        Text(issue.reason.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if !ImportResolutions.onlyLeavesOut(issue, in: item) {
                    answers
                }
                // A new kind's name refused beside its question (a statement's answers show their own).
                if let answerProblem, isKindQuestion {
                    Text(answerProblem.figuresUnbroken).font(.caption).foregroundStyle(theme.expense)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Leaving the item out is offered once, after all its questions (the preview).
                let offers = ImportResolutions.onlyLeavesOut(issue, in: item) ? [] : extraOffers
                if !offers.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(offers.enumerated()), id: \.offset) { _, offer in
                            Button(title(of: offer)) { resolve(offer) }
                        }
                    }
                    .controlSize(.small)
                }
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
            ImportKindChooser(initial: .evidence(proposed ?? .other), keep: nil, resolve: resolve)
                .id("\(item.id)-\(issue.id)")
        case .kindMismatch(let expected, let found):
            // "Keep as <found>" is its acknowledge, whether the kind takes it or the issue offers it.
            ImportKindChooser(initial: Self.documentKind(expected) == nil && !Self.isCustom(expected) ? found : expected,
                              keep: ImportResolutions.accepts(issue, .acknowledge) ? title(of: .acknowledge) : nil,
                              resolve: resolve)
                .id("\(item.id)-\(issue.id)")
        case .confirmFigure(let field), .missingFigure(let field):
            ImportFigureEditor(field: field, current: item.facts.first { $0.field == field }?.value,
                               currency: Self.currency(of: item, field: field),
                               confirming: { if case .confirmFigure = issue.kind { return true } else { return false } }(),
                               remembers: LearntFigures.offersRemembering(item, field: field, issuer: issuer),
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
        case .statement(let statement):
            ImportStatementIssueAnswers(item: item, issue: issue, statement: statement, targetNames: targetNames,
                                        accounts: accounts, answerProblem: answerProblem, resolve: resolve)
                .id("\(item.id)-\(issue.id)")
        case .confirmModelReading:
            // What the model read, to take as it is or correct field by field (each an answer for the item).
            ImportModelReading(item: item, issuer: issuer, accept: { resolve(.acceptModelReading) },
                               resolve: resolveItem ?? resolve)
                .id("\(item.id)-\(issue.id)")
        case .readerProblem, .filedYear:
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
            // The account picker (statement plan, Task 7) makes these, not one button each.
            case (.chooseAccount, .statement(.unknownAccount)), (.chooseAccount, .statement(.unknownLinkedAccount)): return false
            // Its reason field and button make it.
            case (.importAnyway, .statement(.balanceMismatch)): return false
            default: return true
            }
        }
    }

    func title(of offer: ImportResolution) -> String {
        switch offer {
        case .acknowledge:
            if case .kindMismatch(_, let found) = issue.kind { return "Keep as \(found == item.recognition.kind ? item.kindName : kindLabel(found))" }
            if issue.id == ImportDuplicates.correctedVersionIssueId { return "Import as the newer version" }
            // A BBVA receipt whose interest the fund/mortgage tool estimated otherwise.
            if issue.id.hasPrefix(Self.estimateIssuePrefix) { return "Replace the estimate" }
            if issue.id == EvidenceDocumentReader.instalmentsIssueId { return "Keep both links" }
            return "Got it"
        case .fileWithoutLink:
            let documentOnly = issue.id == UtilityInvoiceImportReader.documentOnlyIssueId || ImportDuplicates.isCorrectedVersion(issue.id)
                || issue.id == UtilityInvoiceImportReader.chooseInvoiceIssueId
            return documentOnly ? "File the document only" : "File without a link"
        case .chooseKind(let kind): return "File as \(kind.displayName)"
        case .chooseCustomKind(let key): return "File as \(kindLabel(.customEvidence(key)))"
        case .createKind(let name, _): return "File as \(name)"
        case .chooseLink(let entity): return "Link to \(entity.type.displayName.lowercased()) #\(entity.id)"
        case .confirmFigure(let field, _), .confirmFigureRemembering(let field, _): return "Use this \(field.displayName.lowercased())"
        case .chooseTarget(let kind, let id): return "Use \(targetNames.name(kind, id))"
        case .chooseAccount(_, let id): return "Use \(targetNames.name(.account, id))"
        case .importAnyway: return "Import anyway"
        case .keepRow: return "Keep"
        case .skipRow: return "Skip"
        case .saveProfile: return "Use this layout"
        case .leaveOut: return Self.leaveOutTitle
        case .linkTransactions(let ids): return ids.count == 1 ? "Link to this transaction" : "Link to these \(ids.count) transactions"
        case .addTransactionLink: return "Link to this transaction too"
        case .unlink: return "Unlink"
        case .setIssuer(let name): return "Name the issuer \(name)"
        case .acceptModelReading, .setBenefits: return "Use these"
        case .markChecked: return "Mark as checked"
        case .unmarkChecked: return "Undo"
        case .markAllChecked: return "Mark all as checked"
        case .unmarkAllChecked: return "Undo all checks"
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

    /// Whether `kind` is a custom kind (saved or made in this review).
    static func isCustom(_ kind: ImportKind) -> Bool {
        if case .customEvidence = kind { return true }
        return false
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

/// A bank statement's question answered in place: a closing that doesn't match (the figures,
/// a reason and "Import anyway"), a row that looks already saved (the saved row; Keep / Skip
/// are its offers), the lines not read, a layout to map ("Set up columns…" / "Set up
/// layout…", the existing wizards as a sheet), the account to choose. Instalment and fund
/// mismatches say why and take what they offer (or only Leave out).
struct ImportStatementIssueAnswers: View {
    let item: ImportItem
    let issue: ImportIssue
    let statement: StatementIssue
    let targetNames: ImportTargetNames
    let accounts: [Int64: Account]
    let answerProblem: String?
    let resolve: (ImportResolution) -> Void
    @State private var reason = ""
    @State private var chosenAccount: Int64?
    @State private var mapping: Mapping?
    @Environment(\.theme) private var theme

    /// The wizard open over the review, prefilled from `existing` when the question offers a saved layout.
    private struct Mapping: Identifiable {
        let id = UUID()
        let account: Account
        let format: ImportFormat
        let existing: ImportProfile?
    }

    /// The saved layout the question offers as its starting point (`.remap`).
    private var offeredProfile: ImportProfile? {
        issue.offers.lazy.compactMap { offer -> ImportProfile? in
            if case .saveProfile(let profile) = offer { return profile }
            return nil
        }.first
    }

    /// Lines shown before the list scrolls.
    static let visibleLines = 8

    var body: some View {
        switch statement {
        case .balanceMismatch(let mismatch):
            balanceMismatch(mismatch)
        case .possibleDuplicate(_, let existingLabel):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Saved row:").foregroundStyle(.secondary)
                Text(existingLabel.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        case .unparsedLines(let lines):
            unparsed(lines)
        case .noProfile(let format, let accountId):
            layoutButton(format: format, accountId: accountId)
        case .remap(let format, let accountId):
            // "Edit column mapping…": the wizard prefilled with the saved layout it offers ("Use
            // this layout" keeps that one as it is).
            layoutButton(format: format, accountId: accountId, existing: offeredProfile)
        case .unknownAccount:
            accountPicker(role: .current)
        case .unknownLinkedAccount(let role):
            accountPicker(role: role)
        case .instalmentMismatch, .fundMismatch:
            // The reason says it all; what it offers (if anything) is a button below.
            EmptyView()
        }
    }

    // MARK: Balance

    /// The currency of the statement's account (else the item's figures').
    private var currency: Currency {
        switch item.effect {
        case .ukStatement(let effect): if let account = accounts[effect.accountId] { return account.currency }
        case .bbvaStatement(let effect): if let account = accounts[effect.currentAccountId] { return account.currency }
        default: break
        }
        return ImportIssueControls.currency(of: item, field: .closingBalance)
    }

    @ViewBuilder
    private func balanceMismatch(_ mismatch: StatementMismatch) -> some View {
        let currency = currency
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                figureRow("Statement closing", mismatch.statementMinorUnits, currency)
                figureRow("Computed balance", mismatch.computedMinorUnits, currency)
                figureRow("Difference", mismatch.statementMinorUnits - mismatch.computedMinorUnits, currency)
            }
            if ImportResolutions.accepts(issue, .importAnyway(reason: "?")) {
                HStack(spacing: 6) {
                    TextField("Why import it anyway?", text: $reason)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(importAnyway)
                    Button("Import anyway", action: importAnyway)
                        .disabled(trimmedReason.isEmpty)
                }
                .controlSize(.small)
            }
            if let answerProblem {
                Text(answerProblem.figuresUnbroken).font(.caption).foregroundStyle(theme.expense)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    private var trimmedReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func importAnyway() {
        guard !trimmedReason.isEmpty else { return }
        resolve(.importAnyway(reason: reason))
    }

    private func figureRow(_ label: String, _ minorUnits: Int, _ currency: Currency) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            MoneyText(minorUnits: minorUnits, currency: currency, font: .callout.monospacedDigit(), role: .neutral)
                .figureText()
                .gridColumnAlignment(.trailing)
        }
    }

    // MARK: Lines not read

    private func unparsed(_ lines: [String]) -> some View {
        let lineHeight: CGFloat = 15
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).lineLimit(1).truncationMode(.tail)
                        .frame(height: lineHeight, alignment: .leading)
                        .help(line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .frame(height: CGFloat(min(lines.count, Self.visibleLines)) * lineHeight + 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5)))
    }

    // MARK: Layout

    @ViewBuilder
    private func layoutButton(format: ImportFormat, accountId: Int64, existing: ImportProfile? = nil) -> some View {
        // Only where the question takes a layout for this account and format.
        if let account = accounts[accountId], ImportResolutions.accepts(issue, .saveProfile(ImportProfile(accountId: accountId, format: format))) {
            Button(existing == nil ? (format == .pdf ? "Set up layout…" : "Set up columns…") : (format == .pdf ? "Edit layout…" : "Edit columns…")) {
                mapping = Mapping(account: account, format: format, existing: existing)
            }
                .controlSize(.small)
                .sheet(item: $mapping) { request in
                    switch request.format {
                    case .pdf:
                        PDFLayoutWizardView(account: request.account, sampleLines: sampleLines, existingProfile: request.existing) { profile in
                            mapping = nil
                            answer(profile)
                        }
                    case .csv:
                        CSVMappingWizardView(account: request.account, csvText: item.file.text ?? "", existingProfile: request.existing) { profile in
                            mapping = nil
                            answer(profile)
                        }
                    }
                }
        }
    }

    /// The wizard's layout as the answer, only when the question takes it (this account and format).
    private func answer(_ profile: ImportProfile) {
        guard ImportResolutions.accepts(issue, .saveProfile(profile)) else { return }
        resolve(.saveProfile(profile))
    }

    /// The PDF's text lines (what its layout is set up from).
    private var sampleLines: [String] {
        (item.file.text ?? "").split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Accounts

    /// The accounts the question offers for `role`, in its order (the remembered or plausible
    /// ones first); a linked account's of the statement's bank region first.
    private func offered(_ role: StatementAccountRole) -> [Int64] {
        let ids = issue.offers.compactMap { offer -> Int64? in
            if case .chooseAccount(let offeredRole, let id) = offer, offeredRole == role { return id }
            return nil
        }
        guard case .unknownLinkedAccount = statement else { return ids }
        let region: BankRegion = item.recognition.kind == .bbvaStatement ? .europe : .uk
        return ids.enumerated().sorted { lhs, rhs in
            let left = accounts[lhs.element]?.effectiveBankRegion == region ? 0 : 1
            let right = accounts[rhs.element]?.effectiveBankRegion == region ? 0 : 1
            return (left, lhs.offset) < (right, rhs.offset)
        }.map(\.element)
    }

    @ViewBuilder
    private func accountPicker(role: StatementAccountRole) -> some View {
        let options = offered(role)
        if !options.isEmpty {
            let selection = Binding<Int64>(get: { chosenAccount.flatMap { options.contains($0) ? $0 : nil } ?? options[0] },
                                           set: { chosenAccount = $0 })
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Picker("Account", selection: selection) {
                        ForEach(options, id: \.self) { Text(targetNames.name(.account, $0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Use this account") { resolve(.chooseAccount(role, selection.wrappedValue)) }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                Text("Remembered for files like this").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// "What is this?": the review's kinds (`ImportSession.kindChoices`: the built-ins by name, the
/// saved custom kinds, then the ones made in this review), "New kind…" last, and "Use this kind"
/// (with "Keep as …" when the file may stay what it was recognised as). New kind… asks a name and
/// an area and files the document as it at once (`ImportResolution.createKind`).
struct ImportKindChooser: View {
    let keep: String?
    let resolve: (ImportResolution) -> Void
    @Environment(\.importKindChoices) private var choices
    @State private var selection: Selection
    @State private var creating = false

    /// A kind, or "New kind…" (it opens the popover and goes back to the kind shown before).
    enum Selection: Hashable {
        case kind(ImportKind)
        case newKind
    }

    static let newKindTitle = "New kind…"

    init(initial: ImportKind, keep: String?, resolve: @escaping (ImportResolution) -> Void) {
        self.keep = keep
        self.resolve = resolve
        _selection = State(initialValue: .kind(Self.choiceKind(initial)))
    }

    /// The chooser's kind for what an item was recognised as (a library kind or a custom one); Other otherwise.
    static func choiceKind(_ kind: ImportKind) -> ImportKind {
        if case .customEvidence = kind { return kind }
        return .evidence(ImportIssueControls.documentKind(kind) ?? .other)
    }

    private var builtIns: [ImportKindChoice] { choices.filter { if case .evidence = $0.kind { return true } else { return false } } }
    private var custom: [ImportKindChoice] { choices.filter { if case .customEvidence = $0.kind { return true } else { return false } } }

    /// The kind chosen, when it is one the chooser offers (else Other).
    private var chosen: ImportKindChoice? {
        guard case .kind(let kind) = selection else { return nil }
        return choices.first { $0.kind == kind } ?? choices.first { $0.kind == .evidence(.other) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker("Kind", selection: Binding(get: { pickerSelection }, set: { choose($0) })) {
                ForEach(builtIns, id: \.self) { Text($0.label).tag(Selection.kind($0.kind)) }
                if !custom.isEmpty {
                    Divider()
                    ForEach(custom, id: \.self) { Text($0.label).tag(Selection.kind($0.kind)) }
                }
                Divider()
                Text(Self.newKindTitle).tag(Selection.newKind)
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .popover(isPresented: $creating, arrowEdge: .bottom) {
                NewKindPopover(choices: choices, create: { name, area in
                    creating = false
                    resolve(.createKind(name: name, area: area))
                }, cancel: { creating = false })
            }
            Button("Use this kind") { if let resolution = chosen?.resolution { resolve(resolution) } }
                .disabled(chosen?.resolution == nil)
            if let keep {
                Button(keep) { resolve(.acknowledge) }
            }
        }
        .controlSize(.small)
    }

    /// What the picker shows: the chosen kind, Other when it isn't offered.
    private var pickerSelection: Selection {
        chosen.map { .kind($0.kind) } ?? .kind(.evidence(.other))
    }

    private func choose(_ value: Selection) {
        if value == .newKind {
            creating = true
        } else {
            selection = value
        }
    }
}

/// A figure to check or enter: a day, an amount, a tax year or text, and "Confirm" / "Use this".
struct ImportFigureEditor: View {
    enum Kind { case date, money, year, text }

    let field: ImportFigureField
    let currency: Currency
    let confirming: Bool
    /// Whether "Remember for this issuer" is offered (`LearntFigures.offersRemembering`).
    let remembers: Bool
    let resolve: (ImportResolution) -> Void
    @State private var date: Date
    @State private var amount: String
    @State private var year: Int
    @State private var text: String
    @State private var remember = false

    static let rememberTitle = "Remember for this issuer"

    init(field: ImportFigureField, current: ImportFactValue?, currency: Currency, confirming: Bool, remembers: Bool = false,
         resolve: @escaping (ImportResolution) -> Void) {
        self.field = field
        self.confirming = confirming
        self.remembers = remembers
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
        case .amount, .accountTotal, .pay, .taxDeducted, .openingBalance, .closingBalance: return .money
        case .taxYear: return .year
        case .currency, .invoiceNumber, .receiptNumber, .reference, .issuer, .person, .rows, .instalments, .fund, .taxCode: return .text
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

    /// The answer the typed value gives: an issuer's name names the issuer (`.setIssuer`); a
    /// figure ticked "Remember for this issuer" is remembered (its position, never its value).
    private func answer(_ value: ImportFactValue) -> ImportResolution {
        if field == .issuer, case .text(let name) = value { return .setIssuer(name) }
        return remembers && remember ? .confirmFigureRemembering(field, value) : .confirmFigure(field, value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            fields
            if remembers {
                Toggle(Self.rememberTitle, isOn: $remember)
                    .toggleStyle(.checkbox)
                    .help("Where this figure sits on the page is remembered for this issuer's next documents, never its value")
            }
        }
        .controlSize(.small)
        .font(.callout)
    }

    private var fields: some View {
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
                if let value { resolve(answer(value)) }
            }
            .disabled(value == nil)
        }
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

/// Which property, person, account, tenancy, provider or recorded invoice the document is for.
/// A recorded invoice's name (amount first) is never truncated: the picker takes its width.
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
        // An invoice's choice (up to ~280 pt) takes the line; its button goes below.
        let layout = kind == .invoice ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            Picker(kind.rawValue.capitalized, selection: $chosen) {
                ForEach(options, id: \.self) { Text(names.name(kind, $0)).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: kind == .invoice ? nil : 200)
            .fixedSize(horizontal: kind == .invoice, vertical: false)
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
    /// The document's issuer key, if any ("Remember for this issuer").
    var issuer: IssuerKey? = nil
    let resolve: (ImportResolution) -> Void

    /// Whether the model's reading is asked as a whole (its table: the model's figures and kind aren't asked again here).
    private var modelReadingAsked: Bool {
        item.issues.contains { $0.kind == .confirmModelReading }
    }

    /// Figures to check that no issue already asks about.
    private var facts: [ImportFact] {
        let asked = Set(item.issues.compactMap { issue -> ImportFigureField? in
            switch issue.kind {
            case .confirmFigure(let field), .missingFigure(let field): return field
            default: return nil
            }
        })
        return item.facts.filter { $0.confidence == .needsReview && !asked.contains($0.field)
            && !(modelReadingAsked && $0.source == .model) }
    }

    /// Whether the kind is unsure and no issue asks it.
    private var asksKind: Bool {
        item.recognition.confidence == .needsReview && !(modelReadingAsked && ImportModelProposals.isProposed(item.recognition))
            && !item.issues.contains { issue in
            switch issue.kind {
            case .unknownKind, .kindMismatch: return true
            default: return false
            }
        }
    }

    /// Links to check that no question ("which one?", instalments) already asks about.
    private var links: [ProposedLink] {
        let asked = item.linksAskedByIssues
        return item.links.filter { $0.confidence == .needsReview && !asked.contains($0.entity) }
    }

    var body: some View {
        let facts = facts, links = links
        if asksKind || !facts.isEmpty || !links.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if asksKind {
                    check(item.recognition.reason) {
                        ImportKindChooser(initial: item.recognition.kind, keep: nil, resolve: resolve)
                    }
                }
                ForEach(facts, id: \.field) { fact in
                    check(Self.reason(fact)) {
                        ImportFigureEditor(field: fact.field, current: fact.value,
                                           currency: ImportIssueControls.currency(of: item, field: fact.field),
                                           confirming: true,
                                           remembers: LearntFigures.offersRemembering(item, field: fact.field, issuer: issuer),
                                           resolve: resolve)
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

// MARK: The model's reading

/// What the on-device model read (`confirmModelReading`): its proposed kind and figures in a small
/// table, each with a pencil to correct it (an answer for the item), and "Use these" to take them
/// as they are (learnt for the issuer on Confirm import).
struct ImportModelReading: View {
    let item: ImportItem
    let issuer: IssuerKey?
    let accept: () -> Void
    let resolve: (ImportResolution) -> Void
    /// The row being corrected (nil: none); `kindRow` for the kind.
    @State private var editing: String?

    private static let kindRow = "kind"

    private var facts: [ImportFact] { item.facts.filter { $0.source == .model } }
    private var proposesKind: Bool { ImportModelProposals.isProposed(item.recognition) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                if proposesKind {
                    GridRow {
                        label("Kind")
                        Text(item.kindName).font(.callout).figureText()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        pencil(Self.kindRow, "kind")
                    }
                }
                ForEach(facts, id: \.field) { fact in
                    GridRow {
                        label(fact.field.displayName)
                        ImportFactValueView(value: fact.value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        pencil(fact.field.rawValue, fact.field.displayName.lowercased())
                    }
                }
            }
            if editing == Self.kindRow {
                ImportKindChooser(initial: item.recognition.kind, keep: nil) { resolution in
                    editing = nil
                    resolve(resolution)
                }
            } else if let editing, let fact = facts.first(where: { $0.field.rawValue == editing }) {
                ImportFigureEditor(field: fact.field, current: fact.value,
                                   currency: ImportIssueControls.currency(of: item, field: fact.field), confirming: true,
                                   remembers: LearntFigures.offersRemembering(item, field: fact.field, issuer: issuer)) { resolution in
                    self.editing = nil
                    resolve(resolution)
                }
                .id("\(item.id)-model-\(editing)")
            }
            Button("Use these", action: accept)
                .controlSize(.small)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
    }

    private func pencil(_ row: String, _ name: String) -> some View {
        Button {
            editing = editing == row ? nil : row
        } label: {
            Image(systemName: "pencil").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Change the \(name)")
        .accessibilityLabel("Change the \(name)")
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
