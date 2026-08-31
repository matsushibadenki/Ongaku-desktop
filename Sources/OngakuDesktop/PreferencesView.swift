import SwiftUI

struct PreferencesContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum PreferencesSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case playback
    case storage
    case social

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.text("settings.sidebar.general")
        case .appearance: L10n.text("settings.sidebar.appearance")
        case .playback: L10n.text("settings.sidebar.playback")
        case .storage: L10n.text("settings.sidebar.storage")
        case .social: L10n.text("settings.sidebar.social")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .playback: "play.circle"
        case .storage: "externaldrive"
        case .social: "person.2.badge.gearshape"
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
                case .appearance:
                    AppearanceSettingsView()
                case .playback:
                    PlaybackSettingsView()
                case .storage:
                    StorageSettingsView()
                case .social:
                    SocialPrivacySettingsView()
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
        min(max(Self.minimumHeight, measuredContentHeight + Self.verticalContentPadding), 760)
    }
}

private struct PlaybackSettingsView: View {
    @EnvironmentObject private var player: PlaybackController

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
                    settingsRow(
                        title: L10n.text("settings.playback.normalization.title"),
                        description: L10n.text("settings.playback.normalization.description")
                    ) {
                        Picker("", selection: $player.loudnessNormalizationMode) {
                            ForEach(LoudnessNormalizationMode.allCases) { mode in
                                Text(L10n.text(mode.localizationKey)).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
                        HStack {
                            Text(L10n.text("settings.playback.normalization.target"))
                                .font(.callout.weight(.medium))
                            Spacer(minLength: AppTheme.spaceLG)
                            Text(L10n.format(
                                "settings.playback.normalization.targetValue",
                                player.loudnessTargetDBFS
                            ))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryInk)
                        }
                        Slider(
                            value: $player.loudnessTargetDBFS,
                            in: LoudnessNormalizationPolicy.targetRange,
                            step: 1
                        )
                        .accessibilityLabel(
                            L10n.text("settings.playback.normalization.target")
                        )
                    }
                    .disabled(player.loudnessNormalizationMode == .off)

                    if let adjustment = player.loudnessAdjustmentDescription {
                        Label(adjustment, systemImage: "waveform.badge.magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle(isOn: $player.preventsClipping) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("settings.playback.clipping.title"))
                                .font(.headline)
                            Text(L10n.text("settings.playback.clipping.description"))
                                .font(.callout)
                                .foregroundStyle(AppTheme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                }

                Divider()

                VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("settings.playback.signalPath.title"))
                            .font(.headline)
                        Text(L10n.text("settings.playback.signalPath.description"))
                            .font(.callout)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let path = player.signalPathSnapshot {
                        VStack(spacing: AppTheme.spaceSM) {
                            signalPathRow(
                                L10n.text("settings.playback.signalPath.source"),
                                format(path.sourceSampleRate, channels: path.sourceChannelCount)
                            )
                            signalPathRow(
                                L10n.text("settings.playback.signalPath.processing"),
                                format(
                                    path.processingSampleRate,
                                    channels: path.processingChannelCount
                                )
                            )
                            signalPathRow(
                                L10n.text("settings.playback.signalPath.dsp"),
                                dspDescription(path)
                            )
                            signalPathRow(
                                L10n.text("settings.playback.signalPath.normalization"),
                                normalizationDescription(path)
                            )
                            signalPathRow(
                                L10n.text("settings.playback.signalPath.output"),
                                format(path.outputSampleRate, channels: path.outputChannelCount)
                            )
                        }
                        .padding(AppTheme.spaceMD)
                        .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 8))

                        Label(
                            L10n.text("settings.playback.signalPath.sourceUnmodified"),
                            systemImage: "checkmark.shield.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(AppTheme.good)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label(
                            L10n.text("settings.playback.signalPath.unavailable"),
                            systemImage: "waveform"
                        )
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryInk)
                    }
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

    private func signalPathRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.spaceMD) {
            Text(title)
                .foregroundStyle(AppTheme.secondaryInk)
            Spacer(minLength: AppTheme.spaceLG)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func format(_ sampleRate: Double, channels: UInt32) -> String {
        let rate = sampleRate / 1_000
        let rateText = abs(rate.rounded() - rate) < 0.01
            ? String(format: "%.0f kHz", rate)
            : String(format: "%.1f kHz", rate)
        return L10n.format("settings.playback.signalPath.format", rateText, Int(channels))
    }

    private func dspDescription(_ path: AudioSignalPathSnapshot) -> String {
        if path.effectsBypassed {
            return L10n.text("settings.playback.signalPath.effectsBypassed")
        }
        if path.enabledEffects.isEmpty {
            return L10n.text("settings.playback.signalPath.effectsNone")
        }
        return path.enabledEffects.map(\.displayName).joined(separator: " → ")
    }

    private func normalizationDescription(_ path: AudioSignalPathSnapshot) -> String {
        guard path.normalizationMode != .off else {
            return L10n.text("settings.playback.normalization.mode.off")
        }
        return player.loudnessAdjustmentDescription
            ?? L10n.text("settings.playback.normalization.pending")
    }
}

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var appearance: AppAppearanceSettings
    @EnvironmentObject private var meterSettings: PlayerMeterSettings
    @EnvironmentObject private var trackTableSettings: TrackTableSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
                settingsHeader(
                    title: L10n.text("settings.appearanceSection.title"),
                    subtitle: L10n.text("settings.appearanceSection.subtitle"),
                    icon: "circle.lefthalf.filled"
                )

                Divider()

                settingsRow(
                    title: L10n.text("settings.tableColumns.title"),
                    description: L10n.text("settings.tableColumns.description")
                ) {
                    Menu {
                        Label(L10n.text("column.title"), systemImage: "checkmark")
                            .disabled(true)
                        Divider()
                        ForEach(TrackTableColumn.allCases) { column in
                            Toggle(
                                L10n.text(column.localizationKey),
                                isOn: trackTableSettings.binding(for: column)
                            )
                        }
                    } label: {
                        Label(
                            L10n.format(
                                "settings.tableColumns.visibleCount",
                                trackTableSettings.visibleColumns.count + 1
                            ),
                            systemImage: "tablecells"
                        )
                        .frame(width: 180)
                    }
                    .menuStyle(.borderlessButton)
                }

                Divider()

                settingsRow(
                    title: L10n.text("settings.appearance.title"),
                    description: L10n.text("settings.appearance.description")
                ) {
                    Picker("", selection: $appearance.selectedAppearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(L10n.text(option.localizationKey)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                Divider()

                settingsRow(
                    title: L10n.text("settings.playerPosition.title"),
                    description: L10n.text("settings.playerPosition.description")
                ) {
                    Picker("", selection: $meterSettings.barPosition) {
                        ForEach(PlayerBarPosition.allCases) { position in
                            Text(L10n.text(position.localizationKey)).tag(position)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .accessibilityLabel(L10n.text("settings.playerPosition.title"))
                }

                Divider()

                VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
                    settingsRow(
                        title: L10n.text("settings.meter.title"),
                        description: L10n.text("settings.meter.description")
                    ) {
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
private func settingsRow<Control: View>(
    title: String,
    description: String,
    @ViewBuilder control: () -> Control
) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: AppTheme.spaceLG) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 290, alignment: .leading)

        control()
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
