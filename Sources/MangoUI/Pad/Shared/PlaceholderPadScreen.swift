import SwiftUI

/// A sidebar section whose screen a later step 10 task builds (Money, Calendar, Checks, Profile).
struct PlaceholderPadScreen: View {
    let section: PadSection
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        NavigationStack {
            ContentUnavailableView(section.title, systemImage: section.systemImage,
                                   description: Text("This screen is coming to the iPad soon."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.background)
                .navigationTitle(section.title)
        }
    }
}
