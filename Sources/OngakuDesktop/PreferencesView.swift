import SwiftUI

struct PreferencesContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum PreferencesSection: String, CaseIterable, Identifiable {
    case general
    case playback
    case storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.text("settings.sidebar.general")
        case .playback: L10n.text("settings.sidebar.playback")
        case .storage: L10n.text("settings.sidebar.storage")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .playback: "play.circle"
        case .storage: "externaldrive"
        }
    }
}

struct PreferencesView: View {
    private static let fixedWidth: CGFloat = 761
    private static let minimumHeight: CGFloat = 440
    private static let verticalContentPadding: CGFloat = 48

    @EnvironmentObject private var language: AppLanguageSettings
    @EnvironmentObject private var appearance: AppAppearanceSettings
    @State private var selection: PreferencesSection = .general
    @State private var measuredContentHeight: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            List(PreferencesSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            .frame(maxHeight: .infinity)

            Divider()

            Group {
                switch selection {
                case .general:
                    GeneralSettingsView()
                case .playback:
                    PlaybackSettingsView()
                case .storage:
                    StorageSettingsView()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(width: 570)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            minWidth: Self.fixedWidth,
            maxWidth: Self.fixedWidth,
            minHeight: Self.minimumHeight,
            maxHeight: maximumHeight
        )
        .background(AppTheme.canvas)
        .tint(AppTheme.accent)
        .preferredColorScheme(appearance.selectedAppearance.colorScheme)
        .environment(\.locale, language.selectedLanguage.locale ?? .current)
        .onPreferenceChange(PreferencesContentHeightPreferenceKey.self) { height in
            measuredContentHeight = ceil(height)
        }
        .onChange(of: selection) {
            measuredContentHeight = 0
        }
    }

    private var maximumHeight: CGFloat {
        max(Self.minimumHeight, measuredContentHeight + Self.verticalContentPadding)
    }
}

private struct PlaybackSettingsView: View {
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            settingsHeader(
                title: L10n.text("settings.playback.title"),
                subtitle: L10n.text("settings.playback.subtitle"),
                icon: "play.circle.fill"
            )

            Divider()

            VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("settings.playback.crossfade.title"))
                            .font(.headline)
                        Text(L10n.text("settings.playback.crossfade.description"))
                            .font(.callout)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: AppTheme.spaceLG)
                    Text(L10n.format(
                        "settings.playback.crossfade.value",
                        player.crossfadeDuration
                    ))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryInk)
                }

                Slider(value: $player.crossfadeDuration, in: 0...12, step: 0.5)
                    .accessibilityLabel(L10n.text("settings.playback.crossfade.title"))
                    .accessibilityValue(L10n.format(
                        "settings.playback.crossfade.value",
                        player.crossfadeDuration
                    ))
            }

            Divider()

            Toggle(isOn: $player.disableCrossfadeWithinAlbum) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("settings.playback.albumGapless.title"))
                        .font(.headline)
                    Text(L10n.text("settings.playback.albumGapless.description"))
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PreferencesContentHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
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
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PreferencesContentHeightPreferenceKey.self,
                    value: proxy.size.height
                )
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
