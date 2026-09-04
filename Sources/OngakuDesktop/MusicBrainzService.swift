import AppKit
import CryptoKit
import Foundation

struct MusicBrainzCandidate: Identifiable, Equatable, Sendable {
    enum MatchKind: Equatable, Sendable {
        case isrc
        case titleAlbumMatch
        case metadata
        case titleHint
        case albumHint
    }

    let recordingID: String
    let releaseID: String
    let releaseGroupID: String?
    let title: String
    let artist: String
    let artistSortName: String
    let artistIDs: [String]
    let album: String
    let albumArtist: String
    let duration: TimeInterval?
    let releaseDate: String?
    let country: String?
    let mediaFormat: String?
    let trackNumber: Int?
    let trackCount: Int?
    let discNumber: Int?
    let discCount: Int?
    let isrc: String?
    let confidence: Double
    let durationDifference: TimeInterval?
    let matchKind: MatchKind

    var id: String { "\(recordingID):\(releaseID)" }

    var releaseYear: Int? {
        releaseDate.flatMap { Int($0.prefix(4)) }
    }

    func reference(
        coverArt: CoverArtCandidate? = nil,
        fetchedAt: Date = .now
    ) -> MusicBrainzReference {
        MusicBrainzReference(
            recordingID: recordingID,
            releaseID: releaseID,
            releaseGroupID: releaseGroupID,
            artistIDs: artistIDs,
            isrc: isrc,
            country: country,
            mediaFormat: mediaFormat,
            coverArtID: coverArt?.id,
            coverArtTypes: coverArt?.types ?? [],
            fetchedAt: fetchedAt
        )
    }
}

struct CoverArtCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let types: [String]
    let isFront: Bool
    let isBack: Bool
    let isApproved: Bool
    let comment: String
    let originalURL: URL
    let thumbnailURL: URL
    let downloadURL: URL
}

struct MusicBrainzDiscTOC: Equatable, Sendable {
    let firstTrack: Int
    let lastTrack: Int
    let leadoutOffset: Int
    let trackOffsets: [Int]

    init(trackDurations: [TimeInterval]) {
        firstTrack = 1
        lastTrack = trackDurations.count
        var offset = 150
        var offsets: [Int] = []
        for duration in trackDurations {
            offsets.append(offset)
            offset += max(Int((duration * 75).rounded()), 1)
        }
        leadoutOffset = offset
        trackOffsets = offsets
    }

    init(firstTrack: Int, lastTrack: Int, leadoutOffset: Int, trackOffsets: [Int]) {
        self.firstTrack = firstTrack
        self.lastTrack = lastTrack
        self.leadoutOffset = leadoutOffset
        self.trackOffsets = trackOffsets
    }

    var discID: String {
        var hexadecimal = String(format: "%02X%02X%08X", firstTrack, lastTrack, leadoutOffset)
        for index in 0..<99 {
            let trackNumber = index + 1
            let offset: Int
            if trackNumber >= firstTrack,
               trackNumber <= lastTrack,
               trackNumber - firstTrack < trackOffsets.count {
                offset = trackOffsets[trackNumber - firstTrack]
            } else {
                offset = 0
            }
            hexadecimal += String(format: "%08X", offset)
        }
        let digest = Insecure.SHA1.hash(data: Data(hexadecimal.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    var queryValue: String {
        ([firstTrack, lastTrack, leadoutOffset] + trackOffsets)
            .map(String.init)
            .joined(separator: " ")
    }
}

struct MusicBrainzDiscTrackMetadata: Equatable, Sendable {
    let position: Int
    let title: String
    let artist: String
    let recordingID: String?
    let artistIDs: [String]
    let isrc: String?
}

struct MusicBrainzDiscReleaseCandidate: Identifiable, Equatable, Sendable {
    let releaseID: String
    let releaseGroupID: String?
    let title: String
    let artist: String
    let artistIDs: [String]
    let releaseDate: String?
    let country: String?
    let mediaFormat: String?
    let discNumber: Int
    let discCount: Int
    let tracks: [MusicBrainzDiscTrackMetadata]

    var id: String { "\(releaseID):\(discNumber)" }
    var releaseYear: Int? { releaseDate.flatMap { Int($0.prefix(4)) } }
}

enum MusicBrainzServiceError: LocalizedError, Equatable {
    case invalidResponse
    case serviceUnavailable
    case artworkUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: L10n.text("musicbrainz.error.invalidResponse")
        case .serviceUnavailable: L10n.text("musicbrainz.error.unavailable")
        case .artworkUnavailable: L10n.text("musicbrainz.error.artworkUnavailable")
        }
    }
}

actor MusicBrainzService {
    static let shared = MusicBrainzService()

    private static let baseURL = URL(string: "https://musicbrainz.org/ws/2")!
    private static let coverArtBaseURL = URL(string: "https://coverartarchive.org")!
    private static let requestSpacing = Duration.milliseconds(1_100)
    private static let maximumCandidates = 20
    private static let maximumArtworkSize = 12 * 1_024 * 1_024
    private static var clientIdentifier: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.2"
        return "OngakuDesktop/\(version) (https://github.com/matsushibadenki/Ongaku-desktop)"
    }

