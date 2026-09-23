// App/Import/ImportView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import UniformTypeIdentifiers

struct ImportView: View {
    @StateObject var viewModel: ImportViewModel
    let account: Account
    let categories: [Category]
    let profileStore: ImportProfileStore

    @State private var showFilePicker = false
    @State private var pendingHeaderRowForWizard: [String]?
    @State private var pendingFileURL: URL?
    @State private var showPDFPicker = false
    @State private var pendingPDFLines: [String]?

    var body: some View {
        VStack {
            if !viewModel.stagedRows.isEmpty {
                ReviewView(viewModel: viewModel, categories: categories) {}
            } else {
                Button("Import CSV statement…") { showFilePicker = true }
                Button("Import PDF statement…") { showPDFPicker = true }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.commaSeparatedText]) { result in
            guard case .success(let url) = result else { return }
            handlePickedFile(url)
        }
        .fileImporter(isPresented: $showPDFPicker, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            handlePickedPDF(url)
        }
        .sheet(item: Binding(get: { pendingHeaderRowForWizard.map { Wrapped(value: $0) } }, set: { _ in pendingHeaderRowForWizard = nil })) { wrapped in
            CSVMappingWizardView(account: account, sampleHeaderRow: wrapped.value) { profile in
                try? profileStore.save(profile)
                pendingHeaderRowForWizard = nil
                if let url = pendingFileURL {
                    Task { await viewModel.stageCSV(fileURL: url, account: account) }
                }
            }
        }
        .sheet(item: Binding(get: { pendingPDFLines.map { Wrapped(value: $0) } }, set: { _ in pendingPDFLines = nil })) { wrapped in
            PDFLayoutWizardView(account: account, sampleLines: wrapped.value) { profile in
                try? profileStore.save(profile)
                pendingPDFLines = nil
                if let configJSON = profile.pdfLayoutConfig, let config = try? PDFLayoutConfig.decode(configJSON) {
                    Task { try? await viewModel.stagePDF(lines: wrapped.value, config: config, account: account) }
                }
            }
        }
    }

    private func handlePickedFile(_ url: URL) {
        pendingFileURL = url
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let firstLine = CSVStatementParser.splitLines(text).first else { return }
        let existingProfile = try? profileStore.find(accountId: account.id!, format: .csv)
        if existingProfile != nil {
            Task { await viewModel.stageCSV(fileURL: url, account: account) }
        } else {
            pendingHeaderRowForWizard = CSVRowSplitter.split(line: String(firstLine), delimiter: ",")
        }
    }

    private func handlePickedPDF(_ url: URL) {
        guard let lines = try? PDFTextExtractor.extractLines(from: url) else { return }
        if let existingProfile = try? profileStore.find(accountId: account.id!, format: .pdf),
           let configJSON = existingProfile.pdfLayoutConfig,
           let config = try? PDFLayoutConfig.decode(configJSON) {
            Task { try? await viewModel.stagePDF(lines: lines, config: config, account: account) }
        } else {
            pendingPDFLines = lines
        }
    }
}

private struct Wrapped: Identifiable {
    let value: [String]
    var id: String { value.joined() }
}
