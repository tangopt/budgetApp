import SwiftUI
import BudgetCore

/// The sidebar's foot (step 10, Task 3): the signed-in person's avatar (initials unless there is a picture) and name only,
/// never the access level, a sync line, and Settings. Collapsed it is the avatar, a sync dot and the gear.
struct SidebarFooter: View {
    let userName: String
    let avatar: Image?
    let sync: SyncSidebarStatus?
    var waitingChanges: Int = 0
    var collapsed = false
    var now = Date()
    let onSettings: () -> Void
    @Environment(\.phoneTheme) private var theme

    /// The words under the name: "N changes waiting" while anything is queued, else the sync status's own.
    static func syncLine(_ sync: SyncSidebarStatus?, waitingChanges: Int, now: Date) -> String {
        if waitingChanges > 0 { return waitingChanges == 1 ? "1 change waiting" : "\(waitingChanges) changes waiting" }
        guard let sync else { return "Sync is off" }
        return sync.text(now: now)
    }

    /// Every text the expanded footer shows, in order.
    static func texts(userName: String, sync: SyncSidebarStatus?, waitingChanges: Int, now: Date) -> [String] {
        [userName, syncLine(sync, waitingChanges: waitingChanges, now: now)]
    }

    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var line: String { Self.syncLine(sync, waitingChanges: waitingChanges, now: now) }

    private var dotColor: Color {
        if waitingChanges > 0 { return theme.pending }
        switch sync {
        case .attention: return theme.pending
        case .synced: return theme.income
        case .syncing, .paused, .none: return .secondary
        }
    }

    var body: some View {
        if collapsed {
            VStack(spacing: 14) {
                avatarView
                Circle().fill(dotColor).frame(width: 10, height: 10)
                    .accessibilityElement().accessibilityLabel(line)
                settingsButton
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 10) {
                avatarView
                VStack(alignment: .leading, spacing: 2) {
                    Text(userName).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle().fill(dotColor).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(line.figuresUnbroken).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                settingsButton
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private var avatarView: some View {
        Group {
            if let avatar {
                avatar.resizable().scaledToFill()
            } else {
                Text(Self.initials(userName)).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.accent)
            }
        }
        .frame(width: 36, height: 36).clipShape(Circle())
        .accessibilityElement().accessibilityLabel(userName)
    }

    private var settingsButton: some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings").help("Settings")
    }
}
