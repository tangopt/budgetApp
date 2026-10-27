import SwiftUI
import BudgetCore

/// Settings ▸ Widgets' words.
public enum WidgetsCopy {
    public static let header = "Widgets"
    public static let lockScreenToggle = "Show figures on the lock screen"
    public static let lockScreenFooter = "Off: widgets and reminders hide amounts while this iPhone is locked. A setting of this iPhone only."
}

/// Settings' Widgets section (step 7b): whether the widget's figures show on the lock screen, off until turned on.
/// A setting of this iPhone only (`PhoneOutputSettings`), never synced; it applies at once, as Appearance does.
public struct WidgetsSection: View {
    @Binding var settings: PhoneOutputSettings

    public init(settings: Binding<PhoneOutputSettings>) {
        _settings = settings
    }

    /// The toggle's state.
    var showsFiguresOnLockScreen: Bool { settings.showFiguresOnLockScreen }

    public var body: some View {
        Section {
            Toggle(isOn: $settings.showFiguresOnLockScreen) {
                Text(WidgetsCopy.lockScreenToggle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 44)
        } header: {
            Text(WidgetsCopy.header)
        } footer: {
            Text(WidgetsCopy.lockScreenFooter)
        }
    }
}
