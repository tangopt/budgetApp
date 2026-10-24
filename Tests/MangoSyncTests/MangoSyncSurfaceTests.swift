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

    /// `--sync-demo` (Mac and iPhone) keeps its keys under the demo scope; only a real-data sync uses the plain one.
    func testKeyScopeForTheDemoIsNeverThePlainOne() {
        XCTAssertEqual(CloudKitTransport.keyScope(demo: true), CloudKitTransport.demoKeyScope)
        XCTAssertEqual(CloudKitTransport.keyScope(demo: false), CloudKitTransport.containerIdentifier)
    }

    /// Whether the phone may make a `CKContainer` (fix round 1, I1): only a team-signed build says so (Info.plist's
    /// `MangoCloudKit` = YES, set by Config/SigningPhone.xcconfig), and a simulator build must also carry the
    /// container in its entitlements. Anything else fails closed. A device never reads a provisioning profile
    /// (TestFlight and App Store installs have none).
    func testCloudKitAvailabilityFailsClosed() {
        let container = CloudKitTransport.containerIdentifier
        let signed: [String: Any] = [CloudKitAvailability.containersEntitlement: [container]]
        let other: [String: Any] = [CloudKitAvailability.containersEntitlement: ["iCloud.example.other"]]
        // Device: the build flag decides.
        XCTAssertTrue(CloudKitAvailability.isAvailable(buildFlag: "YES", isSimulator: false, simulatorEntitlements: nil))
        for flag in [nil, "", "NO", "yes", "$(MANGO_CLOUDKIT)"] {
            XCTAssertFalse(CloudKitAvailability.isAvailable(buildFlag: flag, isSimulator: false, simulatorEntitlements: signed), "\(String(describing: flag))")
        }
        // Simulator: the flag and the entitlement.
        XCTAssertTrue(CloudKitAvailability.isAvailable(buildFlag: "YES", isSimulator: true, simulatorEntitlements: signed))
        XCTAssertFalse(CloudKitAvailability.isAvailable(buildFlag: "YES", isSimulator: true, simulatorEntitlements: nil))
        XCTAssertFalse(CloudKitAvailability.isAvailable(buildFlag: "YES", isSimulator: true, simulatorEntitlements: other))
        XCTAssertFalse(CloudKitAvailability.isAvailable(buildFlag: "NO", isSimulator: true, simulatorEntitlements: signed))
        XCTAssertEqual(CloudKitAvailability.infoKey, "MangoCloudKit")
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
