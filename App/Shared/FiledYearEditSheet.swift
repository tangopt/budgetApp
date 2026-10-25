// App/Shared/FiledYearEditSheet.swift
import SwiftUI
import BudgetCore
import GRDB
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// Runs edits through the filed-year check (`FiledYearEditCheck`, plan Task 14) off the main
/// thread, and holds the question one of them asks until it's answered (`.filedYearGate(_:)`
/// presents it). A screen's view model has one for its own actions; a sheet that saves has its
/// own, so the question shows on top of it.
@MainActor
final class FiledYearGate: ObservableObject {
    @Published var pending: FiledYearPending?
    /// A check or a save is under way (a sheet keeps its Save off meanwhile).
    @Published private(set) var isRunning = false

    /// `apply` in one write of `dbQueue`, through the check, on a background queue. `scope` is
    /// worked out in that write, before `apply`. Saved, or refused: `done` (on the main actor) with
    /// the result. A question: `pending`, and its answer runs it again (then `done`); Cancel
    /// writes nothing and calls nothing.
    func run<T>(_ dbQueue: DatabaseQueue, edit: String, scope: @escaping (Database) throws -> FiledYearEditCheck.Scope,
                resolution: FiledYearEditCheck.Resolution? = nil,
                _ apply: @escaping (Database) throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        isRunning = true
        let now = AppClock.now
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try dbQueue.write { db in
                    try FiledYearEditCheck.save(db: db, edit: edit, scope: try scope(db), resolution: resolution, now: now) { try apply(db) }
                }
            }
            DispatchQueue.main.async {
                self.isRunning = false
                switch result {
                case .success(.saved(let value)):
                    done(.success(value))
                case .success(.asks(let question)):
                    self.pending = FiledYearPending(question: question) { [weak self] answer in
                        self?.run(dbQueue, edit: edit, scope: scope, resolution: answer, apply, done: done)
                    }
                case .failure(let error):
                    done(.failure(error))
                }
            }
        }
    }

    /// `run` with the scope known up front.
    func run<T>(_ dbQueue: DatabaseQueue, edit: String, scope: FiledYearEditCheck.Scope,
                _ apply: @escaping (Database) throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        run(dbQueue, edit: edit, scope: { _ in scope }, apply, done: done)
    }
}

extension View {
    /// Presents `gate`'s question.
    func filedYearGate(_ gate: FiledYearGate) -> some View {
        modifier(FiledYearGateModifier(gate: gate))
    }
}

private struct FiledYearGateModifier: ViewModifier {
    @ObservedObject var gate: FiledYearGate

    func body(content: Content) -> some View {
        content.filedYearQuestion($gate.pending)
    }
}

extension Result where Failure == Error {
    /// The error, nil when it succeeded.
    var failure: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// A save through a sheet's gate: the input, the sheet's gate (its question shows on the sheet),
/// and what to do once saved or refused (not called on Cancel).
typealias CheckedSave<Input> = (Input, FiledYearGate, @escaping (SaveOutcome) -> Void) -> Void

extension FiledYearEditCheck.Scope {
    /// Edit transaction's Save of `id`: its category, and a manual transaction's new date.
    static func transactionEdit(id: Int64, changes: TransactionEditChanges) -> Self {
        Self(transactionIds: [id], dates: changes.manual.map { [$0.date] } ?? [], categoryIds: [changes.categoryId])
    }

    /// Add transaction…: the new row's date and category.
    static func added(_ input: ManualTransactionInput) -> Self {
        Self(dates: [input.date], categoryIds: [input.categoryId])
    }
}

/// What the filed-year question names an edit by (the notes it leaves say it too).
enum FiledYearEditNames {
    /// Edit transaction's Save: "Categorised as Repairs" when the category changes to one, else
    /// "Edited by hand". `transactionId`'s category before is read here.
    static func transactionEdit(_ changes: TransactionEditChanges, transactionId: Int64, dbQueue: DatabaseQueue,
                                categories: [Category]) -> String {
        let before = try? dbQueue.read { db in try Transaction.fetchOne(db, key: transactionId)?.categoryId }
        if let id = changes.categoryId, id != before ?? nil, let name = categories.first(where: { $0.id == id })?.name {
            return "Categorised as \(name)"
        }
        return "Edited by hand"
    }

    /// "Categorised as Repairs".
    static func categorised(_ categoryId: Int64, categories: [Category]) -> String {
        categories.first { $0.id == categoryId }.map { "Categorised as \($0.name)" } ?? "Categorised by hand"
    }
}

/// An edit waiting on the filed-year question (`FiledYearEditCheck`): the question, and what
/// each answer does (the edit saved again with it). Cancel only drops it: nothing was written.
struct FiledYearPending: Identifiable {
    let id = UUID()
    let question: FiledYearEditCheck.Question
    let answer: (FiledYearEditCheck.Resolution) -> Void
}

extension View {
    /// Presents `pending`'s question (plan Task 14); an answer clears it, then runs it.
    func filedYearQuestion(_ pending: Binding<FiledYearPending?>) -> some View {
        sheet(item: pending) { item in
            FiledYearEditSheet(question: item.question) { resolution in
                pending.wrappedValue = nil
                if let resolution { item.answer(resolution) }
            }
        }
    }
}

/// "This changes your filed 2022/23 return:", each box that moves with its figures before and
/// after, and three answers: Mark as not counted for 2022/23 and save (when that keeps the
/// return as filed), Save anyway, Cancel.
struct FiledYearEditSheet: View {
    let question: FiledYearEditCheck.Question
    /// The answer; nil = Cancel.
    let onAnswer: (FiledYearEditCheck.Resolution?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
            Text(question.heading)
                .font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
                    ForEach(question.years) { year in
                        yearSection(year)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Cancel") { onAnswer(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Save anyway") { onAnswer(.saveAnyway) }
                if question.canMarkNotCounted {
                    Button(question.markTitle) { onAnswer(.markNotCounted) }
                        .buttonStyle(.borderedProminent).prominentTint()
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .padding(SheetMetrics.padding)
        .frame(width: SheetMetrics.listWidth, alignment: .topLeading)
    }

    private var note: String {
        if question.canMarkNotCounted {
            return "Marking it as not counted saves the change and leaves it off the \(question.markYears.count == 1 ? "year" : "years") "
                + "as filed. Saving anyway changes the figures and notes it on the year."
        }
        return "It can't be kept off the return by marking it as not counted. Saving anyway changes the figures and notes it on the year."
    }

    private func yearSection(_ year: FiledYearEditCheck.Question.Year) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(year.title)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(Array(year.lines.enumerated()), id: \.offset) { _, line in
                    GridRow {
                        Text((line.person.map { "\($0) · " } ?? "") + line.box)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(line.before) → \(line.after)")
                            .monospacedDigit()
                            .figureText()
                            .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.callout)
        }
    }
}
