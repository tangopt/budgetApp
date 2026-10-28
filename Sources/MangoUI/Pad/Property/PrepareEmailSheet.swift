import SwiftUI
import BudgetCore
import GRDB

/// Prepare email for a draft statement (step 10, Task 12): the package as the tenant will get it, read only, then opened
/// in Mail (or shared) for the person to check and send. Building it writes nothing; Mark as sent is a separate,
/// confirmed step (`RechargeEmailFlow`), through the device writer (`RechargeEmailPackage.markSent`), never on the
/// composer's dismissal.
@MainActor
public final class PrepareEmailModel: ObservableObject {
    public enum Load: Equatable {
        case loading
        case ready(RechargeEmailPackage)
        case failed(String)
    }

    public static let failureCopy = "Couldn't prepare the email. Try again."

    @Published public var language: RechargeEmailLanguage = .portuguese
    @Published public private(set) var load: Load = .loading
    @Published public private(set) var flow = RechargeEmailFlow()
    /// Why Mark as sent didn't save.
    @Published public private(set) var refusal: String?
    /// The day it was marked sent.
    @Published public private(set) var sentOn: Date?

    public let statementId: Int64
    /// "October 2026": the statement's month, for the title and the question.
    @Published public private(set) var monthName: String
    public let write: PadWriteModel
    private let dbQueue: any DatabaseReader
    private let open: (@Sendable (String) async throws -> URL)?
    private let today: () -> Date
    private let onMarkedSent: () async -> Void
    /// The library files already got onto this iPad, by document id.
    private var files: [Int64: URL] = [:]

    /// The previous email's folder: its copies go when the next one is prepared (the composer has them by then).
    private static var lastFolder: URL?

    public init(statementId: Int64, monthName: String, dbQueue: any DatabaseReader, write: PadWriteModel,
                open: (@Sendable (String) async throws -> URL)?, today: @escaping () -> Date,
                onMarkedSent: @escaping () async -> Void = {}) {
        self.statementId = statementId
        self.monthName = monthName
        self.dbQueue = dbQueue
        self.write = write
        self.open = open
        self.today = today
        self.onMarkedSent = onMarkedSent
    }

    public var package: RechargeEmailPackage? {
        if case .ready(let package) = load { return package }
        return nil
    }

    /// Where Open in Mail goes on this iPad.
    public func route(canSendMail: Bool? = nil) -> MailComposer.Route {
        MailComposer.route(canSendMail: canSendMail ?? MailComposer.canSendMail)
    }

    /// Shows an already built package (the snapshot routes' first frame).
    public func preload(_ package: RechargeEmailPackage) {
        load = .ready(package)
    }

    /// Gets the bills' files onto this iPad (each library file not here is downloaded), then builds the package in the
    /// chosen language. A file that can't be got is named in the package; the email isn't opened until it's here.
    public func reload() async {
        let id = statementId
        let reader = dbQueue
        guard let (month, documents) = try? await reader.read({ db in
            (try RechargeStatement.fetchOne(db, key: id)?.month, try RechargeEmailPackage.documents(db: db, statementId: id))
        }) else {
            load = .failed(Self.failureCopy)
            return
        }
        if let month { monthName = RechargeEmail.monthName(month, language: .english) }
        if let open {
            for document in documents {
                guard let documentId = document.id, files[documentId] == nil else { continue }
                if let url = try? await open(document.storedRelativePath) { files[documentId] = url }
            }
        }
        let found = files
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(RechargeEmail.temporaryFolderPrefix + UUID().uuidString, isDirectory: true)
        if let previous = Self.lastFolder { try? FileManager.default.removeItem(at: previous) }
        Self.lastFolder = folder
        let library = RechargeEmailPackage.Library(folder: folder) { document in document.id.flatMap { found[$0] } }
        let language = language
        do {
            load = .ready(try await reader.read { db in
                try RechargeEmailPackage.build(db: db, statementId: id, language: language, library: library)
            })
        } catch {
            load = .failed(PadWriteModel.text(for: error))
        }
    }

    // MARK: Flow

    /// The message is being opened in Mail or the share sheet.
    public func opened() { flow.open() }

    /// How the composer ended: only `.sent` asks "Mark as sent?"; nothing is marked by it.
    public func finished(_ outcome: MailComposer.Outcome) { flow.finished(outcome) }

    /// Mark as sent offered from the preview (she sent it another way): asks first. Only with Edit on Property.
    public func askToMarkSent() {
        guard write.canEdit else { return }
        flow.askToMarkSent()
    }

    public func decline() { flow.decline() }

    /// The person confirmed: the statement is marked sent today through the device writer; a refusal shows in the sheet.
    @discardableResult
    public func confirmMarkSent() async -> Bool {
        guard write.canEdit, let writer = write.writer, flow.confirm() else { return false }
        let day = today()
        do {
            try await RechargeEmailPackage.markSent(statementId: statementId, writer: writer, at: day)
            flow.marked(saved: true)
            refusal = nil
            sentOn = day
            await onMarkedSent()
            return true
        } catch {
            flow.marked(saved: false)
            refusal = PadWriteModel.text(for: error)
            if error is AccessDenied { await write.refresh() }
            return false
        }
    }
}

