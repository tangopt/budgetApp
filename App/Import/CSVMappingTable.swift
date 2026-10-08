// App/Import/CSVMappingTable.swift
import SwiftUI
import BudgetCore

/// Every column of the CSV — header plus the first sample rows — with a role menu above
/// each header. Scrolls horizontally when the file is wider than the sheet (a Lloyds-style
/// export has eight columns).
struct CSVMappingTable: View {
    @ObservedObject var model: CSVMappingModel

    /// The Description column holds the longest text, so it never gets narrower than this.
    private static let descriptionMinWidth: CGFloat = 280

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<model.columnCount, id: \.self) { column in
                        roleMenu(column: column)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 6)
                            .frame(width: width(column), alignment: .leading)
                    }
                }
                GridRow {
                    ForEach(0..<model.columnCount, id: \.self) { column in
                        cell(model.headerTitle(column: column), column: column)
                            .fontWeight(.semibold)
                    }
                }
                .background(.quaternary.opacity(0.5))
                Divider()
                ForEach(model.sampleRows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<model.columnCount, id: \.self) { column in
                            cell(model.sampleValue(row: row, column: column), column: column)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.visible)
    }

    private func role(_ column: Int) -> CSVColumnRole { model.mapping.roles[column] }

    private func width(_ column: Int) -> CGFloat {
        let natural = model.contentWidths[column]
        return role(column) == .description ? max(natural, Self.descriptionMinWidth) : natural
    }

    private func cell(_ text: String, column: Int) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(role(column) == .ignore ? .secondary : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: width(column), alignment: .leading)
            .help(text)
    }

    private func roleMenu(column: Int) -> some View {
        let current = role(column)
        let mapped = current != .ignore
        return Menu {
            Picker("Column holds", selection: Binding(
                get: { role(column) },
                set: { model.setRole($0, forColumn: column) }
            )) {
                ForEach(model.offeredRoles, id: \.self) { role in
                    Text(role.title).tag(role)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(current.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(mapped ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(mapped ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(mapped ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("\(model.headerTitle(column: column)) column: \(current.title)")
    }
}
