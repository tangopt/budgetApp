// App/Rules/RulesView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct RulesView: View {
    @ObservedObject var viewModel: RulesViewModel
    @State private var searchText = ""
    @State private var selection: Set<Rule.ID> = []
    /// The rule sheet on show: a new rule, or an existing one being edited.
    @State private var sheetDraft: RuleDraft?

    /// `viewModel.rules` filtered by a case-insensitive substring match against
    /// `matchPattern`. An empty `searchText` (the default) matches everything, so
    /// existing behavior is unchanged until the user actually types.
    private var filteredRules: [Rule] {
        guard !searchText.isEmpty else { return viewModel.rules }
        return viewModel.rules.filter { $0.matchPattern.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Table(filteredRules, selection: $selection) {
            TableColumn("Pattern") { rule in Text(rule.matchPattern) }
            TableColumn("Type") { rule in Text(rule.matchType.title) }
            TableColumn("Category") { rule in
                Picker("", selection: Binding(
                    get: { rule.categoryId },
                    set: { newValue in try? viewModel.updateCategory(rule, to: newValue) }
                )) {
                    ForEach(viewModel.categories.filter(\.isAssignable)) { category in Text(category.name).tag(category.id!) }
                }
                .labelsHidden()
            }
            TableColumn("Priority") { rule in Text("\(rule.priority)") }
            TableColumn("") { rule in
                Button("Delete") { try? viewModel.delete(rule) }
            }
        }
        .contextMenu(forSelectionType: Rule.ID.self) { ids in
            if ids.count == 1, let rule = rule(ids.first ?? nil) {
                Button("Edit Rule…") { sheetDraft = RuleDraft(rule: rule) }
            }
        } primaryAction: { ids in
            // Double-click (or Return) on a row edits it.
            if ids.count == 1, let rule = rule(ids.first ?? nil) { sheetDraft = RuleDraft(rule: rule) }
        }
        .padding()
        .searchable(text: $searchText, prompt: "Search patterns")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { sheetDraft = RuleDraft() } label: { Label("Rule", systemImage: "plus") }
                    .help("New rule")
            }
        }
        .sheet(item: $sheetDraft) { draft in
            RuleSheet(draft: draft, viewModel: viewModel) { sheetDraft = nil }
        }
    }

    private func rule(_ id: Int64?) -> Rule? {
        guard let id else { return nil }
        return viewModel.rules.first { $0.id == id }
    }
}

extension RuleMatchType {
    var title: String {
        switch self {
        case .contains: return "Contains"
        case .regex: return "Regular expression"
        }
    }
}

/// What the rule sheet opens with.
struct RuleDraft: Identifiable {
    let id = UUID()
    var ruleId: Int64?
    var pattern = ""
    var matchType: RuleMatchType = .contains
    var categoryId: Int64?

    init() {}

    init(rule: Rule) {
        ruleId = rule.id
        pattern = rule.matchPattern
        matchType = rule.matchType
        categoryId = rule.categoryId
    }
}

/// New rule / Edit rule (spec 2026-10-16 §B): pattern, match type, category, a live preview of
/// what it matches, and whether to file the uncategorised matches now.
private struct RuleSheet: View {
    let draft: RuleDraft
    @ObservedObject var viewModel: RulesViewModel
    let dismiss: () -> Void

    @State private var pattern: String
    @State private var matchType: RuleMatchType
    @State private var categoryId: Int64?
    @State private var applyNow = true
    @State private var preview: RulePreview = .empty
    /// The pattern and type `preview` was computed for; nil until the first one loads.
    @State private var previewKey: PreviewKey?
    @State private var previewError: String?
    @State private var error: String?

    init(draft: RuleDraft, viewModel: RulesViewModel, dismiss: @escaping () -> Void) {
        self.draft = draft
        self.viewModel = viewModel
        self.dismiss = dismiss
        _pattern = State(initialValue: draft.pattern)
        _matchType = State(initialValue: draft.matchType)
        _categoryId = State(initialValue: draft.categoryId)
    }

    private var validation: RuleSaveError? { Rules.validationError(pattern: pattern, matchType: matchType) }

