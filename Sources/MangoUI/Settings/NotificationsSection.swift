import SwiftUI
import BudgetCore

/// Settings ▸ Notifications' words.
public enum NotificationsCopy {
    public static let header = "Notifications"
    public static let allow = "Allow notifications"
    public static let denied = "Notifications are off for Mango in Settings."
    public static let lockScreenNote = "Amounts appear in notifications and widgets on the lock screen."

    public static func title(_ kind: NotificationKind) -> String {
        switch kind {
        case .rentLate: "Rent not seen"
        case .billDue: "Bill due in 3 days"
        case .taxDue: "Tax payment due in 7 days"
        case .noImport: "No statement imported"
        }
    }
}

/// Settings' Notifications section (step 7b): "Allow notifications" until the person has been asked (the only place
/// Mango asks), then one toggle per reminder; "No statement imported" only for the admin. A setting of this iPhone
/// only (`PhoneOutputSettings`); a change re-plans at once.
public struct NotificationsSection: View {
    @Binding var settings: PhoneOutputSettings
    let authorization: NotificationAuthorization
    let isAdmin: Bool
    let onAllow: () -> Void

    public init(settings: Binding<PhoneOutputSettings>, authorization: NotificationAuthorization, isAdmin: Bool,
                onAllow: @escaping () -> Void) {
        _settings = settings
        self.authorization = authorization
        self.isAdmin = isAdmin
        self.onAllow = onAllow
    }

    /// The toggles shown, in order.
    public static func kinds(isAdmin: Bool) -> [NotificationKind] {
        NotificationKind.allCases.filter { $0 != .noImport || isAdmin }
    }

    var kinds: [NotificationKind] { Self.kinds(isAdmin: isAdmin) }
    var showsAllowRow: Bool { authorization == .notDetermined }
    var showsDeniedNote: Bool { authorization == .denied }

    public var body: some View {
        Section {
            if showsAllowRow {
                Button(action: onAllow) {
                    Label(NotificationsCopy.allow, systemImage: "bell.badge")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                }
            }
            ForEach(kinds, id: \.self) { kind in
                Toggle(isOn: binding(kind)) {
                    Text(NotificationsCopy.title(kind))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 44)
            }
        } header: {
            Text(NotificationsCopy.header)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if showsDeniedNote { Text(NotificationsCopy.denied) }
                Text(NotificationsCopy.lockScreenNote)
            }
        }
    }

    private func binding(_ kind: NotificationKind) -> Binding<Bool> {
        Binding(get: { settings.notifications.contains(kind) },
                set: { on in
                    if on { settings.notifications.insert(kind) } else { settings.notifications.remove(kind) }
                })
    }
}
