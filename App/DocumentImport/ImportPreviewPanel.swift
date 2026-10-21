// App/DocumentImport/ImportPreviewPanel.swift
import SwiftUI
import BudgetCore

/// The selected document, docked beside the review's list: the file, what it was recognised as
/// and why, the figures read (each with where it came from), where it will be filed, what it
/// will link to and why, the lines shown with it, a statement's rows held apart and the
/// information-only changes to a filed year. Its questions, with their answers, come first
/// under its title.
struct ImportPreviewPanel: View {
    let item: ImportItem?
    let children: [ImportItem]
    /// A statement's rows to keep or skip (possible duplicates, kept and skipped rows).
    let rows: [ImportItem]
    /// A left-out item that can come back (not a statement's rows while the statement is out).
    let canPutBack: Bool
    let targetNames: ImportTargetNames
    let isAnswerable: Bool
    /// The linked transactions' peeks and the link search.
    @ObservedObject var center: ImportCenterModel
    /// (item, issue, answer).
    let resolve: (UUID, String?, ImportResolution) -> Void

    private var pendingUndoShown: Binding<Bool> {
        Binding(get: { center.pendingUndo != nil }, set: { if !$0 { center.pendingUndo = nil } })
    }

    private var undoTitle: String {
        let count = center.pendingUndo?.others ?? 0
        return "Also undo the changes on \(count) other document\(count == 1 ? "" : "s")?"
    }