    /// Only the regex check shows inline (a blank pattern just disables Save).
    private var patternNote: String? { validation == .invalidRegex ? RuleSaveError.invalidRegex.message : nil }

    private var assignableCategories: [Category] { viewModel.categories.filter(\.isAssignable) }

    private var canSave: Bool { validation == nil && categoryId.map { id in assignableCategories.contains { $0.id == id } } == true }

    private struct PreviewKey: Hashable {
        let pattern: String
        let matchType: RuleMatchType
    }

    var body: some View {
        SheetScaffold(
            title: draft.ruleId == nil ? "New Rule" : "Edit Rule",
            subtitle: "Transactions whose description matches are filed into the category when imported.",
            error: error,
            width: 480,
            onCancel: dismiss,
            primary: SheetAction(draft.ruleId == nil ? "Add Rule" : "Save", isEnabled: canSave, action: save)
        ) {
            SheetForm {
                LabeledContent("Pattern") {
                    TextField("Pattern", text: $pattern, prompt: Text(matchType == .regex ? "e.g. ^TESCO" : "e.g. TESCO"))
                        .textFieldStyle(.roundedBorder)
                        .sheetFieldNote(patternNote, isError: true)
                }
                LabeledContent("Match") {
                    Picker("Match", selection: $matchType) {
                        ForEach(RuleMatchType.allCases, id: \.self) { type in Text(type.title).tag(type) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                LabeledContent("Category") {
                    CategoryPickerButton(
                        selection: $categoryId,
                        categories: assignableCategories,
                        groups: viewModel.categoryGroups,
                        suggestedId: nil,
                        recentIds: viewModel.recentCategoryIds,
                        amountMinorUnits: nil,
                        createCategory: viewModel.createCategory
                    )
                    .frame(maxWidth: 260)
                }
            }
            previewSection
        }
        .task(id: PreviewKey(pattern: pattern, matchType: matchType)) {
            // A short pause so typing doesn't run a search per keystroke.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let key = PreviewKey(pattern: pattern, matchType: matchType)
            do {
                let result = try await viewModel.preview(pattern: pattern, matchType: matchType)
                guard !Task.isCancelled else { return }
                preview = result
                previewKey = key
                previewError = nil
            } catch {
                guard !Task.isCancelled else { return }
                preview = .empty
                previewKey = nil
                previewError = "Couldn't check which transactions match: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if validation != nil {
                Text("Enter a pattern to see what it matches.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let previewError {
                SheetCaption(previewError, isError: true)
            } else {
                Text(matchSummary).font(.callout)
                if !preview.sampleDescriptions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(preview.sampleDescriptions.enumerated()), id: \.offset) { _, description in
                            Text(description)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if preview.matchCount > preview.sampleDescriptions.count {
                            Text("and \(preview.matchCount - preview.sampleDescriptions.count) more")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 8)
                }
                Toggle(applyLabel, isOn: $applyNow)
                    .toggleStyle(.checkbox)
                    .disabled(preview.uncategorisedCount == 0 || previewKey != PreviewKey(pattern: pattern, matchType: matchType))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var matchSummary: String {
        let n = preview.matchCount
        let m = preview.uncategorisedCount
        return "Matches \(n) transaction\(n == 1 ? "" : "s") (\(m) uncategorised)"
    }

    private var applyLabel: String {
        let m = preview.uncategorisedCount
        return m == 1 ? "Also categorise the 1 uncategorised match now" : "Also categorise the \(m) uncategorised matches now"
    }

    /// Whether saving files the uncategorised matches: only when ticked and the preview on
    /// show is for this exact pattern and has some (so the checkbox means what it says).
    private var appliesNow: Bool {
        applyNow && previewKey == PreviewKey(pattern: pattern, matchType: matchType) && preview.uncategorisedCount > 0
    }

    private func save() {
        guard canSave, let categoryId else { return }
        error = viewModel.save(ruleId: draft.ruleId, pattern: pattern, matchType: matchType, categoryId: categoryId,
                               applyToUncategorised: appliesNow)
        if error == nil { dismiss() }
    }
}
