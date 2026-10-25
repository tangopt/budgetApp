import Foundation
import MachO
import MangoSync

/// Whether this build is signed for Mango's iCloud container. `CKContainer` traps without the entitlement, and an
/// unsigned build (scripts/build-phone.sh, the snapshot build) has none, so nothing CloudKit runs without this check.
/// The decision is `CloudKitAvailability`'s (tested): the build's `MangoCloudKit` flag, plus, on the simulator, the
/// entitlements the executable carries in its `__TEXT,__entitlements` section. iOS has no `SecTask`, and a device's
/// TestFlight or App Store install has no provisioning profile to read, so a device goes by the flag.
enum PhoneEntitlements {
    static func hasCloudKitContainer() -> Bool {
        let flag = Bundle.main.object(forInfoDictionaryKey: CloudKitAvailability.infoKey) as? String
        #if targetEnvironment(simulator)
        return CloudKitAvailability.isAvailable(buildFlag: flag, isSimulator: true, simulatorEntitlements: simulatorEntitlements())
        #else
        return CloudKitAvailability.isAvailable(buildFlag: flag, isSimulator: false, simulatorEntitlements: nil)
        #endif
    }

    #if targetEnvironment(simulator)
    /// The simulator build's entitlements, or nil when it has none (unsigned) or they can't be read.
    private static func simulatorEntitlements() -> [String: Any]? {
        guard let data = executableSection("__TEXT", "__entitlements") else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The main executable's section `segment,section`, copied.
    private static func executableSection(_ segment: String, _ section: String) -> Data? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return nil }
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index),
                  URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath().path == executable,
                  let header = _dyld_get_image_header(index) else { continue }
            var size: UInt = 0
            let bytes = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
                getsectiondata($0, segment, section, &size)
            }
            guard let bytes, size > 0 else { return nil }
            return Data(bytes: bytes, count: Int(size))
        }
        return nil
    }
    #endif
}
