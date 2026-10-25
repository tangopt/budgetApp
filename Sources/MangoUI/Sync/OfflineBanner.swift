import SwiftUI
import BudgetCore

/// The amber banner at the top of every tab while offline (iPhone spec §3.9): "Offline · showing data from 14:05."
/// (`SyncStatusCopy.offlineBanner`). The phone sends nothing, so it never counts changes waiting.
public struct OfflineBanner: View {
    public let lastSync: Date?
    public let now: Date

    public init(lastSync: Date?, now: Date) {
        self.lastSync = lastSync
        self.now = now
    }

    public var body: some View {
        InlineBanner(tone: .amber, text: SyncStatusCopy.offlineBanner(lastSync: lastSync, now: now))
    }
}

/// What `offlineBanner(_:lastSync:now:)` hands to the screens: shown by `offlineBannerSlot()`, inside each tab's
/// navigation stack, so it sits under the navigation bar rather than over its buttons.
struct OfflineBannerInfo: Equatable {
    let lastSync: Date?
    let now: Date
}

extension EnvironmentValues {
    @Entry var offlineBannerInfo: OfflineBannerInfo? = nil
}

private struct OfflineBannerSlot: ViewModifier {
    @Environment(\.offlineBannerInfo) private var info
    @Environment(\.showsDemoData) private var showsDemoData

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if showsDemoData {
                // Demo data: never synced, so never offline; the demo banner instead.
                DemoBanner()
            } else if let info {
                OfflineBanner(lastSync: info.lastSync, now: info.now)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
    }
}

extension View {
    /// Shows the offline banner (when a screen above set one with `offlineBanner`) at the top of this screen's
    /// content, under its navigation bar. Each tab's root screen calls it inside its `NavigationStack`.
    public func offlineBannerSlot() -> some View {
        modifier(OfflineBannerSlot())
    }

    /// Shows `OfflineBanner` at the top of the screens below while `status` is offline; nothing otherwise.
    public func offlineBanner(_ status: SyncStatus, lastSync: Date?, now: @escaping () -> Date = { Date() }) -> some View {
        let info: OfflineBannerInfo? = if case .offline = status { OfflineBannerInfo(lastSync: lastSync, now: now()) } else { nil }
        return environment(\.offlineBannerInfo, info)
    }
}
