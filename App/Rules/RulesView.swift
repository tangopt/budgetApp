// App/Rules/RulesView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct RulesView: View {
    @ObservedObject var viewModel: RulesViewModel
    @State private var searchText = ""

    /// `viewModel.rules` filtered by a case-insensitive substring match against
    /// `matchPattern`. An empty `searchText` (the default) matches everything, so
    /// existing behavior is unchanged until the user actually types.
    private var filteredRules: [Rule] {
        guard !searchText.isEmpty else { return viewModel.rules }
        return viewModel.rules.filter { $0.matchPattern.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Table(filteredRules) {
            TableColumn("Pattern") { rule in Text(rule.matchPattern) }
            TableColumn("Type") { rule in Text(rule.matchType.rawValue) }
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
        .padding()
        .searchable(text: $searchText, prompt: "Search patterns")
    }
}
