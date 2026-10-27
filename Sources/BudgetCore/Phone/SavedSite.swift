import Foundation

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

    public var errorDescription: String? {
        switch self {
        case .notHTTPS: "Only secure web addresses (https) can be saved or opened."
        case .invalid: "That isn't a web address Mango can open."
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
}

/// The sites saved on this device only (a UserDefaults suite). Starts empty; "Add site" adds. A stored site whose
/// address no longer passes `SavedSite.validate` is left out.
public struct LocalSavedSiteStore: SavedSiteStore {
    public static let defaultSuite = "ubberninja.mango.savedSites"
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
