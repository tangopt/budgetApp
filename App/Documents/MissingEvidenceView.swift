// App/Documents/MissingEvidenceView.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore
import struct BudgetCore.Transaction

/// The Missing evidence screen (spec 2026-10-16 §7, UI polish §4.2): for a UK tax year (or a
/// custom range), everything the rules expect. A summary on top — the period's progress as a
/// ring with its figures, and each usual source's progress — then the checklist as a table
/// grouped by source (collapsible strips), one line per item: status, date, what it is, the
/// evidence it needs or has, the amount, and its actions (an icon for the main one, the rest
/// in a ••• menu and the context menu). A file dropped on a row, or added with Add document…,
/// goes to the importer with the row's record as its link target (nothing is added before
/// Confirm import).
///
/// Standalone, Rules… and Export checklist… are in the toolbar. Embedded (`embedded`, the Tax
/// years page's tab) the page picks the year and pads the content, so there is no period
/// picker or padding of its own, and those two sit in the summary instead.
struct MissingEvidenceView: View {
    @ObservedObject var viewModel: MissingEvidenceViewModel
    /// Shows a transaction: Search, on its day and account, with its row selected.
    let openTransaction: (Transaction) -> Void
    /// Shown inside Tax years: no period picker, toolbar items or padding of its own.
    var embedded = false
    @Environment(\.theme) private var theme
    @Environment(\.documentImport) private var documentImport

    @State private var linking: MissingEvidence.Item?
    @State private var waiving: MissingEvidence.Item?
    @State private var showingRules = false
    @State private var seeding = false
    @State private var exportDocument: MarkdownDocument?
    /// Sources whose rows are folded away.
    @State private var collapsed: Set<String> = []

