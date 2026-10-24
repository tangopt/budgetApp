import Foundation
import MachO
import MangoSync

/// Whether this build is signed for Mango's iCloud container. `CKContainer` traps without the entitlement, and an
/// unsigned simulator build (scripts/build-phone.sh, the snapshot build) has none, so nothing CloudKit runs without
/// this check. iOS has no `SecTask` API: a simulator build carries its entitlements in the executable's
/// `__TEXT,__entitlements` section; a device build in its provisioning profile.
enum PhoneEntitlements {
    static let containersKey = "com.apple.developer.icloud-container-identifiers"

    static func hasCloudKitContainer(_ container: String = CloudKitTransport.containerIdentifier) -> Bool {
        (current()?[containersKey] as? [String])?.contains(container) ?? false
    }

    /// This build's entitlements, or nil when it has none (unsigned) or they can't be read.
    static func current() -> [String: Any]? {
        #if targetEnvironment(simulator)
        guard let data = executableSection("__TEXT", "__entitlements") else { return nil }
        return plist(data)
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? Data(contentsOf: url),
              let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let dictionary = plist(profile[start.lowerBound..<end.upperBound]) else { return nil }
        return dictionary["Entitlements"] as? [String: Any]
        #endif
    }

    private static func plist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    #if targetEnvironment(simulator)
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
