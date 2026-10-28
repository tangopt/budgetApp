import SwiftUI
import BudgetCore

/// Coming up (iPhone spec §3.7): the property's obligations over the next `PropertyGlance.comingUpDays` days (IMI,
/// condomínio, insurance, tax, the mortgage), each with its day and expected amount; an estimate says "est.".
struct ComingUpList: View {
    let obligations: [PropertyObligation]
    let currency: Currency

    var body: some View {
        Card(title: "Coming up") {
            if obligations.isEmpty {
                Text(PropertyCopy.nothingComingUp.figuresUnbroken)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(obligations.enumerated()), id: \.element.id) { index, obligation in
                if index > 0 { Divider() }
                FigureRow(label: obligation.title, secondary: PropertyCopy.comingUpCaption(obligation)) {
                    if let amount = obligation.expectedMinorUnits {
                        MoneyText(minorUnits: amount, currency: obligation.currency ?? currency, role: .due)
                    } else {
                        Text(PropertyCopy.amountNotKnown)
                            .mangoFont(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(PropertyCopy.comingUpSpoken(obligation, currency: currency))
            }
        }
    }
}
