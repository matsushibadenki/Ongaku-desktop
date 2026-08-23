import AppKit
import MusicKit
import SwiftUI

enum AppleMusicCatalogItemKind: String, Sendable {
    case song
    case album
    case artist
    case playlist
    case musicVideo
    case station

    var localizationKey: String { "appleMusic.kind.\(rawValue)" }

    var isPlayable: Bool {
        switch self {
        case .song, .album, .playlist, .station: true
        case .artist, .musicVideo: false
        }
    }

    var canEnqueue: Bool {
        switch self {
        case .song, .album, .playlist: true
        case .artist, .musicVideo, .station: false
        }
    }

    var catalogRatingType: String? {
        switch self {
        case .song: "songs"
        case .album: "albums"
        case .playlist: "playlists"
        case .musicVideo: "music-videos"
        case .station: "stations"
        case .artist: nil
        }
    }
}

enum AppleMusicLibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case songs
    case albums
    case playlists

    var id: String { rawValue }
    var localizationKey: String { "appleMusic.library.filter.\(rawValue)" }

    func includes(_ kind: AppleMusicCatalogItemKind) -> Bool {
        switch self {
        case .all: true
        case .songs: kind == .song
        case .albums: kind == .album
        case .playlists: kind == .playlist
        }
    }
}

struct AppleMusicCatalogItem: Identifiable, Sendable {
    let id: String
    let musicItemID: String
    let kind: AppleMusicCatalogItemKind
    let title: String
    let subtitle: String
    let detail: String
    let artworkURL: URL?
    let destinationURL: URL?
    let playlistTrackType: String?
    let ratingResourceType: String?

    init(
        id: String,
        musicItemID: String,
        kind: AppleMusicCatalogItemKind,
        title: String,
        subtitle: String,
        detail: String,
        artworkURL: URL?,
        destinationURL: URL?,
        playlistTrackType: String? = nil,
        ratingResourceType: String? = nil
    ) {
        self.id = id
        self.musicItemID = musicItemID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.artworkURL = artworkURL
        self.destinationURL = destinationURL
        self.playlistTrackType = playlistTrackType
        self.ratingResourceType = ratingResourceType ?? kind.catalogRatingType
    }
}

private enum AppleMusicServiceError: Error {
    case unauthorized
    case unavailable
    case conflict
    case rateLimited
    case server

    var localizationKey: String {
        switch self {
        case .unauthorized: "appleMusic.error.unauthorized"
        case .unavailable: "appleMusic.error.unavailable"
        case .conflict: "appleMusic.error.conflict"
        case .rateLimited: "appleMusic.error.rateLimited"
        case .server: "appleMusic.error.server"
        }
    }
}

struct ITunesStoreItem: Identifiable, Sendable, Decodable {
    let trackId: Int
    let trackName: String
    let artistName: String
    let collectionName: String?
    let artworkUrl100: URL?
    let trackViewUrl: URL?
    let trackPrice: Double?
    let currency: String?

    var id: Int { trackId }
}

private struct ITunesStoreResponse: Decodable, Sendable {
    let results: [ITunesStoreItem]
}

private struct AppleMusicRatingsResponse: Decodable, Sendable {
    struct Rating: Decodable, Sendable {
        struct Attributes: Decodable, Sendable {
            let value: Int
        }

        let id: String
        let attributes: Attributes
    }

    let data: [Rating]
}

actor ITunesStoreClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated static func searchURL(
        term: String,
        countryCode: String,
        limit: Int = 40
    ) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: countryCode.uppercased()),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200))),
            URLQueryItem(name: "explicit", value: "Yes"),
        ]
        return components?.url
    }

    nonisolated static func decodeResponse(_ data: Data) throws -> [ITunesStoreItem] {
        try JSONDecoder().decode(ITunesStoreResponse.self, from: data).results
    }

    func search(term: String, countryCode: String) async throws -> [ITunesStoreItem] {
        guard let url = Self.searchURL(term: term, countryCode: countryCode) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try Self.decodeResponse(data)
    }
}

@MainActor
final class AppleMusicStoreController: ObservableObject {
    nonisolated static let subscriptionURL = URL(string: "https://www.apple.com/apple-music/")!

    enum AuthorizationState: Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized

