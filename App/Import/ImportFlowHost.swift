// App/Import/ImportFlowHost.swift
import SwiftUI
import BudgetCore
import UniformTypeIdentifiers

struct ImportFlowActions {
    let startCSV: () -> Void
    let startPDF: () -> Void
}

/// Owns everything needed to START an import — the two file pickers, the column-mapping and
/// PDF-layout wizards, and the "which file did the user pick" state — so the Import screen
/// and the Dashboard's import card start one in exactly the same way. Progress and review
/// stay on the Import screen (`ImportView`).
struct ImportFlowHost<Content: View>: View {
    @ObservedObject var viewModel: ImportViewModel
    let account: Account
    let profileStore: ImportProfileStore
    /// Called when staging actually begins (not when the user cancels a picker or wizard).
    let onStarted: () -> Void
    @ViewBuilder let content: (ImportFlowActions) -> Content

    @State private var showFilePicker = false
    @State private var pendingHeaderRowForWizard: [String]?
    @State private var pendingFileURL: URL?
    @State private var showPDFPicker = false
    @State private var pendingPDFLines: [String]?
    @State private var pendingPDFFileName = "statement.pdf"

    var body: some View {
        content(ImportFlowActions(startCSV: { showFilePicker = true }, startPDF: { showPDFPicker = true }))
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
            .sheet(item: Binding(get: { pendingHeaderRowForWizard.map { Wrapped(value: $0) } }, set: { _ in pendingHeaderRowForWizard = nil })) { wrapped in
                CSVMappingWizardView(account: account, sampleHeaderRow: wrapped.value) { profile in
                    pendingHeaderRowForWizard = nil
                    do {
                        try profileStore.save(profile)
                    } catch {
                        viewModel.fail("Couldn't save the column mapping: \(error.localizedDescription)")
                        return
                    }
                    if let url = pendingFileURL { startCSVStaging(url) }
                }
            }
            .sheet(item: Binding(get: { pendingPDFLines.map { Wrapped(value: $0) } }, set: { _ in pendingPDFLines = nil })) { wrapped in
                PDFLayoutWizardView(account: account, sampleLines: wrapped.value) { profile in
                    pendingPDFLines = nil
                    do {
                        try profileStore.save(profile)
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
        onStarted()
        Task { await viewModel.stageCSV(fileURL: url, account: account) }
    }

    private func startPDFStaging(lines: [String], config: PDFLayoutConfig, fileName: String) {
        onStarted()
        Task { await viewModel.stagePDF(lines: lines, config: config, account: account, sourceFileName: fileName) }
    }

    private func handlePickedFile(_ url: URL) {
        viewModel.errorMessage = nil
        pendingFileURL = url
        guard let accountId = account.id else {
            viewModel.fail("This account hasn't been saved yet.")
            return
        }
        let text: String
        do {
            text = try ImportViewModel.readText(at: url)
        } catch {
            viewModel.fail("Couldn't read \(url.lastPathComponent) as UTF-8 text: \(error.localizedDescription)")
            return
        }
        // CSVStatementParser.splitLines handles LF, CRLF and CR line endings alike.
        guard let firstLine = CSVStatementParser.splitLines(text).first else {
            viewModel.fail("\(url.lastPathComponent) is empty.")
            return
        }
        do {
            if try profileStore.find(accountId: accountId, format: .csv) != nil {
                startCSVStaging(url)
            } else {
                pendingHeaderRowForWizard = CSVRowSplitter.split(line: firstLine, delimiter: ",")
            }
        } catch {
            viewModel.fail("Couldn't load this account's import settings: \(error.localizedDescription)")
        }
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
