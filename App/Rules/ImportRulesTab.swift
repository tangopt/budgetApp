// App/Rules/ImportRulesTab.swift
import SwiftUI
import BudgetCore

/// The Rules page's "Import rules" tab: what the importer learnt from the user's corrections,
/// in the transaction rules' table look — kind, when, then, how often used, on/off — with
/// Edit Rule… (the action only) and Delete. A rule whose account or record is gone says
/// "Target missing" (the importer skips it).
struct ImportRulesTab: View {
    @ObservedObject var viewModel: RulesViewModel
    let searchText: String
    @State private var selection: Set<ImportRuleRow.ID> = []
    @State private var editing: ImportRuleEditContext?
    @State private var error: String?
    /// The rule whose Delete is waiting for confirmation.
    @State private var deleting: Int64?

    /// "When" and "Then" matched case-insensitively; empty matches everything.
    private var filteredRows: [ImportRuleRow] {
        guard !searchText.isEmpty else { return viewModel.importRules }
        return viewModel.importRules.filter {
            $0.when.localizedCaseInsensitiveContains(searchText) || $0.then.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if viewModel.importRules.isEmpty {
                EmptyState(systemImage: "wand.and.stars", title: "No import rules",
                           message: "Nothing learnt yet: corrections you make while importing appear here.")
                    .fillingScreen()
            } else {
                table
            }
        }
        // "Show on Rules page" from an import's review: that rule selected.
        .onAppear { takeFocus() }
        .onChange(of: viewModel.focusedImportRuleId) { takeFocus() }
        .onChange(of: viewModel.importRules) { takeFocus(afterReload: true) }
    }

