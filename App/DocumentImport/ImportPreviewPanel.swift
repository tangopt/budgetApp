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

    /// A statement's row (kept, skipped or asked about) takes only Keep / Skip: no corrections.
    private var correctable: Bool { ImportResolutions.isCorrectable(item) && !isStatementRow }

    /// A statement's row (kept, skipped or asked about): a child with nothing of its own to do.
    private var isStatementRow: Bool { item.parentId != nil && item.effect == .none }

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
                                                    }) { resolution in
                                    resolve(item.id, issue.id, resolution)
                                }
                            }
                            ImportItemChecks(item: item) { resolution in resolve(item.id, nil, resolution) }
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
                        if item.recognition.confidence == .needsReview {
                            StatusPill("Check it", tone: .warning)
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
                                StatusPill(fact.source.pillTitle, tone: fact.confidence == .needsReview ? .warning : .neutral,
                                           help: fact.reason)
                                if correctable {
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
                                           confirming: false) { resolution in
                            editingField = nil
                            resolve(item.id, nil, resolution)
                        }
                        .id("\(item.id)-edit-\(field.rawValue)")
                        .disabled(!isAnswerable)
                        .padding(.top, 4)
                    }
                }
            }

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

            if !item.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(item.notes.enumerated()), id: \.offset) { _, note in
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
