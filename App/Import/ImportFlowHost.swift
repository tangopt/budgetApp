// App/Import/ImportFlowHost.swift
import SwiftUI
import BudgetCore
import UniformTypeIdentifiers

struct ImportFlowActions {
    let startCSV: () -> Void
    let startPDF: () -> Void
    /// Reopens the column-mapping sheet prefilled from the saved CSV profile — `nil` when the
    /// account has none yet.
    let editCSVMapping: (() -> Void)?
    /// "Reset column mapping…" (asks first) — `nil` when the account has no CSV profile.
    let resetCSVMapping: (() -> Void)?
    /// "Reset PDF layout…" (asks first) — `nil` when the account has no PDF profile.
    let resetPDFLayout: (() -> Void)?
}

/// One presentation of the column-mapping sheet: the file it's shown with, and whether the
/// file should be imported once the mapping is saved.
private struct CSVMappingRequest: Identifiable {
    let id = UUID()
    let fileURL: URL
    let csvText: String
    let existingProfile: ImportProfile?
    let stageAfterSave: Bool
}

/// Owns everything needed to START an import — the two file pickers, the column-mapping and
/// PDF-layout wizards, the "which file did the user pick" state, and resetting a saved
/// mapping or layout (spec 2026-10-15 §4). Hosted by the Dashboard's import card and the
/// Accounts screen (spec 2026-10-15 §1); progress and review are on the Import screen
/// (`ImportView`), which the sidebar shows and selects as soon as staging begins (`ContentView`).
struct ImportFlowHost<Content: View>: View {
    @ObservedObject var viewModel: ImportViewModel
    let account: Account
    let profileStore: ImportProfileStore
    @ViewBuilder let content: (ImportFlowActions) -> Content

    @State private var showFilePicker = false
    @State private var pendingCSVMapping: CSVMappingRequest?
    /// The last CSV picked here, so "Edit column mapping…" can reopen the sheet with it
    /// rather than asking for a file again.
    @State private var lastCSVFileURL: URL?
    /// Set by "Edit column mapping…" when there's no last file: the next picked file opens
    /// the sheet (prefilled from the saved profile) instead of importing straight away.
    @State private var editMappingAfterPick = false
    @State private var hasCSVProfile = false
    @State private var hasPDFProfile = false
    /// The format whose saved mapping/layout the reset alert is asking about.
    @State private var pendingReset: ImportFormat?
    @State private var showPDFPicker = false
    @State private var pendingPDFLines: [String]?
    @State private var pendingPDFFileName = "statement.pdf"

