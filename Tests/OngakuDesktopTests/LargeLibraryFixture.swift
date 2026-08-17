import Foundation
@testable import OngakuDesktop

enum LargeLibraryFixture {
    static let fullTrackCount = 100_000
    static let tracksPerAlbum = 10
    static let tracksPerArtist = 20

    static func makeDocument(trackCount: Int = fullTrackCount) -> LibraryDocument {
        precondition(trackCount >= 0)
        let artistCount = max(1, (trackCount + tracksPerArtist - 1) / tracksPerArtist)
        let albumCount = max(1, (trackCount + tracksPerAlbum - 1) / tracksPerAlbum)
        let artistIDs = (0..<artistCount).map { stableUUID(namespace: 0x2000_0000, value: $0) }
        let albumIDs = (0..<albumCount).map { stableUUID(namespace: 0x3000_0000, value: $0) }
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let tracks = (0..<trackCount).map { index in
            let artistIndex = index / tracksPerArtist
            let albumIndex = index / tracksPerAlbum
            let titlePrefix = switch index % 3 {
            case 0: "Track"
            case 1: "楽曲"
            default: "曲目"
            }
            return Track(
                id: stableUUID(namespace: 0x1000_0000, value: index),
                title: "\(titlePrefix) \(padded(index, width: 6))",
                artist: "Artist \(padded(artistIndex, width: 4))",
                album: "Album \(padded(albumIndex, width: 5))",
                duration: TimeInterval(120 + index % 300),
                fileSize: Int64(3_000_000 + index % 12_000_000),
                managedPath: "/PerformanceFixture/Artist \(padded(artistIndex, width: 4))/Album \(padded(albumIndex, width: 5))/Track \(padded(index, width: 6)).m4a",
                sha256: String(format: "%064llx", UInt64(index + 1)),
                addedAt: baseDate.addingTimeInterval(TimeInterval(index)),
                lastVerifiedAt: index.isMultiple(of: 5) ? nil : baseDate,
                health: index.isMultiple(of: 97) ? .unchecked : .verified,
                artistID: artistIDs[artistIndex],
                albumID: albumIDs[albumIndex]
            )
        }

        return LibraryDocument(
            updatedAt: baseDate,
            tracks: tracks,
            libraryID: stableUUID(namespace: 0x4000_0000, value: 0),
            createdAt: baseDate,
            playlists: [],
            playbackEvents: []
        )
    }

    private static func stableUUID(namespace: UInt32, value: Int) -> UUID {
        let representation = String(
            format: "%08X-0000-4000-8000-%012llX",
            namespace,
            UInt64(value)
        )
        return UUID(uuidString: representation)!
    }

    private static func padded(_ value: Int, width: Int) -> String {
        String(format: "%0*d", width, value)
    }
}
