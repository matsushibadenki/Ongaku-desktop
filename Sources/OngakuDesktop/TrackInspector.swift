import SwiftUI

struct TrackInspector: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        Group {
            if let track = library.selectedTrack {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
                        artwork(for: track)
                        identity(track)
                        integrity(track)
                        fileDetails(track)

                        HStack {
                            Button {
                                player.play(track)
                            } label: {
                                Label(L10n.text("track.play"), systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            Button(L10n.text("track.reveal")) {
                                library.reveal(track)
                            }
                        }
                    }
                    .padding(AppTheme.spaceLG)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    L10n.text("inspector.empty.title"),
                    systemImage: "sidebar.right",
                    description: Text(L10n.text("inspector.empty.body"))
                )
            }
        }
        .background(AppTheme.sidebar)
        .navigationTitle(L10n.text("inspector.title"))
    }

    private func artwork(for track: Track) -> some View {
        ArtworkThumbnail(
            tracks: [track],
            subject: .album(name: track.album, artist: track.artist),
            shape: .roundedRectangle,
            fallbackSymbol: "waveform",
            fallbackLetter: String(track.album.prefix(1)).uppercased()
        )
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func identity(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
            Text(track.artist)
                .font(.body)
                .foregroundStyle(AppTheme.secondaryInk)
            Text(track.album)
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryInk)
        }
    }

    private func integrity(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text("inspector.integrity"))
                .font(.headline)
            HealthLabel(health: track.health, compact: false)
            detailRow(L10n.text("inspector.verified"), value: track.lastVerifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            VStack(alignment: .leading, spacing: 4) {
                Text("SHA-256")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
                Text(track.sha256)
                    .font(.caption2.monospaced())
                    .foregroundStyle(AppTheme.ink)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
        .padding(AppTheme.spaceMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ongakuPanel()
    }

    private func fileDetails(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text("inspector.file"))
                .font(.headline)
            detailRow(L10n.text("inspector.size"), value: ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file))
            detailRow(L10n.text("inspector.duration"), value: DurationFormatter.string(track.duration))
            Text(track.managedPath)
                .font(.caption2.monospaced())
                .foregroundStyle(AppTheme.secondaryInk)
                .textSelection(.enabled)
        }
        .padding(AppTheme.spaceMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ongakuPanel()
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(AppTheme.secondaryInk)
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(AppTheme.ink)
        }
        .font(.callout)
    }
}

struct HealthLabel: View {
    @Environment(\.controlActiveState) private var controlActiveState
    let health: FileHealth
    let compact: Bool
    var isSelected = false

    private var color: Color {
        switch health {
        case .verified: AppTheme.good
        case .unchecked: AppTheme.secondaryInk
        case .missing, .changed: AppTheme.warning
        case .unreadable: AppTheme.danger
        }
    }

    var body: some View {
        Group {
            if compact {
                Label(L10n.text(health.titleKey), systemImage: health.symbol)
                    .labelStyle(.iconOnly)
            } else {
                Label(L10n.text(health.titleKey), systemImage: health.symbol)
                    .labelStyle(.titleAndIcon)
            }
        }
        .foregroundStyle(
            isSelected && controlActiveState == .key ? Color.white : color
        )
        .accessibilityLabel(L10n.text(health.titleKey))
    }
}
