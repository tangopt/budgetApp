// App/Snapshots/SnapshotRunner.swift
import SwiftUI
import AppKit
import BudgetCore
import GRDB

#if SNAPSHOTS
/// `Budget --render-snapshots <outDir> [--only a,b] [--themes classic,midnight] [--appearances light,dark]
///  [--scale 1] [--settle 1.6] [--as-of YYYY-MM-DD] [--size 1440x900]`
///
/// Renders every route of `SnapshotCatalog` (each sidebar screen and tab, the main sheets) in an
/// off-screen window, in each appearance and theme, to
/// `<outDir>/<screen>-<tab>-<appearance>-<theme>.png` plus `index.html`, then exits. It opens
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
            fail("usage: --render-snapshots <outDir> [--only a,b] [--themes ids] [--appearances light,dark] [--scale n] [--as-of YYYY-MM-DD] [--size WxH]", code: 2)
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
            case "--themes": options.themes = list(value)
            case "--appearances": options.appearances = list(value).filter { ["light", "dark"].contains($0) }
            case "--scale": options.scale = CGFloat(Double(value) ?? 1)
            case "--settle": options.settle = Double(value) ?? options.settle
            case "--as-of":
                guard SnapshotMode.asOf != nil else { fail("--as-of takes YYYY-MM-DD", code: 2) }
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

    init(options: SnapshotRunner.Options) {
        self.options = options
    }

    func run() async throws {
        try FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)
        let environment = try await AppEnvironment.load()
        let context = SnapshotContext(environment: environment, settleSeconds: options.settle)
        let themes = options.themes.map(Theme.named)
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
            window = SnapshotWindow.make()
            window.setAppearance(options.appearances.first == "dark" ? .darkAqua : .aqua)
            hostState.theme = themes.first ?? .classic
            window.mount(SnapshotHost(state: hostState, content: content))
            await context.settle(route.settleFactor)
            // A warm-up pass: some views (chart axes) finish laying out on their second display.
            _ = SnapshotCapture.png(of: window, scale: 1)
            await context.settle(0.2)
            var files: [String] = []
            for appearance in options.appearances {
                window.setAppearance(appearance == "dark" ? .darkAqua : .aqua)
                for theme in themes {
                    hostState.theme = theme
                    await context.settle(0.25)
                    let name = "\(route.name)-\(appearance)-\(theme.id).png"
                    if let data = SnapshotCapture.png(of: window, scale: options.scale) {
                        try data.write(to: options.outDir.appendingPathComponent(name))
                        files.append(name)
                    } else {
                        print("  \(name): capture failed")
                    }
                }
            }
            window.unmount()
            window.orderOut(nil)
            window.close()
            written.append((route, files))
            print(String(format: "  %@ (%.1fs)", route.name, Date().timeIntervalSince(started)))
        }
        try SnapshotIndex.html(written.map { ($0.route.name, $0.route.title, $0.files) }, appearances: options.appearances,
                               themes: themes.map(\.id))
            .write(to: options.outDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        print("Wrote \(written.reduce(0) { $0 + $1.files.count }) PNGs and index.html")
    }
}

/// The theme the routes draw with, changed between captures without rebuilding the view.
@MainActor
final class SnapshotHostState: ObservableObject {
    @Published var theme: Theme = .classic
}

/// A route's view with the theme (as `ThemedRoot` would inject it) and the harness's own
/// defaults store.
struct SnapshotHost: View {
    @ObservedObject var state: SnapshotHostState
    let content: AnyView

    var body: some View {
        content
            .environment(\.theme, state.theme)
            .tint(state.theme.usesSystemAccent ? nil : state.theme.accent)
            .defaultAppStorage(SnapshotMode.defaults)
            .frame(width: SnapshotWindow.size.width, height: SnapshotWindow.size.height)
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
