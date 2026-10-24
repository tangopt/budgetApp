#if SNAPSHOTS
// The phone's snapshot harness (iPhone spec §6; plan step 4, Task 6). Compiled only into a snapshot build
// (`SWIFT_ACTIVE_COMPILATION_CONDITIONS` += `SNAPSHOTS`, scripts/render-phone-snapshots.sh), which runs nothing
// else: no lock (plan Global Constraints: snapshot builds skip it), no sync, no network, never the phone's database.
//
// Ruling (BudgetDemo in the app): XcodeGen can't vary a target's dependencies by build setting, so `MangoPhone`
// links the `BudgetDemo` library in every build, and only this file imports it, under `#if SNAPSHOTS`. A release
// build carries the unused library and never calls it.
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
/// at each of the route's Dynamic Type sizes, to `Documents/snapshots/<route>-<appearance>-<size>.png`, with the
/// wrap probe's `wrap-report.txt`; then exits. A failure writes `Documents/snapshots/error.txt` and exits 1.
@MainActor
enum PhoneSnapshotRunner {
    static let windowSize = CGSize(width: 393, height: 852)
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

        let probe = WrapProbeRegistry.shared
        probe.isActive = true
        var violations: [WrapProbeRegistry.Violation] = []
        var renders: [(name: String, checked: Int)] = []
        for route in routes {
            for appearance in appearances {
                for size in route.sizes {
                    let name = "\(route.name)-\(appearance.name)-\(String(describing: size))"
                    probe.reset()
                    window.overrideUserInterfaceStyle = appearance.style
                    let root = route.make(context)
                        .environment(\.dynamicTypeSize, size)
                        .environment(\.phoneTheme, .classic)
                    window.rootViewController = UIHostingController(rootView: root)
                    window.layoutIfNeeded()
                    await settle(probe)
                    violations += probe.violations(route: name, window: windowSize)
                    renders.append((name, probe.checkedCount))
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    guard let png = image.pngData() else { fail("couldn't encode \(name).png") }
                    do {
                        try png.write(to: outDir.appendingPathComponent("\(name).png"))
                    } catch {
                        fail("couldn't write \(name).png: \(error.localizedDescription)")
                    }
                    window.rootViewController = nil
                }
            }
        }
        probe.isActive = false
        let report = WrapProbeRegistry.report(violations, renders: renders, window: windowSize)
        do {
            try report.write(to: outDir.appendingPathComponent("wrap-report.txt"), atomically: true, encoding: .utf8)
        } catch {
            fail("couldn't write wrap-report.txt: \(error.localizedDescription)")
        }
        print(report.split(separator: "\n").prefix(2).joined(separator: "\n"))
        exit(0)
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
