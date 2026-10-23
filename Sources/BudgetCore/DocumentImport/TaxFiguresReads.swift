import CryptoKit
import Foundation
import GRDB
import SQLite3

/// What a `TaxFigures` snapshot read: each statement it ran (read-only, its arguments written
/// into its SQL) with a digest of the rows it returned. The snapshot is worked out from what its
/// statements return and nothing else of the database, so when every one of them returns the
/// same rows in a later state, the snapshot there is the same one: the filed-year guard then
/// skips taking it again (`FiledYearGuard`), the slow part of checking an item.
///
/// Recording gives nil — the snapshot is always taken — when a statement can't be replayed
/// as it ran: it writes, its SQL couldn't be written out with its arguments, or an argument is
/// a real number (written with 15 digits, which may not be the value bound).
struct TaxFiguresReads {
    /// Each statement (prepared on the connection that recorded it) with its digest, in the
    /// order first run. Only used inside the database access that recorded it.
    private var statements: [(statement: Statement, digest: SHA256Digest)] = []
    private var indexes: [String: Int] = [:]

    /// How many statements were recorded.
    var count: Int { statements.count }

    /// `body` run with every statement it runs recorded (a statement recorded before is kept
    /// once), and the indexes of the statements it ran; their digests are taken right after it,
    /// in the same state. Nil indexes: a statement can't be replayed — what `body` read can't be vouched for.
    mutating func record<T>(db: Database, _ body: () throws -> T) throws -> (T, Set<Int>?) {
        let recorder = Recorder()
        db.trace(options: .statement) { event in
            if case .statement(let statement) = event { recorder.add(statement.expandedSQL) }
        }
        let value: T
        do {
            defer { db.trace(options: []) }
            value = try body()
        }
        var read = Set<Int>()
        for sql in recorder.sqls {
            if let index = indexes[sql] {
                read.insert(index)
                continue
            }
            guard Self.replayable(sql) else { return (value, nil) }
            let statement = try db.makeStatement(sql: sql)
            guard statement.isReadonly, (try? statement.validateArguments([])) != nil, let digest = Self.digest(statement) else {
                return (value, nil)
            }
            indexes[sql] = statements.count
            read.insert(statements.count)
            statements.append((statement, digest))
        }
        return (value, read)
    }

    /// The statements that return something else now (or can't run any more). `written`: the
    /// only tables written since they were recorded (`writtenTables`) — a statement reading
    /// none of them returns what it did, and isn't run again; nil: every statement is.
    func changed(written: Set<String>? = nil) -> Set<Int> {
        var changed = Set<Int>()
        for (index, (statement, recorded)) in statements.enumerated() {
            if let written, !Self.reads(statement, anyOf: written) { continue }
            if Self.digest(statement) != recorded { changed.insert(index) }
        }
        return changed
    }

    /// Whether the statement reads one of `tables` (one whose reads SQLite doesn't tell — a
    /// pragma, a function of no table — counts as reading them all).
    private static func reads(_ statement: Statement, anyOf tables: Set<String>) -> Bool {
        let region = statement.databaseRegion
        guard !region.isEmpty else { return true }
        return tables.contains { region.isModified(byEventsOfKind: .insert(tableName: $0)) }
    }

    /// `body` run, and the tables it wrote a row of, as SQLite reports each row written. Nil when
    /// that can't be told: a write wasn't reported (fewer reports than rows SQLite counts as
    /// changed — a table emptied at once, a table without rowids), the schema changed, or
    /// something else listens to the reports.
    ///
    /// Limitation: it takes SQLite's single update hook for the duration of `body` and clears it after,
    /// rather than restoring a hook installed before. GRDB installs its own hook only while a statement it
    /// observes runs, so none is installed between statements; one that is (`previous != nil`) makes this
    /// return nil (callers replay every statement) and is cleared. Statements of `body` that GRDB observes
    /// (an active `ValueObservation`, say) replace this hook while they run, which shows as missed rows: nil.
    static func writtenTables(db: Database, _ body: () throws -> Void) throws -> Set<String>? {
        final class Written {
            var tables: Set<String> = []
            var rows = 0
        }
        let written = Written()
        let schema = try db.schemaVersion()
        let changes = db.totalChangesCount
        let context = Unmanaged.passUnretained(written).toOpaque()
        let previous = sqlite3_update_hook(db.sqliteConnection, { context, _, _, table, _ in
            let written = Unmanaged<Written>.fromOpaque(context!).takeUnretainedValue()
            written.rows += 1
            if let table { written.tables.insert(String(cString: table)) }
        }, context)
        do {
            defer { sqlite3_update_hook(db.sqliteConnection, nil, nil) }
            try withExtendedLifetime(written) { try body() }
        }
        guard previous == nil, try db.schemaVersion() == schema, written.rows == db.totalChangesCount - changes else { return nil }
        return written.tables
    }

