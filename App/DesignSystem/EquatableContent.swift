// App/DesignSystem/EquatableContent.swift
import SwiftUI

/// Content built again only when `value` changes: a page redrawing for something else (a side
/// panel opening, another receipt chosen) keeps a large section — and its measured layout — as
/// it was. `value` must hold everything the content shows (environment values it reads in the
/// builder too, such as the theme); its actions keep working, as they reach the page's state
/// and model by reference.
struct EquatableContent<Value: Equatable, Content: View>: View, Equatable {
    let value: Value
    @ViewBuilder let content: () -> Content

    init(_ value: Value, @ViewBuilder content: @escaping () -> Content) {
        self.value = value
        self.content = content
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }

    var body: some View { content() }
}

extension View {
    /// The view, built again only when `value` changes (`EquatableContent`).
    func rebuilt<Value: Equatable>(when value: Value) -> some View {
        EquatableContent(value) { self }.equatable()
    }
}
