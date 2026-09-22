import Foundation

public enum CSVRowSplitter {
    public static func split(line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            if char == "\"" {
                insideQuotes.toggle()
            } else if char == delimiter && !insideQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
