// App/DesignSystem/DateText.swift
import SwiftUI

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
    private static let templates: [String] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let days = (1...12).compactMap { calendar.date(from: DateComponents(year: 2026, month: $0, day: 28)) }
        return Array(Set(days.map(DocumentFormat.day))).sorted()
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
