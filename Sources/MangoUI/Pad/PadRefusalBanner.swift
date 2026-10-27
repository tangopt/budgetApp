import SwiftUI
import BudgetCore
import GRDB
import struct BudgetCore.Transaction

/// Why an iPad edit wasn't saved, shown under the row it was made on (step 8): an `InlineBanner` with the refusal's
/// own copy (`DeviceWriteRefusal`, `AccessDenied`, `EvidenceLinkGuard.Failure`). Nothing when `message` is nil.
public struct PadRefusalBanner: View {
    public let message: String?

    public init(message: String?) {
        self.message = message
    }

    public var body: some View {
        if let message {
            InlineBanner(tone: .amber, text: message)
                .accessibilityIdentifier("pad-refusal")
        }
    }
}

/// The iPad screens' writes (step 8, Tasks 8 and 10): every action goes through `DeviceWriter.writeCheckingFiledYears`
/// in the model's `area` (Property's screens, or Documents and Missing evidence). Whether the user may edit is read from the writer; a refusal is kept against the row it was made on
/// until another write on that row saves. With no writer (demo data) nothing is offered and nothing is said.
@MainActor
public final class PadWriteModel: ObservableObject {
    /// A refusal and the row it belongs to.
    public struct Refusal: Equatable, Sendable {
        public var rowId: String
        public var message: String

        public init(rowId: String, message: String) {
            self.rowId = rowId
            self.message = message
        }
    }

    public let writer: DeviceWriter?
    /// The area these screens edit.
    public let area: AccessArea
    @Published public private(set) var canEdit: Bool
    /// Changes made here that can't go up any more (the user lost Edit before they were sent).
    @Published public private(set) var unsent = 0
    @Published public private(set) var refusal: Refusal?

    public init(writer: DeviceWriter?, area: AccessArea = .property) {
        self.writer = writer
        self.area = area
        canEdit = false
    }

    /// Shows an already known state (the snapshot routes' first frame).
    public func preload(canEdit: Bool, refusal: Refusal? = nil) {
        self.canEdit = canEdit
        self.refusal = refusal
    }

    /// Keeps `message` under row `rowId` for something refused before it reached the writer (a form's own check).
    public func refuse(rowId: String, message: String) {
        refusal = Refusal(rowId: rowId, message: message)
    }

    /// Reads again whether the user has Edit on the area, and what is left unsent.
    public func refresh() async {
        guard let writer else {
            canEdit = false
            unsent = 0
            return
        }
        canEdit = await writer.canEdit(area)
        unsent = canEdit ? 0 : await writer.unsentChanges()
    }

    /// What the screens read with (`DeviceWriter.readScope`): with no writer (demo data) everything.
    public func readScope() async -> DeviceReadScope {
        guard let writer else { return .everything }
        return await writer.readScope()
    }

    /// Shown in place of the actions: the user views the area only.
    public var viewOnlyMessage: String? {
        writer != nil && !canEdit ? DeviceWriteCopy.viewOnly(area) : nil
    }

    /// "N changes not sent — you can no longer change this", while some are.
    public var unsentMessage: String? {
        !canEdit && unsent > 0 ? DeviceWriteCopy.notSent(unsent) : nil
    }

    /// The refusal under row `rowId`, if any.
    public func message(for rowId: String) -> String? {
        refusal?.rowId == rowId ? refusal?.message : nil
    }

    /// Runs `body` through the writer in the area, checking filed years: true when it saved. A refusal is kept under `rowId`
    /// (with its own copy, else `DeviceWriteCopy.notSaved`); the user's Edit is read again after one.
    @discardableResult
    public func perform(rowId: String, origin: WriteOrigin, edit: String, scope: FiledYearEditCheck.Scope,
                        _ body: @escaping @Sendable (Database) throws -> Void) async -> Bool {
        await saving(rowId: rowId, origin: origin, edit: edit, scope: scope, body) != nil
    }

    /// `perform`, giving what `body` returned (nil: nothing saved, the refusal kept under `rowId`).
    public func saving<T: Sendable>(rowId: String, origin: WriteOrigin, edit: String, scope: FiledYearEditCheck.Scope,
                                    _ body: @escaping @Sendable (Database) throws -> T) async -> T? {
        guard let writer, canEdit else { return nil }
        do {
            let result = try await writer.writeCheckingFiledYears(area, origin: origin, edit: edit, scope: scope, body)
            if refusal?.rowId == rowId { refusal = nil }
            return result
        } catch {
            refusal = Refusal(rowId: rowId, message: Self.text(for: error))
            if error is AccessDenied { await refresh() }
            return nil
        }
    }

    nonisolated static func text(for error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        if let error = error as? RechargeError { return error.userMessage }
        if let error = error as? RentPaymentError { return error.userMessage }
        return DeviceWriteCopy.notSaved
    }
}

/// The view-only and unsent notices a Property screen shows above its rows.
struct PadWriteNotices: View {
    @ObservedObject var write: PadWriteModel

    var body: some View {
        if write.viewOnlyMessage != nil || write.unsentMessage != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let text = write.viewOnlyMessage { InlineBanner(tone: .neutral, text: text) }
                if let text = write.unsentMessage { InlineBanner(tone: .amber, text: text) }
            }
        }
    }
}

/// One thing an iPad action can be linked to: a document, a bank movement, a tenant credit.
struct PadChoice: Identifiable, Equatable {
    var id: Int64
    var title: String
    var date: Date?
    var amountMinorUnits: Int?
}

/// An action waiting for its choice: the sheet lists `choices`, each with an explicit button.
struct PadChoiceRequest: Identifiable {
    let id = UUID()
    var title: String
    var button: String
    var empty: String
    var currency: Currency
    var choices: [PadChoice]
    var choose: (Int64) async -> Void
}

/// The sheet an action's choice is made in: nothing changes until a row's button is pressed.
struct PadChoiceSheet: View {
    let request: PadChoiceRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if request.choices.isEmpty {
                    Text(request.empty).foregroundStyle(.secondary)
                }
                ForEach(request.choices) { choice in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(choice.title).font(.body)
                            HStack(spacing: 8) {
                                if let date = choice.date { DateText(date, font: .subheadline) }
                                if let amount = choice.amountMinorUnits {
                                    MoneyText(minorUnits: amount, currency: request.currency, role: .neutral, font: .subheadline)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button(request.button) {
                            Task {
                                await request.choose(choice.id)
                                dismiss()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

extension PadChoice {
    static func transaction(_ transaction: Transaction) -> PadChoice {
        PadChoice(id: transaction.id ?? 0, title: transaction.rawDescription, date: transaction.date,
                  amountMinorUnits: transaction.amountMinorUnits)
    }
}
