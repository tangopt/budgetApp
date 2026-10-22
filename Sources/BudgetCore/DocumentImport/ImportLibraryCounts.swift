// Sources/BudgetCore/DocumentImport/ImportLibraryCounts.swift
import Foundation
import GRDB
import Observation

/// How many library documents a library shortcut would bring (`ImportShortcut.libraryDocumentIds`),
/// read off the main actor when asked for and older than a few seconds (or after an import
/// changed the data, `invalidate`); 0 until read. Observed by SwiftUI through Observation.
@MainActor
@Observable
public final class ImportLibraryCounts {
    public private(set) var counts: [String: Int] = [:]
    /// Bumped by `invalidate`, read by `count(for:)`: a view showing a count asks again.
    private var generation = 0
    @ObservationIgnored private var readAt: [String: Date] = [:]
    @ObservationIgnored private var reading: Set<String> = []
    @ObservationIgnored private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// The last count read for `shortcut`, a fresh read started when it is stale.
    public func count(for shortcut: ImportShortcut) -> Int {
        _ = generation
        let key = String(describing: shortcut)
        if !reading.contains(key), readAt[key].map({ Date().timeIntervalSince($0) > 5 }) ?? true {
            reading.insert(key)
            let dbQueue = dbQueue
            Task { [weak self] in
                let count = (try? await dbQueue.read { db in try shortcut.libraryDocumentIds(db: db) })?.count ?? 0
                guard let self else { return }
                self.reading.remove(key)
                self.readAt[key] = Date()
                if self.counts[key] != count { self.counts[key] = count }
            }
        }
        return counts[key] ?? 0
    }

    /// Every count read again when next asked for (an import confirmed or undone).
    public func invalidate() {
        readAt.removeAll()
        generation += 1
    }
}
