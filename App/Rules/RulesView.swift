// App/Rules/RulesView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct RulesView: View {
    @ObservedObject var viewModel: RulesViewModel

    var body: some View {
        Table(viewModel.rules) {
            TableColumn("Pattern") { rule in Text(rule.matchPattern) }
            TableColumn("Type") { rule in Text(rule.matchType.rawValue) }
            TableColumn("Category") { rule in
                Picker("", selection: Binding(
                    get: { rule.categoryId },
                    set: { newValue in try? viewModel.updateCategory(rule, to: newValue) }
                )) {
                    ForEach(viewModel.categories) { category in Text(category.name).tag(category.id!) }
                }
                .labelsHidden()
            }
            TableColumn("Priority") { rule in Text("\(rule.priority)") }
            TableColumn("") { rule in
                Button("Delete") { try? viewModel.delete(rule) }
            }
        }
        .padding()
    }
}
