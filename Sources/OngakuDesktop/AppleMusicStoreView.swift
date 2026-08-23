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

enum AppleMusicChartScope: String, CaseIterable, Identifiable, Sendable {
    case cities
    case genres

    var id: String { rawValue }
    var localizationKey: String { "appleMusic.charts.scope.\(rawValue)" }
}

struct AppleMusicGenreOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct AppleMusicCatalogItem: Identifiable, Equatable, Sendable {
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
    let groupTitle: String?

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
        ratingResourceType: String? = nil,
        groupTitle: String? = nil
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
        self.groupTitle = groupTitle
    }
}

struct AppleMusicDiscoveryShelf: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let items: [AppleMusicCatalogItem]
}

enum AppleMusicDiscoveryPlanner {
    static func recentReleaseIDs(
        _ candidates: [(id: String, releaseDate: Date?)],
        since cutoff: Date,
        through latestDate: Date,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        return candidates
            .compactMap { candidate -> (id: String, date: Date)? in
                guard let date = candidate.releaseDate,
                      date >= cutoff,
                      date <= latestDate else { return nil }
                return (candidate.id, date)
            }
            .sorted { $0.date > $1.date }
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map(\.id)
    }

    static func mergingShelves(
        _ existing: [AppleMusicDiscoveryShelf],
        with incoming: [AppleMusicDiscoveryShelf],
        replacingAll: Bool
    ) -> [AppleMusicDiscoveryShelf] {
        guard !replacingAll else { return incoming }
        var result = existing
        for shelf in incoming {
            if let index = result.firstIndex(where: { $0.id == shelf.id }) {
                result[index] = shelf
            } else {
                result.append(shelf)
            }
        }
        return result
    }

