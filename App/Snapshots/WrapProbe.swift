// App/Snapshots/WrapProbe.swift
#if SNAPSHOTS
import SwiftUI
import AppKit

extension EnvironmentValues {
    /// Inside content that scrolls sideways: a figure beyond the window isn't cut off.
    @Entry var wrapProbeScrollsHorizontally = false
    /// Inside a native table or list (`wrapProbeClips`): the region its figures must stay in.
    @Entry var wrapProbeClipRegion: UUID?
    /// Inside a chart (`wrapProbeInChart`): its labels' scroll-view geometry isn't the drawn one.
    @Entry var wrapProbeIsInChart = false
    /// Inside the probe's own measuring copy, which reports nothing.
    @Entry var wrapProbeIsReference = false
}

/// The snapshot harness's check that figures stay on one line (spec §6.3): every figure view
/// (`figureText`, `MoneyText`, `DateText`, `FigureTile`, `StatusPill`) reports its rendered
/// frame and its one-line ideal size; `SnapshotSession` asks for the violations after each
/// route has laid out and writes them to `<outDir>/wrap-report.txt`.
///
/// - **wrapped**: taller than one line of its font (its ideal height).
/// - **truncated**: narrower than its ideal width, beyond what its shrink allows.
/// - **cut off**: outside the window sideways, in content that doesn't scroll sideways.
@MainActor
final class WrapProbe {
    static let shared = WrapProbe()
    /// Off while timing (`PanelTiming`): the probe's geometry readers would be timed too, and
    /// the app has none.
    nonisolated(unsafe) static var isEnabled = true

    struct Entry {
        var kind: String
        var text: String?
        var source: String?
        var minimumScale: CGFloat
        var scrollsHorizontally: Bool
        var frame: CGRect?
        var ideal: CGSize?
        /// The part of the figure its scroll view shows sideways (the figure's own coordinates):
        /// a table column pushed out of its pane is cut off without leaving the window.
        var visibleInScrollView: ClosedRange<CGFloat>?
        /// The native table or list it's in (`wrapProbeClips`).
        var clipRegion: UUID?
    }

    struct Violation: Hashable {
        enum Problem: String, CaseIterable { case wrapped, truncated, cutOff = "cut off" }
        let route: String
        let problem: Problem
        let kind: String
        let text: String
        let source: String
        let size: CGSize
        let ideal: CGSize
        let origin: CGPoint

        func hash(into hasher: inout Hasher) {
            hasher.combine(route); hasher.combine(problem); hasher.combine(kind); hasher.combine(text); hasher.combine(source)
        }

        static func == (a: Violation, b: Violation) -> Bool {
            a.route == b.route && a.problem == b.problem && a.kind == b.kind && a.text == b.text && a.source == b.source
        }
    }

    private var entries: [UUID: Entry] = [:]
    /// Native tables' and lists' frames (`wrapProbeClips`), by region.
    var clipRegions: [UUID: CGRect] = [:]

    /// How many figures on screen have reported both sizes.
    var checkedCount: Int {
        entries.values.filter { $0.frame != nil && $0.ideal != nil }.count
    }

    func reset() {
        entries = [:]
        clipRegions = [:]
    }

    func update(_ id: UUID, kind: String, text: String?, source: String?, minimumScale: CGFloat, scrolls: Bool, clipRegion: UUID? = nil,
                frame: CGRect? = nil, ideal: CGSize? = nil, visibleInScrollView: ClosedRange<CGFloat>?? = nil) {
        var entry = entries[id] ?? Entry(kind: kind, text: text, source: source, minimumScale: minimumScale, scrollsHorizontally: scrolls)
        entry.kind = kind
        entry.text = text
        entry.source = source
        entry.minimumScale = minimumScale
        entry.scrollsHorizontally = scrolls
        if let clipRegion { entry.clipRegion = clipRegion }
        if let frame { entry.frame = frame }
        if let visibleInScrollView { entry.visibleInScrollView = visibleInScrollView }
        if let ideal { entry.ideal = ideal }
        entries[id] = entry
    }

    func remove(_ id: UUID) {
        entries[id] = nil
    }

