// App/DocumentImport/ImportReviewView.swift
import SwiftUI
import BudgetCore
import GRDB

// MARK: The review's state

/// The open plan as the review shows it — its sections, Ready's groups, each statement's
/// rows and the footer's counts — worked out once when the plan changes
/// (`ImportCenterModel.plan`), so drawing the review never walks the plan.
struct ImportReviewState {
    /// A document's row: the item, the line under its title, its figure.
    struct Row: Identifiable {
        let item: ImportItem
        /// The row's title when not the item's (a duplicate file's name).
        var title: String? = nil
        let detail: String?
        let figure: ImportFactValue?
        /// A statement's row (a possible duplicate) shown indented under its statement.
        var isIndented = false
        var id: UUID { item.id }
    }

    /// A Ready group: its one-line summary and its documents.
    struct Group: Identifiable {
        let id: String
        let title: String
        let summary: String
        let rows: [Row]
    }

    let needsYou: [Row]
    let ready: [Group]
    let duplicates: [Row]
    let leftOut: [Row]
    /// Every item by id (the preview's selection).
    let items: [UUID: ImportItem]
    /// A statement's rows held apart from it (rows already imported), by the statement.
    let children: [UUID: [ImportItem]]
    /// A statement's rows the checks ask about or the user answered (`StatementChecks.isRowChild`:
    /// possible duplicates, kept and skipped rows), by the statement: shown under it, never as
    /// documents of their own (a possible duplicate also as its own Needs-you row, indented).
    let rows: [UUID: [ImportItem]]
    /// Left-out items that "Put back" brings back: not a statement's rows while the statement
    /// is out (they come back with it; Core refuses them alone).
    let canPutBack: Set<UUID>
    let readyCount: Int
    /// "4 ready · 2 need you · 1 duplicate".
    let countsLine: String
    let canConfirm: Bool
    let ignoredFiles: [String]
    let isEmpty: Bool

    init(_ plan: ImportPlan) {
        var byId: [UUID: ImportItem] = [:]
        for item in plan.items { byId[item.id] = item }
        var bySection: [ImportSection: [ImportItem]] = [:]
        var children: [UUID: [ImportItem]] = [:]
        var rows: [UUID: [ImportItem]] = [:]
        var documents: [ImportItem] = []
        for item in plan.items {
            if let parentId = item.parentId, let parent = byId[parentId], StatementChecks.isRowChild(item, of: parent) {
                rows[parentId, default: []].append(item)
                continue
            }
            documents.append(item)
            bySection[item.section, default: []].append(item)
            if let parentId = item.parentId { children[parentId, default: []].append(item) }
        }
        items = byId
        self.children = children
        self.rows = rows
        // A statement's rows to keep or skip right under it, indented.
        var needsYou: [Row] = []
        for item in bySection[.needsYou] ?? [] {
            needsYou.append(Row(item: item, detail: item.needsYouReasons.first, figure: item.headlineFigure))
            for row in rows[item.id] ?? [] where row.section == .needsYou {
                needsYou.append(Row(item: row, detail: row.needsYouReasons.first, figure: nil, isIndented: true))
            }
        }
        // (A statement's rows wait only while it does: never without it, but shown if so.)
        let shown = Set(needsYou.map(\.id))
        for item in plan.items where item.section == .needsYou && !shown.contains(item.id) {
            if let parentId = item.parentId, rows[parentId]?.contains(where: { $0.id == item.id }) == true {
                needsYou.append(Row(item: item, detail: item.needsYouReasons.first, figure: nil, isIndented: true))
            }
        }
        self.needsYou = needsYou
        duplicates = (bySection[.duplicates] ?? []).map { Row(item: $0, title: $0.parentId == nil ? $0.file.fileName : $0.title, detail: $0.duplicate?.of, figure: nil) }
        canPutBack = Set((bySection[.leftOut] ?? []).filter { item in
            item.parentId.flatMap { byId[$0] }?.isLeftOut != true
        }.map(\.id))
        leftOut = (bySection[.leftOut] ?? []).map { Row(item: $0, detail: $0.recognition.kind.displayName, figure: $0.headlineFigure) }
        // Ready's groups and summaries without the statements' rows (a kept row is its statement's).
        ready = ImportPlan(items: documents).readyGroups.map { group in
            Group(id: group.id, title: group.title, summary: group.summary,
                  rows: group.itemIds.compactMap { byId[$0] }.map { Row(item: $0, detail: $0.readyDetail, figure: $0.headlineFigure) })
        }
        canConfirm = plan.canConfirm
        ignoredFiles = plan.ignoredFiles
        isEmpty = documents.isEmpty
        readyCount = bySection[.ready]?.count ?? 0
        countsLine = Self.countsLine(ready: readyCount, needsYou: needsYou.count,
                                     duplicates: duplicates.count, leftOut: leftOut.count)
    }

