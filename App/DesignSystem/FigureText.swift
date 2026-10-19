// App/DesignSystem/FigureText.swift
import SwiftUI

/// How a figure keeps to one line (spec §6.3, "figures never wrap").
enum FigureFit {
    /// At its natural width: it never wraps or truncates, and the layout around it gives way
    /// (a label beside it truncates, a column flexes). The default.
    case natural
    /// In a slot whose width can't give way (a fixed column, a chart's annotation): one line
    /// that shrinks down to `minimumScale` before it would truncate.
    case shrink(minimumScale: CGFloat = 0.7)
}

extension View {
    /// A figure that isn't an amount (`MoneyText`) or a day (`DateText`) — a count, a
    /// percentage, a rate ("€1 = £0.8640"), "3 of 5", a box value, a year, a period — as one
    /// line that never wraps: `lineLimit(1)` and its natural width (`.natural`), or a slight
    /// shrink where the width is fixed (`.shrink`). In a snapshot build the wrap probe checks it.
    func figureText(_ fit: FigureFit = .natural, file: StaticString = #fileID, line: UInt = #line) -> some View {
        modifier(FigureTextModifier(fit: fit, text: nil, file: file, line: line))
    }
}

extension Text {
    /// `View.figureText` for a `Text`, which the wrap probe can name in its report.
    func figureText(_ fit: FigureFit = .natural, file: StaticString = #fileID, line: UInt = #line) -> some View {
        modifier(FigureTextModifier(fit: fit, text: WrapProbeText.describe(self), file: file, line: line))
    }
}

struct FigureTextModifier: ViewModifier {
    let fit: FigureFit
    /// The probe's names for it (snapshot builds): its words, and where it is in the source.
    let text: String?
    let file: StaticString
    let line: UInt

    func body(content: Content) -> some View {
        switch fit {
        case .natural:
            content
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .wrapProbe("figure", text: text, source: "\(file):\(line)")
        case let .shrink(minimumScale):
            content
                .lineLimit(1)
                .minimumScaleFactor(minimumScale)
                .wrapProbe("figure", text: text, source: "\(file):\(line)", minimumScale: minimumScale)
        }
    }
}

extension View {
    /// Reports the view's rendered size against its one-line ideal to the snapshot harness's
    /// wrap probe (`WrapProbe`, snapshot builds only); does nothing in the app.
    /// `text` and `source` are only evaluated in a snapshot build.
    @ViewBuilder
    func wrapProbe(_ kind: String, text: @autoclosure () -> String?, source: @autoclosure () -> String? = nil,
                   minimumScale: CGFloat = 1) -> some View {
        #if SNAPSHOTS
        modifier(WrapProbeModifier(kind: kind, text: text(), source: source(), minimumScale: minimumScale))
        #else
        self
        #endif
    }

    /// Marks a chart: Swift Charts lays its axis labels and annotations out apart from the
    /// enclosing scroll view, so the probe's scroll-view clip check doesn't apply to them.
    /// Snapshot builds only; does nothing in the app.
    @ViewBuilder
    func wrapProbeInChart() -> some View {
        #if SNAPSHOTS
        environment(\.wrapProbeIsInChart, true)
        #else
        self
        #endif
    }

    /// Marks a native `Table` or `List`: the probe checks its figures against its frame, since
    /// the table clips a column pushed past its edge without it leaving the window. Snapshot
    /// builds only; does nothing in the app.
    @ViewBuilder
    func wrapProbeClips() -> some View {
        #if SNAPSHOTS
        modifier(WrapProbeClipRegion())
        #else
        self
        #endif
    }

    /// Marks content that scrolls sideways (the month grids): its figures may lie beyond the
    /// window without being cut off. Snapshot builds only; does nothing in the app.
    @ViewBuilder
    func wrapProbeScrollsHorizontally() -> some View {
        #if SNAPSHOTS
        environment(\.wrapProbeScrollsHorizontally, true)
        #else
        self
        #endif
    }
}

/// A `Text`'s words for the wrap probe's report (snapshot builds; empty in the app).
enum WrapProbeText {
    static func describe(_ text: Text) -> String? {
        #if SNAPSHOTS
        WrapProbe.describe(text)
        #else
        nil
        #endif
    }
}
