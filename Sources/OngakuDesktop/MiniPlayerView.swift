@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlaybackController
    @State private var isShowingVolume = false
    @State private var artwork: NSImage?

    var body: some View {
        HStack(spacing: 14) {
            albumArtwork

            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentTrack?.album ?? L10n.text("metadata.unknownAlbum"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .lineLimit(1)

                Text(player.currentTrack?.title ?? L10n.text("player.idle"))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .help(player.currentTrack?.title ?? L10n.text("player.idle"))

                Spacer(minLength: 2)

                HStack(spacing: AppTheme.spaceSM) {
                    StereoLevelMeter(levels: player.stereoLevels)
                    Color.clear
                        .frame(width: 22, height: 1)
                        .accessibilityHidden(true)
                }
                .padding(.bottom, 5)

                HStack(spacing: AppTheme.spaceSM) {
                    Slider(
                        value: Binding(
                            get: { player.elapsed },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 1)
                    )
                    .disabled(player.currentTrack == nil)
                    .accessibilityLabel(L10n.text("miniPlayer.progress"))

                    Button {
                        isShowingVolume.toggle()
                    } label: {
                        Image(systemName: volumeSymbol)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .accessibilityLabel(L10n.text("miniPlayer.volume"))
                    .popover(isPresented: $isShowingVolume, arrowEdge: .bottom) {
                        volumePopover
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .padding(14)
        .frame(width: WindowPresentationController.miniContentSize.width,
               height: WindowPresentationController.miniContentSize.height)
        .background(AppTheme.surface)
        .task(id: player.currentTrack?.id) {
            await loadArtwork()
        }
    }

    private var albumArtwork: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous)
                    .fill(AppTheme.raised)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(player.currentTrack == nil ? AppTheme.secondaryInk : AppTheme.accent)
                    }
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous))
    }

    private var volumePopover: some View {
        HStack(spacing: AppTheme.spaceSM) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(AppTheme.secondaryInk)
            Slider(value: $player.volume, in: 0...1)
                .frame(width: 150)
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

    @MainActor
    private func loadArtwork() async {
        artwork = nil
        guard let url = player.currentTrack?.fileURL else { return }
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(
                  from: metadata,
                  filteredByIdentifier: .commonIdentifierArtwork
              ).first,
              let data = try? await item.load(.dataValue) else { return }
        artwork = NSImage(data: data)
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
