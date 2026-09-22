import Foundation
import CryptoKit

public enum TransactionFingerprint {
    public static func compute(accountId: Int64, date: Date, amountMinorUnits: Int, description: String) -> String {
        let normalizedDescription = description
            .uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        let dayString = dayFormatter.string(from: date)

        let raw = "\(accountId)|\(dayString)|\(amountMinorUnits)|\(normalizedDescription)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
