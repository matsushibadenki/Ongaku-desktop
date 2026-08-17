import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(AppTheme.rule)
            HStack(spacing: AppTheme.spaceLG) {
                nowPlaying
                    .frame(width: 260, alignment: .leading)
                controls
                    .frame(maxWidth: .infinity)
                volume
                    .frame(width: 210, alignment: .trailing)
            }
            .padding(.horizontal, AppTheme.spaceLG)
            .frame(height: 78)
            .background(AppTheme.surface)
        }
        .task(id: library.contentRevision) {
            player.updatePlaybackQueue(library.tracks)
        }
    }

    private var nowPlaying: some View {
        HStack(spacing: AppTheme.spaceSM) {
            RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                .fill(AppTheme.raised)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "waveform")
                        .foregroundStyle(player.currentTrack == nil ? AppTheme.secondaryInk : AppTheme.accent)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.title ?? L10n.text("player.idle"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Text(player.currentTrack?.artist ?? L10n.text("player.chooseTrack"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .lineLimit(1)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: AppTheme.spaceMD) {
            Button(action: primaryPlaybackAction) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .frame(width: 44, height: 44)
            .disabled(player.currentTrack == nil && library.selectedTrack == nil)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(L10n.text(player.isPlaying ? "player.pause" : "track.play"))

            PlaybackModeMenu()

            VStack(spacing: 8) {
                HStack(spacing: AppTheme.spaceMD) {
                    Color.clear.frame(width: 42, height: 1)
                    StereoLevelMeter(levels: player.stereoLevels)
                    Color.clear.frame(width: 42, height: 1)
                }

                HStack(spacing: AppTheme.spaceMD) {
                    Text(DurationFormatter.string(player.elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryInk)
                        .frame(width: 42, alignment: .trailing)

                    Slider(
                        value: Binding(
                            get: { player.elapsed },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 1)
                    )
                    .disabled(player.currentTrack == nil)

                    Text(DurationFormatter.string(player.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryInk)
                        .frame(width: 42, alignment: .leading)
                }
            }
            .layoutPriority(1)
        }
    }

    private func primaryPlaybackAction() {
        if player.currentTrack != nil {
            player.togglePlayback()
        } else if let selectedTrack = library.selectedTrack {
            player.play(selectedTrack)
        }
    }

    private var volume: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let signalPath = player.signalPathDescription {
                Text(signalPath)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(player.isUpsampling ? AppTheme.good : AppTheme.secondaryInk)
                    .lineLimit(1)
                    .help(L10n.text("player.upsamplingHelp"))
            }
            HStack(spacing: AppTheme.spaceXS) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(AppTheme.secondaryInk)
                Slider(value: $player.volume, in: 0...1)
                    .frame(width: 120)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(AppTheme.secondaryInk)
            }
        }
    }
}

struct PlaybackModeMenu: View {
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        Menu {
            ForEach(PlaybackMode.allCases) { mode in
                Button {
                    player.playbackMode = mode
                } label: {
                    Label(L10n.text(mode.localizationKey), systemImage: mode.systemImage)
                }
            }
        } label: {
            Label(
                L10n.text(player.playbackMode.localizationKey),
                systemImage: player.playbackMode.systemImage
            )
            .labelStyle(.iconOnly)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .foregroundStyle(
            player.playbackMode == .sequential ? AppTheme.secondaryInk : AppTheme.accent
        )
        .help(L10n.text(player.playbackMode.localizationKey))
        .accessibilityLabel(L10n.text("player.mode.title"))
        .accessibilityValue(L10n.text(player.playbackMode.localizationKey))
    }
}

enum DurationFormatter {
    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
