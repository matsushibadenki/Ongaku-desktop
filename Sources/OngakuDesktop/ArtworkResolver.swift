@preconcurrency import AVFoundation
import AppKit
import CryptoKit
import Foundation
@preconcurrency import MusicKit
import SwiftUI

enum ArtworkSubject: Hashable, Sendable {
    case album(name: String, artist: String)
    case artist(name: String)

    fileprivate var cacheKey: String {
        switch self {
        case let .album(name, artist):
            "album\u{001F}\(name)\u{001F}\(artist)"
        case let .artist(name):
            "artist\u{001F}\(name)"
        }
    }
}

enum ArtworkThumbnailShape: Equatable {
    case roundedRectangle
    case circle
}

struct ArtistImageCandidate: Identifiable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case appleMusic
        case wikimediaCommons

        var titleKey: String { "artistImage.source.\(rawValue)" }
    }

    let id: String
    let artistName: String
    let previewURL: URL
    let downloadURL: URL
    let sourceURL: URL?
    let source: Source
    let attribution: String?
    let licenseName: String?
    let licenseURL: URL?
    let matchScore: Double
}

struct ArtistArtworkAttribution: Codable, Equatable, Sendable {
    let artistName: String
    let source: ArtistImageCandidate.Source
    let sourceURL: URL?
    let attribution: String?
    let licenseName: String?
    let licenseURL: URL?
    let savedAt: Date

    init(candidate: ArtistImageCandidate, savedAt: Date = .now) {
        artistName = candidate.artistName
        source = candidate.source
        sourceURL = candidate.sourceURL
        attribution = candidate.attribution
        licenseName = candidate.licenseName
        licenseURL = candidate.licenseURL
        self.savedAt = savedAt
    }
}

/// Displays a user-registered image first, then embedded artwork, and only
/// searches online when neither local source provides an image.
struct ArtworkThumbnail: View {
    @EnvironmentObject private var library: LibraryStore

    let tracks: [Track]
    let subject: ArtworkSubject
    let shape: ArtworkThumbnailShape
    let fallbackSymbol: String
    let fallbackLetter: String
    var onEditAlbum: (() -> Void)? = nil
    var onEditArtist: (() -> Void)? = nil

    @State private var artwork: NSImage?
    @State private var isRefreshing = false
    @State private var didRefresh = false
    @State private var isShowingRefreshFailure = false

