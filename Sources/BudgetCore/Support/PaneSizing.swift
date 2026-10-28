import Foundation

/// The arithmetic of resizable panes on the Mac: a right-hand side panel's width, and the split
/// between a form column and a results column. Pure numbers so the limits are tested; the views
/// (`ResizableDock`, `ResizableSplit`) only drag and store.
public enum PaneSizing {
    /// The preference key a panel kind's width is remembered under (per Mac, in the app's defaults).
    public static func widthKey(_ kind: String) -> String { "pane.\(kind).width" }
    /// The preference key a split's leading fraction is remembered under.
    public static func splitKey(_ kind: String) -> String { "split.\(kind).fraction" }

    /// A side panel's width: `stored` (0 or less: `defaultWidth`) held between `minimum` and the
    /// smaller of `maximum` and the room left once the page keeps `pageMinimum`. The minimum wins
    /// where the window is too small for both.
    public static func panelWidth(stored: Double, defaultWidth: Double, minimum: Double, maximum: Double,
                                  available: Double, pageMinimum: Double) -> Double {
        let wanted = stored > 0 ? stored : defaultWidth
        let upper = max(minimum, min(maximum, available - pageMinimum))
        return min(max(wanted, minimum), upper)
    }

    /// The width after dragging the leading edge: dragging left (a negative translation) widens it.
    public static func draggedPanelWidth(start: Double, translation: Double) -> Double { start - translation }

    /// The leading column's width in a split of `total` points: `fraction` of it, held so the
    /// leading column keeps `leadingMinimum` and the trailing one `trailingMinimum`.
    public static func splitLeadingWidth(fraction: Double, total: Double, leadingMinimum: Double, trailingMinimum: Double) -> Double {
        let upper = max(leadingMinimum, total - trailingMinimum)
        return min(max(fraction * total, leadingMinimum), upper)
    }

    /// The fraction to remember for a leading column of `width` in `total` (0.5 for no room).
    public static func splitFraction(leadingWidth: Double, total: Double) -> Double {
        guard total > 0 else { return 0.5 }
        return min(max(leadingWidth / total, 0.05), 0.95)
    }
}
