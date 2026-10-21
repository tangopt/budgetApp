// App/Snapshots/SnapshotRunner.swift
import SwiftUI
import AppKit
import BudgetCore
import GRDB

#if SNAPSHOTS
/// `Budget --render-snapshots <outDir> [--only a,b] [--themes classic,midnight] [--appearances light,dark]
///  [--looks light-classic,dark-midnight] [--scale 1] [--settle 1.6] [--as-of YYYY-MM-DD] [--size 1440x900]`
///
/// Renders every route of `SnapshotCatalog` (each sidebar screen and tab, the main sheets) in an
/// off-screen window, in each appearance and theme, to
/// `<outDir>/<screen>-<tab>-<appearance>-<theme>.png` plus `index.html` and the wrap probe's
/// `wrap-report.txt` (`WrapProbe`: figures that wrap, truncate or are cut off), then exits. It opens
/// only a demo database: `BUDGET_DB_PATH` must be an absolute path to an existing file outside
/// the app's data folders that carries the demo id (`DemoMarker`). It never shows a window,
/// takes focus, appears in the Dock or touches the network.
enum SnapshotRunner {
    struct Options {
        var outDir: URL
        var only: [String] = []
        var themes: [String] = ["classic", "midnight", "sunset"]
        var appearances: [String] = ["light", "dark"]
        var scale: CGFloat = 1
        /// Seconds a route gets to load before its first capture.
        var settle: Double = 1.6
        var size = NSSize(width: 1440, height: 900)
        /// Appearance–theme pairs to capture instead of every appearance in every theme
        /// (`--looks light-classic,dark-midnight`).
        var looks: [(appearance: String, theme: String)]?
        /// A timing run instead of the routes (`--perf tenancies`: `PanelTiming`).
        var perf: String?
    }

    @MainActor
    static func main() -> Never {
        let options = parseOptions()
        let dbPath = checkedDatabasePath()
        // The one path the app opens from here on: the checked, resolved one.
        setenv("BUDGET_DB_PATH", dbPath, 1)
        SnapshotWindow.size = options.size
        let app = SnapshotApplication.shared
        // No Dock icon, no menu bar, never frontmost.
        app.setActivationPolicy(.prohibited)
        let delegate = Delegate(options: options)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("render-snapshots: \(message)\n".utf8))
        exit(code)
    }

    /// `BUDGET_DB_PATH`, resolved once and checked: an absolute file path (never a `file:`
    /// URI, which SQLite would read with its own rules), an existing file outside the app's
    /// data folders whose evidence folder is outside them too, and a demo database.
    static func checkedDatabasePath() -> String {
        guard let raw = ProcessInfo.processInfo.environment["BUDGET_DB_PATH"], !raw.isEmpty else {
            fail("BUDGET_DB_PATH must point at a demo database (scripts/render-snapshots.sh builds one).", code: 2)
        }
        guard raw.hasPrefix("/"), !raw.lowercased().hasPrefix("file:") else {
            fail("BUDGET_DB_PATH must be an absolute file path, not \(raw)", code: 2)
        }
        let resolved = TaxRegression.resolvedPath(raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
            fail("no database file at \(resolved)", code: 2)
        }
        let evidence = (((resolved as NSString).deletingLastPathComponent) as NSString).appendingPathComponent("Evidence")
        if TaxRegression.isAppData(resolved) || TaxRegression.isAppData(evidence) {
            fail("refusing to render from the app's own data folder: \(resolved)", code: 2)
        }
        guard DemoMarker.isDemoDatabase(atPath: resolved) else {
            fail("\(resolved) isn't a demo database (MakeDemoDatabase builds one)", code: 2)
        }
        return resolved
    }

    static func parseOptions() -> Options {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let index = arguments.firstIndex(of: SnapshotMode.argument), index + 1 < arguments.count else {
            fail("usage: --render-snapshots <outDir> [--only a,b] [--themes ids] [--appearances light,dark] [--looks light-classic,dark-midnight] [--scale n] [--as-of YYYY-MM-DD] [--size WxH]", code: 2)
        }
        let outPath = arguments[index + 1]
        guard outPath.hasPrefix("/") else { fail("the output folder must be an absolute path", code: 2) }
        var options = Options(outDir: URL(fileURLWithPath: TaxRegression.resolvedPath(outPath), isDirectory: true))
        arguments.removeSubrange(index...(index + 1))
        func list(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            guard argument.hasPrefix("--") else { continue }  // e.g. -NSDocumentRevisionsDebugMode YES
            guard !arguments.isEmpty else { fail("\(argument) needs a value", code: 2) }
            let value = arguments.removeFirst()
            switch argument {
            case "--only": options.only = list(value)
            case "--perf":
                guard value == "tenancies" else { fail("--perf takes tenancies", code: 2) }
                options.perf = value
            case "--themes": options.themes = list(value)
            case "--appearances": options.appearances = list(value).filter { ["light", "dark"].contains($0) }
            case "--scale": options.scale = CGFloat(Double(value) ?? 1)
            case "--settle": options.settle = Double(value) ?? options.settle
            case "--as-of":
                guard SnapshotMode.asOf != nil else { fail("--as-of takes YYYY-MM-DD", code: 2) }
            case "--looks":
                let pairs = list(value).map { $0.split(separator: "-", maxSplits: 1).map(String.init) }
                guard !pairs.isEmpty, pairs.allSatisfy({ $0.count == 2 && ["light", "dark"].contains($0[0]) }) else {
                    fail("--looks takes appearance-theme pairs, e.g. light-classic,dark-midnight", code: 2)
                }
                options.looks = pairs.map { ($0[0], $0[1]) }
                options.appearances = Array(Set(pairs.map { $0[0] })).sorted { $0 == "light" && $1 != "light" }
                options.themes = pairs.map { $0[1] }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            case "--size":
                let parts = value.lowercased().split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts[0] >= 800, parts[1] >= 500 else { fail("--size takes WxH, at least 800x500", code: 2) }
                options.size = NSSize(width: parts[0], height: parts[1])
            default: fail("unknown option \(argument)", code: 2)
            }
        }
        if TaxRegression.isAppData(options.outDir.path) { fail("refusing to write into the app's data folder", code: 2) }
        let known = Set(Theme.all.map(\.id))
        if let unknown = options.themes.first(where: { !known.contains($0) }) {
            fail("unknown theme \(unknown) (one of \(Theme.all.map(\.id).joined(separator: ", ")))", code: 2)
        }
        if options.appearances.isEmpty { fail("--appearances takes light and/or dark", code: 2) }
        return options
    }

    // MARK: Running

    final class Delegate: NSObject, NSApplicationDelegate {
        let options: Options
        init(options: Options) { self.options = options }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                let code: Int32
                do {
                    try await SnapshotSession(options: options).run()
                    code = 0
                } catch {
                    FileHandle.standardError.write(Data("render-snapshots: \(error)\n".utf8))
                    code = 1
                }
                SnapshotMode.defaults.removePersistentDomain(forName: SnapshotMode.defaultsSuiteName)
                exit(code)
            }
        }
    }
}

