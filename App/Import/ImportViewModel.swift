// App/Import/ImportViewModel.swift
import Foundation
import BudgetCore
import GRDB

struct ReviewRow: Identifiable {
    let staged: StagedTransaction
    var chosenCategoryId: Int64?
    var id: UUID { staged.id }
}

@MainActor
final class ImportViewModel: ObservableObject {
    @Published var stagedRows: [ReviewRow] = []
    @Published var duplicateCount: Int = 0
    @Published var errorMessage: String?

    private let dbQueue: DatabaseQueue
    private let coordinator: ImportCoordinator
    private let profileStore: ImportProfileStore
    private var lastSourceFileName: String = ""
    private var lastAccountId: Int64 = 0

    init(dbQueue: DatabaseQueue, coordinator: ImportCoordinator, profileStore: ImportProfileStore) {
        self.dbQueue = dbQueue
        self.coordinator = coordinator
        self.profileStore = profileStore
    }

    func stageCSV(fileURL: URL, account: Account) async {
        do {
            let csvText = try String(contentsOf: fileURL, encoding: .utf8)
            guard let profile = try profileStore.find(accountId: account.id!, format: .csv) else {
                errorMessage = "No column mapping saved for this account yet. Run the mapping wizard first."
                return
            }
            lastSourceFileName = fileURL.lastPathComponent
            lastAccountId = account.id!
            let result = try await coordinator.stageCSVImport(csvText: csvText, profile: profile, accountId: account.id!)
            stagedRows = result.staged.map { ReviewRow(staged: $0, chosenCategoryId: $0.suggestedCategoryId) }
            duplicateCount = result.duplicateCount
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func commit() throws {
        let decisions = stagedRows.map { ImportDecision(stagedId: $0.staged.id, finalCategoryId: $0.chosenCategoryId) }
        try coordinator.commit(accountId: lastAccountId, sourceFileName: lastSourceFileName, staged: stagedRows.map(\.staged), decisions: decisions)
        stagedRows = []
    }
}
