import SwiftUI

/// The snapshot harness's check that figures stay on one line (iPhone spec §4 and §6; a port of the Mac's
/// `App/Snapshots/WrapProbe.swift`). Every figure view (`MoneyText`, `figureText`, `DateText`) reports its rendered
/// frame and its one-line ideal size while the probe is active; the phone's `PhoneSnapshotRunner` turns it on, asks
/// for the violations after each render has laid out, and writes them to `wrap-report.txt`.
///
/// - **wrapped**: taller than one line of its font (its ideal height).
/// - **truncated**: narrower than its ideal width, beyond what its shrink allows.
/// - **cut off**: outside the window sideways.
///
/// MangoUI is a package and can't see the app's `SNAPSHOTS` condition, so the switch is `isActive`, off unless the
/// harness sets it: in the app the probe adds no geometry readers and reports nothing.
@MainActor
public final class WrapProbeRegistry {
    public static let shared = WrapProbeRegistry()

    /// On only in the snapshot harness.
    public var isActive = false

    struct Entry {
        var kind: String
        var text: String?
        var source: String?
        var minimumScale: CGFloat
        var frame: CGRect?
        var ideal: CGSize?
    }

    public struct Violation: Hashable, Sendable {
        public enum Problem: String, CaseIterable, Sendable { case wrapped, truncated, cutOff = "cut off" }
        public let route: String
        public let problem: Problem
        public let kind: String
        public let text: String
        public let source: String
        public let size: CGSize
        public let ideal: CGSize
        public let origin: CGPoint

        public init(route: String, problem: Problem, kind: String, text: String, source: String, size: CGSize, ideal: CGSize,
                    origin: CGPoint) {
            self.route = route
            self.problem = problem
            self.kind = kind
            self.text = text
            self.source = source
            self.size = size
            self.ideal = ideal
            self.origin = origin
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(route); hasher.combine(problem); hasher.combine(kind); hasher.combine(text); hasher.combine(source)
        }

        public static func == (a: Violation, b: Violation) -> Bool {
            a.route == b.route && a.problem == b.problem && a.kind == b.kind && a.text == b.text && a.source == b.source
        }
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    /// How many figures on screen have reported both sizes.
    public var checkedCount: Int {
        entries.values.filter { $0.frame != nil && $0.ideal != nil }.count
    }

    public func reset() {
        entries = [:]
    }

    func update(_ id: UUID, kind: String, text: String?, source: String?, minimumScale: CGFloat,
                frame: CGRect? = nil, ideal: CGSize? = nil) {
        var entry = entries[id] ?? Entry(kind: kind, text: text, source: source, minimumScale: minimumScale)
        entry.kind = kind
        entry.text = text
        entry.source = source
        entry.minimumScale = minimumScale
        if let frame { entry.frame = frame }
        if let ideal { entry.ideal = ideal }
        entries[id] = entry
    }

    func remove(_ id: UUID) {
        entries[id] = nil
    }

    /// The figures on screen now that break the rule, in a window of `window` points.
    public func violations(route: String, window: CGSize) -> [Violation] {
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
            if frame.width > 0, frame.maxX > window.width + 1 || frame.minX < -1 { add(.cutOff) }
        }
        return found
    }

    // MARK: Naming a Text

