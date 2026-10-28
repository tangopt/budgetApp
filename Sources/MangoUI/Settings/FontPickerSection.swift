import SwiftUI
import BudgetCore

/// Settings ▸ Appearance ▸ Font (step 16): the rows the picker lists. Pure, so a test can read them.
public struct FontPickerModel {
    public struct Row: Identifiable, Equatable {
        public let id: String
        public let name: String
        /// A figure drawn in the row's own font, so the person sees how money will look.
        public let sample: String
        public let isSelected: Bool
    }

    public static let sampleFigure = "£1,284.50"

    /// The 13 fonts in the catalogue's order; the stored id marks one (an unknown id marks SF Pro).
    public static func rows(selected id: String) -> [Row] {
        let selectedID = FontCatalog.font(id: id).id
        return FontCatalog.all.map { Row(id: $0.id, name: $0.name, sample: sampleFigure, isSelected: $0.id == selectedID) }
    }
}

/// The Font picker: a navigation-link picker whose rows are each drawn in their own font.
struct FontPickerSection: View {
    @Binding var fontId: String

    var body: some View {
        Picker("Font", selection: $fontId) {
            ForEach(FontPickerModel.rows(selected: fontId)) { row in
                FontPickerRow(row: row, face: FontCatalog.font(id: row.id))
                    .tag(row.id)
            }
        }
        #if os(iOS)
        .pickerStyle(.navigationLink)
        #endif
        .frame(minHeight: 44)
    }
}

private struct FontPickerRow: View {
    let row: FontPickerModel.Row
    let face: PhoneFont

    var body: some View {
        HStack {
            Text(row.name)
                .font(TypefaceResolver.font(face, style: .body, weight: nil, isFigure: false))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(row.sample)
                .font(TypefaceResolver.font(face, style: .body, weight: nil, isFigure: true).monospacedDigit())
                .foregroundStyle(.secondary)
                .figureText()
        }
        .frame(minHeight: 44)
    }
}
