// App/Forecast/ScenarioListPanel.swift
import SwiftUI
import BudgetCore

/// The lab's left panel: "Budget" first, then the scenarios, each with a "compare"
/// checkbox, a selection highlight and a menu (Rename…, Duplicate…, Refresh from budget,
/// Delete…); "New scenario…" copies the budget.
struct ScenarioListPanel: View {
    @ObservedObject var viewModel: ScenarioLabViewModel
    @State private var nameSheet: NameSheet?
    @State private var deleting: Scenario?

    private enum NameSheet: Identifiable {
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

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PLANS")
                    .font(.caption).bold().tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                budgetRow
                ForEach(Array(viewModel.scenarios.enumerated()), id: \.element.id) { index, scenario in
                    scenarioRow(scenario, colorIndex: index + 1)
                }
                if viewModel.scenarios.isEmpty {
                    Text("A scenario starts as a copy of the budget. Change it freely, compare, then apply what you like.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                Button("+ New scenario…") { nameSheet = .new }
                    .buttonStyle(.borderless)
                    .padding(.top, 6)
            }
            .padding()
        }
        .sheet(item: $nameSheet) { sheet in
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
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { scenario in
            Button("Delete scenario", role: .destructive) { viewModel.delete(scenario); deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("Its changes are deleted. The budget, and anything already applied to it, stays as it is.")
        }
    }

    private var budgetRow: some View {
        HStack(spacing: 8) {
            // The Budget is always on the chart: a fixed, checked box.
            Toggle("", isOn: .constant(true))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
                .help("The budget is always compared")
            Circle().fill(PlanPalette.color(0)).frame(width: 8, height: 8)
            Text("Budget").fontWeight(.medium)
            Spacer()
        }
        .modifier(SelectableRow(isSelected: viewModel.selectedScenarioId == nil) { viewModel.selectedScenarioId = nil })
    }

    private func scenarioRow(_ scenario: Scenario, colorIndex: Int) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { viewModel.isCompared(scenario) },
                set: { viewModel.setCompared(scenario, $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help("Compare")
            Circle().fill(PlanPalette.color(colorIndex)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(scenario.name).lineLimit(1)
                Text(Self.copiedLabel(scenario)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Rename…") { nameSheet = .rename(scenario) }
                Button("Duplicate…") { nameSheet = .duplicate(scenario) }
                Button("Refresh from budget") { viewModel.refresh(scenario) }
                Divider()
                Button("Delete…", role: .destructive) { deleting = scenario }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .modifier(SelectableRow(isSelected: viewModel.selectedScenarioId == scenario.id) { viewModel.selectedScenarioId = scenario.id })
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

/// A list row that selects on click, with the accent highlight when selected.
private struct SelectableRow: ViewModifier {
    let isSelected: Bool
    let select: () -> Void

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
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
