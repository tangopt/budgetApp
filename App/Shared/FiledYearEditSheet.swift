// App/Shared/FiledYearEditSheet.swift
import SwiftUI
import BudgetCore
import GRDB
import struct BudgetCore.Category
import struct BudgetCore.Transaction

/// A save checked against the filed years (`FiledYearEditCheck`): done, as `SaveOutcome` says, or
/// waiting on the question (nothing written yet).
enum CheckedSaveOutcome: Equatable {
    case done(SaveOutcome)
    case asks(FiledYearEditCheck.Question)
}

extension DatabaseQueue {
    /// `apply` in one write, through the filed-year check: saved, or (without `resolution`) the
    /// question with nothing written.
    func checkedWrite<T>(edit: String, resolution: FiledYearEditCheck.Resolution?,
                         _ apply: (Database) throws -> T) throws -> FiledYearEditCheck.Outcome<T> {
        try write { db in
            try FiledYearEditCheck.save(db: db, edit: edit, resolution: resolution, now: AppClock.now) { try apply(db) }
        }
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
            Text(question.years.count == 1 ? "A filed return would change" : "Filed returns would change")
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

/// A screen's transaction write (its `manualWrite`: refusals as messages, then the reload) with the
/// edit checked against the filed years first.
enum FiledYearCheckedSave {
    static func save(edit: String, resolution: FiledYearEditCheck.Resolution?,
                     through write: ((Database) throws -> Void) -> SaveOutcome,
                     _ apply: @escaping (Database) throws -> Void) -> CheckedSaveOutcome {
        var question: FiledYearEditCheck.Question?
        let outcome = write { db in
            question = nil
            if case .asks(let asked) = try FiledYearEditCheck.save(db: db, edit: edit, resolution: resolution, now: AppClock.now, { try apply(db) }) {
                question = asked
            }
        }
        if case .failed = outcome { return .done(outcome) }
        return question.map(CheckedSaveOutcome.asks) ?? .done(outcome)
    }
}
