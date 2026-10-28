import SwiftUI
import BudgetCore
import GRDB

/// What Settings ▸ Sharing shows on the iPhone (step 6, read-only: levels are changed on the Mac).
public enum SharingSectionState: Equatable, Sendable {
    /// The household hasn't named this iPhone's iCloud user yet: it shows only what the household shares.
    case notNamed
    /// The viewer's own accounts and levels (`SharingOverview.load(viewer:db:)`).
    case loaded(SharingOverview)

    /// Whether this iPhone's viewer is the household's admin (the Mac's grid is theirs; some reminders too).
    public var isAdmin: Bool {
        if case .loaded(let overview) = self { return overview.isAdmin }
        return false
    }

    public static func read(_ db: Database, viewer: PhoneViewer) throws -> SharingSectionState {
        guard let overview = try SharingOverview.load(viewer: try viewer.resolve(db: db), db: db) else { return .notNamed }
        return .loaded(overview)
    }

    /// Read off the main actor; nil when the read fails (the section is then left out).
    public nonisolated static func load(_ reader: any DatabaseReader, viewer: PhoneViewer) async -> SharingSectionState? {
        try? await reader.read { db in try read(db, viewer: viewer) }
    }
}

/// Settings' Sharing section: the viewer's own accounts, each with its level as text (no picker), their tax years
/// and income level, and "Levels are changed on the Mac." Before the owners are set: the Mac's explanation for the
/// admin, the waiting line for a member.
public struct SharingSection: View {
    let state: SharingSectionState

    public init(state: SharingSectionState) {
        self.state = state
    }

    public var body: some View {
        Section {
            switch state {
            case .notNamed:
                note(SharingCopy.phoneNotNamedYet)
            case .loaded(let overview) where !overview.isConfirmed:
                note(overview.isAdmin ? SharingCopy.setupExplanation : SharingCopy.waitingForOwners)
            case .loaded(let overview):
                if overview.own.isEmpty {
                    note(SharingCopy.noOwnAccounts)
                } else {
                    ForEach(overview.own) { row in
                        level(row.displayName, detail: row.bankName, value: row.level.title)
                    }
                }
                level(SharingCopy.taxAndIncome, detail: nil, value: overview.taxIncomeLevel.title)
            }
        } header: {
            Text(SharingCopy.paneTitle)
        } footer: {
            Text(SharingCopy.changedOnTheMac)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44, alignment: .leading)
    }

    /// A name (with its bank beneath) and its level, trailing; both wrap rather than truncate.
    private func level(_ name: String, detail: String?, value: String) -> some View {
        LabeledContent {
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .mangoFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