    /// Ready and Needs you always; duplicates and left out when there are any.
    static func countsLine(ready: Int, needsYou: Int, duplicates: Int, leftOut: Int) -> String {
        var parts = ["\(ready) ready", "\(needsYou) need\(needsYou == 1 ? "s" : "") you"]
        if duplicates > 0 { parts.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s")") }
        if leftOut > 0 { parts.append("\(leftOut) left out") }
        return parts.joined(separator: " · ")
    }
}

/// The names a "which one?" question offers: properties, people, accounts, tenancies and
/// utility providers, by id.
struct ImportTargetNames: Equatable, Sendable {
    var names: [ImportTargetKind: [Int64: String]] = [:]

    func name(_ kind: ImportTargetKind, _ id: Int64) -> String {
        if let name = names[kind]?[id] { return name }
        switch kind {
        case .property: return "Property #\(id)"
        case .person: return "Person #\(id)"
        case .account: return "Account #\(id)"
        case .tenancy: return "Tenancy #\(id)"
        case .provider: return "Provider #\(id)"
        }
    }

    static func read(_ db: Database) throws -> ImportTargetNames {
        func byId<T>(_ records: [T], _ id: KeyPath<T, Int64?>, _ name: (T) -> String) -> [Int64: String] {
            var result: [Int64: String] = [:]
            for record in records { if let key = record[keyPath: id] { result[key] = name(record) } }
            return result
        }
        let properties = try Property.fetchAll(db)
        let propertyNames = byId(properties, \.id, \.name)
        let providers = try UtilityProvider.fetchAll(db)
        return ImportTargetNames(names: [
            .property: propertyNames,
            .person: byId(try Person.fetchAll(db), \.id, \.name),
            .account: byId(try Account.fetchAll(db), \.id, \.displayName),
            .tenancy: byId(try Tenancy.fetchAll(db), \.id, \.referenceLabel),
            // "EDP · Flat 1": a provider's name alone may be shared by two properties.
            .provider: byId(providers, \.id) { provider in
                propertyNames[provider.propertyId].map { "\(provider.name) · \($0)" } ?? provider.name
            }
        ])
    }
}

// MARK: The review

/// The open review (layout "option A"): on the left Needs you (each with why), Ready grouped
/// by kind with a one-line summary per group (expandable per document), Duplicates skipped
/// (with what each duplicates) and Left out (Put back); docked on the right the selected
/// document's preview with its questions; beneath, the counts, Add files…, Discard and
/// Confirm import (disabled while anything needs the user).
struct ImportReviewView: View {
    @ObservedObject var center: ImportCenterModel
    let pickFiles: () -> Void
    @State private var confirmingDiscard = false

    static let listMinimumWidth: CGFloat = 520
    static let previewWidth: CGFloat = 360
    /// The list's and the preview's minimum side by side: the Imports screen's minimum while a
    /// review is open (892, a 1036 pt window: within 1100×700).
    static let minimumWidth = listMinimumWidth + ScreenMetrics.spacing + previewWidth

