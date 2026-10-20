// App/DocumentImport/ImportPreviewPanel.swift
import SwiftUI
import BudgetCore

/// The selected document, docked beside the review's list: the file, what it was recognised as
/// and why, the figures read (each with where it came from), where it will be filed, what it
/// will link to and why, the lines shown with it, a statement's rows held apart and the
/// information-only changes to a filed year. Its questions, with their answers, come first
/// under its title.
struct ImportPreviewPanel: View {
    let item: ImportItem?
    let children: [ImportItem]
    /// A left-out item that can come back (not a statement's rows while the statement is out).
    let canPutBack: Bool
    let targetNames: ImportTargetNames
    let isAnswerable: Bool
    /// (item, issue, answer).
    let resolve: (UUID, String?, ImportResolution) -> Void

    var body: some View {
        Panel(padding: 12, fillsHeight: true) {
            if let item {
                ScrollView {
                    ImportPreviewContent(item: item, children: children, canPutBack: canPutBack, targetNames: targetNames,
                                         isAnswerable: isAnswerable, resolve: resolve)
                        .padding(.trailing, 4)
                }
                // A new document starts at its top, with its own answers' state.
                .id(item.id)
            } else {
                Text("Select a document to see what was read from it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ImportPreviewContent: View {
    let item: ImportItem
    let children: [ImportItem]
    let canPutBack: Bool
    let targetNames: ImportTargetNames
    let isAnswerable: Bool
    let resolve: (UUID, String?, ImportResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DocumentThumbnail(url: item.file.url, height: 150)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if item.title != item.file.fileName {
                    Text(item.file.fileName).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(item.file.fileName)
                }
            }

            if item.section == .needsYou {
                block("Needs you") {
                    VStack(alignment: .leading, spacing: 10) {
                        let holds = item.issues.filter { ImportResolutions.onlyLeavesOut($0, in: item) }
                        if !holds.isEmpty {
                            // Held (a filed return would move, the check failed, the file can't be
                            // read): why, and one answer for the item — nothing else is asked.
                            ForEach(holds) { issue in
                                if ImportResolutions.isFiledYearHold(issue) {
                                    ImportHoldBanner(issue: issue)
                                } else {
                                    Label {
                                        Text(issue.reason.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
                                    } icon: {
                                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                }
                            }
                            Button(ImportIssueControls.leaveOutTitle) { resolve(item.id, nil, .leaveOut) }
                                .controlSize(.small)
                        } else {
                            ForEach(item.issues) { issue in
                                ImportIssueControls(item: item, issue: issue, targetNames: targetNames) { resolution in
                                    resolve(item.id, issue.id, resolution)
                                }
                            }
                            ImportItemChecks(item: item) { resolution in resolve(item.id, nil, resolution) }
                            if item.issues.isEmpty {
                                Button(ImportIssueControls.leaveOutTitle) { resolve(item.id, nil, .leaveOut) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .disabled(!isAnswerable)
            } else if item.isLeftOut {
                if canPutBack {
                    Button("Put back") { resolve(item.id, nil, .leaveOut) }
                        .controlSize(.small)
                        .disabled(!isAnswerable)
                } else {
                    Text("Comes back with its statement").font(.callout).foregroundStyle(.secondary)
                }
            } else if item.duplicate == nil {
                Button(ImportIssueControls.leaveOutTitle) { resolve(item.id, nil, .leaveOut) }
                    .controlSize(.small)
                    .disabled(!isAnswerable)
            }

            block("Recognised as \(item.recognition.kind.displayName)") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.recognition.reason.figuresUnbroken).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if item.recognition.confidence == .needsReview {
                        StatusPill("Check it", tone: .warning)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }

            if !item.facts.isEmpty {
                block("Figures") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(item.facts, id: \.field) { fact in
                            GridRow {
                                Text(fact.field.displayName).font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                                ImportFactValueView(value: fact.value)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                StatusPill(fact.source.pillTitle, tone: fact.confidence == .needsReview ? .warning : .neutral,
                                           help: fact.reason)
                            }
                        }
                    }
                }
            }

            if let placement = item.placement {
                block("Filed as") {
                    Text(placement.canonicalName.figuresUnbroken).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            if !item.links.isEmpty {
                block("Links to") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.links, id: \.entity) { link in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(link.label.figuresUnbroken).font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    if link.confidence == .needsReview {
                                        StatusPill("Check it", tone: .warning)
                                    }
                                }
                                if !link.reasons.isEmpty {
                                    Text(link.reasons.joined(separator: " · ").figuresUnbroken)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }

            if let duplicate = item.duplicate {
                block("Duplicate") {
                    Text(duplicate.of.figuresUnbroken).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !item.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(item.notes.enumerated()), id: \.offset) { _, note in
                        Text(note.figuresUnbroken).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ImportStatementLines(item: item, children: children, listsUnparsedLines: true)

            if !item.informationChanges.isEmpty {
                block("Changes to filed years (information only)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(item.informationChanges.enumerated()), id: \.offset) { _, impact in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(UKTaxYear(startYear: impact.startYear).label.unbroken) · \(impact.person)")
                                    .font(.caption.weight(.medium))
                                ForEach(Array(impact.informationChanges.enumerated()), id: \.offset) { _, line in
                                    Text("\(line.label): \(line.before.unbroken) → \(line.after.unbroken)")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.figuresUnbroken).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }
}
