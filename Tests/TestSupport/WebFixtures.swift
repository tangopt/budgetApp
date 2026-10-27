import Foundation

/// The local web fixtures (`Fixtures/web`): a sign-in form, a one-page PDF bill and an HTML page named `.pdf`. Tests use
/// these, never a real site.
public enum WebFixtures {
    /// The fixture `name`, copied into a fresh temporary folder (a test may move or delete it).
    public static func copy(_ name: String) throws -> URL {
        guard let source = Bundle.module.url(forResource: "Fixtures/web/" + name, withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("web-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }
}
