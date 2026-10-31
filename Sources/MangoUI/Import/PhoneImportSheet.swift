import SwiftUI
import BudgetCore

/// The iPhone import sheet (spec 2026-10-31): full height; Cancel at the top left, the page dots ("File 2 of 3") under
/// the title, one file at a time below, and that file's one primary action at the bottom. The reading state, the
/// statement and document screens, the unreadable-file card and the closing summary are its stages.
public struct PhoneImportSheet: View {
    @Bindable var model: PhoneImportModel
    let onClose: () -> Void
    /// The summary's "Where it landed" rows and the uncategorised shortcut; nil hides the row's chevron.
    var onOpenAccount: ((Int64) -> Void)?
    var onReviewUncategorised: (() -> Void)?
    @State private var confirmingLeave = false
    @State private var confirmingUndo = false
    @Environment(\.phoneTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(model: PhoneImportModel, onClose: @escaping () -> Void, onOpenAccount: ((Int64) -> Void)? = nil,
                onReviewUncategorised: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
        self.onOpenAccount = onOpenAccount
        self.onReviewUncategorised = onReviewUncategorised
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .background(theme.background)
        .confirmationDialog(PhoneImportCopy.cancelTitle, isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button(PhoneImportCopy.leave, role: .destructive) { leave() }
            Button(PhoneImportCopy.keepGoing, role: .cancel) {}
        } message: {
            Text(PhoneImportCopy.cancelMessage)
        }
        .interactiveDismissDisabled(model.isWorking || model.stage == .reviewing)
        .onDisappear { model.close() }
    }

    private func leave() {
        model.close()
        onClose()
    }

    // MARK: Top bar

    private var topBar: some View {
        let cancel = Button(PhoneImportCopy.cancel) {
            if model.needsLeaveConfirmation { confirmingLeave = true } else { leave() }
        }
        .buttonStyle(.pad(.textLink))
        .disabled(model.isWorking)
        let title: AnyView = model.stage == .reviewing
            ? AnyView(ImportPageDots(batch: model.batch))
            : AnyView(Text(model.stage == .done ? "" : PhoneImportCopy.title).mangoFont(.headline).accessibilityAddTraits(.isHeader))
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Side by side there is no room: Cancel above, the position under it.
                VStack(alignment: .leading, spacing: 2) {
                    if model.stage != .done { cancel }
                    title
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ZStack {
                    title
                    HStack {
                        if model.stage != .done { cancel }
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, MangoSpacing.s)
        .padding(.top, MangoSpacing.xs)
        .frame(minHeight: 52)
    }

    // MARK: Stages

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .reading:
            PhoneImportReadingView(batch: model.batch)
        case .reviewing:
            reviewing
                .gesture(swipe)
        case .done:
            PhoneImportSummaryView(model: model, onDone: onClose, onOpenAccount: onOpenAccount,
                                   onReviewUncategorised: onReviewUncategorised, confirmingUndo: $confirmingUndo)
        }
    }

    @ViewBuilder
    private var reviewing: some View {
        if let file = model.currentFile {
            Group {
                if file.kind == .cantRead {
                    PhoneImportUnreadableView(file: file, onNext: { Task { await model.nextFile() } })
                } else if !file.needsReview {
                    PhoneImportSettledView(file: file)
                } else if model.statement != nil {
                    PhoneStatementReviewView(model: model, file: file)
                } else if model.review != nil {
                    PhoneDocumentCheckView(model: model, file: file)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .id(file.id)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: file.id)
        }
    }

    /// A horizontal swipe moves between the files (Reduce Motion: the cross-fade above, no slide).
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 50).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
            let target = model.batch.current + (value.translation.width < 0 ? 1 : -1)
            Task { await model.select(target) }
        }
    }
}

/// "Reading 3 files": each file with a tick once it is read; the screen is never blocked by a spinner.
struct PhoneImportReadingView: View {
    let batch: PhoneImportBatch
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MangoSpacing.m) {
                Text(PhoneImportCopy.readingFiles(batch.count)).mangoFont(.title2, weight: .bold)
                    .accessibilityAddTraits(.isHeader)
                if let note = batch.overflowNote { InlineBanner(tone: .neutral, text: note) }
                Card {
                    ForEach(Array(batch.files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { Divider() }
                        HStack(spacing: MangoSpacing.s) {
                            Text(file.name).mangoFont(.body).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: MangoSpacing.xs)
                            if file.kind == nil {
                                ProgressView().accessibilityLabel("Reading")
                            } else {
                                Image(systemName: file.kind == .cantRead ? "exclamationmark.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(file.kind == .cantRead ? theme.pending : theme.income)
                                    .accessibilityLabel(file.kind == .cantRead ? PhoneImportCopy.cantRead : "Read")
                            }
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(MangoSpacing.m)
        }
    }
}

/// "Can’t read this file": the batch goes on without it.
struct PhoneImportUnreadableView: View {
    let file: PhoneImportBatch.File
    let onNext: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MangoSpacing.m) {
                    Card {
                        VStack(alignment: .leading, spacing: MangoSpacing.xs) {
                            Image(systemName: "doc.badge.ellipsis").mangoFont(.largeTitle).foregroundStyle(theme.pending).accessibilityHidden(true)
                            Text(PhoneImportCopy.cantRead).mangoFont(.title3, weight: .bold).accessibilityAddTraits(.isHeader)
                            Text(file.name).mangoFont(.body).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text(file.problem ?? ImportInboxCopy.unreadable).mangoFont(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(MangoSpacing.m)
            }
            ImportBottomBar {
                Button(PhoneImportCopy.nextFile, action: onNext).buttonStyle(ImportPrimaryButtonStyle())
            }
        }
    }
}

/// A file already settled that the person swiped back to.
struct PhoneImportSettledView: View {
    let file: PhoneImportBatch.File

    var body: some View {
        ScrollView {
            Card {
                VStack(alignment: .leading, spacing: MangoSpacing.xs) {
                    Text(file.name).mangoFont(.headline).lineLimit(1).truncationMode(.middle)
                    Text(file.outcome.settledWords).mangoFont(.body).foregroundStyle(.secondary)
                }
            }
            .padding(MangoSpacing.m)
        }
    }
}

/// The primary action's strip at the foot of a screen.
struct ImportBottomBar<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(spacing: MangoSpacing.xxs) { content }
            .padding(.horizontal, MangoSpacing.m)
            .padding(.top, MangoSpacing.xs)
            .padding(.bottom, MangoSpacing.xs)
            .frame(maxWidth: .infinity)
            .background(theme.background)
    }
}