    /// Answers are taken only in the review, one at a time (a second click waits for the first).
    private var isAnswerable: Bool { center.phase == .review && !center.isResolving }

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            if let problem = center.problem {
                InlineBanner(.error, onDismiss: { center.problem = nil }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(problem.title.figuresUnbroken).fontWeight(.medium)
                        ForEach(Array(problem.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.figuresUnbroken).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let review = center.review {
                HStack(alignment: .top, spacing: ScreenMetrics.spacing) {
                    ImportReviewList(review: review, selectedItemId: $center.selectedItemId,
                                     isAnswerable: isAnswerable, putBack: { center.resolve($0, .leaveOut) })
                        .frame(minWidth: Self.listMinimumWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    ImportPreviewPanel(item: center.selectedItemId.flatMap { review.items[$0] },
                                       children: center.selectedItemId.flatMap { review.children[$0] } ?? [],
                                       rows: center.selectedItemId.flatMap { review.rows[$0] } ?? [],
                                       canPutBack: center.selectedItemId.map(review.canPutBack.contains) ?? false,
                                       targetNames: center.targetNames, isAnswerable: isAnswerable, center: center,
                                       resolve: { itemId, issueId, resolution in center.resolve(itemId, issueId: issueId, resolution) })
                        .frame(width: Self.previewWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                footer(review)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Discard this import?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { center.discard() }
            Button("Keep reviewing", role: .cancel) {}
        } message: {
            Text("Nothing from these files has been saved.")
        }
    }

    private func footer(_ review: ImportReviewState) -> some View {
        let canConfirm = isAnswerable && review.canConfirm
        return HStack(alignment: .center, spacing: 8) {
            Text(review.countsLine).font(.callout).foregroundStyle(.secondary).figureText()
            Spacer(minLength: 8)
            if center.phase == .applying || center.isResolving {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(center.phase == .applying ? "Importing" : "Updating the review")
            }
            Button("Add files…", action: pickFiles)
                .disabled(center.phase != .review)
            Button("Discard") { confirmingDiscard = true }
                .disabled(center.phase != .review)
            Button("Confirm import") { center.confirm() }
                .buttonStyle(.borderedProminent)
                .disabled(!canConfirm)
                .help(review.canConfirm ? "Files the documents and records what they hold, as one import you can undo"
                                        : "Settle everything in Needs you first")
        }
    }
}

extension ImportSection {
    /// The section's title in the review.
    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .ready: return "Ready"
        case .duplicates: return "Duplicates skipped"
        case .leftOut: return "Left out"
        }
    }
}

// MARK: The list

/// The review's sections, each a panel of rows; a row selects its document for the preview.
private struct ImportReviewList: View {
    let review: ImportReviewState
    @Binding var selectedItemId: UUID?
    let isAnswerable: Bool
    let putBack: (UUID) -> Void
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
                if review.isEmpty {
                    Panel {
                        Text("Nothing to import from these files: add files, or discard this import.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !review.needsYou.isEmpty {
                    section(.needsYou, count: review.needsYou.count) {
                        ForEach(review.needsYou) { row($0, needsYou: true) }
                    }
                }
                if !review.ready.isEmpty {
                    section(.ready, count: review.readyCount) {
                        ForEach(review.ready) { group in
                            DisclosureGroup(isExpanded: expanded(group.id)) {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(group.rows) { row($0) }
                                }
                                .padding(.top, 4)
                            } label: {
                                Text(group.summary.figuresUnbroken)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help(group.title)
                            }
                        }
                    }
                }
                if !review.duplicates.isEmpty {
                    section(.duplicates, count: review.duplicates.count) {
                        ForEach(review.duplicates) { row($0) }
                    }
                }
                if !review.leftOut.isEmpty {
                    section(.leftOut, count: review.leftOut.count) {
                        ForEach(review.leftOut) { leftOut in
                            let item = leftOut.item
                            row(leftOut) {
                                // A statement's rows follow it: they come back with it.
                                if review.canPutBack.contains(item.id) {
                                    Button("Put back") { putBack(item.id) }
                                        .controlSize(.small)
                                        .disabled(!isAnswerable)
                                        .help("Import this file again with the others")
                                }
                            }
                        }
                    }
                }
                if !review.ignoredFiles.isEmpty {
                    Text("Not read: \(review.ignoredFiles.joined(separator: ", "))")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // A Ready document selected from outside the list (the review opened on it)
        // shows in its group.
        .onAppear(perform: revealSelection)
        .onChange(of: selectedItemId) { revealSelection() }
    }

    private func revealSelection() {
        guard let id = selectedItemId, let group = review.ready.first(where: { $0.rows.contains { $0.id == id } }) else { return }
        expandedGroups.insert(group.id)
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedGroups.contains(id) },
                set: { if $0 { expandedGroups.insert(id) } else { expandedGroups.remove(id) } })
    }

    private func section<Rows: View>(_ section: ImportSection, count: Int, @ViewBuilder rows: () -> Rows) -> some View {
        Panel(section.title, accessory: { StatusPill("\(count)", tone: section == .needsYou ? .warning : .neutral) }) {
            LazyVStack(alignment: .leading, spacing: 2) { rows() }
        }
    }

    private func row(_ row: ImportReviewState.Row, title: String? = nil, needsYou: Bool = false) -> some View {
        self.row(row, title: title, needsYou: needsYou) { EmptyView() }
    }

    private func row<Accessory: View>(_ row: ImportReviewState.Row, title: String? = nil, needsYou: Bool = false,
                                      @ViewBuilder accessory: () -> Accessory) -> some View {
        let item = row.item
        return ImportReviewRow(item: item, title: title ?? row.title ?? item.title, detail: row.detail, figure: row.figure, needsYou: needsYou,
                               isIndented: row.isIndented, children: review.children[item.id] ?? [], rows: review.rows[item.id] ?? [],
                               isSelected: selectedItemId == item.id,
                               select: { selectedItemId = item.id }, accessory: accessory())
    }
}

/// One document: (Needs you) its pill, its title over why it sits in its section, a
/// statement's rows held apart beneath, and its main figure.
private struct ImportReviewRow<Accessory: View>: View {
    let item: ImportItem
    let title: String
    let detail: String?
    let figure: ImportFactValue?
    let needsYou: Bool
    let isIndented: Bool
    let children: [ImportItem]
    let rows: [ImportItem]
    let isSelected: Bool
    let select: () -> Void
    let accessory: Accessory
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isIndented {
                // A row of the statement above: under it, its own question.
                Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .accessibilityHidden(true)
            }
            if needsYou {
                StatusPill("Needs you", tone: .warning)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if let detail {
                    Text(detail.figuresUnbroken).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ImportStatementLines(item: item, children: children, rows: rows, listsUnparsedLines: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let figure {
                ImportFactValueView(value: figure)
            }
            accessory
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? theme.selectionFill : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Show in the preview", select)
    }
}

/// A statement's rows held apart ("3 rows already imported") and the lines it
/// couldn't read (a count in the list, the lines themselves in the preview).
struct ImportStatementLines: View {
    let item: ImportItem
    let children: [ImportItem]
    /// Its rows answered: skipped ("Skipped: not imported") and kept ones (the rows still
    /// asked about are their own rows in Needs you).
    var rows: [ImportItem] = []
    let listsUnparsedLines: Bool

    /// "05/11/2026 SHOP €12.00 · Skipped: not imported", "… · Kept".
    static func answeredLine(_ row: ImportItem) -> String? {
        if StatementChecks.isSkippedRow(row) { return "\(row.title) · \(StatementChecks.skippedNote)" }
        if row.section != .needsYou, !row.isLeftOut { return "\(row.title) · Kept" }
        return nil
    }

    private var unparsed: [String] {
        item.issues.flatMap { issue -> [String] in
            if case .statement(.unparsedLines(let lines)) = issue.kind { return lines }
            return []
        }
    }

    var body: some View {
        let unparsed = unparsed
        let answered = rows.compactMap { row in Self.answeredLine(row).map { (row.id, $0) } }
        if !children.isEmpty || !unparsed.isEmpty || !answered.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(children) { child in
                    Label {
                        Text((child.duplicate?.of ?? child.title).figuresUnbroken)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrow.turn.down.right")
                    }
                }
                ForEach(answered, id: \.0) { _, line in
                    Label {
                        Text(line.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrow.turn.down.right")
                    }
                }
                if !unparsed.isEmpty {
                    Label {
                        Text("\(unparsed.count) line\(unparsed.count == 1 ? "" : "s") not read".unbroken)
                    } icon: {
                        Image(systemName: "arrow.turn.down.right")
                    }
                    if listsUnparsedLines {
                        ForEach(Array(unparsed.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).lineLimit(1).truncationMode(.tail)
                                .padding(.leading, 18)
                                .help(line)
                        }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: Figures

extension ImportItem {
    /// The figure a row shows: the amount (or pay), else the date or period start, else the tax year.
    var headlineFigure: ImportFactValue? {
        for field in [ImportFigureField.amount, .pay, .docDate, .periodStart, .taxYear] {
            if let fact = facts.first(where: { $0.field == field }) { return fact.value }
        }
        return nil
    }

    /// A Ready row's line: its first note, else what it links to, else where it's filed.
    var readyDetail: String? {
        // A link the user chose is named first, with the others ("Links to Flat 1 · THE GOLDEN SPOON").
        let chosen = links.contains { $0.reasons.contains(ImportResolutions.chosenReasonText) }
        if !chosen, let note = notes.first { return note }
        if !links.isEmpty { return "Links to " + links.map(\.label).joined(separator: " · ") }
        if let note = notes.first { return note }
        return placement.map { "Filed as \($0.canonicalName)" }
    }
}

/// A fact's value as a figure: an amount (`MoneyText`, as on the document), a day
/// (`DateText`), a tax year, or a text figure on one line.
struct ImportFactValueView: View {
    let value: ImportFactValue
    var font: Font = .callout

    var body: some View {
        switch value {
        case .money(let minorUnits, let currency):
            MoneyText(minorUnits: minorUnits, currency: currency, font: font.monospacedDigit(), role: .neutral)
        case .date(let date):
            DateText(date: date, font: font)
        case .year(let startYear):
            Text(UKTaxYear(startYear: startYear).label).font(font.monospacedDigit()).figureText()
        case .text(let text):
            Text(text).font(font).figureText()
        }
    }
}

extension ImportFactSource {
    /// Where a figure came from, as its pill says.
    var pillTitle: String {
        switch self {
        case .textLayer: return "Text"
        case .ocr: return "OCR"
        case .fileName: return "File name"
        case .user: return "You"
        case .matchedRecord: return "From the app"
        case .intent: return "Import target"
        case .learntRule: return "Learnt rule"
        case .model: return "Model"
        }
    }
}
