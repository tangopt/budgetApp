import Foundation

/// Whether an iOS build may make a `CKContainer` (which traps without the container entitlement). Decided from the
/// build, failing closed (plan step 4 Task 12, fix round 1):
/// - `buildFlag`: Info.plist's `MangoCloudKit`, "YES" only in a team-signed build with signing allowed
///   (Config/SigningPhone.xcconfig derives it from DEVELOPMENT_TEAM and CODE_SIGNING_ALLOWED); anything else is no.
/// - On the simulator the build must also carry the container in its entitlements (the executable's
///   `__TEXT,__entitlements` section), since a simulator build can be signed without them.
/// A device never reads `embedded.mobileprovision`: TestFlight and App Store installs don't have one.
public enum CloudKitAvailability {
    public static let infoKey = "MangoCloudKit"
    public static let containersEntitlement = "com.apple.developer.icloud-container-identifiers"

    public static func isAvailable(buildFlag: String?, isSimulator: Bool, simulatorEntitlements: [String: Any]?,
                                   container: String = CloudKitTransport.containerIdentifier) -> Bool {
        guard buildFlag == "YES" else { return false }
        guard isSimulator else { return true }
        return (simulatorEntitlements?[containersEntitlement] as? [String])?.contains(container) ?? false
    }
}
