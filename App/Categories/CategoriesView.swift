// App/Categories/CategoriesView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import GRDB

@MainActor
final class CategoriesViewModel: ObservableObject {
    @Published var categories: [Category] = []
    @Published var groups: [CategoryGroup] = []
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func load() throws {
        categories = try dbQueue.read { db in try Category.filter(Column("isReserved") == false).fetchAll(db) }
        groups = try dbQueue.read { db in try CategoryGroup.fetchAll(db) }
    }

    func createGroup(name: String) throws {
        guard !name.isEmpty else { return }
        var group = CategoryGroup(name: name)
        try dbQueue.write { db in try group.insert(db) }
        try load()
    }

    func assignCategory(_ category: Category, toGroupId groupId: Int64?) throws {
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        var updated = categories[index]
        updated.groupId = groupId
        try dbQueue.write { db in try updated.update(db, columns: ["groupId"]) }
        categories[index] = updated
    }

    /// "Covered by a reserve": the auto-forecast leaves this category alone (and its
    /// existing auto entries are removed when turning this on).
    func setExcludedFromAutoForecast(_ category: Category, excluded: Bool) throws {
        guard let id = category.id else { return }
        try dbQueue.write { db in try ReservedCategories.setExcludedFromAutoForecast(db: db, categoryId: id, excluded) }
        try load()
    }
}

struct CategoriesView: View {
    @ObservedObject var viewModel: CategoriesViewModel
    @State private var newGroupName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("New group name", text: $newGroupName)
                    .frame(maxWidth: 240)
                Button("Add Group") {
                    guard !newGroupName.isEmpty else { return }
                    try? viewModel.createGroup(name: newGroupName)
                    newGroupName = ""
                }
            }

            List(viewModel.categories) { category in
                HStack {
                    Text(category.name)
                    Spacer()
                    if category.type == .expense {
                        Toggle("Exclude from auto-forecast", isOn: Binding(
                            get: { category.excludeFromAutoForecast },
                            set: { newValue in try? viewModel.setExcludedFromAutoForecast(category, excluded: newValue) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Stops the forecast detecting new recurring amounts for this category. Existing planned items are kept.")
                    }
                    Picker("", selection: Binding<Int64?>(
                        get: { category.groupId },
                        set: { newValue in try? viewModel.assignCategory(category, toGroupId: newValue) }
                    )) {
                        Text("None").tag(Int64?.none)
                        ForEach(viewModel.groups) { group in Text(group.name).tag(Int64?.some(group.id!)) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
        }
        .padding()
        .onAppear { try? viewModel.load() }
    }
}
