import Foundation
import OSLog
import BudgetCore

/// The phone's side of the sync demo (plan step 4 Task 12; DEBUG only). `--sync-demo` on the phone means "pull the
/// Development container's demo zone into the demo database" (`SyncActivation` still decides: a DEBUG launch whose
/// `BUDGET_DB_PATH` names a demo database, which only a simulator build honours). Its keys live under the demo
/// scope (`CloudKitTransport.keyScope(demo: true)`), never the real data's.
///
/// The simulator has no iCloud Keychain, so a simulator launch may hand the demo household key over in
/// `MANGO_DEMO_HOUSEHOLD_KEY` (64 hex characters): stored once at launch in the demo-scope key store. A malformed
/// value is refused with a log line and nothing is stored. Never a real key; never on a device.
enum PhoneSyncDemoMode {
    private static let log = Logger(subsystem: "ubberninja.mango.ios", category: "Sync")

    /// Whether this launch asked for the sync demo (always false outside DEBUG).
    static var isRequested: Bool {
        #if DEBUG
        CommandLine.arguments.contains(SyncActivation.demoArgument)
        #else
        false
        #endif
    }

    /// Stores the handed-over demo key in `store` (the demo scope's), simulator DEBUG builds only.
    static func storeHandedOverKey(in store: any SyncKeyStore,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG && targetEnvironment(simulator)
        guard isRequested, let raw = environment[DemoHouseholdKey.environmentVariable], !raw.isEmpty else { return }
        guard let key = DemoHouseholdKey.parse(raw) else {
            log.error("Sync demo: \(DemoHouseholdKey.environmentVariable, privacy: .public) isn't 64 hex characters; nothing stored")
            return
        }
        do {
            try store.store(key, zone: SyncRecordStore.householdZone)
            log.info("Sync demo: the handed-over demo household key is in the demo key store")
        } catch {
            log.error("Sync demo: the demo household key couldn't be stored (\(String(describing: type(of: error)), privacy: .public))")
        }
        #endif
    }
}
