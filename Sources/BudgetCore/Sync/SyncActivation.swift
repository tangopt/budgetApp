import Foundation

/// Whether this launch may sync at all (plan step 4 Global Constraints, Review Focus 5). In build step 4 the real
/// database never syncs: only a Debug launch with `--sync-demo` whose `BUDGET_DB_PATH` names the demo database
/// (`DemoMarker`), outside the app's own data folder, in a build signed with the iCloud entitlement. Everything
/// else is refused with its reason, before any database is opened. Both apps ask here (the Mac's `SyncDemoMode`,
/// the iPhone's launch).
public enum SyncActivation {
    public static let demoArgument = "--sync-demo"

    public struct Decision: Equatable, Sendable {
        public let allowed: Bool
        /// Why the launch can't sync; nil when it may.
        public let reason: String?

        public init(allowed: Bool, reason: String?) {
            self.allowed = allowed
            self.reason = reason
        }

        static let allow = Decision(allowed: true, reason: nil)
        static func refuse(_ reason: String) -> Decision { Decision(allowed: false, reason: reason) }
    }

    /// `databasePath`: `BUDGET_DB_PATH` as the environment gives it. `hasCloudKitEntitlement`: whether the process
    /// is signed for Mango's iCloud container (`CKContainer` traps without it).
    public static func decision(databasePath: String?, arguments: [String], isDebug: Bool, hasCloudKitEntitlement: Bool,
                                fileManager: FileManager = .default) -> Decision {
        guard arguments.contains(demoArgument) else {
            return .refuse("Sync is off: only a Debug launch with \(demoArgument) on the demo database syncs in this build.")
        }
        guard isDebug else {
            return .refuse("\(demoArgument) works only in a Debug build; this build syncs nothing.")
        }
        guard let raw = databasePath, !raw.isEmpty else {
            return .refuse("\(demoArgument) needs BUDGET_DB_PATH pointing at the demo database (MakeDemoDatabase builds one).")
        }
        guard raw.hasPrefix("/"), !raw.lowercased().hasPrefix("file:") else {
            return .refuse("\(demoArgument): BUDGET_DB_PATH must be an absolute file path.")
        }
        let resolved = TaxRegression.resolvedPath(raw, fileManager: fileManager)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .refuse("\(demoArgument): there is no database file at BUDGET_DB_PATH.")
        }
        guard !TaxRegression.isAppData(resolved, fileManager: fileManager) else {
            return .refuse("\(demoArgument) never syncs the app's own database.")
        }
        guard DemoMarker.isDemoDatabase(atPath: resolved, fileManager: fileManager) else {
            return .refuse("\(demoArgument) syncs only the demo database; BUDGET_DB_PATH isn't one (MakeDemoDatabase builds it).")
        }
        guard hasCloudKitEntitlement else {
            return .refuse("\(demoArgument) needs a team-signed Debug build with the iCloud entitlement for Mango's container (Config/Signing.local.xcconfig names the team); this build has none.")
        }
        return .allow
    }
}
