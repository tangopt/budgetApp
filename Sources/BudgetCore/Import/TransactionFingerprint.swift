import Foundation
import CryptoKit

public enum TransactionFingerprint {
    /// `occurrence` distinguishes genuinely repeated, identical-looking transactions
    /// within one statement (two £3.30 coffees at the same shop on the same day):
    /// the first keeps the plain fingerprint (occurrence 0, backward compatible), the
    /// nth repeat gets occurrence n-1. Re-importing an overlapping statement recomputes
    /// the same occurrence numbers, so each row still dedups against its earlier twin.
    public static func compute(accountId: Int64, date: Date, amountMinorUnits: Int, description: String, occurrence: Int = 0) -> String {
        let normalizedDescription = description
            .uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        let dayString = dayFormatter.string(from: date)

        var raw = "\(accountId)|\(dayString)|\(amountMinorUnits)|\(normalizedDescription)"
        if occurrence > 0 { raw += "|#\(occurrence)" }
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
