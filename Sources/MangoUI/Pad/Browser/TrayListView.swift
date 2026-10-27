import SwiftUI
import BudgetCore

/// The Downloads tray beside the site (step 10, Task 5): each PDF waiting to be checked, newest first. A row is the
/// file's name (truncated in the middle) and its summary (where it came from, when, how big), with Check (the
/// magnifier) and Discard. Nothing here is synced: a file leaves the tray once it is checked and saved, or discarded.
struct TrayListView: View {
    let items: [TrayItem]
    let onCheck: (TrayItem) -> Void
    let onDiscard: (TrayItem) -> Void
    var now = Date()
    @Environment(\.phoneTheme) private var theme

    /// "Downloads (2)".
    static func title(count: Int) -> String { count == 0 ? "Downloads" : "Downloads (\(count))" }

    /// The row's summary: "example.test · 14:05 · 120 KB" (a day before today shows its date; a shared file says so).
    static func summary(_ item: TrayItem, now: Date, calendar: Calendar = .current) -> String {
        source(item) + " · " + figures(item, now: now, calendar: calendar)
    }

    /// Where it came from: the site's host, or "Shared to Mango".
    static func source(_ item: TrayItem) -> String { item.sourceHost ?? "Shared to Mango" }

    /// When and how big: "14:05 · 120 KB" (one line, never wrapped).
    static func figures(_ item: TrayItem, now: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime
        style.timeZone = calendar.timeZone
        let when = calendar.isDate(item.receivedAt, inSameDayAs: now)
            ? item.receivedAt.formatted(style.hour().minute())
            : item.receivedAt.formatted(style.day().month(.abbreviated))
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)
        return "\(when) · \(size)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.title(count: items.count)).figureText()
                .font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: RowAction.download.systemImage).font(.title2).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("PDFs you download here, or share to Mango, wait here to be checked.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity).padding(24)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ item: TrayItem) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.richtext").foregroundStyle(theme.accent).accessibilityHidden(true)
                .padding(.trailing, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                // Where it came from and when on one line; under each other when that doesn't fit (larger text).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        Text(Self.source(item) + " · ").lineLimit(1).fixedSize()
                        Text(Self.figures(item, now: now)).figureText()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.source(item)).lineLimit(1).truncationMode(.middle)
                        Text(Self.figures(item, now: now)).figureText()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RowIconButton(.check, item: item.fileName, size: .small) { onCheck(item) }
            RowIconButton(.discard, item: item.fileName, size: .small) { onDiscard(item) }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}
