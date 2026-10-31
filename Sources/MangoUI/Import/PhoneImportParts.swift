import SwiftUI
import BudgetCore

/// The one primary action of an import screen: full width, 50 pt, in the set's accent. Disabled, it is dimmed.
struct ImportPrimaryButtonStyle: ButtonStyle {
    @Environment(\.phoneTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: MangoRadius.control, style: .continuous)
        configuration.label
            .mangoFont(.body, weight: .semibold)
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, MangoSpacing.m)
            .background(theme.accent, in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// A text button under the primary ("Not now", "Undo import"): 44 pt tall.
struct ImportTextButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.phoneTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .mangoFont(.body, weight: .medium)
            .multilineTextAlignment(.center)
            .foregroundStyle(destructive ? theme.expense : theme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}

/// A label with its value: side by side, the value trailing and truncating in the middle; at accessibility sizes the
/// label above the value. A pill (Read, To check, Detected) always carries a word.
struct ImportFieldRow<Value: View>: View {
    let label: String
    var pill: (text: String, status: StatusPill.Status)?
    @ViewBuilder var value: Value
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if AmountRowLayout.stacks(at: dynamicTypeSize) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).mangoFont(.subheadline).foregroundStyle(.secondary)
                    value.frame(maxWidth: .infinity, alignment: .leading)
                    if let pill { StatusPill(pill.text, pill.status) }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: MangoSpacing.s) {
                    Text(label).mangoFont(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 72, maxWidth: .infinity, alignment: .leading)
                    value.layoutPriority(1)
                    if let pill { StatusPill(pill.text, pill.status) }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// A row of the engine's fields (`CheckRow`): a figure kept on one line, a name truncating in the middle, the pill
/// "Read" (read from the file) or "To check". A period too long for one line at accessibility sizes shows its two days
/// one above the other.
struct ImportCheckRow: View {
    let row: CheckRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ row: CheckRow) { self.row = row }

    private var pill: (text: String, status: StatusPill.Status)? {
        switch row.mark {
        case .read: (PhoneImportCopy.readFromFile, .done)
        case .toCheck: (PhoneImportCopy.toCheck, .waiting)
        case .none: nil
        }
    }

    var body: some View {
        ImportFieldRow(label: row.label, pill: pill) {
            if row.isFigure, row.label == "Period", dynamicTypeSize >= .xxxLarge {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        Text(day).figureText(.shrink()).mangoFont(.body)
                    }
                }
            } else if row.isFigure {
                Text(row.value.figuresUnbroken).figureText(.shrink()).mangoFont(.body)
            } else {
                Text(row.value).mangoFont(.body).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// "1 Sep 2026 – 30 Sep 2026" as its two days.
    private var days: [String] {
        row.value.components(separatedBy: "–").map {
            $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{2060}"))).figuresUnbroken
        }
    }
}

/// A count and what it counts ("14" "new rows"): one element for VoiceOver.
struct ImportCountTile: View {
    let count: Int
    let caption: String
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(count)).figureText(.shrink()).mangoFont(.title2, weight: .bold)
            Text(caption).mangoFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(MangoSpacing.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: MangoRadius.card, style: .continuous).fill(theme.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(String(count))
    }
}

/// The page dots under the sheet's title: "File 2 of 3" for VoiceOver.
struct ImportPageDots: View {
    let batch: PhoneImportBatch
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            Text(batch.positionLabel).foregroundStyle(.secondary).figureText().mangoFont(.footnote)
            if batch.count > 1 {
                HStack(spacing: 6) {
                    ForEach(batch.files.indices, id: \.self) { index in
                        Circle()
                            .fill(index == batch.current ? theme.accent : theme.separator)
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(batch.positionLabel)
    }
}

extension PhoneImportBatch.Outcome {
    /// The words a settled file ends on, for the summary and a swipe back to it.
    var settledWords: String {
        switch self {
        case .waiting: ""
        case .imported(_, _, let rows, _, _): PhoneImportBatchCopy.newRows(rows)
        case .alreadyInMango: "Already in Mango"
        case .saved(_, _, let linked): linked ? "Saved and linked" : "Saved"
        case .sentToMac: "Sent to the Mac"
        case .notImported: PhoneImportCopy.notImported
        case .cantRead: PhoneImportCopy.cantRead
        }
    }
}
