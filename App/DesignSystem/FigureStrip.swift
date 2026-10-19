// App/DesignSystem/FigureStrip.swift
import SwiftUI
import BudgetCore

/// One key figure (spec §4.1): a `.caption` secondary title, the value in `.title3`
/// semibold, then an optional GBP equivalent, an optional caption (secondary, or in a
/// warning tone) and an optional status pill (a check on the figure: "€100.00 short").
struct FigureTile: View {
    enum Value {
        case money(Int, Currency, MoneyRole)
        case text(String)
    }

    let title: String
    let value: Value
    /// The GBP equivalent of a non-GBP amount, beneath it.
    var gbp: Int? = nil
    var caption: String? = nil
    var captionIsWarning = false
    var pill: StatusPill? = nil
    @Environment(\.theme) private var theme

    /// How the amount (and its GBP equivalent) reads.
    private var role: MoneyRole {
        if case let .money(_, _, role) = value { return role }
        return .neutral
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .wrapProbe("FigureTile.title", text: title)
            switch value {
            case let .money(minorUnits, currency, role):
                MoneyText(minorUnits: minorUnits, currency: currency, font: .title3.monospacedDigit().weight(.semibold), role: role)
            case let .text(text):
                Text(text).font(.title3.monospacedDigit().weight(.semibold)).lineLimit(1).fixedSize()
                    .wrapProbe("FigureTile.value", text: text)
            }
            if let gbp {
                MoneyText(minorUnits: gbp, currency: .gbp, font: .caption.monospacedDigit(), role: role, tint: .secondary)
            }
            if let caption {
                Text(caption).font(.caption).lineLimit(1)
                    .foregroundStyle(captionIsWarning ? theme.pending : Color.secondary)
                    .wrapProbe("FigureTile.caption", text: caption)
            }
            if let pill {
                pill.padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// Key figures in a row of equal columns with dividers between them; two rows when they
/// don't fit (never wrapping a figure).
struct FigureStrip: View {
    let tiles: [FigureTile]

    init(_ tiles: [FigureTile]) {
        self.tiles = tiles
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(tiles)
            VStack(alignment: .leading, spacing: 12) {
                let half = (tiles.count + 1) / 2
                row(Array(tiles.prefix(half)))
                row(Array(tiles.dropFirst(half)))
            }
        }
    }

    private func row(_ tiles: [FigureTile]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                if index > 0 { Divider() }
                tile.fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
