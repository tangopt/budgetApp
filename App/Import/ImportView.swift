// App/Import/ImportView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

struct ImportView: View {
    // Owned by ContentView (as a @StateObject there) and passed in, so observed here.
    @ObservedObject var viewModel: ImportViewModel
    let account: Account
    let categories: [Category]
    let profileStore: ImportProfileStore

    var body: some View {
        ImportFlowHost(viewModel: viewModel, account: account, profileStore: profileStore, onStarted: {}) { actions in
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
                } else if viewModel.isStaging {
                    stagingProgressView
                } else {
                    Button("Import CSV statement…") { actions.startCSV() }
                    if let editCSVMapping = actions.editCSVMapping {
                        Button("Edit column mapping…") { editCSVMapping() }
                    }
                    Button("Import PDF statement…") { actions.startPDF() }
                }
                Spacer(minLength: 0)
            }
            .padding()
        }
    }

    /// Shown in place of the two "Import…" buttons while a staging run is in flight.
    /// `stagingProgress` is `nil` until the first categorization batch reports in (the
    /// initial parse and duplicate lookup happen first) — an indeterminate spinner covers
    /// that gap so the screen is never silently blank.
    private var stagingProgressView: some View {
        VStack(spacing: 8) {
            if let progress = viewModel.stagingProgress {
                ProgressView(value: Double(progress.current), total: Double(progress.total))
                    .frame(maxWidth: 280)
                Text("Categorizing \(progress.current) of \(progress.total) transactions…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Preparing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
