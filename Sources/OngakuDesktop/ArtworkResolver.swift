@preconcurrency import AVFoundation
import AppKit
import CryptoKit
import Foundation
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
            if case .album = subject {
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
    private let cacheDirectory: URL
    private let customDirectory: URL
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

        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        cacheDirectory = caches
            .appendingPathComponent("Ongaku Desktop", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        customDirectory = applicationSupport
            .appendingPathComponent("Ongaku Desktop", isDirectory: true)
            .appendingPathComponent("Custom Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: customDirectory,
            withIntermediateDirectories: true
        )
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
    }

    func removeCustomArtwork(for subject: ArtworkSubject) throws {
        let url = customURL(for: subject)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func migrateCustomArtwork(from source: ArtworkSubject, to destination: ArtworkSubject) throws {
        guard source != destination,
              let data = try? Data(contentsOf: customURL(for: source)) else { return }
        try registerCustomArtwork(data, for: destination)
        try removeCustomArtwork(for: source)
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
        guard let response: ArtistSearchResponse = await musicBrainzJSON(
            path: "/ws/2/artist/",
            queryItems: [
                URLQueryItem(name: "query", value: "artist:\"\(escapedQuery(name))\""),
                URLQueryItem(name: "fmt", value: "json"),
                URLQueryItem(name: "limit", value: "5")
            ]
        ) else { return nil }

        let expected = Self.normalized(name)
        guard let match = response.artists
            .filter({ artist in
                Self.normalized(artist.name) == expected
                    || artist.aliases?.contains(where: { Self.normalized($0.name) == expected }) == true
            })
            .max(by: { $0.score < $1.score }), match.score >= 90,
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
