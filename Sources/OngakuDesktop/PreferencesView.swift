import SwiftUI

private enum PreferencesSection: String, CaseIterable, Identifiable {
    case general
    case storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.text("settings.sidebar.general")
        case .storage: L10n.text("settings.sidebar.storage")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .storage: "externaldrive"
        }
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var language: AppLanguageSettings
    @EnvironmentObject private var appearance: AppAppearanceSettings
    @State private var selection: PreferencesSection = .general

    var body: some View {
        HStack(spacing: 0) {
            List(PreferencesSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 190, height: 440)

            Divider()

            Group {
                switch selection {
                case .general:
                    GeneralSettingsView()
                case .storage:
                    StorageSettingsView()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(width: 570, height: 440, alignment: .topLeading)
        }
        .frame(width: 761, height: 440)
        .background(AppTheme.canvas)
        .tint(AppTheme.accent)
        .preferredColorScheme(appearance.selectedAppearance.colorScheme)
        .environment(\.locale, language.selectedLanguage.locale ?? .current)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var language: AppLanguageSettings
    @EnvironmentObject private var appearance: AppAppearanceSettings

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            settingsHeader(
                title: L10n.text("settings.general.title"),
                subtitle: L10n.text("settings.general.subtitle"),
                icon: "gearshape.fill"
            )

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.spaceLG) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("settings.language.title"))
                        .font(.headline)
                    Text(L10n.text("settings.language.description"))
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 290, alignment: .leading)

                Picker("", selection: $language.selectedLanguage) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.spaceLG) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("settings.appearance.title"))
                        .font(.headline)
                    Text(L10n.text("settings.appearance.description"))
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 290, alignment: .leading)

                Picker("", selection: $appearance.selectedAppearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(L10n.text(option.localizationKey)).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
    }
}

@ViewBuilder
private func settingsHeader(title: String, subtitle: String, icon: String) -> some View {
    HStack(spacing: AppTheme.spaceMD) {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(AppTheme.accent)

        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryInk)
        }
    }
}
