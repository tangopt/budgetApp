import SwiftUI
import BudgetCore

/// Home's first line (iPhone spec §3.2): "Data through <day> · last import <day>", in the secondary colour; past
/// 14 days (`HomeSummary.isFreshnessAmber`) an amber banner that also says how old the data is.
struct FreshnessLine: View {
    let summary: HomeSummary

    var body: some View {
        let text = HomeCopy.freshness(summary)
        if summary.isFreshnessAmber {
            InlineBanner(tone: .amber, text: text)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "clock")
                    .accessibilityHidden(true)
                Text(text.figuresUnbroken)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .mangoFont(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}
