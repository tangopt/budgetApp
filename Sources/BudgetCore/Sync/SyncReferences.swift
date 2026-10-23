import Foundation
import GRDB

public enum SyncReferenceError: Error, Equatable {
    /// A polymorphic type value (`documentLink.entityType`) or an evidence entity type inside JSON that
    /// `SyncSchema` doesn't classify, so its id can't be translated.
    case unclassifiedType(table: String, column: String, type: String)
}

/// How a reference read on this device is sent, and how one that arrives is resolved.
final class SyncReferenceResolver {
    enum Incoming: Equatable {
        case local(Int64)
        /// The record was deleted (a tombstone here): the reference names no row.
        case deleted
        /// Not here yet: the payload waits in staging.
        case missing
    }

    let db: Database
    /// What incoming references are waiting for, as `table` names (never values).
    private(set) var missing: Set<String> = []
    /// An incoming declared foreign key names a deleted parent.
    private(set) var deletedParents: Set<String> = []

    init(db: Database) { self.db = db }

    func reset() {
        missing = []
        deletedParents = []
    }

    /// The row's UUID, creating its identity if it has none; nil when no such row exists here.
    func outgoing(table: String, localId: Int64) throws -> String? {
        guard SyncSchema.table(table) != nil else { return nil }
        if let uuid = try SyncRecordStore.existingUUID(table: table, localId: localId, db: db) { return uuid }
        do {
            return try SyncRecordStore.uuid(for: table, localId: localId, db: db)
        } catch SyncRecordStoreError.noSuchRow {
            return nil
        }
    }

    func incoming(table: String, uuid: String) throws -> Incoming {
        if let id = try SyncRecordStore.localId(table: table, uuid: uuid, db: db) { return .local(id) }
        if try Bool.fetchOne(db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM syncTombstone WHERE uuid = ?)"), arguments: [uuid]) ?? false {
            return .deleted
        }
        return .missing
    }

    /// A reference that isn't a declared foreign key: a deleted target names no row.
    func incomingWeak(table: String, uuid: String) throws -> Int64? {
        switch try incoming(table: table, uuid: uuid) {
        case .local(let id): return id
        case .deleted: return nil
        case .missing:
            missing.insert(table)
            return nil
        }
    }

    /// A declared foreign key.
    func incomingStrong(table: String, uuid: String) throws -> Int64? {
        switch try incoming(table: table, uuid: uuid) {
        case .local(let id): return id
        case .deleted:
            deletedParents.insert(table)
            return nil
        case .missing:
            missing.insert(table)
            return nil
        }
    }
}

// MARK: JSON with byte ranges

/// A JSON value with the byte range of every node in its text, so references can be rewritten in place
/// and everything else stays byte-identical (formatting, key order, escapes, number spelling).
struct SyncJSONNode {
    enum Kind {
        case object([(key: String, keyStart: Int, value: SyncJSONNode)])
        case array([SyncJSONNode])
        case string(String)
        case number
        case bool
        case null
    }

    var kind: Kind
    var range: Range<Int>

