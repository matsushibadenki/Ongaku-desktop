/* Hallmark · pre-emit critique: P5 H5 E4 S5 R5 V4
 * component: compact player transport · genre: atmospheric · theme: Midnight
 * states: native macOS default · hover · focus · active · disabled · playback feedback
 */
import AppKit
import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var appleMusicPlayback: AppleMusicPlaybackController
    @State private var isShowingVolume = false

    var body: some View {
        HStack(spacing: AppTheme.spaceSM) {
            nowPlayingArtwork

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: AppTheme.spaceXS) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayedTitle)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)
                            .help(displayedTitle)

                        Text(trackContext)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .lineLimit(1)
                            .help(trackContext)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if appleMusicPlayback.currentItem == nil {
                        PlaybackModeMenu()
                    }
                }

                HStack(spacing: 6) {
                    Text(DurationFormatter.string(displayedElapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryInk)
                        .frame(width: 31, alignment: .trailing)
                    Slider(
                        value: Binding(
                            get: { displayedElapsed },
                            set: { newValue in
                                if appleMusicPlayback.currentItem != nil {
                                    appleMusicPlayback.seek(to: newValue)
                                } else {
                                    player.seek(to: newValue)
                                }
                            }
                        ),
                        in: 0...max(displayedDuration, 1)
                    )
                    .disabled(
                        appleMusicPlayback.currentItem != nil
                            ? displayedDuration <= 0
                            : player.currentTrack == nil
                    )
                    .accessibilityLabel(L10n.text("miniPlayer.progress"))

                    Text(remainingTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryInk)
                        .frame(width: 38, alignment: .leading)
                }

                HStack(spacing: AppTheme.spaceXS) {
                    PlayerTransportControls(compact: true)

                    Spacer(minLength: 4)

                    StereoLevelMeter(levels: player.stereoLevels)
                        .frame(width: 66)

                    PlaybackQueueButton()

                    if appleMusicPlayback.currentItem == nil {
                        Button {
                            isShowingVolume.toggle()
                        } label: {
                            Image(systemName: volumeSymbol)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.text("miniPlayer.volume"))
                        .accessibilityLabel(L10n.text("miniPlayer.volume"))
                        .popover(isPresented: $isShowingVolume, arrowEdge: .bottom) {
                            volumePopover
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(
            width: WindowPresentationController.miniContentSize.width,
            height: WindowPresentationController.miniContentSize.height
        )
        .background(AppTheme.surface)
    }

    private var trackContext: String {
        if let item = appleMusicPlayback.currentQueueItem {
            return "\(item.subtitle) — Apple Music"
        }
        if let item = appleMusicPlayback.currentItem {
            return "\(item.subtitle) — Apple Music"
        }
        guard let track = player.currentTrack else { return L10n.text("player.chooseTrack") }
        return "\(track.artist) — \(track.album)"
    }

    private var remainingTime: String {
        if appleMusicPlayback.currentItem != nil {
            return "−\(DurationFormatter.string(max(displayedDuration - displayedElapsed, 0)))"
        }
        guard player.currentTrack != nil else { return "0:00" }
        return "−\(DurationFormatter.string(max(displayedDuration - displayedElapsed, 0)))"
    }

    @ViewBuilder
    private var nowPlayingArtwork: some View {
        if let item = appleMusicPlayback.currentItem {
            AsyncImage(
                url: appleMusicPlayback.currentQueueItem?.artworkURL ?? item.artworkURL
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "apple.logo")
                    .foregroundStyle(AppTheme.secondaryInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.raised)
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            NowPlayingArtwork(track: player.currentTrack, size: 96)
        }
    }

    private var displayedTitle: String {
        appleMusicPlayback.currentQueueItem?.title
            ?? appleMusicPlayback.currentItem?.title
            ?? player.currentTrack?.title
            ?? L10n.text("player.idle")
    }

    private var displayedElapsed: TimeInterval {
        appleMusicPlayback.currentItem == nil ? player.elapsed : appleMusicPlayback.elapsed
    }

    private var displayedDuration: TimeInterval {
        appleMusicPlayback.currentItem == nil ? player.duration : appleMusicPlayback.duration
    }

    private var volumePopover: some View {
        HStack(spacing: AppTheme.spaceSM) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(AppTheme.secondaryInk)
            Slider(value: $player.volume, in: 0...1)
                .frame(width: 150)
                .accessibilityLabel(L10n.text("miniPlayer.volume"))
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(AppTheme.secondaryInk)
        }
        .padding(AppTheme.spaceMD)
        .background(AppTheme.surface)
    }

    private var volumeSymbol: String {
        switch player.volume {
        case ...0.001: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

}

struct StereoLevelMeter: View {
    let levels: StereoLevels

    var body: some View {
        VStack(spacing: 2) {
            channel(label: "L", level: levels.left)
            channel(label: "R", level: levels.right)
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("miniPlayer.stereoMeter"))
        .accessibilityValue("L \(percentage(levels.left)), R \(percentage(levels.right))")
    }

    private func channel(label: String, level: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.rule.opacity(0.48))
                    .frame(height: 3)
                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: proxy.size.width * min(max(level, 0), 1))
                    .frame(height: 3)

                Text(label)
                    .font(.system(size: 6, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.ink.opacity(0.78))
                    .padding(.leading, 3)
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func percentage(_ level: Double) -> String {
        "\(Int((min(max(level, 0), 1) * 100).rounded()))%"
    }
}