    var body: some View {
        content(ImportFlowActions(
            startCSV: { editMappingAfterPick = false; showFilePicker = true },
            startPDF: { showPDFPicker = true },
            editCSVMapping: hasCSVProfile ? { editCSVMapping() } : nil,
            resetCSVMapping: hasCSVProfile ? { pendingReset = .csv } : nil,
            resetPDFLayout: hasPDFProfile ? { pendingReset = .pdf } : nil
        ))
            .task(id: account.id) { refreshHasProfiles() }
            .onChange(of: account.id) { lastCSVFileURL = nil; editMappingAfterPick = false }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.commaSeparatedText]) { result in
                switch result {
                case .success(let url): handlePickedFile(url)
                case .failure(let error): viewModel.fail("Couldn't open the file: \(error.localizedDescription)")
                }
            }
            .fileImporter(isPresented: $showPDFPicker, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url): handlePickedPDF(url)
                case .failure(let error): viewModel.fail("Couldn't open the file: \(error.localizedDescription)")
                }
            }
            .alert(resetTitle, isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } })) {
                Button("Cancel", role: .cancel) { pendingReset = nil }
                Button("Reset", role: .destructive) { resetProfile() }
            } message: {
                Text(pendingReset == .pdf
                     ? "The next PDF import asks you to set up its layout again."
                     : "The next CSV import asks you to map its columns again.")
            }
            .sheet(item: $pendingCSVMapping) { request in
                CSVMappingWizardView(account: account, csvText: request.csvText, existingProfile: request.existingProfile) { profile in
                    pendingCSVMapping = nil
                    do {
                        try profileStore.save(profile)
                    } catch {
                        viewModel.fail("Couldn't save the column mapping: \(error.localizedDescription)")
                        return
                    }
                    hasCSVProfile = true
                    if request.stageAfterSave { startCSVStaging(request.fileURL) }
                }
            }
            .sheet(item: Binding(get: { pendingPDFLines.map { Wrapped(value: $0) } }, set: { _ in pendingPDFLines = nil })) { wrapped in
                PDFLayoutWizardView(account: account, sampleLines: wrapped.value) { profile in
                    pendingPDFLines = nil
                    do {
                        try profileStore.save(profile)
                        hasPDFProfile = true
                        guard let configJSON = profile.pdfLayoutConfig else {
                            viewModel.fail("The PDF layout couldn't be saved.")
                            return
                        }
                        let config = try PDFLayoutConfig.decode(configJSON)
                        startPDFStaging(lines: wrapped.value, config: config, fileName: pendingPDFFileName)
                    } catch {
                        viewModel.fail("Couldn't save the PDF layout: \(error.localizedDescription)")
                    }
                }
            }
    }

    private func startCSVStaging(_ url: URL) {
        Task { await viewModel.stageCSV(fileURL: url, account: account) }
    }

    private func startPDFStaging(lines: [String], config: PDFLayoutConfig, fileName: String) {
        Task { await viewModel.stagePDF(lines: lines, config: config, account: account, sourceFileName: fileName) }
    }

    private func handlePickedFile(_ url: URL) {
        viewModel.errorMessage = nil
        let editing = editMappingAfterPick
        editMappingAfterPick = false
        guard let accountId = account.id else {
            viewModel.fail("This account hasn't been saved yet.")
            return
        }
        guard let text = readCSV(at: url) else { return }
        lastCSVFileURL = url
        do {
            let existing = try profileStore.find(accountId: accountId, format: .csv)
            if existing != nil && !editing {
                startCSVStaging(url)
            } else {
                // A new mapping, or an edit with the file about to be imported: either way
                // the file is imported once the mapping is saved.
                pendingCSVMapping = CSVMappingRequest(fileURL: url, csvText: text, existingProfile: existing, stageAfterSave: true)
            }
        } catch {
            viewModel.fail("Couldn't load this account's import settings: \(error.localizedDescription)")
        }
    }

    /// "Edit column mapping…": reopens the sheet with the last file picked here (saving only
    /// replaces the mapping), or asks for the next file to import first.
    private func editCSVMapping() {
        viewModel.errorMessage = nil
        guard let accountId = account.id else {
            viewModel.fail("This account hasn't been saved yet.")
            return
        }
        guard let url = lastCSVFileURL else {
            editMappingAfterPick = true
            showFilePicker = true
            return
        }
        guard let text = readCSV(at: url) else {
            // The remembered file is gone or unreadable: forget it and ask for a file instead.
            lastCSVFileURL = nil
            editMappingAfterPick = true
            showFilePicker = true
            return
        }
        do {
            let existing = try profileStore.find(accountId: accountId, format: .csv)
            pendingCSVMapping = CSVMappingRequest(fileURL: url, csvText: text, existingProfile: existing, stageAfterSave: false)
        } catch {
            viewModel.fail("Couldn't load this account's import settings: \(error.localizedDescription)")
        }
    }

    /// The file's text, or `nil` (with the error shown) when it can't be read or is empty.
    private func readCSV(at url: URL) -> String? {
        let text: String
        do {
            text = try ImportViewModel.readText(at: url)
        } catch {
            viewModel.fail("Couldn't read \(url.lastPathComponent) as UTF-8 text: \(error.localizedDescription)")
            return nil
        }
        // CSVStatementParser.splitLines handles LF, CRLF and CR line endings alike.
        guard !CSVStatementParser.splitLines(text).isEmpty else {
            viewModel.fail("\(url.lastPathComponent) is empty.")
            return nil
        }
        return text
    }

    private func refreshHasProfiles() {
        guard let accountId = account.id else { hasCSVProfile = false; hasPDFProfile = false; return }
        hasCSVProfile = (try? profileStore.find(accountId: accountId, format: .csv)) != nil
        hasPDFProfile = (try? profileStore.find(accountId: accountId, format: .pdf)) != nil
    }

    private var resetTitle: String {
        pendingReset == .pdf
            ? "Reset the PDF layout for \(account.displayName)?"
            : "Reset the column mapping for \(account.displayName)?"
    }

    /// Deletes the account's saved mapping or layout (`ImportProfileStore.delete`).
    private func resetProfile() {
        guard let format = pendingReset else { return }
        pendingReset = nil
        guard let accountId = account.id else { return }
        do {
            try profileStore.delete(accountId: accountId, format: format)
            if format == .csv { lastCSVFileURL = nil }
        } catch {
            viewModel.fail("Couldn't reset the \(format == .pdf ? "PDF layout" : "column mapping"): \(error.localizedDescription)")
        }
        refreshHasProfiles()
    }

    private func handlePickedPDF(_ url: URL) {
        viewModel.errorMessage = nil
        guard let accountId = account.id else {
            viewModel.fail("This account hasn't been saved yet.")
            return
        }
        let lines: [String]
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            lines = try PDFTextExtractor.extractLines(from: url)
        } catch {
            viewModel.fail("Couldn't read text from \(url.lastPathComponent). Is it a scanned (image-only) PDF?")
            return
        }
        guard !lines.isEmpty else {
            viewModel.fail("No text could be extracted from \(url.lastPathComponent).")
            return
        }
        pendingPDFFileName = url.lastPathComponent
        do {
            if let existingProfile = try profileStore.find(accountId: accountId, format: .pdf),
               let configJSON = existingProfile.pdfLayoutConfig {
                let config = try PDFLayoutConfig.decode(configJSON)
                startPDFStaging(lines: lines, config: config, fileName: url.lastPathComponent)
            } else {
                pendingPDFLines = lines
            }
        } catch {
            viewModel.fail("Couldn't load this account's PDF layout: \(error.localizedDescription)")
        }
    }
}

private struct Wrapped: Identifiable {
    let value: [String]
    var id: String { value.joined() }
}
