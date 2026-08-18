import MediaPlayer
import Testing
@testable import OngakuDesktop

@Suite("System Now Playing")
struct SystemNowPlayingTests {
    @Test("Metadata contains the track, position, state, and queue location")
    func metadataSnapshot() {
        let previousID = UUID()
        let track = makeTrack()
        let nextID = UUID()
        let snapshot = SystemNowPlayingSnapshot(
            track: track,
            duration: 245,
            elapsed: 37.5,
            isPlaying: true,
            queueTrackIDs: [previousID, track.id, nextID]
        )
        let info = snapshot.nowPlayingInfo

        #expect(info[MPMediaItemPropertyTitle] as? String == "Signal")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Ongaku")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "System")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 245)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 37.5)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 1)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 3)
        #expect(
            info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String
                == track.id.uuidString
        )
    }

    @Test("Elapsed time is clamped and paused playback reports zero rate")
    func clampsElapsedTime() {
        let track = makeTrack()
        let snapshot = SystemNowPlayingSnapshot(
            track: track,
            duration: 120,
            elapsed: 200,
            isPlaying: false,
            queueTrackIDs: [track.id]
        )

        #expect(snapshot.elapsed == 120)
        #expect(snapshot.playbackRate == 0)
        #expect(snapshot.queueIndex == 0)
        #expect(snapshot.queueCount == 1)
    }

    private func makeTrack() -> Track {
        Track(
            id: UUID(),
            title: "Signal",
            artist: "Ongaku",
            album: "System",
            duration: 245,
            fileSize: 1_024,
            managedPath: "/tmp/signal.m4a",
            sha256: "system-now-playing",
            addedAt: .now,
            lastVerifiedAt: nil,
            health: .unchecked
        )
    }
}
