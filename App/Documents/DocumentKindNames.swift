// App/Documents/DocumentKindNames.swift
import SwiftUI
import BudgetCore
import GRDB

extension EnvironmentValues {
    /// Every document kind's name, the custom kinds included (`DocumentKindsModel`, set by ContentView):
    /// wherever a document's kind is shown, `documentKinds.displayName(of:)` names a custom kind, never "Other".
    @Entry var documentKinds = DocumentKindCatalog(customKinds: [])
}

/// The custom kinds, observed: re-read whenever one is made, renamed, merged or arrives by sync, so
/// every screen and sheet names them as they are now.
@MainActor
final class DocumentKindsModel: ObservableObject {
    @Published private(set) var customKinds: [CustomDocumentKind] = []
    private var task: Task<Void, Never>?

    var catalog: DocumentKindCatalog { DocumentKindCatalog(customKinds: customKinds) }

    init(dbQueue: DatabaseQueue) {
        let values = ValueObservation.tracking { db in try CustomDocumentKind.fetchAll(db) }
            .removeDuplicates()
            .values(in: dbQueue)
        task = Task { [weak self] in
            do {
                for try await kinds in values {
                    guard let self, !Task.isCancelled else { return }
                    self.customKinds = kinds
                }
            } catch {
                // Names fall back to the built-ins' ("Other" for a custom kind) until the next launch.
            }
        }
    }

    isolated deinit {
        task?.cancel()
    }
}