    /// The statements traced, each once, in the order first run.
    private final class Recorder {
        private(set) var sqls: [String] = []
        private var seen: Set<String> = []

        func add(_ sql: String) {
            if seen.insert(sql).inserted { sqls.append(sql) }
        }
    }

    /// Whether the SQL as traced is the statement that ran: written out (a trigger's comment or
    /// an empty expansion isn't), and with no real-number literal outside quotes.
    static func replayable(_ sql: String) -> Bool {
        guard !sql.isEmpty, !sql.hasPrefix("--") else { return false }
        return !hasRealLiteral(sql)
    }

    /// Whether `sql` holds a number with a decimal point or an exponent outside quotes
    /// (`'…'` strings, `"…"`, `` `…` `` and `[…]` identifiers).
    static func hasRealLiteral(_ sql: String) -> Bool {
        let chars = Array(sql.unicodeScalars)
        func isWordChar(_ c: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(c) || c == "_" || c == "$"
        }
        func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "'", "\"", "`", "[":
                let close: Unicode.Scalar = c == "[" ? "]" : c
                i += 1
                while i < chars.count {
                    if chars[i] == close {
                        // A doubled quote is one quote inside the string.
                        if close != "]", i + 1 < chars.count, chars[i + 1] == close { i += 2; continue }
                        break
                    }
                    i += 1
                }
                i += 1
            case _ where isDigit(c) || (c == "." && i + 1 < chars.count && isDigit(chars[i + 1])):
                if i > 0, isWordChar(chars[i - 1]) {
                    i += 1
                    continue
                }
                var j = i
                var real = false
                while j < chars.count {
                    let d = chars[j]
                    if isDigit(d) {
                        j += 1
                    } else if d == "." {
                        real = true
                        j += 1
                    } else if d == "e" || d == "E" {
                        real = true
                        j += 1
                        if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                    } else if (d == "x" || d == "X") && j == i + 1 && c == "0" {
                        // A hexadecimal integer: its letters aren't exponents.
                        j += 1
                        while j < chars.count, isWordChar(chars[j]) { j += 1 }
                        break
                    } else {
                        break
                    }
                }
                if real { return true }
                i = j
            default:
                i += 1
            }
        }
        return false
    }

    /// The statement's rows, every value with its storage class, digested (read from SQLite as
    /// stored, not decoded). Nil: it failed.
    private static func digest(_ statement: Statement) -> SHA256Digest? {
        let handle = statement.sqliteStatement
        sqlite3_reset(handle)
        defer { sqlite3_reset(handle) }
        var hasher = SHA256()
        func add(_ tag: UInt8, _ value: Int64) {
            withUnsafeBytes(of: value.littleEndian) { hasher.update(data: [tag] + Array($0)) }
        }
        func add(_ tag: UInt8, bytes: UnsafeRawPointer?, count: Int32) {
            add(tag, Int64(count))
            if let bytes, count > 0 { hasher.update(bufferPointer: UnsafeRawBufferPointer(start: bytes, count: Int(count))) }
        }
        let columns = sqlite3_column_count(handle)
        while true {
            let code = sqlite3_step(handle)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { return nil }
            add(0xA0, Int64(columns))
            for column in 0..<columns {
                switch sqlite3_column_type(handle, column) {
                case SQLITE_NULL: add(0xB0, 0)
                case SQLITE_INTEGER: add(0xB1, sqlite3_column_int64(handle, column))
                case SQLITE_FLOAT: add(0xB2, Int64(bitPattern: sqlite3_column_double(handle, column).bitPattern))
                case SQLITE_TEXT:
                    let text = sqlite3_column_text(handle, column)
                    add(0xB3, bytes: text.map(UnsafeRawPointer.init), count: sqlite3_column_bytes(handle, column))
                default:
                    let blob = sqlite3_column_blob(handle, column)
                    add(0xB4, bytes: blob, count: sqlite3_column_bytes(handle, column))
                }
            }
        }
        add(0xA1, 0)
        return hasher.finalize()
    }
}
