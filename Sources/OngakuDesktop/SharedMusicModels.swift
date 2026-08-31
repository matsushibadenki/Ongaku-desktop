import Foundation

struct MusicBrainzReference: Codable, Hashable, Sendable {
    var recordingID: String?
    var releaseID: String
    var releaseGroupID: String?
    var artistIDs: [String]
    var isrc: String?
    var country: String?
    var mediaFormat: String?
    var coverArtID: String?
    var coverArtTypes: [String]
    var fetchedAt: Date

    var albumReference: MusicBrainzReference {
        MusicBrainzReference(
            recordingID: nil,
            releaseID: releaseID,
            releaseGroupID: releaseGroupID,
            artistIDs: artistIDs,
            isrc: nil,
            country: country,
            mediaFormat: mediaFormat,
            coverArtID: coverArtID,
            coverArtTypes: coverArtTypes,
            fetchedAt: fetchedAt
        )
    }
}
