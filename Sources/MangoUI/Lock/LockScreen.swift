import SwiftUI
import BudgetCore

/// The phone's lock screen (auth spec §10). Shows only the copy from `MobileLockPolicy` and two buttons; it never
/// sits over the content (the app renders it instead of the content). Fits the 375 pt width class and scrolls at
/// accessibility Dynamic Type sizes rather than clipping.
public struct LockScreen: View {
    private let availability: MobileLockPolicy.Availability
    private let icon: Image?
    private let isBusy: Bool
    private let onPrimary: () -> Void
    private let onSecondary: () -> Void

    /// `icon`: the app's mark (the phone passes its icon); a lock symbol when nil. `isBusy`: an unlock is in
    /// progress, so the buttons are disabled.
    public init(availability: MobileLockPolicy.Availability, icon: Image? = nil, isBusy: Bool = false,
                onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void) {
        self.availability = availability
        self.icon = icon
        self.isBusy = isBusy
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    public var body: some View {
        let copy = MobileLockPolicy.lockScreenCopy(availability)
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    mark
                    VStack(spacing: 8) {
                        Text(copy.title)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text(copy.body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 12) {
                        if let primary = copy.primary {
                            Button(action: onPrimary) {
                                Label(primary, systemImage: primarySymbol)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityIdentifier("lock.primary")
                        }
                        if let secondary = copy.secondary {
                            Button(action: onSecondary) {
                                Text(secondary)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("lock.secondary")
                        }
                    }
                    .disabled(isBusy)
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder private var mark: some View {
        if let icon {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
    }

    private var primarySymbol: String {
        switch availability {
        case .biometrics(.faceID): "faceid"
        case .biometrics(.touchID): "touchid"
        case .passcodeOnly: "lock.open"
        case .noPasscode: "gear"
        case .unavailable: "arrow.clockwise"
        }
    }
}
