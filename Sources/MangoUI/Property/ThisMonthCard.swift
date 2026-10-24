import SwiftUI
import BudgetCore

/// This month (iPhone spec §3.7): the rent and its status (Received <date> / Expected / Late), the receipt's status,
/// and the last recharge with its status (Paid / Sent / Ready to send). Words from `PropertyGlance`'s enums
/// (`PropertyCopy`); the amounts are its figures, in the property's currency.
struct ThisMonthCard: View {
    let glance: PropertyGlance
    @Environment(\.phoneTheme) private var theme

    private var currency: Currency { glance.property.currency }

    var body: some View {
        Card(title: "This month") {
            if let status = PropertyCopy.rentStatus(glance.rent) {
                rentRow(status: status)
            } else {
                Text(PropertyCopy.notLet)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let receipt = PropertyCopy.receipt(glance.receipt) {
                Divider()
                statusRow(label: "Receipt", status: receipt)
            }
            if let caption = PropertyCopy.rechargeCaption(glance) {
                Divider()
                FigureRow(label: "Last recharge", secondary: caption) {
                    if let total = glance.lastRechargeTotalMinorUnits {
                        MoneyText(minorUnits: total, currency: currency, role: .neutral)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Last recharge")
                .accessibilityValue(([caption] + (glance.lastRechargeTotalMinorUnits.map {
                    [MoneyPresentation(minorUnits: $0, currency: currency, role: .neutral).spoken]
                } ?? [])).joined(separator: ", "))
            }
        }
    }

    /// Rent: the amount, its status beneath; a late rent's status in amber with a mark.
    private func rentRow(status: String) -> some View {
        let late = PropertyCopy.isLate(glance.rent)
        let role = PropertyCopy.rentRole(glance.rent)
        return VStack(alignment: .leading, spacing: 2) {
            FigureRow(label: "Rent", secondary: late ? nil : status) {
                if let rent = glance.rentMinorUnits {
                    MoneyText(minorUnits: rent, currency: currency, role: role)
                }
            }
            if late {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .accessibilityHidden(true)
                    Text(status.figuresUnbroken)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundStyle(theme.pending)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rent")
        .accessibilityValue(([status] + (glance.rentMinorUnits.map {
            [MoneyPresentation(minorUnits: $0, currency: currency, role: role).spoken]
        } ?? [])).joined(separator: ", "))
    }

    /// A status with no amount: the label over its words.
    private func statusRow(label: String, status: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            Text(status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(status)
    }
}
