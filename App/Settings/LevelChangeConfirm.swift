// App/Settings/LevelChangeConfirm.swift
import SwiftUI
import BudgetCore

/// The confirmation a level picked in Settings ▸ Sharing opens (sharing spec §3 goal 4): from and to, how many records
/// move ("Moves 1,204 records", counted off the main thread), and for a lower level the warning that Mango can't
/// recall what the other person may already have (a higher one says what they will see). Nothing changes until
/// Change. A Hidden that something still needs lists what blocks it and offers no Change.
struct LevelChangeConfirm: View {
    let change: SharingLevelChangeFlow.Pending
    let otherName: String
    let onCancel: () -> Void
    let onChange: () -> Void

    private var preview: SharingOverview.LevelChangePreview? { change.preview }
    private var isBlocked: Bool { preview?.isBlocked == true }

    var body: some View {
        SheetScaffold(title: isBlocked ? SharingCopy.blockedTitle(account: change.account.displayName)
                                       : SharingCopy.changeTitle(account: change.account.displayName),
                      subtitle: SharingCopy.changeSummary(from: change.account.level, to: change.to),
                      error: change.error,
                      width: SheetMetrics.formWidth,
                      onCancel: onCancel,
                      primary: isBlocked ? nil : SheetAction(SharingCopy.changeButton, isEnabled: change.canChange, action: onChange)) {
            VStack(alignment: .leading, spacing: 10) {
                if let preview {
                    if preview.isBlocked {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(preview.blockers.enumerated()), id: \.offset) { _, blocker in
                                Label(SharingCopy.blocker(blocker), systemImage: "link")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text(SharingCopy.blockedNote)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(SharingCopy.moves(count: preview.affectedCount)).figureText()
                        if preview.isLowering {
                            InlineBanner(.warning, SharingCopy.lowerWarning(otherName: otherName))
                        } else {
                            Text(SharingCopy.raiseNote(otherName: otherName))
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if change.isChanging {
                        progress(SharingCopy.changing)
                    }
                } else if change.error == nil {
                    progress(SharingCopy.counting)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}
