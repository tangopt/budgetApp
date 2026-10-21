// App/DocumentImport/ImportLinkViews.swift
import SwiftUI
import BudgetCore

// MARK: The peek

/// A transaction as the review shows it in place (no navigating away): its description and
/// amount, then its day, account and category; opened, why it was linked or offered, its note
/// and the documents already on it. `accessory` sits at the end of the second line (Unlink).
struct ImportTransactionPeekRow<Accessory: View>: View {
    let candidate: ImportTransactionCandidate?
    /// The label the plan gives it, while the transaction is read (or when it no longer exists).
    let fallbackLabel: String
    var reasons: [String] = []
    var needsReview = false
    @Binding var isExpanded: Bool
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide the transaction's details" : "Show the transaction's details")
                Text((candidate?.description ?? fallbackLabel).figuresUnbroken)
                    .font(.callout).lineLimit(1).truncationMode(.tail)
                    .help(candidate?.description ?? fallbackLabel)
                Spacer(minLength: 4)
                if needsReview {
                    StatusPill("Check it", tone: .warning)
                }
                if let candidate {
                    MoneyText(minorUnits: candidate.amountMinorUnits, currency: candidate.currency, font: .callout.monospacedDigit())
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let candidate {
                    DateText(date: candidate.date, font: .caption)
                    Text("·")
                    Text(candidate.accountName).lineLimit(1).truncationMode(.tail)
                    if !candidate.categoryName.isEmpty {
                        Text("·")
                        Text(candidate.categoryName).lineLimit(1).truncationMode(.tail)
                    }
                } else {
                    Text("Transaction details are being read").lineLimit(1)
                }
                Spacer(minLength: 4)
                accessory()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.leading, 16)
            if isExpanded {
                details.padding(.leading, 16).padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !reasons.isEmpty {
                Text(reasons.joined(separator: " · ").figuresUnbroken)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = candidate?.note, !note.isEmpty {
                Text("Note: \(note)".figuresUnbroken).fixedSize(horizontal: false, vertical: true)
            }
            if let candidate {
                if candidate.documentNames.isEmpty {
                    Text("No documents on it yet")
                } else {
                    Text("Documents on it:")
                    ForEach(Array(candidate.documentNames.enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "doc")
                            .lineLimit(1).truncationMode(.middle).help(name)
                    }
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: Links to

/// The preview's "Links to": every link with why, a transaction as its peek; "Unlink" on each
/// link the item lets go of, and "Link to a transaction…" (the search over the preview).
struct ImportLinksSection: View {
    let item: ImportItem
    @ObservedObject var center: ImportCenterModel
    let resolve: (ImportResolution) -> Void

    private var correctable: Bool { ImportResolutions.isCorrectable(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(item.links, id: \.entity) { link in
                if link.entity.type == .transaction {
                    ImportTransactionPeekRow(candidate: center.linkedTransactions[link.entity.id], fallbackLabel: link.label,
                                             reasons: link.reasons, needsReview: link.confidence == .needsReview,
                                             isExpanded: expanded(link.entity.id)) {
                        unlinkButton(link)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(link.label.figuresUnbroken).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if link.confidence == .needsReview {
                                StatusPill("Check it", tone: .warning)
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if !link.reasons.isEmpty {
                                Text(link.reasons.joined(separator: " · ").figuresUnbroken)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            unlinkButton(link)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if item.links.isEmpty {
                Text("Not linked to anything").font(.callout).foregroundStyle(.secondary)
            }
            if correctable {
                Button("Link to a transaction…") { center.linkSearchItemId = item.id }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func unlinkButton(_ link: ProposedLink) -> some View {
        if ImportResolutions.canUnlink(link, in: item) {
            Button("Unlink") { resolve(.unlink(link.entity)) }
                .buttonStyle(.link)
                .font(.caption)
                .help("Remove this link: the document is filed without it")
        }
    }

    private func expanded(_ id: Int64) -> Binding<Bool> {
        Binding(get: { center.expandedPeeks.contains(id) },
                set: { open in
                    if open { center.expandedPeeks.insert(id) } else { center.expandedPeeks.remove(id) }
                })
    }
}

// MARK: The search

/// "Link to a transaction…": the search's fields (prefilled from the document's amount and
/// date), its results (the proposed ones first) and what is picked. Searching runs off the
/// main actor on the planning copy, a moment after the user stops typing.
@MainActor
final class ImportLinkSearchModel: ObservableObject {
    @Published var text = "" { didSet { schedule() } }
    @Published var amount = "" { didSet { schedule() } }
    @Published var usesDates = true { didSet { schedule() } }
    @Published var from: Date { didSet { schedule() } }
    @Published var to: Date { didSet { schedule() } }
    @Published var accountId: Int64? { didSet { schedule() } }
    @Published private(set) var proposed: [ImportTransactionCandidate] = []
    @Published private(set) var results: [ImportTransactionCandidate] = []
    @Published private(set) var isSearching = false
    @Published private(set) var failure: String?
    @Published var selected: [Int64]

    let currency: Currency
    private let center: ImportCenterModel
    private let proposedIds: [Int64]
    private var task: Task<Void, Never>?

    static let debounce: Duration = .milliseconds(300)

    init(item: ImportItem, center: ImportCenterModel) {
        self.center = center
        let suggested = ImportTransactionQuery.suggested(for: item)
        currency = ImportIssueControls.currency(of: item, field: .amount)
        amount = suggested.amountMinorUnits.map { Money.formatInput($0) } ?? ""
        let today = PayCalendar.utcDay(sameDayAs: AppClock.now, in: .current)
        usesDates = true // the suggested window, else the last 3 months: a search never scans everything
        from = suggested.from ?? MonthRange.calendar.date(byAdding: .month, value: -3, to: today)!
        to = suggested.to ?? today
        // What the item is linked to (certain) is picked to start with: Link keeps it.
        selected = item.links.filter { $0.entity.type == .transaction && $0.confidence == .certain }.map(\.entity.id)
        let offered = item.issues.flatMap { issue -> [EvidenceEntity] in
            if case .chooseLink(let candidates) = issue.kind { return candidates.map(\.entity) }
            return []
        }
        var ids: [Int64] = []
        for entity in item.links.map(\.entity) + offered where entity.type == .transaction && !ids.contains(entity.id) {
            ids.append(entity.id)
        }
        proposedIds = ids
    }

    var query: ImportTransactionQuery {
        let trimmed = amount.trimmingCharacters(in: .whitespaces)
        return ImportTransactionQuery(text: text, amountMinorUnits: trimmed.isEmpty ? nil : Money.parseMinorUnits(trimmed).map(abs),
                                      from: usesDates ? from : nil, to: usesDates ? to : nil, accountId: accountId)
    }

    /// The results without the proposed ones (shown first, apart).
    var others: [ImportTransactionCandidate] {
        let shown = Set(proposed.map(\.id))
        return results.filter { !shown.contains($0.id) }
    }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            self.proposed = (try? await self.center.transactions(self.proposedIds)) ?? []
        }
        run(after: .zero)
    }

    func toggle(_ id: Int64) {
        if let index = selected.firstIndex(of: id) { selected.remove(at: index) } else { selected.append(id) }
    }

    private func schedule() { run(after: Self.debounce) }

    private func run(after delay: Duration) {
        task?.cancel()
        let query = query
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.isSearching = true
            do {
                let found = try await self.center.searchTransactions(query)
                guard !Task.isCancelled else { return }
                self.results = found
                self.failure = nil
            } catch {
                if !Task.isCancelled { self.failure = "Couldn't search: \(error.localizedDescription)" }
            }
            if !Task.isCancelled { self.isSearching = false }
        }
    }

    func cancel() { task?.cancel() }
}

/// The search over the preview: the fields, the proposed transactions then the results (each
/// a peek with a checkbox), and Link (the picked ones become the document's transactions) or
/// Cancel.
struct ImportLinkSearchPanel: View {
    let item: ImportItem
    @ObservedObject var center: ImportCenterModel
    let isAnswerable: Bool
    let resolve: (ImportResolution) -> Void
    @StateObject private var search: ImportLinkSearchModel

    init(item: ImportItem, center: ImportCenterModel, isAnswerable: Bool, resolve: @escaping (ImportResolution) -> Void) {
        self.item = item
        self.center = center
        self.isAnswerable = isAnswerable
        self.resolve = resolve
        _search = StateObject(wrappedValue: ImportLinkSearchModel(item: item, center: center))
    }

    private var accounts: [(id: Int64, name: String)] {
        (center.targetNames.names[.account] ?? [:]).map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Link to a transaction").font(.headline)
                Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            fields
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !search.proposed.isEmpty {
                        heading("Proposed")
                        ForEach(search.proposed) { candidate in result(candidate) }
                        heading("Search results")
                    }
                    if let failure = search.failure {
                        Text(failure.figuresUnbroken).font(.callout).foregroundStyle(.secondary)
                    } else if search.others.isEmpty {
                        Text(search.isSearching ? "Searching…"
                             : search.query.isEmpty ? "Enter words, an amount or dates to search"
                             : (search.results.isEmpty ? "No transactions match" : "Nothing else matches"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(search.others) { candidate in result(candidate) }
                    if search.results.count >= ImportTransactionSearch.limit {
                        Text("The \(ImportTransactionSearch.limit) newest shown: narrow the search to see others")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 4)
            }
            HStack(spacing: 8) {
                Text(search.selected.count == 1 ? "1 picked" : "\(search.selected.count) picked")
                    .font(.callout).foregroundStyle(.secondary).figureText()
                Spacer(minLength: 4)
                Button("Cancel") { close() }
                Button("Link") {
                    resolve(.linkTransactions(search.selected))
                    close()
                }
                .buttonStyle(.borderedProminent)
                .disabled(search.selected.isEmpty || !isAnswerable)
                .help(search.selected.count > 1 ? "Links the document to each transaction picked: all of them are its payments"
                                                : "Links the document to the transaction picked, instead of what was proposed")
            }
            .controlSize(.small)
        }
        .onAppear { search.start() }
        .onDisappear { search.cancel() }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Description, note or category", text: $search.text)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Text("Amount").foregroundStyle(.secondary)
                MoneyField("Amount", text: $search.amount, currency: search.currency, width: 90)
                Spacer(minLength: 4)
                Picker("Account", selection: $search.accountId) {
                    Text("All accounts").tag(Int64?.none)
                    ForEach(accounts, id: \.id) { account in Text(account.name).tag(Optional(account.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
            }
            HStack(spacing: 6) {
                Toggle("From", isOn: $search.usesDates)
                DatePicker("From", selection: utcDay($search.from), displayedComponents: .date)
                    .labelsHidden().disabled(!search.usesDates)
                Text("to").foregroundStyle(.secondary)
                DatePicker("To", selection: utcDay($search.to), displayedComponents: .date)
                    .labelsHidden().disabled(!search.usesDates)
            }
        }
        .controlSize(.small)
        .font(.callout)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func result(_ candidate: ImportTransactionCandidate) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Toggle(isOn: Binding(get: { search.selected.contains(candidate.id) }, set: { _ in search.toggle(candidate.id) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("Pick \(candidate.description)")
            ImportTransactionPeekRow(candidate: candidate, fallbackLabel: candidate.description,
                                     isExpanded: expanded(candidate.id)) { EmptyView() }
        }
    }

    private func expanded(_ id: Int64) -> Binding<Bool> {
        Binding(get: { center.expandedPeeks.contains(id) },
                set: { open in
                    if open { center.expandedPeeks.insert(id) } else { center.expandedPeeks.remove(id) }
                })
    }

    private func close() {
        search.cancel()
        center.linkSearchItemId = nil
    }
}

// MARK: Corrections

/// What can be changed on any item that isn't held — Ready ones too, not only where a question
/// asks: its kind ("Change kind…"), its target ("Change provider…"), each figure (the pencil
/// beside it in Figures). A changed item is checked again and may move to Needs you.
struct ImportCorrections: View {
    let item: ImportItem
    let targetNames: ImportTargetNames
    let resolve: (ImportResolution) -> Void
    @State private var changingKind = false
    @State private var changingTarget = false
    @State private var namingIssuer = false

    /// No issuer read: the user can name it (learnt for the issuer on Confirm import). One read is
    /// changed with its pencil in Figures.
    private var namesIssuer: Bool {
        ImportResolutions.takesIssuerName(item) && !item.facts.contains { $0.field == .issuer }
    }

    /// Whether a question already asks the kind.
    private var kindAsked: Bool {
        item.recognition.confidence == .needsReview || item.issues.contains { issue in
            switch issue.kind {
            case .unknownKind, .kindMismatch: return true
            default: return false
            }
        }
    }

    private var targetOptions: [Int64] {
        guard let kind = ImportResolutions.correctableTarget(of: item) else { return [] }
        return (targetNames.names[kind] ?? [:]).sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }.map(\.key)
    }

    var body: some View {
        let target = ImportResolutions.correctableTarget(of: item)
        let options = targetOptions
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !kindAsked {
                    Button("Change kind…") { changingKind.toggle() }
                }
                if let target, !options.isEmpty {
                    Button("Change \(target.rawValue)…") { changingTarget.toggle() }
                }
                if namesIssuer {
                    Button("Name the issuer…") { namingIssuer.toggle() }
                }
            }
            .controlSize(.small)
            if changingKind, !kindAsked {
                ImportKindChooser(initial: ImportIssueControls.documentKind(item.recognition.kind) ?? .other, keep: nil, resolve: resolve)
            }
            if changingTarget, let target, !options.isEmpty {
                ImportTargetChooser(kind: target, options: options, names: targetNames, resolve: resolve)
            }
            if namingIssuer, namesIssuer {
                ImportFigureEditor(field: .issuer, current: nil, currency: .eur, confirming: false) { resolution in
                    namingIssuer = false
                    resolve(resolution)
                }
            }
        }
    }
}
