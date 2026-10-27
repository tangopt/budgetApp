// App/Settings/PermissionGridView.swift
import SwiftUI
import BudgetCore

/// Settings ▸ Household: what the joined member can do, area by area (step 7b spec §2.1). A draft: nothing is written
/// until Save, Cancel drops the changes, and Reset to defaults only changes the draft. It is a Form section.
struct PermissionGridView: View {
    var grid: PermissionGrid
    /// The saved grid the draft is compared with.
    var original: PermissionGrid
    var onChange: (AccessArea, PermissionLevel) -> Void
    var onReset: () -> Void
    var onSave: () -> Void
    var onCancel: () -> Void
    var busy: Bool

    @Environment(\.theme) private var theme

    private var changed: Bool { !grid.differences(from: original).isEmpty }

    var body: some View {
        Section(HouseholdCopy.gridTitle(grid.memberName)) {
            ForEach(grid.rows) { row in
                LabeledContent {
                    Picker(row.title, selection: Binding(get: { row.level }, set: { onChange(row.area, $0) })) {
                        ForEach(row.choices, id: \.self) { level in
                            Text(HouseholdCopy.gridLevel(level)).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .frame(width: 180, alignment: .trailing)
                    .disabled(busy)
                } label: {
                    Text(row.title).lineLimit(1).truncationMode(.middle)
                }
            }
            Text(HouseholdCopy.gridLowerNote(grid.memberName))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent("") {
                HStack {
                    Button(HouseholdCopy.gridResetButton) { onReset() }.disabled(busy)
                    Button("Cancel") { onCancel() }.disabled(busy || !changed)
                    Button("Save") { onSave() }.buttonStyle(.borderedProminent).disabled(busy || !changed)
                }
            }
        }
    }
}
