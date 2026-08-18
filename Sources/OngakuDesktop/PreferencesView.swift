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
    @EnvironmentObject private var meterSettings: PlayerMeterSettings

    var body: some View {
        ScrollView {
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

                Divider()

                VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.spaceLG) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("settings.meter.title"))
                                .font(.headline)
                            Text(L10n.text("settings.meter.description"))
                                .font(.callout)
                                .foregroundStyle(AppTheme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 290, alignment: .leading)

                        Picker("", selection: $meterSettings.style) {
                            ForEach(PlayerMeterStyle.allCases) { style in
                                Text(L10n.text(style.localizationKey)).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }

                    HStack(alignment: .center, spacing: AppTheme.spaceLG) {
                        Text(L10n.text("settings.meter.backlight.title"))
                            .font(.callout.weight(.medium))
                            .frame(width: 290, alignment: .leading)

                        HStack(spacing: AppTheme.spaceSM) {
                            ForEach(VUMeterBacklight.allCases) { backlight in
                                Button {
                                    meterSettings.backlight = backlight
                                } label: {
                                    Circle()
                                        .fill(backlight.color)
                                        .frame(width: 22, height: 22)
                                        .overlay {
                                            Circle()
                                                .strokeBorder(
                                                    meterSettings.backlight == backlight
                                                        ? AppTheme.ink : Color.clear,
                                                    lineWidth: 2
                                                )
                                                .padding(-3)
                                        }
                                        .shadow(color: backlight.color.opacity(0.7), radius: 5)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help(L10n.text(backlight.localizationKey))
                                .accessibilityLabel(L10n.text(backlight.localizationKey))
                                .accessibilityAddTraits(
                                    meterSettings.backlight == backlight ? .isSelected : []
                                )
                            }
                        }
                        .frame(width: 180, alignment: .leading)
                    }
                    .disabled(meterSettings.style != .vu)
                    .opacity(meterSettings.style == .vu ? 1 : 0.42)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, AppTheme.spaceMD)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PreferencesContentHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .scrollIndicators(.automatic)
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

                Menu {
                    ForEach(AppLanguage.allCases) { option in
                        Button {
                            language.selectedLanguage = option
                        } label: {
                            if language.selectedLanguage == option {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: AppTheme.spaceXS) {
                        Text(language.selectedLanguage.displayName)
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)

                        Spacer(minLength: AppTheme.spaceXS)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryInk)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 180, height: 30)
                    .background(AppTheme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(AppTheme.rule.opacity(0.8), lineWidth: 1)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.text("settings.language.description"))
                .accessibilityLabel(L10n.text("settings.language.title"))
                .accessibilityValue(language.selectedLanguage.displayName)
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
