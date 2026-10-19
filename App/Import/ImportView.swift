// App/Import/ImportView.swift
import SwiftUI
import BudgetCore
import struct BudgetCore.Category

/// The Import screen: staging progress, then the review. It is only in the sidebar while an
/// import is staging or in review (spec §6); starting one, and any error from doing so,
/// belong to the Dashboard's import card.
struct ImportView: View {
    // Owned by ContentView (as a @StateObject there) and passed in, so observed here.
    @ObservedObject var viewModel: ImportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isReviewing {
                // ReviewView fills the height itself (its list takes what's left) and shows
                // `errorMessage` next to the button that caused it.
                ReviewView(viewModel: viewModel) {}
            } else if viewModel.isStaging {
                stagingProgressView
                Spacer(minLength: 0)
            }
        }
        .padding()
    }

    /// Shown while a staging run is in flight. `stagingProgress` is `nil` until the first
    /// categorization batch reports in (the initial parse and duplicate lookup happen
    /// first) — an indeterminate spinner covers that gap so the screen is never silently
    /// blank.
    private var stagingProgressView: some View {
        VStack(spacing: 8) {
            if let progress = viewModel.stagingProgress {
                ProgressView(value: Double(progress.current), total: Double(progress.total))
                    .frame(maxWidth: 280)
                Text("Categorizing \(progress.current) of \(progress.total) transactions…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .figureText()
            } else {
                ProgressView()
                Text("Preparing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