    private var requestID: String {
        subject.cacheKey
            + "|" + tracks.map(\.sha256).joined(separator: "|")
            + "|revision:\(library.contentRevision)"
    }

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .clipShape(thumbnailShape)
        .overlay {
            thumbnailShape
                .stroke(AppTheme.rule.opacity(0.45), lineWidth: 1)
        }
        .overlay {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(AppTheme.spaceSM)
                    .background(.regularMaterial, in: Circle())
            } else if didRefresh {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.good)
                    .padding(AppTheme.spaceXS)
                    .background(.regularMaterial, in: Circle())
            }
        }
        .contentShape(thumbnailShape)
        .accessibilityHidden(true)
        .contextMenu {
            switch subject {
            case .album:
                if let onEditAlbum {
                    Button {
                        onEditAlbum()
                    } label: {
                        Label(L10n.text("metadataEditor.album.menu"), systemImage: "pencil")
                    }
                    Divider()
                }
                Button {
                    Task { await refreshAlbumArtwork() }
                } label: {
                    Label(
                        L10n.text("artwork.forceRefreshAlbum"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isRefreshing)
            case .artist:
                if let onEditArtist {
                    Button {
                        onEditArtist()
                    } label: {
                        Label(L10n.text("metadataEditor.artist.menu"), systemImage: "pencil")
                    }
                }
            }
        }
        .alert(
            L10n.text("artwork.refreshFailed.title"),
            isPresented: $isShowingRefreshFailure
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(L10n.text("artwork.refreshFailed.message"))
        }
        .task(id: requestID) {
            artwork = nil
            if let custom = await ArtworkResolver.shared.customArtworkData(for: subject),
               !Task.isCancelled {
                artwork = NSImage(data: custom)
                return
            }
            let urls = tracks.map(\.fileURL)
            let embedded = await EmbeddedArtworkCache.shared.firstArtworkData(for: urls)
            let data: Data?
            if let embedded {
                data = embedded
            } else {
                data = await ArtworkResolver.shared.artworkData(for: subject)
            }
            guard !Task.isCancelled, let data else { return }
            artwork = NSImage(data: data)
        }
    }

    @MainActor
    private func refreshAlbumArtwork() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let data = await ArtworkResolver.shared.forceRefreshAlbumArtwork(for: subject)
        isRefreshing = false

        guard !Task.isCancelled else { return }
        guard let data, let refreshed = NSImage(data: data) else {
            isShowingRefreshFailure = true
            return
        }
        artwork = refreshed
        didRefresh = true
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        didRefresh = false
    }

    private var fallback: some View {
        ZStack(alignment: .bottomLeading) {
            thumbnailShape.fill(AppTheme.raised)
            Image(systemName: fallbackSymbol)
                .font(.system(size: shape == .circle ? 28 : 38, weight: .ultraLight))
                .foregroundStyle(AppTheme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(fallbackLetter)
                .font(.system(size: shape == .circle ? 20 : 42, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.ink.opacity(0.10))
                .padding(shape == .circle ? 6 : AppTheme.spaceSM)
        }
    }

    private var thumbnailShape: AnyShape {
        switch shape {
        case .roundedRectangle:
            AnyShape(RoundedRectangle(cornerRadius: AppTheme.radiusLarge, style: .continuous))
        case .circle:
            AnyShape(Circle())
        }
    }
}

actor EmbeddedArtworkCache {
    static let shared = EmbeddedArtworkCache()

    private let maximumCost = 96 * 1_024 * 1_024
    private var dataByPath: [String: Data] = [:]
    private var missingPaths = Set<String>()
    private var insertionOrder: [String] = []
    private var totalCost = 0

    func firstArtworkData(for urls: [URL]) async -> Data? {
        for url in urls {
            let key = url.standardizedFileURL.path
            if let cached = dataByPath[key] { return cached }
            if missingPaths.contains(key) { continue }

            let data = await loadArtworkData(from: url)
            if let data {
                insert(data, forKey: key)
                return data
            }
            missingPaths.insert(key)
        }
        return nil
    }

    func invalidate(_ urls: [URL]) {
        let keys = Set(urls.map { $0.standardizedFileURL.path })
        for key in keys {
            if let removed = dataByPath.removeValue(forKey: key) {
                totalCost -= removed.count
            }
            missingPaths.remove(key)
        }
        insertionOrder.removeAll { keys.contains($0) }
    }

    private func loadArtworkData(from url: URL) async -> Data? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(
                  from: metadata,
                  filteredByIdentifier: .commonIdentifierArtwork
              ).first else { return nil }
        return try? await item.load(.dataValue)
    }

    private func insert(_ data: Data, forKey key: String) {
        dataByPath[key] = data
        insertionOrder.append(key)
        totalCost += data.count
        while totalCost > maximumCost, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            if let removed = dataByPath.removeValue(forKey: oldest) {
                totalCost -= removed.count
            }
        }
    }
}

