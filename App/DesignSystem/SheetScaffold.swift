// App/DesignSystem/SheetScaffold.swift
import SwiftUI

/// The shared measurements for sheets and popovers (spec 2026-10-13 §3).
enum SheetMetrics {
    /// Around a sheet's content.
    static let padding: CGFloat = 20
    /// Between a sheet's title, content, error and footer, and between form rows.
    static let spacing: CGFloat = 12
    /// The narrowest a sheet is; wider where its content needs it.
    static let minWidth: CGFloat = 420
    /// Around a popover's content.
    static let popoverPadding: CGFloat = 12

    // The standard sheet widths (UI polish §1.7): a sheet takes the narrowest that fits its
    // content, so sheets of a kind open at the same size.
    /// A few short fields (`minWidth`): a rate, a split, a person.
    static let compactWidth: CGFloat = minWidth
    /// A form with longer fields, a note, documents or a small table (a tenancy, an income).
    static let formWidth: CGFloat = 520
    /// A list to pick from or a table of records (link pickers, rules, owners).
    static let listWidth: CGFloat = 640
    /// A wide table (a line's sources, a folder's files).
    static let tableWidth: CGFloat = 860
    /// Two panes, or a table of editable columns (a statement and its email, invoice intake).
    static let workspaceWidth: CGFloat = 1120
}

/// A button in a sheet's footer.
struct SheetAction {
    let title: String
    var isEnabled = true
    /// Whether Return presses it (`.defaultAction`). False where Return belongs to the
    /// content (the PDF layout's fields refresh the preview).
    var isDefault = true
    let action: () -> Void

    init(_ title: String, isEnabled: Bool = true, isDefault: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.action = action
    }
}

/// Every sheet's frame: the title (`.title3`, semibold) at the top, an optional secondary
/// line under it, the content, an optional error (an error `InlineBanner`) and the footer.
/// The footer has Cancel (`.cancelAction`) on the left and the primary action on the right
/// (`.borderedProminent`, `.defaultAction`, disabled until valid); a destructive action sits
/// at the far left, apart from Cancel. With no primary action the single dismiss button
/// (e.g. "Done") sits on the right. 20pt padding, 12pt spacing, at least 420pt wide; `width`
/// is one of `SheetMetrics`' standard widths.
///
/// Forms inside use `SheetForm` (two columns: labels trailing, controls leading).
struct SheetScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var error: String? = nil
    var width: CGFloat = SheetMetrics.minWidth
    var cancelTitle: String = "Cancel"
    let onCancel: () -> Void
    var primary: SheetAction? = nil
    var destructive: SheetAction? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SheetMetrics.spacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            if let error {
                SheetErrorText(error)
            }
            SheetFooter(cancelTitle: cancelTitle, onCancel: onCancel, primary: primary, destructive: destructive)
                .padding(.top, 4)
        }
        .padding(SheetMetrics.padding)
        .frame(width: max(width, SheetMetrics.minWidth), alignment: .topLeading)
    }
}

/// A sheet's error, above the footer: an error banner (the screens' `InlineBanner`), so a
/// sheet's message looks like the screen's.
struct SheetErrorText: View {
    let message: String

    init(_ message: String) { self.message = message }

    var body: some View {
        InlineBanner(.error, message)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The footer row on its own, for sheets that lay themselves out (the CSV mapping wizard).
struct SheetFooter: View {
    var cancelTitle: String = "Cancel"
    let onCancel: () -> Void
    var primary: SheetAction? = nil
    var destructive: SheetAction? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let destructive {
                Button(destructive.title, role: .destructive, action: destructive.action)
                    .disabled(!destructive.isEnabled)
                    .padding(.trailing, 16)
            }
            if let primary {
                cancelButton
                Spacer(minLength: 0)
                if primary.isDefault {
                    primaryButton(primary)
                        .keyboardShortcut(.defaultAction)
                } else {
                    primaryButton(primary)
                }
            } else {
                Spacer(minLength: 0)
                cancelButton
            }
        }
    }

    private func primaryButton(_ primary: SheetAction) -> some View {
        Button(primary.title, action: primary.action)
            .buttonStyle(.borderedProminent).prominentTint()
            .disabled(!primary.isEnabled)
    }

    private var cancelButton: some View {
        Button(cancelTitle, role: .cancel, action: onCancel)
            .keyboardShortcut(.cancelAction)
    }
}

// MARK: - Form

/// A sheet's form: a two-column grid with labels trailing in the first column and controls
/// leading in the second, filling it. Each row is a `LabeledContent` — editable
/// (`LabeledContent("Category") { picker }`) or read-only
/// (`LabeledContent("Date", value: …)`, plain text) — so read-only values line up with the
/// controls. Controls' own labels are hidden (the row's label names them). A view that isn't
/// a row spans both columns; `SheetFormNote` puts a caption under the controls.
struct SheetForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: SheetMetrics.spacing, verticalSpacing: SheetMetrics.spacing) {
            content
        }
        // Rows take the height their wrapped text needs (captions, long values).
        .fixedSize(horizontal: false, vertical: true)
        .labeledContentStyle(SheetFormRowStyle())
    }
}

/// Turns each `LabeledContent` in a `SheetForm` into a grid row.
private struct SheetFormRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        GridRow {
            configuration.label
                .gridColumnAlignment(.trailing)
            configuration.content
                .labelsHidden()
                .labeledContentStyle(.automatic)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A caption in a `SheetForm`'s control column (no label), e.g. a hint about the row above.
struct SheetFormNote: View {
    let text: String
    var isError = false

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        GridRow {
            // An empty Text, not an unsized Color: that stops the grid filling the width.
            Text(verbatim: "")
            SheetCaption(text, isError: isError)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A secondary (or red, for an error) caption.
struct SheetCaption: View {
    let text: String
    var isError = false

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        // No `fixedSize` here: inside a `SheetForm` it stops the grid filling the sheet's
        // width (the form itself is fixed-size vertically, so captions still wrap).
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? Color.red : Color.secondary)
    }
}

/// A sheet's empty area — a list with nothing in it yet, a file not chosen yet: an icon, a
/// line and a sentence, centred in a dashed outline, with optional actions under them (the
/// screens' empty state at a sheet's size; the invoice intake's drop zone).
struct SheetEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    var minHeight: CGFloat
    let actions: Actions

    init(systemImage: String, title: String, message: String? = nil, minHeight: CGFloat = 150,
         @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.minHeight = minHeight
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Actions.self != EmptyView.self {
                actions.padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .overlay(RoundedRectangle(cornerRadius: Panel<EmptyView, EmptyView>.cornerRadius)
            .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
        .accessibilityElement(children: .contain)
    }
}

/// A checkbox with its name beside it as text (clicking the name ticks it too), so it stays
/// named inside a `SheetForm`, whose rows hide their controls' own labels.
struct NamedCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 5) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(title)
            Text(title)
                .lineLimit(1)
                .onTapGesture { isOn.toggle() }
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// A caption directly under a form control, in the same cell (a field's validation
    /// error, or a hint); nothing when `note` is nil.
    func sheetFieldNote(_ note: String?, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            self
            if let note { SheetCaption(note, isError: isError) }
        }
    }

    /// A popover's standard padding.
    func popoverPadding() -> some View {
        padding(SheetMetrics.popoverPadding)
    }

    /// A scrolling list in a sheet (a picker's results, a folder's files): outlined like the
    /// sheets' check-box lists, so a row cut at its edge reads as more to scroll.
    func sheetListFrame() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
