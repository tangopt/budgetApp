import SwiftUI
import BudgetCore

/// A stored day as the phone writes it: "8 Jan 2026" (UTC, English month names, whatever the device's locale), as
/// the Mac does.
public enum PhoneDateFormat {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    /// "8 Jan 2026"; "—" for no day.
    public static func day(_ date: Date?) -> String {
        date.map { formatter.string(from: $0) } ?? "—"
    }

    /// What VoiceOver reads: the day, or "No date".
    public static func spoken(_ date: Date?) -> String {
        date == nil ? "No date" : day(date)
    }
}

/// A day as one line in tabular digits ("8 Jan 2026"); "—", secondary, when there is none. Never wraps; checked by
/// the wrap probe.
public struct DateText: View {
    public let date: Date?
    public var font: PhoneTextStyle
    public var fit: FigureFit
    @Environment(\.phoneFonts) private var fonts

    public init(_ date: Date?, font: PhoneTextStyle = .body, fit: FigureFit = .natural) {
        self.date = date
        self.font = font
        self.fit = fit
    }

    public var body: some View {
        let text = PhoneDateFormat.day(date)
        Text(text)
            .font(TypefaceResolver.font(fonts, style: font.style, weight: font.weight, isFigure: true).monospacedDigit())
            .foregroundStyle(date == nil ? Color.secondary : Color.primary)
            .modifier(FigureFitModifier(fit: fit, kind: "DateText", text: text, source: nil))
            .accessibilityLabel(PhoneDateFormat.spoken(date))
    }
}
