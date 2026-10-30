// Sources/BudgetCore/Themes/ThemeSetPreference.swift
import Foundation

/// Where the iPhone and iPad keep their theme set (step 8): this device's own choice, never synced, under `key` in the
/// app's defaults, mirrored to the App Group's (`widgetKey`) so the widgets draw in the same colours.
public enum ThemeSetPreference {
    public static let key = "phone.themeSet"
    /// The colour theme and font the phone stored before step 8; read once by `migrate`, then left for a rollback.
    public static let oldThemeKey = "phone.theme"
    public static let oldFontKey = "phone.font"
    public static let appearanceKey = "phone.appearance"
    /// The set's id in the App Group's defaults, for the widgets.
    public static let widgetKey = "widgets.themeSet"

    /// The one-time migration (design review §3.5): when no set is stored yet, the old colour theme and font pick one
    /// (`ThemeSetMigration`), it is stored, and a dark-only old theme (Midnight) sets Appearance to Dark. Returns the
    /// set's id; a second call changes nothing.
    @discardableResult
    public static func migrate(_ defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: key) { return ThemeSet.named(stored).id }
        let result = ThemeSetMigration.result(colorTheme: defaults.string(forKey: oldThemeKey),
                                              font: defaults.string(forKey: oldFontKey))
        defaults.set(result.setID, forKey: key)
        if result.setsDarkAppearance { defaults.set("dark", forKey: appearanceKey) }
        return result.setID
    }

    /// Hands the set to the widgets.
    public static func share(_ id: String, with groupDefaults: UserDefaults) {
        let id = ThemeSet.named(id).id
        if groupDefaults.string(forKey: widgetKey) != id { groupDefaults.set(id, forKey: widgetKey) }
    }

    /// The set the widgets draw in: the app's, else Mango.
    public static func widgetSet(_ groupDefaults: UserDefaults) -> ThemeSet {
        ThemeSet.named(groupDefaults.string(forKey: widgetKey) ?? ThemeSet.defaultID)
    }
}