    private let session: URLSession
    private let clock = ContinuousClock()
    private var nextMusicBrainzRequestAt: ContinuousClock.Instant?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.requestCachePolicy = .useProtocolCachePolicy
            configuration.urlCache = URLCache(
                memoryCapacity: 8 * 1_024 * 1_024,
                diskCapacity: 48 * 1_024 * 1_024,
                diskPath: "OngakuDesktop-MusicBrainz"
            )
            configuration.httpAdditionalHeaders = [
                "User-Agent": Self.clientIdentifier,
                "Accept": "application/json"
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    func candidates(for track: Track) async throws -> [MusicBrainzCandidate] {
        var result: [MusicBrainzCandidate] = []
        if !track.isrc.isEmpty {
            let response: RecordingSearchResponse = try await musicBrainzJSON(
                from: Self.isrcSearchURL(track.isrc)
            )
            result += Self.expand(response, against: track, matchKind: .isrc)
        }
        var response: RecordingSearchResponse = try await musicBrainzJSON(
            from: Self.searchURL(for: track)
        )
        result += Self.expand(response, against: track, matchKind: .metadata)
        if result.isEmpty {
            response = try await musicBrainzJSON(from: Self.searchURL(for: track, includesAlbum: false))
            result += Self.expand(response, against: track, matchKind: .metadata)
        }
        response = try await musicBrainzJSON(from: Self.titleOnlySearchURL(for: track))
        result += Self.expand(response, against: track, matchKind: .titleHint)
            .filter { Self.isUsefulFallback($0, for: track) }
        if result.isEmpty {
            response = try await musicBrainzJSON(from: Self.albumOnlySearchURL(for: track))
            result += Self.expand(response, against: track, matchKind: .albumHint)
                .filter { Self.isUsefulFallback($0, for: track) }
        }
        let unique = Dictionary(grouping: result, by: \.id).compactMap { _, matches in
            Self.orderedCandidates(matches).first
        }
        return Self.orderedCandidates(unique)
        .prefix(Self.maximumCandidates)
        .map { $0 }
    }

    nonisolated static func orderedCandidates(
        _ candidates: [MusicBrainzCandidate]
    ) -> [MusicBrainzCandidate] {
        candidates.sorted {
            let lhsPriority = matchPriority($0.matchKind)
            let rhsPriority = matchPriority($1.matchKind)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            let lhsDuration = $0.durationDifference ?? .greatestFiniteMagnitude
            let rhsDuration = $1.durationDifference ?? .greatestFiniteMagnitude
            if lhsDuration != rhsDuration { return lhsDuration < rhsDuration }
            return $0.id < $1.id
        }
    }

    nonisolated private static func matchPriority(
        _ matchKind: MusicBrainzCandidate.MatchKind
    ) -> Int {
        switch matchKind {
        case .titleAlbumMatch: 0
        case .isrc: 1
        case .titleHint: 2
        case .metadata: 3
        case .albumHint: 4
        }
    }

    func releases(for toc: MusicBrainzDiscTOC) async throws -> [MusicBrainzDiscReleaseCandidate] {
        let response: DiscLookupResponse
        do {
            response = try await musicBrainzJSON(from: Self.discLookupURL(for: toc))
        } catch MusicBrainzServiceError.invalidResponse {
            response = try await musicBrainzJSON(from: Self.tocLookupURL(for: toc))
        }
        return Self.discCandidates(from: response, matching: toc)
    }

    func coverArt(for releaseID: String) async throws -> [CoverArtCandidate] {
        let url = Self.coverArtURL(for: releaseID)
        let response: CoverArtResponse
        do {
            response = try await json(from: url, treatsNotFoundAsEmpty: true)
        } catch MusicBrainzServiceError.artworkUnavailable {
            return []
        }
        return response.images.compactMap(Self.makeCoverArtCandidate).sorted {
            if $0.isFront != $1.isFront { return $0.isFront && !$1.isFront }
            if $0.isApproved != $1.isApproved { return $0.isApproved && !$1.isApproved }
            if $0.isBack != $1.isBack { return !$0.isBack && $1.isBack }
            return $0.id < $1.id
        }
    }

    func downloadArtwork(_ candidate: CoverArtCandidate) async throws -> Data {
        var request = URLRequest(url: candidate.downloadURL)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue(Self.clientIdentifier, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= Self.maximumArtworkSize,
              NSImage(data: data) != nil else {
            throw MusicBrainzServiceError.artworkUnavailable
        }
        return data
    }

    nonisolated static func searchURL(for track: Track, includesAlbum: Bool = true) -> URL {
        var terms = [
            "recording:\"\(escapeLucene(track.title))\"",
            "artist:\"\(escapeLucene(track.artist))\""
        ]
        if includesAlbum {
            terms.append("release:\"\(escapeLucene(track.album))\"")
        }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("recording/"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "query", value: terms.joined(separator: " AND ")),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "20")
        ]
        return components.url!
    }

