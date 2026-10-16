// App/Settings/SettingsView.swift
import SwiftUI
import BudgetCore

/// Budget ▸ Settings… (⌘,): Appearance (System / Light / Dark) and Theme (the swatch grid).
/// Both apply immediately, app-wide, and are remembered (`appAppearance`, `appTheme`).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Appearance", systemImage: "circle.lefthalf.filled") {
                AppearanceSettings()
            }
            Tab("Theme", systemImage: "paintpalette") {
                ThemeSettings()
            }
        }
        .scenePadding()
        .frame(width: 640)
    }
}

/// System / Light / Dark (moved from the sidebar). `ThemedRoot` applies the choice.
private struct AppearanceSettings: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Form {
            Picker("Appearance:", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            Text("System follows the macOS appearance. Each theme has a light and a dark version.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }
}

/// Every theme as a swatch card; clicking one applies it.
private struct ThemeSettings: View {
    @AppStorage(Theme.storageKey) private var themeID = ThemePalette.defaultID

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Theme.all) { theme in
                    Button { themeID = theme.id } label: {
                        ThemeSwatchCard(theme: theme, isSelected: theme.id == Theme.named(themeID).id)
                    }
                    .buttonStyle(.plain)
                    .help("Use the \(theme.name) theme")
                }
            }
            .padding(4)
        }
        .frame(height: 470)
    }
}

/// A theme's card: its name over a miniature grid drawn in its own colours (header, a section
/// band, plain and striped rows, a group row, the Net totals row; income, expense and pending
/// amounts) and its first chart colours, outlined in its accent when selected. Drawn in the
/// current appearance's variant, like the app.
struct ThemeSwatchCard: View {
    let theme: Theme
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            preview
            HStack(spacing: 4) {
                ForEach(0..<min(theme.chartSeries.count, 8), id: \.self) { index in
                    Circle().fill(theme.series(index)).frame(width: 7, height: 7)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent)
                }
            }
            Text(theme.name).font(.callout.weight(isSelected ? .semibold : .regular))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? theme.accent.opacity(0.10) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? theme.accent : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Category").bold()
                Spacer()
                Text("Oct").bold()
            }
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(theme.gridHeaderBackground)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.primary.opacity(0.18)), alignment: .bottom)

            HStack {
                Text("INCOME").font(.system(size: 7, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 5)
            .frame(height: 12)
            .background(theme.sectionHeaderTint)

            row("Salary", stripe: theme.income, background: .clear) {
                Text("£3,200").foregroundStyle(theme.income)
            }
            row("Rent", stripe: theme.expense, background: theme.rowStripe) {
                Text("−£1,450").foregroundStyle(theme.expense)
            }
            row("Bills", bold: true, stripe: theme.expense, background: theme.groupRowTint) {
                HStack(spacing: 2) {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 6))
                    Text("−£86").italic()
                }
                .foregroundStyle(theme.pending)
            }
            row("Net", bold: true, stripe: theme.totalsStripe, background: theme.totalsNetTint) {
                Text("£1,664").foregroundStyle(theme.income).bold()
            }
        }
        .font(.system(size: 9).monospacedDigit())
        .background(theme.windowFill)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func row<Amount: View>(_ name: String, bold: Bool = false, stripe: Color, background: Color, @ViewBuilder amount: () -> Amount) -> some View {
        HStack(spacing: 0) {
            Text(name).fontWeight(bold ? .bold : .regular)
            Spacer(minLength: 4)
            amount()
        }
        .padding(.leading, 6).padding(.trailing, 5)
        .frame(height: 15)
        .background(background)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .bottom)
        .overlay(Rectangle().frame(width: 2).foregroundStyle(stripe), alignment: .leading)
    }
}
