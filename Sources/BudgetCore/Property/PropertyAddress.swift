import Foundation
import GRDB

/// How a property's map location was placed.
public enum PropertyLocationSource: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    /// Found from the address with the geocoder (Apple Maps).
    case lookedUp
    /// Placed or moved by hand on the map.
    case adjusted
}

/// A property's address as one value: the street lines, postcode, city and the property's country.
/// Portuguese addresses are the usual case ("Rua …, 3.º Esq.", "1000-001", "Lisboa", "PT"), but nothing
/// here assumes a country's format.
public struct PropertyAddress: Equatable, Sendable {
    /// Street, number, floor, door: one per line.
    public var lines: String
    public var postcode: String
    public var city: String
    /// ISO 3166-1 alpha-2, upper case.
    public var country: String

    public init(lines: String = "", postcode: String = "", city: String = "", country: String = "") {
        self.lines = lines
        self.postcode = postcode
        self.city = city
        self.country = country
    }

    public init(_ property: Property) {
        self.init(lines: property.address ?? "", postcode: property.postcode ?? "", city: property.city ?? "",
                  country: property.country)
    }

    /// The street lines, trimmed, without blank ones.
    public var streetLines: [String] {
        lines.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Nothing entered besides the country (which every property has).
    public var isEmpty: Bool {
        streetLines.isEmpty && Self.trimmed(postcode) == nil && Self.trimmed(city) == nil
    }

    /// The text sent to the geocoder: "Rua A 1, 2.º, 1000-001 Lisboa, PT". Nil when there is nothing to find.
    public var searchText: String? {
        guard !isEmpty else { return nil }
        var parts = streetLines
        let place = [Self.trimmed(postcode), Self.trimmed(city)].compactMap { $0 }.joined(separator: " ")
        if !place.isEmpty { parts.append(place) }
        if let country = Self.trimmed(country) { parts.append(country.uppercased()) }
        return parts.joined(separator: ", ")
    }

    /// The address as shown, one line per row: the street lines, then "postcode city".
    public var displayLines: [String] {
        var rows = streetLines
        let place = [Self.trimmed(postcode), Self.trimmed(city)].compactMap { $0 }.joined(separator: " ")
        if !place.isEmpty { rows.append(place) }
        return rows
    }

    /// Whether `other` is a different address once spacing, blank lines and letter case are ignored:
    /// what decides whether the location has to be found again.
    public func differs(from other: PropertyAddress) -> Bool {
        comparisonKey != other.comparisonKey
    }

    private var comparisonKey: String {
        let parts = streetLines + [postcode, city, country].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }.joined(separator: "\n")
    }

    static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// A point on the map.
public struct PropertyCoordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public extension Property {
    var postalAddress: PropertyAddress { PropertyAddress(self) }

    /// The stored location, when there is one.
    var location: PropertyCoordinate? {
        guard let latitude, let longitude else { return nil }
        return PropertyCoordinate(latitude: latitude, longitude: longitude)
    }

    /// Sets the address fields from `address` (its country becomes the property's country).
    mutating func setAddress(_ address: PropertyAddress) {
        let lines = address.streetLines
        self.address = lines.isEmpty ? nil : lines.joined(separator: "\n")
        postcode = PropertyAddress.trimmed(address.postcode)
        city = PropertyAddress.trimmed(address.city)
        country = address.country
    }

    /// Stores `coordinate` (or none) and how it was placed.
    mutating func setLocation(_ coordinate: PropertyCoordinate?, source: PropertyLocationSource?) {
        latitude = coordinate?.latitude
        longitude = coordinate?.longitude
        locationSource = coordinate == nil ? nil : source
    }
}

/// What saving an edited address means for the stored map location. The app geocodes only on `.lookUp`
/// and asks only on `.askBeforeReplacing`; nothing changes, and nothing is sent anywhere, on `.keep`.
public enum PropertyLocationPlan: Equatable, Sendable {
    /// The address is the same (or there was no address and there still is none): keep the location as it is.
    case keep
    /// The address changed and the location was looked up or never found: look it up again.
    case lookUp(String)
    /// The address changed but the pin was placed by hand: ask before replacing it.
    case askBeforeReplacing(String)
    /// The address was removed: drop a looked-up location (an adjusted pin is the user's and stays).
    case clearLookedUp