    static func parse(_ text: String) -> SyncJSONNode? {
        var parser = Parser(bytes: Array(text.utf8))
        guard let node = parser.value() else { return nil }
        parser.skipSpace()
        return parser.index == parser.bytes.count ? node : nil
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value() -> SyncJSONNode? {
            skipSpace()
            guard index < bytes.count else { return nil }
            let start = index
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [(key: String, keyStart: Int, value: SyncJSONNode)] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return SyncJSONNode(kind: .object(members), range: start..<index)
                }
                while true {
                    skipSpace()
                    let keyStart = index
                    guard let key = string(), case .string(let name) = key.kind else { return nil }
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                    index += 1
                    guard let member = value() else { return nil }
                    members.append((name, keyStart, member))
                    skipSpace()
                    guard index < bytes.count else { return nil }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "}") else { return nil }
                    index += 1
                    return SyncJSONNode(kind: .object(members), range: start..<index)
                }
            case UInt8(ascii: "["):
                index += 1
                var elements: [SyncJSONNode] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return SyncJSONNode(kind: .array(elements), range: start..<index)
                }
                while true {
                    guard let element = value() else { return nil }
                    elements.append(element)
                    skipSpace()
                    guard index < bytes.count else { return nil }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "]") else { return nil }
                    index += 1
                    return SyncJSONNode(kind: .array(elements), range: start..<index)
                }
            case UInt8(ascii: "\""):
                return string()
            case UInt8(ascii: "t"): return literal("true", .bool)
            case UInt8(ascii: "f"): return literal("false", .bool)
            case UInt8(ascii: "n"): return literal("null", .null)
            default:
                let numberBytes = Set("+-0123456789.eE".utf8)
                while index < bytes.count, numberBytes.contains(bytes[index]) { index += 1 }
                return index > start ? SyncJSONNode(kind: .number, range: start..<index) : nil
            }
        }

        mutating func literal(_ word: String, _ kind: Kind) -> SyncJSONNode? {
            let start = index
            let wordBytes = Array(word.utf8)
            guard index + wordBytes.count <= bytes.count, Array(bytes[index..<index + wordBytes.count]) == wordBytes else { return nil }
            index += wordBytes.count
            return SyncJSONNode(kind: kind, range: start..<index)
        }

        mutating func string() -> SyncJSONNode? {
            let start = index
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
            index += 1
            var scalars: [UInt8] = []
            var pendingHigh: UInt32?
            func append(_ scalar: UInt32) {
                if let s = Unicode.Scalar(scalar) { scalars.append(contentsOf: Array(String(Character(s)).utf8)) }
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    return SyncJSONNode(kind: .string(String(decoding: scalars, as: UTF8.self)), range: start..<index)
                }
                if byte == UInt8(ascii: "\\") {
                    guard index + 1 < bytes.count else { return nil }
                    let escape = bytes[index + 1]
                    index += 2
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append(0x22)
                    case UInt8(ascii: "\\"): scalars.append(0x5C)
                    case UInt8(ascii: "/"): scalars.append(0x2F)
                    case UInt8(ascii: "b"): scalars.append(0x08)
                    case UInt8(ascii: "f"): scalars.append(0x0C)
                    case UInt8(ascii: "n"): scalars.append(0x0A)
                    case UInt8(ascii: "r"): scalars.append(0x0D)
                    case UInt8(ascii: "t"): scalars.append(0x09)
                    case UInt8(ascii: "u"):
                        guard index + 4 <= bytes.count,
                              let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else { return nil }
                        index += 4
                        if (0xD800..<0xDC00).contains(code) {
                            pendingHigh = code
                            continue
                        }
                        if (0xDC00..<0xE000).contains(code), let high = pendingHigh {
                            append(0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00))
                        } else {
                            append(code)
                        }
                        pendingHigh = nil
                        continue
                    default: return nil
                    }
                    pendingHigh = nil
                    continue
                }
                scalars.append(byte)
                index += 1
            }
            return nil
        }
    }
}

/// Replacements of byte ranges in a text, applied together.
struct SyncTextEdits {
    private(set) var edits: [(range: Range<Int>, text: String)] = []

    var isEmpty: Bool { edits.isEmpty }

    mutating func replace(_ range: Range<Int>, with text: String) { edits.append((range, text)) }

