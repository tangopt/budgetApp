import Foundation

/// Whether this launch may sync at all (plan step 4 Global Constraints, Review Focus 5). In build step 4 the real
/// database never syncs: only a Debug launch with `--sync-demo` whose `BUDGET_DB_PATH` names the demo database
/// (`DemoMarker`), outside the app's own data folder, in a build signed with the iCloud entitlement. Everything
/// else is refused with its reason, before any database is opened. Both apps ask here (the Mac's `SyncDemoMode`,
/// the iPhone's launch). Step 6: the Mac's real database syncs once "Turn on sync…" has run on it (`realDecision`).
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

    /// A developer's flag: a Debug Mac build may sync the real database only when launched with it (and everything
    /// else `realDecision` asks holds, Production included).
    public static let realInDebugArgument = "--sync-real-in-debug"

    /// Whether the Mac's real database may sync (step 6 Task 12): only the app's own database, never the demo's, once
    /// this Mac's "Turn on sync…" flow has reached the upload (`SyncTurnOn.Stage` `uploading` or `done`, kept in that
    /// database), in a build signed for Mango's iCloud container in its Production environment. A Debug build only
    /// with `realInDebugArgument`. Never together with `--sync-demo` (that launch keeps `decision`'s demo rules).
    public static func realDecision(isAppDatabase: Bool, isDemoDatabase: Bool, stage: SyncTurnOn.Stage, hasCloudKitEntitlement: Bool,
                                    isProduction: Bool, isDebug: Bool, arguments: [String]) -> Decision {
        if arguments.contains(demoArgument) {
            return .refuse("A \(demoArgument) launch syncs only the demo database, never the real one.")
        }
        guard isAppDatabase else { return .refuse("Only the app's own database syncs with your data in iCloud.") }
        guard !isDemoDatabase else { return .refuse("The demo database never syncs with your data in iCloud.") }
        guard stage >= .uploading else {
            return .refuse("Sync is off: turn it on in Settings ▸ Sync (Turn on sync…) on this Mac first.")
        }
        guard !isDebug || arguments.contains(realInDebugArgument) else {
            return .refuse("A Debug build syncs the real database only with \(realInDebugArgument).")
        }
        guard hasCloudKitEntitlement else {
            return .refuse("This build isn't signed with the iCloud entitlement for Mango's container, so it syncs nothing.")
        }
        guard isProduction else {
            return .refuse("This build syncs with iCloud's development environment; your data syncs only in Production.")
        }
        return .allow
    }

    /// Whether the iPhone may sync (step 6 Task 11). Demo data (`PhoneDemoMode.syncRefusal`: demo mode on, the demo
    /// folder, a demo database outside `--sync-demo`) never syncs. A `--sync-demo` launch keeps `decision`'s rules
    /// (`databasePath`: `BUDGET_DB_PATH`). Otherwise the phone's own database syncs in a Release build (TestFlight)
    /// signed with the iCloud entitlement: it is the phone's own and read-only (pulls only), so it can't change the
    /// household's data.
    public static func phoneDecision(isDemoData: Bool, isSyncDemoLaunch: Bool, hasCloudKitEntitlement: Bool, isDebug: Bool,
                                     databasePath: String? = nil, fileManager: FileManager = .default) -> Decision {
        if isDemoData { return .refuse("Demo data never syncs.") }
        if isSyncDemoLaunch {
            return decision(databasePath: databasePath, arguments: [demoArgument], isDebug: isDebug,
                            hasCloudKitEntitlement: hasCloudKitEntitlement, fileManager: fileManager)
        }
        guard !isDebug else {
            return .refuse("This iPhone's own data syncs only in a Release build (TestFlight); a Debug build syncs only with \(demoArgument).")
        }
        guard hasCloudKitEntitlement else {
            return .refuse("This build isn't signed with the iCloud entitlement for Mango's container, so it syncs nothing.")
        }
        return .allow
    }
}
