import Foundation

/// The words of every reminder the iPhone sends. A figure appears only with `showFigures` (the lock-screen setting)
/// and an amount to show; the dates may carry digits.
public enum NotificationCopy {
    /// The longest a property or bill name runs before its middle is cut.
    public static let nameLimit = 40

    /// The days are the rent status's own window (`RentReceiptMatching.Options.windowDays`), the point the property
    /// screen calls the rent late, so the words never drift from it.
    public static func rentLate(property: String, showFigures: Bool, amount: String?) -> (title: String, body: String) {
        let place = truncated(property)
        let expected = showFigures ? amount.map { " (\($0) expected)" } : nil
        return ("Rent not seen", "Rent for \(place) hasn't arrived \(RentReceiptMatching.Options().windowDays) days after it was due\(expected ?? "").")
    }

    public static func billDue(name: String, date: Date, showFigures: Bool, amount: String?) -> (title: String, body: String) {
        ("Bill due in 3 days", due(name: name, date: date, showFigures: showFigures, amount: amount))
    }

    public static func taxDue(name: String, date: Date, showFigures: Bool, amount: String?) -> (title: String, body: String) {
        ("Tax payment due in 7 days", due(name: name, date: date, showFigures: showFigures, amount: amount))
    }

    public static func noImport() -> (title: String, body: String) {
        ("No statement imported", "The last import was 14 days ago or more.")
    }

    private static func due(name: String, date: Date, showFigures: Bool, amount: String?) -> String {
        let figure = showFigures ? amount.map { " \($0)" } : nil
        return "\(truncated(name)) is due on \(dateText(date)).\(figure ?? "")"
    }

    /// "12 Nov 2026", the same on every device.
    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// `text` cut in the middle with an ellipsis when longer than `nameLimit` characters.
    static func truncated(_ text: String) -> String {
        guard text.count > nameLimit else { return text }
        let head = (nameLimit - 1) / 2 + (nameLimit - 1) % 2
        let tail = nameLimit - 1 - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }
}