        var localizationKey: String {
            switch self {
            case .notDetermined: "appleMusic.authorization.notDetermined"
            case .denied: "appleMusic.authorization.denied"
            case .restricted: "appleMusic.authorization.restricted"
            case .authorized: "appleMusic.authorization.authorized"
            }
        }
    }

    @Published private(set) var authorization: AuthorizationState = .notDetermined
    @Published private(set) var canPlayCatalogContent = false
    @Published private(set) var canBecomeSubscriber = false
    @Published private(set) var hasCloudLibraryEnabled = false
    @Published private(set) var catalogItems: [AppleMusicCatalogItem] = []
    @Published private(set) var storeItems: [ITunesStoreItem] = []
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published private(set) var addedSongIDs: Set<String> = []
    @Published private(set) var libraryPlaylists: [AppleMusicCatalogItem] = []
    @Published private(set) var favoriteResourceKeys: Set<String> = []
    @Published private(set) var hasMoreLibraryItems = false
    @Published private(set) var playlistEntries: [AppleMusicCatalogItem] = []
    @Published private(set) var playlistContentsTitle = ""
    @Published private(set) var unifiedCatalogItems: [AppleMusicCatalogItem] = []
    @Published private(set) var unifiedLibraryItems: [AppleMusicCatalogItem] = []
    @Published private(set) var isUnifiedSearchWorking = false
    @Published private(set) var unifiedSearchMessage: String?

    private let storeClient: ITunesStoreClient
    private var songsByID: [String: Song] = [:]
    private var albumsByID: [String: Album] = [:]
    private var playlistsByID: [String: MusicKit.Playlist] = [:]
    private var stationsByID: [String: Station] = [:]
    private var librarySongItems: [AppleMusicCatalogItem] = []
    private var libraryAlbumItems: [AppleMusicCatalogItem] = []
    private var libraryPlaylistItems: [AppleMusicCatalogItem] = []
    private var libraryOffset = 0
    private let libraryPageSize = 100
    private var libraryFilter: AppleMusicLibraryFilter = .all
    private var unifiedSearchGeneration = UUID()

    init(storeClient: ITunesStoreClient = ITunesStoreClient()) {
        self.storeClient = storeClient
        refreshAuthorizationState()
    }

    func requestAccess() async {
        isWorking = true
        let status = await MusicAuthorization.request()
        authorization = Self.authorizationState(status)
        if authorization == .authorized {
            await refreshSubscription()
        }
        isWorking = false
    }

    func refresh() async {
        refreshAuthorizationState()
        guard authorization == .authorized else { return }
        await refreshSubscription()
        if hasCloudLibraryEnabled {
            await loadLibraryPlaylists()
        }
    }

    func loadLibrary(reset: Bool = true) async {
        guard authorization == .authorized else {
            message = L10n.text("appleMusic.search.authorizationRequired")
            return
        }
        guard hasCloudLibraryEnabled else {
            message = L10n.text("appleMusic.library.cloudRequired")
            return
        }
        isWorking = true
        message = nil
        do {
            if reset {
                libraryOffset = 0
                librarySongItems = []
                libraryAlbumItems = []
                libraryPlaylistItems = []
            }
            var songRequest = MusicLibraryRequest<Song>()
            songRequest.limit = libraryPageSize
            songRequest.offset = libraryOffset
            var albumRequest = MusicLibraryRequest<Album>()
            albumRequest.limit = libraryPageSize
            albumRequest.offset = libraryOffset
            var playlistRequest = MusicLibraryRequest<MusicKit.Playlist>()
            playlistRequest.limit = libraryPageSize
            playlistRequest.offset = libraryOffset
            playlistRequest.sort(by: \.name, ascending: true)
            async let songResponse = songRequest.response()
            async let albumResponse = albumRequest.response()
            async let playlistResponse = playlistRequest.response()
            let (songResult, albumResult, playlistResult) = try await (
                songResponse,
                albumResponse,
                playlistResponse
            )

            songsByID.merge(
                Dictionary(uniqueKeysWithValues: songResult.items.map { ($0.id.rawValue, $0) })
            ) { _, new in new }
            albumsByID.merge(
                Dictionary(uniqueKeysWithValues: albumResult.items.map { ($0.id.rawValue, $0) })
            ) { _, new in new }
            playlistsByID.merge(
                Dictionary(uniqueKeysWithValues: playlistResult.items.map {
                    ($0.id.rawValue, $0)
                })
            ) { _, new in new }
            let songs = songResult.items.map { song in
                AppleMusicCatalogItem(
                    id: "librarySong:\(song.id.rawValue)",
                    musicItemID: song.id.rawValue,
                    kind: .song,
                    title: song.title,
                    subtitle: song.artistName,
                    detail: song.albumTitle ?? "",
                    artworkURL: song.artwork?.url(width: 180, height: 180),
                    destinationURL: song.url,
                    playlistTrackType: "library-songs",
                    ratingResourceType: "library-songs"
                )
            }
            let albums = albumResult.items.map { album in
                AppleMusicCatalogItem(
                    id: "libraryAlbum:\(album.id.rawValue)",
                    musicItemID: album.id.rawValue,
                    kind: .album,
                    title: album.title,
                    subtitle: album.artistName,
                    detail: L10n.format("appleMusic.album.trackCount", album.trackCount),
                    artworkURL: album.artwork?.url(width: 180, height: 180),
                    destinationURL: album.url,
                    ratingResourceType: "library-albums"
                )
            }
            let playlists = playlistResult.items.map { playlist in
                Self.libraryPlaylistItem(playlist)
            }
            librarySongItems = Self.merging(librarySongItems, with: songs)
            libraryAlbumItems = Self.merging(libraryAlbumItems, with: albums)
            libraryPlaylistItems = Self.merging(libraryPlaylistItems, with: playlists)
            libraryPlaylists = libraryPlaylistItems
            rebuildLibraryCatalog()
            hasMoreLibraryItems = [
                songResult.items.count,
                albumResult.items.count,
                playlistResult.items.count,
            ].contains(libraryPageSize)
            libraryOffset += libraryPageSize
            await refreshFavoriteRatings(for: catalogItems)
            message = catalogItems.isEmpty
                ? L10n.text("appleMusic.library.empty")
                : L10n.format("appleMusic.library.loaded", catalogItems.count)
        } catch {
            message = Self.localizedServiceError(error)
        }
        isWorking = false
    }

    func loadMoreLibrary() async {
        guard hasMoreLibraryItems, !isWorking else { return }
        await loadLibrary(reset: false)
    }

    func setLibraryFilter(_ filter: AppleMusicLibraryFilter) {
        libraryFilter = filter
        rebuildLibraryCatalog()
    }

    func searchLibrary(_ rawTerm: String, filter: AppleMusicLibraryFilter) async {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            setLibraryFilter(filter)
            return
        }
        guard authorization == .authorized, hasCloudLibraryEnabled else {
            message = L10n.text("appleMusic.library.cloudRequired")
            return
        }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let types: [any MusicLibrarySearchable.Type]
            switch filter {
            case .all:
                types = [Song.self, Album.self, MusicKit.Playlist.self]
            case .songs:
                types = [Song.self]
            case .albums:
                types = [Album.self]
            case .playlists:
                types = [MusicKit.Playlist.self]
            }
            var request = MusicLibrarySearchRequest(term: term, types: types)
            request.limit = 100
            request.includeTopResults = true
            let response = try await request.response()
            songsByID.merge(
                Dictionary(uniqueKeysWithValues: response.songs.map { ($0.id.rawValue, $0) })
            ) { _, new in new }
            albumsByID.merge(
                Dictionary(uniqueKeysWithValues: response.albums.map { ($0.id.rawValue, $0) })
            ) { _, new in new }
            playlistsByID.merge(
                Dictionary(uniqueKeysWithValues: response.playlists.map {
                    ($0.id.rawValue, $0)
                })
            ) { _, new in new }

            let songs = response.songs.map(Self.librarySongItem)
            let albums = response.albums.map(Self.libraryAlbumItem)
            let playlists = response.playlists.map(Self.libraryPlaylistItem)
            catalogItems = songs + albums + playlists
            hasMoreLibraryItems = false
            await refreshFavoriteRatings(for: catalogItems)
            message = catalogItems.isEmpty
                ? L10n.text("appleMusic.search.noResults")
                : L10n.format("appleMusic.library.searchResults", catalogItems.count)
        } catch {
            message = Self.localizedServiceError(error)
        }
    }

    func loadPlaylistContents(_ item: AppleMusicCatalogItem) async {
        guard item.kind == .playlist,
              let playlist = playlistsByID[item.musicItemID] else { return }
        isWorking = true
        message = nil
        playlistEntries = []
        playlistContentsTitle = item.title
        defer { isWorking = false }
        do {
            let detailedPlaylist = try await playlist.with(.entries)
            let entries = detailedPlaylist.entries ?? []
            var result: [AppleMusicCatalogItem] = []
            for entry in entries {
                guard let entryItem = entry.item else { continue }
                switch entryItem {
                case let .song(song):
                    songsByID[song.id.rawValue] = song
                    result.append(Self.librarySongItem(song))
                case let .musicVideo(video):
                    result.append(AppleMusicCatalogItem(
                        id: "playlistVideo:\(entry.id.rawValue)",
                        musicItemID: video.id.rawValue,
                        kind: .musicVideo,
                        title: video.title,
                        subtitle: video.artistName,
                        detail: video.albumTitle ?? "",
                        artworkURL: video.artwork?.url(width: 180, height: 180),
                        destinationURL: video.url,
                        playlistTrackType: "library-music-videos",
                        ratingResourceType: "library-music-videos"
                    ))
                @unknown default:
                    continue
                }
            }
            playlistEntries = result
            await refreshFavoriteRatings(for: result)
            if result.isEmpty {
                message = L10n.text("appleMusic.library.playlistEmpty")
            }
        } catch {
            message = Self.localizedServiceError(error)
        }
    }

    func createLibraryPlaylist(name rawName: String, description: String) async -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, hasCloudLibraryEnabled else { return false }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            var request = URLRequest(url: URL(
                string: "https://api.music.apple.com/v1/me/library/playlists"
            )!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.playlistCreationBody(name: name, description: description)
            let response = try await MusicDataRequest(urlRequest: request).response()
            try Self.validateStatus(response.urlResponse.statusCode, accepted: [201])
            await loadLibraryPlaylists()
            message = L10n.format("appleMusic.library.playlistCreated", name)
            return true
        } catch {
            message = Self.localizedServiceError(error)
            return false
        }
    }

    func addSong(_ item: AppleMusicCatalogItem, to playlist: AppleMusicCatalogItem) async {
        guard item.kind == .song, playlist.kind == .playlist else { return }
        guard hasCloudLibraryEnabled else {
            message = L10n.text("appleMusic.library.cloudRequired")
            return
        }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let baseURL = URL(string: "https://api.music.apple.com/v1/me/library/playlists")!
            let url = baseURL
                .appendingPathComponent(playlist.musicItemID)
                .appendingPathComponent("tracks")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.playlistTracksBody(
                id: item.musicItemID,
                type: item.playlistTrackType ?? "songs"
            )
            let response = try await MusicDataRequest(urlRequest: request).response()
            try Self.validateStatus(response.urlResponse.statusCode, accepted: [204])
            message = L10n.format(
                "appleMusic.library.addedToPlaylist",
                item.title,
                playlist.title
            )
        } catch {
            message = Self.localizedServiceError(error)
        }
    }

    func isFavorite(_ item: AppleMusicCatalogItem) -> Bool {
        guard let key = Self.favoriteKey(item) else { return false }
        return favoriteResourceKeys.contains(key)
    }

    func toggleFavorite(_ item: AppleMusicCatalogItem) async {
        guard let resourceType = item.ratingResourceType,
              let key = Self.favoriteKey(item) else { return }
        let removing = favoriteResourceKeys.contains(key)
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let baseURL = URL(string: "https://api.music.apple.com/v1/me/ratings")!
            let url = baseURL
                .appendingPathComponent(resourceType)
                .appendingPathComponent(item.musicItemID)
            var request = URLRequest(url: url)
            request.httpMethod = removing ? "DELETE" : "PUT"
            if !removing {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try Self.favoriteRatingBody()
            }
            let response = try await MusicDataRequest(urlRequest: request).response()
            try Self.validateStatus(
                response.urlResponse.statusCode,
                accepted: removing ? [204] : [200]
            )
            if removing {
                favoriteResourceKeys.remove(key)
            } else {
                favoriteResourceKeys.insert(key)
            }
            message = L10n.format(
                removing
                    ? "appleMusic.favorite.removed" : "appleMusic.favorite.added",
                item.title
            )
        } catch {
            message = Self.localizedServiceError(error)
        }
    }

    func searchAppleMusic(_ rawTerm: String) async {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        guard authorization == .authorized else {
            message = L10n.text("appleMusic.search.authorizationRequired")
            return
        }
        isWorking = true
        message = nil
        do {
            var request = MusicCatalogSearchRequest(
                term: term,
                types: [
                    Song.self,
                    Album.self,
                    Artist.self,
                    MusicKit.Playlist.self,
                    MusicVideo.self,
                    Station.self,
                ]
            )
            request.limit = 20
            request.includeTopResults = true
            let response = try await request.response()
            songsByID = Dictionary(
                uniqueKeysWithValues: response.songs.map { ($0.id.rawValue, $0) }
            )
            albumsByID = Dictionary(
                uniqueKeysWithValues: response.albums.map { ($0.id.rawValue, $0) }
            )
            playlistsByID = Dictionary(
                uniqueKeysWithValues: response.playlists.map { ($0.id.rawValue, $0) }
            )
            stationsByID = Dictionary(
                uniqueKeysWithValues: response.stations.map { ($0.id.rawValue, $0) }
            )
            let songs = response.songs.map { song in
                AppleMusicCatalogItem(
                    id: "song:\(song.id.rawValue)",
                    musicItemID: song.id.rawValue,
                    kind: .song,
                    title: song.title,
                    subtitle: song.artistName,
                    detail: song.albumTitle ?? "",
                    artworkURL: song.artwork?.url(width: 180, height: 180),
                    destinationURL: song.url
                )
            }
            let albums = response.albums.map { album in
                AppleMusicCatalogItem(
                    id: "album:\(album.id.rawValue)",
                    musicItemID: album.id.rawValue,
                    kind: .album,
                    title: album.title,
                    subtitle: album.artistName,
                    detail: L10n.format("appleMusic.album.trackCount", album.trackCount),
                    artworkURL: album.artwork?.url(width: 180, height: 180),
                    destinationURL: album.url
                )
            }
            let artists = response.artists.map { artist in
                AppleMusicCatalogItem(
                    id: "artist:\(artist.id.rawValue)",
                    musicItemID: artist.id.rawValue,
                    kind: .artist,
                    title: artist.name,
                    subtitle: artist.genreNames?.first ?? "",
                    detail: "",
                    artworkURL: artist.artwork?.url(width: 180, height: 180),
                    destinationURL: artist.url
                )
            }
            let playlists = response.playlists.map { playlist in
                AppleMusicCatalogItem(
                    id: "playlist:\(playlist.id.rawValue)",
                    musicItemID: playlist.id.rawValue,
                    kind: .playlist,
                    title: playlist.name,
                    subtitle: playlist.curatorName ?? "Apple Music",
                    detail: playlist.shortDescription ?? "",
                    artworkURL: playlist.artwork?.url(width: 180, height: 180),
                    destinationURL: playlist.url
                )
            }
            let musicVideos = response.musicVideos.map { musicVideo in
                AppleMusicCatalogItem(
                    id: "musicVideo:\(musicVideo.id.rawValue)",
                    musicItemID: musicVideo.id.rawValue,
                    kind: .musicVideo,
                    title: musicVideo.title,
                    subtitle: musicVideo.artistName,
                    detail: musicVideo.albumTitle ?? "",
                    artworkURL: musicVideo.artwork?.url(width: 180, height: 180),
                    destinationURL: musicVideo.url
                )
            }
            let stations = response.stations.map { station in
                AppleMusicCatalogItem(
                    id: "station:\(station.id.rawValue)",
                    musicItemID: station.id.rawValue,
                    kind: .station,
                    title: station.name,
                    subtitle: station.stationProviderName ?? "Apple Music",
                    detail: station.isLive ? L10n.text("appleMusic.station.live") : "",
                    artworkURL: station.artwork?.url(width: 180, height: 180),
                    destinationURL: station.url
                )
            }
            catalogItems = songs + albums + playlists + musicVideos + stations + artists
            await refreshFavoriteRatings(for: catalogItems)
            if catalogItems.isEmpty {
                message = L10n.text("appleMusic.search.noResults")
            }
        } catch {
            message = Self.localizedServiceError(error)
        }
        isWorking = false
    }

    func searchUnified(_ rawTerm: String) async {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = UUID()
        unifiedSearchGeneration = generation
        guard !term.isEmpty else {
            unifiedCatalogItems = []
            unifiedLibraryItems = []
            unifiedSearchMessage = nil
            isUnifiedSearchWorking = false
            return
        }
        guard authorization == .authorized else {
            unifiedCatalogItems = []
            unifiedLibraryItems = []
            unifiedSearchMessage = L10n.text("appleMusic.search.authorizationRequired")
            return
        }

        isUnifiedSearchWorking = true
        unifiedSearchMessage = nil
        var catalogResults: [AppleMusicCatalogItem] = []
        var libraryResults: [AppleMusicCatalogItem] = []
        var errors: [String] = []

        do {
            var request = MusicCatalogSearchRequest(
                term: term,
                types: [Song.self, Album.self, Artist.self, MusicKit.Playlist.self]
            )
            request.limit = 12
            request.includeTopResults = true
            let response = try await request.response()
            guard unifiedSearchGeneration == generation else { return }
            songsByID.merge(
                Dictionary(uniqueKeysWithValues: response.songs.map { ($0.id.rawValue, $0) })
            ) { _, new in new }
            albumsByID.merge(
                Dictionary(uniqueKeysWithValues: response.albums.map { ($0.id.rawValue, $0) })
            ) { _, new in new }
            playlistsByID.merge(
                Dictionary(uniqueKeysWithValues: response.playlists.map {
                    ($0.id.rawValue, $0)
                })
            ) { _, new in new }
            let songs = response.songs.map(Self.catalogSongItem)
            let albums = response.albums.map(Self.catalogAlbumItem)
            let playlists = response.playlists.map(Self.catalogPlaylistItem)
            let artists = response.artists.map(Self.catalogArtistItem)
            catalogResults = songs + albums + playlists + artists
        } catch {
            errors.append(Self.localizedServiceError(error))
        }

        if hasCloudLibraryEnabled {
            do {
                var request = MusicLibrarySearchRequest(
                    term: term,
                    types: [Song.self, Album.self, MusicKit.Playlist.self]
                )
                request.limit = 12
                request.includeTopResults = true
                let response = try await request.response()
                guard unifiedSearchGeneration == generation else { return }
                songsByID.merge(
                    Dictionary(uniqueKeysWithValues: response.songs.map {
                        ($0.id.rawValue, $0)
                    })
                ) { _, new in new }
                albumsByID.merge(
                    Dictionary(uniqueKeysWithValues: response.albums.map {
                        ($0.id.rawValue, $0)
                    })
                ) { _, new in new }
                playlistsByID.merge(
                    Dictionary(uniqueKeysWithValues: response.playlists.map {
                        ($0.id.rawValue, $0)
                    })
                ) { _, new in new }
                libraryResults = response.songs.map(Self.librarySongItem)
                    + response.albums.map(Self.libraryAlbumItem)
                    + response.playlists.map(Self.libraryPlaylistItem)
            } catch {
                errors.append(Self.localizedServiceError(error))
            }
        }

        guard unifiedSearchGeneration == generation else { return }
        unifiedCatalogItems = catalogResults
        unifiedLibraryItems = libraryResults
        await refreshFavoriteRatings(for: catalogResults + libraryResults)
        if catalogResults.isEmpty && libraryResults.isEmpty {
            unifiedSearchMessage = errors.first ?? L10n.text("appleMusic.search.noResults")
        } else if !errors.isEmpty {
            unifiedSearchMessage = errors.joined(separator: " ")
        }
        isUnifiedSearchWorking = false
    }

    func loadAppleMusicCharts() async {
        guard authorization == .authorized else {
            message = L10n.text("appleMusic.search.authorizationRequired")
            return
        }
        isWorking = true
        message = nil
        do {
            var request = MusicCatalogChartsRequest(
                kinds: [.mostPlayed, .dailyGlobalTop],
                types: [Song.self, Album.self, MusicKit.Playlist.self, MusicVideo.self]
            )
            request.limit = 10
            let response = try await request.response()

            songsByID = Dictionary(response.songCharts
                .flatMap(\.items)
                .map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
            albumsByID = Dictionary(response.albumCharts
                .flatMap(\.items)
                .map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
            playlistsByID = Dictionary(response.playlistCharts
                .flatMap(\.items)
                .map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })

            var seenIDs = Set<String>()
            let songs = response.songCharts.flatMap { chart in
                chart.items.enumerated().map { rank, song in
                    AppleMusicCatalogItem(
                        id: "song:\(song.id.rawValue)",
                        musicItemID: song.id.rawValue,
                        kind: .song,
                        title: song.title,
                        subtitle: song.artistName,
                        detail: Self.chartDetail(chart.title, rank: rank + 1),
                        artworkURL: song.artwork?.url(width: 180, height: 180),
                        destinationURL: song.url
                    )
                }
            }
            let albums = response.albumCharts.flatMap { chart in
                chart.items.enumerated().map { rank, album in
                    AppleMusicCatalogItem(
                        id: "album:\(album.id.rawValue)",
                        musicItemID: album.id.rawValue,
                        kind: .album,
                        title: album.title,
                        subtitle: album.artistName,
                        detail: Self.chartDetail(chart.title, rank: rank + 1),
                        artworkURL: album.artwork?.url(width: 180, height: 180),
                        destinationURL: album.url
                    )
                }
            }
            let playlists = response.playlistCharts.flatMap { chart in
                chart.items.enumerated().map { rank, playlist in
                    AppleMusicCatalogItem(
                        id: "playlist:\(playlist.id.rawValue)",
                        musicItemID: playlist.id.rawValue,
                        kind: .playlist,
                        title: playlist.name,
                        subtitle: playlist.curatorName ?? "Apple Music",
                        detail: Self.chartDetail(chart.title, rank: rank + 1),
                        artworkURL: playlist.artwork?.url(width: 180, height: 180),
                        destinationURL: playlist.url
                    )
                }
            }
            let musicVideos = response.musicVideoCharts.flatMap { chart in
                chart.items.enumerated().map { rank, musicVideo in
                    AppleMusicCatalogItem(
                        id: "musicVideo:\(musicVideo.id.rawValue)",
                        musicItemID: musicVideo.id.rawValue,
                        kind: .musicVideo,
                        title: musicVideo.title,
                        subtitle: musicVideo.artistName,
                        detail: Self.chartDetail(chart.title, rank: rank + 1),
                        artworkURL: musicVideo.artwork?.url(width: 180, height: 180),
                        destinationURL: musicVideo.url
                    )
                }
            }
            catalogItems = (songs + albums + playlists + musicVideos).filter {
                seenIDs.insert($0.id).inserted
            }
            await refreshFavoriteRatings(for: catalogItems)
            message = catalogItems.isEmpty
                ? L10n.text("appleMusic.search.noResults")
                : L10n.format("appleMusic.charts.loaded", catalogItems.count)
        } catch {
            message = Self.localizedServiceError(error)
        }
        isWorking = false
    }

    func searchITunesStore(_ rawTerm: String) async {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isWorking = true
        message = nil
        do {
            let region = Locale.current.region?.identifier ?? "JP"
            storeItems = try await storeClient.search(term: term, countryCode: region)
            if storeItems.isEmpty {
                message = L10n.text("appleMusic.search.noResults")
            }
        } catch {
            message = Self.localizedServiceError(error)
        }
        isWorking = false
    }

    func addSongToLibrary(_ item: AppleMusicCatalogItem) async {
        guard item.kind == .song, songsByID[item.musicItemID] != nil else { return }
        guard hasCloudLibraryEnabled else {
            message = L10n.text("appleMusic.library.cloudRequired")
            return
        }
        isWorking = true
        message = nil
        do {
            var components = URLComponents(string: "https://api.music.apple.com/v1/me/library")
            components?.queryItems = [
                URLQueryItem(name: "ids[songs]", value: item.musicItemID),
            ]
            guard let url = components?.url else { throw URLError(.badURL) }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            let response = try await MusicDataRequest(urlRequest: urlRequest).response()
            try Self.validateStatus(
                response.urlResponse.statusCode,
                accepted: Set(200..<300)
            )
            addedSongIDs.insert(item.musicItemID)
            message = L10n.format("appleMusic.library.added", item.title)
        } catch {
            message = Self.localizedServiceError(error)
        }
        isWorking = false
    }

    func playCatalogItem(
        _ item: AppleMusicCatalogItem,
        with playback: AppleMusicPlaybackController,
        localPlayer: PlaybackController
    ) async {
        guard canPlayCatalogContent else {
            message = L10n.text("appleMusic.playback.unavailable")
            return
        }

        let queue: ApplicationMusicPlayer.Queue?
        switch item.kind {
        case .song:
            queue = songsByID[item.musicItemID].map {
                ApplicationMusicPlayer.Queue(for: [$0])
            }
        case .album:
            queue = albumsByID[item.musicItemID].map {
                ApplicationMusicPlayer.Queue(for: [$0])
            }
        case .playlist:
            queue = playlistsByID[item.musicItemID].map {
                ApplicationMusicPlayer.Queue(for: [$0])
            }
        case .station:
            queue = stationsByID[item.musicItemID].map {
                ApplicationMusicPlayer.Queue(for: [$0])
            }
        case .artist, .musicVideo:
            queue = nil
        }
        guard let queue else { return }

        await playback.play(item: item, queue: queue) {
            localPlayer.pauseForExternalPlayback()
        }
        if let errorMessage = playback.errorMessage {
            message = errorMessage
        } else {
            message = L10n.format("appleMusic.playback.started", item.title)
        }
    }

    func enqueueCatalogItem(
        _ item: AppleMusicCatalogItem,
        position: MusicPlayer.Queue.EntryInsertionPosition,
        with playback: AppleMusicPlaybackController
    ) async {
        guard playback.currentItem != nil else { return }
        switch item.kind {
        case .song:
            if let song = songsByID[item.musicItemID] {
                await playback.insert(song, position: position)
            }
        case .album:
            if let album = albumsByID[item.musicItemID] {
                await playback.insert(album, position: position)
            }
        case .playlist:
            if let playlist = playlistsByID[item.musicItemID] {
                await playback.insert(playlist, position: position)
            }
        case .artist, .musicVideo, .station:
            return
        }

        if let errorMessage = playback.errorMessage {
            message = errorMessage
        } else {
            let key = position == .afterCurrentEntry
                ? "appleMusic.queue.addedNext" : "appleMusic.queue.addedLater"
            message = L10n.format(key, item.title)
        }
    }

    func loadLibraryPlaylists() async {
        guard authorization == .authorized, hasCloudLibraryEnabled else {
            libraryPlaylists = []
            return
        }
        do {
            var request = MusicLibraryRequest<MusicKit.Playlist>()
            request.limit = 100
            request.sort(by: \.name, ascending: true)
            let response = try await request.response()
            playlistsByID = Dictionary(uniqueKeysWithValues: response.items.map {
                ($0.id.rawValue, $0)
            })
            libraryPlaylists = response.items.map(Self.libraryPlaylistItem)
        } catch {
            libraryPlaylists = []
            message = Self.localizedServiceError(error)
        }
    }

    private func refreshAuthorizationState() {
        authorization = Self.authorizationState(MusicAuthorization.currentStatus)
    }

    private func refreshSubscription() async {
        do {
            let subscription = try await MusicSubscription.current
            canPlayCatalogContent = subscription.canPlayCatalogContent
            canBecomeSubscriber = subscription.canBecomeSubscriber
            hasCloudLibraryEnabled = subscription.hasCloudLibraryEnabled
        } catch {
            canPlayCatalogContent = false
            hasCloudLibraryEnabled = false
            message = Self.localizedServiceError(error)
        }
    }

    private static func authorizationState(
        _ status: MusicAuthorization.Status
    ) -> AuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .restricted
        }
    }

    private static func localizedServiceError(_ error: Error) -> String {
        if let serviceError = error as? AppleMusicServiceError {
            return L10n.text(serviceError.localizationKey)
        }
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return L10n.text("appleMusic.error.offline")
        }
        return error.localizedDescription
    }

    private func refreshFavoriteRatings(for items: [AppleMusicCatalogItem]) async {
        let groupedItems = Dictionary(grouping: items) { $0.ratingResourceType }
        for (resourceType, typedItems) in groupedItems {
            guard let resourceType else { continue }
            for chunk in typedItems.chunked(into: 100) {
                var components = URLComponents(
                    string: "https://api.music.apple.com/v1/me/ratings/\(resourceType)"
                )
                components?.queryItems = [
                    URLQueryItem(
                        name: "ids",
                        value: chunk.map(\.musicItemID).joined(separator: ",")
                    ),
                ]
                guard let url = components?.url else { continue }
                do {
                    let response = try await MusicDataRequest(urlRequest: URLRequest(url: url))
                        .response()
                    try Self.validateStatus(response.urlResponse.statusCode, accepted: [200])
                    let ratings = try JSONDecoder().decode(
                        AppleMusicRatingsResponse.self,
                        from: response.data
                    )
                    let likedIDs = Set(ratings.data.filter { $0.attributes.value == 1 }.map(\.id))
                    for item in chunk {
                        guard let key = Self.favoriteKey(item) else { continue }
                        if likedIDs.contains(item.musicItemID) {
                            favoriteResourceKeys.insert(key)
                        } else {
                            favoriteResourceKeys.remove(key)
                        }
                    }
                } catch {
                    message = Self.localizedServiceError(error)
                }
            }
        }
    }

    private static func favoriteKey(_ item: AppleMusicCatalogItem) -> String? {
        item.ratingResourceType.map { "\($0):\(item.musicItemID)" }
    }

    private func rebuildLibraryCatalog() {
        catalogItems = (librarySongItems + libraryAlbumItems + libraryPlaylistItems)
            .filter { libraryFilter.includes($0.kind) }
    }

    private static func catalogSongItem(_ song: Song) -> AppleMusicCatalogItem {
        AppleMusicCatalogItem(
            id: "song:\(song.id.rawValue)",
            musicItemID: song.id.rawValue,
            kind: .song,
            title: song.title,
            subtitle: song.artistName,
            detail: song.albumTitle ?? "",
            artworkURL: song.artwork?.url(width: 180, height: 180),
            destinationURL: song.url
        )
    }

    private static func catalogAlbumItem(_ album: Album) -> AppleMusicCatalogItem {
        AppleMusicCatalogItem(
            id: "album:\(album.id.rawValue)",
            musicItemID: album.id.rawValue,
            kind: .album,
            title: album.title,
            subtitle: album.artistName,
            detail: L10n.format("appleMusic.album.trackCount", album.trackCount),
            artworkURL: album.artwork?.url(width: 180, height: 180),
            destinationURL: album.url
        )
    }

    private static func catalogPlaylistItem(
        _ playlist: MusicKit.Playlist
    ) -> AppleMusicCatalogItem {
        AppleMusicCatalogItem(
            id: "playlist:\(playlist.id.rawValue)",
            musicItemID: playlist.id.rawValue,
            kind: .playlist,
            title: playlist.name,
            subtitle: playlist.curatorName ?? "Apple Music",
            detail: playlist.shortDescription ?? "",
            artworkURL: playlist.artwork?.url(width: 180, height: 180),
            destinationURL: playlist.url
        )
    }

    private static func catalogArtistItem(_ artist: Artist) -> AppleMusicCatalogItem {
        AppleMusicCatalogItem(
            id: "artist:\(artist.id.rawValue)",
            musicItemID: artist.id.rawValue,
            kind: .artist,
            title: artist.name,
            subtitle: artist.genreNames?.first ?? "",
            detail: "",
            artworkURL: artist.artwork?.url(width: 180, height: 180),
            destinationURL: artist.url
        )
    }

    private static func librarySongItem(_ song: Song) -> AppleMusicCatalogItem {
        AppleMusicCatalogItem(
            id: "librarySong:\(song.id.rawValue)",
            musicItemID: song.id.rawValue,
            kind: .song,
            title: song.title,
            subtitle: song.artistName,
            detail: song.albumTitle ?? "",
            artworkURL: song.artwork?.url(width: 180, height: 180),
            destinationURL: song.url,
            playlistTrackType: "library-songs",
            ratingResourceType: "library-songs"
        )
    }

    private static func libraryAlbumItem(_ album: Album) -> AppleMusicCatalogItem {
        AppleMusicCatalogItem(
            id: "libraryAlbum:\(album.id.rawValue)",
            musicItemID: album.id.rawValue,
            kind: .album,
            title: album.title,
            subtitle: album.artistName,
            detail: L10n.format("appleMusic.album.trackCount", album.trackCount),
            artworkURL: album.artwork?.url(width: 180, height: 180),
            destinationURL: album.url,
            ratingResourceType: "library-albums"
        )
    }

    private static func libraryPlaylistItem(_ playlist: MusicKit.Playlist) -> AppleMusicCatalogItem {
        AppleMusicCatalogItem(
            id: "libraryPlaylist:\(playlist.id.rawValue)",
            musicItemID: playlist.id.rawValue,
            kind: .playlist,
            title: playlist.name,
            subtitle: playlist.curatorName ?? L10n.text("appleMusic.library.personal"),
            detail: playlist.shortDescription ?? "",
            artworkURL: playlist.artwork?.url(width: 180, height: 180),
            destinationURL: playlist.url,
            ratingResourceType: "library-playlists"
        )
    }

    nonisolated static func merging(
        _ existing: [AppleMusicCatalogItem],
        with newItems: [AppleMusicCatalogItem]
    ) -> [AppleMusicCatalogItem] {
        var seen = Set(existing.map(\.id))
        return existing + newItems.filter { seen.insert($0.id).inserted }
    }

    nonisolated static func validateStatus(
        _ statusCode: Int,
        accepted: Set<Int>
    ) throws {
        guard !accepted.contains(statusCode) else { return }
        switch statusCode {
        case 401: throw AppleMusicServiceError.unauthorized
        case 403, 404: throw AppleMusicServiceError.unavailable
        case 409, 412: throw AppleMusicServiceError.conflict
        case 429: throw AppleMusicServiceError.rateLimited
        default: throw AppleMusicServiceError.server
        }
    }

    nonisolated static func chartDetail(_ title: String, rank: Int) -> String {
        "\(title) · #\(rank)"
    }

    nonisolated static func playlistCreationBody(
        name: String,
        description: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "attributes": [
                "name": name,
                "description": description,
                "isPublic": false,
            ],
        ])
    }

    nonisolated static func playlistTracksBody(id: String, type: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "data": [["id": id, "type": type]],
        ])
    }

    nonisolated static func favoriteRatingBody() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "rating",
            "attributes": ["value": 1],
        ])
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

