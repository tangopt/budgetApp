// App/Tax/TaxComparisonTile.swift
import SwiftUI
import BudgetCore

/// The Calculation tab's "Compared with <previous year>" tile: every figure of the return and
/// the calculation, last year's beside this year's with the difference; the lines that changed
/// are tinted and say why where `TaxReturnComparison` could tell. Only lays the comparison out.
struct TaxComparisonPanel: View {
    let comparison: TaxReturnComparison.Result?
    let previousLabel: String

    var body: some View {
        if let comparison {
            Panel("Compared with \(comparison.previousLabel)",
                  subtitle: "\(comparison.changedCount) of \(comparison.lineCount) figures differ from \(comparison.previousLabel); changed lines are highlighted") {
                TaxComparisonTable(comparison: comparison)
            }
        } else {
            Panel("Compared with \(previousLabel)") {
                Text("No return for \(previousLabel) to compare with.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct TaxComparisonTable: View {
    let comparison: TaxReturnComparison.Result
    @Environment(\.theme) private var theme

    private static let amountWidth: CGFloat = 116

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Figure")
                Spacer(minLength: 8)
                Text(comparison.previousLabel).frame(width: Self.amountWidth, alignment: .trailing)
                Text(comparison.currentLabel).frame(width: Self.amountWidth, alignment: .trailing)
                Text("Difference").frame(width: Self.amountWidth, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(theme.gridHeaderBackground)
            .overlay(alignment: .bottom) { Rectangle().frame(height: 1).foregroundStyle(.separator) }
            .accessibilityHidden(true)
            ForEach(comparison.groups) { group in
                HStack {
                    Text(group.section.rawValue).font(.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    if group.changedCount > 0 {
                        Text("\(group.changedCount) changed").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(theme.gridHeaderBackground.opacity(0.6))
                .accessibilityAddTraits(.isHeader)
                ForEach(Array(group.lines.enumerated()), id: \.element.id) { index, line in
                    row(line, index: index)
                }
            }
        }
    }

    private func row(_ line: TaxReturnComparison.Line, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.label).font(line.isTotal ? .body.weight(.semibold) : .body)
                    .lineLimit(1).truncationMode(.middle).help(line.label)
                if let why = line.why, line.isChanged {
                    Text(why.figuresUnbroken).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            amount(line.previous, present: line.inPrevious)
            amount(line.current, present: line.inCurrent)
            Group {
                if line.isChanged {
                    MoneyText(minorUnits: line.difference, currency: .gbp, role: .neutral, alignment: .trailing)
                        .fontWeight(.semibold)
                } else {
                    Text("–").foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.amountWidth, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(minHeight: 28)
        .background(line.isChanged ? theme.accent.opacity(0.13) : theme.rowBackground(index % 2 == 1))
        .overlay(alignment: .leading) {
            if line.isChanged { Rectangle().fill(theme.accent).frame(width: 3) }
        }
        .overlay(alignment: .bottom) { Rectangle().frame(height: 1).foregroundStyle(.separator) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility(line))
    }

    @ViewBuilder
    private func amount(_ value: Int, present: Bool) -> some View {
        Group {
            if present {
                MoneyText(minorUnits: value, currency: .gbp, role: .neutral, alignment: .trailing)
            } else {
                Text("–").foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.amountWidth, alignment: .trailing)
    }

    private func accessibility(_ line: TaxReturnComparison.Line) -> String {
        let money = { (v: Int) in Money.format(v, currency: .gbp) }
        var text = "\(line.label): \(comparison.previousLabel) \(line.inPrevious ? money(line.previous) : "none"), \(comparison.currentLabel) \(line.inCurrent ? money(line.current) : "none")"
        if line.isChanged { text += ", difference \(money(line.difference))" + (line.why.map { ". \($0)" } ?? "") } else { text += ", unchanged" }
        return text
    }
}
