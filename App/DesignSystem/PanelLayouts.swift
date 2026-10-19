// App/DesignSystem/PanelLayouts.swift
import SwiftUI

/// Two panels side by side, the first taking `ratio` of the width (a chart beside its
/// companion), both as tall as the taller one when they stretch (`Panel(fillsHeight:)`); one
/// above the other when the row is narrower than `stackBelow`, or when either panel can't fit
/// its share (a side panel open beside the page). `TwoUpRow` is the equal-width version.
struct SplitRow: Layout {
    var ratio: CGFloat = 0.5
    var spacing: CGFloat = ScreenMetrics.spacing
    var stackBelow: CGFloat = 640

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let first = ((total - spacing) * ratio).rounded()
        return (first, total - spacing - first)
    }

    /// Whether the two go side by side in `total`: wide enough, and (`checksFit`: a width was
    /// proposed) each fits its share.
    private func sideBySide(_ total: CGFloat, _ subviews: Subviews, checksFit: Bool) -> Bool {
        guard subviews.count == 2, total >= stackBelow else { return false }
        guard checksFit else { return true }
        let (first, second) = widths(total)
        return subviews[0].sizeThatFits(ProposedViewSize(width: first, height: nil)).width <= first + 0.5
            && subviews[1].sizeThatFits(ProposedViewSize(width: second, height: nil)).width <= second + 0.5
    }

    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = width(proposal, subviews)
        guard subviews.count == 2 else {
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: total, height: nil)).height }
            return CGSize(width: total, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
        }
        if !sideBySide(total, subviews, checksFit: proposal.width != nil) {
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: total, height: nil)).height }
            return CGSize(width: total, height: heights.reduce(0, +) + spacing)
        }
        let (first, second) = widths(total)
        let height = max(subviews[0].sizeThatFits(ProposedViewSize(width: first, height: nil)).height,
                         subviews[1].sizeThatFits(ProposedViewSize(width: second, height: nil)).height)
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard sideBySide(bounds.width, subviews, checksFit: proposal.width != nil) else {
            var y = bounds.minY
            for subview in subviews {
                let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height + spacing
            }
            return
        }
        let (first, second) = widths(bounds.width)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: first, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + first + spacing, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: second, height: bounds.height))
    }
}

/// Panels in rows of equal columns filling the width — as many columns as fit at
/// `minColumnWidth` (at most `maxColumns`) — each panel as tall as the tallest in its row
/// (`Panel(fillsHeight:)`). Unlike an adaptive grid it never leaves a gap at the end of a row
/// wider than the spacing.
struct PanelGrid: Layout {
    var minColumnWidth: CGFloat = 340
    var maxColumns = 3
    var spacing: CGFloat = ScreenMetrics.spacing

    private func columns(_ width: CGFloat) -> Int {
        max(1, min(maxColumns, Int((width + spacing) / (minColumnWidth + spacing))))
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (columnWidth: CGFloat, heights: [CGFloat], columns: Int) {
        let columns = columns(width)
        let columnWidth = ((width - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        var heights: [CGFloat] = []
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = subviews[start..<min(start + columns, subviews.count)]
            heights.append(row.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0)
        }
        return (columnWidth, heights, columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minColumnWidth * CGFloat(maxColumns) + spacing * CGFloat(maxColumns - 1))
        let layout = rows(subviews, width: width)
        let height = layout.heights.reduce(0, +) + spacing * CGFloat(max(0, layout.heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (rowIndex, height) in layout.heights.enumerated() {
            for column in 0..<layout.columns {
                let index = rowIndex * layout.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (layout.columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: layout.columnWidth, height: height))
            }
            y += height + spacing
        }
    }
}
