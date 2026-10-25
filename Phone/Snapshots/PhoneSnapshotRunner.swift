#if SNAPSHOTS
// The phone's snapshot harness (iPhone spec §6; plan step 4, Task 6). Compiled only into a snapshot build
// (`SWIFT_ACTIVE_COMPILATION_CONDITIONS` += `SNAPSHOTS`, scripts/render-phone-snapshots.sh), which runs nothing
// else: no lock (plan Global Constraints: snapshot builds skip it), no sync, no network, never the phone's database.
//
// BudgetDemo is part of every build of the app: "Try with demo data" (Phone/Demo/PhoneDemoData.swift) builds the
// demo database on the phone too, into its own folder (Caches/Mango-Demo).
import SwiftUI
import UIKit
import BudgetCore
import BudgetDemo
import GRDB
import MangoUI

/// `Mango --render-snapshots [--only gallery,home]`
///
/// Builds the demo database in-process (`DemoDatabase`, in the app's temporary folder, never Application Support),
/// opens it read-only, and renders each route of `DemoRoutes.all` in a 393×852 window (iPhone 17), light and dark,
/// at each of the route's Dynamic Type sizes, to `Documents/snapshots/<route>-<appearance>-<size>.png`; then again
/// at 393×4000 so the probe measures everything below the fold (`…-full.png`, light only, cropped to the content);
/// with the wrap probe's `wrap-report.txt`; then exits. A failure, including a render that measured fewer figures
/// than its route requires (`DemoRoute.coverageProblem`), writes `Documents/snapshots/error.txt` and exits 1.
@MainActor
enum PhoneSnapshotRunner {
    static let windowSize = CGSize(width: 393, height: 852)
    /// The full-height pass: the same width, tall enough that a screen's whole content is laid out.
    static let fullSize = CGSize(width: 393, height: 4000)
    /// How far the full pass grows for taller content.
    static let maximumFullHeight: CGFloat = 12_000
    static let appearances: [(name: String, style: UIUserInterfaceStyle)] = [("light", .light), ("dark", .dark)]

    static func main() -> Never {
        guard CommandLine.arguments.contains("--render-snapshots") else {
            FileHandle.standardError.write(Data("This is a snapshot build of Mango for iPhone: it only runs the snapshot harness (--render-snapshots).\n".utf8))
            exit(2)
        }
        PhoneSnapshotApp.main()
        exit(0)
    }