/// The sheet: the language, To, Subject, the text and the attachments as they'll go (read only), what's missing, then
/// "Open in Mail" (primary; the share sheet when Mail isn't set up) and "Share instead". After the composer, "Mark as
/// sent?" is asked only when Mail says it was sent; "Mark as sent…" stays offered (with Edit) for one sent another way.
struct PrepareEmailSheet: View {
    @StateObject private var model: PrepareEmailModel
    @ObservedObject private var write: PadWriteModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneTheme) private var theme

    init(model: @autoclosure @escaping () -> PrepareEmailModel, write: PadWriteModel) {
        _model = StateObject(wrappedValue: model())
        self.write = write
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background)
            .navigationTitle("Email · \(model.monthName)")
            .navigationBarTitleDisplayModeInline()
            .toolbar { ToolbarItem(placement: .confirmationAction) { PadIconButton(systemImage: "checkmark", label: "Done", prominent: true) { dismiss() } }.padFlatToolbarItem() }
        }
        .task {
            if model.package == nil { await model.reload() }
        }
        .onChange(of: model.language) { _, _ in Task { await model.reload() } }
        .confirmationDialog("Mark the \(model.monthName) statement as sent?",
                            isPresented: Binding(get: { model.flow.stage == .confirming }, set: { if !$0, model.flow.stage == .confirming { model.decline() } }),
                            titleVisibility: .visible) {
            Button("Mark as sent") { Task { await model.confirmMarkSent() } }
            Button("Not now", role: .cancel) { model.decline() }
        } message: {
            Text("Only once the email has gone. Its lines are then fixed, and the tenant's next credit can pay it.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.flow.stage == .markedSent {
            InlineBanner(tone: .neutral, text: "Marked as sent\(model.sentOn.map { " on \(PhoneDateFormat.day($0))" } ?? "").")
        }
        Picker("Language", selection: $model.language) {
            ForEach(RechargeEmailLanguage.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .disabled(model.flow.stage != .preview)
        switch model.load {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Getting the bills' PDFs…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .failed(let message):
            InlineBanner(tone: .amber, text: message)
            Button("Try again") { Task { await model.reload() } }.buttonStyle(.pad(.secondary))
        case .ready(let package):
            preview(package)
        }
    }

    @ViewBuilder
    private func preview(_ package: RechargeEmailPackage) -> some View {
        if let note = model.flow.note, model.flow.stage == .preview { InlineBanner(tone: .neutral, text: note) }
        PadRefusalBanner(message: model.refusal)
        ForEach(package.missing, id: \.self) { InlineBanner(tone: .amber, text: $0) }
        Card {
            VStack(alignment: .leading, spacing: 12) {
                field("To", package.to.isEmpty ? "No recipient" : package.to.joined(separator: ", "), secondary: package.to.isEmpty)
                Divider()
                field("Subject", package.subject)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Message").mangoFont(.footnote).foregroundStyle(.secondary)
                Text(package.body)
                    .mangoFont(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Email text as it will be sent")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Attachments").mangoFont(.footnote).foregroundStyle(.secondary)
                ForEach(package.attachments, id: \.url) { attachment in
                    Label {
                        Text(attachment.fileName).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "doc.richtext").foregroundStyle(theme.accent)
                    }
                    .mangoFont(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        actions(package)
    }

    private func field(_ label: String, _ value: String, secondary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).mangoFont(.footnote).foregroundStyle(.secondary)
            Text(value).mangoFont(.body).foregroundStyle(secondary ? .secondary : .primary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func actions(_ package: RechargeEmailPackage) -> some View {
        if !package.isReady {
            Button("Try again") { Task { await model.reload() } }.buttonStyle(.pad(.secondary))
        } else if model.flow.stage != .markedSent {
            if model.route() == .shareSheet {
                Text(Self.noMailCopy).mangoFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons(package) }
                VStack(alignment: .leading, spacing: 10) { buttons(package) }
            }
        }
    }

    @ViewBuilder
    private func buttons(_ package: RechargeEmailPackage) -> some View {
        Button("Open in Mail") { compose(package, route: nil) }
            .buttonStyle(.pad(.primary))
            .disabled(model.flow.stage != .preview)
        Button("Share instead") { compose(package, route: .shareSheet) }
            .buttonStyle(.pad(.secondary))
            .disabled(model.flow.stage != .preview)
        if write.canEdit {
            Button("Mark as sent…") { model.askToMarkSent() }
                .buttonStyle(.pad(.secondary))
                .disabled(model.flow.stage != .preview)
        }
    }

    static let noMailCopy = "Mail isn't set up on this iPad: Open in Mail shows the share sheet with the same text and files. Add the recipient there."

    private func compose(_ package: RechargeEmailPackage, route: MailComposer.Route?) {
        model.opened()
        #if canImport(UIKit)
        MailComposer.present(package: package, route: route) { outcome in model.finished(outcome) }
        #endif
    }
}
