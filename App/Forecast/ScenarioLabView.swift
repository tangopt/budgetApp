// App/Forecast/ScenarioLabView.swift
import SwiftUI
import BudgetCore

/// The Forecast screen: the scenario list on the left; the horizon and the Compare /
/// Differences / Grid tabs on the right.
struct ScenarioLabView: View {
    @ObservedObject var viewModel: ScenarioLabViewModel

    enum Tab: String, CaseIterable, Identifiable {
        case compare = "Compare"
        case differences = "Differences"
        case grid = "Grid"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScenarioListPanel(viewModel: viewModel)
                .frame(width: 250)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("View", selection: $viewModel.tab) {
                        ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Spacer()
                    Picker("Horizon", selection: $viewModel.horizon) {
                        ForEach(ComparisonHorizon.allCases) { horizon in Text(horizon.label).tag(horizon) }
                    }
                    .frame(maxWidth: 240)
                }
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
                case .compare: CompareTab(viewModel: viewModel)
                case .differences: DifferencesTab(viewModel: viewModel)
                case .grid: ScenarioGridTab(viewModel: viewModel)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