    static var outDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("snapshots", isDirectory: true)
    }

    static func fail(_ message: String) -> Never {
        try? Data("render-phone-snapshots: \(message)\n".utf8).write(to: outDir.appendingPathComponent("error.txt"))
        FileHandle.standardError.write(Data("render-phone-snapshots: \(message)\n".utf8))
        exit(1)
    }

    /// `--only a,b`: just those routes (by name).
    static var only: Set<String> {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--only"), index + 1 < arguments.count else { return [] }
        return Set(arguments[index + 1].split(separator: ",").map(String.init))
    }

    static func run() async {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outDir)
        do {
            try fileManager.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            fail("couldn't create \(outDir.path): \(error.localizedDescription)")
        }

        // The demo database, in the temporary folder: never the phone's own (Application Support/Mango).
        let demoFolder = fileManager.temporaryDirectory.appendingPathComponent("snapshot-demo-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: demoFolder) }
        let context: PhoneDemoContext
        do {
            try fileManager.createDirectory(at: demoFolder, withIntermediateDirectories: true)
            let path = demoFolder.appendingPathComponent("demo.sqlite").path
            try DemoDatabase.build(at: path, evidenceRoot: demoFolder.appendingPathComponent("Evidence", isDirectory: true))
            guard DemoMarker.isDemoDatabase(atPath: path) else { fail("the database built isn't a demo database") }
            var configuration = Configuration()
            configuration.readonly = true
            let dbQueue = try DatabaseQueue(path: path, configuration: configuration)
            let today = DemoDatabase.defaultAsOf
            context = PhoneDemoContext(dbQueue: dbQueue, today: today, syncStatus: .idle(lastSync: today))
        } catch {
            fail("couldn't build the demo database: \(error.localizedDescription)")
        }

        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            fail("no window scene")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: windowSize)
        window.windowLevel = .normal + 1
        window.isHidden = false

        let only = only
        let routes = DemoRoutes.all.filter { only.isEmpty || only.contains($0.name) }
        if !only.isEmpty, routes.count != only.count {
            let known = Set(DemoRoutes.all.map(\.name))
            fail("no route named \(only.subtracting(known).sorted().joined(separator: ", ")) (routes: \(DemoRoutes.all.map(\.name).joined(separator: ", ")))")
        }

        // Each route's assertion about its figures, before anything renders: a failure ends the run.
        var checks: [String] = []
        for route in routes {
            guard let check = route.check else { continue }
            do {
                checks.append(try check(context))
            } catch {
                fail("check failed: \(error)")
            }
        }

        let probe = WrapProbeRegistry.shared
        probe.isActive = true
        var violations: [WrapProbeRegistry.Violation] = []
        var renders: [WrapProbeRegistry.Render] = []
        var problems: [String] = []
        // Two passes: the first screen as the person sees it (393×852), then the same width at full height
        // (393×4000) so everything below the fold is laid out and measured too; its PNGs, light only, are cropped
        // to the content.
        for full in [false, true] {
            for route in routes {
                for appearance in appearances {
                    for size in route.sizes {
                        let name = "\(route.name)-\(appearance.name)-\(String(describing: size))" + (full ? "-full" : "")
                        probe.reset()
                        window.overrideUserInterfaceStyle = appearance.style
                        let root = route.make(context)
                            .environment(\.dynamicTypeSize, size)
                            .environment(\.phoneTheme, .classic)
                        window.frame = CGRect(origin: .zero, size: full ? fullSize : windowSize)
                        window.rootViewController = UIHostingController(rootView: root)
                        window.layoutIfNeeded()
                        await settle(probe)
                        // Content taller than the full window (the gallery at AX5): grow to it and measure again.
                        // The probe keeps its entries: figures that don't move don't report again, and any that do
                        // update theirs.
                        if full, let content = scrollContentHeight(window), content > window.bounds.height {
                            window.frame.size.height = min(content.rounded(.up), maximumFullHeight)
                            window.layoutIfNeeded()
                            await settle(probe)
                        }
                        violations += probe.violations(route: name, window: window.bounds.size)
                        let render = WrapProbeRegistry.Render(name: name, checked: probe.checkedCount,
                                                              belowFold: probe.checkedCount(below: windowSize.height))
                        renders.append(render)
                        if let problem = route.coverageProblem(render: render, full: full) { problems.append(problem) }
                        if !full || appearance.style == .light {
                            let height = full ? contentHeight(window, lowestFigure: probe.lowestFigure) : windowSize.height
                            write(window, height: height, offScreen: full, to: "\(name).png")
                        }
                        window.rootViewController = nil
                    }
                }
            }
        }
        probe.isActive = false
        if renders.reduce(0, { $0 + $1.checked }) == 0 { problems.append("the run measured no figures at all") }
        let report = WrapProbeRegistry.report(violations, renders: renders, problems: problems, window: windowSize, checks: checks)
        do {
            try report.write(to: outDir.appendingPathComponent("wrap-report.txt"), atomically: true, encoding: .utf8)
        } catch {
            fail("couldn't write wrap-report.txt: \(error.localizedDescription)")
        }
        print(report.split(separator: "\n").prefix(2).joined(separator: "\n"))
        for check in checks { print("check: \(check)") }
        // A render that measured too little is a failure, not a pass with 0 violations.
        if !problems.isEmpty { fail("coverage: " + problems.joined(separator: "; ")) }
        exit(0)
    }

    /// The full-height window's content: the tallest scroll view's content (its insets included), else just past
    /// the lowest figure; at least the first screen, at most the window.
    private static func contentHeight(_ window: UIWindow, lowestFigure: CGFloat) -> CGFloat {
        let height = scrollContentHeight(window) ?? (lowestFigure + 80)
        return min(max(height, windowSize.height), window.bounds.height).rounded(.up)
    }

    /// How tall the window's tallest scroll view's content reaches (its insets included), or nil without one.
    private static func scrollContentHeight(_ window: UIWindow) -> CGFloat? {
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        return scrollViews(window).map { scroll in
            scroll.convert(CGPoint.zero, to: window).y + scroll.adjustedContentInset.top + scroll.contentSize.height
                + scroll.adjustedContentInset.bottom
        }.max()
    }

    /// The top `height` points of the window as `<outDir>/<file>`. A window taller than the screen (`offScreen`)
    /// is drawn from its layers: the screen-capture path (`drawHierarchy`) draws nothing past the display.
    private static func write(_ window: UIWindow, height: CGFloat, offScreen: Bool, to file: String) {
        let image = UIGraphicsImageRenderer(size: CGSize(width: window.bounds.width, height: height)).image { context in
            if offScreen {
                window.layer.render(in: context.cgContext)
            } else {
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
        guard let png = image.pngData() else { fail("couldn't encode \(file)") }
        do {
            try png.write(to: outDir.appendingPathComponent(file))
        } catch {
            fail("couldn't write \(file): \(error.localizedDescription)")
        }
    }

    /// Waits for the render to lay out and its figures to report: until the count of checked figures holds still
    /// for two ticks (at least 0.6 s, at most 4 s).
    private static func settle(_ probe: WrapProbeRegistry) async {
        var last = -1
        var steady = 0
        for tick in 0..<20 {
            try? await Task.sleep(for: .milliseconds(200))
            let count = probe.checkedCount
            steady = count == last ? steady + 1 : 0
            last = count
            if tick >= 2, steady >= 2 { return }
        }
    }
}

/// The snapshot build's only scene: a blank window whose task runs the harness.
struct PhoneSnapshotApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
                .task { await PhoneSnapshotRunner.run() }
        }
    }
}
#endif
