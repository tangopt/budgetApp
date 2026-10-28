// App/Snapshots/SnapshotMode.swift
import SwiftUI
import BudgetCore

/// The UI snapshot harness (`--render-snapshots <outDir>`, run by
/// `scripts/render-snapshots.sh` against the demo database only): renders every screen, tab
/// and main sheet off-screen to PNGs so the UI can be reviewed without the app on anyone's
/// screen. See `SnapshotRunner`.
///
/// The harness is compiled only into snapshot builds (`SNAPSHOTS`, set by the script's
/// build): in the app as built normally `isActive` is always false and the runner, capture
/// and catalog don't exist.
enum SnapshotMode {
    static let argument = "--render-snapshots"

    #if SNAPSHOTS
    /// Whether this process is rendering snapshots: no network, no normal UI.
    static var isActive: Bool { CommandLine.arguments.contains(argument) }

    /// The day the app takes as today while rendering (`--as-of YYYY-MM-DD`, at noon UTC), so
    /// the screens don't drift with the calendar. The demo database's day by default.
    static let asOf: Date? = {
        let arguments = CommandLine.arguments
        let text = arguments.firstIndex(of: "--as-of").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "2026-10-15"
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // An impossible day (2026-02-30, month 13) is refused rather than rolled over.
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == parts[0], back.month == parts[1], back.day == parts[2] else { return nil }
        return date
    }()
    #else
    static let isActive = false
    static let asOf: Date? = nil
    #endif

    /// Where `@AppStorage` reads and writes while rendering, so nothing reaches the app's
    /// own preferences (removed again when the run ends).
    static let defaultsSuiteName = "com.personal.budget.snapshot-storage"
    static let defaults: UserDefaults = UserDefaults(suiteName: defaultsSuiteName) ?? .standard
}

/// The current time as the app sees it: the clock, or the snapshot harness's fixed day.
enum AppClock {
    static var now: Date { SnapshotMode.asOf ?? Date() }
}

/// What `ContentView` opens on in a snapshot, and the state to set up once its view models
/// exist (a tab, a selection, a period). Inert outside snapshot builds.
struct SnapshotSetup {
    let screen: AppScreen
    var prepare: @MainActor (SnapshotScreenModels) -> Void = { _ in }
}

/// `ContentView`'s screen view models, handed to `SnapshotSetup.prepare`.
struct SnapshotScreenModels {
    let dashboard: DashboardViewModel
    let budgetGrid: BudgetGridViewModel
    let scenarioLab: ScenarioLabViewModel
    let salary: SalaryComparisonViewModel
    let accounts: AccountsViewModel
    let categories: CategoriesViewModel
    let search: SearchViewModel
    let documents: DocumentsViewModel
    let missingEvidence: MissingEvidenceViewModel
    let property: PropertyViewModel
    let taxYears: TaxYearsViewModel
    let rules: RulesViewModel
    let uncategorized: UncategorizedViewModel
}
