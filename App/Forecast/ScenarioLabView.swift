// App/Forecast/ScenarioLabView.swift
import SwiftUI
import BudgetCore

/// The Forecast screen: the Compare / Differences / Grid tabs and the horizon in the window toolbar; each
/// tab shows its own scenario chips (`ScenarioChips`) under them. The chips' sheets and
/// dialogs, and the refresh / apply / undo notices, are presented here.
struct ScenarioLabView: View {
    @ObservedObject var viewModel: ScenarioLabViewModel
    /// The chip rows' name sheet and delete confirmation, presented here so that switching
    /// tabs (a created scenario opens the Grid) never removes their presenter.
    @State private var chipPrompts = ScenarioChipPrompts()

    enum Tab: String, CaseIterable, Identifiable {
        case compare = "Compare"
        case differences = "Differences"
        case grid = "Grid"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = viewModel.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { viewModel.errorMessage = nil }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
            }
            switch viewModel.tab {
            case .compare: CompareTab(viewModel: viewModel, chipPrompts: $chipPrompts)
            case .differences: DifferencesTab(viewModel: viewModel, chipPrompts: $chipPrompts)
            case .grid: ScenarioGridTab(viewModel: viewModel, chipPrompts: $chipPrompts)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Window toolbar items live only while this screen is shown.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $viewModel.tab) {
                    ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Horizon", selection: $viewModel.horizon) {
                    ForEach(ComparisonHorizon.allCases) { horizon in Text(horizon.label).tag(horizon) }
                }
            }
        }
        .scenarioChipPrompts($chipPrompts, viewModel: viewModel)
        .alert(viewModel.notice?.title ?? "", isPresented: Binding(
            get: { viewModel.notice != nil },
            set: { if !$0 { viewModel.notice = nil } }
        ), presenting: viewModel.notice) { _ in
            Button("OK") { viewModel.notice = nil }
        } message: { notice in
            Text(notice.lines.joined(separator: "\n"))
        }
    }
}

/// Chart and legend colours: the Budget first, then each scenario by its list position.
enum PlanPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint, .red]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}
