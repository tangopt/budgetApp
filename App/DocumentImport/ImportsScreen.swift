// App/DocumentImport/ImportsScreen.swift
import SwiftUI
import BudgetCore

/// The Imports screen: the files being read (with Cancel), the review of what they hold, or —
/// with nothing in progress — the last result and the import history (`ImportHistoryView`). Files come from
/// File ▸ Import… (⇧⌘I), the toolbar's Import… button, a drop anywhere on the window or the
/// button here; all go to the window's `ImportCenterModel`.
struct ImportsScreen: View {
    @ObservedObject var center: ImportCenterModel
    @Environment(\.documentImport) private var documentImport

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenMetrics.spacing) {
            switch center.phase {
            case .reading(let progress):
                ImportReadingPanel(progress: progress, addingToReview: center.hasOpenReview, cancel: center.cancelReading)
                if center.hasOpenReview {
                    ImportReviewView(center: center, pickFiles: pickFiles).disabled(true)
                } else {
                    Spacer(minLength: 0)
                }
            case .review, .applying:
                ImportReviewView(center: center, pickFiles: pickFiles)
            case .idle, .finished, .failed:
                ImportHistoryView(center: center, pickFiles: pickFiles)
            }
        }
        .padding(ScreenMetrics.padding)
        // Measured at this width, so the window's minimum isn't that of every line wrapped
        // at the narrowest (spec §6.1: fits 1100×700).
        .frame(minWidth: center.review == nil ? ImportHistoryView.minimumWidth : ImportReviewView.minimumWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { center.loadRuns() }
    }

    private func pickFiles() {
        documentImport?.pickFiles(.none, "Imports screen")
    }
}

// MARK: Reading

/// "Reading 3 of 12 — <file>" while the files are read, then the pass under way ("Checking
/// filed tax years (12 of 49)…"); its progress bar (indeterminate without a count) and Cancel.
private struct ImportReadingPanel: View {
    let progress: ImportProgress
    let addingToReview: Bool
    let cancel: () -> Void

    var body: some View {
        Panel(addingToReview ? "Adding files to the review" : "Reading files",
              subtitle: "Nothing is saved until you confirm the import",
              accessory: { Button("Cancel", action: cancel).controlSize(.small) }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    if let stage = progress.stageText {
                        Text(stage).figureText()
                    } else if progress.total == 0 {
                        Text("Finding the files…")
                    } else {
                        Text("Reading \(progress.completed) of \(progress.total)").figureText()
                        if let file = progress.currentFile {
                            Text("— \(file)").lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .font(.callout)
                if progress.total == 0 {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
