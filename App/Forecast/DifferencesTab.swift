// App/Forecast/DifferencesTab.swift
import SwiftUI
import BudgetCore

/// The selected scenario's differences from the budget, each with a checkbox; "Apply to
/// budget…" applies the ticked ones from the current pay month, "Undo last apply" undoes the
/// scenario's latest apply.
struct DifferencesTab: View {
    @ObservedObject var viewModel: ScenarioLabViewModel
    @State private var confirmingApply = false
    @State private var confirmingUndo = false

    var body: some View {
        if let scenario = viewModel.selectedScenario {
            content(scenario)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Select a scenario on the left to see how it differs from the budget.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func content(_ scenario: Scenario) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("“\(scenario.name)” vs the budget").font(.headline)
                Spacer()
                if !viewModel.differences.isEmpty {
                    Button(allTicked ? "Untick all" : "Tick all") {
                        viewModel.tickedDifferenceIds = allTicked ? [] : Set(viewModel.differences.map(\.id))
                    }
                }
                Button("Undo last apply") { confirmingUndo = true }
                    .disabled(!viewModel.canUndo)
                    .help(viewModel.canUndo ? "Puts the budget back as it was before this scenario's latest apply." : "Nothing applied from this scenario to undo.")
                Button("Apply to budget…") { confirmingApply = true }
                    .disabled(viewModel.tickedDifferenceIds.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Applied changes start from the current pay month (\(PayMonthFormat.name(viewModel.payCalendar.current))) and become ordinary planned items in the budget.")
                .font(.caption).foregroundStyle(.secondary)
            if viewModel.differences.isEmpty {
                Text("No differences: this scenario matches its copy of the budget. Change it in the Grid tab.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Spacer()
            } else {
                List(viewModel.differences) { difference in
                    differenceRow(difference)
                }
            }
        }
        .confirmationDialog("Apply \(viewModel.tickedDifferenceIds.count) item\(viewModel.tickedDifferenceIds.count == 1 ? "" : "s") to the budget?",
                            isPresented: $confirmingApply, titleVisibility: .visible) {
            Button("Apply to budget") { viewModel.applyTicked() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.tickedDifferences.map { "\(Self.kindLabel($0.kind)): \($0.categoryName) — \($0.summary)" }.joined(separator: "\n"))
        }
        .confirmationDialog("Undo the last apply from “\(scenario.name)”?", isPresented: $confirmingUndo, titleVisibility: .visible) {
            Button("Undo last apply") { viewModel.undoLastApply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The items it added to the budget are removed and the items it ended are restored.")
        }
    }

    private var allTicked: Bool {
        !viewModel.differences.isEmpty && viewModel.tickedDifferenceIds.count == viewModel.differences.count
    }

    private func differenceRow(_ difference: ScenarioDifference) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { viewModel.tickedDifferenceIds.contains(difference.id) },
                set: { ticked in
                    if ticked { viewModel.tickedDifferenceIds.insert(difference.id) } else { viewModel.tickedDifferenceIds.remove(difference.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            Text(Self.kindLabel(difference.kind))
                .font(.caption.bold())
                .foregroundStyle(Self.kindColor(difference.kind))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Self.kindColor(difference.kind).opacity(0.15)))
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(difference.categoryName).fontWeight(.medium)
                Text(difference.summary).font(.callout).foregroundStyle(.secondary)
                ForEach(difference.fieldChanges, id: \.self) { change in
                    Text("• \(change)").font(.callout)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    static func kindLabel(_ kind: ScenarioChange) -> String {
        switch kind {
        case .added: return "Added"
        case .changed: return "Changed"
        case .removed: return "Removed"
        }
    }

    private static func kindColor(_ kind: ScenarioChange) -> Color {
        switch kind {
        case .added: return .green
        case .changed: return .orange
        case .removed: return .red
        }
    }
}
