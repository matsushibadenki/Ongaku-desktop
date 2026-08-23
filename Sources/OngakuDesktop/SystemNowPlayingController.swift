import AppKit
import Combine
import MediaPlayer

private final class NowPlayingArtworkImageBox: @unchecked Sendable {
    let image: NSImage

    init(_ image: NSImage) {
        self.image = image
    }
}

// MediaPlayer invokes this request handler on MPNowPlayingInfoCenter/accessQueue.
// Creating it outside the MainActor controller avoids attaching a main-queue
// executor precondition to the callback.
private func makeNowPlayingArtwork(
    from box: NowPlayingArtworkImageBox
) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: box.image.size) { _ in box.image }
}

struct SystemNowPlayingSnapshot: Equatable, Sendable {
    let trackID: Track.ID
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let elapsed: TimeInterval
    let playbackRate: Double
    let queueIndex: Int
    let queueCount: Int

    @MainActor
    init(player: PlaybackController, track: Track) {
        self.init(
            track: track,
            duration: player.duration,
            elapsed: player.elapsed,
            isPlaying: player.isPlaying,
            queueTrackIDs: player.queueState.trackIDs
        )
    }

    init(
        track: Track,
        duration: TimeInterval,
        elapsed: TimeInterval,
        isPlaying: Bool,
        queueTrackIDs: [Track.ID]
    ) {
        trackID = track.id
        title = track.title
        artist = track.artist
        album = track.album
        self.duration = max(duration, 0)
        self.elapsed = min(max(elapsed, 0), self.duration)
        playbackRate = isPlaying ? 1 : 0
        queueIndex = queueTrackIDs.firstIndex(of: track.id) ?? 0
        queueCount = queueTrackIDs.count
    }

    var nowPlayingInfo: [String: Any] {
        [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: trackID.uuidString,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: queueIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queueCount
        ]
    }
}

/// Keeps macOS Control Center and media-key commands synchronized with the
/// app's existing playback controller. Remote commands always return to the
/// main actor before touching the AVAudioEngine-backed player.
@MainActor
final class SystemNowPlayingController: ObservableObject {
    private weak var player: PlaybackController?
    private weak var appleMusicPlayback: AppleMusicPlaybackController?
    private var observations = Set<AnyCancellable>()
    private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkTrackID: Track.ID?
    private var artwork: MPMediaItemArtwork?

    init(
        player: PlaybackController,
        appleMusicPlayback: AppleMusicPlaybackController
    ) {
        self.player = player
        self.appleMusicPlayback = appleMusicPlayback
        configureRemoteCommands()

        Publishers.CombineLatest3(
            player.$currentTrack,
            player.$isPlaying,
            player.$queueState
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            self?.synchronize()
        }
        .store(in: &observations)

        appleMusicPlayback.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.synchronize()
            }
            .store(in: &observations)

        // Control Center advances elapsed time from the playback rate. A
        // one-second correction is enough to keep seeks and long playback in
        // sync without replacing the full metadata dictionary four times/sec.
        player.$elapsed
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.synchronize()
            }
            .store(in: &observations)

        synchronize()
    }

    func activate() {
        synchronize()
    }

    private func synchronize() {
        if appleMusicPlayback?.currentItem != nil {
            updateCommandAvailability(hasTrack: true)
            return
        }
        guard let player, let track = player.currentTrack else {
            artworkTask?.cancel()
            artworkTask = nil
            artworkTrackID = nil
            artwork = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            updateCommandAvailability(hasTrack: false)
            return
        }

        if artworkTrackID != track.id {
            artworkTrackID = track.id
            artwork = nil
            loadArtwork(for: track)
        }

        var info = SystemNowPlayingSnapshot(player: player, track: track).nowPlayingInfo
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
        updateCommandAvailability(hasTrack: true)
    }

    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            let subject = ArtworkSubject.album(name: track.album, artist: track.artist)
            let data = if let custom = await ArtworkResolver.shared.customArtworkData(for: subject) {
                custom
            } else if let embedded = await EmbeddedArtworkCache.shared.firstArtworkData(for: [track.fileURL]) {
                embedded
            } else {
                await ArtworkResolver.shared.artworkData(for: subject)
            }
            guard !Task.isCancelled,
                  let data,
                  let image = NSImage(data: data),
                  self?.artworkTrackID == track.id else { return }
            self?.artwork = makeNowPlayingArtwork(
                from: NowPlayingArtworkImageBox(image)
            )
            self?.synchronize()
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { player, appleMusicPlayback in
            if appleMusicPlayback.currentItem != nil {
                if !appleMusicPlayback.isPlaying {
                    Task { await appleMusicPlayback.resume() }
                }
            } else if player.currentTrack != nil, !player.isPlaying {
                player.togglePlayback()
            }
        }
        register(center.pauseCommand) { player, appleMusicPlayback in
            if appleMusicPlayback.currentItem != nil {
                appleMusicPlayback.pause()
            } else if player.isPlaying {
                player.togglePlayback()
            }
        }
        register(center.togglePlayPauseCommand) { player, appleMusicPlayback in
            if appleMusicPlayback.currentItem != nil {
                if appleMusicPlayback.isPlaying {
                    appleMusicPlayback.pause()
                } else {
                    Task { await appleMusicPlayback.resume() }
                }
            } else {
                player.togglePlayback()
            }
        }
        register(center.previousTrackCommand) { player, appleMusicPlayback in
            if appleMusicPlayback.currentItem != nil {
                Task { await appleMusicPlayback.playPrevious() }
            } else {
                player.playPrevious()
            }
        }
        register(center.nextTrackCommand) { player, appleMusicPlayback in
            if appleMusicPlayback.currentItem != nil {
                Task { await appleMusicPlayback.playNext() }
            } else {
                player.playNext()
            }
        }

        center.changePlaybackPositionCommand.isEnabled = true
        let seekToken = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                if let appleMusicPlayback = self?.appleMusicPlayback,
                   appleMusicPlayback.currentItem != nil {
                    appleMusicPlayback.seek(to: position)
                } else {
                    self?.player?.seek(to: position)
                }
            }
            return .success
        }
        commandTargets.append((center.changePlaybackPositionCommand, seekToken))
    }

    private func register(
        _ command: MPRemoteCommand,
        action: @escaping @MainActor (
            PlaybackController,
            AppleMusicPlaybackController
        ) -> Void
    ) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let player = self?.player,
                      let appleMusicPlayback = self?.appleMusicPlayback else { return }
                action(player, appleMusicPlayback)
            }
            return .success
        }
        commandTargets.append((command, token))
    }

    private func updateCommandAvailability(hasTrack: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = hasTrack
        center.pauseCommand.isEnabled = hasTrack
        center.togglePlayPauseCommand.isEnabled = hasTrack
        center.previousTrackCommand.isEnabled = hasTrack
        center.nextTrackCommand.isEnabled = hasTrack
        center.changePlaybackPositionCommand.isEnabled = hasTrack
    }
}
