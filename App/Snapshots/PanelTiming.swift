// App/Snapshots/PanelTiming.swift
#if SNAPSHOTS
import SwiftUI
import AppKit
import BudgetCore
import GRDB

/// `--perf tenancies` (scripts/render-snapshots.sh `--perf tenancies`, which builds the demo
/// with "Tenancy L": 62 receipts, each with its PDF and credit): times the Tenancies tab's
/// receipt panel in the off-screen window instead of rendering routes, and writes
/// `<outDir>/perf-report.txt`.
///
/// The wrap probe is off (the app has none). Each step changes the page's state, then times
/// two things on the main thread:
/// - first frame: the change plus the window's layout and display that show it;
/// - blocked: for 1.2 s after, the main thread's stalls longer than 8 ms (animations, the
///   scroll to the open row, loads) — what makes clicking feel laggy — and the longest one.
@MainActor
enum PanelTiming {
    struct Sample {
        var firstFrame: Double
        var blocked: Double
        var longest: Double
    }

    static func run(context: SnapshotContext, options: SnapshotRunner.Options, hostState: SnapshotHostState) async throws {
        let found = try await context.dbQueue.read { db -> (Int64, [Int64])? in
            guard let tenancy = try Tenancy.filter(Column("referenceLabel") == "Tenancy L").fetchOne(db)?.id else { return nil }
            let receipts = try Int64.fetchAll(db, sql: "SELECT id FROM rentReceipt WHERE tenancyId = ? ORDER BY periodStart DESC", arguments: [tenancy])
            return (tenancy, receipts)
        }
        guard let (tenancy, receipts) = found, receipts.count >= 10 else {
            throw SnapshotMissing("Tenancy L (build the demo with --long-tenancy)")
        }
        // Timed as the app runs: without the wrap probe's readers on every figure.
        WrapProbe.isEnabled = false
        var property: PropertyViewModel?
        let content = AnyView(ContentView(environment: context.environment, snapshotSetup: SnapshotSetup(screen: .property, prepare: { models in
            models.property.tab = .tenancies
            models.property.selectedTenancyId = tenancy
            property = models.property
        })))
        let window = SnapshotWindow.make()
        window.setAppearance(.aqua)
        hostState.theme = .classic
        window.mount(SnapshotHost(state: hostState, content: content))
        await context.settle(2)
        guard let model = property else { throw SnapshotMissing("the property page") }
        _ = SnapshotCapture.png(of: window, scale: 1)
        await context.settle(0.3)

        var lines = ["Receipt panel timing — Tenancy L, \(receipts.count) receipts with PDFs, window \(Int(options.size.width))×\(Int(options.size.height))",
                     "first frame: the change, layout and display (ms); blocked: main-thread stalls > 8 ms in the 1.2 s after (ms); longest stall (ms)",
                     ""]
        func report(_ title: String, _ samples: [Sample]) {
            func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
            lines.append(String(format: "%@ (n=%d): first frame median %.0f max %.0f · blocked median %.0f max %.0f · longest stall max %.0f",
                                title, samples.count, median(samples.map(\.firstFrame)), samples.map(\.firstFrame).max()!,
                                median(samples.map(\.blocked)), samples.map(\.blocked).max()!, samples.map(\.longest).max()!))
            for sample in samples {
                lines.append(String(format: "    %.0f / %.0f / %.0f", sample.firstFrame, sample.blocked, sample.longest))
            }
        }

        // A change the tab doesn't show (the loan chart's range): what any change of the page's
        // model costs.
        var controls: [Sample] = []
        for range in [PropertyViewModel.LoanRange.fiveYears, .soFar, .fiveYears, .soFar] {
            controls.append(await measure(window) { model.loanRange = range })
        }
        report("Control: an unrelated change", controls)
        // Opening and closing the panel on the newest receipt (from the table).
        var opens: [Sample] = [], closes: [Sample] = []
        for _ in 0..<4 {
            opens.append(await measure(window) { model.toggleSidePanel(.receipt(id: receipts[0], tenancyId: tenancy)) })
            closes.append(await measure(window) { model.sidePanel = nil })
        }
        // Switching the open receipt: clicking other rows with the panel open, across the years.
        model.sidePanel = .receipt(id: receipts[0], tenancyId: tenancy)
        await context.settle(0.8)
        var switches: [Sample] = []
        for index in [1, 2, 13, 14, 30, 31, 50, 51, 5, 6] where index < receipts.count {
            switches.append(await measure(window) { model.toggleSidePanel(.receipt(id: receipts[index], tenancyId: tenancy)) })
        }
        if let data = SnapshotCapture.png(of: window, scale: 1) {
            try data.write(to: options.outDir.appendingPathComponent("perf-tenancies-receipt.png"))
        }
        report("Open the panel", opens)
        report("Close the panel", closes)
        report("Switch receipt", switches)
        window.unmount()
        window.orderOut(nil)
        window.close()
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: options.outDir.appendingPathComponent("perf-report.txt"), atomically: true, encoding: .utf8)
        print(text)
    }

    private static func measure(_ window: NSWindow, _ change: () -> Void) async -> Sample {
        let start = CACurrentMediaTime()
        change()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let firstFrame = (CACurrentMediaTime() - start) * 1000
        var blocked = 0.0, longest = 0.0
        let watchUntil = CACurrentMediaTime() + 1.2
        var last = CACurrentMediaTime()
        while last < watchUntil {
            try? await Task.sleep(for: .milliseconds(2))
            let now = CACurrentMediaTime()
            let stall = (now - last) * 1000 - 2
            if stall > 8 {
                blocked += stall
                longest = max(longest, stall)
            }
            last = now
        }
        return Sample(firstFrame: firstFrame, blocked: blocked, longest: longest)
    }
}
#endif
