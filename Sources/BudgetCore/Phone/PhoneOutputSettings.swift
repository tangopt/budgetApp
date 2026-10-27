import Foundation

/// A reminder the iPhone can send (step 7b's notifications plan them).
public enum NotificationKind: String, CaseIterable, Codable, Sendable {
    case rentLate, billDue, taxDue, noImport
}

/// What this iPhone shows outside the app: whether the widget's figures show on the lock screen (off until turned on),
/// and which reminders it sends (all until turned off). Per device by construction: kept in `UserDefaults`, which never
/// syncs, under `defaultsKey` in the App Group's suite (`PhoneAppGroup.identifier`) so the widget reads it too.
public struct PhoneOutputSettings: Codable, Equatable, Sendable {
    public var showFiguresOnLockScreen = false
    public var notifications: Set<NotificationKind> = Set(NotificationKind.allCases)

    public static let defaultsKey = "phone.outputSettings"

    public init(showFiguresOnLockScreen: Bool = false, notifications: Set<NotificationKind> = Set(NotificationKind.allCases)) {
        self.showFiguresOnLockScreen = showFiguresOnLockScreen
        self.notifications = notifications
    }

    /// A field missing from what was stored keeps its default (a later build may add one).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showFiguresOnLockScreen = try container.decodeIfPresent(Bool.self, forKey: .showFiguresOnLockScreen) ?? false
        notifications = try container.decodeIfPresent(Set<NotificationKind>.self, forKey: .notifications) ?? Set(NotificationKind.allCases)
    }

    /// The stored settings, else the defaults (nothing stored, or unreadable).
    public static func load(from defaults: UserDefaults) -> PhoneOutputSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(PhoneOutputSettings.self, from: data) else { return PhoneOutputSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