struct AppleMusicStoreView: View {
    private enum Source: String, CaseIterable, Identifiable {
        case appleMusic
        case library
        case iTunesStore

        var id: String { rawValue }
        var localizationKey: String { "appleMusic.source.\(rawValue)" }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localPlayer: PlaybackController
    @EnvironmentObject private var appleMusicPlayback: AppleMusicPlaybackController
    @EnvironmentObject private var controller: AppleMusicStoreController
    @State private var source: Source = .appleMusic
    @State private var query = ""
    @State private var isCreatingPlaylist = false
    @State private var playlistName = ""
    @State private var playlistDescription = ""
    @State private var libraryQuery = ""
    @State private var libraryFilter: AppleMusicLibraryFilter = .all
    @State private var isShowingPlaylistContents = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if source != .iTunesStore && controller.authorization != .authorized {
                authorizationView
            } else if source == .library {
                libraryContent
            } else {
                searchContent
            }
            Divider()
            footer
        }
        .frame(width: 900, height: 650)
        .background(AppTheme.canvas)
        .task { await controller.refresh() }
        .onChange(of: source) { _, newSource in
            if newSource == .library {
                Task { await controller.loadLibrary() }
            }
        }
        .sheet(isPresented: $isCreatingPlaylist) {
            createPlaylistSheet
        }
        .sheet(isPresented: $isShowingPlaylistContents) {
            playlistContentsSheet
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("appleMusic.store.title"))
                    .font(.headline)
                Text(L10n.text("appleMusic.store.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $source) {
                ForEach(Source.allCases) { source in
                    Text(L10n.text(source.localizationKey)).tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 390)
        }
        .padding(20)
    }

