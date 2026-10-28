import SwiftUI
import BudgetCore

/// No iCloud account on this iPhone, or iCloud restricted (iPhone spec §3.9, sync spec §5.6): a full screen saying
/// so, with "Open Settings". Local data stays readable: "Show what's here" goes to the tabs.
public struct ICloudUnavailableView: View {
    public let state: ICloudAccountState
    public let onOpenSettings: () -> Void
    public let onShowLocal: () -> Void
    @Environment(\.phoneTheme) private var theme

    public init(state: ICloudAccountState, onOpenSettings: @escaping () -> Void, onShowLocal: @escaping () -> Void) {
        self.state = state
        self.onOpenSettings = onOpenSettings
        self.onShowLocal = onShowLocal
    }

    public static let title = "Sign in to iCloud to see the household's data"
    public static let noAccountMessage = "Mango brings the household's records from iCloud. Sign in to iCloud in Settings on this iPhone; what's already here stays readable."
    public static let restrictedMessage = "iCloud is restricted on this iPhone (Screen Time or a profile). What's already here stays readable."

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(Self.title)
                    .mangoFont(.title2, weight: .semibold)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(state == .restricted ? Self.restrictedMessage : Self.noAccountMessage)
                    .mangoFont(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: onOpenSettings) {
                    Text("Open Settings")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
                Button(action: onShowLocal) {
                    Text("Show what's here")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .padding(.top, 60)
        }
        .background(theme.background.ignoresSafeArea())
    }
}
