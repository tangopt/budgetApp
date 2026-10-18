// App/DesignSystem/EmptyState.swift
import SwiftUI

/// A screen's or a panel's "nothing here yet" (spec §1.10): an icon (`.largeTitle`,
/// secondary), a `.title3` semibold line, a `.callout` secondary sentence, centred, and the
/// one or two things to do (the main one prominent). Place it with `fillingScreen()` (a whole
/// screen) or `inPanel()` (inside a `Panel`). A sheet's empty area is `SheetEmptyState`; a list
/// with nothing in it, one `.callout` secondary sentence.
struct EmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    let actions: Actions

    init(systemImage: String, title: String, message: String? = nil, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Actions.self != EmptyView.self {
                HStack(spacing: 8) { actions }.padding(.top, 4)
            }
        }
        .frame(maxWidth: 460)
        .accessibilityElement(children: .contain)
    }

    /// A whole screen's empty state, centred in the screen.
    func fillingScreen() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A panel's empty state, centred across it with room above and below.
    func inPanel() -> some View {
        frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}