    public static func plan(old: Property?, newAddress: PropertyAddress) -> PropertyLocationPlan {
        let oldAddress = old.map(PropertyAddress.init) ?? PropertyAddress()
        let hasLocation = old?.location != nil
        guard newAddress.differs(from: oldAddress) else { return .keep }
        guard let text = newAddress.searchText else {
            return old?.locationSource == .lookedUp && hasLocation ? .clearLookedUp : .keep
        }
        if hasLocation, old?.locationSource == .adjusted { return .askBeforeReplacing(text) }
        return .lookUp(text)
    }
}

public extension Properties {
    /// Stores the property's map location (or clears it with nil). A coordinate needs a source.
    static func setLocation(db: Database, propertyId: Int64, _ coordinate: PropertyCoordinate?,
                            source: PropertyLocationSource) throws {
        guard var property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        if let coordinate, !coordinate.isValid { throw PropertyError.invalidLocation }
        property.setLocation(coordinate, source: source)
        try writeAddressColumns(db: db, property)
    }

    /// Whether giving a property `address` changes its country (the one address field the tax figures read).
    static func addressChangesCountry(_ address: PropertyAddress, of property: Property) -> Bool {
        let normalized = { (country: String) in country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        return normalized(address.country) != normalized(property.country)
    }

    /// Edit address's save: the stored property (read here, so nothing else in it is overwritten) takes `address`'s
    /// street lines, postcode and city, and its map location is cleared when `clearingLocation`. Its country changes
    /// only with `includingCountry`: without it the save moves no tax figure (street, postcode, city and the map
    /// location are read by none), so it needs no filed-year check.
    static func saveAddress(db: Database, propertyId: Int64, _ address: PropertyAddress, clearingLocation: Bool,
                            includingCountry: Bool) throws {
        guard var property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        let country = property.country
        property.setAddress(address)
        if !includingCountry { property.country = country }
        if clearingLocation { property.setLocation(nil, source: nil) }
        try save(db: db, &property)
    }

    /// Writes the address and location columns as they are, NULLs included (`Property.encode` leaves nil ones
    /// out). Does nothing on a database migrated only up to before they existed.
    public static func writeAddressColumns(db: Database, _ property: Property) throws {
        guard let id = property.id, try db.columns(in: "property").contains(where: { $0.name == "locationSource" }) else { return }
        try db.execute(sql: """
            UPDATE property SET address = ?, postcode = ?, city = ?, latitude = ?, longitude = ?, locationSource = ?
            WHERE id = ? AND (address IS NOT ? OR postcode IS NOT ? OR city IS NOT ? OR latitude IS NOT ? OR longitude IS NOT ?
                              OR locationSource IS NOT ?)
            """, arguments: [property.address, property.postcode, property.city, property.latitude, property.longitude,
                             property.locationSource, id,
                             property.address, property.postcode, property.city, property.latitude, property.longitude,
                             property.locationSource])
    }
}

func registerPropertyAddressMigration(_ migrator: inout DatabaseMigrator) {
    // Only adds nullable columns: existing rows keep every value and have no address yet.
    migrator.registerMigration("addPropertyAddressAndLocation") { db in
        try db.alter(table: "property") { t in
            t.add(column: "address", .text)
            t.add(column: "postcode", .text)
            t.add(column: "city", .text)
            t.add(column: "latitude", .double)
            t.add(column: "longitude", .double)
            t.add(column: "locationSource", .text)
        }
    }
}