    private var authorizationView: some View {
        ContentUnavailableView {
            Label(
                L10n.text("appleMusic.authorization.title"),
                systemImage: "person.crop.circle.badge.checkmark"
            )
        } description: {
            VStack(spacing: 8) {
                Text(L10n.text("appleMusic.authorization.message"))
                Text(L10n.text(controller.authorization.localizationKey))
                    .font(.caption.weight(.semibold))
            }
        } actions: {
            if controller.authorization == .notDetermined {
                Button(L10n.text("appleMusic.authorization.action")) {
                    Task { await controller.requestAccess() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(L10n.text("appleMusic.authorization.settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L10n.text("appleMusic.search.prompt"), text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { search() }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Button(L10n.text("appleMusic.search.action"), action: search)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if source == .appleMusic {
                    Button {
                        Task { await controller.loadAppleMusicCharts() }
                    } label: {
                        Label(L10n.text("appleMusic.charts.action"), systemImage: "chart.bar.xaxis")
                    }
                    .help(L10n.text("appleMusic.charts.help"))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .padding(20)

            statusStrip

            if controller.isWorking {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if source == .appleMusic {
                catalogResults
            } else {
                storeResults
            }
        }
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("appleMusic.library.title"))
                        .font(.headline)
                    Text(L10n.text("appleMusic.library.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await controller.loadLibrary() }
                } label: {
                    Label(L10n.text("appleMusic.library.refresh"), systemImage: "arrow.clockwise")
                }
                Button {
                    playlistName = ""
                    playlistDescription = ""
                    isCreatingPlaylist = true
                } label: {
                    Label(L10n.text("appleMusic.library.newPlaylist"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.hasCloudLibraryEnabled)
            }
            .padding(20)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L10n.text("appleMusic.library.searchPrompt"), text: $libraryQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { searchLibrary() }
                if !libraryQuery.isEmpty {
                    Button {
                        libraryQuery = ""
                        controller.setLibraryFilter(libraryFilter)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Picker("", selection: $libraryFilter) {
                    ForEach(AppleMusicLibraryFilter.allCases) { filter in
                        Text(L10n.text(filter.localizationKey)).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: libraryFilter) { _, filter in
                    if libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        controller.setLibraryFilter(filter)
                    } else {
                        searchLibrary()
                    }
                }
                Button(L10n.text("appleMusic.search.action"), action: searchLibrary)
                    .disabled(
                        libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            statusStrip

            if controller.isWorking {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    catalogResults
                    if controller.hasMoreLibraryItems {
                        Divider()
                        Button {
                            Task { await controller.loadMoreLibrary() }
                        } label: {
                            Label(
                                L10n.text("appleMusic.library.loadMore"),
                                systemImage: "chevron.down.circle"
                            )
                        }
                        .buttonStyle(.borderless)
                        .padding(12)
                    }
                }
            }
        }
    }

    private var createPlaylistSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("appleMusic.library.newPlaylist"))
                .font(.title2.weight(.semibold))
            Form {
                TextField(L10n.text("appleMusic.library.playlistName"), text: $playlistName)
                TextField(
                    L10n.text("appleMusic.library.playlistDescription"),
                    text: $playlistDescription,
                    axis: .vertical
                )
                .lineLimit(2...4)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) {
                    isCreatingPlaylist = false
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.text("common.create")) {
                    Task {
                        if await controller.createLibraryPlaylist(
                            name: playlistName,
                            description: playlistDescription
                        ) {
                            isCreatingPlaylist = false
                            await controller.loadLibrary()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || controller.isWorking
                )
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var playlistContentsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.playlistContentsTitle)
                        .font(.title2.weight(.semibold))
                    Text(L10n.format(
                        "appleMusic.library.playlistTrackCount",
                        controller.playlistEntries.count
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("common.close")) {
                    isShowingPlaylistContents = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            if controller.isWorking {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.playlistEntries) { item in
                    catalogRow(item)
                }
                .overlay {
                    if controller.playlistEntries.isEmpty {
                        ContentUnavailableView(
                            L10n.text("appleMusic.library.playlistEmpty"),
                            systemImage: "music.note.list"
                        )
                    }
                }
            }
        }
        .frame(width: 760, height: 560)
        .background(AppTheme.canvas)
    }

    @ViewBuilder
    private var statusStrip: some View {
        if source != .iTunesStore {
            HStack(spacing: 8) {
                capabilityBadge(
                    controller.canPlayCatalogContent,
                    key: "appleMusic.capability.playback"
                )
                capabilityBadge(
                    controller.hasCloudLibraryEnabled,
                    key: "appleMusic.capability.cloudLibrary"
                )
                if controller.canBecomeSubscriber {
                    Text(L10n.text("appleMusic.capability.subscriptionAvailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(L10n.text("appleMusic.subscription.action")) {
                        NSWorkspace.shared.open(AppleMusicStoreController.subscriptionURL)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }

    private var catalogResults: some View {
        List(controller.catalogItems) { item in
            catalogRow(item)
        }
        .overlay {
            if controller.catalogItems.isEmpty {
                emptySearchState
            }
        }
    }

    private var storeResults: some View {
        List(controller.storeItems) { item in
            HStack(spacing: 12) {
                artwork(item.artworkUrl100)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.trackName).fontWeight(.medium).lineLimit(1)
                    Text(item.artistName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if let album = item.collectionName {
                        Text(album).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer()
                if let price = priceText(item) {
                    Text(price).font(.callout.monospacedDigit())
                }
                Button(L10n.text("appleMusic.store.open")) {
                    if let url = item.trackViewUrl { NSWorkspace.shared.open(url) }
                }
                .disabled(item.trackViewUrl == nil)
            }
            .padding(.vertical, 5)
        }
        .overlay {
            if controller.storeItems.isEmpty {
                emptySearchState
            }
        }
    }

    private func catalogRow(_ item: AppleMusicCatalogItem) -> some View {
        HStack(spacing: 12) {
            artwork(item.artworkURL)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.medium).lineLimit(1)
                    Text(L10n.text(item.kind.localizationKey))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(item.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if item.kind.isPlayable {
                Button {
                    if appleMusicPlayback.isCurrent(item), appleMusicPlayback.isPlaying {
                        appleMusicPlayback.pause()
                    } else if appleMusicPlayback.isCurrent(item) {
                        Task { await appleMusicPlayback.resume() }
                    } else {
                        Task {
                            await controller.playCatalogItem(
                                item,
                                with: appleMusicPlayback,
                                localPlayer: localPlayer
                            )
                        }
                    }
                } label: {
                    if appleMusicPlayback.isCurrent(item), appleMusicPlayback.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: appleMusicPlayback.isCurrent(item)
                            && appleMusicPlayback.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .help(L10n.text(
                    appleMusicPlayback.isCurrent(item) && appleMusicPlayback.isPlaying
                        ? "appleMusic.playback.pause" : "appleMusic.playback.play"
                ))
                .accessibilityLabel(L10n.text(
                    appleMusicPlayback.isCurrent(item) && appleMusicPlayback.isPlaying
                        ? "appleMusic.playback.pause" : "appleMusic.playback.play"
                ))
                .disabled(!controller.canPlayCatalogContent || appleMusicPlayback.isWorking)

                if item.kind.canEnqueue {
                    Menu {
                        Button(L10n.text("player.queue.playNext")) {
                            Task {
                                await controller.enqueueCatalogItem(
                                    item,
                                    position: .afterCurrentEntry,
                                    with: appleMusicPlayback
                                )
                            }
                        }
                        Button(L10n.text("player.queue.playLater")) {
                            Task {
                                await controller.enqueueCatalogItem(
                                    item,
                                    position: .tail,
                                    with: appleMusicPlayback
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .help(L10n.text("appleMusic.queue.actions"))
                    .disabled(appleMusicPlayback.currentItem == nil || appleMusicPlayback.isWorking)
                }
            }
            if source == .appleMusic, item.kind == .song {
                Button {
                    Task { await controller.addSongToLibrary(item) }
                } label: {
                    Image(systemName: controller.addedSongIDs.contains(item.musicItemID)
                        ? "checkmark" : "plus")
                }
                .help(L10n.text("appleMusic.library.add"))
                .disabled(
                    !controller.hasCloudLibraryEnabled
                        || controller.addedSongIDs.contains(item.musicItemID)
                )
            }
            if source != .iTunesStore,
               item.kind == .song,
               !controller.libraryPlaylists.isEmpty {
                Menu {
                    ForEach(controller.libraryPlaylists) { playlist in
                        Button(playlist.title) {
                            Task { await controller.addSong(item, to: playlist) }
                        }
                    }
                } label: {
                    Image(systemName: "text.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .help(L10n.text("appleMusic.library.addToPlaylist"))
                .disabled(controller.isWorking)
            }
            if source != .iTunesStore, item.ratingResourceType != nil {
                Button {
                    Task { await controller.toggleFavorite(item) }
                } label: {
                    Image(systemName: controller.isFavorite(item) ? "heart.fill" : "heart")
                        .foregroundStyle(controller.isFavorite(item) ? Color.red : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.text(
                    controller.isFavorite(item)
                        ? "appleMusic.favorite.remove" : "appleMusic.favorite.add"
                ))
                .accessibilityLabel(L10n.text(
                    controller.isFavorite(item)
                        ? "appleMusic.favorite.remove" : "appleMusic.favorite.add"
                ))
                .disabled(controller.isWorking)
            }
            if source == .library, item.kind == .playlist {
                Button {
                    isShowingPlaylistContents = true
                    Task { await controller.loadPlaylistContents(item) }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("appleMusic.library.viewPlaylist"))
                .accessibilityLabel(L10n.text("appleMusic.library.viewPlaylist"))
            }
            Button(L10n.text("appleMusic.open")) {
                if let url = item.destinationURL { NSWorkspace.shared.open(url) }
            }
            .disabled(item.destinationURL == nil)
        }
        .padding(.vertical, 5)
    }

    private var emptySearchState: some View {
        ContentUnavailableView {
            Label(L10n.text("appleMusic.search.empty"), systemImage: "magnifyingglass")
        } description: {
            Text(controller.message ?? L10n.text("appleMusic.search.emptyMessage"))
        }
    }

    private var footer: some View {
        HStack {
            if let message = appleMusicPlayback.errorMessage ?? controller.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(L10n.text("appleMusic.store.attribution"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button(L10n.text("common.close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func artwork(_ url: URL?) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.raised)
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func capabilityBadge(_ enabled: Bool, key: String) -> some View {
        Label(L10n.text(key), systemImage: enabled ? "checkmark.circle.fill" : "xmark.circle")
            .font(.caption)
            .foregroundStyle(enabled ? Color.green : Color.secondary)
    }

    private func search() {
        if source == .appleMusic {
            Task { await controller.searchAppleMusic(query) }
        } else {
            Task { await controller.searchITunesStore(query) }
        }
    }

    private func searchLibrary() {
        Task { await controller.searchLibrary(libraryQuery, filter: libraryFilter) }
    }

    private func priceText(_ item: ITunesStoreItem) -> String? {
        guard let price = item.trackPrice, let currency = item.currency else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: price))
    }
}
