// App/DesignSystem/ValueStepper.swift
import SwiftUI

/// A whole-number stepper that shows its value (spec C11): the value as text beside a
/// label-hidden stepper, the `IntervalStepper` pattern. A `Stepper`'s own label is hidden
/// inside a `SheetForm` (its rows hide control labels), so a value carried in the label would
/// vanish.
struct ValueStepper: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    /// The shown value: "2 months", "12 months".
    var text: (Int) -> String

    init(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, text: @escaping (Int) -> String = { "\($0)" }) {
        self.title = title
        self._value = value
        self.range = range
        self.text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(text(value))
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .leading)
            Stepper(title, value: $value, in: range)
                .labelsHidden()
                .accessibilityValue(text(value))
        }
    }
}

extension ValueStepper {
    /// "1 month", "2 months".
    static func months(_ value: Int) -> String { "\(value) month\(value == 1 ? "" : "s")" }
}
