/* Hallmark · pre-emit critique: P5 H5 E4 S5 R5 V4
 * component: compact player transport · genre: atmospheric · theme: Midnight
 * states: native macOS default · hover · focus · active · disabled · playback feedback
 */
import AppKit
import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @State private var isShowingVolume = false

    var body: some View {
        HStack(spacing: AppTheme.spaceSM) {
            NowPlayingArtwork(track: player.currentTrack, size: 96)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: AppTheme.spaceXS) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? L10n.text("player.idle"))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)
                            .help(player.currentTrack?.title ?? L10n.text("player.idle"))

                        Text(trackContext)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .lineLimit(1)
                            .help(trackContext)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    PlaybackModeMenu()
                }

                HStack(spacing: 6) {
                    Text(DurationFormatter.string(player.elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryInk)
                        .frame(width: 31, alignment: .trailing)
                    Slider(
                        value: Binding(
                            get: { player.elapsed },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 1)
                    )
                    .disabled(player.currentTrack == nil)
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
        .padding(14)
        .frame(
            width: WindowPresentationController.miniContentSize.width,
            height: WindowPresentationController.miniContentSize.height
        )
        .background(AppTheme.surface)
    }

    private var trackContext: String {
        guard let track = player.currentTrack else { return L10n.text("player.chooseTrack") }
        return "\(track.artist) — \(track.album)"
    }

    private var remainingTime: String {
        guard player.currentTrack != nil else { return "0:00" }
        return "−\(DurationFormatter.string(max(player.duration - player.elapsed, 0)))"
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
