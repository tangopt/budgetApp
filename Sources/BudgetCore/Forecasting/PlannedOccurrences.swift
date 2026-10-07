import Foundation

public struct PlannedOccurrence: Equatable, Identifiable {
    public let entryId: Int64
    public let originalDate: Date
    public let date: Date            // after any move
    public let categoryId: Int64     // after any re-file
    public let amountMinorUnits: Int // after any override
    public let isException: Bool
    public var id: String { "\(entryId)-\(originalDate.timeIntervalSince1970)" }

    public init(entryId: Int64, originalDate: Date, date: Date, categoryId: Int64, amountMinorUnits: Int, isException: Bool) {
        self.entryId = entryId
        self.originalDate = originalDate
        self.date = date
        self.categoryId = categoryId
        self.amountMinorUnits = amountMinorUnits
        self.isException = isException
    }
}

public enum PlannedOccurrences {
    /// Occurrences whose (possibly moved) date falls in the period: the series' originals
    /// in the period that aren't skipped or moved out, plus exceptions moved into it.
    public static func occurrences(entries: [ForecastEntry], exceptions: [PlannedOccurrenceException], in period: PayPeriod) -> [PlannedOccurrence] {
        let byKey = Dictionary(exceptions.map { (Key(entryId: $0.entryId, date: $0.originalDate), $0) }, uniquingKeysWith: { a, _ in a })
        let entryById = Dictionary(entries.compactMap { e in e.id.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        var result: [PlannedOccurrence] = []
        for entry in entries {
            guard let id = entry.id else { continue }
            for original in FrequencyExpander.occurrences(for: entry, in: period) {
                let exception = byKey[Key(entryId: id, date: original)]
                if exception?.isSkipped == true { continue }
                let date = exception?.date ?? original
                guard date >= period.startDate, date <= period.endDate else { continue } // moved out
                result.append(make(entry, original: original, exception: exception))
            }
        }
        // Exceptions moved INTO the period from an original date outside it.
        for exception in exceptions where !exception.isSkipped {
            guard let moved = exception.date, moved >= period.startDate, moved <= period.endDate,
                  !(exception.originalDate >= period.startDate && exception.originalDate <= period.endDate),
                  let entry = entryById[exception.entryId] else { continue }
            // Only if the original is a real occurrence of the series.
            let probe = PayPeriod(startDate: exception.originalDate, endDate: exception.originalDate, type: .projected)
            guard FrequencyExpander.occurrences(for: entry, in: probe).contains(exception.originalDate) else { continue }
            result.append(make(entry, original: exception.originalDate, exception: exception))
        }
        return result.sorted { $0.date < $1.date }
    }

    private struct Key: Hashable { let entryId: Int64; let date: Date }

    private static func make(_ entry: ForecastEntry, original: Date, exception: PlannedOccurrenceException?) -> PlannedOccurrence {
        PlannedOccurrence(entryId: entry.id!, originalDate: original, date: exception?.date ?? original,
                          categoryId: exception?.categoryId ?? entry.categoryId,
                          amountMinorUnits: exception?.amountMinorUnits ?? entry.amountMinorUnits,
                          isException: exception != nil)
    }
}
