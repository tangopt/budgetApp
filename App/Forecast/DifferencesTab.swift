// App/Forecast/DifferencesTab.swift
import SwiftUI
import BudgetCore

/// The Differences chips, then the ticked scenarios side by side with the budget
/// (spec 2026-10-08-scenario-lab-tabs-design.md, "Differences tab"): one row per item that
/// differs in any ticked scenario (`DifferenceMatrix`), a Budget column, then one column per
/// scenario. A differing cell is tinted in its scenario's colour and offers a tick box
/// (one per row), Edit… and Revert; an applied one shows "Applied". "Apply to budget…"
/// applies the ticked cells from the current pay month, "Undo last apply" undoes a scenario's
/// latest apply.
struct DifferencesTab: View {
    @ObservedObject var viewModel: ScenarioLabViewModel
    @Binding var chipPrompts: ScenarioChipPrompts
    @State private var confirmingApply = false
    @State private var undoing: Scenario?
    @State private var reverting: RevertTarget?
    @State private var editing: PlannedRow?

    private struct RevertTarget: Identifiable {
        let scenario: Scenario
        let difference: ScenarioDifference
        var id: Int64 { difference.id }
    }

    private static let categoryWidth: CGFloat = 190
    private static let budgetWidth: CGFloat = 230
    private static let scenarioWidth: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScenarioChips(viewModel: viewModel, mode: .multi(selected: $viewModel.differencesSelection), prompts: $chipPrompts)
            if viewModel.differencesScenarios.isEmpty {
                Text("Tick a scenario above to see how it differs from the budget.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                content
            }
        }
        .confirmationDialog(applyTitle, isPresented: $confirmingApply, titleVisibility: .visible) {
            Button("Apply to budget") { viewModel.applyTicked() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(applyMessage)
        }
        .confirmationDialog("Undo the last apply from “\(undoing?.name ?? "")”?", isPresented: Binding(
            get: { undoing != nil },
            set: { if !$0 { undoing = nil } }
        ), titleVisibility: .visible, presenting: undoing) { scenario in
            Button("Undo last apply") { viewModel.undoLastApply(scenario); undoing = nil }
            Button("Cancel", role: .cancel) { undoing = nil }
        } message: { _ in
            Text("The items it added to the budget are removed and the items it ended are restored.")
        }
        .confirmationDialog(revertTitle, isPresented: Binding(
            get: { reverting != nil },
            set: { if !$0 { reverting = nil } }
        ), titleVisibility: .visible, presenting: reverting) { target in
            Button("Revert", role: .destructive) { viewModel.revert(target.difference, in: target.scenario); reverting = nil }
            Button("Cancel", role: .cancel) { reverting = nil }
        } message: { _ in
            Text("Your edits to this item in the scenario are lost.")
        }
        .sheet(item: $editing) { row in
            EditOccurrenceSheet(row: row, categories: viewModel.categories, fixedScope: .thisAndFollowing) { change, scope in
                viewModel.planEditActions.save(row, change, scope)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("The ticked scenarios vs the budget").font(.headline)
                Spacer()
                if !viewModel.tickedDifferenceIds.isEmpty {
                    Button("Untick all") { viewModel.tickedDifferenceIds = [] }
                }
                Menu("Undo last apply") {
                    ForEach(viewModel.undoableScenarios) { scenario in
                        Button(scenario.name) { undoing = scenario }
                    }
                }
                .fixedSize()
                .disabled(viewModel.undoableScenarios.isEmpty)
                .help(viewModel.undoableScenarios.isEmpty ? "Nothing applied from the ticked scenarios to undo." : "Puts the budget back as it was before a scenario's latest apply.")
                Button("Apply to budget…") { confirmingApply = true }
                    .disabled(viewModel.tickedDifferenceIds.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Tick one version per item. Applied changes start from the current pay month (\(PayMonthFormat.name(viewModel.payCalendar.current))) and become ordinary planned items in the budget.")
                .font(.caption).foregroundStyle(.secondary)
            if viewModel.differenceRows.isEmpty {
                Text("No differences: the ticked scenarios match their copies of the budget. Change them in the Grid tab.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Spacer()
            } else {
                table
            }
        }
    }

    // MARK: Table

    private var table: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(viewModel.differenceRows) { row in
                        rowView(row)
                        Divider()
                    }
                } header: {
                    headerRow
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Category").fontWeight(.medium)
                .padding(8)
                .frame(width: Self.categoryWidth, alignment: .leading)
            columnHeader("Budget", color: PlanPalette.color(0), width: Self.budgetWidth)
            ForEach(viewModel.differencesScenarios) { scenario in
                columnHeader(scenario.name, color: PlanPalette.color(viewModel.colorIndex(of: scenario.id)), width: Self.scenarioWidth)
            }
        }
        .font(.callout)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func columnHeader(_ name: String, color: Color, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).fontWeight(.medium).lineLimit(1)
        }
        .padding(8)
        .frame(width: width, alignment: .leading)
        .background(color.opacity(0.14))
    }