    var body: some View {
        Panel(padding: 12, fillsHeight: true) {
            if let item, center.linkSearchItemId == item.id {
                // Over the preview, the review staying as it is beside it.
                ImportLinkSearchPanel(item: item, center: center, isAnswerable: isAnswerable) { resolve(item.id, nil, $0) }
                    .id("search-\(item.id)")
            } else if let item {
                ScrollView {
                    ImportPreviewContent(item: item, children: children, rows: rows, canPutBack: canPutBack, targetNames: targetNames,
                                         isAnswerable: isAnswerable, center: center, resolve: resolve)
                        .padding(.trailing, 4)
                }
                // A new document starts at its top, with its own answers' state.
                .id(item.id)
            } else {
                Text("Select a document to see what was read from it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $center.ruleFitsReview) { review in
            let source = center.plan?.items.first { $0.id == review.sourceId }
            ImportRuleFitsSheet(sourceName: source?.file.fileName ?? "this document",
                                rules: center.plan?.appliedRuleDrafts(of: review.sourceId).map(\.actionLabel) ?? [],
                                fits: center.ruleFits[review.sourceId] ?? [],
                                apply: { center.applyRule(from: review.sourceId, to: $0) },
                                cancel: { center.ruleFitsReview = nil })
        }
        .confirmationDialog(undoTitle, isPresented: pendingUndoShown, titleVisibility: .visible) {
            Button("Undo all") { center.finishPendingUndo(alsoOthers: true) }
            Button("Keep them") { center.finishPendingUndo(alsoOthers: false) }
            Button("Cancel", role: .cancel) { center.pendingUndo = nil }
        } message: {
            Text("Undo all also reverts every change this document's rules made on the other documents of this import. Keep them leaves those changes as they are.")
        }
    }
}

private struct ImportPreviewContent: View {
    let item: ImportItem
    let children: [ImportItem]
    let rows: [ImportItem]
    let canPutBack: Bool
    let targetNames: ImportTargetNames
    let isAnswerable: Bool
    @ObservedObject var center: ImportCenterModel
    let resolve: (UUID, String?, ImportResolution) -> Void
    /// The figure being changed (its pencil in Figures).
    @State private var editingField: ImportFigureField?

    /// A P11D's effect: its benefit rows are corrected in the Benefits table (the amount is their total).
    private var p11d: PayrollFormImport.Confirmed? {
        if case .payrollForm(let confirmed) = item.effect, confirmed.kind == .p11d { return confirmed }
        return nil
    }
    private var isP11D: Bool { p11d != nil }

    /// A statement's row (kept, skipped or asked about) takes only Keep / Skip: no corrections.
    private var correctable: Bool { ImportResolutions.isCorrectable(item) && !isStatementRow }

    /// A statement's row (kept, skipped or asked about): a child with nothing of its own to do.
    private var isStatementRow: Bool { item.parentId != nil && item.effect == .none }

    /// The document's issuer key ("Remember for this issuer" is offered only with one).
    private var issuer: IssuerKey? { center.issuerKey(of: item) }

    /// Whether `target` was ticked off in this review (it shows "Checked" and Undo).
    private func isMarked(_ target: ImportCheckTarget) -> Bool { center.plan?.isMarkedChecked(item.id, target) == true }

    /// Whether the model's reading is asked (its figures are corrected in that question's table).
    private var modelReadingAsked: Bool { item.issues.contains { $0.kind == .confirmModelReading } }

    /// The notes saying a corrected figure is fixed for this document only: shown with the figures.
    private var fixedNotes: [String] { item.notes.filter(LearntFigures.fixedNotes.contains) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DocumentThumbnail(url: item.file.url, height: 150)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if item.title != item.file.fileName {
                    Text(item.file.fileName).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(item.file.fileName)
                }
            }

            // Every "Check it" of the document at once (questions that need a choice stay), or those ticks taken back together.
            if center.plan?.isMarkedAllChecked(item.id) == true {
                HStack(spacing: 4) {
                    Label("All checks marked", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                    Button { resolve(item.id, nil, .unmarkAllChecked) } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.tint)
                    .help("Undo all checks")
                    .accessibilityLabel("Undo all checks")
                }
                .disabled(!isAnswerable)
            }
            // Offered whenever two checks or more can be ticked (again, after some were taken back).
            if ImportChecks.canMarkAll(item) {
                Button("Mark all as checked") { resolve(item.id, nil, .markAllChecked) }
                    .controlSize(.small)
                    .help("Tick every “Check it” on this document; questions that need a choice stay")
                    .disabled(!isAnswerable)
            }

            if item.section == .needsYou {
                block("Needs you") {
                    VStack(alignment: .leading, spacing: 10) {
                        let holds = item.issues.filter { ImportResolutions.onlyLeavesOut($0, in: item) }
                        if !holds.isEmpty {
                            // Held (a filed return would move, the check failed, the file can't be
                            // read): why, and one answer for the item — nothing else is asked.
                            ForEach(holds) { issue in
                                if ImportResolutions.isFiledYearHold(issue) {
                                    ImportHoldBanner(issue: issue)
                                } else {
                                    Label {
                                        Text(issue.reason.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
                                    } icon: {
                                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                }
                            }
                            Button(ImportIssueControls.leaveOutTitle) { resolve(item.id, nil, .leaveOut) }
                                .controlSize(.small)
                        } else {
                            ForEach(item.issues) { issue in
                                ImportIssueControls(item: item, issue: issue, targetNames: targetNames, accounts: center.accounts,
                                                    answerProblem: center.answerProblem.flatMap { problem in
                                                        problem.itemId == item.id && problem.issueId == issue.id ? problem.message : nil
                                                    },
                                                    issuer: issuer,
                                                    resolveItem: { resolve(item.id, nil, $0) }) { resolution in
                                    resolve(item.id, issue.id, resolution)
                                }
                            }
                            ImportItemChecks(item: item, issuer: issuer) { resolution in resolve(item.id, nil, resolution) }
                            // Once for the item, after its questions; a statement's row has Skip instead
                            // (the pipeline takes Leave out on it as Skip).
                            if !isStatementRow {
                                Button(ImportIssueControls.leaveOutTitle) { resolve(item.id, nil, .leaveOut) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .disabled(!isAnswerable)
            } else if item.isLeftOut {
                if canPutBack {
                    Button("Put back") { resolve(item.id, nil, .leaveOut) }
                        .controlSize(.small)
                        .disabled(!isAnswerable)
                } else {
                    Text("Comes back with its statement").font(.callout).foregroundStyle(.secondary)
                }
            } else if item.duplicate == nil {
                Button(ImportIssueControls.leaveOutTitle) { resolve(item.id, nil, .leaveOut) }
                    .controlSize(.small)
                    .disabled(!isAnswerable)
            }

            if let summary = ImportStatementSummary(item: item) {
                block("Statement") {
                    ImportStatementSummaryView(summary: summary)
                }
            }

            if !rows.isEmpty {
                block("Rows that look already saved") {
                    ImportStatementRows(rows: rows) { row, resolution in resolve(row.id, nil, resolution) }
                        .disabled(!isAnswerable)
                }
            }

            block("Recognised as \(item.recognition.kind.displayName)") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.recognition.reason.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if item.recognition.confidence == .needsReview || isMarked(.recognition) {
                            ImportCheckPill(title: "Check it", help: item.recognition.reason, target: .recognition,
                                            item: item, plan: center.plan, isAnswerable: isAnswerable) { resolve(item.id, nil, $0) }
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    if correctable {
                        // Ready items too: any change is checked again (it may move to Needs you).
                        ImportCorrections(item: item, targetNames: targetNames) { resolve(item.id, nil, $0) }
                            .disabled(!isAnswerable)
                    }
                }
            }

            // A statement's period, balances and legs are in its Statement block.
            let shownAbove: Set<ImportFigureField> = ImportStatementSummary(item: item) == nil ? []
                : [.periodStart, .periodEnd, .openingBalance, .closingBalance, .instalments, .fund]
            let figures = item.facts.filter { !shownAbove.contains($0.field) }
            if !figures.isEmpty {
                block("Figures") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(figures, id: \.field) { fact in
                            GridRow {
                                Text(fact.field.displayName).font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                                ImportFactValueView(value: fact.value)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ImportCheckPill(title: fact.source.pillTitle, help: fact.reason, target: .figure(fact.field),
                                                item: item, plan: center.plan, isAnswerable: isAnswerable) { resolve(item.id, nil, $0) }
                                // A model figure is corrected in its question's table while asked (one edit path per field).
                                if correctable, !(modelReadingAsked && fact.source == .model), !(fact.field == .amount && isP11D) {
                                    Button {
                                        editingField = editingField == fact.field ? nil : fact.field
                                    } label: {
                                        Image(systemName: "pencil").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Change the \(fact.field.displayName.lowercased())")
                                    .accessibilityLabel("Change the \(fact.field.displayName.lowercased())")
                                }
                            }
                        }
                    }
                    if correctable, let field = editingField, let fact = item.facts.first(where: { $0.field == field }) {
                        ImportFigureEditor(field: field, current: fact.value,
                                           currency: ImportIssueControls.currency(of: item, field: field),
                                           confirming: false,
                                           remembers: LearntFigures.offersRemembering(item, field: field, issuer: issuer)) { resolution in
                            editingField = nil
                            resolve(item.id, nil, resolution)
                        }
                        .id("\(item.id)-edit-\(field.rawValue)")
                        .disabled(!isAnswerable)
                        .padding(.top, 4)
                    }
                    ForEach(fixedNotes, id: \.self) { note in
                        Text(note.figuresUnbroken).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let confirmed = p11d, correctable {
                block("Benefits") {
                    ImportBenefitsEditor(benefits: confirmed.benefits) { resolve(item.id, nil, .setBenefits($0)) }
                        .id("\(item.id)-benefits-" + confirmed.benefits.map { "\($0.kind.rawValue):\($0.cashEquivalentMinorUnits)" }.joined(separator: ","))
                        .disabled(!isAnswerable)
                }
            }

            if !item.appliedRules.isEmpty {
                block("Learnt rules used") {
                    ImportAppliedRules(uses: item.appliedRules) { center.showImportRule($0) }
                }
            }

            let recognisesItself = item.notes.contains(ImportLearning.recognisesItselfNote)
            if !item.ruleDrafts.isEmpty || recognisesItself {
                // What Confirm import will learn from the corrections made here (and the kind it won't).
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(item.ruleDrafts.enumerated()), id: \.offset) { _, draft in
                        Label {
                            Text(ImportAppliedRules.willRemember(draft).figuresUnbroken)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "wand.and.stars").foregroundStyle(.secondary)
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    if recognisesItself {
                        Label {
                            Text(ImportLearning.recognisesItselfNote).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "wand.and.stars").foregroundStyle(.tertiary)
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            // The correction's rule on the other documents of this import, and a rule's change here.
            ImportRuleFitLines(item: item, center: center, isAnswerable: isAnswerable)

            if let placement = item.placement {
                block("Filed as") {
                    Text(placement.canonicalName.figuresUnbroken).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            if !item.links.isEmpty || correctable {
                block("Links to") {
                    ImportLinksSection(item: item, center: center) { resolve(item.id, nil, $0) }
                        .disabled(!isAnswerable)
                }
            }

            if let duplicate = item.duplicate {
                block("Duplicate") {
                    Text(duplicate.of.figuresUnbroken).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            let notes = item.notes.filter { ($0 != ImportLearning.recognisesItselfNote) && (!LearntFigures.fixedNotes.contains($0) || figures.isEmpty) }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        Text(note.figuresUnbroken).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // (In Needs you, its question lists the lines not read.)
            ImportStatementLines(item: item, children: children, listsUnparsedLines: item.section != .needsYou)

            if !item.informationChanges.isEmpty {
                block("Changes to filed years (information only)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(item.informationChanges.enumerated()), id: \.offset) { _, impact in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(UKTaxYear(startYear: impact.startYear).label.unbroken) · \(impact.person)")
                                    .font(.caption.weight(.medium))
                                ForEach(Array(impact.informationChanges.enumerated()), id: \.offset) { _, line in
                                    Text("\(line.label): \(line.before.unbroken) → \(line.after.unbroken)")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.figuresUnbroken).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }
}


// MARK: Checks

/// A figure's source pill, or a recognition's "Check it": to check, it is a button that ticks it
/// off in place ("Mark as checked", `.markChecked`); ticked off in this review, it says "Checked"
/// with Undo (`.unmarkChecked`, exactly what was there before); otherwise the plain pill.
struct ImportCheckPill: View {
    let title: String
    let help: String
    let target: ImportCheckTarget
    let item: ImportItem
    let plan: ImportPlan?
    let isAnswerable: Bool
    let resolve: (ImportResolution) -> Void

    static let markHelp = "Mark as checked"

    var body: some View {
        if plan?.isMarkedChecked(item.id, target) == true {
            HStack(spacing: 4) {
                StatusPill("Checked", tone: .positive, help: ImportChecks.checkedReason)
                Button { resolve(.unmarkChecked(target)) } label: {
                    Image(systemName: "arrow.uturn.backward")
                        // A comfortable hit area around a small glyph.
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.tint)
                .help("Undo")
                .accessibilityLabel("Undo check")
                .disabled(!isAnswerable)
            }
        } else if ImportChecks.canMark(target, on: item) {
            Button { resolve(.markChecked(target)) } label: {
                StatusPill(title, tone: .warning, systemImage: "checkmark.circle")
            }
            .buttonStyle(.plain)
            .help(Self.markHelp)
            .accessibilityLabel("\(Self.markHelp): \(title)")
            .disabled(!isAnswerable)
        } else {
            let unsure = target == .recognition ? item.recognition.confidence == .needsReview
                : item.facts.contains { if case .figure(let field) = target { return $0.field == field && $0.confidence == .needsReview }; return false }
            StatusPill(title, tone: unsure ? .warning : .neutral, help: help)
        }
    }
}

// MARK: Rules on the other documents

/// Under a correction's "Will remember": "This rule also fits N other documents in this import"
/// with Review (the sheet), and once applied "Changed N other documents by this rule" with an
/// undo for all of them; on a document a rule changed, "Changed by your rule from <name>" with
/// the undo (that document only), as a ticked check has it.
struct ImportRuleFitLines: View {
    let item: ImportItem
    @ObservedObject var center: ImportCenterModel
    let isAnswerable: Bool

    var body: some View {
        let fits = center.ruleFits[item.id] ?? []
        let changed = center.plan?.ruleChangedItems(from: item.id) ?? []
        let source = center.plan?.ruleChangeSource(of: item.id)
        if !fits.isEmpty || !changed.isEmpty || source != nil {
            VStack(alignment: .leading, spacing: 4) {
                if !fits.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        line(Self.fitsLine(fits.count), systemImage: "wand.and.stars")
                        Button("Review") { center.reviewRuleFits(item.id) }
                            .controlSize(.small)
                            .fixedSize()
                    }
                }
                if !changed.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        line(Self.changedLine(changed.count), systemImage: "checkmark.circle")
                        undoButton(help: "Undo the changes on the other documents") { center.undoRuleChanges(from: item.id) }
                    }
                }
                if let source {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        line("Changed by your rule from \(source.name)", systemImage: "wand.and.stars")
                        undoButton(help: "Undo this change") { center.undoRuleChange(item.id) }
                    }
                }
            }
            .disabled(!isAnswerable)
        }
    }

    static func fitsLine(_ count: Int) -> String {
        "This rule also fits \(count) other document\(count == 1 ? "" : "s") in this import"
    }

    static func changedLine(_ count: Int) -> String {
        "Changed \(count) other document\(count == 1 ? "" : "s") by this rule"
    }

    private func line(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    /// The undo icon of a ticked check (`ImportCheckPill`).
    private func undoButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.tint)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "Apply your rule to other documents": each document the correction's rule fits, its name then
/// each change as before → after, ticked by default; Apply changes the ticked ones (as the user's
/// answers there), Cancel nothing.
struct ImportRuleFitsSheet: View {
    let sourceName: String
    let rules: [String]
    let fits: [ImportRuleFit]
    let apply: (Set<UUID>) -> Void
    let cancel: () -> Void
    @State private var unticked: Set<UUID> = []

    private var ticked: Set<UUID> { Set(fits.map(\.itemId)).subtracting(unticked) }

    var body: some View {
        SheetScaffold(title: "Apply your rule to other documents",
                      subtitle: subtitle,
                      width: SheetMetrics.listWidth,
                      onCancel: cancel,
                      primary: SheetAction(ticked.isEmpty ? "Apply" : "Apply to \(ticked.count)", isEnabled: !ticked.isEmpty) { apply(ticked) }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(fits.enumerated()), id: \.element.id) { index, fit in
                        if index > 0 { Divider() }
                        row(fit)
                    }
                }
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            .sheetListFrame()
        }
    }

    private var subtitle: String {
        let what = rules.isEmpty ? "" : ": " + rules.joined(separator: "; ")
        return "From \(sourceName)\(what). Nothing is learnt until you confirm the import."
    }

    private func row(_ fit: ImportRuleFit) -> some View {
        let isOn = Binding(get: { !unticked.contains(fit.itemId) },
                           set: { on in if on { unticked.remove(fit.itemId) } else { unticked.insert(fit.itemId) } })
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(fit.documentName, isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(fit.documentName)
            VStack(alignment: .leading, spacing: 3) {
                Text(fit.documentName.figuresUnbroken).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { isOn.wrappedValue.toggle() }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                    ForEach(Array(fit.changes.enumerated()), id: \.offset) { _, change in
                        GridRow {
                            Text(change.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            // Side by side when both fit, else the new value under the old: never clipped.
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    value(change.before)
                                    arrow
                                    value(change.after)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    value(change.before)
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        arrow
                                        value(change.after)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var arrow: some View {
        Text("→").font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func value(_ value: ImportRuleChangeValue) -> some View {
        switch value {
        case .none:
            Text("None").font(.caption).foregroundStyle(.secondary)
        case .text(let text):
            // Names and labels wrap as prose (figures in them stay whole); only figures never wrap.
            Text(text.figuresUnbroken).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        case .figure(let fact):
            ImportFactValueView(value: fact, font: .caption)
        }
    }
}

// MARK: Learnt rules

/// The learnt rules that shaped a document, each named as it was applied, with "Show on Rules
/// page" (Rules ▸ Import rules, the rule selected).
struct ImportAppliedRules: View {
    let uses: [ImportRuleUse]
    let show: (Int64) -> Void

    /// "Will remember: Example Seguros → Kind: Insurance receipt": what Confirm import learns from a
    /// correction, and the learnt rule it replaces ("(replaces: Paid by “OTHER”)").
    static func willRemember(_ draft: ImportRuleDraft) -> String {
        "Will remember: \(draft.matchLabel) → \(draft.actionLabel)" + (draft.replaces.map { " (replaces: \($0))" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(uses.enumerated()), id: \.offset) { _, use in
                // The link under its label: neither is squeezed.
                VStack(alignment: .leading, spacing: 1) {
                    Text(use.label.figuresUnbroken).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show on Rules page") { show(use.ruleId) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .fixedSize()
                }
            }
        }
    }
}

// MARK: Statements

/// A bank statement's preview lines, read from the item's own facts, effect and issues (no
/// database, no plan walk): its period, opening → closing, its
/// rows (new, already imported, skipped), what its legs move (BBVA instalments and fund) and
/// whether its closing balance matches.
struct ImportStatementSummary {
    enum Check { case matches, differs, none }

    var periodStart: Date?
    var periodEnd: Date?
    var opening: Int?
    var closing: Int?
    var currency: Currency
    var newRows: Int
    var alreadyImported: Int
    var skipped: Int
    var legs: [String]
    var check: Check
    /// The reason given for importing it anyway.
    var reason: String?

    init?(item: ImportItem) {
        guard item.parentId == nil else { return nil }
        func date(_ field: ImportFigureField) -> Date? {
            if case .date(let value)? = item.facts.first(where: { $0.field == field })?.value { return value }
            return nil
        }
        func money(_ field: ImportFigureField) -> (Int, Currency)? {
            if case .money(let value, let currency)? = item.facts.first(where: { $0.field == field })?.value { return (value, currency) }
            return nil
        }
        func text(_ field: ImportFigureField) -> String? {
            if case .text(let value)? = item.facts.first(where: { $0.field == field })?.value { return value }
            return nil
        }
        let closingCheck: StatementClosing?
        switch item.effect {
        case .ukStatement(let effect):
            newRows = effect.staged.count
            alreadyImported = effect.certainDuplicates.count
            skipped = effect.skipped.count
            closingCheck = effect.statement?.closing
        case .bbvaStatement(let effect):
            newRows = effect.staged.count
            alreadyImported = effect.certainDuplicates.count
            skipped = effect.skipped.count
            closingCheck = effect.closing
        default:
            return nil
        }
        periodStart = date(.periodStart)
        periodEnd = date(.periodEnd)
        opening = money(.openingBalance)?.0
        closing = money(.closingBalance)?.0 ?? closingCheck?.balanceMinorUnits
        currency = money(.closingBalance)?.1 ?? money(.openingBalance)?.1 ?? ImportIssueControls.currency(of: item, field: .closingBalance)
        legs = [text(.instalments), text(.fund)].compactMap { $0 }
        let differs = item.issues.contains { issue in
            if case .statement(.balanceMismatch) = issue.kind { return true }
            return false
        } || item.resolutionNote != nil
        check = closingCheck == nil ? .none : differs ? .differs : .matches
        reason = item.resolutionNote
    }

    /// "3 new · 38 already imported · 1 skipped".
    var rowsLine: String {
        var parts = ["\(newRows) new"]
        if alreadyImported > 0 { parts.append("\(alreadyImported) already imported") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: " · ")
    }
}

struct ImportStatementSummaryView: View {
    let summary: ImportStatementSummary

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            if let start = summary.periodStart, let end = summary.periodEnd {
                GridRow {
                    label("Period")
                    HStack(spacing: 4) {
                        // Trailing in its width, so the dash stays close.
                        DateText(date: start, font: .callout, alignment: .trailing)
                        Text("–").font(.callout).foregroundStyle(.secondary)
                        DateText(date: end, font: .callout)
                    }
                }
            }
            if summary.opening != nil || summary.closing != nil {
                GridRow {
                    label(summary.opening == nil ? "Closing" : "Opening → closing")
                    HStack(spacing: 4) {
                        if let opening = summary.opening {
                            money(opening)
                            Text("→").font(.callout).foregroundStyle(.secondary)
                        }
                        if let closing = summary.closing { money(closing) }
                    }
                }
            }
            GridRow {
                label("Rows")
                Text(summary.rowsLine).font(.callout).figureText()
            }
            ForEach(Array(summary.legs.enumerated()), id: \.offset) { _, line in
                GridRow {
                    label("Legs")
                    Text(line.figuresUnbroken).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            if summary.check != .none {
                GridRow {
                    label("Check")
                    HStack(spacing: 6) {
                        StatusPill(summary.check == .matches ? "Balance matches" : "Balance differs",
                                   tone: summary.check == .matches ? .positive : .warning)
                        if let reason = summary.reason {
                            Text("Imported anyway: \(reason)".figuresUnbroken).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
    }

    private func money(_ minorUnits: Int) -> some View {
        MoneyText(minorUnits: minorUnits, currency: summary.currency, font: .callout.monospacedDigit(), role: .neutral)
            .figureText()
    }
}

/// A statement's rows that look already saved, each with its answer: Keep / Skip while asked,
/// then Skip (a kept row) or Keep (a skipped one, "Skipped: not imported") to change it.
struct ImportStatementRows: View {
    let rows: [ImportItem]
    let resolve: (ImportItem, ImportResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title.figuresUnbroken).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text(state(row).figuresUnbroken).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if StatementChecks.isSkippedRow(row) {
                        Button("Keep") { resolve(row, .keepRow) }
                    } else if row.section == .needsYou {
                        Button("Keep") { resolve(row, .keepRow) }
                        Button("Skip") { resolve(row, .skipRow) }
                    } else {
                        Button("Skip") { resolve(row, .skipRow) }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func state(_ row: ImportItem) -> String {
        if StatementChecks.isSkippedRow(row) { return StatementChecks.skippedNote }
        if row.section == .needsYou { return row.needsYouReasons.first ?? "Keep or skip it" }
        return "Kept: imported with the statement"
    }
}