    nonisolated static func titleOnlySearchURL(for track: Track) -> URL {
        recordingSearchURL(query: "recording:\"\(escapeLucene(track.title))\"")
    }

    nonisolated static func albumOnlySearchURL(for track: Track) -> URL {
        recordingSearchURL(query: "release:\"\(escapeLucene(track.album))\"")
    }

    nonisolated private static func recordingSearchURL(query: String) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("recording/"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "20")
        ]
        return components.url!
    }

    nonisolated static func coverArtURL(for releaseID: String) -> URL {
        coverArtBaseURL
            .appendingPathComponent("release")
            .appendingPathComponent(releaseID)
    }

    nonisolated static func discLookupURL(for toc: MusicBrainzDiscTOC) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("discid").appendingPathComponent(toc.discID),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(
                name: "inc",
                value: "recordings+artist-credits+release-groups+isrcs"
            )
        ]
        return components.url!
    }

    nonisolated static func tocLookupURL(for toc: MusicBrainzDiscTOC) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("discid/-"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "toc", value: toc.queryValue),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(
                name: "inc",
                value: "recordings+artist-credits+release-groups+isrcs"
            )
        ]
        return components.url!
    }

    nonisolated static func isrcSearchURL(_ isrc: String) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("recording/"),
            resolvingAgainstBaseURL: false
        )!
        let normalized = isrc.uppercased().filter { $0.isLetter || $0.isNumber }
        components.queryItems = [
            URLQueryItem(name: "query", value: "isrc:\(normalized)"),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "20")
        ]
        return components.url!
    }

    private func musicBrainzJSON<T: Decodable>(from url: URL) async throws -> T {
        try await reserveMusicBrainzRequestSlot()
        do {
            return try await json(from: url)
        } catch MusicBrainzServiceError.serviceUnavailable {
            try await clock.sleep(for: .milliseconds(1_500))
            try await reserveMusicBrainzRequestSlot()
            return try await json(from: url)
        }
    }

    private func reserveMusicBrainzRequestSlot() async throws {
        let now = clock.now
        let scheduled = max(nextMusicBrainzRequestAt ?? now, now)
        nextMusicBrainzRequestAt = scheduled.advanced(by: Self.requestSpacing)
        if scheduled > now { try await clock.sleep(until: scheduled) }
        try Task.checkCancellation()
    }

    private func json<T: Decodable>(
        from url: URL,
        treatsNotFoundAsEmpty: Bool = false
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.clientIdentifier, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MusicBrainzServiceError.invalidResponse
        }
        if treatsNotFoundAsEmpty, http.statusCode == 404 {
            throw MusicBrainzServiceError.artworkUnavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 503 || http.statusCode == 429 {
                throw MusicBrainzServiceError.serviceUnavailable
            }
            throw MusicBrainzServiceError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MusicBrainzServiceError.invalidResponse
        }
    }

    private nonisolated static func makeCandidate(
        recording: RecordingSearchResponse.Recording,
        release: RecordingSearchResponse.Release,
        track: Track,
        matchKind: MusicBrainzCandidate.MatchKind
    ) -> MusicBrainzCandidate {
        let recordingCredit = creditedArtist(recording.artistCredit)
        let releaseCredit = creditedArtist(release.artistCredit ?? recording.artistCredit)
        let media = release.media?.first(where: { medium in
            medium.tracks?.contains(where: { $0.title == recording.title }) == true
        }) ?? release.media?.first
        let mediumTrack = media?.tracks?.first(where: { $0.title == recording.title })
        let duration = recording.length.map { Double($0) / 1_000 }
        let durationDifference = duration.map { abs($0 - track.duration) }
        let titleScore = similarity(recording.title, track.title)
        let artistScore = similarity(recordingCredit.name, track.artist)
        let albumScore = similarity(release.title, track.album)
        let durationScore = durationDifference.map { max(0, 1 - $0 / 15) } ?? 0.5
        let serverScore = min(max(Double(recording.score ?? 0) / 100, 0), 1)
        let normalizedTrackISRC = track.isrc.uppercased().filter { $0.isLetter || $0.isNumber }
        let candidateISRC = recording.isrcs?.first?.uppercased() ?? ""
        let confidence: Double
        if normalizedTrackISRC.isEmpty {
            confidence = min(
                1,
                titleScore * 0.30 + artistScore * 0.25 + albumScore * 0.15
                    + durationScore * 0.15 + serverScore * 0.15
            )
        } else {
            let isrcScore = candidateISRC == normalizedTrackISRC ? 1.0 : 0.0
            confidence = min(
                1,
                titleScore * 0.25 + artistScore * 0.20 + albumScore * 0.12
                    + durationScore * 0.13 + serverScore * 0.10 + isrcScore * 0.20
            )
        }
        let resolvedMatchKind: MusicBrainzCandidate.MatchKind
        if matchKind == .isrc {
            resolvedMatchKind = .isrc
        } else if titleScore == 1, albumScore == 1 {
            resolvedMatchKind = .titleAlbumMatch
        } else if titleScore == 1 || matchKind == .titleHint {
            resolvedMatchKind = .titleHint
        } else {
            resolvedMatchKind = matchKind
        }
        return MusicBrainzCandidate(
            recordingID: recording.id,
            releaseID: release.id,
            releaseGroupID: release.releaseGroup?.id,
            title: recording.title,
            artist: recordingCredit.name,
            artistSortName: recordingCredit.sortName,
            artistIDs: recording.artistCredit.map(\.artist.id),
            album: release.title,
            albumArtist: releaseCredit.name,
            duration: duration,
            releaseDate: release.date ?? recording.firstReleaseDate,
            country: release.country,
            mediaFormat: media?.format,
            trackNumber: mediumTrack.flatMap { Int($0.number) },
            trackCount: media?.trackCount,
            discNumber: media?.position,
            discCount: release.mediumCount,
            isrc: recording.isrcs?.first,
            confidence: confidence,
            durationDifference: durationDifference,
            matchKind: resolvedMatchKind
        )
    }

    private nonisolated static func discCandidates(
        from response: DiscLookupResponse,
        matching toc: MusicBrainzDiscTOC
    ) -> [MusicBrainzDiscReleaseCandidate] {
        let candidates = response.releases.flatMap { release -> [MusicBrainzDiscReleaseCandidate] in
            let releaseCredit = creditedArtist(release.artistCredit)
            return release.media.compactMap { medium in
                let matchesDiscID = medium.discs?.contains(where: { $0.id == toc.discID }) == true
                guard matchesDiscID || medium.tracks.count == toc.trackOffsets.count else {
                    return nil
                }
                let tracks = medium.tracks.sorted { $0.position < $1.position }.map { track in
                    let credits = track.recording?.artistCredit ?? track.artistCredit
                        ?? release.artistCredit
                    let credit = creditedArtist(credits)
                    return MusicBrainzDiscTrackMetadata(
                        position: track.position,
                        title: track.title,
                        artist: credit.name,
                        recordingID: track.recording?.id,
                        artistIDs: credits.map(\.artist.id),
                        isrc: track.recording?.isrcs?.first
                    )
                }
                return MusicBrainzDiscReleaseCandidate(
                    releaseID: release.id,
                    releaseGroupID: release.releaseGroup?.id,
                    title: release.title,
                    artist: releaseCredit.name,
                    artistIDs: release.artistCredit.map(\.artist.id),
                    releaseDate: release.date,
                    country: release.country,
                    mediaFormat: medium.format,
                    discNumber: medium.position,
                    discCount: release.media.count,
                    tracks: tracks
                )
            }
        }
        return Dictionary(grouping: candidates, by: \.id).compactMap { $0.value.first }.sorted {
            if $0.releaseDate != $1.releaseDate {
                return ($0.releaseDate ?? "9999") < ($1.releaseDate ?? "9999")
            }
            return $0.id < $1.id
        }
    }

    private nonisolated static func expand(
        _ response: RecordingSearchResponse,
        against track: Track,
        matchKind: MusicBrainzCandidate.MatchKind
    ) -> [MusicBrainzCandidate] {
        response.recordings.flatMap { recording in
            (recording.releases ?? []).map { release in
                makeCandidate(
                    recording: recording,
                    release: release,
                    track: track,
                    matchKind: matchKind
                )
            }
        }
    }

    nonisolated static func isUsefulFallback(
        _ candidate: MusicBrainzCandidate,
        for track: Track
    ) -> Bool {
        switch candidate.matchKind {
        case .titleHint:
            similarity(candidate.title, track.title) >= 0.55
        case .albumHint:
            similarity(candidate.album, track.album) >= 0.55
        case .isrc, .titleAlbumMatch, .metadata:
            true
        }
    }

    private nonisolated static func makeCoverArtCandidate(
        _ image: CoverArtResponse.Image
    ) -> CoverArtCandidate? {
        guard let original = secureURL(image.image),
              let thumbnail = secureURL(
                image.thumbnails.fiveHundred
                    ?? image.thumbnails.large
                    ?? image.thumbnails.twoFifty
                    ?? image.image
              ),
              let download = secureURL(
                image.thumbnails.twelveHundred
                    ?? image.thumbnails.fiveHundred
                    ?? image.thumbnails.large
                    ?? image.image
              ) else { return nil }
        return CoverArtCandidate(
            id: String(image.id),
            types: image.types,
            isFront: image.front,
            isBack: image.back,
            isApproved: image.approved,
            comment: image.comment,
            originalURL: original,
            thumbnailURL: thumbnail,
            downloadURL: download
        )
    }

    private nonisolated static func creditedArtist(
        _ credits: [RecordingSearchResponse.ArtistCredit]
    ) -> (name: String, sortName: String) {
        let name = credits.map { $0.name + ($0.joinphrase ?? "") }.joined()
        let sortName = credits.map { $0.artist.sortName }.joined(separator: "; ")
        return (name, sortName)
    }

    private nonisolated static func escapeLucene(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private nonisolated static func secureURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value) else { return nil }
        if components.scheme == "http" { components.scheme = "https" }
        return components.url
    }

    private nonisolated static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        if left.contains(right) || right.contains(left) { return 0.85 }
        let leftTokens = Set(tokenized(lhs))
        let rightTokens = Set(tokenized(rhs))
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }
        return Double(leftTokens.intersection(rightTokens).count)
            / Double(leftTokens.union(rightTokens).count)
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .unicodeScalars
        .filter(CharacterSet.alphanumerics.contains)
        .map(String.init)
        .joined()
    }

    private nonisolated static func tokenized(_ value: String) -> [String] {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    }
}