    /// The figures on screen now that break the rule.
    func violations(route: String, window: CGSize) -> [Violation] {
        var found: [Violation] = []
        for entry in entries.values {
            guard let frame = entry.frame, let ideal = entry.ideal, ideal.width > 0.5, ideal.height > 0.5,
                  frame.width > 0 || frame.height > 0 else { continue }
            func add(_ problem: Violation.Problem) {
                found.append(Violation(route: route, problem: problem, kind: entry.kind, text: entry.text ?? "?",
                                       source: entry.source ?? "", size: frame.size, ideal: ideal, origin: frame.origin))
            }
            if frame.height > ideal.height + 1 { add(.wrapped) }
            if frame.width < ideal.width * entry.minimumScale - 1 { add(.truncated) }
            if !entry.scrollsHorizontally, frame.width > 0 {
                let outsideWindow = frame.maxX > window.width + 1 || frame.minX < -1
                let outsideScrollView = entry.visibleInScrollView.map { $0.lowerBound > 1 || $0.upperBound < frame.width - 1 } ?? false
                let outsideTable = entry.clipRegion.flatMap { clipRegions[$0] }.map { frame.maxX > $0.maxX + 1 || frame.minX < $0.minX - 1 } ?? false
                if outsideWindow || outsideScrollView || outsideTable { add(.cutOff) }
            }
        }
        return found
    }

    // MARK: Naming a Text

