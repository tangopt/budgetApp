import SwiftUI
import BudgetCore
#if canImport(UIKit)
import UIKit
#endif

/// The bundled fonts the theme sets draw in (seven since step 8) and where each one's SIL Open Font Licence sits under `Phone/Fonts` (and, in the app,
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

/// What a built app's `Fonts` folder is missing: a catalogue PostScript name that doesn't resolve to exactly that font
/// (a silent fall back to SF Pro), or a licence file that isn't bundled. The snapshot run fails on any.
public enum FontBundleCheck {
    public static func problems(bundle: Bundle = .main) -> [String] {
        var found: [String] = []
        for font in FontCatalog.all where font.kind == .bundled {
            for name in Set(font.postScriptNames.values).sorted() {
                #if canImport(UIKit)
                if UIFont(name: name, size: 12)?.fontName != name { found.append("\(font.name): \(name) doesn't resolve") }
                #endif
            }
            let folder = bundle.resourceURL?.appending(path: "Fonts")
            for file in font.files where folder.map({ !FileManager.default.fileExists(atPath: $0.appending(path: file).path) }) ?? true {
                found.append("\(font.name): \(file) isn't in the app bundle")
            }
        }
        for entry in FontLicences.entries where FontLicences.text(entry, bundle: bundle) == nil {
            found.append("\(entry.name): \(entry.path) isn't in the app bundle")
        }
        return found
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
        .mangoNavigationTitle("Font licences")
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
        .mangoNavigationTitle(entry.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
