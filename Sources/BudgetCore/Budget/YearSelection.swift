import Foundation

/// A grid's selected years (the Forecast grid's year cards): a plain click shows one year, a
/// ⌘-click adds or removes one to compare several. Always sorted, never empty.
public enum YearSelection {
    /// `selected` with `year` added (kept sorted), or removed unless it is the last one left.
    public static func toggled(_ selected: [Int], _ year: Int) -> [Int] {
        if let index = selected.firstIndex(of: year) {
            guard selected.count > 1 else { return selected }
            var result = selected
            result.remove(at: index)
            return result
        }
        return (selected + [year]).sorted()
    }

    /// `selected` kept to the `available` years; when none is left, `preferred` if available,
    /// else the first available year (`selected` unchanged when nothing is available).
    public static func clamped(_ selected: [Int], to available: [Int], preferred: Int) -> [Int] {
        let kept = selected.filter(available.contains).sorted()
        if !kept.isEmpty { return kept }
        if available.contains(preferred) { return [preferred] }
        return available.first.map { [$0] } ?? selected
    }
}
