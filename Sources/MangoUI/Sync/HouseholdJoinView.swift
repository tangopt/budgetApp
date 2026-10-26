import SwiftUI
import BudgetCore

/// What a member's device shows while it joins the household (step 7a), and after its removal: the 6-digit code large
/// to check against the Mac's, the waits, and the ways out (Retry, Start again, OK). All state and copy come from
/// `HouseholdJoinState` and `HouseholdCopy`; the buttons only call back.
public struct HouseholdJoinView: View {
    public let state: HouseholdJoinState
    public let onRetry: () -> Void
    public let onStartAgain: () -> Void
    public let onDismiss: () -> Void
    @Environment(\.phoneTheme) private var theme

    public init(state: HouseholdJoinState, onRetry: @escaping () -> Void = {}, onStartAgain: @escaping () -> Void = {},
                onDismiss: @escaping () -> Void = {}) {
        self.state = state
        self.onRetry = onRetry
        self.onStartAgain = onStartAgain
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                symbol
                VStack(spacing: 12) {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .showCode(let code) = state {
                        Text(code)
                            .font(.system(size: 56, weight: .semibold, design: .rounded))
                            .figureText(.shrink(minimumScale: 0.5))
                            .accessibilityLabel(code.map(String.init).joined(separator: " "))
                    }
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                if showsProgress { ProgressView().controlSize(.large) }
                buttons
            }
            .padding(24)
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, minHeight: 560)
        }
        .background(theme.background.ignoresSafeArea())
    }

    private var symbol: some View {
        Image(systemName: symbolName)
            .font(.system(size: 44))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var symbolName: String {
        switch state {
        case .accepting, .pulling: "icloud.and.arrow.down"
        case .waitingForKey, .showCode: "key"
        case .refused, .expired, .cannotJoin: "exclamationmark.triangle"
        case .stillJoining: "icloud.slash"
        case .removed: "person.crop.circle.badge.minus"
        }
    }

    private var title: String {
        switch state {
        case .accepting: HouseholdCopy.joiningTitle
        case .waitingForKey: HouseholdCopy.waitingForKey
        case .showCode: HouseholdCopy.checkCodeTitle
        case .pulling: HouseholdCopy.pullingTitle
        case .refused: HouseholdCopy.keyRefused
        case .expired: HouseholdCopy.keyExpired
        case .stillJoining: HouseholdCopy.stillJoiningTitle
        case .cannotJoin(let message): message
        case .removed: HouseholdCopy.removedNotice
        }
    }

    private var detail: String? {
        switch state {
        case .accepting: HouseholdCopy.joiningDetail
        case .showCode, .waitingForKey: HouseholdCopy.checkCodeDetail
        case .stillJoining(let reason): HouseholdCopy.stillJoiningReason(reason)
        default: nil
        }
    }

    private var showsProgress: Bool {
        switch state {
        case .accepting, .pulling, .waitingForKey: true
        default: false
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch state {
        case .stillJoining:
            Button(action: onRetry) { Text(HouseholdCopy.retryButton).frame(maxWidth: .infinity, minHeight: 36) }
                .buttonStyle(.borderedProminent)
        case .refused, .expired:
            Button(action: onStartAgain) { Text(HouseholdCopy.startAgainButton).frame(maxWidth: .infinity, minHeight: 36) }
                .buttonStyle(.borderedProminent)
        case .cannotJoin, .removed:
            Button(action: onDismiss) { Text(HouseholdCopy.okButton).frame(maxWidth: .infinity, minHeight: 36) }
                .buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
    }
}

/// The joining states' snapshot routes (step 7a, Task 10).
public enum JoinRoutes {
    static let all: [DemoRoute] = [
        route("join_accept", .accepting),
        route("join_code", .showCode("482915"), figures: 1),
        route("join_waiting_key", .waitingForKey),
        route("join_received", .pulling),
        route("join_refused", .refused),
        route("join_expired", .expired),
        route("join_still_joining", .stillJoining(.notShownYet)),
        route("join_cannot", .cannotJoin(HouseholdCopy.hasOwnData)),
        route("join_removed", .removed),
    ]

    private static func route(_ name: String, _ state: HouseholdJoinState, figures: Int = 0) -> DemoRoute {
        DemoRoute(name: name, minimumFigures: figures) { _ in AnyView(HouseholdJoinView(state: state)) }
    }
}
