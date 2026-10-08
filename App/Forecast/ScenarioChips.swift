// App/Forecast/ScenarioChips.swift
import SwiftUI
import BudgetCore

/// A Forecast tab's plan chips (spec 2026-10-08-scenario-lab-tabs-design.md, "Forecast screen
/// layout"): "Budget" first, then each scenario in its `PlanPalette` colour, then
/// "+ New scenario" (copies the budget). A scenario chip's context menu renames, duplicates,
/// refreshes from the budget or deletes it.
///
/// `.multi` chips are toggles with the Budget always on (Compare, Differences); `.single`
/// selects one plan, nil being the Budget (Grid).
///
/// The name sheet and delete confirmation the chips open are presented by `ScenarioLabView`
/// (`scenarioChipPrompts`), not by the chip row: creating or duplicating switches to the
/// Grid tab, which removes the Compare / Differences chip row while its sheet is dismissing.
struct ScenarioChips: View {
    enum Mode {
        case multi(selected: Binding<Set<Int64>>)
        case single(selected: Binding<Int64?>)
    }

    @ObservedObject var viewModel: ScenarioLabViewModel
    let mode: Mode
    @Binding var prompts: ScenarioChipPrompts

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                budgetChip
                ForEach(Array(viewModel.scenarios.enumerated()), id: \.element.id) { index, scenario in
                    scenarioChip(scenario, colorIndex: index + 1)
                }
                newChip
                if viewModel.scenarios.isEmpty {
                    Text("A scenario starts as a copy of the budget. Change it freely, compare, then apply what you like.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: Chips

    @ViewBuilder
    private var budgetChip: some View {
        switch mode {
        case .multi:
            // Always on: Δ and the differences are measured against it.
            PlanChip(name: "Budget", color: PlanPalette.color(0), isSelected: true, isEmphasised: true, action: nil)
                .help("The budget is always shown")
        case .single(let selected):
            PlanChip(name: "Budget", color: PlanPalette.color(0), isSelected: selected.wrappedValue == nil, isEmphasised: true) {
                selected.wrappedValue = nil
            }
            .help("The budget, read-only")
        }
    }

    private func scenarioChip(_ scenario: Scenario, colorIndex: Int) -> some View {
        PlanChip(name: scenario.name, color: PlanPalette.color(colorIndex), isSelected: isSelected(scenario), isEmphasised: false) {
            select(scenario)
        }
        .help(Self.copiedLabel(scenario))
        .contextMenu {
            Button("Rename…") { prompts.nameSheet = .rename(scenario) }
            Button("Duplicate…") { prompts.nameSheet = .duplicate(scenario) }
            Button("Refresh from budget") { viewModel.refresh(scenario) }
            Divider()
            Button("Delete…", role: .destructive) { prompts.deleting = scenario }
        }
    }

    private var newChip: some View {
        Button { prompts.nameSheet = .new } label: {
            Label("New scenario", systemImage: "plus")
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Capsule().stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("A new scenario, starting as a copy of today's budget")
    }

    private func isSelected(_ scenario: Scenario) -> Bool {
        guard let id = scenario.id else { return false }
        switch mode {
        case .multi(let selected): return selected.wrappedValue.contains(id)
        case .single(let selected): return selected.wrappedValue == id
        }
    }

    private func select(_ scenario: Scenario) {
        guard let id = scenario.id else { return }
        switch mode {
        case .multi(let selected):
            if selected.wrappedValue.contains(id) { selected.wrappedValue.remove(id) } else { selected.wrappedValue.insert(id) }
        case .single(let selected):
            selected.wrappedValue = id
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    /// "Copied 7 Oct 2026" / "Refreshed 9 Oct 2026": how old its copy of the budget is.
    static func copiedLabel(_ scenario: Scenario) -> String {
        if let refreshed = scenario.refreshedAt { return "Refreshed \(dayFormatter.string(from: refreshed))" }
        return "Copied \(dayFormatter.string(from: scenario.createdAt))"
    }
}

/// What a chip row asked to open: a name sheet (new, rename, duplicate) or the delete
/// confirmation. Owned by `ScenarioLabView`, shared by every tab's chip row.
struct ScenarioChipPrompts {
    enum NameSheet: Identifiable {
        case new
        case rename(Scenario)
        case duplicate(Scenario)

        var id: String {
            switch self {
            case .new: return "new"
            case .rename(let scenario): return "rename-\(scenario.id ?? -1)"
            case .duplicate(let scenario): return "duplicate-\(scenario.id ?? -1)"
            }
        }
    }

    var nameSheet: NameSheet?
    var deleting: Scenario?
}

extension View {
    /// Presents the chip rows' name sheet and delete confirmation.
    func scenarioChipPrompts(_ prompts: Binding<ScenarioChipPrompts>, viewModel: ScenarioLabViewModel) -> some View {
        sheet(item: prompts.nameSheet) { sheet in
            switch sheet {
            case .new:
                ScenarioNameSheet(title: "New scenario", message: "Starts as a copy of today's budget.", actionLabel: "Create", initialName: "") { name in
                    viewModel.createScenario(name: name)
                }
            case .rename(let scenario):
                ScenarioNameSheet(title: "Rename scenario", message: nil, actionLabel: "Rename", initialName: scenario.name) { name in
                    viewModel.rename(scenario, to: name)
                }
            case .duplicate(let scenario):
                ScenarioNameSheet(title: "Duplicate “\(scenario.name)”", message: "Copies the scenario with all its changes.", actionLabel: "Duplicate", initialName: "\(scenario.name) copy") { name in
                    viewModel.duplicate(scenario, name: name)
                }
            }
        }
        .confirmationDialog("Delete “\(prompts.wrappedValue.deleting?.name ?? "")”?", isPresented: Binding(
            get: { prompts.wrappedValue.deleting != nil },
            set: { if !$0 { prompts.wrappedValue.deleting = nil } }
        ), titleVisibility: .visible, presenting: prompts.wrappedValue.deleting) { scenario in
            Button("Delete scenario", role: .destructive) { viewModel.delete(scenario); prompts.wrappedValue.deleting = nil }
            Button("Cancel", role: .cancel) { prompts.wrappedValue.deleting = nil }
        } message: { _ in
            Text("Its changes are deleted. The budget, and anything already applied to it, stays as it is.")
        }
    }
}

/// One chip: colour dot + name; selected = filled with a tint of the plan's colour and
/// bordered in it. Without an action it is shown but not clickable.
private struct PlanChip: View {
    let name: String
    let color: Color
    let isSelected: Bool
    let isEmphasised: Bool
    let action: (() -> Void)?

    var body: some View {
        let label = HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).lineLimit(1).fontWeight(isEmphasised ? .medium : .regular)
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(isSelected ? color.opacity(0.18) : Color.clear))
        .overlay(Capsule().stroke(isSelected ? color : Color.secondary.opacity(0.35), lineWidth: isSelected ? 1.5 : 1))
        .contentShape(Capsule())
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            label
                .accessibilityAddTraits(.isSelected)
        }
    }
}

/// Names a scenario (new, rename, duplicate). A failed save (blank or taken name) keeps the
/// sheet open with the message.
struct ScenarioNameSheet: View {
    let title: String
    let message: String?
    let actionLabel: String
    let onSave: (String) -> SaveOutcome
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var errorMessage: String?

    init(title: String, message: String?, actionLabel: String, initialName: String, onSave: @escaping (String) -> SaveOutcome) {
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            Text(title).font(.headline)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Name", text: $name)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(actionLabel) {
                    switch onSave(name) {
                    case .saved, .savedButReloadFailed: dismiss()
                    case .failed(let message): errorMessage = message
                    }
                }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: name) { _, _ in errorMessage = nil }
        .padding()
        .frame(width: 380)
    }
}