private struct RecordingSearchResponse: Decodable {
    let recordings: [Recording]

    struct Recording: Decodable {
        let id: String
        let title: String
        let score: Int?
        let length: Int?
        let isrcs: [String]?
        let firstReleaseDate: String?
        let artistCredit: [ArtistCredit]
        let releases: [Release]?

        enum CodingKeys: String, CodingKey {
            case id, title, score, length, isrcs, releases
            case firstReleaseDate = "first-release-date"
            case artistCredit = "artist-credit"
        }
    }

    struct ArtistCredit: Decodable {
        let name: String
        let joinphrase: String?
        let artist: Artist
    }

    struct Artist: Decodable {
        let id: String
        let name: String
        let sortName: String

        enum CodingKeys: String, CodingKey {
            case id, name
            case sortName = "sort-name"
        }
    }

    struct Release: Decodable {
        let id: String
        let title: String
        let date: String?
        let country: String?
        let mediumCount: Int?
        let artistCredit: [ArtistCredit]?
        let releaseGroup: ReleaseGroup?
        let media: [Medium]?

        enum CodingKeys: String, CodingKey {
            case id, title, date, country, media
            case mediumCount = "count"
            case artistCredit = "artist-credit"
            case releaseGroup = "release-group"
        }
    }

    struct ReleaseGroup: Decodable { let id: String }

