import SwiftUI

/// A figure tile (design review §3.4): a label (footnote, secondary), the figure, a caption, on the card surface. With
/// an `action` the whole tile is a button to its home screen. In a `PadTileGrid` every tile of a row takes the row's
/// tallest height.
struct Tile<Value: View, Caption: View>: View {
    let title: String
    let value: Value
    let caption: Caption
    let action: (() -> Void)?

    init(_ title: String, action: (() -> Void)? = nil, @ViewBuilder value: () -> Value,
         @ViewBuilder caption: () -> Caption = { EmptyView() }) {
        self.title = title
        self.action = action
        self.value = value()
        self.caption = caption()
    }

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: MangoSpacing.xs - 2) {
            Text(title).mangoFont(.footnote).foregroundStyle(.secondary).lineLimit(2)
            value
            caption.mangoFont(.footnote).foregroundStyle(.secondary)
        }
        .padding(MangoSpacing.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mangoSurface()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