    func applied(to text: String) -> String {
        guard !edits.isEmpty else { return text }
        var bytes = Array(text.utf8)
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            bytes.replaceSubrange(edit.range, with: Array(edit.text.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: Translating references inside JSON

enum SyncDirection {
    case outgoing
    case incoming
}

/// Rewrites the ids inside JSON columns (`SyncSchema.jsonReferences`): local ids to UUID strings going
/// out, UUID strings back to local ids coming in. An id that names no row becomes 0, which no row has.
struct SyncJSONTranslator {
    let resolver: SyncReferenceResolver
    let direction: SyncDirection

    /// `text` with the ids the rules name translated; text that isn't JSON is left as it is.
    func translate(_ text: String, rules: [SyncJSONRule], table: String, column: String) throws -> String {
        guard let root = SyncJSONNode.parse(text) else { return text }
        var edits = SyncTextEdits()
        let byPath = Dictionary(rules.map { ($0.path, $0.target) }, uniquingKeysWith: { first, _ in first })
        try walk(root, path: "", text: text, rules: byPath, table: table, column: column, edits: &edits)
        return edits.applied(to: text)
    }

    private func walk(_ node: SyncJSONNode, path: String, text: String, rules: [String: SyncJSONRule.Target],
                      table: String, column: String, edits: inout SyncTextEdits) throws {
        if let target = rules[path] {
            try apply(target, to: node, text: text, table: table, column: column, edits: &edits)
            return
        }
        switch node.kind {
        case .object(let members):
            for member in members {
                try walk(member.value, path: path.isEmpty ? member.key : path + "." + member.key, text: text, rules: rules,
                         table: table, column: column, edits: &edits)
            }
        case .array(let elements):
            for element in elements {
                try walk(element, path: path + "[]", text: text, rules: rules, table: table, column: column, edits: &edits)
            }
        default:
            break
        }
    }

    private func apply(_ target: SyncJSONRule.Target, to node: SyncJSONNode, text: String, table: String, column: String,
                       edits: inout SyncTextEdits) throws {
        switch target {
        case .row(let referenced):
            if let replacement = try id(node, text: text, table: referenced) { edits.replace(node.range, with: replacement) }
        case .evidenceEntity:
            guard case .object(let members) = node.kind,
                  let typeNode = members.first(where: { $0.key == "type" })?.value, case .string(let type) = typeNode.kind,
                  let idNode = members.first(where: { $0.key == "id" })?.value else { return }
            if let referenced = SyncSchema.evidenceEntityTables[type] {
                if let replacement = try id(idNode, text: text, table: referenced) { edits.replace(idNode.range, with: replacement) }
            } else if !SyncSchema.evidenceEntityPassThrough.contains(type) {
                throw SyncReferenceError.unclassifiedType(table: table, column: column, type: type)
            }
        case .forecastFingerprint:
            guard case .string = node.kind else { return }
            let inner = node.range.lowerBound + 1..<node.range.upperBound - 1
            let raw = String(decoding: Array(text.utf8)[inner], as: UTF8.self)
            let translated = try fingerprint(raw)
            if translated != raw { edits.replace(inner, with: translated) }
        }
    }

    /// The replacement token for an id node, or nil to leave it.
    private func id(_ node: SyncJSONNode, text: String, table: String) throws -> String? {
        let token = String(decoding: Array(text.utf8)[node.range], as: UTF8.self)
        switch (direction, node.kind) {
        case (.outgoing, .number):
            guard let localId = Int64(token), localId != 0 else { return nil }
            return try resolver.outgoing(table: table, localId: localId).map { "\"\($0)\"" } ?? "0"
        case (.incoming, .string(let uuid)):
            return String(try resolver.incomingWeak(table: table, uuid: uuid) ?? 0)
        default:
            return nil
        }
    }

    private static let fingerprintPattern = try! NSRegularExpression(
        pattern: #"^([^|]+)\|([^|]+)\|(.*?)(\|account:([^|\[\]]+))?((?:\|\[[^\[\]|]*\|(?:true|false)\|[^\[\]|]*\|[^\[\]|]*\|[^\[\]|]*\])*)$"#,
        options: [.dotMatchesLineSeparators])
    private static let exceptionPattern = try! NSRegularExpression(
        pattern: #"\|\[[^\[\]|]*\|(?:true|false)\|[^\[\]|]*\|[^\[\]|]*\|([^\[\]|]*)\]"#)

    /// `ScenarioApply.fingerprint`'s text, `group|category|…[|account:A][|[…|category]]…`, with its ids
    /// translated ("-" is no id).
    func fingerprint(_ raw: String) throws -> String {
        let whole = NSRange(raw.startIndex..., in: raw)
        guard let match = Self.fingerprintPattern.firstMatch(in: raw, range: whole) else { return raw }
        var edits = SyncTextEdits()
        func translate(_ range: NSRange, table: String) throws {
            guard range.location != NSNotFound, let swiftRange = Range(range, in: raw) else { return }
            let value = String(raw[swiftRange])
            guard value != "-" else { return }
            let replacement: String?
            switch direction {
            case .outgoing:
                guard let localId = Int64(value), localId != 0 else { return }
                replacement = try resolver.outgoing(table: table, localId: localId) ?? "0"
            case .incoming:
                guard Int64(value) == nil else { return }
                replacement = String(try resolver.incomingWeak(table: table, uuid: value) ?? 0)
            }
            if let replacement {
                let start = raw.utf8.distance(from: raw.startIndex, to: swiftRange.lowerBound)
                edits.replace(start..<start + value.utf8.count, with: replacement)
            }
        }
        try translate(match.range(at: 1), table: "forecastGroup")
        try translate(match.range(at: 2), table: "category")
        try translate(match.range(at: 5), table: "account")
        let tail = match.range(at: 6)
        for exception in Self.exceptionPattern.matches(in: raw, range: tail) {
            try translate(exception.range(at: 1), table: "category")
        }
        return edits.applied(to: raw)
    }

    // MARK: Rows recorded by ImportChangeCapture

    /// A row of `table` as `ImportChangeCapture` records it, with every reference the table declares
    /// translated and, going out, its local-only columns removed. Nil for a table that doesn't sync.
    func translateRow(_ text: String, table: String, changeTable: String, column: String) throws -> String? {
        guard let schema = SyncSchema.table(table) else { return nil }
        guard let root = SyncJSONNode.parse(text), case .object(let members) = root.kind else { return text }
        var edits = SyncTextEdits()
        let foreign = schema.foreignKeys.merging(SyncSchema.logicalReferences(of: table)) { first, _ in first }
        let polymorphic = SyncSchema.polymorphicReferences(of: table)
        let json = Dictionary(SyncSchema.jsonReferences(of: table).map { ($0.column, $0) }, uniquingKeysWith: { first, _ in first })
        let bytes = Array(text.utf8)
        for (index, member) in members.enumerated() {
            let value = member.value
            if direction == .outgoing, schema.localOnlyColumns.contains(member.key) {
                // Removed with the comma that joins it to its neighbour.
                if index > 0 {
                    edits.replace(members[index - 1].value.range.upperBound..<value.range.upperBound, with: "")
                } else if members.count > 1 {
                    edits.replace(member.keyStart..<members[1].keyStart, with: "")
                } else {
                    edits.replace(member.keyStart..<value.range.upperBound, with: "")
                }
                continue
            }
            if let referenced = foreign[member.key] ?? (member.key == schema.localIdColumn ? table : nil) {
                if let replacement = try id(value, text: text, table: referenced) { edits.replace(value.range, with: replacement) }
            } else if let reference = polymorphic.first(where: { $0.idColumn == member.key }) {
                guard let typeNode = members.first(where: { $0.key == reference.typeColumn })?.value,
                      case .string(let type) = typeNode.kind else { continue }
                if let referenced = reference.targets[type] {
                    if let replacement = try id(value, text: text, table: referenced) { edits.replace(value.range, with: replacement) }
                } else if case .passThrough(let types) = reference.unlisted, !types.contains(type) {
                    throw SyncReferenceError.unclassifiedType(table: changeTable, column: column, type: type)
                } else if reference.unlisted == .dangling, direction == .outgoing {
                    edits.replace(value.range, with: "0")
                }
            } else if let nested = json[member.key], case .rules(let rules) = nested.content, case .string(let inner) = value.kind {
                let translated = try translate(inner, rules: rules, table: table, column: member.key)
                if translated != inner {
                    let original = String(decoding: bytes[value.range], as: UTF8.self)
                    guard Self.sqliteQuoted(inner) == original else { continue }
                    edits.replace(value.range, with: Self.sqliteQuoted(translated))
                }
            }
        }
        return edits.applied(to: text)
    }

    /// A JSON string as SQLite's `json_object` writes it.
    static func sqliteQuoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

// MARK: Paths, for the guard test

extension SyncJSONNode {
    /// Every number's path (`a.b[]`), and the paths of objects shaped like an evidence entity.
    func numberPaths(_ path: String = "") -> [String] {
        switch kind {
        case .object(let members):
            return members.flatMap { $0.value.numberPaths(path.isEmpty ? $0.key : path + "." + $0.key) }
        case .array(let elements):
            return elements.flatMap { $0.numberPaths(path + "[]") }
        case .number:
            return [path]
        default:
            return []
        }
    }

    /// Every string's path and value.
    func stringPaths(_ path: String = "") -> [(String, String)] {
        switch kind {
        case .object(let members):
            return members.flatMap { $0.value.stringPaths(path.isEmpty ? $0.key : path + "." + $0.key) }
        case .array(let elements):
            return elements.flatMap { $0.stringPaths(path + "[]") }
        case .string(let value):
            return [(path, value)]
        default:
            return []
        }
    }
}