/// Reports itself active so controls draw as in a frontmost app (accent-coloured selections
/// and default buttons); it never actually activates.
final class SnapshotApplication: NSApplication {
    override var isActive: Bool { true }
}

/// What the routes read: the opened environment and the demo's records.
@MainActor
struct SnapshotContext {
    let environment: AppEnvironment
    var dbQueue: DatabaseQueue { environment.dbQueue }
    var library: EvidenceLibrary { environment.evidenceLibrary }
    let settleSeconds: Double

    /// Lets loads and observations finish.
    func settle(_ factor: Double = 1) async {
        try? await Task.sleep(for: .seconds(settleSeconds * factor))
    }
}

/// One run: opens the database the normal way, then renders each route in turn.
@MainActor
final class SnapshotSession {
    let options: SnapshotRunner.Options
    let hostState = SnapshotHostState()
    private var window: SnapshotWindow!
    private var written: [(route: SnapshotRoute, files: [String])] = []
    /// The wrap probe's findings (`WrapProbe`), and each route's content minimum.
    private var violations: [WrapProbe.Violation] = []
    private var minimums: [(name: String, minimum: CGSize, rendered: CGSize, checked: Int)] = []

    init(options: SnapshotRunner.Options) {
        self.options = options
    }

    func run() async throws {
        // The routes' temporary folders (the demo source folder) go when the run ends.
        defer { SnapshotCatalog.removeTemporaryFolders() }
        try FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)
        let environment = try await AppEnvironment.load()
        let context = SnapshotContext(environment: environment, settleSeconds: options.settle)
        if options.perf != nil {
            try await PanelTiming.run(context: context, options: options, hostState: hostState)
            return
        }
        let themes = options.themes.map(Theme.named)
        // Each appearance in each theme, or just the pairs `--looks` names.
        let looks: [(String, Theme)] = options.looks.map { $0.map { ($0.appearance, Theme.named($0.theme)) } }
            ?? options.appearances.flatMap { appearance in themes.map { (appearance, $0) } }
        let routes = SnapshotCatalog.routes.filter { route in
            options.only.isEmpty || options.only.contains { route.name.contains($0) }
        }
        print("Rendering \(routes.count) routes × \(options.appearances.count) appearances × \(themes.count) themes to \(options.outDir.path)")
        for route in routes {
            let started = Date()
            let content: AnyView
            do {
                content = try await route.makeView(context)
            } catch {
                print("  \(route.name): skipped — \(error)")
                continue
            }
            // A fresh window per route, so no toolbar or title state carries over.
            WrapProbe.shared.reset()
            window = SnapshotWindow.make()
            window.setAppearance(looks.first?.0 == "dark" ? .darkAqua : .aqua)
            hostState.theme = looks.first?.1 ?? .classic
            window.mount(SnapshotHost(state: hostState, content: content))
            await context.settle(route.settleFactor)
            // A warm-up pass: some views (chart axes) finish laying out on their second display.
            _ = SnapshotCapture.png(of: window, scale: 1)
            await context.settle(0.2)
            var files: [String] = []
            var found = Set<WrapProbe.Violation>()
            var shownAppearance: String?
            var checked = 0
            for (appearance, theme) in looks {
                if appearance != shownAppearance {
                    window.setAppearance(appearance == "dark" ? .darkAqua : .aqua)
                    shownAppearance = appearance
                }
                hostState.theme = theme
                await context.settle(0.25)
                let name = "\(route.name)-\(appearance)-\(theme.id).png"
                if let data = SnapshotCapture.png(of: window, scale: options.scale) {
                    try data.write(to: options.outDir.appendingPathComponent(name))
                    files.append(name)
                } else {
                    print("  \(name): capture failed")
                }
                // What the capture showed (it laid the window out).
                found.formUnion(WrapProbe.shared.violations(route: route.name, window: window.contentLayoutSize))
                checked = max(checked, WrapProbe.shared.checkedCount)
            }
            violations += found
            minimums.append((route.name, window.contentMinSize, window.contentLayoutSize, checked))
            window.unmount()
            window.orderOut(nil)
            window.close()
            written.append((route, files))
            print(String(format: "  %@ (%.1fs)", route.name, Date().timeIntervalSince(started)) + (found.isEmpty ? "" : " — \(found.count) wrap probe violation\(found.count == 1 ? "" : "s")"))
        }
        WrapProbe.shared.reset()
        try SnapshotIndex.html(written.map { ($0.route.name, $0.route.title, $0.files) }, appearances: options.appearances,
                               themes: themes.map(\.id))
            .write(to: options.outDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let report = WrapProbe.report(violations, routes: minimums, options: options)
        try report.write(to: options.outDir.appendingPathComponent("wrap-report.txt"), atomically: true, encoding: .utf8)
        print("Wrote \(written.reduce(0) { $0 + $1.files.count }) PNGs and index.html")
        print(report.split(separator: "\n", omittingEmptySubsequences: false).prefix(2).joined(separator: "\n") + " — wrap-report.txt")
    }
}