actor ArtworkResolver {
    static let shared = ArtworkResolver()

    private static let positiveLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let negativeLifetime: TimeInterval = 24 * 60 * 60
    private static let maximumDownloadSize = 12 * 1_024 * 1_024

    private let session: URLSession
    private var cacheDirectory: URL
    private var customDirectory: URL
    private var memoryCache: [ArtworkSubject: Data] = [:]
    private var missing = Set<ArtworkSubject>()
    private var inFlight: [ArtworkSubject: Task<Data?, Never>] = [:]
    private var nextMusicBrainzRequest: ContinuousClock.Instant?
    private var isManualRefreshInProgress = false

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = [
            "User-Agent": "OngakuDesktop/0.1 (https://github.com/matsushibadenki/Ongaku-desktop)",
            "Accept": "application/json, image/*"
        ]
        session = URLSession(configuration: configuration)

        let defaultMedia = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Ongaku Desktop/Ongaku Media", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Ongaku Media")
        let portable = PortableLibraryStorage(mediaURL: defaultMedia)
        cacheDirectory = portable.downloadedArtworkURL
        customDirectory = portable.customArtworkURL
    }

    /// Selects the artwork directories belonging to the active portable
    /// library. Device-independent artwork then travels with the music folder.
    func configure(libraryRootURL: URL) throws {
        cacheDirectory = libraryRootURL
            .appendingPathComponent("Artwork/Downloaded", isDirectory: true)
        customDirectory = libraryRootURL
            .appendingPathComponent("Artwork/Custom", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: customDirectory,
            withIntermediateDirectories: true
        )
        memoryCache.removeAll()
        missing.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    func customArtworkData(for subject: ArtworkSubject) -> Data? {
        guard let data = try? Data(contentsOf: customURL(for: subject)),
              data.count <= Self.maximumDownloadSize,
              NSImage(data: data) != nil else { return nil }
        return data
    }

    func registerCustomArtwork(_ data: Data, for subject: ArtworkSubject) throws {
        guard data.count <= Self.maximumDownloadSize,
              NSImage(data: data) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try data.write(to: customURL(for: subject), options: .atomic)
        try? FileManager.default.removeItem(at: attributionURL(for: subject))
    }

    func registerArtistArtwork(
        _ data: Data,
        candidate: ArtistImageCandidate,
        for subject: ArtworkSubject
    ) throws {
        guard case .artist = subject else { throw CocoaError(.fileWriteInvalidFileName) }
        try registerCustomArtwork(data, for: subject)
        let attribution = ArtistArtworkAttribution(candidate: candidate)
        try JSONEncoder().encode(attribution).write(
            to: attributionURL(for: subject),
            options: .atomic
        )
    }

    func artistArtworkAttribution(for subject: ArtworkSubject) -> ArtistArtworkAttribution? {
        guard let data = try? Data(contentsOf: attributionURL(for: subject)) else { return nil }
        return try? JSONDecoder().decode(ArtistArtworkAttribution.self, from: data)
    }

    func removeCustomArtwork(for subject: ArtworkSubject) throws {
        let url = customURL(for: subject)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: attributionURL(for: subject))
    }

    func migrateCustomArtwork(from source: ArtworkSubject, to destination: ArtworkSubject) throws {
        guard source != destination,
              let data = try? Data(contentsOf: customURL(for: source)) else { return }
        try registerCustomArtwork(data, for: destination)
        if let attribution = artistArtworkAttribution(for: source) {
            try JSONEncoder().encode(attribution).write(
                to: attributionURL(for: destination),
                options: .atomic
            )
        }
        try removeCustomArtwork(for: source)
    }

    func artistImageCandidates(for name: String) async -> [ArtistImageCandidate] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isMeaningful(.artist(name: trimmed)) else { return [] }

        let musicBrainzMatch = await matchedMusicBrainzArtist(name: trimmed)
        var acceptedNames = Set([Self.normalized(trimmed)])
        if let musicBrainzMatch {
            acceptedNames.insert(Self.normalized(musicBrainzMatch.name))
            for alias in musicBrainzMatch.aliases ?? [] {
                acceptedNames.insert(Self.normalized(alias.name))
            }
        }

        async let appleMusic = appleMusicArtistCandidates(
            name: trimmed,
            acceptedNames: acceptedNames
        )
        let commons = await wikimediaArtistCandidates(
            name: trimmed,
            musicBrainzMatch: musicBrainzMatch
        )
        let combined = await appleMusic + commons
        return Self.orderedArtistImageCandidates(combined)
    }

    nonisolated static func orderedArtistImageCandidates(
        _ candidates: [ArtistImageCandidate]
    ) -> [ArtistImageCandidate] {
        Dictionary(grouping: candidates, by: \.id)
            .compactMap { $0.value.max(by: { $0.matchScore < $1.matchScore }) }
            .sorted {
                let lhsExact = $0.matchScore >= 0.999
                let rhsExact = $1.matchScore >= 0.999
                if lhsExact != rhsExact { return lhsExact && !rhsExact }
                if $0.source != $1.source {
                    return $0.source == .appleMusic
                }
                if $0.matchScore != $1.matchScore { return $0.matchScore > $1.matchScore }
                return $0.id < $1.id
            }
    }

    func downloadArtistImage(_ candidate: ArtistImageCandidate) async -> Data? {
        await imageData(from: candidate.downloadURL)
    }

    func artworkData(for subject: ArtworkSubject) async -> Data? {
        guard Self.isMeaningful(subject) else { return nil }
        if let data = memoryCache[subject] { return data }
        if missing.contains(subject) { return nil }
        if let cached = diskCache(for: subject, allowExpired: false) {
            if cached.isEmpty {
                missing.insert(subject)
                return nil
            }
            memoryCache[subject] = cached
            return cached
        }
        // A manual refresh gets priority over background thumbnail population.
        guard !isManualRefreshInProgress else { return nil }
        if let task = inFlight[subject] { return await task.value }

        let task = Task { await self.resolveAndCache(subject) }
        inFlight[subject] = task
        let result = await task.value
        inFlight[subject] = nil
        return result
    }

    /// Ignores positive and negative caches and performs a new album lookup.
    /// A failed manual refresh deliberately preserves the current cached image.
    func forceRefreshAlbumArtwork(for subject: ArtworkSubject) async -> Data? {
        guard case let .album(name, artist) = subject,
              Self.isMeaningful(subject) else { return nil }

        // Drop queued automatic lookups so this explicit user action does not
        // sit behind every thumbnail that happened to appear in a lazy grid.
        isManualRefreshInProgress = true
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        nextMusicBrainzRequest = ContinuousClock().now.advanced(by: .milliseconds(1_100))
        defer { isManualRefreshInProgress = false }

        missing.remove(subject)
        guard let resolved = await resolveAlbum(name: name, artist: artist) else {
            return nil
        }
        memoryCache[subject] = resolved
        writeDiskCache(resolved, for: subject)
        return resolved
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "" }
            .joined()
    }

    private func resolveAndCache(_ subject: ArtworkSubject) async -> Data? {
        let resolved: Data?
        switch subject {
        case let .album(name, artist):
            resolved = await resolveAlbum(name: name, artist: artist)
        case let .artist(name):
            resolved = await resolveArtist(name: name)
        }

        guard !Task.isCancelled else { return nil }
        if let resolved {
            memoryCache[subject] = resolved
            writeDiskCache(resolved, for: subject)
            return resolved
        }

        // A stale image is more useful than a placeholder during a temporary
        // outage, while a short negative cache prevents repeated web searches.
        if let stale = diskCache(for: subject, allowExpired: true), !stale.isEmpty {
            memoryCache[subject] = stale
            return stale
        }
        missing.insert(subject)
        writeDiskCache(Data(), for: subject)
        return nil
    }

    private func resolveAlbum(name: String, artist: String) async -> Data? {
        guard let response: ReleaseGroupSearchResponse = await musicBrainzJSON(
            path: "/ws/2/release-group/",
            queryItems: [
                URLQueryItem(name: "query", value: "releasegroup:\"\(escapedQuery(name))\" AND artist:\"\(escapedQuery(artist))\""),
                URLQueryItem(name: "fmt", value: "json"),
                URLQueryItem(name: "limit", value: "5")
            ]
        ) else { return nil }

        let expectedAlbum = Self.normalized(name)
        let expectedArtist = Self.normalized(artist)
        guard let match = response.releaseGroups
            .filter({ group in
                Self.normalized(group.title) == expectedAlbum
                    || group.aliases?.contains(where: { Self.normalized($0.name) == expectedAlbum }) == true
            })
            .filter({ group in
                group.artistCredit.contains { credit in
                    Self.normalized(credit.name) == expectedArtist
                        || Self.normalized(credit.artist.name) == expectedArtist
                        || credit.artist.aliases?.contains(where: {
                            Self.normalized($0.name) == expectedArtist
                        }) == true
                }
            })
            .max(by: { $0.score < $1.score }), match.score >= 80 else {
            return nil
        }

        if let url = URL(string: "https://coverartarchive.org/release-group/\(match.id)/front-500"),
           let data = await imageData(from: url) {
            return data
        }

        // Some releases have approved cover art before the release group gets
        // a representative image. Try the exact matching editions as fallback.
        for release in (match.releases ?? []).prefix(4) {
            guard !Task.isCancelled,
                  let url = URL(string: "https://coverartarchive.org/release/\(release.id)/front-500") else {
                return nil
            }
            if let data = await imageData(from: url) { return data }
        }
        return nil
    }

    private func resolveArtist(name: String) async -> Data? {
        guard let match = await matchedMusicBrainzArtist(name: name),
              let details: ArtistDetails = await musicBrainzJSON(
                  path: "/ws/2/artist/\(match.id)",
                  queryItems: [
                      URLQueryItem(name: "inc", value: "url-rels"),
                      URLQueryItem(name: "fmt", value: "json")
                  ]
              ),
              let wikidataURL = details.relations.first(where: { $0.type == "wikidata" })?.url.resource,
              let identifier = URL(string: wikidataURL)?.lastPathComponent,
              identifier.hasPrefix("Q"),
              let entityURL = URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(identifier).json"),
              let entities: WikidataResponse = await json(from: entityURL),
              let filename = entities.entities[identifier]?.claims["P18"]?.first?.mainsnak.datavalue?.value else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "commons.wikimedia.org"
        components.path = "/wiki/Special:Redirect/file/\(filename)"
        components.queryItems = [URLQueryItem(name: "width", value: "600")]
        guard let imageURL = components.url else { return nil }
        return await imageData(from: imageURL)
    }

    private func matchedMusicBrainzArtist(name: String) async -> ArtistSearchResult? {
        guard let response: ArtistSearchResponse = await musicBrainzJSON(
            path: "/ws/2/artist/",
            queryItems: [
                URLQueryItem(name: "query", value: "artist:\"\(escapedQuery(name))\""),
                URLQueryItem(name: "fmt", value: "json"),
                URLQueryItem(name: "limit", value: "8")
            ]
        ) else { return nil }
        let expected = Self.normalized(name)
        return response.artists
            .filter { artist in
                Self.normalized(artist.name) == expected
                    || artist.aliases?.contains(where: {
                        Self.normalized($0.name) == expected
                    }) == true
            }
            .filter { $0.score >= 80 }
            .max(by: { $0.score < $1.score })
    }

    private func appleMusicArtistCandidates(
        name: String,
        acceptedNames: Set<String>
    ) async -> [ArtistImageCandidate] {
        do {
            var request = MusicCatalogSearchRequest(term: name, types: [MusicKit.Artist.self])
            request.limit = 10
            request.includeTopResults = true
            let response = try await request.response()
            return response.artists.compactMap { artist in
                let normalizedName = Self.normalized(artist.name)
                let score = acceptedNames.contains(normalizedName)
                    ? 1.0 : Self.nameSimilarity(normalizedName, Self.normalized(name))
                guard score >= 0.72,
                      let previewURL = artist.artwork?.url(width: 360, height: 360),
                      let downloadURL = artist.artwork?.url(width: 1_000, height: 1_000) else {
                    return nil
                }
                return ArtistImageCandidate(
                    id: "apple-music:\(artist.id.rawValue)",
                    artistName: artist.name,
                    previewURL: previewURL,
                    downloadURL: downloadURL,
                    sourceURL: artist.url,
                    source: .appleMusic,
                    attribution: "Apple Music · \(artist.name)",
                    licenseName: nil,
                    licenseURL: nil,
                    matchScore: score
                )
            }
        } catch {
            return []
        }
    }

    private func wikimediaArtistCandidates(
        name: String,
        musicBrainzMatch: ArtistSearchResult?
    ) async -> [ArtistImageCandidate] {
        guard let musicBrainzMatch,
              let details: ArtistDetails = await musicBrainzJSON(
                path: "/ws/2/artist/\(musicBrainzMatch.id)",
                queryItems: [
                    URLQueryItem(name: "inc", value: "url-rels"),
                    URLQueryItem(name: "fmt", value: "json")
                ]
              ),
              let wikidataURL = details.relations.first(where: {
                $0.type == "wikidata"
              })?.url.resource,
              let identifier = URL(string: wikidataURL)?.lastPathComponent,
              identifier.hasPrefix("Q"),
              let entityURL = URL(
                string: "https://www.wikidata.org/wiki/Special:EntityData/\(identifier).json"
              ),
              let entities: WikidataResponse = await json(from: entityURL) else {
            return []
        }
        let fileNames = entities.entities[identifier]?.claims["P18"]?
            .compactMap(\.mainsnak.datavalue?.value) ?? []
        var candidates: [ArtistImageCandidate] = []
        for fileName in fileNames.prefix(8) {
            guard !Task.isCancelled,
                  let metadata = await commonsMetadata(fileName: fileName) else { continue }
            candidates.append(ArtistImageCandidate(
                id: "wikimedia-commons:\(fileName)",
                artistName: musicBrainzMatch.name,
                previewURL: metadata.thumbnailURL ?? metadata.originalURL,
                downloadURL: metadata.originalURL,
                sourceURL: metadata.descriptionURL,
                source: .wikimediaCommons,
                attribution: Self.plainText(metadata.artist ?? metadata.credit),
                licenseName: Self.plainText(metadata.licenseName),
                licenseURL: metadata.licenseURL.flatMap(URL.init(string:)),
                matchScore: Self.normalized(musicBrainzMatch.name) == Self.normalized(name)
                    ? 1 : Double(musicBrainzMatch.score) / 100
            ))
        }
        return candidates
    }

    private func commonsMetadata(fileName: String) async -> CommonsImageMetadata? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "commons.wikimedia.org"
        components.path = "/w/api.php"
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "360"),
            URLQueryItem(name: "titles", value: "File:\(fileName)")
        ]
        guard let url = components.url,
              let response: CommonsQueryResponse = await json(from: url),
              let info = response.query.pages.values.first?.imageInfo?.first,
              let originalURL = URL(string: info.url) else { return nil }
        return CommonsImageMetadata(
            originalURL: originalURL,
            thumbnailURL: info.thumbnailURL.flatMap(URL.init(string:)),
            descriptionURL: info.descriptionURL.flatMap(URL.init(string:)),
            artist: info.extmetadata?["Artist"]?.value,
            credit: info.extmetadata?["Credit"]?.value,
            licenseName: info.extmetadata?["LicenseShortName"]?.value,
            licenseURL: info.extmetadata?["LicenseUrl"]?.value
        )
    }

    private nonisolated static func nameSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        if lhs.contains(rhs) || rhs.contains(lhs) {
            return Double(min(lhs.count, rhs.count)) / Double(max(lhs.count, rhs.count))
        }
        return 0
    }

    private nonisolated static func plainText(_ value: String?) -> String? {
        guard let value else { return nil }
        let withoutTags = value.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let collapsed = withoutTags
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private func musicBrainzJSON<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]
    ) async -> T? {
        // Reserve the request slot before suspending. Other tasks entering this
        // actor while we sleep therefore reserve later slots instead of firing
        // together when the first delay ends.
        let clock = ContinuousClock()
        let now = clock.now
        let requestTime: ContinuousClock.Instant
        if let nextMusicBrainzRequest, nextMusicBrainzRequest > now {
            requestTime = nextMusicBrainzRequest
        } else {
            requestTime = now
        }
        nextMusicBrainzRequest = requestTime.advanced(by: .milliseconds(1_100))
        if requestTime > now {
            do {
                try await clock.sleep(until: requestTime)
            } catch {
                return nil
            }
        }
        guard !Task.isCancelled else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "musicbrainz.org"
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else { return nil }
        return await json(from: url)
    }

    private func json<T: Decodable>(from url: URL) async -> T? {
        guard !Task.isCancelled else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func imageData(from url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= Self.maximumDownloadSize,
              NSImage(data: data) != nil else { return nil }
        return data
    }

    private func diskCache(for subject: ArtworkSubject, allowExpired: Bool) -> Data? {
        let url = cacheURL(for: subject)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url) else { return nil }
        let lifetime = data.isEmpty ? Self.negativeLifetime : Self.positiveLifetime
        guard allowExpired || Date().timeIntervalSince(modified) <= lifetime else { return nil }
        return data
    }

    private func writeDiskCache(_ data: Data, for subject: ArtworkSubject) {
        try? data.write(to: cacheURL(for: subject), options: .atomic)
    }

    private func cacheURL(for subject: ArtworkSubject) -> URL {
        let name = hashedName(for: subject)
        return cacheDirectory.appendingPathComponent(name).appendingPathExtension("artwork")
    }

    private func customURL(for subject: ArtworkSubject) -> URL {
        customDirectory.appendingPathComponent(hashedName(for: subject))
            .appendingPathExtension("custom-artwork")
    }

    private func attributionURL(for subject: ArtworkSubject) -> URL {
        customDirectory.appendingPathComponent(hashedName(for: subject))
            .appendingPathExtension("artist-attribution.json")
    }

    private func hashedName(for subject: ArtworkSubject) -> String {
        let digest = SHA256.hash(data: Data(subject.cacheKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func escapedQuery(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func isMeaningful(_ subject: ArtworkSubject) -> Bool {
        let values: [String]
        switch subject {
        case let .album(name, artist): values = [name, artist]
        case let .artist(name): values = [name]
        }
        let unknown = [
            "unknown", "unknownalbum", "unknownartist",
            "不明", "不明なアルバム", "不明なアーティスト",
            "未知专辑", "未知艺人"
        ].map(normalized)
        return values.allSatisfy {
            let value = normalized($0)
            return value.count >= 2 && !unknown.contains(value)
        }
    }
}

private struct ReleaseGroupSearchResponse: Decodable {
    let releaseGroups: [ReleaseGroup]

    enum CodingKeys: String, CodingKey { case releaseGroups = "release-groups" }
}

private struct ReleaseGroup: Decodable {
    let id: String
    let score: Int
    let title: String
    let artistCredit: [ArtistCredit]
    let aliases: [NameAlias]?
    let releases: [ReleaseReference]?

    enum CodingKeys: String, CodingKey {
        case id, score, title, aliases, releases
        case artistCredit = "artist-credit"
    }
}

private struct ArtistCredit: Decodable {
    let name: String
    let artist: ArtistReference
}

private struct ArtistReference: Decodable {
    let name: String
    let aliases: [NameAlias]?
}

private struct NameAlias: Decodable { let name: String }

private struct ReleaseReference: Decodable { let id: String }

private struct ArtistSearchResponse: Decodable { let artists: [ArtistSearchResult] }

private struct ArtistSearchResult: Decodable {
    let id: String
    let score: Int
    let name: String
    let aliases: [NameAlias]?
}

private struct ArtistDetails: Decodable { let relations: [ArtistRelation] }

private struct ArtistRelation: Decodable {
    let type: String
    let url: RelationURL
}

private struct RelationURL: Decodable { let resource: String }

private struct WikidataResponse: Decodable { let entities: [String: WikidataEntity] }

private struct WikidataEntity: Decodable { let claims: [String: [WikidataClaim]] }

private struct WikidataClaim: Decodable { let mainsnak: WikidataSnak }

private struct WikidataSnak: Decodable { let datavalue: WikidataValue? }

private struct WikidataValue: Decodable { let value: String }

private struct CommonsQueryResponse: Decodable {
    let query: Query

    struct Query: Decodable {
        let pages: [String: Page]
    }

    struct Page: Decodable {
        let imageInfo: [ImageInfo]?

        enum CodingKeys: String, CodingKey {
            case imageInfo = "imageinfo"
        }
    }

    struct ImageInfo: Decodable {
        let url: String
        let thumbnailURL: String?
        let descriptionURL: String?
        let extmetadata: [String: MetadataValue]?

        enum CodingKeys: String, CodingKey {
            case url, extmetadata
            case thumbnailURL = "thumburl"
            case descriptionURL = "descriptionurl"
        }
    }

    struct MetadataValue: Decodable {
        let value: String
    }
}

private struct CommonsImageMetadata {
    let originalURL: URL
    let thumbnailURL: URL?
    let descriptionURL: URL?
    let artist: String?
    let credit: String?
    let licenseName: String?
    let licenseURL: String?
}