    /// A `Text`'s words, read from its structure (a string, or a localized key with its arguments put in). Best
    /// effort, for the report; nil unless the probe is active, so the app never walks a `Text`.
    static func describe(_ text: Text) -> String? {
        guard shared.isActive else { return nil }
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
            case let number as Double: arguments.append("\(number)"); return
            case let number as CGFloat: arguments.append("\(number)"); return
            case is Bool: return
            default: break
            }
            for child in Mirror(reflecting: value).children {
                walk(child.value, depth: depth + 1, label: child.label)
            }
        }
        walk(text, depth: 0, label: nil)
        guard var result = strings.first else { return arguments.isEmpty ? nil : arguments.joined(separator: " ") }
        var remaining = arguments[...]
        while let range = result.range(of: #"%(\d+\$)?[-+ 0#]*\d*(\.\d+)?(ll|l|h)?[@dDiuUxXoOfeEgGcCsS]"#, options: .regularExpression),
              let argument = remaining.popFirst() {
            result.replaceSubrange(range, with: argument)
        }
        let rest = strings.dropFirst() + remaining
        return rest.isEmpty ? result : ([result] + rest).joined(separator: " ")
    }

    // MARK: Report

    /// The report: a heading, the count line (the script prints both), then each render's violations.
    /// `renders`: each render's name ("gallery-dark-xxxLarge") and how many figures it checked.
    public nonisolated static func report(_ violations: [Violation], renders: [(name: String, checked: Int)], window: CGSize) -> String {
        var lines: [String] = []
        let byProblem = Violation.Problem.allCases.map { problem in "\(problem.rawValue) \(violations.filter { $0.problem == problem }.count)" }
        let renderCount = Set(violations.map(\.route)).count
        lines.append("Wrap probe at \(Int(window.width))×\(Int(window.height)) (iPhone)")
        lines.append("\(renders.count) renders, \(renders.reduce(0) { $0 + $1.checked }) figures checked; \(violations.count) violations in \(renderCount) renders (\(byProblem.joined(separator: ", ")))")
        lines.append("")
        for render in renders {
            let found = violations.filter { $0.route == render.name }
                .sorted { ($0.problem.rawValue, $0.origin.y, $0.origin.x) < ($1.problem.rawValue, $1.origin.y, $1.origin.x) }
            guard !found.isEmpty else { continue }
            lines.append(render.name)
            for violation in found {
                let text = violation.text.replacingOccurrences(of: "\n", with: " ")
                lines.append("  \(violation.problem.rawValue)  \(violation.kind)  \"\(text)\"  shown \(size(violation.size)) needs \(size(violation.ideal)) at \(Int(violation.origin.x)),\(Int(violation.origin.y))  \(violation.source)")
            }
        }
        lines.append("Figures checked by render:")
        for render in renders {
            lines.append("  \(render.name) \(render.checked)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated private static func size(_ size: CGSize) -> String {
        String(format: "%.0f×%.0f", size.width, size.height)
    }
}

extension View {
    /// Reports the view's rendered size against its one-line ideal to the wrap probe while it is active (the
    /// snapshot harness); adds nothing otherwise.
    func wrapProbe(_ kind: String, text: String?, source: String?, minimumScale: CGFloat) -> some View {
        modifier(WrapProbeModifier(kind: kind, text: text, source: source, minimumScale: minimumScale))
    }

    /// Marks hidden copies laid out only to be measured: the probe leaves their figures out.
    public func wrapProbeIgnored() -> some View {
        environment(\.wrapProbeIsReference, true)
    }
}

extension EnvironmentValues {
    /// Inside the probe's own measuring copy (or a hidden one), which reports nothing.
    @Entry var wrapProbeIsReference = false
}

/// Reports one figure view's frame and its ideal, one-line size to `WrapProbeRegistry`.
struct WrapProbeModifier: ViewModifier {
    let kind: String
    let text: String?
    let source: String?
    let minimumScale: CGFloat
    @Environment(\.wrapProbeIsReference) private var isReference
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if isReference || !WrapProbeRegistry.shared.isActive {
            content
        } else {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    WrapProbeRegistry.shared.update(id, kind: kind, text: text, source: source, minimumScale: minimumScale, frame: frame)
                }
                .background {
                    // The same view at its ideal size: one line, as wide as it needs.
                    content
                        .fixedSize()
                        .hidden()
                        .environment(\.wrapProbeIsReference, true)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { ideal in
                            WrapProbeRegistry.shared.update(id, kind: kind, text: text, source: source, minimumScale: minimumScale, ideal: ideal)
                        }
                        .accessibilityHidden(true)
                }
                .onDisappear { WrapProbeRegistry.shared.remove(id) }
        }
    }
}
