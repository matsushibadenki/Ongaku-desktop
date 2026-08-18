import AppKit
import Combine
import MediaPlayer

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
    private var observations = Set<AnyCancellable>()
    private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkTrackID: Track.ID?
    private var artwork: MPMediaItemArtwork?

    init(player: PlaybackController) {
        self.player = player
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
            self?.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self?.synchronize()
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { player in
            guard player.currentTrack != nil else { return }
            if !player.isPlaying { player.togglePlayback() }
        }
        register(center.pauseCommand) { player in
            if player.isPlaying { player.togglePlayback() }
        }
        register(center.togglePlayPauseCommand) { player in
            player.togglePlayback()
        }
        register(center.previousTrackCommand) { player in
            player.playPrevious()
        }
        register(center.nextTrackCommand) { player in
            player.playNext()
        }

        center.changePlaybackPositionCommand.isEnabled = true
        let seekToken = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                self?.player?.seek(to: position)
            }
            return .success
        }
        commandTargets.append((center.changePlaybackPositionCommand, seekToken))
    }

    private func register(
        _ command: MPRemoteCommand,
        action: @escaping @MainActor (PlaybackController) -> Void
    ) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let player = self?.player else { return }
                action(player)
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
