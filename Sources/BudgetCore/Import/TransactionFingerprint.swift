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

    /// Every row's fingerprint as staging assigns it: the nth identical-looking row of the
    /// file (same day, amount and description) gets occurrence n-1.
    public static func computeAll(accountId: Int64, transactions: [ParsedTransaction]) -> [String] {
        var occurrencesSeen: [String: Int] = [:]
        return transactions.map { parsed in
            let base = compute(accountId: accountId, date: parsed.date, amountMinorUnits: parsed.amountMinorUnits, description: parsed.rawDescription)
            let occurrence = occurrencesSeen[base, default: 0]
            occurrencesSeen[base] = occurrence + 1
            return compute(accountId: accountId, date: parsed.date, amountMinorUnits: parsed.amountMinorUnits, description: parsed.rawDescription,
                           occurrence: occurrence)
        }
    }
}
