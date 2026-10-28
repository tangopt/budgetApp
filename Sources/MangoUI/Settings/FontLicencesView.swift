import SwiftUI
import BudgetCore

/// The ten bundled fonts and where each one's SIL Open Font Licence sits under `Phone/Fonts` (and, in the app,
/// under the bundle's `Fonts` folder).
public enum FontLicences {
    public struct Entry: Identifiable, Equatable {
        public var id: String { path }
        public let name: String
        /// Relative to `Phone/Fonts`: "Inter/OFL.txt".
        public let path: String
    }

    public static var entries: [Entry] {
        FontCatalog.all.compactMap { font in
            guard font.kind == .bundled, let file = font.files.first, let folder = file.split(separator: "/").first else { return nil }
            return Entry(name: font.name, path: "\(folder)/OFL.txt")
        }
    }

    /// The licence text from the app bundle; nil where the file isn't bundled (a test host).
    public static func text(_ entry: Entry, bundle: Bundle = .main) -> String? {
        guard let url = bundle.resourceURL?.appending(path: "Fonts").appending(path: entry.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Settings ▸ About ▸ Font licences.
struct FontLicencesView: View {
    var body: some View {
        List {
            Section {
                ForEach(FontLicences.entries) { entry in
                    NavigationLink(entry.name) { FontLicenceText(entry: entry) }
                        .frame(minHeight: 44)
                }
            } footer: {
                Text("These fonts are used under the SIL Open Font License.")
            }
        }
        .navigationTitle("Font licences")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct FontLicenceText: View {
    let entry: FontLicences.Entry

    var body: some View {
        ScrollView {
            Text(FontLicences.text(entry) ?? "The licence text isn't available in this build.")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(entry.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
