@preconcurrency import AVFoundation
import AppKit
import SwiftUI

private struct TrackTableForegroundModifier: ViewModifier {
    @Environment(\.controlActiveState) private var controlActiveState
    let isSelected: Bool
    let fallback: Color

    func body(content: Content) -> some View {
        content.foregroundStyle(
            isSelected && controlActiveState == .key ? Color.white : fallback
        )
    }
}

private extension View {
    func trackTableForeground(isSelected: Bool, fallback: Color) -> some View {
        modifier(TrackTableForegroundModifier(isSelected: isSelected, fallback: fallback))
    }
}

struct LibraryContent: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @State private var sortOrder = [KeyPathComparator(\Track.title)]
    @State private var sortedTracks: [Track] = []
    @State private var isSortingTracks = false
    @State private var trackSortTask: Task<Void, Never>?
    @State private var trackSortGeneration = UUID()
    @State private var selectedAlbumID: AlbumGroup.ID?
    @State private var selectedArtistID: ArtistGroup.ID?
    @State private var metadataEditTarget: MetadataEditTarget?

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
        .sheet(item: $metadataEditTarget) { target in
            MetadataEditorView(target: target)
                .environmentObject(library)
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch library.selectedSection {
        case .albums:
            if let album = selectedAlbum {
                AlbumDetail(
                    album: album,
                    onBack: { selectedAlbumID = nil },
                    onEditTrack: editTrack,
                    onEditAlbum: editAlbum
                )
            } else {
                AlbumGrid(
                    albums: albums,
                    selectedAlbumID: $selectedAlbumID,
                    onEditAlbum: editAlbum
                )
            }
        case .artists:
            if let artist = selectedArtist {
                ArtistDetail(
                    artist: artist,
                    onBack: { selectedArtistID = nil },
                    onSelectAlbum: { album in
                        selectedAlbumID = album.id
                        library.selectedSection = .albums
                    },
                    onEditTrack: editTrack,
                    onEditAlbum: editAlbum
                )
            } else {
                ArtistBrowser(
                    artists: artists,
                    selectedArtistID: $selectedArtistID
                )
            }
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

    private var albums: [AlbumGroup] {
        AlbumGroup.makeGroups(from: library.filteredTracks)
    }

    private var selectedAlbum: AlbumGroup? {
        guard let selectedAlbumID else { return nil }
        return albums.first { $0.id == selectedAlbumID }
    }

    private var artists: [ArtistGroup] {
        ArtistGroup.makeGroups(from: library.filteredTracks)
    }

    private var selectedArtist: ArtistGroup? {
        guard let selectedArtistID else { return nil }
        return artists.first { $0.id == selectedArtistID }
    }

    private var trackTable: some View {
        Table(sortedTracks, selection: $library.selectedTrackID, sortOrder: $sortOrder) {
            TableColumn(L10n.text("column.title"), value: \.title) { track in
                HStack(spacing: 10) {
                    Image(systemName: player.currentTrack?.id == track.id && player.isPlaying ? "speaker.wave.2.fill" : "music.note")
                        .trackTableForeground(
                            isSelected: library.selectedTrackID == track.id,
                            fallback: player.currentTrack?.id == track.id
                                ? AppTheme.accent : AppTheme.secondaryInk
                        )
                        .frame(width: 16)
                    Text(track.title)
                        .trackTableForeground(
                            isSelected: library.selectedTrackID == track.id,
                            fallback: AppTheme.ink
                        )
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0).onChanged { _ in
                        library.selectedTrackID = track.id
                    }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        library.selectedTrackID = track.id
                        player.play(track)
                    }
                )
                .contextMenu {
                    Button(L10n.text("track.play")) { player.play(track) }
                    PlaybackQueueContextActions(tracks: [track])
                    Button(L10n.text("metadataEditor.track.menu")) { editTrack(track) }
                    Divider()
                    Button(L10n.text("track.reveal")) { library.reveal(track) }
                }
            }
            .width(min: 240, ideal: 300)

            TableColumn(L10n.text("column.artist"), value: \.artist) { track in
                Text(track.artist).lineLimit(1)
            }
            .width(min: 130, ideal: 180)

            TableColumn(L10n.text("column.album"), value: \.album) { track in
                Text(track.album)
                    .lineLimit(1)
                    .contextMenu {
                        if let album = albums.first(where: {
                            $0.name == track.album && $0.artist == track.artist
                        }) {
                            Button(L10n.text("metadataEditor.album.menu")) {
                                editAlbum(album)
                            }
                        }
                    }
            }
            .width(min: 150, ideal: 200)

            TableColumn(L10n.text("column.duration")) { track in
                Text(DurationFormatter.string(track.duration))
                    .font(.callout.monospacedDigit())
            }
            .width(min: 68, ideal: 76)

            TableColumn(L10n.text("column.health")) { track in
                HealthLabel(
                    health: track.health,
                    compact: true,
                    isSelected: library.selectedTrackID == track.id
                )
            }
            .width(min: 64, ideal: 72)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay(alignment: .topTrailing) {
            if isSortingTracks {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("library.sorting"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryInk)
                }
                .padding(.horizontal, AppTheme.spaceSM)
                .frame(height: 30)
                .background(.regularMaterial, in: Capsule())
                .padding(AppTheme.spaceSM)
                .allowsHitTesting(false)
            }
        }
        .task(id: trackSortRequest) {
            startTrackSort()
        }
        .onDisappear {
            trackSortTask?.cancel()
            trackSortTask = nil
        }
    }

    private func editTrack(_ track: Track) {
        metadataEditTarget = .track(track)
    }

    private func editAlbum(_ album: AlbumGroup) {
        metadataEditTarget = .album(
            id: album.id,
            name: album.name,
            artist: album.artist,
            trackIDs: album.tracks.map(\.id)
        )
    }

    private var trackSortRequest: TrackSortRequest {
        TrackSortRequest(
            contentRevision: library.contentRevision,
            section: library.selectedSection,
            searchText: library.searchText,
            rules: sortOrder.compactMap(TrackSortRule.init)
        )
    }

    private func startTrackSort() {
        trackSortTask?.cancel()

        let sourceTracks = library.filteredTracks
        let rules = trackSortRequest.rules
        let request = trackSortRequest
        let generation = UUID()
        trackSortGeneration = generation
        isSortingTracks = true

        trackSortTask = Task.detached(priority: .userInitiated) {
            let result = sourceTracks.sorted { lhs, rhs in
                guard !Task.isCancelled else { return false }
                return TrackSortRule.areInIncreasingOrder(lhs, rhs, using: rules)
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard request == trackSortRequest,
                      generation == trackSortGeneration else { return }
                sortedTracks = result
                isSortingTracks = false
                trackSortTask = nil
            }
        }
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

private struct TrackSortRequest: Hashable, Sendable {
    let contentRevision: Int
    let section: LibrarySection
    let searchText: String
    let rules: [TrackSortRule]
}

private struct TrackSortRule: Hashable, Sendable {
    enum Field: Hashable, Sendable {
        case title
        case artist
        case album
    }

    let field: Field
    let isAscending: Bool

    init?(_ comparator: KeyPathComparator<Track>) {
        if comparator.keyPath == \Track.title {
            field = .title
        } else if comparator.keyPath == \Track.artist {
            field = .artist
        } else if comparator.keyPath == \Track.album {
            field = .album
        } else {
            return nil
        }
        isAscending = comparator.order == .forward
    }

    static func areInIncreasingOrder(
        _ lhs: Track,
        _ rhs: Track,
        using rules: [TrackSortRule]
    ) -> Bool {
        let effectiveRules = rules.isEmpty
            ? [TrackSortRule(field: .title, isAscending: true)]
            : rules

        for rule in effectiveRules {
            let comparison = rule.compare(lhs, rhs)
            guard comparison != .orderedSame else { continue }
            return rule.isAscending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }

        let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private init(field: Field, isAscending: Bool) {
        self.field = field
        self.isAscending = isAscending
    }

    private func compare(_ lhs: Track, _ rhs: Track) -> ComparisonResult {
        switch field {
        case .title:
            lhs.title.localizedStandardCompare(rhs.title)
        case .artist:
            lhs.artist.localizedStandardCompare(rhs.artist)
        case .album:
            lhs.album.localizedStandardCompare(rhs.album)
        }
    }
}

private struct AlbumGroup: Identifiable {
    let id: UUID
    let name: String
    let artist: String
    let tracks: [Track]

    var sortedTracks: [Track] {
        tracks.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    static func makeGroups(from tracks: [Track]) -> [AlbumGroup] {
        let groups = Dictionary(grouping: tracks, by: \.albumID)
        return groups.values.compactMap { group in
            guard let first = group.first else { return nil }
            return AlbumGroup(
                id: first.albumID,
                name: first.album,
                artist: first.artist,
                tracks: group
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct ArtistGroup: Identifiable {
    let id: UUID
    let name: String
    let tracks: [Track]
    var albumCount: Int { Set(tracks.map(\.albumID)).count }

    var sortedTracks: [Track] {
        tracks.sorted {
            let albumComparison = $0.album.localizedStandardCompare($1.album)
            if albumComparison != .orderedSame { return albumComparison == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var albums: [AlbumGroup] {
        AlbumGroup.makeGroups(from: tracks)
    }

    static func makeGroups(from tracks: [Track]) -> [ArtistGroup] {
        Dictionary(grouping: tracks, by: \.artistID).compactMap { artistID, songs in
            guard let artist = songs.first?.artist else { return nil }
            return ArtistGroup(id: artistID, name: artist, tracks: songs)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum AlbumTitleGrouping {
    static let miscellaneousInitial = "#"

    static func initial(for title: String, locale: Locale = .current) -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
        guard let firstCharacter = normalized.first else { return miscellaneousInitial }
        let initial = String(firstCharacter)
        guard initial.unicodeScalars.contains(where: CharacterSet.letters.contains) else {
            return miscellaneousInitial
        }
        return initial.uppercased(with: locale)
    }

    static func ordered(_ initials: some Sequence<String>, locale: Locale = .current) -> [String] {
        initials.sorted { lhs, rhs in
            if lhs == miscellaneousInitial { return false }
            if rhs == miscellaneousInitial { return true }
            return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                == .orderedAscending
        }
    }
}

private struct AlbumGrid: View {
    private struct AlbumSection: Identifiable {
        let initial: String
        let albums: [AlbumGroup]
        var id: String { initial }
    }

    let albums: [AlbumGroup]
    @Binding var selectedAlbumID: AlbumGroup.ID?
    let onEditAlbum: (AlbumGroup) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.spaceLG, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        LazyVGrid(columns: columns, spacing: AppTheme.spaceLG) {
                            ForEach(section.albums) { album in
                                albumCard(album)
                            }
                        }
                        .padding(.horizontal, AppTheme.spaceLG)
                    } header: {
                        HStack(spacing: AppTheme.spaceSM) {
                            Text(section.initial)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(AppTheme.ink)
                                .accessibilityAddTraits(.isHeader)

                            Rectangle()
                                .fill(AppTheme.rule)
                                .frame(height: 1)
                        }
                        .padding(.horizontal, AppTheme.spaceLG)
                        .padding(.vertical, AppTheme.spaceXS)
                        .background(AppTheme.canvas)
                    }
                }
            }
            .padding(.vertical, AppTheme.spaceMD)
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: AppTheme.spaceLG)]
    }

    private var sections: [AlbumSection] {
        let grouped = Dictionary(grouping: albums) {
            AlbumTitleGrouping.initial(for: $0.name)
        }
        return AlbumTitleGrouping.ordered(grouped.keys).compactMap { initial in
            guard let albums = grouped[initial] else { return nil }
            return AlbumSection(initial: initial, albums: albums)
        }
    }

    private func albumCard(_ album: AlbumGroup) -> some View {
        Button {
            selectedAlbumID = album.id
        } label: {
            VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                GeometryReader { geometry in
                    ArtworkThumbnail(
                        tracks: album.tracks,
                        subject: .album(name: album.name, artist: album.artist),
                        shape: .roundedRectangle,
                        fallbackSymbol: "square.stack.3d.up.fill",
                        fallbackLetter: String(album.name.prefix(1)).uppercased(),
                        onEditAlbum: { onEditAlbum(album) }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .aspectRatio(1, contentMode: .fit)

                Text(album.name)
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)

                Text(album.artist)
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)

                Text(L10n.format("album.songCount", album.tracks.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryInk)
                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(album.name), \(album.artist)")
        .contextMenu {
            PlaybackQueueContextActions(tracks: album.sortedTracks)
            Divider()
            Button(L10n.text("metadataEditor.album.menu")) {
                onEditAlbum(album)
            }
        }
    }
}

private struct AlbumDetail: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController

    let album: AlbumGroup
    let onBack: () -> Void
    let onEditTrack: (Track) -> Void
    let onEditAlbum: (AlbumGroup) -> Void

    var body: some View {
        VStack(spacing: 0) {
            albumHeader

            Divider()
                .overlay(AppTheme.rule)

            trackTable
        }
        .background(AppTheme.canvas)
    }

    private var albumHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            Button(action: onBack) {
                Label(L10n.text("album.back"), systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.secondaryInk)

            HStack(alignment: .bottom, spacing: AppTheme.spaceLG) {
                ArtworkThumbnail(
                    tracks: album.tracks,
                    subject: .album(name: album.name, artist: album.artist),
                    shape: .roundedRectangle,
                    fallbackSymbol: "square.stack.3d.up.fill",
                    fallbackLetter: String(album.name.prefix(1)).uppercased(),
                    onEditAlbum: { onEditAlbum(album) }
                )
                .frame(width: 168, height: 168)
                .shadow(color: .black.opacity(0.16), radius: 14, y: 7)

                VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                    Text(album.name)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(album.artist)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(AppTheme.secondaryInk)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(L10n.format("album.songCount", album.tracks.count))
                        Text("·")
                        Text(DurationFormatter.string(album.totalDuration))
                    }
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryInk)

                    Button {
                        guard let firstTrack = album.sortedTracks.first else { return }
                        library.selectedTrackID = firstTrack.id
                        player.play(firstTrack)
                    } label: {
                        Label(L10n.text("album.play"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(album.tracks.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    PlaybackQueueContextActions(tracks: album.sortedTracks)
                    Divider()
                    Button(L10n.text("metadataEditor.album.menu")) {
                        onEditAlbum(album)
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.spaceLG)
        .padding(.top, AppTheme.spaceXS)
        .padding(.bottom, AppTheme.spaceLG)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var trackTable: some View {
        Table(album.sortedTracks, selection: $library.selectedTrackID) {
            TableColumn(L10n.text("column.title")) { track in
                HStack(spacing: 10) {
                    Image(systemName: player.currentTrack?.id == track.id && player.isPlaying ? "speaker.wave.2.fill" : "music.note")
                        .trackTableForeground(
                            isSelected: library.selectedTrackID == track.id,
                            fallback: player.currentTrack?.id == track.id
                                ? AppTheme.accent : AppTheme.secondaryInk
                        )
                        .frame(width: 16)
                    Text(track.title)
                        .trackTableForeground(
                            isSelected: library.selectedTrackID == track.id,
                            fallback: AppTheme.ink
                        )
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0).onChanged { _ in
                        library.selectedTrackID = track.id
                    }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        library.selectedTrackID = track.id
                        player.play(track)
                    }
                )
                .contextMenu {
                    Button(L10n.text("track.play")) { player.play(track) }
                    PlaybackQueueContextActions(tracks: [track])
                    Button(L10n.text("metadataEditor.track.menu")) { onEditTrack(track) }
                    Divider()
                    Button(L10n.text("track.reveal")) { library.reveal(track) }
                }
            }
            .width(min: 260, ideal: 380)

            TableColumn(L10n.text("column.duration")) { track in
                Text(DurationFormatter.string(track.duration))
                    .font(.callout.monospacedDigit())
            }
            .width(min: 68, ideal: 76)

            TableColumn(L10n.text("column.health")) { track in
                HealthLabel(
                    health: track.health,
                    compact: true,
                    isSelected: library.selectedTrackID == track.id
                )
            }
            .width(min: 64, ideal: 72)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .padding(.bottom, AppTheme.spaceMD)
    }
}

private struct ArtistBrowser: View {
    let artists: [ArtistGroup]
    @Binding var selectedArtistID: ArtistGroup.ID?

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ArtistInitialIndex(
                    targetByInitial: targetByInitial,
                    onSelect: { artistID in
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(artistID, anchor: .top)
                        }
                    }
                )

                Divider()
                    .overlay(AppTheme.rule)

                List {
                    ForEach(artists) { artist in
                        Button {
                            selectedArtistID = artist.id
                        } label: {
                            HStack(spacing: AppTheme.spaceMD) {
                                ArtworkThumbnail(
                                    tracks: artist.tracks,
                                    subject: .artist(name: artist.name),
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
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.secondaryInk)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 6)
                        .id(artist.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var targetByInitial: [String: ArtistGroup.ID] {
        var result: [String: ArtistGroup.ID] = [:]
        for artist in artists {
            guard let initial = ArtistInitialIndex.initial(for: artist.name),
                  result[initial] == nil else { continue }
            result[initial] = artist.id
        }
        return result
    }
}

private struct ArtistInitialIndex: View {
    private static let japaneseRows = ["あ", "か", "さ", "た", "な", "は", "ま", "や", "ら", "わ", "ん"]
    private static let latinRows = (65...90).compactMap(UnicodeScalar.init).map(String.init)
    private static let numberRows = (0...9).map(String.init)
    private static let allInitials = japaneseRows + latinRows + numberRows

    let targetByInitial: [String: ArtistGroup.ID]
    let onSelect: (ArtistGroup.ID) -> Void

    var body: some View {
        GeometryReader { geometry in
            let rowHeight = max(8, geometry.size.height / CGFloat(Self.allInitials.count))

            VStack(spacing: 0) {
                ForEach(Self.allInitials, id: \.self) { initial in
                    let target = targetByInitial[initial]
                    Button {
                        if let target { onSelect(target) }
                    } label: {
                        Text(initial)
                            .font(.system(size: min(9, rowHeight * 0.72), weight: .semibold, design: .rounded))
                            .foregroundStyle(target == nil ? AppTheme.rule : AppTheme.secondaryInk)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(target == nil)
                    .frame(height: rowHeight)
                    .accessibilityLabel(L10n.format("artist.index.jump", initial))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: 26)
        .padding(.vertical, 4)
        .background(AppTheme.raised.opacity(0.35))
    }

    static func initial(for artistName: String) -> String? {
        let trimmed = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let widthFolded = trimmed.folding(
            options: [.widthInsensitive, .caseInsensitive],
            locale: Locale(identifier: "ja_JP")
        )
        guard let firstCharacter = widthFolded.first else { return nil }
        let first = String(firstCharacter)

        if let scalar = first.unicodeScalars.first {
            let value = scalar.value
            if (65...90).contains(value) { return first.uppercased() }
            if (97...122).contains(value), let uppercase = UnicodeScalar(value - 32) {
                return String(uppercase)
            }
            if (48...57).contains(value) { return first }
        }

        let hiragana = first.applyingTransform(.hiraganaToKatakana, reverse: true) ?? first
        for (row, characters) in kanaRows where characters.contains(hiragana) {
            return row
        }
        return nil
    }

    private static let kanaRows: [(String, String)] = [
        ("あ", "あいうえおぁぃぅぇぉ"),
        ("か", "かきくけこがぎぐげご"),
        ("さ", "さしすせそざじずぜぞ"),
        ("た", "たちつてとだぢづでどっ"),
        ("な", "なにぬねの"),
        ("は", "はひふへほばびぶべぼぱぴぷぺぽ"),
        ("ま", "まみむめも"),
        ("や", "やゆよゃゅょ"),
        ("ら", "らりるれろ"),
        ("わ", "わをゎ"),
        ("ん", "ん")
    ]
}

private struct ArtistDetail: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController

    let artist: ArtistGroup
    let onBack: () -> Void
    let onSelectAlbum: (AlbumGroup) -> Void
    let onEditTrack: (Track) -> Void
    let onEditAlbum: (AlbumGroup) -> Void

    var body: some View {
        VStack(spacing: 0) {
            artistHeader

            Divider()
                .overlay(AppTheme.rule)

            albumStrip

            Divider()
                .overlay(AppTheme.rule)

            trackTable
        }
        .background(AppTheme.canvas)
    }

    private var artistHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            Button(action: onBack) {
                Label(L10n.text("artist.back"), systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.secondaryInk)

            HStack(spacing: AppTheme.spaceLG) {
                ArtworkThumbnail(
                    tracks: artist.tracks,
                    subject: .artist(name: artist.name),
                    shape: .circle,
                    fallbackSymbol: "person.crop.circle.fill",
                    fallbackLetter: String(artist.name.prefix(1)).uppercased()
                )
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.14), radius: 12, y: 6)

                VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                    Text(artist.name)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(L10n.format("artist.summary", artist.albumCount, artist.tracks.count))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryInk)

                    Button {
                        guard let firstTrack = artist.sortedTracks.first else { return }
                        library.selectedTrackID = firstTrack.id
                        player.play(firstTrack)
                    } label: {
                        Label(L10n.text("artist.play"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(artist.tracks.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, AppTheme.spaceLG)
        .padding(.top, AppTheme.spaceXS)
        .padding(.bottom, AppTheme.spaceMD)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var albumStrip: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text("artist.albums"))
                .font(.headline)
                .foregroundStyle(AppTheme.ink)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: AppTheme.spaceMD) {
                    ForEach(artist.albums) { album in
                        Button {
                            onSelectAlbum(album)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkThumbnail(
                                    tracks: album.tracks,
                                    subject: .album(name: album.name, artist: album.artist),
                                    shape: .roundedRectangle,
                                    fallbackSymbol: "square.stack.3d.up.fill",
                                    fallbackLetter: String(album.name.prefix(1)).uppercased(),
                                    onEditAlbum: { onEditAlbum(album) }
                                )
                                .frame(width: 88, height: 88)

                                Text(album.name)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(AppTheme.ink)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(width: 120, height: 36, alignment: .topLeading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            PlaybackQueueContextActions(tracks: album.sortedTracks)
                            Divider()
                            Button(L10n.text("metadataEditor.album.menu")) {
                                onEditAlbum(album)
                            }
                        }
                    }
                }
                .padding(.bottom, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, AppTheme.spaceLG)
        .padding(.vertical, AppTheme.spaceMD)
        .frame(height: 196, alignment: .top)
    }

    private var trackTable: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
            Text(L10n.text("artist.songs"))
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .padding(.horizontal, AppTheme.spaceLG)
                .padding(.top, AppTheme.spaceSM)

            Table(artist.sortedTracks, selection: $library.selectedTrackID) {
                TableColumn(L10n.text("column.title")) { track in
                    HStack(spacing: 10) {
                        Image(systemName: player.currentTrack?.id == track.id && player.isPlaying ? "speaker.wave.2.fill" : "music.note")
                            .trackTableForeground(
                                isSelected: library.selectedTrackID == track.id,
                                fallback: player.currentTrack?.id == track.id
                                    ? AppTheme.accent : AppTheme.secondaryInk
                            )
                            .frame(width: 16)
                        Text(track.title)
                            .trackTableForeground(
                                isSelected: library.selectedTrackID == track.id,
                                fallback: AppTheme.ink
                            )
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0).onChanged { _ in
                            library.selectedTrackID = track.id
                        }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            library.selectedTrackID = track.id
                            player.play(track)
                        }
                    )
                    .contextMenu {
                        Button(L10n.text("track.play")) { player.play(track) }
                        PlaybackQueueContextActions(tracks: [track])
                        Button(L10n.text("metadataEditor.track.menu")) { onEditTrack(track) }
                        Divider()
                        Button(L10n.text("track.reveal")) { library.reveal(track) }
                    }
                }
                .width(min: 220, ideal: 300)

                TableColumn(L10n.text("column.album")) { track in
                    Text(track.album)
                        .lineLimit(1)
                        .contextMenu {
                            if let album = artist.albums.first(where: {
                                $0.name == track.album && $0.artist == track.artist
                            }) {
                                Button(L10n.text("metadataEditor.album.menu")) {
                                    onEditAlbum(album)
                                }
                            }
                        }
                }
                .width(min: 150, ideal: 210)

                TableColumn(L10n.text("column.duration")) { track in
                    Text(DurationFormatter.string(track.duration))
                        .font(.callout.monospacedDigit())
                }
                .width(min: 68, ideal: 76)

                TableColumn(L10n.text("column.health")) { track in
                    HealthLabel(
                        health: track.health,
                        compact: true,
                        isSelected: library.selectedTrackID == track.id
                    )
                }
                .width(min: 64, ideal: 72)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: AppTheme.spaceLG)
            }
        }
        .padding(.bottom, AppTheme.spaceSM)
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
