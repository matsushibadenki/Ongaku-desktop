/* Hallmark · pre-emit critique: P5 H5 E4 S5 R5 V4
 * component: persistent player transport · genre: atmospheric · theme: Midnight
 * states: native macOS default · hover · focus · active · disabled · playback feedback
 */
import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(AppTheme.rule)
            HStack(spacing: AppTheme.spaceLG) {
                nowPlaying
                    .frame(width: 310, alignment: .leading)
                playbackCenter
                    .frame(maxWidth: .infinity)
                volume
                    .frame(width: 220, alignment: .trailing)
            }
            .padding(.horizontal, AppTheme.spaceLG)
            .frame(height: 92)
            .background(AppTheme.surface)
        }
    }

    private var nowPlaying: some View {
        HStack(spacing: AppTheme.spaceSM) {
            NowPlayingArtwork(track: player.currentTrack, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(player.currentTrack?.title ?? L10n.text("player.idle"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .help(player.currentTrack?.title ?? L10n.text("player.idle"))
                Text(player.currentTrack?.artist ?? L10n.text("player.chooseTrack"))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .lineLimit(1)
                if let album = player.currentTrack?.album {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryInk.opacity(0.82))
                        .lineLimit(1)
                }
            }
        }
    }

    private var playbackCenter: some View {
        VStack(spacing: 7) {
            HStack(spacing: AppTheme.spaceSM) {
                PlaybackModeMenu()
                    .frame(width: 104, alignment: .leading)
                Spacer(minLength: AppTheme.spaceSM)
                PlayerTransportControls()
                Spacer(minLength: AppTheme.spaceSM)
                StereoLevelMeter(levels: player.stereoLevels)
                    .frame(width: 104)
            }

            HStack(spacing: AppTheme.spaceSM) {
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
                .accessibilityLabel(L10n.text("miniPlayer.progress"))
                Text(DurationFormatter.string(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryInk)
                    .frame(width: 42, alignment: .leading)
            }
        }
    }

    private var volume: some View {
        VStack(alignment: .trailing, spacing: 7) {
            if let signalPath = player.signalPathDescription {
                Text(signalPath)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(player.isUpsampling ? AppTheme.good : AppTheme.secondaryInk)
                    .lineLimit(1)
                    .help(L10n.text("player.upsamplingHelp"))
            } else {
                Text(L10n.text("player.outputIdle"))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryInk.opacity(0.78))
            }
            HStack(spacing: AppTheme.spaceXS) {
                PlaybackQueueButton()
                Image(systemName: volumeSymbol)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .frame(width: 18)
                Slider(value: $player.volume, in: 0...1)
                    .frame(width: 150)
                    .accessibilityLabel(L10n.text("miniPlayer.volume"))
            }
        }
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

struct PlayerTransportControls: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController

    var compact = false

    var body: some View {
        HStack(spacing: compact ? AppTheme.spaceXS : AppTheme.spaceSM) {
            Button { player.playPrevious() } label: {
                Image(systemName: "backward.fill")
                    .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(player.currentTrack == nil)
            .help(L10n.text("player.previous"))
            .accessibilityLabel(L10n.text("player.previous"))

            Button(action: primaryPlaybackAction) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(compact ? .small : .regular)
            .disabled(player.currentTrack == nil && playableTrack == nil)
            .keyboardShortcut(.space, modifiers: [])
            .help(L10n.text(player.isPlaying ? "player.pause" : "track.play"))
            .accessibilityLabel(L10n.text(player.isPlaying ? "player.pause" : "track.play"))

            Button { player.playNext() } label: {
                Image(systemName: "forward.fill")
                    .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(player.currentTrack == nil)
            .help(L10n.text("player.next"))
            .accessibilityLabel(L10n.text("player.next"))
        }
    }

    private func primaryPlaybackAction() {
        if player.currentTrack != nil {
            player.togglePlayback()
        } else if let playableTrack {
            player.play(playableTrack)
        }
    }

    private var playableTrack: Track? {
        library.selectedTrack ?? library.filteredTracks.first ?? library.tracks.first
    }
}

struct NowPlayingArtwork: View {
    let track: Track?
    let size: CGFloat

    var body: some View {
        Group {
            if let track {
                ArtworkThumbnail(
                    tracks: [track],
                    subject: .album(name: track.album, artist: track.artist),
                    shape: .roundedRectangle,
                    fallbackSymbol: "waveform",
                    fallbackLetter: String(track.album.prefix(1)).uppercased()
                )
            } else {
                RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous)
                    .fill(AppTheme.raised)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: size * 0.32, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryInk)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous))
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

struct PlaybackQueueContextActions: View {
    @EnvironmentObject private var player: PlaybackController
    let tracks: [Track]

    var body: some View {
        Button(L10n.text("player.queue.playNext")) {
            player.enqueueNext(tracks)
        }
        Button(L10n.text("player.queue.playLater")) {
            player.appendToQueue(tracks)
        }
    }
}

struct PlaybackQueueButton: View {
    @EnvironmentObject private var player: PlaybackController
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "list.bullet")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L10n.text("player.queue.title"))
        .accessibilityLabel(L10n.text("player.queue.title"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PlaybackQueuePopover()
        }
    }
}

private struct PlaybackQueuePopover: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case queue
        case history

        var id: String { rawValue }
        var titleKey: String { "player.\(rawValue).title" }
    }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @State private var selectedTab: Tab = .queue
    @State private var selectedQueueTrackID: Track.ID?
    @State private var selectedHistorySessionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text(selectedTab.titleKey))
                    .font(.headline)
                Spacer()
                if selectedTab == .queue {
                    Button(L10n.text("player.queue.undo")) {
                        player.undoLastQueueEdit()
                    }
                    .buttonStyle(.borderless)
                    .disabled(!player.canUndoQueueEdit)
                    Button(L10n.text("player.queue.clear")) {
                        player.clearUpcomingQueue()
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button(L10n.text("player.history.clear")) {
                        Task { await library.clearPlaybackHistory() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(library.playbackEvents.isEmpty)
                }
            }
            .padding(AppTheme.spaceMD)

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(L10n.text(tab.titleKey)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, AppTheme.spaceMD)
            .padding(.bottom, AppTheme.spaceSM)

            Divider()

            if selectedTab == .queue {
                queueContent
            } else {
                historyContent
            }
        }
        .frame(width: 430)
        .background(AppTheme.surface)
    }

    @ViewBuilder
    private var queueContent: some View {
        if player.queuedTracks.isEmpty {
            ContentUnavailableView(
                L10n.text("player.queue.empty"),
                systemImage: "text.line.first.and.arrowtriangle.forward"
            )
            .frame(height: 310)
        } else {
            List(selection: $selectedQueueTrackID) {
                ForEach(Array(player.queuedTracks.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: AppTheme.spaceSM) {
                        Image(systemName: player.currentTrack?.id == track.id
                              ? "speaker.wave.2.fill" : "music.note")
                            .foregroundStyle(player.currentTrack?.id == track.id
                                             ? AppTheme.accent : AppTheme.secondaryInk)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1)
                            Text("\(track.artist) — \(track.album)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryInk)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(DurationFormatter.string(track.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryInk)
                        queueButtons(track: track, index: index)
                    }
                    .contentShape(Rectangle())
                    .tag(track.id)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            selectedQueueTrackID = track.id
                            library.selectedTrackID = track.id
                        }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            selectedQueueTrackID = track.id
                            library.selectedTrackID = track.id
                            player.play(track)
                        }
                    )
                }
                .onMove(perform: player.moveInQueue)
            }
            .listStyle(.inset)
            .frame(height: 310)
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        let items = PlaybackHistoryResolver.items(
            events: library.playbackEvents,
            tracks: library.tracks
        )
        if items.isEmpty {
            ContentUnavailableView(
                L10n.text("player.history.empty"),
                systemImage: "clock.arrow.circlepath"
            )
            .frame(height: 310)
        } else {
            List(selection: $selectedHistorySessionID) {
                ForEach(items) { item in
                    HStack(spacing: AppTheme.spaceSM) {
                    Image(systemName: historySymbol(item.event.kind))
                        .foregroundStyle(AppTheme.secondaryInk)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.track.title).lineLimit(1)
                        Text("\(item.track.artist) — \(item.track.album)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L10n.text(item.event.kind.titleKey))
                            .font(.caption)
                        Text(item.event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryInk)
                    }
                    }
                    .contentShape(Rectangle())
                    .tag(item.id)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            selectedHistorySessionID = item.id
                            library.selectedTrackID = item.track.id
                        }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            selectedHistorySessionID = item.id
                            library.selectedTrackID = item.track.id
                            player.play(item.track)
                        }
                    )
                }
            }
            .listStyle(.inset)
            .frame(height: 310)
        }
    }

    private func historySymbol(_ kind: PlaybackEvent.Kind) -> String {
        switch kind {
        case .started: "play.circle"
        case .completed: "checkmark.circle"
        case .skipped: "forward.circle"
        }
    }

    @ViewBuilder
    private func queueButtons(track: Track, index: Int) -> some View {
        HStack(spacing: 2) {
            Button { player.moveInQueue(track, offset: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(L10n.text("player.queue.moveUp"))

            Button { player.moveInQueue(track, offset: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == player.queuedTracks.count - 1)
            .help(L10n.text("player.queue.moveDown"))

            Button { player.removeFromQueue(track) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(player.currentTrack?.id == track.id)
            .help(L10n.text("player.queue.remove"))
        }
    }
}

enum DurationFormatter {
    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