    static func chartGroupTitles(in items: [AppleMusicCatalogItem]) -> [String] {
        Array(Set(items.compactMap(\.groupTitle)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func filteringChartItems(
        _ items: [AppleMusicCatalogItem],
        groupTitle: String?
    ) -> [AppleMusicCatalogItem] {
        items.filter { groupTitle == nil || $0.groupTitle == groupTitle }
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

    private enum RetryOperation {
        case discovery
        case moreRecommendations
        case discoveryDetails(AppleMusicCatalogItem)
        case discoveryCharts(AppleMusicChartScope, String?, Bool)
        case loadLibrary(reset: Bool)
        case searchLibrary(String, AppleMusicLibraryFilter)
        case playlistContents(AppleMusicCatalogItem)
        case catalogSearch(String)
        case unifiedSearch(String)
        case charts
        case storeSearch(String)
    }

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
    @Published private(set) var canRetry = false
    @Published private(set) var recommendationShelves: [AppleMusicDiscoveryShelf] = []
    @Published private(set) var recentlyPlayedItems: [AppleMusicCatalogItem] = []
    @Published private(set) var newReleaseItems: [AppleMusicCatalogItem] = []
    @Published private(set) var hasMoreRecommendations = false
    @Published private(set) var isLoadingMoreRecommendations = false
    @Published private(set) var discoveryDetailItems: [AppleMusicCatalogItem] = []
    @Published private(set) var discoveryDetailTitle = ""
    @Published private(set) var discoveryDetailSubtitle = ""
    @Published private(set) var isDiscoveryDetailWorking = false
    @Published private(set) var discoveryRelatedItems: [AppleMusicCatalogItem] = []
    @Published private(set) var chartGenres: [AppleMusicGenreOption] = []
    @Published private(set) var discoveryChartItems: [AppleMusicCatalogItem] = []
    @Published private(set) var discoveryChartTitle = ""
    @Published private(set) var chartCityNames: [String] = []
    @Published private(set) var hasMoreDiscoveryChartItems = false
    @Published private(set) var isLoadingMoreDiscoveryCharts = false

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
    private var retryOperation: RetryOperation?
    private var recommendationOffset = 0
    private let recommendationPageSize = 10
    private var genresByID: [String: Genre] = [:]
    private var allDiscoveryChartItems: [AppleMusicCatalogItem] = []
    private var selectedChartCityName: String?
    private var discoveryChartOffset = 0
    private let discoveryChartPageSize = 12

    nonisolated static let replayURL = URL(string: "https://replay.music.apple.com/")!

    init(storeClient: ITunesStoreClient = ITunesStoreClient()) {
        self.storeClient = storeClient
        refreshAuthorizationState()
    }

    func retryLastOperation() async {
        guard let retryOperation, !isWorking, !isUnifiedSearchWorking else { return }
        canRetry = false
        switch retryOperation {
        case .discovery:
            await loadDiscovery()
        case .moreRecommendations:
            await loadMoreRecommendations()
        case .discoveryDetails(let item):
            await loadDiscoveryDetails(item)
        case .discoveryCharts(let scope, let genreID, let reset):
            await loadDiscoveryCharts(scope: scope, genreID: genreID, reset: reset)
        case .loadLibrary(let reset):
            await loadLibrary(reset: reset)
        case .searchLibrary(let term, let filter):
            await searchLibrary(term, filter: filter)
        case .playlistContents(let item):
            await loadPlaylistContents(item)
        case .catalogSearch(let term):
            await searchAppleMusic(term)
        case .unifiedSearch(let term):
            await searchUnified(term)
        case .charts:
            await loadAppleMusicCharts()
        case .storeSearch(let term):
            await searchITunesStore(term)
        }
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

    func loadDiscovery() async {
        guard authorization == .authorized else {
            message = L10n.text("appleMusic.search.authorizationRequired")
            return
        }
        beginRetryableOperation(.discovery)
        isWorking = true
        message = nil
        defer { isWorking = false }

        var shelves: [AppleMusicDiscoveryShelf] = []
        var recentItems: [AppleMusicCatalogItem] = []
        var releaseAlbums: [Album] = []
        var errors: [String] = []
        var recommendationCount = 0

        do {
            var request = MusicPersonalRecommendationsRequest()
            request.limit = recommendationPageSize
            request.offset = 0
            let response = try await request.response()
            recommendationCount = response.recommendations.count
            shelves = response.recommendations.compactMap { recommendation in
                releaseAlbums.append(contentsOf: recommendation.albums)
                let items = recommendation.items.compactMap { item in
                    discoveryItem(item)
                }
                guard !items.isEmpty else { return nil }
                return AppleMusicDiscoveryShelf(
                    id: recommendation.id.rawValue,
                    title: recommendation.title
                        ?? L10n.text("appleMusic.discovery.recommended"),
                    subtitle: recommendation.reason,
                    items: Array(items.prefix(12))
                )
            }
        } catch {
            errors.append(Self.localizedServiceError(error))
        }

        do {
            var request = MusicRecentlyPlayedContainerRequest()
            request.limit = 20
            let response = try await request.response()
            recentItems = response.items.compactMap { recentlyPlayedItem($0) }
        } catch {
            errors.append(Self.localizedServiceError(error))
        }

        do {
            var request = MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Album.self])
            request.limit = 25
            let response = try await request.response()
            releaseAlbums.append(contentsOf: response.albumCharts.flatMap(\.items))
        } catch {
            errors.append(Self.localizedServiceError(error))
        }

        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: now)
            ?? now.addingTimeInterval(-15_552_000)
        var releaseAlbumsByID: [String: Album] = [:]
        for album in releaseAlbums where releaseAlbumsByID[album.id.rawValue] == nil {
            releaseAlbumsByID[album.id.rawValue] = album
            albumsByID[album.id.rawValue] = album
        }
        let releaseIDs = AppleMusicDiscoveryPlanner.recentReleaseIDs(
            releaseAlbums.map { ($0.id.rawValue, $0.releaseDate) },
            since: cutoff,
            through: now.addingTimeInterval(604_800),
            limit: 20
        )
        let releases = releaseIDs.compactMap { releaseAlbumsByID[$0] }
            .map(Self.catalogAlbumItem)

        recommendationShelves = AppleMusicDiscoveryPlanner.mergingShelves(
            recommendationShelves,
            with: shelves,
            replacingAll: true
        )
        recommendationOffset = recommendationCount
        hasMoreRecommendations = recommendationCount == recommendationPageSize
        recentlyPlayedItems = recentItems
        newReleaseItems = Array(releases)
        await refreshFavoriteRatings(
            for: shelves.flatMap(\.items) + recentItems + newReleaseItems
        )

        if errors.isEmpty {
            completeRetryableOperation()
        } else {
            message = errors.joined(separator: " ")
            markRetryableFailure()
        }
    }

    func loadMoreRecommendations() async {
        guard authorization == .authorized,
              hasMoreRecommendations,
              !isLoadingMoreRecommendations else { return }
        beginRetryableOperation(.moreRecommendations)
        isLoadingMoreRecommendations = true
        message = nil
        defer { isLoadingMoreRecommendations = false }

        do {
            var request = MusicPersonalRecommendationsRequest()
            request.limit = recommendationPageSize
            request.offset = recommendationOffset
            let response = try await request.response()
            let incoming: [AppleMusicDiscoveryShelf] = response.recommendations.compactMap {
                recommendation in
                let items = recommendation.items.compactMap { discoveryItem($0) }
                guard !items.isEmpty else { return nil }
                return AppleMusicDiscoveryShelf(
                    id: recommendation.id.rawValue,
                    title: recommendation.title
                        ?? L10n.text("appleMusic.discovery.recommended"),
                    subtitle: recommendation.reason,
                    items: Array(items.prefix(12))
                )
            }
            recommendationShelves = AppleMusicDiscoveryPlanner.mergingShelves(
                recommendationShelves,
                with: incoming,
                replacingAll: false
            )
            recommendationOffset += response.recommendations.count
            hasMoreRecommendations = response.recommendations.count
                == recommendationPageSize
            await refreshFavoriteRatings(for: incoming.flatMap(\.items))
            completeRetryableOperation()
        } catch {
            message = Self.localizedServiceError(error)
            markRetryableFailure()
        }
    }

    func loadDiscoveryDetails(_ item: AppleMusicCatalogItem) async {
        guard authorization == .authorized else { return }
        beginRetryableOperation(.discoveryDetails(item))
        isDiscoveryDetailWorking = true
        discoveryDetailItems = []
        discoveryRelatedItems = []
        discoveryDetailTitle = item.title
        discoveryDetailSubtitle = item.subtitle
        message = nil
        defer { isDiscoveryDetailWorking = false }

        do {
            switch item.kind {
            case .album:
                guard let album = albumsByID[item.musicItemID] else {
                    throw AppleMusicServiceError.unavailable
                }
                let detailedAlbum = try await album.with(
                    .tracks,
                    .relatedAlbums,
                    .appearsOn
                )
                discoveryDetailItems = (detailedAlbum.tracks ?? []).compactMap {
                    discoveryTrackItem($0)
                }
                let relatedAlbums = (detailedAlbum.relatedAlbums ?? []).map { album in
                    albumsByID[album.id.rawValue] = album
                    return Self.catalogAlbumItem(album)
                }
                let relatedPlaylists = (detailedAlbum.appearsOn ?? []).map { playlist in
                    playlistsByID[playlist.id.rawValue] = playlist
                    return Self.catalogPlaylistItem(playlist)
                }
                discoveryRelatedItems = relatedAlbums + relatedPlaylists
            case .playlist:
                guard let playlist = playlistsByID[item.musicItemID] else {
                    throw AppleMusicServiceError.unavailable
                }
                let detailedPlaylist = try await playlist.with(.entries, .moreByCurator)
                discoveryDetailItems = (detailedPlaylist.entries ?? []).compactMap { entry in
                    guard let entryItem = entry.item else { return nil }
                    return discoveryPlaylistEntryItem(entryItem, entryID: entry.id.rawValue)
                }
                discoveryRelatedItems = (detailedPlaylist.moreByCurator ?? []).map {
                    playlist in
                    playlistsByID[playlist.id.rawValue] = playlist
                    return Self.catalogPlaylistItem(playlist)
                }
            case .song, .artist, .musicVideo, .station:
                discoveryDetailItems = []
            }
            await refreshFavoriteRatings(for: discoveryDetailItems)
            completeRetryableOperation()
        } catch {
            message = Self.localizedServiceError(error)
            markRetryableFailure()
        }
    }

    func loadDiscoveryCharts(
        scope: AppleMusicChartScope,
        genreID requestedGenreID: String? = nil,
        reset: Bool = true
    ) async {
        guard authorization == .authorized else { return }
        guard reset || (hasMoreDiscoveryChartItems && !isLoadingMoreDiscoveryCharts) else {
            return
        }
        beginRetryableOperation(.discoveryCharts(scope, requestedGenreID, reset))
        if reset {
            isWorking = true
        } else {
            isLoadingMoreDiscoveryCharts = true
        }
        message = nil
        defer {
            isWorking = false
            isLoadingMoreDiscoveryCharts = false
        }

        do {
            if chartGenres.isEmpty {
                var genreRequest = MusicCatalogResourceRequest<Genre>()
                genreRequest.limit = 50
                let response = try await genreRequest.response()
                let genres = response.items.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                genresByID = Dictionary(uniqueKeysWithValues: genres.map {
                    ($0.id.rawValue, $0)
                })
                chartGenres = genres.map {
                    AppleMusicGenreOption(id: $0.id.rawValue, name: $0.name)
                }
            }

            let genreID = requestedGenreID ?? chartGenres.first?.id
            let genre = scope == .genres ? genreID.flatMap { genresByID[$0] } : nil
            var request = MusicCatalogChartsRequest(
                genre: genre,
                kinds: scope == .cities ? [.cityTop] : [.mostPlayed],
                types: [Song.self, Album.self, MusicKit.Playlist.self]
            )
            request.limit = discoveryChartPageSize
            request.offset = reset ? 0 : discoveryChartOffset
            let response = try await request.response()
            var items: [AppleMusicCatalogItem] = []
            var pageCounts: [Int] = []

            for chart in response.songCharts {
                pageCounts.append(chart.items.count)
                for (rank, song) in chart.items.enumerated() {
                    songsByID[song.id.rawValue] = song
                    items.append(AppleMusicCatalogItem(
                        id: "chart:\(chart.id):song:\(song.id.rawValue)",
                        musicItemID: song.id.rawValue,
                        kind: .song,
                        title: song.title,
                        subtitle: song.artistName,
                        detail: Self.chartDetail(
                            chart.title,
                            rank: (reset ? 0 : discoveryChartOffset) + rank + 1
                        ),
                        artworkURL: song.artwork?.url(width: 180, height: 180),
                        destinationURL: song.url,
                        groupTitle: chart.title
                    ))
                }
            }
            for chart in response.albumCharts {
                pageCounts.append(chart.items.count)
                for (rank, album) in chart.items.enumerated() {
                    albumsByID[album.id.rawValue] = album
                    items.append(AppleMusicCatalogItem(
                        id: "chart:\(chart.id):album:\(album.id.rawValue)",
                        musicItemID: album.id.rawValue,
                        kind: .album,
                        title: album.title,
                        subtitle: album.artistName,
                        detail: Self.chartDetail(
                            chart.title,
                            rank: (reset ? 0 : discoveryChartOffset) + rank + 1
                        ),
                        artworkURL: album.artwork?.url(width: 180, height: 180),
                        destinationURL: album.url,
                        groupTitle: chart.title
                    ))
                }
            }
            for chart in response.playlistCharts {
                pageCounts.append(chart.items.count)
                for (rank, playlist) in chart.items.enumerated() {
                    playlistsByID[playlist.id.rawValue] = playlist
                    items.append(AppleMusicCatalogItem(
                        id: "chart:\(chart.id):playlist:\(playlist.id.rawValue)",
                        musicItemID: playlist.id.rawValue,
                        kind: .playlist,
                        title: playlist.name,
                        subtitle: playlist.curatorName ?? "Apple Music",
                        detail: Self.chartDetail(
                            chart.title,
                            rank: (reset ? 0 : discoveryChartOffset) + rank + 1
                        ),
                        artworkURL: playlist.artwork?.url(width: 180, height: 180),
                        destinationURL: playlist.url,
                        groupTitle: chart.title
                    ))
                }
            }
            allDiscoveryChartItems = reset
                ? items
                : Self.merging(allDiscoveryChartItems, with: items)
            discoveryChartOffset = (reset ? 0 : discoveryChartOffset)
                + discoveryChartPageSize
            hasMoreDiscoveryChartItems = pageCounts.contains(discoveryChartPageSize)
            chartCityNames = AppleMusicDiscoveryPlanner.chartGroupTitles(
                in: allDiscoveryChartItems
            )
            if scope != .cities {
                selectedChartCityName = nil
            }
            rebuildDiscoveryChartItems()
            discoveryChartTitle = scope == .cities
                ? L10n.text("appleMusic.charts.citiesTitle")
                : chartGenres.first(where: { $0.id == genreID })?.name
                    ?? L10n.text("appleMusic.charts.genresTitle")
            await refreshFavoriteRatings(for: items)
            completeRetryableOperation()
        } catch {
            if reset {
                allDiscoveryChartItems = []
                discoveryChartItems = []
                chartCityNames = []
            }
            message = Self.localizedServiceError(error)
            markRetryableFailure()
        }
    }

    func loadMoreDiscoveryCharts(
        scope: AppleMusicChartScope,
        genreID: String?
    ) async {
        await loadDiscoveryCharts(scope: scope, genreID: genreID, reset: false)
    }

    func setChartCityFilter(_ cityName: String?) {
        selectedChartCityName = cityName
        rebuildDiscoveryChartItems()
    }

    private func rebuildDiscoveryChartItems() {
        discoveryChartItems = AppleMusicDiscoveryPlanner.filteringChartItems(
            allDiscoveryChartItems,
            groupTitle: selectedChartCityName
        )
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
        beginRetryableOperation(.loadLibrary(reset: reset))
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
            completeRetryableOperation()
        } catch {
            message = Self.localizedServiceError(error)
            markRetryableFailure()
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
        beginRetryableOperation(.searchLibrary(term, filter))
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
            completeRetryableOperation()
        } catch {
            message = Self.localizedServiceError(error)
            markRetryableFailure()
        }
    }

    func loadPlaylistContents(_ item: AppleMusicCatalogItem) async {
        guard item.kind == .playlist,
              let playlist = playlistsByID[item.musicItemID] else { return }
        beginRetryableOperation(.playlistContents(item))
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
            completeRetryableOperation()
        } catch {
            message = Self.localizedServiceError(error)
            markRetryableFailure()
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
        beginRetryableOperation(.catalogSearch(term))
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
            completeRetryableOperation()
        } catch {
            message = Self.localizedServiceError(error)
            markRetryableFailure()
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

        beginRetryableOperation(.unifiedSearch(term))
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
        if errors.isEmpty {
            completeRetryableOperation()
        } else {
            markRetryableFailure()
        }
        isUnifiedSearchWorking = false
    }

    func loadAppleMusicCharts() async {
        guard authorization == .authorized else {
            message = L10n.text("appleMusic.search.authorizationRequired")
            return
        }
        beginRetryableOperation(.charts)
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
            completeRetryableOperation()
        } catch {
            message = Self.localizedServiceError(error)
            markRetryableFailure()
        }
        isWorking = false
    }

