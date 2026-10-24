import CloudKit
import XCTest
import BudgetCore
@testable import MangoSync

/// The shared CloudKit target's surface, pinned without reaching CloudKit or the Keychain: nothing here makes a
/// `CKContainer`, a `CloudKitTransport` or a Keychain call.
final class MangoSyncSurfaceTests: XCTestCase {
    func testContainerAndScopes() {
        XCTAssertEqual(CloudKitTransport.containerIdentifier, "iCloud.ubberninja.mango")
        XCTAssertEqual(CloudKitTransport.demoKeyScope, "iCloud.ubberninja.mango/demo")
        XCTAssertNotEqual(CloudKitTransport.demoKeyScope, CloudKitTransport.containerIdentifier)
    }

    func testKeychainServiceIsUnchanged() {
        XCTAssertEqual(KeychainSyncKeyStore.service, "ubberninja.mango.sync")
    }

    func testKeyStoreIsASyncKeyStore() {
        let store: any SyncKeyStore = KeychainSyncKeyStore(container: CloudKitTransport.demoKeyScope)
        XCTAssertTrue(store is KeychainSyncKeyStore)
    }

    func testAccountStatusMapping() {
        XCTAssertEqual(CloudKitAccountStatus.status(for: .available), .available)
        XCTAssertEqual(CloudKitAccountStatus.status(for: .noAccount), .noAccount)
        XCTAssertEqual(CloudKitAccountStatus.status(for: .restricted), .restricted)
        XCTAssertEqual(CloudKitAccountStatus.status(for: .couldNotDetermine), .couldNotDetermine)
        // Temporarily unavailable (signed in, but iCloud needs attention): not usable yet, not "no account".
        XCTAssertEqual(CloudKitAccountStatus.status(for: .temporarilyUnavailable), .couldNotDetermine)
    }
}