    /// The narrowest the page lays out at: the summary's two panels side by side
    /// (`TwoUpRow`'s 340 pt each). Embedded, what Tax years has left at a 1100-wide window.
    static let minimumWidth: CGFloat = 700
    static let embeddedMinimumWidth: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            summary
            // The property chip stays reachable when its filter leaves nothing to show.
            if hasChecklist || viewModel.propertyFilter != nil {
                filterBar
            }
            messages
            checklist
                // The table or empty state takes the rest of the window below the summary.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // The page's minimum is measured at this width, where the summary's panels sit side by
        // side: measured narrower, they stacked and the window's minimum height came to 932 pt
        // (the checklist scrolls in whatever height is left).
        .frame(minWidth: embedded ? Self.embeddedMinimumWidth : Self.minimumWidth)
        // Standalone: padded like Accounts and Budget. Embedded: the page pads the sides and
        // top; the bottom is ours.
        .padding(embedded ? [.bottom] : .all, ScreenMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .primaryAction) {
                    rulesButton
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    exportButton
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .markdownText, defaultFilename: viewModel.exportFileName) { result in
            if case .failure(let error) = result { viewModel.errorMessage = "Couldn't export: \(error.localizedDescription)" }
            exportDocument = nil
        }
        .sheet(item: $linking) { item in
            LinkEvidenceSheet(item: item, viewModel: viewModel)
        }
        .sheet(item: $waiving) { item in
            WaiveEvidenceSheet(item: item, viewModel: viewModel)
        }
        .sheet(isPresented: $showingRules) {
            EvidenceRulesSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $seeding) {
            PropertyRulesSheet(viewModel: viewModel)
        }
    }

    /// The period has items to show (the checklist, not an empty state).
    private var hasChecklist: Bool {
        viewModel.period != nil && !viewModel.requirements.isEmpty && !viewModel.items.isEmpty
    }

    private var rulesButton: some View {
        Button { showingRules = true } label: {
            Label("Rules…", systemImage: "list.bullet.clipboard")
        }
        .buttonStyle(.borderless)
        .help("Evidence rules: what the checklist expects")
        .accessibilityLabel("Evidence rules")
    }

    private var exportButton: some View {
        Button {
            if let markdown = viewModel.markdown() { exportDocument = MarkdownDocument(text: markdown) }
        } label: {
            Label("Export checklist…", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.items.isEmpty)
        .help("Export checklist… as Markdown")
        .accessibilityLabel("Export checklist")
    }

    // MARK: Summary

    @ViewBuilder
    private var summary: some View {
        if hasChecklist {
            if embedded {
                // Always side by side under the Tax years header: stacked (a `TwoUpRow` at its
                // narrowest), the summary pushed the page past a 1280×800 window.
                HStack(alignment: .top, spacing: ScreenMetrics.spacing) {
                    progressPanel.frame(maxWidth: .infinity)
                    sourcesPanel.frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                TwoUpRow {
                    progressPanel
                } second: {
                    sourcesPanel
                }
            }
        } else {
            // Nothing to sum up: the period (a picker standalone) and, embedded, the actions
            // the toolbar has standalone.
            HStack(spacing: 8) {
                periodControl
                Spacer(minLength: 0)
                if embedded {
                    rulesButton
                    exportButton
                }
            }
        }
    }

    private var progressPanel: some View {
        let progress = viewModel.progress
        return Panel(padding: 14, fillsHeight: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    periodControl
                    Spacer(minLength: 8)
                    if embedded {
                        HStack(spacing: 10) {
                            rulesButton.labelStyle(.iconOnly)
                            exportButton.labelStyle(.iconOnly)
                        }
                    }
                }
                // The ring and figures centred in the height the sources beside it take.
                Spacer(minLength: 12)
                HStack(alignment: .center, spacing: 16) {
                    ProgressRing(done: progress.done, total: progress.total, size: 68, caption: nil)
                        .accessibilityLabel("Evidence collected")
                    FigureStrip([
                        FigureTile(title: "Expected", value: .text("\(progress.total)")),
                        FigureTile(title: "Has document", value: .text("\(progress.satisfied)")),
                        FigureTile(title: "Not available", value: .text("\(progress.waived)")),
                        FigureTile(title: "Missing", value: .text("\(progress.missing)"),
                                   caption: progress.missing == 0 ? "Nothing missing" : "Drop files on a row",
                                   captionIsWarning: progress.missing > 0)
                    ])
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var sourcesPanel: some View {
        let sources = viewModel.sources
        let half = (sources.count + 1) / 2
        // Always two columns: a one-column fallback would raise the window's minimum height
        // (the summary sizes the screen when it's squeezed), and the names truncate first.
        return Panel("By source", subtitle: "Where the documents usually come from", fillsHeight: true) {
            HStack(alignment: .top, spacing: 20) {
                sourceColumn(Array(sources.prefix(half)))
                if sources.count > 1 {
                    sourceColumn(Array(sources.dropFirst(half)))
                }
            }
        }
    }

    private func sourceColumn(_ sources: [MissingEvidence.SourceGroup]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sources, id: \.source) { sourceRow($0) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func sourceRow(_ group: MissingEvidence.SourceGroup) -> some View {
        HStack(spacing: 6) {
            ProgressRing(done: group.progress.done, total: group.progress.total, size: 14, lineWidth: 3)
            // Only the name gives way (tightened first, whole on hover); the figures keep their width.
            Text(group.source).lineLimit(1).truncationMode(.tail).allowsTightening(true)
                .help(group.source)
            Spacer(minLength: 6)
            if group.progress.missing > 0 {
                Text("\(group.progress.missing) missing")
                    .foregroundStyle(theme.pending)
                    .figureText()
            }
            Text("\(group.progress.done)/\(group.progress.total)")
                .foregroundStyle(.secondary)
                .figureText()
                .frame(minWidth: 36, alignment: .trailing)
        }
        .font(.callout.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.source): \(group.progress.done) of \(group.progress.total) done, \(group.progress.missing) missing")
    }

    /// The period: a menu of tax years (and a custom range) standalone; the page's year, as
    /// a title, embedded.
    @ViewBuilder
    private var periodControl: some View {
        if embedded {
            Text(viewModel.periodTitle).font(.headline).figureText()
        } else {
            HStack(spacing: 8) {
                Menu {
                    ForEach(viewModel.years, id: \.self) { year in
                        Button("Tax year \(year.label)") { viewModel.periodChoice = .taxYear(year.startYear) }
                    }
                    Divider()
                    Button("Custom range") { viewModel.periodChoice = .custom }
                } label: {
                    HStack(spacing: 4) {
                        Text(viewModel.periodChoice == .custom ? "Custom range" : viewModel.periodTitle)
                            .font(.headline)
                            .figureText()
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("The period the checklist covers")
                .accessibilityLabel("Period")
                .accessibilityValue(viewModel.periodTitle)
                if viewModel.periodChoice == .custom {
                    DatePicker("From", selection: utcDay($viewModel.customFirstDay), displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("From")
                    Text("to").foregroundStyle(.secondary)
                    DatePicker("To", selection: utcDay($viewModel.customLastDay), displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("To")
                }
            }
            .controlSize(.small)
        }
    }

    /// A DatePicker's local midnight ↔ the stored UTC midnight of the same day.
    private func utcDay(_ binding: Binding<Date>) -> Binding<Date> {
        Binding(get: { PayCalendar.localDay(sameDayAs: binding.wrappedValue, in: .current) },
                set: { binding.wrappedValue = PayCalendar.utcDay(sameDayAs: $0, in: .current) })
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("Show", selection: $viewModel.missingOnly) {
                Text("Missing").tag(true)
                Text("All").tag(false)
            }
            .pickerStyle(.segmented).prominentTint()
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Show")
            SearchField("Search descriptions, categories, kinds or an amount", text: $viewModel.queryText)
                .frame(maxWidth: 360)
            if let filter = viewModel.propertyFilter {
                Button { viewModel.propertyFilter = nil } label: {
                    HStack(spacing: 4) {
                        Text(filter.name).lineLimit(1)
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .foregroundStyle(theme.accent)
                }
                .controlSize(.small)
                .fixedSize()
                .help("Showing only \(filter.name)'s rules. Click to show everything.")
                .accessibilityLabel("Property filter: \(filter.name). Remove filter")
            }
            Spacer(minLength: 8)
            let shown = viewModel.groups.reduce(0) { $0 + $1.items.count }
            Text(shown == 1 ? "1 item" : "\(shown) items")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                .figureText()
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let error = viewModel.errorMessage {
            InlineBanner(.error, error) { viewModel.errorMessage = nil }
        }
        if let info = viewModel.infoMessage {
            InlineBanner(.info, info) { viewModel.infoMessage = nil }
        }
    }

    // MARK: Checklist

    @ViewBuilder
    private var checklist: some View {
        if viewModel.period == nil {
            ContentUnavailableView("Pick a range", systemImage: "calendar",
                                   description: Text("The range must end on or after the day it starts."))
        } else if viewModel.isLoading, viewModel.items.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.requirements.isEmpty {
            ContentUnavailableView {
                Label("No evidence rules yet", systemImage: "checklist")
            } description: {
                Text("Rules say which transactions and periods need a document. Start with the property rules for a category group, or add your own.")
            } actions: {
                Button("Set up property rules…") { seeding = true }
                    .buttonStyle(.borderedProminent).prominentTint()
                Button("Rules…") { showingRules = true }
            }
        } else if viewModel.items.isEmpty {
            ContentUnavailableView("Nothing expected", systemImage: "checkmark.seal",
                                   description: Text("No rule expects a document in \(viewModel.periodTitle.unbroken)."))
        } else if viewModel.groups.isEmpty {
            if viewModel.missingOnly, viewModel.queryText.isEmpty {
                ContentUnavailableView("Nothing missing", systemImage: "checkmark.seal",
                                       description: Text("Every item in \(viewModel.periodTitle.unbroken) has its document or is marked not available."))
            } else {
                ContentUnavailableView.search(text: viewModel.queryText)
            }
        } else {
            ChecklistTable(groups: viewModel.groups, collapsed: $collapsed,
                           progress: { viewModel.progress(source: $0) },
                           actions: actions(for:))
        }
    }

    private func actions(for item: MissingEvidence.Item) -> MissingEvidenceRow.Actions {
        let transaction = item.target.entity.type == .transaction
        // The importer captured here: the row's ••• and context menus may not inherit the environment.
        let documentImport = documentImport
        return MissingEvidenceRow.Actions(
            addFiles: documentImport.map { importer in { importer.pickShortcut(MissingEvidenceRow.shortcut(item)) } },
            linkExisting: { linking = item },
            waive: { waiving = item },
            removeWaiver: { viewModel.removeWaiver(item) },
            unlink: { documentId in viewModel.unlink(documentId: documentId, from: item) },
            showTransaction: transaction ? {
                if let found = viewModel.transaction(for: item) { openTransaction(found) } else { viewModel.errorMessage = "The transaction no longer exists." }
            } : nil)
    }
}

/// The checklist's columns, shared by the header strip and every row so they line up.
private enum ChecklistColumns {
    static let status: CGFloat = 110
    static let amount: CGFloat = 112
    static let actions: CGFloat = 60
    static let evidenceMin: CGFloat = 150
    static let evidenceMax: CGFloat = 240
    /// Each cell's side padding.
    static let cellPadding: CGFloat = 8
    /// The row's own inset, so the first and last cells clear the card's edge.
    static let rowInset: CGFloat = 6
    /// The date column, about (a `DateText` and its padding).
    static let date: CGFloat = 112
    /// What the item column gets before the evidence column grows past its minimum.
    static let itemFirst: CGFloat = 480

    /// The evidence column's width for a table `width` wide: the item takes the width first
    /// (about `itemFirst`), the evidence what's left, between its minimum and maximum. One
    /// width for the header and every row, so the columns line up.
    static func evidence(tableWidth width: CGFloat) -> CGFloat {
        let fixed = status + date + amount + actions + 2 * rowInset
        return min(evidenceMax, max(evidenceMin, width - fixed - itemFirst))
    }
}

/// The checklist as a card-framed table (the `DataTable` look): a header strip, then per source
/// a sticky strip (fold it with its chevron; its progress over the whole period) and the
/// source's rows, shaded alternately with a separator under each. Lazy, so long periods
/// scroll smoothly.
private struct ChecklistTable: View {
    let groups: [MissingEvidence.SourceGroup]
    @Binding var collapsed: Set<String>
    let progress: (String) -> MissingEvidence.Progress
    let actions: (MissingEvidence.Item) -> MissingEvidenceRow.Actions
    @Environment(\.theme) private var theme
    /// The rows' height, so a short checklist's card ends with its last row.
    @State private var contentHeight: CGFloat = 0
    /// The table's width, measured once for the header and every row (the evidence column).
    @State private var width: CGFloat = 0

    private var evidenceWidth: CGFloat { ChecklistColumns.evidence(tableWidth: width) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.source) { group in
                        Section {
                            if !collapsed.contains(group.source) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    MissingEvidenceRow(item: item, shaded: index % 2 == 1,
                                                       evidenceWidth: evidenceWidth, actions: actions(item))
                                }
                            }
                        } header: {
                            groupStrip(group)
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(maxHeight: contentHeight > 0 ? contentHeight : .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Panel<EmptyView, EmptyView>.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Panel<EmptyView, EmptyView>.cornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var header: some View {
        HStack(spacing: 0) {
            title("Status").frame(width: ChecklistColumns.status, alignment: .leading)
            // As wide as the rows' dates.
            DateText(date: nil).hidden()
                .overlay(alignment: .leading) { Text("Date").font(.caption).foregroundStyle(.secondary) }
                .padding(.horizontal, ChecklistColumns.cellPadding)
            // The item takes the width first; the evidence column gives way down to its minimum.
            title("Item").frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            title("Evidence").frame(width: evidenceWidth, alignment: .leading)
            title("Amount").frame(width: ChecklistColumns.amount, alignment: .trailing)
            Color.clear.frame(width: ChecklistColumns.actions, height: 1)
        }
        .padding(.horizontal, ChecklistColumns.rowInset)
        .padding(.vertical, 5)
        .background(theme.gridHeaderBackground)
        .overlay(alignment: .bottom) { Rectangle().frame(height: 1).foregroundStyle(.separator) }
        .accessibilityHidden(true)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, ChecklistColumns.cellPadding)
    }

    private func groupStrip(_ group: MissingEvidence.SourceGroup) -> some View {
        let isCollapsed = collapsed.contains(group.source)
        let progress = progress(group.source)
        return HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(group.source).font(.subheadline.bold()).lineLimit(1)
            if isCollapsed {
                Text(group.items.count == 1 ? "1 item" : "\(group.items.count) items")
                    .font(.caption).foregroundStyle(.secondary)
                    .figureText()
            }
            Spacer(minLength: 8)
            Text("\(progress.done) of \(progress.total) done")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .figureText()
            ProgressRing(done: progress.done, total: progress.total, size: 14, lineWidth: 3)
        }
        .padding(.horizontal, ChecklistColumns.rowInset + ChecklistColumns.cellPadding)
        .padding(.vertical, 5)
        // Opaque, so rows scrolling under the pinned strip don't show through.
        .background { ZStack { theme.windowFill; theme.surface; theme.sectionHeaderTint } }
        .overlay(alignment: .bottom) { Rectangle().frame(height: 1).foregroundStyle(.separator) }
        .contentShape(Rectangle())
        .onTapGesture { toggle(group.source) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.source): \(progress.done) of \(progress.total) done")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityAction { toggle(group.source) }
        .help(isCollapsed ? "Show \(group.source)'s items" : "Hide \(group.source)'s items")
    }

    private func toggle(_ source: String) {
        if collapsed.contains(source) { collapsed.remove(source) } else { collapsed.insert(source) }
    }
}

/// One checklist item on one line: its status, the day (the transaction's, or the start of the
/// slot it covers), what it is with its rule, category and account after it, the documents it
/// needs (or has, or why not), the amount, and its actions — the main one as an icon, the
/// rest in the ••• menu (also the row's context menu). Files dropped on it are added and linked.
struct MissingEvidenceRow: View {
    struct Actions {
        /// Add document…: the importer's open panel (nil: no importer).
        let addFiles: (() -> Void)?
        let linkExisting: () -> Void
        let waive: () -> Void
        let removeWaiver: () -> Void
        let unlink: (Int64) -> Void
        let showTransaction: (() -> Void)?
    }

    let item: MissingEvidence.Item
    var shaded = false
    /// The evidence column's width (the table's, `ChecklistColumns.evidence`).
    var evidenceWidth: CGFloat = ChecklistColumns.evidenceMin
    let actions: Actions
    @Environment(\.theme) private var theme

    /// What Add document… and a drop on the row hand the importer: the row's record as the link
    /// target, the document kind it asks for (when it asks for one kind) as the expected kind,
    /// and its slot (a periodic item) for a document without a period of its own.
    static func shortcut(_ item: MissingEvidence.Item) -> ImportShortcut {
        .attach(item.target.entity, role: nil, from: .missingEvidence,
                expected: item.expectedKinds.count == 1 ? item.expectedKinds.first : nil, period: item.expectedPeriod)
    }

    var body: some View {
        HStack(spacing: 0) {
            status
                .padding(.horizontal, ChecklistColumns.cellPadding)
                .frame(width: ChecklistColumns.status, alignment: .leading)
            DateText(date: item.expectedDate ?? item.expectedPeriod?.start)
                .padding(.horizontal, ChecklistColumns.cellPadding)
            description
                .padding(.horizontal, ChecklistColumns.cellPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            evidence
                .padding(.horizontal, ChecklistColumns.cellPadding)
                .frame(width: evidenceWidth, alignment: .leading)
            amount
                .padding(.horizontal, ChecklistColumns.cellPadding)
                .frame(width: ChecklistColumns.amount, alignment: .trailing)
            trailingActions
                .padding(.horizontal, ChecklistColumns.cellPadding)
                .frame(width: ChecklistColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, ChecklistColumns.rowInset)
        .padding(.vertical, 3)
        .frame(minHeight: 28)
        .background(theme.rowBackground(shaded))
        .overlay(alignment: .bottom) { Rectangle().frame(height: 1).foregroundStyle(.separator.opacity(0.6)) }
        .contentShape(Rectangle())
        .importDropTarget(Self.shortcut(item))
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
    }

    // MARK: Cells

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .missing:
            StatusPill("Missing", tone: .warning, systemImage: "circle.dashed")
                .help("Missing — drop a file on the row, or add or link one")
        case .satisfied:
            StatusPill("Done", tone: .positive, systemImage: "checkmark")
                .help("Has its document")
        case .waived:
            StatusPill(item.waiver?.reason == .other ? "Waived" : "Not available", tone: .neutral, systemImage: "minus.circle")
                .help("Counts as done; Remove waiver asks for a document again")
        }
    }

    /// What it is, then (secondary) its slot, rule, category and account.
    private var description: some View {
        let detail = caption
        let secondary = Text(verbatim: detail.isEmpty ? "" : "  ·  " + detail).font(.callout).foregroundStyle(.secondary)
        return Text("\(Text(verbatim: item.title))\(secondary)")
            .lineLimit(1)
            .truncationMode(.tail)
            .help(detail.isEmpty ? item.title : "\(item.title)\n\(detail)")
            .accessibilityLabel(detail.isEmpty ? item.title : "\(item.title), \(detail)")
    }

    private var caption: String {
        var parts: [String] = []
        if let slot = item.expectedPeriod { parts.append(MissingEvidenceFormat.slot(slot)) }
        if item.title != item.requirement.name { parts.append(item.requirement.name) }
        if let category = item.categoryName, !item.requirement.name.hasSuffix(category) { parts.append(category) }
        if let account = item.accountName { parts.append(account) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var evidence: some View {
        switch item.status {
        case .missing:
            Text("Needs " + MissingEvidenceViewModel.kindsText(item.expectedKinds))
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Needs " + MissingEvidenceViewModel.kindsText(item.expectedKinds))
        case .satisfied:
            let names = item.satisfyingDocuments.map(\.displayName)
            HStack(spacing: 4) {
                Image(systemName: "paperclip").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(names.joined(separator: "; "))
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.callout)
            .help(names.joined(separator: "\n"))
            .accessibilityLabel("Documents: " + names.joined(separator: ", "))
        case .waived:
            let reason = item.waiver?.reason == .other ? "Waived" : "Not available"
            let text = item.waiver?.note.flatMap { $0.isEmpty ? nil : $0 } ?? reason
            Text(text)
                .font(.callout).italic().foregroundStyle(.secondary)
                .lineLimit(1)
                .help([reason, item.waiver?.note].compactMap { $0 }.joined(separator: ": "))
        }
    }

    @ViewBuilder
    private var amount: some View {
        if let amount = item.expectedAmountMinorUnits, let currency = item.currency {
            // The amount on the transaction, as given: neither a gain nor a loss here.
            MoneyText(minorUnits: amount, currency: currency, role: .neutral, alignment: .trailing)
        } else {
            Text("—").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
    }

    // MARK: Actions

    private var trailingActions: some View {
        HStack(spacing: 6) {
            switch item.status {
            case .missing:
                Button { actions.addFiles?() } label: { Image(systemName: "doc.badge.plus") }
                    .disabled(actions.addFiles == nil)
                    .help("Add document…: import a file and link it to this item")
                    .accessibilityLabel("Add document for \(item.title)")
            case .waived:
                Button(action: actions.removeWaiver) { Image(systemName: "arrow.uturn.backward.circle") }
                    .help("Remove waiver: ask for a document again")
                    .accessibilityLabel("Remove waiver for \(item.title)")
            case .satisfied:
                Image(systemName: "doc.badge.plus").hidden().accessibilityHidden(true)
            }
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions for \(item.title)")
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(item.status == .satisfied ? "Add another document…" : "Add document…") { actions.addFiles?() }
            .disabled(actions.addFiles == nil)
        Button("Link existing…", action: actions.linkExisting)
        Divider()
        switch item.status {
        case .missing:
            Button("Mark not available…", action: actions.waive)
        case .waived:
            Button("Edit waiver…", action: actions.waive)
            Button("Remove waiver", action: actions.removeWaiver)
        case .satisfied:
            ForEach(item.satisfyingDocuments) { document in
                Button("Unlink “\(document.displayName)”") { actions.unlink(document.id) }
            }
        }
        if let show = actions.showTransaction {
            Divider()
            Button("Show transaction", action: show)
        }
    }
}

/// The exported checklist.
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownText] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UTType {
    /// Markdown (`net.daringfireball.markdown`), known to the system.
    static var markdownText: UTType { UTType("net.daringfireball.markdown") ?? .plainText }
}
