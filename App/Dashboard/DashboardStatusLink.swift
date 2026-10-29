// App/Dashboard/DashboardStatusLink.swift
import SwiftUI
import BudgetCore

/// The Dashboard's title row: the page name and, at the right, one compact status ("Up to date · 15 Oct", or the thing
/// that needs doing in the warning colour) that goes to the place to deal with it. An import under way shows instead.
struct DashboardTitleRow: View {
    let status: DashboardStatus?
    @ObservedObject var importCenter: ImportCenterModel
    let navigate: (AppScreen) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Dashboard").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            switch importCenter.phase {
            case .reading, .applying:
                button("Import in progress", icon: nil, tint: .secondary, help: "See the import's progress", destination: .imports, busy: true)
            case .review:
                button("Import in review, not saved yet", icon: "doc.badge.clock", tint: .orange, help: "Resume the import review", destination: .imports)
            case .idle, .finished, .failed:
                if let status { statusButton(status) }
            }
        }
    }

    private func statusButton(_ status: DashboardStatus) -> some View {
        let warning = status.kind == .warning
        let text = status.message + (status.date.map { " · " + Self.dayFormatter.string(from: $0) } ?? "")
        let icon = warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        let target: AppScreen = status.destination == .accounts ? .accounts : .imports
        return button(text, icon: icon, tint: warning ? .orange : .green,
                      help: status.destination == .accounts ? "Open Accounts to update balances" : "Open Imports", destination: target)
    }

    private func button(_ text: String, icon: String?, tint: Color, help: String, destination: AppScreen, busy: Bool = false) -> some View {
        Button { navigate(destination) } label: {
            HStack(spacing: 5) {
                if busy { ProgressView().controlSize(.small) }
                if let icon { Image(systemName: icon).foregroundStyle(tint) }
                Text(text).foregroundStyle(tint == .green ? Color.secondary : tint).monospacedDigit().lineLimit(1).fixedSize()
            }
            .font(.callout)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}