    private var table: some View {
        Table(filteredRows, selection: $selection) {
            TableColumn("Kind") { row in Text(row.kindLabel).lineLimit(1) }
                .width(min: 110, ideal: 130, max: 160)
            TableColumn("When") { row in
                Text(row.when).lineLimit(1).truncationMode(.middle).help(row.when)
            }
            TableColumn("Then") { row in
                HStack(spacing: 6) {
                    Text(row.then).lineLimit(1).truncationMode(.tail).help(row.then)
                    if let who = row.attributionLabel {
                        Text(who).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(who)
                    }
                    if row.targetMissing {
                        StatusPill("Target missing", tone: .warning,
                                   help: "Its account, record or kind no longer exists: the importer skips this rule. Edit it or delete it.")
                    }
                }
            }
            TableColumn("Used") { row in Text(Self.used(row)).monospacedDigit().figureText(.shrink()) }
                .width(min: 90, ideal: 100, max: 130)
            TableColumn("On") { row in
                Toggle("On", isOn: Binding(
                    get: { row.isEnabled },
                    set: { enabled in perform { try viewModel.setEnabled(importRuleId: row.id, enabled) } }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(row.isEnabled ? "Applied on import" : "Off: not applied on import")
            }
            .width(36)
        }
        .wrapProbeClips()
        .contextMenu(forSelectionType: ImportRuleRow.ID.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Edit Rule…") { edit(id) }
                Divider()
                Button("Delete…", role: .destructive) { deleting = id }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { edit(id) }
        }
        .padding()
        .sheet(item: $editing) { context in
            ImportRuleSheet(context: context, viewModel: viewModel) { editing = nil }
        }
        .confirmationDialog("Delete this rule? The importer will forget it.",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = deleting { perform { try viewModel.delete(importRuleId: id) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
        .alert("Couldn't change the rule", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// `afterReload`: the rows were just read; a rule they lack is gone (deleted meanwhile), so the
    /// request is dropped. Otherwise it is kept until the rows (re-read as the page opens) hold it.
    private func takeFocus(afterReload: Bool = false) {
        guard let id = viewModel.focusedImportRuleId else { return }
        guard viewModel.importRules.contains(where: { $0.id == id }) else {
            if afterReload { viewModel.focusedImportRuleId = nil }
            return
        }
        viewModel.focusedImportRuleId = nil
        selection = [id]
    }

    private func edit(_ id: Int64) {
        perform { editing = try viewModel.importRuleEditContext(id: id) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }

    /// "12 × · 3 Oct" (the year too when it isn't this one); "Not yet" before its first use.
    static func used(_ row: ImportRuleRow) -> String {
        guard row.useCount > 0 else { return "Not yet" }
        guard let last = row.lastUsedAt else { return "\(row.useCount) ×" }
        let sameYear = Calendar.current.isDate(last, equalTo: AppClock.now, toGranularity: .year)
        return "\(row.useCount) × · " + (sameYear ? dayMonth : dayMonthYear).string(from: last)
    }

    private static let dayMonth = formatter("d MMM")
    private static let dayMonthYear = formatter("d MMM yyyy")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = format
        return formatter
    }
}

/// Edit Rule for a learnt import rule: a picker or text suited to its kind. Only what the rule
/// does changes; what it matches stays.
private struct ImportRuleSheet: View {
    let context: ImportRuleEditContext
    @ObservedObject var viewModel: RulesViewModel
    let dismiss: () -> Void

    @State private var edit: ImportRuleEdit
    @State private var error: String?

    init(context: ImportRuleEditContext, viewModel: RulesViewModel, dismiss: @escaping () -> Void) {
        self.context = context
        self.viewModel = viewModel
        self.dismiss = dismiss
        _edit = State(initialValue: context.edit)
    }

    private var canSave: Bool {
        switch edit {
        case .issuerName(let text), .merchant(let text), .figureLabel(let text):
            return ImportRuleEditing.isValidText(text)
        case .account(let id):
            return context.accounts.contains { $0.id == id }
        case .link(let entity):
            return context.linkTargets.contains { $0.entity == entity }
        case .documentKind(let kind):
            return context.documentKinds.contains { $0.ref == kind }
        }
    }

    var body: some View {
        SheetScaffold(
            title: "Edit Rule",
            subtitle: "What the importer does with \(context.when). Takes effect on the next import.",
            error: error,
            width: 480,
            onCancel: dismiss,
            primary: SheetAction("Save", isEnabled: canSave, action: save)
        ) {
            SheetForm {
                LabeledContent("Kind") { Text(ImportRuleEditing.kindLabel(context.kind)) }
                field
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        switch edit {
        case .account(let id):
            LabeledContent("Account") {
                Picker("Account", selection: Binding(get: { id }, set: { edit = .account($0) })) {
                    if !context.accounts.contains(where: { $0.id == id }) { Text("Choose an account").tag(id) }
                    ForEach(context.accounts, id: \.id) { account in Text(account.name).tag(account.id) }
                }
                .labelsHidden().frame(maxWidth: 260)
            }
        case .documentKind(let kind):
            LabeledContent("Document type") {
                Picker("Document type", selection: Binding(get: { kind }, set: { edit = .documentKind($0) })) {
                    // A custom kind gone since: shown until another is chosen (Save waits for one).
                    if !context.documentKinds.contains(where: { $0.ref == kind }) { Text("Choose a kind").tag(kind) }
                    ForEach(context.documentKinds, id: \.ref) { option in Text(option.name).tag(option.ref) }
                }
                .labelsHidden().frame(maxWidth: 260)
            }
        case .issuerName(let name):
            LabeledContent("Issuer name") {
                TextField("Issuer name", text: Binding(get: { name }, set: { edit = .issuerName($0) }))
                    .textFieldStyle(.roundedBorder)
            }
        case .link(let entity):
            LabeledContent("Link to") {
                Picker("Link to", selection: Binding(get: { entity }, set: { edit = .link($0) })) {
                    if !context.linkTargets.contains(where: { $0.entity == entity }) { Text("Choose a record").tag(entity) }
                    ForEach(context.linkTargets) { target in Text(target.label).tag(target.entity) }
                }
                .labelsHidden().frame(maxWidth: 260)
            }
        case .merchant(let merchant):
            LabeledContent("Paid by") {
                TextField("Merchant", text: Binding(get: { merchant }, set: { edit = .merchant($0) }),
                          prompt: Text("e.g. EXAMPLE POWER"))
                    .textFieldStyle(.roundedBorder)
                    .sheetFieldNote("The merchant of the transactions that pay these documents.", isError: false)
            }
        case .figureLabel(let label):
            LabeledContent("Label") {
                TextField("Label", text: Binding(get: { label }, set: { edit = .figureLabel($0) }), prompt: Text("e.g. Total a pagar"))
                    .textFieldStyle(.roundedBorder)
                    .sheetFieldNote("The figure is read after this text on the page.", isError: false)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        error = viewModel.update(importRuleId: context.ruleId, edit: edit)
        if error == nil { dismiss() }
    }
}
