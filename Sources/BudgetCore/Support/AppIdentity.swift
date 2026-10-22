import Foundation

/// The Mac app's bundle identifiers. Build step 0 moved it from `com.personal.budget` to
/// `ubberninja.mango` (the old prefix's App Group was already taken on developer.apple.com);
/// the data folder (`Application Support/Budget`) did not move.
public enum AppIdentity {
    public static let macBundleIdentifier = "ubberninja.mango"
    public static let legacyMacBundleIdentifier = "com.personal.budget"
    /// Both, for the command-line tools' "quit the app first" check: an installed copy may
    /// still be the old build.
    public static let macBundleIdentifiers = [macBundleIdentifier, legacyMacBundleIdentifier]

    static let legacyPreferencesCopiedKey = "legacyPreferencesCopied"

    /// Copies the old bundle id's preferences (theme, appearance, panel and grid state) into
    /// `defaults` once, on the first launch under the new id. Keys `defaults` already holds
    /// are kept. Returns the number of keys copied.
    @discardableResult
    public static func copyLegacyPreferencesOnce(
        from legacyDomain: String = legacyMacBundleIdentifier,
        into defaults: UserDefaults = .standard
    ) -> Int {
        guard !defaults.bool(forKey: legacyPreferencesCopiedKey) else { return 0 }
        var copied = 0
        for (key, value) in defaults.persistentDomain(forName: legacyDomain) ?? [:]
        where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(true, forKey: legacyPreferencesCopiedKey)
        return copied
    }
}
