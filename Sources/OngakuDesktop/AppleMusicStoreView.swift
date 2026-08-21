import AppKit
import MusicKit
import SwiftUI

enum AppleMusicCatalogItemKind: String, Sendable {
    case song
    case album
    case artist

    var localizationKey: String { "appleMusic.kind.\(rawValue)" }
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

    private let storeClient: ITunesStoreClient
    private var songsByID: [String: Song] = [:]

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
                types: [Song.self, Album.self, Artist.self]
            )
            request.limit = 20
            request.includeTopResults = true
            let response = try await request.response()
            songsByID = Dictionary(
                uniqueKeysWithValues: response.songs.map { ($0.id.rawValue, $0) }
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
            catalogItems = songs + albums + artists
            if catalogItems.isEmpty {
                message = L10n.text("appleMusic.search.noResults")
            }
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
            guard 200..<300 ~= response.urlResponse.statusCode else {
                throw URLError(.badServerResponse)
            }
            addedSongIDs.insert(item.musicItemID)
            message = L10n.format("appleMusic.library.added", item.title)
        } catch {
            message = Self.localizedServiceError(error)
        }
        isWorking = false
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
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return L10n.text("appleMusic.error.offline")
        }
        return error.localizedDescription
    }
}

struct AppleMusicStoreView: View {
    private enum Source: String, CaseIterable, Identifiable {
        case appleMusic
        case iTunesStore

        var id: String { rawValue }
        var localizationKey: String { "appleMusic.source.\(rawValue)" }
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = AppleMusicStoreController()
    @State private var source: Source = .appleMusic
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if source == .appleMusic && controller.authorization != .authorized {
                authorizationView
            } else {
                searchContent
            }
            Divider()
            footer
        }
        .frame(width: 900, height: 650)
        .background(AppTheme.canvas)
        .task { await controller.refresh() }
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
            .frame(width: 300)
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

    @ViewBuilder
    private var statusStrip: some View {
        if source == .appleMusic {
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
            if item.kind == .song {
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
            if let message = controller.message {
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

    private func priceText(_ item: ITunesStoreItem) -> String? {
        guard let price = item.trackPrice, let currency = item.currency else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: price))
    }
}
