// App/DocumentImport/ImportBenefitsEditor.swift
import SwiftUI
import BudgetCore

/// A P11D's benefit rows in the review: the kind and the cash equivalent of each, rows added
/// or removed, applied together (`.setBenefits`: the payroll effect's benefits, checked by the
/// user). The figures stay on one line.
struct ImportBenefitsEditor: View {
    private struct Row: Identifiable {
        let id = UUID()
        var kind: BenefitKind
        var amount: String
        /// The row's SA102 box as read (kept while its kind isn't changed; a new kind takes its own box).
        var readKind: BenefitKind?
        var readBox: Int?

        var sa102Box: Int? { kind == readKind ? readBox : nil }
    }

    let original: [PayrollFormExtraction.Benefit]
    let apply: ([PayrollFormExtraction.Benefit]) -> Void
    @State private var rows: [Row]

    init(benefits: [PayrollFormExtraction.Benefit], apply: @escaping ([PayrollFormExtraction.Benefit]) -> Void) {
        original = benefits
        self.apply = apply
        _rows = State(initialValue: benefits.map {
            Row(kind: $0.kind, amount: Money.formatInput($0.cashEquivalentMinorUnits), readKind: $0.kind, readBox: $0.sa102Box)
        })
    }

    /// The rows as benefits, nil while an amount isn't a figure (or is negative).
    private var parsed: [PayrollFormExtraction.Benefit]? {
        var result: [PayrollFormExtraction.Benefit] = []
        for row in rows {
            guard let minor = Money.parseMinorUnits(row.amount), minor >= 0 else { return nil }
            result.append(PayrollFormExtraction.Benefit(kind: row.kind, sa102Box: row.sa102Box, cashEquivalentMinorUnits: minor))
        }
        return result
    }

    private var isChanged: Bool { parsed.map { $0 != original } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("No benefits on this form").font(.callout).foregroundStyle(.secondary)
            }
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    Picker("Benefit", selection: $row.kind) {
                        ForEach(BenefitKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("0.00", text: $row.amount)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 84)
                        .accessibilityLabel("\(row.kind.displayName) cash equivalent")
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this benefit")
                    .accessibilityLabel("Remove \(row.kind.displayName)")
                }
            }
            HStack(spacing: 8) {
                Button {
                    rows.append(Row(kind: .medical, amount: ""))
                } label: {
                    Label("Add benefit", systemImage: "plus")
                }
                Button("Use these") {
                    if let parsed { apply(parsed) }
                }
                .disabled(!isChanged)
                .help("Take these benefits as the figures: they count as checked")
            }
            .controlSize(.small)
        }
        .controlSize(.small)
    }
}
