@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct LibraryContent: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @State private var sortOrder = [KeyPathComparator(\Track.title)]

    var body: some View {
        VStack(spacing: 0) {
            header

            if library.selectedSection == .effects {
                sectionContent
            } else if library.filteredTracks.isEmpty {
                EmptyLibraryView(hasTracks: !library.tracks.isEmpty)
            } else {
                sectionContent
            }

            activityBar
        }
        .background(AppTheme.canvas)
        .navigationTitle(L10n.text(library.selectedSection.titleKey))
        .searchable(text: $library.searchText, placement: .toolbar, prompt: L10n.text("library.search"))
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch library.selectedSection {
        case .albums:
            AlbumGrid(tracks: library.filteredTracks)
        case .artists:
            ArtistBrowser(tracks: library.filteredTracks)
        case .songs, .recentlyAdded, .needsAttention:
            trackTable
        case .effects:
            EffectsRackView()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(library.selectedSection.titleKey))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                Text(headerSubtitle)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryInk)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.spaceLG)
        .padding(.top, AppTheme.spaceMD)
        .padding(.bottom, AppTheme.spaceSM)
    }

    private var headerSubtitle: String {
        if library.selectedSection == .effects {
            return L10n.format("effects.enabledCount", player.enabledEffectCount, player.effectSettings.count)
        }
        return L10n.format("library.visibleCount", library.filteredTracks.count)
    }

    private var trackTable: some View {
        Table(library.filteredTracks.sorted(using: sortOrder), selection: $library.selectedTrackID, sortOrder: $sortOrder) {
            TableColumn(L10n.text("column.title"), value: \.title) { track in
                HStack(spacing: 10) {
                    Image(systemName: player.currentTrack?.id == track.id && player.isPlaying ? "speaker.wave.2.fill" : "music.note")
                        .foregroundStyle(player.currentTrack?.id == track.id ? AppTheme.accent : AppTheme.secondaryInk)
                        .frame(width: 16)
                    Text(track.title)
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { player.play(track) }
                .contextMenu {
                    Button(L10n.text("track.play")) { player.play(track) }
                    Button(L10n.text("track.reveal")) { library.reveal(track) }
                }
            }
            .width(min: 240, ideal: 300)

            TableColumn(L10n.text("column.artist"), value: \.artist) { track in
                Text(track.artist).lineLimit(1)
            }
            .width(min: 130, ideal: 180)

            TableColumn(L10n.text("column.album"), value: \.album) { track in
                Text(track.album).lineLimit(1)
            }
            .width(min: 150, ideal: 200)

            TableColumn(L10n.text("column.duration")) { track in
                Text(DurationFormatter.string(track.duration))
                    .font(.callout.monospacedDigit())
            }
            .width(min: 68, ideal: 76)

            TableColumn(L10n.text("column.health")) { track in
                HealthLabel(health: track.health, compact: true)
            }
            .width(min: 64, ideal: 72)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder
    private var activityBar: some View {
        switch library.activity {
        case .idle:
            EmptyView()
        case .importing:
            statusBar(text: L10n.text("status.importing"), progress: true, color: AppTheme.accent)
        case .verifying:
            statusBar(text: L10n.text("status.verifying"), progress: true, color: AppTheme.accent)
        case .notice(let message):
            statusBar(text: message, progress: false, color: AppTheme.good, symbol: "checkmark.shield")
        case .failed(let message):
            statusBar(text: message, progress: false, color: AppTheme.warning)
        }
    }

    private func statusBar(
        text: String,
        progress: Bool,
        color: Color,
        symbol: String = "exclamationmark.triangle"
    ) -> some View {
        HStack(spacing: AppTheme.spaceXS) {
            if progress { ProgressView().controlSize(.small) }
            Image(systemName: progress ? "arrow.triangle.2.circlepath" : symbol)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, AppTheme.spaceMD)
        .frame(height: 34)
        .background(AppTheme.raised)
        .accessibilityElement(children: .combine)
    }
}

private struct AlbumGrid: View {
    let tracks: [Track]

    private struct AlbumGroup: Identifiable {
        let name: String
        let artist: String
        let tracks: [Track]

        var id: String { "\(name)\u{001F}\(artist)" }
    }

    private var albums: [AlbumGroup] {
        let groups = Dictionary(grouping: tracks) { "\($0.album)\u{001F}\($0.artist)" }
        return groups.values.compactMap { group in
            guard let first = group.first else { return nil }
            return AlbumGroup(name: first.album, artist: first.artist, tracks: group)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: AppTheme.spaceLG)], spacing: AppTheme.spaceLG) {
                ForEach(albums) { album in
                    VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                        EmbeddedArtworkThumbnail(
                            tracks: album.tracks,
                            shape: .roundedRectangle,
                            fallbackSymbol: "square.stack.3d.up.fill",
                            fallbackLetter: String(album.name.prefix(1)).uppercased()
                        )
                        .aspectRatio(1, contentMode: .fit)
                        Text(album.name)
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)
                        Text(album.artist)
                            .font(.callout)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .lineLimit(1)
                        Text(L10n.format("album.songCount", album.tracks.count))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryInk)
                    }
                }
            }
            .padding(AppTheme.spaceLG)
        }
    }
}

private struct ArtistBrowser: View {
    let tracks: [Track]

    private struct ArtistGroup: Identifiable {
        let name: String
        let tracks: [Track]

        var id: String { name }
        var albumCount: Int { Set(tracks.map(\.album)).count }
    }

    private var artists: [ArtistGroup] {
        Dictionary(grouping: tracks, by: \.artist).map { artist, songs in
            ArtistGroup(name: artist, tracks: songs)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            ForEach(artists) { artist in
                HStack(spacing: AppTheme.spaceMD) {
                    EmbeddedArtworkThumbnail(
                        tracks: artist.tracks,
                        shape: .circle,
                        fallbackSymbol: "person.crop.circle.fill",
                        fallbackLetter: String(artist.name.prefix(1)).uppercased()
                    )
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(artist.name)
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                        Text(L10n.format("artist.summary", artist.albumCount, artist.tracks.count))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryInk)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

private enum ArtworkThumbnailShape: Equatable {
    case roundedRectangle
    case circle
}

private struct EmbeddedArtworkThumbnail: View {
    let tracks: [Track]
    let shape: ArtworkThumbnailShape
    let fallbackSymbol: String
    let fallbackLetter: String

    @State private var artwork: NSImage?

    private var requestID: String {
        tracks.map(\.sha256).joined(separator: "|")
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
        .contentShape(thumbnailShape)
        .accessibilityHidden(true)
        .task(id: requestID) {
            artwork = nil
            guard let data = await EmbeddedArtworkCache.shared.firstArtworkData(
                for: tracks.map(\.fileURL)
            ), !Task.isCancelled else { return }
            artwork = NSImage(data: data)
        }
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

private actor EmbeddedArtworkCache {
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

private struct EmptyLibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    let hasTracks: Bool
    @State private var isImporting = false

    var body: some View {
        ContentUnavailableView {
            Label(
                hasTracks ? L10n.text("empty.filtered.title") : L10n.text("empty.library.title"),
                systemImage: hasTracks ? "line.3.horizontal.decrease.circle" : "music.note.house"
            )
        } description: {
            Text(hasTracks ? L10n.text("empty.filtered.body") : L10n.text("empty.library.body"))
        } actions: {
            if hasTracks {
                Button(L10n.text("empty.clearSearch")) { library.searchText = "" }
            } else {
                Button(L10n.text("command.import")) {
                    NotificationCenter.default.post(name: .requestImport, object: nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AppTheme.spaceMD)
    }
}