    func searchITunesStore(_ rawTerm: String) async {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        beginRetryableOperation(.storeSearch(term))
        isWorking = true
        message = nil
        do {
            let region = Locale.current.region?.identifier ?? "JP"
            storeItems = try await storeClient.search(term: term, countryCode: region)
            if storeItems.isEmpty {
                message = L10n.text("appleMusic.search.noResults")
            }
            completeRetryableOperation()
        } catch {
            message = Self.localizedServiceError(error)
            markRetryableFailure()
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

    private func beginRetryableOperation(_ operation: RetryOperation) {
        retryOperation = operation
        canRetry = false
    }

    private func completeRetryableOperation() {
        retryOperation = nil
        canRetry = false
    }

    private func markRetryableFailure() {
        canRetry = retryOperation != nil
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

    private func discoveryItem(
        _ item: MusicPersonalRecommendation.Item
    ) -> AppleMusicCatalogItem? {
        switch item {
        case .album(let album):
            albumsByID[album.id.rawValue] = album
            return Self.catalogAlbumItem(album)
        case .playlist(let playlist):
            playlistsByID[playlist.id.rawValue] = playlist
            return Self.catalogPlaylistItem(playlist)
        case .station(let station):
            stationsByID[station.id.rawValue] = station
            return Self.catalogStationItem(station)
        @unknown default:
            return nil
        }
    }

    private func recentlyPlayedItem(
        _ item: RecentlyPlayedMusicItem
    ) -> AppleMusicCatalogItem? {
        switch item {
        case .album(let album):
            albumsByID[album.id.rawValue] = album
            return Self.catalogAlbumItem(album)
        case .playlist(let playlist):
            playlistsByID[playlist.id.rawValue] = playlist
            return Self.catalogPlaylistItem(playlist)
        case .station(let station):
            stationsByID[station.id.rawValue] = station
            return Self.catalogStationItem(station)
        @unknown default:
            return nil
        }
    }

    private func discoveryTrackItem(_ track: MusicKit.Track) -> AppleMusicCatalogItem? {
        switch track {
        case .song(let song):
            songsByID[song.id.rawValue] = song
            return Self.catalogSongItem(song)
        case .musicVideo(let video):
            return Self.catalogMusicVideoItem(video)
        @unknown default:
            return nil
        }
    }

    private func discoveryPlaylistEntryItem(
        _ item: MusicKit.Playlist.Entry.Item,
        entryID: String
    ) -> AppleMusicCatalogItem? {
        switch item {
        case .song(let song):
            songsByID[song.id.rawValue] = song
            return Self.catalogSongItem(song)
        case .musicVideo(let video):
            return Self.catalogMusicVideoItem(video, idPrefix: "playlistVideo:\(entryID):")
        @unknown default:
            return nil
        }
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

    private static func catalogStationItem(_ station: Station) -> AppleMusicCatalogItem {
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

    private static func catalogMusicVideoItem(
        _ video: MusicVideo,
        idPrefix: String = "musicVideo:"
    ) -> AppleMusicCatalogItem {
        AppleMusicCatalogItem(
            id: "\(idPrefix)\(video.id.rawValue)",
            musicItemID: video.id.rawValue,
            kind: .musicVideo,
            title: video.title,
            subtitle: video.artistName,
            detail: video.albumTitle ?? "",
            artworkURL: video.artwork?.url(width: 180, height: 180),
            destinationURL: video.url
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
        case home
        case charts
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
    @State private var source: Source = .home
    @State private var query = ""
    @State private var isCreatingPlaylist = false
    @State private var playlistName = ""
    @State private var playlistDescription = ""
    @State private var libraryQuery = ""
    @State private var libraryFilter: AppleMusicLibraryFilter = .all
    @State private var isShowingPlaylistContents = false
    @State private var selectedDiscoveryItem: AppleMusicCatalogItem?
    @State private var chartScope: AppleMusicChartScope = .cities
    @State private var selectedChartGenreID: String?
    @State private var selectedChartCityName: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if source != .iTunesStore && controller.authorization != .authorized {
                authorizationView
            } else if source == .home {
                discoveryContent
            } else if source == .charts {
                discoveryChartsContent
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
        .task {
            await controller.refresh()
            if controller.authorization == .authorized {
                await controller.loadDiscovery()
            }
        }
        .onChange(of: source) { _, newSource in
            if newSource == .home {
                Task { await controller.loadDiscovery() }
            } else if newSource == .charts {
                Task {
                    await controller.loadDiscoveryCharts(
                        scope: chartScope,
                        genreID: selectedChartGenreID
                    )
                    if selectedChartGenreID == nil {
                        selectedChartGenreID = controller.chartGenres.first?.id
                    }
                }
            } else if newSource == .library {
                Task { await controller.loadLibrary() }
            }
        }
        .sheet(isPresented: $isCreatingPlaylist) {
            createPlaylistSheet
        }
        .sheet(isPresented: $isShowingPlaylistContents) {
            playlistContentsSheet
        }
        .sheet(item: $selectedDiscoveryItem) { item in
            discoveryDetailSheet(item)
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
            .frame(width: 560)
        }
        .padding(20)
    }

    private var discoveryChartsContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.discoveryChartTitle.isEmpty
                        ? L10n.text("appleMusic.charts.discoveryTitle")
                        : controller.discoveryChartTitle)
                        .font(.title2.weight(.semibold))
                    Text(L10n.text("appleMusic.charts.discoverySubtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $chartScope) {
                    ForEach(AppleMusicChartScope.allCases) { scope in
                        Text(L10n.text(scope.localizationKey)).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                .onChange(of: chartScope) { _, scope in
                    selectedChartCityName = nil
                    controller.setChartCityFilter(nil)
                    Task {
                        await controller.loadDiscoveryCharts(
                            scope: scope,
                            genreID: selectedChartGenreID
                        )
                        if selectedChartGenreID == nil {
                            selectedChartGenreID = controller.chartGenres.first?.id
                        }
                    }
                }
                if chartScope == .genres {
                    Picker("", selection: $selectedChartGenreID) {
                        ForEach(controller.chartGenres) { genre in
                            Text(genre.name).tag(Optional(genre.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .onChange(of: selectedChartGenreID) { _, genreID in
                        guard let genreID else { return }
                        Task {
                            await controller.loadDiscoveryCharts(
                                scope: .genres,
                                genreID: genreID
                            )
                        }
                    }
                } else if !controller.chartCityNames.isEmpty {
                    Picker("", selection: $selectedChartCityName) {
                        Text(L10n.text("appleMusic.charts.allCities"))
                            .tag(String?.none)
                        ForEach(controller.chartCityNames, id: \.self) { cityName in
                            Text(cityName).tag(Optional(cityName))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .onChange(of: selectedChartCityName) { _, cityName in
                        controller.setChartCityFilter(cityName)
                    }
                }
                Button {
                    Task {
                        await controller.loadDiscoveryCharts(
                            scope: chartScope,
                            genreID: selectedChartGenreID
                        )
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.text("appleMusic.discovery.refresh"))
                .disabled(controller.isWorking)
            }
            .padding(20)

            if controller.isWorking {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
            } else {
                VStack(spacing: 0) {
                    List(controller.discoveryChartItems) { item in
                        catalogRow(item)
                    }
                    .overlay {
                        if controller.discoveryChartItems.isEmpty {
                            ContentUnavailableView(
                                controller.message
                                    ?? L10n.text("appleMusic.charts.empty"),
                                systemImage: "chart.bar.xaxis"
                            )
                        }
                    }
                    if controller.hasMoreDiscoveryChartItems {
                        Divider()
                        Button {
                            Task {
                                await controller.loadMoreDiscoveryCharts(
                                    scope: chartScope,
                                    genreID: selectedChartGenreID
                                )
                            }
                        } label: {
                            if controller.isLoadingMoreDiscoveryCharts {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(
                                    L10n.text("appleMusic.charts.loadMore"),
                                    systemImage: "chevron.down.circle"
                                )
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(controller.isLoadingMoreDiscoveryCharts)
                        .padding(12)
                    }
                }
            }
        }
    }

    private var discoveryContent: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("appleMusic.discovery.title"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.text("appleMusic.discovery.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(AppleMusicStoreController.replayURL)
                } label: {
                    Label(
                        L10n.text("appleMusic.replay.open"),
                        systemImage: "clock.arrow.2.circlepath"
                    )
                }
                .help(L10n.text("appleMusic.replay.help"))
                Button {
                    Task { await controller.loadDiscovery() }
                } label: {
                    Label(L10n.text("appleMusic.discovery.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(controller.isWorking)
            }
            .padding(20)

            statusStrip

            if controller.isWorking
                && controller.recommendationShelves.isEmpty
                && controller.recentlyPlayedItems.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        discoverySection(
                            title: L10n.text("appleMusic.discovery.newReleases"),
                            subtitle: L10n.text("appleMusic.discovery.newReleasesDetail"),
                            items: controller.newReleaseItems,
                            emptyKey: "appleMusic.discovery.newReleasesEmpty"
                        )
                        discoverySection(
                            title: L10n.text("appleMusic.discovery.recentlyPlayed"),
                            subtitle: nil,
                            items: controller.recentlyPlayedItems,
                            emptyKey: "appleMusic.discovery.recentlyPlayedEmpty"
                        )
                        ForEach(controller.recommendationShelves) { shelf in
                            discoverySection(
                                title: shelf.title,
                                subtitle: shelf.subtitle,
                                items: shelf.items,
                                emptyKey: "appleMusic.discovery.recommendationsEmpty"
                            )
                        }
                        if controller.hasMoreRecommendations {
                            Button {
                                Task { await controller.loadMoreRecommendations() }
                            } label: {
                                if controller.isLoadingMoreRecommendations {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label(
                                        L10n.text("appleMusic.discovery.loadMore"),
                                        systemImage: "chevron.down.circle"
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(controller.isLoadingMoreRecommendations)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func discoverySection(
        title: String,
        subtitle: String?,
        items: [AppleMusicCatalogItem],
        emptyKey: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text(L10n.text(emptyKey))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            discoveryCard(item)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func discoveryCard(_ item: AppleMusicCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: item.artworkURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppTheme.raised)
                }
                .frame(width: 142, height: 142)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                if item.kind.isPlayable {
                    Button {
                        Task {
                            await controller.playCatalogItem(
                                item,
                                with: appleMusicPlayback,
                                localPlayer: localPlayer
                            )
                        }
                    } label: {
                        Image(systemName: "play.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .padding(8)
                    .disabled(
                        !controller.canPlayCatalogContent || appleMusicPlayback.isWorking
                    )
                }
            }
            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if item.kind == .album || item.kind == .playlist {
                Button(L10n.text("appleMusic.discovery.details")) {
                    showDiscoveryDetails(item)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .frame(width: 142, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            if item.kind == .album || item.kind == .playlist {
                Button(L10n.text("appleMusic.discovery.details")) {
                    showDiscoveryDetails(item)
                }
            }
            if let url = item.destinationURL {
                Button(L10n.text("appleMusic.open")) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func discoveryDetailSheet(_ item: AppleMusicCatalogItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.discoveryDetailTitle.isEmpty
                        ? item.title : controller.discoveryDetailTitle)
                        .font(.title2.weight(.semibold))
                    Text(controller.discoveryDetailSubtitle.isEmpty
                        ? item.subtitle : controller.discoveryDetailSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.canRetry {
                    Button(L10n.text("common.retry")) {
                        Task { await controller.retryLastOperation() }
                    }
                    .disabled(controller.isDiscoveryDetailWorking)
                }
                Button(L10n.text("common.close")) {
                    selectedDiscoveryItem = nil
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            if controller.isDiscoveryDetailWorking {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
            } else if controller.discoveryDetailItems.isEmpty
                        && controller.discoveryRelatedItems.isEmpty {
                ContentUnavailableView(
                    controller.message
                        ?? L10n.text("appleMusic.discovery.detailsEmpty"),
                    systemImage: "music.note.list"
                )
            } else {
                List {
                    if !controller.discoveryDetailItems.isEmpty {
                        Section(L10n.text("appleMusic.discovery.tracks")) {
                            ForEach(controller.discoveryDetailItems) { detailItem in
                                catalogRow(detailItem)
                            }
                        }
                    }
                    if !controller.discoveryRelatedItems.isEmpty {
                        Section(L10n.text("appleMusic.discovery.related")) {
                            ForEach(controller.discoveryRelatedItems) { relatedItem in
                                HStack(spacing: 8) {
                                    catalogRow(relatedItem)
                                    if relatedItem.kind == .album
                                        || relatedItem.kind == .playlist {
                                        Button {
                                            selectedDiscoveryItem = relatedItem
                                            Task {
                                                await controller.loadDiscoveryDetails(
                                                    relatedItem
                                                )
                                            }
                                        } label: {
                                            Image(systemName: "chevron.right")
                                        }
                                        .buttonStyle(.borderless)
                                        .help(L10n.text("appleMusic.discovery.details"))
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 760, height: 560)
        .background(AppTheme.canvas)
    }

    private func showDiscoveryDetails(_ item: AppleMusicCatalogItem) {
        selectedDiscoveryItem = item
        Task { await controller.loadDiscoveryDetails(item) }
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
                    Task {
                        await controller.requestAccess()
                        if controller.authorization == .authorized, source == .home {
                            await controller.loadDiscovery()
                        }
                    }
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
            if controller.canRetry || appleMusicPlayback.canRetry {
                Button(L10n.text("common.retry")) {
                    Task {
                        if appleMusicPlayback.canRetry {
                            await appleMusicPlayback.retryLastOperation()
                        } else {
                            await controller.retryLastOperation()
                        }
                    }
                }
                .disabled(
                    controller.isWorking
                        || controller.isUnifiedSearchWorking
                        || appleMusicPlayback.isWorking
                )
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
