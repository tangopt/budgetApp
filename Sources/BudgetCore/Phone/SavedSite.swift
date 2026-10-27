import Foundation
import GRDB

/// What a saved site is for: its icon and where it is offered.
public enum SavedSiteKind: String, Codable, CaseIterable, Sendable {
    case bank, utility, tax, condominium, other

    public var title: String {
        switch self {
        case .bank: "Bank"
        case .utility: "Utility"
        case .tax: "Tax"
        case .condominium: "Condominium"
        case .other: "Other"
        }
    }
}

/// Why a typed address was refused.
public enum SavedSiteError: Error, Equatable, LocalizedError {
    /// Not a secure web address: another scheme (`http:`, `javascript:`, `file:`...).
    case notHTTPS
    /// Not an address at all (empty, no host, a name and password inside it...).
    case invalid
    /// The household already has a site at this address.
    case alreadySaved

    public var errorDescription: String? {
        switch self {
        case .notHTTPS: "Only secure web addresses (https) can be saved or opened."
        case .invalid: "That isn't a web address Mango can open."
        case .alreadySaved: "That site is already saved."
        }
    }
}

/// A site the iPad's built-in browser opens from its strip (step 10, Task 5): a bank, a utility provider, the tax
/// portal. Only `https` addresses, checked when saved and again when loaded. Mango keeps the address only, never a
/// password or a cookie.
public struct SavedSite: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var kind: SavedSiteKind
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, url: URL, kind: SavedSiteKind, sortOrder: Int) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
        self.sortOrder = sortOrder
    }

    /// The address `text` names, if it is a secure web address: `https` with a host, and no name or password inside it
    /// (`https://bank.example@other.example` reads as the bank but opens the other). A bare host or path
    /// (`example.com/login`) gets `https://`; any other scheme (`http:`, `javascript:`, `file:`, `data:`) is refused.
    public static func validate(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { throw SavedSiteError.invalid }
        let candidate = hasScheme(trimmed) ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: candidate), let scheme = components.scheme else { throw SavedSiteError.invalid }
        guard scheme.lowercased() == "https" else { throw SavedSiteError.notHTTPS }
        guard let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              !host.hasPrefix("."), !host.hasPrefix("-")
        else { throw SavedSiteError.invalid }
        components.scheme = "https"
        components.host = host.lowercased()
        guard let url = components.url else { throw SavedSiteError.invalid }
        return url
    }

    /// Whether `text` starts with a scheme (`https://`, `javascript:`, `mailto:`), not a host with a port
    /// (`example.com:8443`).
    private static func hasScheme(_ text: String) -> Bool {
        if text.contains("://") { return true }
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon]
        let rest = text[text.index(after: colon)...]
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return false }
        // `host:port`: digits after the colon, and a dot in the host.
        let port = rest.prefix { $0 != "/" }
        return !(scheme.contains(".") && !port.isEmpty && port.allSatisfy(\.isNumber))
    }
}

/// Where saved sites are kept.
public protocol SavedSiteStore: Sendable {
    /// Every site, in strip order.
    func all() async throws -> [SavedSite]
    /// Adds `site` or replaces the one with its id. Throws `SavedSiteError` for an address that isn't https.
    func save(_ site: SavedSite) async throws
    func remove(id: UUID) async throws
    /// Whether adding and removing sites is offered (controls are hidden, not disabled, without it).
    func canEdit() async -> Bool
}

extension SavedSiteStore {
    public func canEdit() async -> Bool { true }
}

/// The sites saved on this device only (a UserDefaults suite). Starts empty; "Add site" adds. A stored site whose
/// address no longer passes `SavedSite.validate` is left out.
public struct LocalSavedSiteStore: SavedSiteStore {
    public static let defaultSuite = "ubberninja.mango.savedSites"
    /// Demo data's sites (step 10): kept apart from the device's own, never adopted by the household, cleared on each purge.
    public static let demoSuite = "ubberninja.mango.savedSites.demo"
    static let key = "savedSites"
    private static let lock = NSLock()

