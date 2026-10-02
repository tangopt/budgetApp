// App/Dashboard/FreshnessImportCard.swift
import SwiftUI
import BudgetCore

struct FreshnessImportCard: View {
    let freshness: DataFreshness
    @ObservedObject var importViewModel: ImportViewModel
    let accounts: [Account]
    @Binding var selectedAccountId: Int64?
    let profileStore: ImportProfileStore
    let navigate: (AppScreen) -> Void

    private var tint: Color {
        switch freshness.status {
        case .behind: return .orange
        case .upToDate: return .green
        case .noData: return .gray
        }
    }

    private var title: String {
        switch freshness.status {
        case .noData: return "Nothing imported yet"
        case .upToDate: return "Up to date"
        case .behind(let months, let days):
            return months >= 1
                ? "Data is \(months) month\(months == 1 ? "" : "s") behind"
                : "Data is \(days) day\(days == 1 ? "" : "s") behind"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let at = freshness.lastImportAt {
            let file = freshness.lastImportFileName.map { " (\($0))" } ?? ""
            parts.append("Last import \(DashboardFormat.day(at))\(file)")
        }
        if let through = freshness.dataThrough { parts.append("transactions through \(DashboardFormat.day(through))") }
        return parts.joined(separator: " · ")
    }

    private var selectedAccount: Account? { accounts.first { $0.id == selectedAccountId } }

    private var statusIcon: String {
        switch freshness.status {
        case .upToDate: return "checkmark.circle.fill"
        case .noData: return "tray"
        case .behind: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: statusIcon)
                    .font(.headline)
                    .foregroundStyle(tint)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            importControls
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35)))
    }

    @ViewBuilder
    private var importControls: some View {
        if importViewModel.isStaging {
            HStack {
                ProgressView().controlSize(.small)
                Text("Import in progress…").font(.callout)
                Button("View progress ›") { navigate(.importReview) }.buttonStyle(.link)
            }
        } else if importViewModel.isReviewing {
            HStack {
                Text("Import ready to review").font(.callout)
                Button("Resume review ›") { navigate(.importReview) }.buttonStyle(.link)
            }
        } else if accounts.isEmpty {
            HStack {
                Text("Add an account to import into").font(.callout).foregroundStyle(.secondary)
                Button("Accounts ›") { navigate(.accounts) }.buttonStyle(.link)
            }
        } else {
            HStack {
                Picker("Import into", selection: $selectedAccountId) {
                    ForEach(accounts) { account in
                        Text(account.name).tag(account.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                if let account = selectedAccount {
                    ImportFlowHost(viewModel: importViewModel, account: account, profileStore: profileStore, onStarted: { navigate(.importReview) }) { actions in
                        HStack {
                            Button("Import CSV…") { actions.startCSV() }
                            Button("Import PDF…") { actions.startPDF() }
                        }
                    }
                }
            }
        }
    }
}
