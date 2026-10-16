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
                      error: viewModel.errorMessage, width: 680, cancelTitle: "Done", onCancel: { dismiss() }) {
            List {
                if viewModel.requirements.isEmpty {
                    Text("No rules yet. Add one, or set up the property rules for a category group.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.requirements) { requirement in
                    row(requirement)
                }
            }
            .frame(height: 360)
            HStack(spacing: 8) {
                Button("Add rule…") { editing = RuleEditTarget(requirement: nil) }
                Button("Set up property rules…") { seeding = true }
                    .help("Add the default rules for a property's category group and its mortgage")
                Spacer()
            }
        }
        .sheet(item: $editing) { target in
            EvidenceRuleEditorSheet(viewModel: viewModel, requirement: target.requirement)
        }
        .sheet(isPresented: $seeding) {
            PropertyRulesSheet(viewModel: viewModel)
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { requirement in
            Button("Delete Rule", role: .destructive) {
                if let id = requirement.id { viewModel.deleteRequirement(id) }
            }
        } message: { _ in
            Text("Its items leave the checklist and their “not available” marks are deleted. Linked documents stay.")
        }
    }

    private func row(_ requirement: EvidenceRequirement) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.name).fontWeight(.medium)
                Text(viewModel.scopeSummary(requirement))
                    .font(.callout).foregroundStyle(.secondary)
                Text(details(requirement))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Edit…") { editing = RuleEditTarget(requirement: requirement) }
                .accessibilityLabel("Edit \(requirement.name)")
            Button(role: .destructive) { deleting = requirement } label: { Image(systemName: "trash") }
                .help("Delete the rule")
                .accessibilityLabel("Delete \(requirement.name)")
        }
        .controlSize(.small)
        .padding(.vertical, 2)
    }

    private func details(_ requirement: EvidenceRequirement) -> String {
        var parts = ["Needs " + MissingEvidenceViewModel.kindsText(requirement.kinds)]
        if let source = requirement.usualSource { parts.append("From \(source)") }
        parts.append(MissingEvidenceViewModel.activeRange(requirement) ?? "Always")
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
        _draft = State(initialValue: EvidenceRuleDraft(requirement))
    }

    var body: some View {
        SheetScaffold(title: requirement == nil ? "New evidence rule" : "Edit evidence rule", error: error, width: 600,
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
                            ForEach(EvidenceRuleDraft.ScopeKind.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    scopeRows
                    LabeledContent("Satisfied by") {
                        CheckboxList(options: DocumentKind.byDisplayName.map { ($0, $0.displayName) }, selection: $draft.kinds, height: 120)
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
                                Toggle("From", isOn: $draft.hasFrom).toggleStyle(.checkbox)
                                DatePicker("From", selection: $draft.from, displayedComponents: .date)
                                    .labelsHidden()
                                    .disabled(!draft.hasFrom)
                            }
                            HStack(spacing: 6) {
                                Toggle("Until", isOn: $draft.hasUntil).toggleStyle(.checkbox)
                                DatePicker("Until", selection: $draft.until, displayedComponents: .date)
                                    .labelsHidden()
                                    .disabled(!draft.hasUntil)
                            }
                        }
                        .sheetFieldNote("Until is the last day it applies. Unticked: no limit.")
                    }
                    LabeledContent("Notes") {
                        TextField("Notes", text: $draft.notes, axis: .vertical)
                            .lineLimit(1...3)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 520)
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
            }
        case .categoryGroup:
            LabeledContent("Group") {
                Picker("Group", selection: $draft.groupId) {
                    Text("Choose…").tag(Int64?.none)
                    ForEach(viewModel.categoryGroups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
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
                .sheetFieldNote("Documents dropped on its items are linked to this record.")
            }
            if draft.scopeKind == .periodic {
                LabeledContent("Every") {
                    Picker("Every", selection: $draft.every) {
                        Text("Month").tag(EvidencePeriodicity.month)
                        Text("Quarter").tag(EvidencePeriodicity.quarter)
                        Text("Year").tag(EvidencePeriodicity.year)
                    }
                    .pickerStyle(.segmented)
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
                .pickerStyle(.segmented)
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
}

/// The editor's fields, turned into a requirement on Save.
struct EvidenceRuleDraft {
    enum ScopeKind: CaseIterable {
        case category, categoryGroup, matching, periodic, single

        var title: String {
            switch self {
            case .category: return "Transactions in a category"
            case .categoryGroup: return "Transactions in a category group"
            case .matching: return "Transactions matching…"
            case .periodic: return "A document every period"
            case .single: return "A single document"
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
    var kinds: Set<DocumentKind> = []
    var direction = EvidenceTransactionDirection.outflows
    var excludedAccountIds: Set<Int64> = []
    var usualSource = ""
    var hasFrom = false
    /// Local midnights (what a `DatePicker` holds).
    var from = Calendar.current.startOfDay(for: Date())
    var hasUntil = false
    var until = Calendar.current.startOfDay(for: Date())
    var notes = ""

    init(_ requirement: EvidenceRequirement?) {
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
        }
        kinds = Set(requirement.kinds)
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
        }
    }

    /// The requirement to save: `base`'s id and creation date kept.
    func requirement(base: EvidenceRequirement?) -> EvidenceRequirement {
        let kindOrder = DocumentKind.allCases.filter(kinds.contains)
        let isTransactionScope = scopeKind.isTransactionScope
        var requirement = EvidenceRequirement(
            id: base?.id, name: name, scope: scope ?? .single(entity: .account(0)), kinds: kindOrder, direction: direction,
            excludedAccountIds: isTransactionScope ? excludedAccountIds.sorted() : [], usualSource: usualSource,
            activeFrom: hasFrom ? PayCalendar.utcDay(sameDayAs: from, in: .current) : nil,
            activeTo: hasUntil ? PayCalendar.utcDay(sameDayAs: until, in: .current).addingTimeInterval(86_400) : nil,
            notes: notes)
        if let base { requirement.createdAt = base.createdAt }
        return requirement
    }
}

/// Ticks for a few options, in a scrolling box.
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
                    Toggle(title, isOn: Binding(
                        get: { selection.contains(value) },
                        set: { isOn in if isOn { selection.insert(value) } else { selection.remove(value) } }))
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
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
                    .padding(4)
            }
        }
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

    var body: some View {
        SheetScaffold(title: "Set up property rules",
                      subtitle: "Every payment in the group's expense categories needs a document of the kind its category implies; every instalment paid into a mortgage account needs the bank's notice.",
                      error: error, width: 620, onCancel: { dismiss() },
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
                }
                LabeledContent("Mortgage accounts") {
                    CheckboxList(options: viewModel.accounts.compactMap { a in a.id.map { ($0, a.displayName) } },
                                 selection: $mortgageAccountIds, height: 90)
                        .sheetFieldNote("Their interest rows are left out of the mortgage categories' rules, so each instalment is asked for once.")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(groupId == nil ? "Choose a group to see the rules." : preview.isEmpty ? "Nothing to add: these rules already exist." : "Will add")
                    .font(.callout).foregroundStyle(.secondary)
                List(preview.indices, id: \.self) { index in
                    let rule = preview[index]
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.name)
                        Text([viewModel.scopeSummary(rule), "Needs " + MissingEvidenceViewModel.kindsText(rule.kinds),
                              rule.usualSource.map { "From \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .frame(height: 200)
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
