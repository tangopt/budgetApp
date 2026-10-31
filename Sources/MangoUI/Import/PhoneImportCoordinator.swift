import SwiftUI
import UniformTypeIdentifiers
import BudgetCore

/// The files the Files picker offers: PDF, CSV, OFX/QFX and photos (statements and documents), or PDF and photos only
/// when the import came from a bill or receipt.
public enum PhoneImportTypes {
    public static func contentTypes(documentsOnly: Bool) -> [UTType] {
        var types: [UTType] = [.pdf, .image]
        if !documentsOnly {
            types.append(.commaSeparatedText)
            types += ["ofx", "qfx"].compactMap { UTType(filenameExtension: $0) }
        }
        return types
    }
}

/// Where an import starts and ends on the iPhone: the entry points ask for the Files picker (with a preset), a file shared
/// to Mango is queued until the app is unlocked, and the open import is presented as a sheet. Without a source (demo
/// data, before the database opens) the entry points are absent and a shared file gets a notice.
@MainActor @Observable
public final class PhoneImportCoordinator {
    public var source: PhoneImportSource? {
        didSet { Task { await refreshAccess() } }
    }
    /// The open import, presented as a sheet.
    public var session: PhoneImportModel?
    public var showsPicker = false
    public private(set) var pickerPreset = PhoneImportModel.Preset()
    /// Said once (an alert): a file shared where nothing can take it.
    public var notice: String?
    /// The Accounts entries are offered (an admin; a member while `membersImport` is off sees none).
    public private(set) var offersStatements = false
    public private(set) var isLocked = true
    @ObservationIgnored private var queued: [(urls: [URL], removing: [URL])] = []

    public init(source: PhoneImportSource? = nil) {
        self.source = source
    }

    /// For the snapshot routes: a coordinator whose Import buttons are shown.
    init(snapshotSource source: PhoneImportSource) {
        self.source = source
        offersStatements = true
    }

    /// The incoming copies still waiting to open (the launch sweep leaves them alone).
    public var queuedURLs: Set<URL> { Set(queued.flatMap(\.removing).map(\.standardizedFileURL)) }

    /// Whether the entry points show at all.
    public var isAvailable: Bool { source != nil }

    public func refreshAccess() async {
        offersStatements = await source?.offersStatementImport() ?? false
    }

    /// An entry point's tap: the Files picker, with the account (or bill) the import started from.
    public func requestPicker(_ preset: PhoneImportModel.Preset = PhoneImportModel.Preset()) {
        guard source != nil else { return }
        pickerPreset = preset
        showsPicker = true
    }

    /// The picker's answer (a cancelled picker is an empty list).
    public func picked(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        open(urls: urls, removing: [], preset: pickerPreset)
    }

    /// "Open in Mango" from Files, Mail or Safari: the file waits behind the lock screen and opens after unlock. `removing`:
    /// the system's incoming copy, deleted once Mango has its own.
    public func receiveShared(_ url: URL) {
        guard source != nil else {
            try? FileManager.default.removeItem(at: url)
            notice = PhoneImportCopy.notAvailableHere
            return
        }
        queued.append(([url], [url]))
        openQueued()
    }

    /// The app locked (an open import is closed: its copies released) or unlocked (a waiting share opens).
    public func setLocked(_ locked: Bool) {
        isLocked = locked
        if locked {
            close()
        } else {
            openQueued()
        }
    }

    private func openQueued() {
        guard !isLocked, session == nil, !queued.isEmpty else { return }
        let urls = queued.flatMap(\.urls)
        let removing = queued.flatMap(\.removing)
        queued = []
        open(urls: urls, removing: removing, preset: PhoneImportModel.Preset())
    }

    private func open(urls: [URL], removing: [URL], preset: PhoneImportModel.Preset) {
        guard let source else { return }
        let model = PhoneImportModel(source: source, preset: preset)
        session = model
        Task { await model.start(urls: urls, removing: removing) }
    }

    /// The sheet closed: its copies are released, and a file shared meanwhile opens next.
    public func close() {
        session?.close()
        session = nil
        openQueued()
    }
}

extension PhoneImportCopy {
    public static let notAvailableHere = "Importing isn’t available here. Open Mango with your own data and share the file again."
}

private struct PhoneImportKey: EnvironmentKey {
    static let defaultValue: PhoneImportCoordinator? = nil
}

extension EnvironmentValues {
    /// The iPhone's import, for the Import buttons (nil: none offered).
    public var phoneImport: PhoneImportCoordinator? {
        get { self[PhoneImportKey.self] }
        set { self[PhoneImportKey.self] = newValue }
    }
}

/// The Import button of Accounts and of an account's page: an icon button, 44 pt, absent unless statements can be
/// imported here.
struct PhoneImportButton: View {
    let preset: PhoneImportModel.Preset
    @Environment(\.phoneImport) private var coordinator

    var body: some View {
        if let coordinator, coordinator.isAvailable, coordinator.offersStatements {
            Button { coordinator.requestPicker(preset) } label: {
                Image(systemName: "tray.and.arrow.down")
                    .mangoFont(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Import")
            .accessibilityHint("Choose statements or documents from Files")
        }
    }
}

extension View {
    /// The Files picker, the import sheet and the notice, for the tabs' root.
    func phoneImportHost(_ coordinator: PhoneImportCoordinator, onOpenAccount: @escaping (Int64) -> Void,
                         onReviewUncategorised: @escaping () -> Void) -> some View {
        modifier(PhoneImportHost(coordinator: coordinator, onOpenAccount: onOpenAccount, onReviewUncategorised: onReviewUncategorised))
    }
}

private struct PhoneImportHost: ViewModifier {
    @Bindable var coordinator: PhoneImportCoordinator
    let onOpenAccount: (Int64) -> Void
    let onReviewUncategorised: () -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.phoneImport, coordinator)
            .fileImporter(isPresented: $coordinator.showsPicker,
                          allowedContentTypes: PhoneImportTypes.contentTypes(documentsOnly: coordinator.pickerPreset.documentsOnly),
                          allowsMultipleSelection: true) { coordinator.picked($0) }
            .sheet(item: $coordinator.session) { session in
                PhoneImportSheet(model: session, onClose: { coordinator.close() },
                                 onOpenAccount: { id in coordinator.close(); onOpenAccount(id) },
                                 onReviewUncategorised: { coordinator.close(); onReviewUncategorised() })
            }
            .alert(coordinator.notice ?? "", isPresented: Binding(get: { coordinator.notice != nil }, set: { if !$0 { coordinator.notice = nil } })) {
                Button("OK", role: .cancel) { coordinator.notice = nil }
            }
    }
}