    /// A `Text`'s words, read from its structure: the string, or a localized key with its
    /// arguments put in ("%lld sources" with 12 → "12 sources"). Best effort, for the report.
    nonisolated static func describe(_ text: Text) -> String? {
        var strings: [String] = []
        var arguments: [String] = []
        func walk(_ value: Any, depth: Int, label: String?) {
            guard depth < 12, strings.count + arguments.count < 24 else { return }
            switch value {
            case let string as String:
                if label == "key" || strings.isEmpty || label == "verbatim" { strings.append(string) } else { arguments.append(string) }
                return
            case let string as NSAttributedString: strings.append(string.string); return
            case let string as AttributedString: strings.append(String(string.characters)); return
            case let number as Int: arguments.append("\(number)"); return
            case let number as Int64: arguments.append("\(number)"); return
            case let number as Int32: arguments.append("\(number)"); return
            case let number as Double: arguments.append("\(number)"); return
            case let number as CGFloat: arguments.append("\(number)"); return
            case let number as Decimal: arguments.append("\(number)"); return
            case let date as Date: arguments.append("\(date)"); return
            case is Bool: return
            default: break
            }
            for child in Mirror(reflecting: value).children {
                walk(child.value, depth: depth + 1, label: child.label)
            }
        }
        walk(text, depth: 0, label: nil)
        guard var result = strings.first else { return arguments.isEmpty ? nil : arguments.joined(separator: " ") }
        // Put the arguments into the key's placeholders, in order.
        var remaining = arguments[...]
        while let range = result.range(of: #"%(\d+\$)?[-+ 0#]*\d*(\.\d+)?(ll|l|h)?[@dDiuUxXoOfeEgGcCsS]"#, options: .regularExpression),
              let argument = remaining.popFirst() {
            result.replaceSubrange(range, with: argument)
        }
        let rest = strings.dropFirst() + remaining
        return rest.isEmpty ? result : ([result] + rest).joined(separator: " ")
    }

    // MARK: Report

    /// `routes`: each route's window minimum (`contentMinSize`, as SwiftUI sets it from the
    /// view, the title bar included), the size it rendered at and how many figures it checked.
    nonisolated static func report(_ violations: [Violation], routes: [(name: String, minimum: CGSize, rendered: CGSize, checked: Int)],
                                   options: SnapshotRunner.Options) -> String {
        let size = "\(Int(options.size.width))×\(Int(options.size.height))"
        var lines: [String] = []
        let byProblem = Violation.Problem.allCases.map { problem in "\(problem.rawValue) \(violations.filter { $0.problem == problem }.count)" }
        let routeCount = Set(violations.map(\.route)).count
        lines.append("Wrap probe at \(size) (themes \(options.themes.joined(separator: ",")), appearances \(options.appearances.joined(separator: ",")))")
        lines.append("\(routes.count) routes, \(routes.reduce(0) { $0 + $1.checked }) figures checked; \(violations.count) violations in \(routeCount) routes (\(byProblem.joined(separator: ", ")))")
        let screens = routes.filter { !$0.name.hasPrefix("sheet-") && !$0.name.hasPrefix("gallery-") && !$0.name.hasPrefix("settings-") }
        if let widest = screens.max(by: { $0.minimum.width < $1.minimum.width }), let narrowest = screens.min(by: { $0.minimum.width < $1.minimum.width }),
           let tallest = screens.max(by: { $0.minimum.height < $1.minimum.height }) {
            lines.append("Window minimum by screen (the window grows to it, as the app's does): narrowest \(narrowest.name) \(Self.size(narrowest.minimum)), widest \(widest.name) \(Self.size(widest.minimum)), tallest \(tallest.name) \(Self.size(tallest.minimum))")
        }
        for route in routes where abs(route.rendered.width - options.size.width) > 0.5 || abs(route.rendered.height - options.size.height) > 0.5 {
            lines.append("  rendered at its minimum, not \(Self.size(options.size)): \(route.name) \(Self.size(route.rendered))")
        }
        lines.append("")
        for route in routes {
            let found = violations.filter { $0.route == route.name }
                .sorted { ($0.problem.rawValue, $0.origin.y, $0.origin.x) < ($1.problem.rawValue, $1.origin.y, $1.origin.x) }
            guard !found.isEmpty else { continue }
            lines.append("\(route.name)  (window minimum \(Self.size(route.minimum)), rendered \(Self.size(route.rendered)))")
            for violation in found {
                let text = violation.text.replacingOccurrences(of: "\n", with: " ")
                lines.append("  \(violation.problem.rawValue)  \(violation.kind)  \"\(text)\"  shown \(Self.size(violation.size)) needs \(Self.size(violation.ideal)) at \(Int(violation.origin.x)),\(Int(violation.origin.y))  \(violation.source)")
            }
        }
        // Every route's window minimum, widest first: what to look at when one outgrows a window.
        lines.append("")
        lines.append("Window minimum by route (widest first):")
        for route in routes.sorted(by: { ($0.minimum.width, $0.minimum.height) > ($1.minimum.width, $1.minimum.height) }) {
            lines.append("  \(route.name) \(Self.size(route.minimum))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated private static func size(_ size: CGSize) -> String {
        String(format: "%.0f×%.0f", size.width, size.height)
    }
}

/// Reports one figure view's frame and its ideal, one-line size to `WrapProbe`.
struct WrapProbeModifier: ViewModifier {
    let kind: String
    let text: String?
    let source: String?
    let minimumScale: CGFloat
    @Environment(\.wrapProbeIsReference) private var isReference
    @Environment(\.wrapProbeScrollsHorizontally) private var scrolls
    @Environment(\.wrapProbeIsInChart) private var inChart
    @Environment(\.wrapProbeClipRegion) private var clipRegion
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if isReference || !WrapProbe.isEnabled {
            content
        } else {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    WrapProbe.shared.update(id, kind: kind, text: text, source: source, minimumScale: minimumScale, scrolls: scrolls,
                                            clipRegion: clipRegion, frame: frame)
                }
                .onGeometryChange(for: ClosedRange<CGFloat>?.self) { proxy in
                    // The scroll view's visible part, sideways, in the figure's own coordinates.
                    inChart ? nil : proxy.bounds(of: .scrollView).map { visible in
                        let width = proxy.size.width
                        let lower = min(max(0, visible.minX), width)
                        return lower...max(lower, min(width, visible.maxX))
                    }
                } action: { visible in
                    WrapProbe.shared.update(id, kind: kind, text: text, source: source, minimumScale: minimumScale, scrolls: scrolls,
                                            visibleInScrollView: .some(visible))
                }
                .background {
                    // The same view at its ideal size: one line, as wide as it needs.
                    content
                        .fixedSize()
                        .hidden()
                        .environment(\.wrapProbeIsReference, true)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { ideal in
                            WrapProbe.shared.update(id, kind: kind, text: text, source: source, minimumScale: minimumScale, scrolls: scrolls, ideal: ideal)
                        }
                        .accessibilityHidden(true)
                }
                .onDisappear { WrapProbe.shared.remove(id) }
        }
    }
}

/// A native table's or list's frame for the probe (`wrapProbeClips`): its figures must lie
/// within it sideways.
struct WrapProbeClipRegion: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.wrapProbeClipRegion, id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                WrapProbe.shared.clipRegions[id] = frame
            }
    }
}
#endif