    private func rowView(_ row: DifferenceMatrix.Row) -> some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 6) {
                Text(row.categoryName).fontWeight(.medium)
                if row.isAdded {
                    Text("new")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                }
            }
            .padding(8)
            .frame(width: Self.categoryWidth, alignment: .topLeading)
            Text(row.budgetSummary ?? "—")
                .foregroundStyle(row.budgetSummary == nil ? .tertiary : .primary)
                .padding(8)
                .frame(width: Self.budgetWidth, alignment: .topLeading)
            ForEach(viewModel.differencesScenarios) { scenario in
                scenarioCell(row, scenario)
                    .padding(8)
                    .frame(width: Self.scenarioWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(row.cells[scenario.id ?? -1] == nil ? Color.clear : PlanPalette.color(viewModel.colorIndex(of: scenario.id)).opacity(0.1))
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The scenario's difference in this row; else the budget's version when the scenario
    /// holds an unchanged copy of it, "—" when it doesn't have the item.
    @ViewBuilder
    private func scenarioCell(_ row: DifferenceMatrix.Row, _ scenario: Scenario) -> some View {
        if let id = scenario.id, let difference = row.cells[id] {
            differenceCell(difference, row: row, scenario: scenario)
        } else if !row.isAdded, let sourceId = row.cells.values.first?.sourceEntryId,
                  let id = scenario.id, viewModel.unchangedCopies[id]?.contains(sourceId) == true {
            Text(row.budgetSummary ?? "").foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func differenceCell(_ difference: ScenarioDifference, row: DifferenceMatrix.Row, scenario: Scenario) -> some View {
        let applied = viewModel.appliedDifferenceIds.contains(difference.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                if !applied {
                    Toggle("", isOn: Binding(
                        get: { viewModel.tickedDifferenceIds.contains(difference.id) },
                        set: { viewModel.setTicked($0, difference, in: row) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("Apply this version to the budget")
                }
                VStack(alignment: .leading, spacing: 2) {
                    if applied {
                        Text("Applied")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .help("Already applied to the budget. Undo the apply to apply it again.")
                    }
                    if difference.kind == .removed {
                        Text("Removed").fontWeight(.medium).foregroundStyle(.red)
                    } else {
                        Text(difference.summary)
                    }
                    ForEach(difference.fieldChanges, id: \.self) { change in
                        Text("• \(change)").foregroundStyle(.secondary)
                    }
                }
            }
            if !applied {
                HStack(spacing: 12) {
                    if let occurrence = viewModel.editableOccurrences[difference.id] {
                        Button("Edit…") { editing = occurrence }
                            .help("Edit this item in “\(scenario.name)” from its first open pay month")
                    }
                    Button("Revert") { reverting = RevertTarget(scenario: scenario, difference: difference) }
                        .help("Put this item in “\(scenario.name)” back to the budget's version")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    // MARK: Confirmations

    private var applyTitle: String {
        let count = viewModel.tickedDifferenceIds.count
        return "Apply \(count) item\(count == 1 ? "" : "s") to the budget?"
    }

    /// The ticked cells grouped by scenario.
    private var applyMessage: String {
        viewModel.tickedByScenario.map { group in
            (["From “\(group.scenario.name)”:"] + group.differences.map { "\(Self.kindLabel($0.kind)): \($0.categoryName) — \($0.summary)" })
                .joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private var revertTitle: String {
        guard let reverting else { return "" }
        return "Revert \(reverting.difference.categoryName) in “\(reverting.scenario.name)” to the budget?"
    }

    static func kindLabel(_ kind: ScenarioChange) -> String {
        switch kind {
        case .added: return "Added"
        case .changed: return "Changed"
        case .removed: return "Removed"
        }
    }
}
