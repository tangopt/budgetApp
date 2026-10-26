// App/Settings/OwnershipSheet.swift
import SwiftUI
import BudgetCore

/// "Who owns each account?" (sharing spec 2026-10-25 §7): the admin's one-time sheet. Every account without an
/// owner, with its bank, its owner (the admin by default, or Joint) and its starting level, each changeable before
/// Save. A joint account is always Everything. Save writes all of it at once or nothing (`SharingSetup.save`); it is
/// enabled from the start, since the proposal is valid as it is. Cancel keeps nothing.
struct OwnershipSheet: View {
    let adminName: String
    /// The admin's person, as the proposal named it.
    private let adminPersonId: Int64?
    let onSave: ([SharingSetup.Row]) async throws -> Void
    @State private var rows: [SharingSetup.Row]
    @State private var error: String?
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(rows: [SharingSetup.Row], adminName: String, onSave: @escaping ([SharingSetup.Row]) async throws -> Void) {
        _rows = State(initialValue: rows)
        // Every row starts as the admin's (`SharingSetup.proposal`).
        adminPersonId = rows.lazy.compactMap { if case .person(let id) = $0.owner { id } else { nil } }.first
        self.adminName = adminName
        self.onSave = onSave
    }

    private static let ownerWidth: CGFloat = 130
    private static let levelWidth: CGFloat = 170
    private static let bankWidth: CGFloat = 170

    var body: some View {
        SheetScaffold(title: SharingCopy.sheetTitle, subtitle: SharingCopy.sheetNote, error: error, width: SheetMetrics.tableWidth,
                      onCancel: { dismiss() },
                      primary: SheetAction("Save", isEnabled: !isSaving) { save() }) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($rows) { $row in
                            line($row)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: rows.count <= 8)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(SharingCopy.accountColumn).frame(maxWidth: .infinity, alignment: .leading)
            Text(SharingCopy.bankColumn).frame(width: Self.bankWidth, alignment: .leading)
            Text(SharingCopy.ownerColumn).frame(width: Self.ownerWidth, alignment: .leading)
            Text(SharingCopy.levelColumn).frame(width: Self.levelWidth, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    private func line(_ row: Binding<SharingSetup.Row>) -> some View {
        let isJoint = row.wrappedValue.owner == .joint
        return HStack(spacing: 12) {
            Text(row.wrappedValue.displayName)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.wrappedValue.bankName ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: Self.bankWidth, alignment: .leading)
            Picker(SharingCopy.ownerColumn, selection: Binding(get: { isJoint }, set: { setJoint($0, row) })) {
                Text(adminName).tag(false)
                Text(SharingCopy.jointChoice).tag(true)
            }
            .labelsHidden()
            .frame(width: Self.ownerWidth, alignment: .leading)
            .accessibilityLabel("\(SharingCopy.ownerColumn) \(row.wrappedValue.displayName)")
            Picker(SharingCopy.levelColumn, selection: row.level) {
                ForEach(isJoint ? [SharingLevel.everything] : SharingLevel.allCases.reversed(), id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
            .labelsHidden()
            .disabled(isJoint)
            .frame(width: Self.levelWidth, alignment: .leading)
            .accessibilityLabel("\(SharingCopy.levelColumn) \(row.wrappedValue.displayName)")
        }
        .padding(.vertical, 5)
    }

    /// Joint locks the level to Everything; back to the admin, the account takes its default again.
    private func setJoint(_ joint: Bool, _ row: Binding<SharingSetup.Row>) {
        guard joint != (row.wrappedValue.owner == .joint) else { return }
        if joint {
            row.wrappedValue.owner = .joint
            row.wrappedValue.level = .everything
        } else if let admin = adminPersonId {
            row.wrappedValue.owner = .person(admin)
            row.wrappedValue.level = SharingDefaults.level(ownerPersonId: admin, isPropertyLinked: row.wrappedValue.isPropertyLinked)
        }
    }


    private func save() {
        isSaving = true
        error = nil
        let rows = self.rows
        Task {
            defer { isSaving = false }
            do {
                try await onSave(rows)
                dismiss()
            } catch let failure as SharingError {
                error = SharingCopy.error(failure)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
