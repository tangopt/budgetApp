// App/DesignSystem/NoteButton.swift
import SwiftUI

/// A transaction's note (spec §5): a `note.text` icon, filled when there is a note, that
/// opens a small popover text field. The edit is handed to `onSave` when the popover
/// closes, and only if it changed.
struct NoteButton: View {
    let note: String?
    let onSave: (String?) -> Void

    @State private var isPresented = false
    @State private var text = ""

    private var hasNote: Bool { !(note ?? "").isEmpty }

    var body: some View {
        Button {
            text = note ?? ""
            isPresented = true
        } label: {
            NoteIcon(filled: hasNote)
        }
        .buttonStyle(.borderless)
        .help(hasNote ? (note ?? "") : "Add a note")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
                Text("Note").font(.headline)
                TextField("Note", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .lineLimit(1...4)
                    .onSubmit { isPresented = false }
                HStack {
                    Spacer()
                    Button("Done") { isPresented = false }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .popoverPadding()
            .frame(width: 280)
        }
        .onChange(of: isPresented) { _, presented in
            guard !presented else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let edited: String? = trimmed.isEmpty ? nil : trimmed
            if edited != note { onSave(edited) }
        }
    }
}

/// `note.text`, "filled" (white on an accent chip — SF Symbols has no filled variant) when
/// the transaction has a note. Also used read-only in lists.
struct NoteIcon: View {
    let filled: Bool

    var body: some View {
        Image(systemName: "note.text")
            .foregroundStyle(filled ? Color.white : Color.secondary)
            .padding(2)
            .background(filled ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }
}
