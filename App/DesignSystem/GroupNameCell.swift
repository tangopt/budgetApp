// App/DesignSystem/GroupNameCell.swift
import SwiftUI

/// A group row's name cell (Budget grid and scenario grid): the whole cell, full category-column
/// width by row height, toggles the group, with a subtle fill while the pointer is over it.
struct GroupNameCell: View {
    let name: String
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2)
            Text(name).bold()
        }
        .frame(width: 220, height: 28, alignment: .leading)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(hovering ? 0.06 : 0))
        .background(Color.orange.opacity(0.10))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .accessibilityAddTraits(.isButton)
    }
}