/// The theme the routes draw with, changed between captures without rebuilding the view.
@MainActor
final class SnapshotHostState: ObservableObject {
    @Published var theme: Theme = .classic
}

/// A route's view with the theme (as `ThemedRoot` would inject it) and the harness's own
/// defaults store. It fills the window, which (like the app's) is never smaller than the
/// view's minimum (`SnapshotWindow.mount`).
struct SnapshotHost: View {
    @ObservedObject var state: SnapshotHostState
    let content: AnyView

    var body: some View {
        content
            .environment(\.theme, state.theme)
            .tint(state.theme.usesSystemAccent ? nil : state.theme.accent)
            .defaultAppStorage(SnapshotMode.defaults)
    }
}

/// A sheet as it shows over the window: its ideal size, top-centred on a dimmed window, with
/// the sheet's background and rounded corners.
struct SnapshotSheetCanvas<Sheet: View>: View {
    let sheet: Sheet
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .top) {
            theme.windowFill
            Color.black.opacity(0.18)
            sheet
                .fixedSize()
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
                .padding(.top, 52)
        }
    }
}

/// A window of its own (Settings): its ideal size, top-left on the window colour.
struct SnapshotStandaloneCanvas<Content: View>: View {
    let content: Content
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            content.fixedSize()
        }
    }
}
#endif
