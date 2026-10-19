// App/DesignSystem/DateText.swift
import SwiftUI
import AppKit

/// A stored (UTC) day as "8 Jan 2026" in monospaced digits, always as wide as the widest day
/// in the font, so the text after it lines up from row to row (spec C10). `nil` shows "—".
struct DateText: View {
    let date: Date?
    var font: Font = .body
    /// Where the day sits in its fixed width: leading in a column of days; trailing for the
    /// first day of a range, so the dash after it stays close ("1 Aug 2025 – 31 Aug 2025").
    var alignment: Alignment = .leading

    /// The widest renderings, formatted as the dates are (`DocumentFormat.day`): a two-digit
    /// day in every month, so the widest month abbreviation in the current locale is covered.
    /// Only the ones that are the widest in some text size and weight are kept (measured once
    /// with the system font): a day reserves its width with one or two hidden texts rather
    /// than twelve, which in a long table is thousands of texts fewer to lay out.
    private static let templates: [String] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let days = (1...12).compactMap { calendar.date(from: DateComponents(year: 2026, month: $0, day: 28)) }
        let all = Array(Set(days.map(DocumentFormat.day))).sorted()
        var widest = Set<String>()
        for size in [10, 11, 12, 13, 15, 17, 20, 22, 26] as [CGFloat] {
            for weight in [NSFont.Weight.regular, .medium, .semibold, .bold] {
                let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                let widths = all.map { ($0, ($0 as NSString).size(withAttributes: [.font: font]).width) }
                guard let top = widths.map(\.1).max() else { continue }
                // Within a hair of the widest too: rounding may favour either.
                widest.formUnion(widths.filter { $0.1 >= top - 0.5 }.map(\.0))
            }
        }
        return widest.isEmpty ? all : widest.sorted()
    }()

    var body: some View {
        ZStack(alignment: alignment) {
            ForEach(Self.templates, id: \.self) { Text($0).hidden() }
            Text(date.map(DocumentFormat.day) ?? "—")
                .foregroundStyle(date == nil ? Color.secondary : Color.primary)
        }
        .font(font.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .wrapProbe("DateText", text: date.map(DocumentFormat.day) ?? "—")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(date.map(DocumentFormat.day) ?? "No date")
    }
}