    struct Medium: Decodable {
        let position: Int?
        let format: String?
        let trackCount: Int?
        let tracks: [MediumTrack]?

        enum CodingKeys: String, CodingKey {
            case position, format
            case trackCount = "track-count"
            case tracks = "track"
        }
    }

    struct MediumTrack: Decodable {
        let number: String
        let title: String
    }
}

private struct DiscLookupResponse: Decodable {
    let releases: [Release]

    struct Release: Decodable {
        let id: String
        let title: String
        let date: String?
        let country: String?
        let artistCredit: [RecordingSearchResponse.ArtistCredit]
        let releaseGroup: RecordingSearchResponse.ReleaseGroup?
        let media: [Medium]

        enum CodingKeys: String, CodingKey {
            case id, title, date, country, media
            case artistCredit = "artist-credit"
            case releaseGroup = "release-group"
        }
    }

    struct Medium: Decodable {
        let position: Int
        let format: String?
        let discs: [Disc]?
        let tracks: [Track]
    }

    struct Disc: Decodable { let id: String }

    struct Track: Decodable {
        let position: Int
        let title: String
        let artistCredit: [RecordingSearchResponse.ArtistCredit]?
        let recording: Recording?

        enum CodingKeys: String, CodingKey {
            case position, title, recording
            case artistCredit = "artist-credit"
        }
    }

    struct Recording: Decodable {
        let id: String
        let isrcs: [String]?
        let artistCredit: [RecordingSearchResponse.ArtistCredit]

        enum CodingKeys: String, CodingKey {
            case id, isrcs
            case artistCredit = "artist-credit"
        }
    }
}

private struct CoverArtResponse: Decodable {
    let images: [Image]

    struct Image: Decodable {
        let id: Int64
        let types: [String]
        let front: Bool
        let back: Bool
        let approved: Bool
        let comment: String
        let image: String
        let thumbnails: Thumbnails
    }

    struct Thumbnails: Decodable {
        let twoFifty: String?
        let fiveHundred: String?
        let twelveHundred: String?
        let small: String?
        let large: String?

        enum CodingKeys: String, CodingKey {
            case twoFifty = "250"
            case fiveHundred = "500"
            case twelveHundred = "1200"
            case small, large
        }
    }
}
