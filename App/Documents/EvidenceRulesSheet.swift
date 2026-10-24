// App/Documents/EvidenceRulesSheet.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// Rules… (Missing evidence): every evidence requirement — what it covers, the kinds that
/// satisfy it, where they come from and when it applies — with Add, Edit, Delete and
/// Set up property rules…. Changes apply at once; the checklist behind follows them.
struct EvidenceRulesSheet: View {
    @ObservedObject var viewModel: MissingEvidenceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: RuleEditTarget?
    @State private var seeding = false
    @State private var deleting: EvidenceRequirement?

    var body: some View {
        SheetScaffold(title: "Evidence rules",
                      subtitle: "What each period's checklist expects. Rules are kept as data, so new tax years get their list automatically.",
                      error: viewModel.errorMessage, width: SheetMetrics.listWidth, cancelTitle: "Done", onCancel: { dismiss() }) {
            List {
                if viewModel.requirements.isEmpty {
                    Text("No rules yet. Add one, or set up the property rules for a category group.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.requirements) { requirement in
                    row(requirement)
                }
            }
            .frame(height: 420)
            .sheetListFrame()
            HStack(spacing: 8) {
                Button("Add rule…") { editing = RuleEditTarget(requirement: nil) }
                Button("Set up property rules…") { seeding = true }
                    .help("Add the default rules for a property's category group and its mortgage")
                Spacer()
            }
        }
        .sheet(item: $editing) { target in
            EvidenceRuleEditorSheet(viewModel: viewModel, requirement: target.requirement)
                .keepsEvidenceObserved(viewModel, as: "rule-editor")
        }
        .sheet(isPresented: $seeding) {
            PropertyRulesSheet(viewModel: viewModel)
                .keepsEvidenceObserved(viewModel, as: "property-rules-from-rules")
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { requirement in
            Button("Delete rule", role: .destructive) {
                if let id = requirement.id { viewModel.deleteRequirement(id) }
            }
        } message: { _ in
            Text("Its items leave the checklist and their “not available” marks are deleted. Linked documents stay. This can't be undone.")
        }
    }

    /// A rule: its name over what it covers, then what it needs, from where and when; edit and
    /// delete as icons.
    private func row(_ requirement: EvidenceRequirement) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(viewModel.scopeSummary(requirement))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                // What and where from truncate; when (a range of months) never does.
                HStack(spacing: 0) {
                    Text(details(requirement) + " · ").lineLimit(1)
                    Text(MissingEvidenceViewModel.activeRange(requirement) ?? "Always").figureText()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button { editing = RuleEditTarget(requirement: requirement) } label: { Image(systemName: "pencil") }
                .help("Edit the rule…")
                .accessibilityLabel("Edit \(requirement.name)")
            Button(role: .destructive) { deleting = requirement } label: { Image(systemName: "trash") }
                .help("Delete the rule…")
                .accessibilityLabel("Delete \(requirement.name)")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
    }

    private func details(_ requirement: EvidenceRequirement) -> String {
        var parts = ["Needs " + viewModel.kindsText(requirement)]
        if let source = requirement.usualSource { parts.append("From \(source)") }
        return parts.joined(separator: " · ")
    }
}

/// The rule an editor sheet opens on (nil: a new one).
private struct RuleEditTarget: Identifiable {
    let id = UUID()
    let requirement: EvidenceRequirement?
}

// MARK: - Editor

/// Add rule… / Edit…: a requirement's name, what it covers, the kinds that satisfy it, its
/// usual source, active range and notes.
struct EvidenceRuleEditorSheet: View {
    @ObservedObject var viewModel: MissingEvidenceViewModel
    let requirement: EvidenceRequirement?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EvidenceRuleDraft
    @State private var error: String?

    init(viewModel: MissingEvidenceViewModel, requirement: EvidenceRequirement?) {
        self.viewModel = viewModel
        self.requirement = requirement
        _draft = State(initialValue: EvidenceRuleDraft(requirement, catalog: viewModel.kindCatalog))
    }

    var body: some View {
        SheetScaffold(title: requirement == nil ? "New evidence rule" : "Edit evidence rule", error: error, width: SheetMetrics.listWidth,
                      onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: draft.isComplete) {
                          error = viewModel.save(draft.requirement(base: requirement))
                          if error == nil { dismiss() }
                      }) {
            ScrollView {
                SheetForm {
                    LabeledContent("Name") {
                        TextField("Name", text: $draft.name, prompt: Text("e.g. Lisbon: IMI"))
                    }
                    LabeledContent("Covers") {
                        Picker("Covers", selection: $draft.scopeKind) {
                            ForEach(draft.availableScopeKinds, id: \.self) { Text($0.title).tag($0) }
                        }
                        .fixedSize()
                    }
                    scopeRows
                    LabeledContent("Satisfied by") {
                        CheckboxList(options: kindOptions, selection: $draft.kinds, height: 120)
                            .sheetFieldNote(draft.kinds.isEmpty ? "None ticked: any document counts." : nil)
                    }
                    LabeledContent("Usual source") {
                        HStack(spacing: 6) {
                            TextField("Usual source", text: $draft.usualSource, prompt: Text("e.g. BBVA app"))
                            Menu {
                                ForEach(viewModel.knownSources, id: \.self) { source in
                                    Button(source) { draft.usualSource = source }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .accessibilityLabel("Pick a usual source")
                            }
                            .menuStyle(.button)
                            .buttonStyle(.borderless)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Pick a source")
                        }
                        .sheetFieldNote("The checklist groups items by it.")
                    }
                    LabeledContent("Applies") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                // Named beside the tick: a SheetForm row hides its controls' own labels.
                                NamedCheckbox(title: "From", isOn: $draft.hasFrom)
                                DatePicker("From", selection: $draft.from, displayedComponents: .date)
                                    .labelsHidden()
                                    .disabled(!draft.hasFrom)
                            }
                            HStack(spacing: 6) {
                                NamedCheckbox(title: "Until", isOn: $draft.hasUntil)
                                DatePicker("Until", selection: $draft.until, displayedComponents: .date)
                                    .labelsHidden()
                                    .disabled(!draft.hasUntil)
                            }
                        }
                        .sheetFieldNote("Until is the last day it applies. Unticked: no limit.")
                    }
                    LabeledContent("Notes") {
                        TextField("Notes", text: $draft.notes, prompt: Text("Optional"), axis: .vertical)
                            .lineLimit(1...3)
                    }
                }
                // Room for the fields' borders and focus rings inside the scroll view's clip.
                .padding(.vertical, 3)
                .padding(.trailing, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var scopeRows: some View {
        switch draft.scopeKind {
        case .category:
            LabeledContent("Category") {
                Picker("Category", selection: $draft.categoryId) {
                    Text("Choose…").tag(Int64?.none)
                    ForEach(viewModel.categories.filter { $0.isAssignable }) { category in
                        Text(category.name).tag(category.id)
                    }
                }
                .fixedSize()
            }
        case .categoryGroup:
            LabeledContent("Group") {
                Picker("Group", selection: $draft.groupId) {
                    Text("Choose…").tag(Int64?.none)
                    ForEach(viewModel.categoryGroups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                .fixedSize()
            }
        case .matching:
            LabeledContent("Categories") {
                CheckboxList(options: viewModel.categories.filter { $0.isAssignable }.compactMap { c in c.id.map { ($0, c.name) } },
                             selection: $draft.matchCategoryIds, height: 100)
            }
            LabeledContent("Accounts") {
                CheckboxList(options: accountOptions, selection: $draft.matchAccountIds, height: 80)
            }
            LabeledContent("Description") {
                TextField("Description contains", text: $draft.descriptionContains, prompt: Text("Text the description contains"))
                    .sheetFieldNote("A transaction must match everything set here.")
            }
        case .propertyRecords:
            LabeledContent("Records") {
                Text(draft.propertyRecordsDescription)
                    .foregroundStyle(.secondary)
            }
        case .periodic, .single:
            LabeledContent("Record") {
                Picker("Record", selection: $draft.entity) {
                    Text("Choose…").tag(EvidenceEntity?.none)
                    Section("Accounts") {
                        ForEach(viewModel.accounts) { account in
                            if let id = account.id { Text(account.displayName).tag(EvidenceEntity?.some(.account(id))) }
                        }
                    }
                    Section("Categories") {
                        ForEach(viewModel.categories) { category in
                            if let id = category.id { Text(category.name).tag(EvidenceEntity?.some(.category(id))) }
                        }
                    }
                }
                .fixedSize()
                .sheetFieldNote("Documents dropped on its items are linked to this record.")
            }
            if draft.scopeKind == .periodic {
                LabeledContent("Every") {
                    Picker("Every", selection: $draft.every) {
                        Text("Month").tag(EvidencePeriodicity.month)
                        Text("Quarter").tag(EvidencePeriodicity.quarter)
                        Text("Year").tag(EvidencePeriodicity.year)
                    }
                    .pickerStyle(.segmented).prominentTint()
                    .fixedSize()
                }
            }
        }
        if draft.scopeKind.isTransactionScope {
            LabeledContent("Transactions") {
                Picker("Transactions", selection: $draft.direction) {
                    Text("Payments out").tag(EvidenceTransactionDirection.outflows)
                    Text("Money in").tag(EvidenceTransactionDirection.inflows)
                    Text("Both").tag(EvidenceTransactionDirection.any)
                }
                .pickerStyle(.segmented).prominentTint()
                .fixedSize()
            }
            LabeledContent("Leave out") {
                CheckboxList(options: accountOptions, selection: $draft.excludedAccountIds, height: 80)
                    .sheetFieldNote("Transactions on these accounts don't need evidence.")
            }
        }
    }

    private var accountOptions: [(Int64, String)] {
        viewModel.accounts.compactMap { a in a.id.map { ($0, a.displayName) } }
    }

    /// The built-in kinds by name, then the kinds the user made, by name.
    private var kindOptions: [(DocumentKindRef, String)] {
        DocumentKind.byDisplayName.map { (DocumentKindRef.builtIn($0), $0.displayName) }
            + viewModel.kindCatalog.customKinds.compactMap { kind in kind.id.map { (DocumentKindRef.custom($0), kind.name) } }
    }
}

/// The editor's fields, turned into a requirement on Save.
struct EvidenceRuleDraft {
    enum ScopeKind: CaseIterable {
        case category, categoryGroup, matching, periodic, single
        /// Each tenancy or rent receipt of a property (made by the property's default rules;
        /// kept as is when edited).
        case propertyRecords

        var title: String {
            switch self {
            case .category: return "Transactions in a category"
            case .categoryGroup: return "Transactions in a category group"
            case .matching: return "Transactions matching…"
            case .periodic: return "A document every period"
            case .single: return "A single document"
            case .propertyRecords: return "Each record (property, income)"
            }
        }

        var isTransactionScope: Bool { self == .category || self == .categoryGroup || self == .matching }
    }

    var name = ""
    var scopeKind = ScopeKind.category
    var categoryId: Int64?
    var groupId: Int64?
    var matchCategoryIds: Set<Int64> = []
    var matchAccountIds: Set<Int64> = []
    var descriptionContains = ""
    var entity: EvidenceEntity?
    var every = EvidencePeriodicity.month
    /// Built-in and custom kinds that satisfy the rule.
    var kinds: Set<DocumentKindRef> = []
    /// Custom kinds the rule names that this device doesn't have (not arrived yet): kept on Save.
    var unknownCustomKindIds: [Int64] = []
    var direction = EvidenceTransactionDirection.outflows
    var excludedAccountIds: Set<Int64> = []
    var usualSource = ""
    var hasFrom = false
    /// Local midnights (what a `DatePicker` holds).
    var from = Calendar.current.startOfDay(for: AppClock.now)
    var hasUntil = false
    var until = Calendar.current.startOfDay(for: AppClock.now)
    var notes = ""
    /// A `recordsOfProperty` scope being edited (not built from the fields).
    var propertyRecordsScope: EvidenceRequirementScope?

    /// What a property-records scope covers, for the editor.
    var propertyRecordsDescription: String {
        switch propertyRecordsScope {
        case let .recordsOfProperty(_, recordType)?: return recordType == .tenancy ? "Each tenancy's contract" : "Each issued rent receipt"
        case let .personalIncomeRecords(record)?: return record.ruleDescription
        default: return ""
        }
    }

    /// The kinds offered: property records only when the rule already is one.
    var availableScopeKinds: [ScopeKind] {
        ScopeKind.allCases.filter { $0 != .propertyRecords || propertyRecordsScope != nil }
    }

    init(_ requirement: EvidenceRequirement?, catalog: DocumentKindCatalog = DocumentKindCatalog(customKinds: [])) {
        guard let requirement else { return }
        name = requirement.name
        switch requirement.scope {
        case let .transactionsInCategory(categoryId):
            scopeKind = .category
            self.categoryId = categoryId
        case let .transactionsInCategoryGroup(groupId):
            scopeKind = .categoryGroup
            self.groupId = groupId
        case let .transactionsMatching(categoryIds, accountIds, text):
            scopeKind = .matching
            matchCategoryIds = Set(categoryIds)
            matchAccountIds = Set(accountIds)
            descriptionContains = text ?? ""
        case let .periodic(entity, every):
            scopeKind = .periodic
            self.entity = entity
            self.every = every
        case let .single(entity):
            scopeKind = .single
            self.entity = entity
        case .recordsOfProperty, .personalIncomeRecords:
            scopeKind = .propertyRecords
            propertyRecordsScope = requirement.scope
        }
        kinds = Set(requirement.knowingOnly(catalog).kindRefs)
        unknownCustomKindIds = requirement.customKindIds.filter { catalog.custom(id: $0) == nil }
        direction = requirement.direction
        excludedAccountIds = Set(requirement.excludedAccountIds)
        usualSource = requirement.usualSource ?? ""
        if let activeFrom = requirement.activeFrom {
            hasFrom = true
            from = PayCalendar.localDay(sameDayAs: activeFrom, in: .current)
        }
        if let activeTo = requirement.activeTo {
            hasUntil = true
            until = PayCalendar.localDay(sameDayAs: activeTo.addingTimeInterval(-86_400), in: .current)
        }
        notes = requirement.notes ?? ""
    }

    /// Whether the scope has what it needs (the rest is checked on Save).
    var isComplete: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch scopeKind {
        case .category: return categoryId != nil
        case .categoryGroup: return groupId != nil
        case .matching: return true
        case .periodic, .single: return entity != nil
        case .propertyRecords: return propertyRecordsScope != nil
        }
    }

    var scope: EvidenceRequirementScope? {
        switch scopeKind {
        case .category: return categoryId.map { .transactionsInCategory(categoryId: $0) }
        case .categoryGroup: return groupId.map { .transactionsInCategoryGroup(groupId: $0) }
        case .matching:
            return .transactionsMatching(categoryIds: matchCategoryIds.sorted(), accountIds: matchAccountIds.sorted(),
                                         descriptionContains: descriptionContains)
        case .periodic: return entity.map { .periodic(entity: $0, every: every) }
        case .single: return entity.map { .single(entity: $0) }
        case .propertyRecords: return propertyRecordsScope
        }
    }

    /// The requirement to save: `base`'s id and creation date kept.
    func requirement(base: EvidenceRequirement?) -> EvidenceRequirement {
        let kindOrder = DocumentKind.allCases.filter { kinds.contains(.builtIn($0)) }
        let customIds = kinds.compactMap { kind -> Int64? in if case .custom(let id) = kind { return id } else { return nil } }.sorted()
        let isTransactionScope = scopeKind.isTransactionScope
        var requirement = EvidenceRequirement(
            id: base?.id, name: name, scope: scope ?? .single(entity: .account(0)), kinds: kindOrder,
            customKindIds: customIds + unknownCustomKindIds.filter { !customIds.contains($0) }, direction: direction,
            excludedAccountIds: isTransactionScope ? excludedAccountIds.sorted() : [], usualSource: usualSource,
            activeFrom: hasFrom ? PayCalendar.utcDay(sameDayAs: from, in: .current) : nil,
            activeTo: hasUntil ? PayCalendar.utcDay(sameDayAs: until, in: .current).addingTimeInterval(86_400) : nil,
            notes: notes)
        if let base { requirement.createdAt = base.createdAt }
        return requirement
    }
}

/// Ticks for a few options, in a scrolling box. Each tick shows its name even inside a
/// `SheetForm` (whose rows hide their controls' labels), and the row's label lines up with
/// the first line of ticks.
struct CheckboxList<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Set<Value>
    var height: CGFloat = 100

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 4) {
                ForEach(options.indices, id: \.self) { index in
                    let (value, title) = options[index]
                    NamedCheckbox(title: title, isOn: Binding(
                        get: { selection.contains(value) },
                        set: { isOn in if isOn { selection.insert(value) } else { selection.remove(value) } }))
                    .help(title)
                }
            }
            .padding(6)
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .overlay(alignment: .topTrailing) {
            if !selection.isEmpty {
                Text("\(selection.count) ticked")
                    .font(.caption2).foregroundStyle(.secondary)
                    .figureText()
                    .padding(4)
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0[.top] + 18 }
    }
}

// MARK: - Property rules

/// Set up property rules…: picks a property's category group and its mortgage accounts,
/// previews the default rules that would be added (`EvidenceRequirementDefaults.propertyRules`)
/// and adds them.
struct PropertyRulesSheet: View {
    @ObservedObject var viewModel: MissingEvidenceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var groupId: Int64?
    @State private var mortgageAccountIds: Set<Int64> = []
    @State private var preview: [EvidenceRequirement] = []
    @State private var error: String?

    /// `groupId`: the category group to start on (the snapshot harness); normally none.
    init(viewModel: MissingEvidenceViewModel, groupId: Int64? = nil) {
        self.viewModel = viewModel
        _groupId = State(initialValue: groupId)
    }

    var body: some View {
        SheetScaffold(title: "Set up property rules",
                      subtitle: "Every payment in the group's expense categories needs a document of the kind its category implies; every instalment paid into a mortgage account needs the bank's notice.",
                      error: error, width: SheetMetrics.listWidth, onCancel: { dismiss() },
                      primary: SheetAction(preview.isEmpty ? "Add rules" : "Add \(preview.count) rule\(preview.count == 1 ? "" : "s")",
                                           isEnabled: groupId != nil && !preview.isEmpty) { add() }) {
            SheetForm {
                LabeledContent("Category group") {
                    Picker("Category group", selection: $groupId) {
                        Text("Choose…").tag(Int64?.none)
                        ForEach(viewModel.categoryGroups.filter { $0.sectionType == .expense }) { group in
                            Text(group.name).tag(group.id)
                        }
                    }
                    .fixedSize()
                }
                LabeledContent("Mortgage accounts") {
                    CheckboxList(options: viewModel.accounts.compactMap { a in a.id.map { ($0, a.displayName) } },
                                 selection: $mortgageAccountIds, height: 90)
                        .sheetFieldNote("Their interest rows are left out of the mortgage categories' rules, so each instalment is asked for once.")
                }
            }
            if groupId == nil {
                SheetEmptyState(systemImage: "checklist", title: "Choose a category group",
                                message: "The rules it would add are listed here before anything is saved.", minHeight: 200)
            } else if preview.isEmpty {
                SheetEmptyState(systemImage: "checkmark.circle", title: "Nothing to add",
                                message: "This group's rules already exist.", minHeight: 200)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Will add").font(.headline)
                    ScrollView {
                        DataTable(columns: previewColumns, rows: preview.indices.map(PreviewRow.init))
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                    .sheetListFrame()
                }
            }
        }
        .onAppear {
            if mortgageAccountIds.isEmpty {
                mortgageAccountIds = Set(viewModel.accounts.filter { $0.kind == .credit && $0.name.localizedCaseInsensitiveContains("mortgage") }.compactMap(\.id))
            }
            refreshPreview()
        }
        .onChange(of: groupId) { refreshPreview() }
        .onChange(of: mortgageAccountIds) { refreshPreview() }
    }

    /// A previewed rule, by its place in the preview.
    private struct PreviewRow: Identifiable {
        let id: Int
    }

    /// The rules to add: the rule and what it covers, what it needs, and where from.
    private var previewColumns: [DataTableColumn<PreviewRow>] {
        [
            .text("Rule", { preview[$0.id].name }, detail: { viewModel.scopeSummary(preview[$0.id]) }),
            .text("Needs", width: .fit, { MissingEvidenceViewModel.kindsText(preview[$0.id].kinds) }),
            // "—" on screen for no usual source; nothing to VoiceOver.
            DataTableColumn("From", accessibilityValue: { preview[$0.id].usualSource }) { row, _ in
                Text(preview[row.id].usualSource ?? "—").lineLimit(1)
            }
        ]
    }

    private func refreshPreview() {
        guard let groupId else { preview = []; return }
        switch viewModel.propertyRulesPreview(groupId: groupId, mortgageAccountIds: mortgageAccountIds.sorted()) {
        case .success(let rules):
            preview = rules
            error = nil
        case .failure(let failure):
            preview = []
            error = failure.localizedDescription
        }
    }

    private func add() {
        guard let groupId else { return }
        switch viewModel.seedPropertyRules(groupId: groupId, mortgageAccountIds: mortgageAccountIds.sorted()) {
        case .success: dismiss()
        case .failure(let failure): error = failure.localizedDescription
        }
    }
}
