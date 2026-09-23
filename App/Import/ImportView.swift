// App/Import/ImportView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category
import UniformTypeIdentifiers

struct ImportView: View {
    // Owned by ContentView (as a @StateObject there) and passed in, so observed here.
    @ObservedObject var viewModel: ImportViewModel
    let account: Account
    let categories: [Category]
    let profileStore: ImportProfileStore

    @State private var showFilePicker = false
    @State private var pendingHeaderRowForWizard: [String]?
    @State private var pendingFileURL: URL?
    @State private var showPDFPicker = false
    @State private var pendingPDFLines: [String]?
    @State private var pendingPDFFileName = "statement.pdf"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // While reviewing, ReviewView shows this same errorMessage locally, right next
            // to the button that caused it — skip the banner here to avoid showing the
            // same error twice (e.g. a failed "Confirm N ready" leaves isReviewing true).
            if let error = viewModel.errorMessage, !viewModel.isReviewing {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { viewModel.errorMessage = nil }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
            }
            if let status = viewModel.statusMessage, !viewModel.isReviewing {
                Text(status).foregroundStyle(.secondary).font(.callout)
            }

            if viewModel.isReviewing {
                ReviewView(viewModel: viewModel, categories: categories) {}
            } else {
                // Disabled while a staging run is in flight so a second import can't start
                // concurrently (ImportViewModel also guards its staging entry points).
                Button("Import CSV statement…") { showFilePicker = true }
                    .disabled(viewModel.isStaging)
                Button("Import PDF statement…") { showPDFPicker = true }
                    .disabled(viewModel.isStaging)
            }
            Spacer(minLength: 0)
        }
        .padding()
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
                if let url = pendingFileURL {
                    Task { await viewModel.stageCSV(fileURL: url, account: account) }
                }
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
                    let fileName = pendingPDFFileName
                    Task { await viewModel.stagePDF(lines: wrapped.value, config: config, account: account, sourceFileName: fileName) }
                } catch {
                    viewModel.fail("Couldn't save the PDF layout: \(error.localizedDescription)")
                }
            }
        }
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
                Task { await viewModel.stageCSV(fileURL: url, account: account) }
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
                let fileName = url.lastPathComponent
                Task { await viewModel.stagePDF(lines: lines, config: config, account: account, sourceFileName: fileName) }
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