    public let suiteName: String

    public init(suiteName: String = LocalSavedSiteStore.defaultSuite) {
        self.suiteName = suiteName
    }

    public func all() async throws -> [SavedSite] {
        Self.lock.withLock { read() }
    }

    public func save(_ site: SavedSite) async throws {
        var site = site
        site.url = try SavedSite.validate(site.url.absoluteString)
        try Self.lock.withLock {
            var sites = read()
            if let index = sites.firstIndex(where: { $0.id == site.id }) {
                sites[index] = site
            } else {
                sites.append(site)
            }
            try write(sites)
        }
    }

    public func remove(id: UUID) async throws {
        try Self.lock.withLock { try write(read().filter { $0.id != id }) }
    }

    /// Forgets every site saved here.
    public func removeAll() {
        Self.lock.withLock { defaults?.removeObject(forKey: Self.key) }
    }

    private var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    private func read() -> [SavedSite] {
        guard let data = defaults?.data(forKey: Self.key),
              let sites = try? JSONDecoder().decode([SavedSite].self, from: data) else { return [] }
        return sites.filter { (try? SavedSite.validate($0.url.absoluteString)) != nil }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    private func write(_ sites: [SavedSite]) throws {
        defaults?.set(try JSONEncoder().encode(sites), forKey: Self.key)
    }
}

/// The household's saved sites (step 10, Task 6): the synced `savedSite` table, so every device of the household shows
/// the same strip. Property's records: adding or removing one needs Edit on Property, written through `DeviceWriter`
/// (an iPad without it is refused, nothing saved, nothing queued; the Mac re-validates what arrives). A site's id is
/// its record's UUID. Addresses are checked when saved and again when read: a row whose address isn't https (one
/// another device sent) is left out, never loaded. Only the name, address, kind and order are kept: no password, no
/// cookie, no account.
public struct GRDBSavedSiteStore: SavedSiteStore {
    public static let table = "savedSite"
    private let writer: DeviceWriter
    private let reader: any DatabaseReader

    public init(writer: DeviceWriter, reader: any DatabaseReader) {
        self.writer = writer
        self.reader = reader
    }

    public func all() async throws -> [SavedSite] {
        try await reader.read { db in try Self.read(db: db) }
    }

    /// Every site `db` holds whose address passes `SavedSite.validate`, in strip order.
    public static func read(db: Database) throws -> [SavedSite] {
        try Row.fetchAll(db, sql: """
            SELECT s.name, s.url, s.kind, s.sortOrder, r.uuid FROM savedSite s
            JOIN syncRecord r ON r.tableName = 'savedSite' AND r.localId = s.id
            ORDER BY s.sortOrder, s.name, s.id
            """).compactMap { row -> SavedSite? in
            guard let uuid = UUID(uuidString: row["uuid"]), let url = try? SavedSite.validate(row["url"]) else { return nil }
            // A kind a newer build added reads as Other.
            let kind = SavedSiteKind(rawValue: row["kind"]) ?? .other
            return SavedSite(id: uuid, name: row["name"], url: url, kind: kind, sortOrder: row["sortOrder"])
        }
    }

    public func save(_ site: SavedSite) async throws {
        var site = site
        site.url = try SavedSite.validate(site.url.absoluteString)
        let saving = site
        try await writer.writeCheckingFiledYears(.property, edit: "Save site", scope: FiledYearEditCheck.Scope()) { db in
            try Self.save(saving, db: db)
        }
    }

    public func remove(id: UUID) async throws {
        try await writer.writeCheckingFiledYears(.property, edit: "Remove site", scope: FiledYearEditCheck.Scope()) { db in
            guard let localId = try SyncRecordStore.localId(table: Self.table, uuid: Self.recordName(id), db: db) else { return }
            try db.execute(sql: "DELETE FROM savedSite WHERE id = ?", arguments: [localId])
        }
    }

