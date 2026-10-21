import Foundation
import GRDB

/// The document importer run over a copy of a database, for checking it on real data before a
/// merge (the `ImportDryRun` tool): the source database is opened read-only and copied to a
/// temporary folder, only the copy is opened (and migrated) after that, the evidence library is
/// an empty temporary folder, and the plan is only worked out — nothing is applied. The files
/// are only read. Everything temporary is deleted before it returns.
///
/// The report: the filed or paid figures that re-running the follow-on matching would change
/// (the guard's baseline against the figures as stored), how long each planning phase took,
/// how many items each section holds, and each Needs-you item's title with its first reason —
/// nothing the review wouldn't show.
public enum ImportDryRun {
    public struct Report: Sendable {
        /// The matching drift on filed or paid returns.
        public var drift: [FiledYearImpact]
        /// Items per section.
        public var sections: [ImportSection: Int]
        /// Each Needs-you item: `"<title>: <first reason>"`.
        public var needsYou: [String]
        /// The report as printed.
        public var text: String
    }

    /// Section titles as the review shows them.
    static let sectionTitles: [(ImportSection, String)] = [
        (.needsYou, "Needs you"), (.ready, "Ready"), (.duplicates, "Duplicates skipped"), (.leftOut, "Left out"),
    ]

    public static func run(databasePath: String, files: [URL]) async throws -> Report {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("ImportDryRun-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        let copyPath = folder.appendingPathComponent("copy.sqlite").path
        let copyStart = Date()
        do {
            var readOnly = Configuration()
            readOnly.readonly = true
            let source = try DatabaseQueue(path: databasePath, configuration: readOnly)
            let target = try DatabaseQueue(path: copyPath)
            try source.backup(to: target)
            try source.close()
            try target.close()
        }
        let copied = Date().timeIntervalSince(copyStart)
        let manager = try DatabaseManager(path: copyPath)
        try manager.migrate()
        let queue = manager.dbQueue

        let driftStart = Date()
        let drift = try await queue.write { db in try FiledYearGuard.matchingDrift(db: db) }
        let drifted = Date().timeIntervalSince(driftStart)

        let library = EvidenceLibrary(root: folder.appendingPathComponent("Library", isDirectory: true), database: queue)
        let pipeline = ImportPipeline(dbQueue: queue, library: library,
                                      categorizationService: CategorizationService(categorizer: NoSuggestions()))
        let timings = ImportPlanTimings()
        let planStart = Date()
        let plan = try await pipeline.plan(files, timings: timings)
        let planned = Date().timeIntervalSince(planStart)
        pipeline.discardPlanningCopy()

        var sections: [ImportSection: Int] = [:]
        for item in plan.items { sections[item.section, default: 0] += 1 }
        let needsYou = plan.items(in: .needsYou).map { item in
            item.needsYouReasons.first.map { "\(item.title): \($0)" } ?? item.title
        }

        func seconds(_ interval: TimeInterval) -> String { String(format: "%.2f s", interval) }
        var out = "Import dry run (a copy: nothing written) · \(files.count) path\(files.count == 1 ? "" : "s") handed in\n\n"
        out += "== Baseline drift (re-running matching would change these filed or paid figures) ==\n"
        if drift.isEmpty { out += "  none\n" }
        for impact in drift {
            out += "  \(impact.headline)\n"
            for line in impact.explanation { out += "    \(line)\n" }
        }
        out += "\n== Timings ==\n"
        out += "  copy of the database   \(seconds(copied))\n"
        out += "  baseline drift         \(seconds(drifted))\n"
        let phases: [(ImportPlanTimings.Phase, String)] = [
            (.copy, "planning copy"), (.load, "load (summed)"), (.detect, "detect (summed)"), (.prepare, "prepare (summed)"),
            (.stage, "stage statements"), (.readers, "readers"), (.duplicates, "duplicates"), (.guardCheck, "filed-year guard"),
        ]
        for (phase, name) in phases {
            out += "  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(seconds(timings.total(phase)))\n"
        }
        out += "  plan (wall clock)      \(seconds(planned))\n"
        out += "\n== Sections ==\n"
        for (section, title) in sectionTitles { out += "  \(title): \(sections[section] ?? 0)\n" }
        if !plan.ignoredFiles.isEmpty { out += "  Ignored files: \(plan.ignoredFiles.count)\n" }
        out += "\n== Needs you ==\n"
        if needsYou.isEmpty { out += "  none\n" }
        for line in needsYou { out += "  \(line)\n" }
        return Report(drift: drift, sections: sections, needsYou: needsYou, text: out)
    }

    /// No category suggestions (statements are staged with saved rules only anyway).
    struct NoSuggestions: Categorizing {
        func suggestCategory(description: String, candidateCategoryNames: [String]) async throws -> CategorySuggestion? { nil }
        func suggestCategories(descriptions: [String], candidateCategoryNames: [String]) async throws -> [CategorySuggestion?] {
            descriptions.map { _ in nil }
        }
    }
}
