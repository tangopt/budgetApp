// App/Documents/MissingEvidenceView.swift
import SwiftUI
import UniformTypeIdentifiers
import BudgetCore
import struct BudgetCore.Transaction

/// The Missing evidence screen (spec 2026-10-16 §7): for a UK tax year (or a custom range),
/// everything the rules expect, grouped by where it usually comes from, with progress
/// overall and per source. Each item takes a dropped file or Add document… (copied into the
/// library and linked to its record at once), Link existing…, Mark not available… / Remove
/// waiver, and Show for its transaction. Rules… and Export checklist… are in the toolbar.
struct MissingEvidenceView: View {
    @ObservedObject var viewModel: MissingEvidenceViewModel
    /// Shows a transaction where it lives (its Budget cell, or Uncategorized).
    let openTransaction: (Transaction) -> Void
    @Environment(\.theme) private var theme

    @State private var importing = false
    /// The item Add document… adds to (kept until the importer completes).
    @State private var importTarget: MissingEvidence.Item?
    @State private var linking: MissingEvidence.Item?
    @State private var waiving: MissingEvidence.Item?
    @State private var showingRules = false
    @State private var seeding = false
    @State private var exportDocument: MarkdownDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            filterBar
            messages
            checklist
                // The list or empty state takes the rest of the window below the header.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Top-aligned and filling the window, padded like Accounts and Budget.
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingRules = true } label: {
                    Label("Rules…", systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(.borderless)
                .help("Evidence rules: what the checklist expects")
                .accessibilityLabel("Evidence rules")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
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
            .sharedBackgroundVisibility(.hidden)
        }
        // The target is read and cleared in the completion: the binding's setter runs before
        // it, so it mustn't clear the target itself.
        .fileImporter(isPresented: $importing, allowedContentTypes: EvidenceFiles.contentTypes, allowsMultipleSelection: true) { result in
            guard let item = importTarget else { return }
            importTarget = nil
            switch result {
            case .success(let urls): viewModel.add(urls, to: item)
            case .failure(let error): viewModel.errorMessage = error.localizedDescription
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

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("Period", selection: $viewModel.periodChoice) {
                ForEach(viewModel.years, id: \.self) { year in
                    Text("Tax year \(year.label)").tag(MissingEvidenceViewModel.PeriodChoice.taxYear(year.startYear))
                }
                Divider()
                Text("Custom range").tag(MissingEvidenceViewModel.PeriodChoice.custom)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Period")
            if viewModel.periodChoice == .custom {
                DatePicker("From", selection: utcDay($viewModel.customFirstDay), displayedComponents: .date)
                    .fixedSize()
                DatePicker("To", selection: utcDay($viewModel.customLastDay), displayedComponents: .date)
                    .fixedSize()
            }
            Spacer(minLength: 12)
            if viewModel.period != nil, !viewModel.items.isEmpty {
                overallProgress
            }
        }
    }

    private var overallProgress: some View {
        let progress = viewModel.progress
        return HStack(spacing: 8) {
            ProgressView(value: progress.fractionDone)
                .frame(width: 140)
                .tint(progress.missing == 0 ? theme.income : theme.accent)
            Text("\(progress.percentDone)% done")
                .fontWeight(.semibold)
                .monospacedDigit()
            Text("\(progress.done) of \(progress.total) · \(progress.missing) missing")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.percentDone) percent done, \(progress.done) of \(progress.total), \(progress.missing) missing")
    }

    /// A DatePicker's local midnight ↔ the stored UTC midnight of the same day.
    private func utcDay(_ binding: Binding<Date>) -> Binding<Date> {
        Binding(get: { PayCalendar.localDay(sameDayAs: binding.wrappedValue, in: .current) },
                set: { binding.wrappedValue = PayCalendar.utcDay(sameDayAs: $0, in: .current) })
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("Show", selection: $viewModel.missingOnly) {
                Text("Missing").tag(true)
                Text("All").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Show")
            searchField
                .frame(maxWidth: 360)
            Spacer()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search descriptions, categories, kinds or an amount", text: $viewModel.queryText)
                .textFieldStyle(.plain)
            if !viewModel.queryText.isEmpty {
                Button { viewModel.queryText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder
    private var messages: some View {
        if let error = viewModel.errorMessage {
            banner(error, systemImage: "exclamationmark.triangle.fill", color: theme.expense) { viewModel.errorMessage = nil }
        }
        if let info = viewModel.infoMessage {
            banner(info, systemImage: "info.circle", color: .secondary) { viewModel.infoMessage = nil }
        }
    }

    private func banner(_ text: String, systemImage: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(color).accessibilityHidden(true)
            Text(text).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
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
                Button("Rules…") { showingRules = true }
            }
        } else if viewModel.items.isEmpty {
            ContentUnavailableView("Nothing expected", systemImage: "checkmark.seal",
                                   description: Text("No rule expects a document in \(viewModel.periodTitle)."))
        } else if viewModel.groups.isEmpty {
            if viewModel.missingOnly, viewModel.queryText.isEmpty {
                ContentUnavailableView("Nothing missing", systemImage: "checkmark.seal",
                                       description: Text("Every item in \(viewModel.periodTitle) has its document or is marked not available."))
            } else {
                ContentUnavailableView.search(text: viewModel.queryText)
            }
        } else {
            List {
                ForEach(viewModel.groups, id: \.source) { group in
                    Section {
                        ForEach(group.items) { item in
                            MissingEvidenceRow(item: item, isAdding: viewModel.addingItemIds.contains(item.id),
                                               actions: actions(for: item))
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func groupHeader(_ group: MissingEvidence.SourceGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.source)
            Spacer()
            ProgressView(value: group.progress.fractionDone)
                .frame(width: 80)
                .tint(group.progress.missing == 0 ? theme.income : theme.accent)
            Text("\(group.progress.done) of \(group.progress.total) done")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.source): \(group.progress.done) of \(group.progress.total) done")
        .accessibilityAddTraits(.isHeader)
    }

    private func actions(for item: MissingEvidence.Item) -> MissingEvidenceRow.Actions {
        let transaction = item.target.entity.type == .transaction
        return MissingEvidenceRow.Actions(
            addFiles: {
                importTarget = item
                importing = true
            },
            drop: { urls in viewModel.add(urls, to: item) },
            linkExisting: { linking = item },
            waive: { waiving = item },
            removeWaiver: { viewModel.removeWaiver(item) },
            unlink: { documentId in viewModel.unlink(documentId: documentId, from: item) },
            showTransaction: transaction ? {
                if let found = viewModel.transaction(for: item) { openTransaction(found) } else { viewModel.errorMessage = "The transaction no longer exists." }
            } : nil)
    }
}

/// One checklist item: its status, what it is (date or slot, description, amount, category
/// and account), the kinds it needs and its documents or waiver, with its actions. Files
/// dropped on it are added and linked.
struct MissingEvidenceRow: View {
    struct Actions {
        let addFiles: () -> Void
        let drop: ([URL]) -> Void
        let linkExisting: () -> Void
        let waive: () -> Void
        let removeWaiver: () -> Void
        let unlink: (Int64) -> Void
        let showTransaction: (() -> Void)?
    }

    let item: MissingEvidence.Item
    let isAdding: Bool
    let actions: Actions
    @Environment(\.theme) private var theme
    @State private var dropTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(2)
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("Needs " + MissingEvidenceViewModel.kindsText(item.expectedKinds))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                statusLine
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let amount = item.expectedAmountMinorUnits, let currency = item.currency {
                Text(Money.format(amount, currency: currency))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            trailingActions
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(dropTargeted ? theme.accent : Color.clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            actions.drop(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .contextMenu { menuItems }
    }

    private var statusIcon: some View {
        let (symbol, color, label): (String, Color, String) = switch item.status {
        case .missing: ("circle.dashed", theme.pending, "Missing")
        case .satisfied: ("checkmark.circle.fill", theme.income, "Has its document")
        case .waived: ("minus.circle", Color.secondary, "Not available")
        }
        return Image(systemName: symbol)
            .foregroundStyle(color)
            .font(.body)
            .frame(width: 18)
            .help(label)
            .accessibilityLabel(label)
    }

    private var caption: String {
        var parts: [String] = []
        if let date = item.expectedDate { parts.append(DocumentFormat.day(date)) }
        if let slot = item.expectedPeriod { parts.append(MissingEvidenceFormat.slot(slot)) }
        if item.title != item.requirement.name { parts.append(item.requirement.name) }
        if let category = item.categoryName, !item.requirement.name.hasSuffix(category) { parts.append(category) }
        if let account = item.accountName { parts.append(account) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch item.status {
        case .missing:
            if isAdding {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Adding…")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Missing — drop a file here")
                    .font(.caption).foregroundStyle(theme.pending)
            }
        case .satisfied:
            Text(item.satisfyingDocuments.map(\.displayName).joined(separator: "; "))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
                .help(item.satisfyingDocuments.map(\.displayName).joined(separator: "\n"))
        case .waived:
            let reason = item.waiver?.reason == .other ? "Waived" : "Not available"
            Text([reason, item.waiver?.note].compactMap { $0 }.joined(separator: ": "))
                .font(.caption).foregroundStyle(.secondary).italic()
                .lineLimit(2)
        }
    }

    private var trailingActions: some View {
        HStack(spacing: 6) {
            switch item.status {
            case .missing:
                Button("Add document…", action: actions.addFiles)
                    .disabled(isAdding)
                    .help("Add a file to the library and link it to this item")
            case .waived:
                Button("Remove waiver", action: actions.removeWaiver)
                    .help("Ask for a document again")
            case .satisfied:
                EmptyView()
            }
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More actions for \(item.title)")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(item.status == .satisfied ? "Add another document…" : "Add document…", action: actions.addFiles)
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