    public func canEdit() async -> Bool {
        await writer.canEdit(.property)
    }

    /// Updates the site with `site.id`, or inserts it under that id. `site.url` is already validated. An address another
    /// site has is refused (`alreadySaved`).
    static func save(_ site: SavedSite, db: Database) throws {
        let name = recordName(site.id)
        let existing = try SyncRecordStore.localId(table: table, uuid: name, db: db)
        let url = site.url.absoluteString
        if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM savedSite WHERE url = ? AND id IS NOT ?)",
                             arguments: [url, existing]) == true {
            throw SavedSiteError.alreadySaved
        }
        if let existing {
            try db.execute(sql: "UPDATE savedSite SET name = ?, url = ?, kind = ?, sortOrder = ? WHERE id = ?",
                           arguments: [site.name, url, site.kind.rawValue, site.sortOrder, existing])
            return
        }
        try db.execute(sql: "INSERT INTO savedSite(name, url, kind, sortOrder) VALUES (?, ?, ?, ?)",
                       arguments: [site.name, url, site.kind.rawValue, site.sortOrder])
        // The record takes the site's id, so the site the caller holds is the one saved (the tracking triggers gave it a
        // random UUID; nothing has seen it yet). An id some other record has or had keeps the triggers' UUID.
        let localId = db.lastInsertedRowID
        guard let given = try SyncRecordStore.existingUUID(table: table, localId: localId, db: db),
              try Bool.fetchOne(db, sql: """
                  SELECT NOT EXISTS (SELECT 1 FROM syncRecord WHERE uuid = ?) AND NOT EXISTS (SELECT 1 FROM syncTombstone WHERE uuid = ?)
                  """, arguments: [name, name]) == true
        else { return }
        try db.execute(sql: "UPDATE syncRecord SET uuid = ? WHERE uuid = ?", arguments: [name, given])
        try db.execute(sql: "UPDATE syncPending SET uuid = ? WHERE uuid = ?", arguments: [name, given])
    }

    /// The record name of the site with `id`: the UUID in its canonical lowercase form.
    static func recordName(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

/// The sites saved on this device before they were the household's (step 10, Task 5): moved into the household's
/// store once, then forgotten here.
public enum SavedSiteAdoption {
    /// Saves each of `local`'s sites into `store` (after the store's own, in their order; an address the store has already
    /// is skipped) and empties `local`. True when nothing is left to adopt. A refused write (no Edit on Property, the
    /// device not linked yet) leaves `local` as it is, to try again later.
    @discardableResult
    public static func adopt(from local: LocalSavedSiteStore, into store: any SavedSiteStore) async -> Bool {
        guard let sites = try? await local.all(), !sites.isEmpty else { return true }
        do {
            let saved = try await store.all()
            var known = Set(saved.map(\.url))
            var next = (saved.map(\.sortOrder).max() ?? -1) + 1
            for site in sites where !known.contains(site.url) {
                var adopted = site
                adopted.sortOrder = next
                do {
                    try await store.save(adopted)
                } catch SavedSiteError.alreadySaved {
                    continue
                }
                known.insert(site.url)
                next += 1
            }
            local.removeAll()
            return true
        } catch {
            return false
        }
    }
}

/// Step 10 Task 6: the household's saved sites. Name, address, kind and strip order only; no CHECK on `kind`, so a kind
/// a newer build adds still applies here (it reads as Other). One row per address.
func registerSavedSiteMigration(_ migrator: inout DatabaseMigrator) {
    // Only adds a table.
    migrator.registerMigration("createSavedSite") { db in
        try db.create(table: "savedSite") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("url", .text).notNull().unique()
            t.column("kind", .text).notNull()
            t.column("sortOrder", .integer).notNull().defaults(to: 0)
        }
    }
}
