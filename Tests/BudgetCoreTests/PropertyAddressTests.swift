import XCTest
import GRDB
@testable import BudgetCore

/// A property's address and map location: stored, normalised, synced, and the rule for when the
/// location is looked up again. Invented addresses only.
final class PropertyAddressTests: XCTestCase {
    private var manager: DatabaseManager!
    private var db: DatabaseQueue { manager.dbQueue }

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: nil)
        try manager.migrate()
    }

    private func save(_ property: Property) throws -> Property {
        try db.write { db in
            var property = property
            try Properties.save(db: db, &property)
            return property
        }
    }

    private static let demo = PropertyAddress(lines: "Rua Exemplo 12\n3.º Esq.", postcode: "1000-001", city: "Lisboa", country: "PT")

    func testAddressIsStoredTrimmedWithoutBlankLines() throws {
        var property = Property(name: "Flat A", country: "pt")
        property.setAddress(PropertyAddress(lines: "  Rua Exemplo 12 \n\n 3.º Esq. ", postcode: " ab1 2cd ", city: " Lisboa ", country: "pt"))
        let saved = try save(property)
        let stored = try db.read { db in try Property.fetchOne(db, key: saved.id!) }
        XCTAssertEqual(stored?.address, "Rua Exemplo 12\n3.º Esq.")
        XCTAssertEqual(stored?.postcode, "AB1 2CD")
        XCTAssertEqual(stored?.city, "Lisboa")
        XCTAssertEqual(stored?.country, "PT")
        XCTAssertNil(stored?.location)
        XCTAssertNil(stored?.locationSource)
    }

    func testBlankAddressIsStoredAsNothing() throws {
        var property = Property(name: "Flat A", country: "PT")
        property.setAddress(PropertyAddress(lines: " \n ", postcode: " ", city: "", country: "PT"))
        let saved = try save(property)
        XCTAssertNil(saved.address)
        XCTAssertNil(saved.postcode)
        XCTAssertNil(saved.city)
        XCTAssertTrue(saved.postalAddress.isEmpty)
        XCTAssertNil(saved.postalAddress.searchText)
    }

    func testSearchTextAndDisplayLines() {
        XCTAssertEqual(Self.demo.searchText, "Rua Exemplo 12, 3.º Esq., 1000-001 Lisboa, PT")
        XCTAssertEqual(Self.demo.displayLines, ["Rua Exemplo 12", "3.º Esq.", "1000-001 Lisboa"])
        XCTAssertEqual(PropertyAddress(city: "Lisboa", country: "PT").searchText, "Lisboa, PT")
    }

    func testLocationRoundTripsWithItsSource() throws {
        var property = Property(name: "Flat A", country: "PT")
        property.setAddress(Self.demo)
        let saved = try save(property)
        try db.write { db in
            try Properties.setLocation(db: db, propertyId: saved.id!, PropertyCoordinate(latitude: 38.71, longitude: -9.14), source: .lookedUp)
        }
        var stored = try XCTUnwrap(try db.read { db in try Property.fetchOne(db, key: saved.id!) })
        XCTAssertEqual(stored.location, PropertyCoordinate(latitude: 38.71, longitude: -9.14))
        XCTAssertEqual(stored.locationSource, .lookedUp)

        try db.write { db in
            try Properties.setLocation(db: db, propertyId: saved.id!, PropertyCoordinate(latitude: 38.712, longitude: -9.139), source: .adjusted)
        }
        stored = try XCTUnwrap(try db.read { db in try Property.fetchOne(db, key: saved.id!) })
        XCTAssertEqual(stored.locationSource, .adjusted)
        XCTAssertEqual(stored.latitude, 38.712)

        try db.write { db in try Properties.setLocation(db: db, propertyId: saved.id!, nil, source: .lookedUp) }
        stored = try XCTUnwrap(try db.read { db in try Property.fetchOne(db, key: saved.id!) })
        XCTAssertNil(stored.location)
        XCTAssertNil(stored.locationSource)
        // The address stays when the location goes.
        XCTAssertEqual(stored.city, "Lisboa")
    }

    func testInvalidLocationsAreRefused() throws {
        let saved = try save(Property(name: "Flat A", country: "PT"))
        XCTAssertThrowsError(try db.write { db in
            try Properties.setLocation(db: db, propertyId: saved.id!, PropertyCoordinate(latitude: 91, longitude: 0), source: .adjusted)
        }) { XCTAssertEqual($0 as? PropertyError, .invalidLocation) }
        XCTAssertThrowsError(try save(Property(name: "Flat B", country: "PT", latitude: 38.7))) {
            XCTAssertEqual($0 as? PropertyError, .invalidLocation)
        }
        XCTAssertThrowsError(try db.write { db in
            try Properties.setLocation(db: db, propertyId: 999, PropertyCoordinate(latitude: 1, longitude: 1), source: .adjusted)
        }) { XCTAssertEqual($0 as? PropertyError, .propertyNotFound) }
    }

    func testCoordinateWithoutASourceCountsAsAdjusted() throws {
        let saved = try save(Property(name: "Flat A", country: "PT", latitude: 38.7, longitude: -9.1))
        XCTAssertEqual(saved.locationSource, .adjusted)
        let cleared = try save(Property(id: saved.id, name: "Flat A", country: "PT", locationSource: .lookedUp))
        XCTAssertNil(cleared.locationSource)
    }

    func testSavingWithoutTheAddressClearsIt() throws {
        var property = Property(name: "Flat A", country: "PT")
        property.setAddress(Self.demo)
        property.setLocation(PropertyCoordinate(latitude: 38.7, longitude: -9.1), source: .lookedUp)
        var saved = try save(property)
        saved.setAddress(PropertyAddress(country: "PT"))
        saved.setLocation(nil, source: nil)
        _ = try save(saved)
        let stored = try XCTUnwrap(try db.read { db in try Property.fetchOne(db, key: saved.id!) })
        XCTAssertNil(stored.address)
        XCTAssertNil(stored.postcode)
        XCTAssertNil(stored.city)
        XCTAssertNil(stored.location)
        XCTAssertNil(stored.locationSource)
    }

    func testPropertiesStillSaveOnADatabaseFromBeforeTheAddress() throws {
        let old = try DatabaseManager(path: nil)
        try old.migrate(upTo: "createSync")
        let id = try old.dbQueue.write { db -> Int64 in
            var property = Property(name: "Flat A", country: "PT", notes: "Older schema")
            try Properties.save(db: db, &property)
            property.notes = "Edited"
            try Properties.save(db: db, &property)
            return property.id!
        }
        let stored = try old.dbQueue.read { db in try Property.fetchOne(db, key: id) }
        XCTAssertEqual(stored?.notes, "Edited")
        XCTAssertNil(stored?.address)
    }

    // MARK: When to look the location up

    func testUnchangedAddressKeepsTheLocation() {
        var property = Property(name: "Flat A", country: "PT")
        property.setAddress(Self.demo)
        property.setLocation(PropertyCoordinate(latitude: 38.7, longitude: -9.1), source: .lookedUp)
        // Spacing and case alone aren't a change: no lookup, nothing sent.
        let same = PropertyAddress(lines: "rua exemplo  12\n3.º Esq.\n", postcode: "1000-001", city: "LISBOA", country: "pt")
        XCTAssertEqual(PropertyLocationPlan.plan(old: property, newAddress: same), .keep)
    }

    func testUnchangedAddressWithoutALocationDoesNotLookUpOnSave() {
        var property = Property(name: "Flat A", country: "PT")
        property.setAddress(Self.demo)
        XCTAssertEqual(PropertyLocationPlan.plan(old: property, newAddress: Self.demo), .keep)
    }

    func testChangedAddressIsLookedUpAgain() {
        var property = Property(name: "Flat A", country: "PT")
        property.setAddress(Self.demo)
        property.setLocation(PropertyCoordinate(latitude: 38.7, longitude: -9.1), source: .lookedUp)
        var moved = Self.demo
        moved.lines = "Avenida Exemplo 5"
        XCTAssertEqual(PropertyLocationPlan.plan(old: property, newAddress: moved), .lookUp("Avenida Exemplo 5, 1000-001 Lisboa, PT"))
        XCTAssertEqual(PropertyLocationPlan.plan(old: nil, newAddress: Self.demo), .lookUp(Self.demo.searchText!))
        XCTAssertEqual(PropertyLocationPlan.plan(old: Property(name: "Flat B", country: "PT"), newAddress: Self.demo),
                       .lookUp(Self.demo.searchText!))
    }

    func testChangedAddressAsksBeforeReplacingAnAdjustedPin() {
        var property = Property(name: "Flat A", country: "PT")
        property.setAddress(Self.demo)
        property.setLocation(PropertyCoordinate(latitude: 38.7, longitude: -9.1), source: .adjusted)
        var moved = Self.demo
        moved.postcode = "1100-002"
        XCTAssertEqual(PropertyLocationPlan.plan(old: property, newAddress: moved), .askBeforeReplacing("Rua Exemplo 12, 3.º Esq., 1100-002 Lisboa, PT"))
    }

    func testRemovedAddressDropsOnlyALookedUpLocation() {
        var property = Property(name: "Flat A", country: "PT")
        property.setAddress(Self.demo)
        property.setLocation(PropertyCoordinate(latitude: 38.7, longitude: -9.1), source: .lookedUp)
        let none = PropertyAddress(country: "PT")
        XCTAssertEqual(PropertyLocationPlan.plan(old: property, newAddress: none), .clearLookedUp)
        property.locationSource = .adjusted
        XCTAssertEqual(PropertyLocationPlan.plan(old: property, newAddress: none), .keep)
        XCTAssertEqual(PropertyLocationPlan.plan(old: nil, newAddress: none), .keep)
    }

    // MARK: Sync

    func testAddressAndLocationSync() throws {
        let table = try XCTUnwrap(SyncSchema.tables.first { $0.name == "property" })
        for column in ["address", "postcode", "city", "latitude", "longitude", "locationSource"] {
            XCTAssertTrue(table.syncedColumns.contains(column), column)
        }
        XCTAssertEqual(SyncSchema.version, 5)
    }
}
