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

private struct TrackPlaybackAttributeActions: View {
    @EnvironmentObject private var library: LibraryStore
    let track: Track

    var body: some View {
        Button {
            Task { await library.setPinned(!track.isPinned, for: track.id) }
        } label: {
            Label(
                L10n.text(track.isPinned ? "track.pin.remove" : "track.pin.add"),
                systemImage: track.isPinned ? "pin.slash" : "pin"
            )
        }

        Button {
            Task { await library.setFavorite(!track.isFavorite, for: track.id) }
        } label: {
            Label(
                L10n.text(track.isFavorite ? "track.favorite.remove" : "track.favorite.add"),
                systemImage: track.isFavorite ? "heart.slash" : "heart"
            )
        }

        Menu {
            Button {
                Task { await library.setRating(0, for: track.id) }
            } label: {
                if track.rating == 0 {
                    Label(L10n.text("track.rating.none"), systemImage: "checkmark")
                } else {
                    Text(L10n.text("track.rating.none"))
                }
            }
            Divider()
            ForEach(1...5, id: \.self) { rating in
                Button {
                    Task { await library.setRating(rating, for: track.id) }
                } label: {
                    let stars = String(repeating: "★", count: rating)
                    if track.rating == rating {
                        Label(stars, systemImage: "checkmark")
                    } else {
                        Text(stars)
                    }
                }
            }
        } label: {
            Label(L10n.text("track.rating.title"), systemImage: "star")
        }

        Button {
            Task {
                await library.setExcludedFromPlayback(
                    !track.isExcludedFromPlayback,
                    for: track.id
                )
            }
        } label: {
            Label(
                L10n.text(
                    track.isExcludedFromPlayback
                        ? "track.playback.include" : "track.playback.exclude"
                ),
                systemImage: track.isExcludedFromPlayback ? "checkmark.circle" : "minus.circle"
            )
        }
    }
}

private struct TrackPlaylistContextActions: View {
    @EnvironmentObject private var library: LibraryStore
    let trackIDs: Set<Track.ID>

    var body: some View {
        Menu {
            if library.playlists.isEmpty {
                Text(L10n.text("playlist.none"))
            } else {
                ForEach(library.playlists.filter { $0.smartDefinition == nil }) { playlist in
                    let containsAll = trackIDs.isSubset(
                        of: Set(playlist.entries.map(\.trackID))
                    )
                    Button {
                        Task { try? await library.addTracks(Array(trackIDs), to: playlist.id) }
                    } label: {
                        Label(
                            playlist.name,
                            systemImage: containsAll ? "checkmark" : "music.note.list"
                        )
                    }
                    .disabled(containsAll)
                }
            }
        } label: {
            Label(L10n.text("playlist.addTo"), systemImage: "text.badge.plus")
        }

        Menu {
            let memberships = library.playlistsContaining(trackIDs: trackIDs)
            if memberships.isEmpty {
                Text(L10n.text("playlist.membership.none"))
            } else {
                ForEach(memberships) { playlist in
                    Button {
                        library.selectedPlaylistID = playlist.id
                        library.selectedTrackID = trackIDs.first
                    } label: {
                        Label(playlist.name, systemImage: "checkmark")
                    }
                }
            }
        } label: {
            Label(L10n.text("playlist.membership"), systemImage: "music.note.list")
        }

        if let playlistID = library.selectedPlaylistID,
           library.selectedPlaylist?.smartDefinition == nil {
            Button(role: .destructive) {
                Task { try? await library.removeTracks(trackIDs, from: playlistID) }
            } label: {
                Label(L10n.text("playlist.removeSelected"), systemImage: "minus")
            }
        }
    }
}

struct LibraryContent: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var trackTableSettings: TrackTableSettings
    @State private var sortOrder = [KeyPathComparator(\Track.title)]
    @State private var sortedTracks: [Track] = []
    @State private var tableSelectedTrackIDs: Set<Track.ID> = []
    @State private var isSortingTracks = false
    @State private var trackSortTask: Task<Void, Never>?
    @State private var trackSortGeneration = UUID()
    @State private var selectedAlbumID: AlbumGroup.ID?
    @State private var selectedArtistID: ArtistGroup.ID?
    @State private var metadataEditTarget: MetadataEditTarget?
    @State private var isShowingFilters = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if library.selectedPlaylist?.smartDefinition != nil
                && library.filteredTracks.isEmpty {
                smartPlaylistEmptyView
            } else if library.selectedPlaylist != nil && library.filteredTracks.isEmpty {
                playlistEmptyView
            } else if library.selectedPlaylist == nil && library.selectedSection == .effects {
                sectionContent
            } else if library.filteredTracks.isEmpty {
                if library.tracks.isEmpty || !library.searchText.isEmpty
                    || library.filterCriteria.activeCount > 0 {
                    EmptyLibraryView(hasTracks: !library.tracks.isEmpty)
                } else {
                    standardSectionEmptyView
                }
            } else {
                sectionContent
            }

            activityBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.canvas)
        .navigationTitle(contentTitle)
        .searchable(text: $library.searchText, placement: .toolbar, prompt: L10n.text("library.search"))
        .sheet(item: $metadataEditTarget) { target in
            MetadataEditorView(target: target)
                .environmentObject(library)
        }
        .onChange(of: library.selectedSection) { _, section in
            restoreSavedSortOrder(for: section)
        }
        .onChange(of: sortOrder) { _, updatedSortOrder in
            persistSortOrder(updatedSortOrder)
        }
        .onAppear {
            restoreSavedSortOrder(for: library.selectedSection)
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        if library.selectedPlaylist != nil {
            trackTable
        } else {
            sectionContentForLibrary
        }
    }

    @ViewBuilder
    private var sectionContentForLibrary: some View {
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
                    onEditAlbum: editAlbum,
                    onEditArtist: editArtist
                )
            } else {
                ArtistBrowser(
                    artists: artists,
                    selectedArtistID: $selectedArtistID,
                    onEditArtist: editArtist
                )
            }
        case .songs, .pinned, .recentlyAdded, .frequentlyPlayed, .recentlyPlayed,
             .favorites, .needsAttention:
            trackTable
        case .duplicates:
            DuplicateLibraryView(groups: library.filteredDuplicateGroups)
        case .effects:
            EffectsRackView()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: AppTheme.spaceMD) {
            if let playlist = library.selectedPlaylist,
               let path = playlist.artworkPath,
               let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(
                        cornerRadius: AppTheme.radiusSmall,
                        style: .continuous
                    ))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(contentTitle)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                if let playlist = library.selectedPlaylist,
                   !playlist.description.isEmpty {
                    Text(playlist.description)
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryInk)
                        .lineLimit(2)
                } else {
                    Text(headerSubtitle)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryInk)
                }
            }
            Spacer()
            if library.selectedSection != .effects {
                Button {
                    isShowingFilters.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: library.filterCriteria.activeCount > 0
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                        if library.filterCriteria.activeCount > 0 {
                            Text("\(library.filterCriteria.activeCount)")
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
                .buttonStyle(.bordered)
                .help(L10n.text("filters.button.help"))
                .accessibilityLabel(L10n.text("filters.button"))
                .popover(isPresented: $isShowingFilters, arrowEdge: .bottom) {
                    LibraryFilterView()
                        .environmentObject(library)
                }
            }
        }
        .padding(.horizontal, AppTheme.spaceLG)
        .padding(.top, AppTheme.spaceMD)
        .padding(.bottom, AppTheme.spaceSM)
    }

    private var headerSubtitle: String {
        if library.selectedPlaylist == nil && library.selectedSection == .effects {
            return L10n.format("effects.enabledCount", player.enabledEffectCount, player.effectSettings.count)
        }
        return L10n.format("library.visibleCount", library.filteredTracks.count)
    }

    private var contentTitle: String {
        library.selectedPlaylist?.name ?? L10n.text(library.selectedSection.titleKey)
    }

    private var playlistEmptyView: some View {
        VStack(spacing: AppTheme.spaceLG) {
            Image(systemName: "music.note.list")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 68, height: 68)
                .background(AppTheme.accent.opacity(0.1))
                .clipShape(RoundedRectangle(
                    cornerRadius: AppTheme.radiusMedium,
                    style: .continuous
                ))

            VStack(spacing: AppTheme.spaceXS) {
                Text(L10n.text("playlist.empty.title"))
                    .font(.title2.bold())
                    .foregroundStyle(AppTheme.ink)
                Text(L10n.text("playlist.empty.description"))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                library.selectedPlaylistID = nil
                library.selectedSection = .songs
            } label: {
                Label(L10n.text("playlist.empty.chooseSongs"), systemImage: "music.note")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text(L10n.text("playlist.empty.dropHint"))
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, AppTheme.spaceLG)
        .padding(.vertical, 32)
        .frame(maxWidth: 440)
        .background(AppTheme.raised)
        .clipShape(RoundedRectangle(
            cornerRadius: AppTheme.radiusLarge,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.radiusLarge, style: .continuous)
                .strokeBorder(AppTheme.ink.opacity(0.07))
        }
        .shadow(color: .black.opacity(0.05), radius: 18, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, AppTheme.spaceLG)
        .padding(.top, 56)
        .padding(.bottom, AppTheme.spaceLG)
    }

    private var smartPlaylistEmptyView: some View {
        ContentUnavailableView(
            L10n.text("smartPlaylist.empty.title"),
            systemImage: "gearshape.2",
            description: Text(L10n.text("smartPlaylist.empty.description"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var standardSectionEmptyView: some View {
        ContentUnavailableView(
            L10n.text("empty.standard.\(library.selectedSection.rawValue).title"),
            systemImage: library.selectedSection.systemImage,
            description: Text(
                L10n.text("empty.standard.\(library.selectedSection.rawValue).body")
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AppTheme.spaceMD)
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
        Table(sortedTracks, selection: $tableSelectedTrackIDs, sortOrder: $sortOrder) {
            TableColumn(L10n.text("column.title"), value: \.title) { track in
                HStack(spacing: 10) {
                    Image(systemName: player.currentTrack?.id == track.id && player.isPlaying ? "speaker.wave.2.fill" : "music.note")
                        .trackTableForeground(
                            isSelected: library.selectedTrackIDs.contains(track.id),
                            fallback: player.currentTrack?.id == track.id
                                ? AppTheme.accent : AppTheme.secondaryInk
                        )
                        .frame(width: 16)
                        .draggable(dragPayload(for: track))
                    Text(track.title)
                        .lineLimit(1)
                    if track.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .trackTableForeground(
                                isSelected: library.selectedTrackIDs.contains(track.id),
                                fallback: AppTheme.secondaryInk
                            )
                            .accessibilityLabel(L10n.text("sidebar.pinned"))
                    }
                    if track.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .trackTableForeground(
                                isSelected: library.selectedTrackIDs.contains(track.id),
                                fallback: AppTheme.accent
                            )
                            .accessibilityLabel(L10n.text("track.favorite"))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(trackCellSelectionGesture(for: track.id))
                .simultaneousGesture(trackCellPlaybackGesture(for: track))
                .dropDestination(for: String.self) { payloads, location in
                    guard let playlistID = library.selectedPlaylistID,
                          library.selectedPlaylist?.smartDefinition == nil else { return false }
                    let trackIDs = orderedUniqueTrackIDs(payloads.flatMap(parseTrackIDs))
                    guard !trackIDs.isEmpty, !trackIDs.contains(track.id) else { return false }
                    let targetTrackID = location.y > 14 ? trackID(after: track.id) : track.id
                    Task {
                        try? await library.moveTracks(
                            trackIDs,
                            before: targetTrackID,
                            in: playlistID
                        )
                    }
                    return true
                } isTargeted: { _ in }
            }
            .width(min: 240, ideal: 300)

            TableColumn(columnTitle(.artist), value: \.artist) { track in
                HStack(spacing: 0) {
                    Text(track.artist).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(trackCellSelectionGesture(for: track.id))
                .simultaneousGesture(trackCellPlaybackGesture(for: track))
                .opacity(columnOpacity(.artist))
            }
            .width(
                min: collapsedWidth(.artist, visible: 130),
                ideal: collapsedWidth(.artist, visible: 180),
                max: collapsedMaximumWidth(.artist)
            )

            TableColumn(columnTitle(.album), value: \.album) { track in
                HStack(spacing: 0) {
                    Text(track.album).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(trackCellSelectionGesture(for: track.id))
                .simultaneousGesture(trackCellPlaybackGesture(for: track))
                .opacity(columnOpacity(.album))
            }
            .width(
                min: collapsedWidth(.album, visible: 150),
                ideal: collapsedWidth(.album, visible: 200),
                max: collapsedMaximumWidth(.album)
            )

            TableColumn(columnTitle(.duration)) { track in
                HStack(spacing: 0) {
                    Text(DurationFormatter.string(track.duration))
                        .font(.callout.monospacedDigit())
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(trackCellSelectionGesture(for: track.id))
                .simultaneousGesture(trackCellPlaybackGesture(for: track))
                .opacity(columnOpacity(.duration))
            }
            .width(
                min: collapsedWidth(.duration, visible: 68),
                ideal: collapsedWidth(.duration, visible: 76),
                max: collapsedMaximumWidth(.duration)
            )

            TableColumn(columnTitle(.health)) { track in
                HStack(spacing: 0) {
                    HealthLabel(
                        health: track.health,
                        compact: true,
                        isSelected: library.selectedTrackIDs.contains(track.id)
                    )
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(trackCellSelectionGesture(for: track.id))
                .simultaneousGesture(trackCellPlaybackGesture(for: track))
                .opacity(columnOpacity(.health))
            }
            .width(
                min: collapsedWidth(.health, visible: 64),
                ideal: collapsedWidth(.health, visible: 72),
                max: collapsedMaximumWidth(.health)
            )
        }
        .contextMenu(forSelectionType: Track.ID.self) { selection in
            trackRowContextMenu(for: selection)
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
        .onAppear {
            tableSelectedTrackIDs = library.selectedTrackIDs
        }
        .onChange(of: tableSelectedTrackIDs) { previousSelection, selection in
            let focusedID = TrackSelectionResolver.focusedTrackID(
                previousFocus: library.selectedTrackID,
                previousSelection: previousSelection,
                newSelection: selection
            )
            library.updateTrackSelection(selection, focusedID: focusedID)
        }
        .onChange(of: library.selectedTrackID) { _, focusedID in
            guard let focusedID else {
                if !tableSelectedTrackIDs.isEmpty {
                    tableSelectedTrackIDs = []
                }
                return
            }
            guard !tableSelectedTrackIDs.contains(focusedID) else { return }
            tableSelectedTrackIDs = [focusedID]
        }
    }

    private func trackCellSelectionGesture(for trackID: Track.ID) -> some Gesture {
        TapGesture(count: 1).onEnded {
            let modifiers = NSEvent.modifierFlags.intersection([.command, .shift, .control])
            guard modifiers.isEmpty else { return }
            tableSelectedTrackIDs = [trackID]
        }
    }

    private func trackCellPlaybackGesture(for track: Track) -> some Gesture {
        TapGesture(count: 2).onEnded {
            tableSelectedTrackIDs = [track.id]
            player.play(track)
        }
    }

    private func contextTrackIDs(for track: Track) -> Set<Track.ID> {
        library.selectedTrackIDs.contains(track.id) ? library.selectedTrackIDs : [track.id]
    }

    private func contextTracks(for track: Track) -> [Track] {
        let ids = contextTrackIDs(for: track)
        return sortedTracks.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private func trackRowContextMenu(for selection: Set<Track.ID>) -> some View {
        let selectedTracks = sortedTracks.filter { selection.contains($0.id) }
        if let track = selectedTracks.first {
            Button(L10n.text("track.play")) { player.play(track) }
            PlaybackQueueContextActions(tracks: selectedTracks)
            TrackPlaylistContextActions(trackIDs: selection)
            TrackPlaybackAttributeActions(track: track)
            if selectedTracks.count > 1 {
                Button(L10n.format("metadataEditor.bulk.menu", selectedTracks.count)) {
                    editTracks(selectedTracks)
                }
            } else {
                Button(L10n.text("metadataEditor.track.menu")) { editTrack(track) }
                if let album = albums.first(where: {
                    $0.name == track.album && $0.artist == track.artist
                }) {
                    Button(L10n.text("metadataEditor.album.menu")) { editAlbum(album) }
                }
                if let artist = artists.first(where: { $0.name == track.artist }) {
                    Button(L10n.text("metadataEditor.artist.menu")) { editArtist(artist) }
                }
            }
            Divider()
            Button(L10n.text("track.reveal")) { library.reveal(track) }
        }
    }

    private func dragPayload(for track: Track) -> String {
        contextTracks(for: track).map(\.id.uuidString).joined(separator: "\n")
    }

    private func parseTrackIDs(_ payload: String) -> [Track.ID] {
        payload.split(whereSeparator: \.isNewline).compactMap { UUID(uuidString: String($0)) }
    }

    private func orderedUniqueTrackIDs(_ trackIDs: [Track.ID]) -> [Track.ID] {
        var seen: Set<Track.ID> = []
        return trackIDs.filter { seen.insert($0).inserted }
    }

    private func trackID(after trackID: Track.ID) -> Track.ID? {
        guard let index = sortedTracks.firstIndex(where: { $0.id == trackID }) else {
            return nil
        }
        let nextIndex = sortedTracks.index(after: index)
        return nextIndex < sortedTracks.endIndex ? sortedTracks[nextIndex].id : nil
    }

    private func editTrack(_ track: Track) {
        metadataEditTarget = .track(track)
    }

    private func editTracks(_ tracks: [Track]) {
        metadataEditTarget = .tracks(tracks)
    }

    private func editAlbum(_ album: AlbumGroup) {
        metadataEditTarget = .album(
            id: album.id,
            name: album.name,
            artist: album.artist,
            tracks: album.tracks
        )
    }

    private func editArtist(_ artist: ArtistGroup) {
        metadataEditTarget = .artist(
            id: artist.id,
            name: artist.name,
            trackIDs: artist.tracks.map(\.id)
        )
    }

    private var trackSortRequest: TrackSortRequest {
        TrackSortRequest(
            contentRevision: library.contentRevision,
            section: library.selectedSection,
            playlistID: library.selectedPlaylistID,
            searchText: library.searchText,
            filterCriteria: library.filterCriteria,
            rules: sortOrder.compactMap(TrackSortRule.init)
        )
    }

    private func restoreSavedSortOrder(for section: LibrarySection) {
        guard !section.preservesResolvedOrder else {
            sortOrder = []
            return
        }
        let order: SortOrder = trackTableSettings.sortAscending ? .forward : .reverse
        switch trackTableSettings.sortField {
        case .title: sortOrder = [KeyPathComparator(\Track.title, order: order)]
        case .artist: sortOrder = [KeyPathComparator(\Track.artist, order: order)]
        case .album: sortOrder = [KeyPathComparator(\Track.album, order: order)]
        }
    }

    private func persistSortOrder(_ comparators: [KeyPathComparator<Track>]) {
        guard !library.selectedSection.preservesResolvedOrder,
              let comparator = comparators.first,
              let rule = TrackSortRule(comparator) else { return }
        switch rule.field {
        case .title: trackTableSettings.sortField = .title
        case .artist: trackTableSettings.sortField = .artist
        case .album: trackTableSettings.sortField = .album
        }
        trackTableSettings.sortAscending = rule.isAscending
    }

    private func columnTitle(_ column: TrackTableColumn) -> String {
        trackTableSettings.isVisible(column) ? L10n.text(column.localizationKey) : ""
    }

    private func columnOpacity(_ column: TrackTableColumn) -> Double {
        trackTableSettings.isVisible(column) ? 1 : 0
    }

    private func collapsedWidth(_ column: TrackTableColumn, visible: CGFloat) -> CGFloat {
        trackTableSettings.isVisible(column) ? visible : 0
    }

    private func collapsedMaximumWidth(_ column: TrackTableColumn) -> CGFloat? {
        trackTableSettings.isVisible(column) ? nil : 0
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
            let result: [Track]
            if request.playlistID != nil
                || (request.section.preservesResolvedOrder && request.rules.isEmpty) {
                result = sourceTracks
            } else {
                result = sourceTracks.sorted { lhs, rhs in
                    guard !Task.isCancelled else { return false }
                    return TrackSortRule.areInIncreasingOrder(lhs, rhs, using: rules)
                }
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
        case .relinking:
            statusBar(text: L10n.text("status.relinking"), progress: true, color: AppTheme.accent)
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

private struct LibraryFilterView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("filters.title"))
                        .font(.headline)
                    Text(L10n.text("filters.description"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryInk)
                }
                Spacer()
                Button(L10n.text("filters.clear")) {
                    library.filterCriteria = LibraryFilterCriteria()
                }
                .disabled(library.filterCriteria.activeCount == 0)
            }

            Grid(alignment: .leading, horizontalSpacing: AppTheme.spaceMD, verticalSpacing: 10) {
                filterTextRow("filters.artist", text: $library.filterCriteria.artist)
                filterTextRow("filters.album", text: $library.filterCriteria.album)
                filterTextRow("filters.composer", text: $library.filterCriteria.composer)
                filterTextRow("filters.genre", text: $library.filterCriteria.genre)

                GridRow {
                    filterLabel("filters.year")
                    HStack(spacing: AppTheme.spaceXS) {
                        TextField(
                            L10n.text("filters.year.minimum"),
                            text: optionalIntegerBinding(\.minimumYear)
                        )
                        .frame(width: 80)
                        Text("–").foregroundStyle(AppTheme.secondaryInk)
                        TextField(
                            L10n.text("filters.year.maximum"),
                            text: optionalIntegerBinding(\.maximumYear)
                        )
                        .frame(width: 80)
                    }
                    .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    filterLabel("filters.rating")
                    Picker("", selection: $library.filterCriteria.minimumRating) {
                        Text(L10n.text("filters.any")).tag(0)
                        ForEach(1...5, id: \.self) { rating in
                            Text(String(repeating: "★", count: rating)).tag(rating)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                GridRow {
                    filterLabel("filters.health")
                    Picker("", selection: $library.filterCriteria.health) {
                        Text(L10n.text("filters.any")).tag(nil as FileHealth?)
                        ForEach(FileHealth.allCases, id: \.self) { health in
                            Text(L10n.text(health.titleKey)).tag(Optional(health))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()

            Toggle(L10n.text("filters.favoritesOnly"), isOn: $library.filterCriteria.favoritesOnly)
            Toggle(
                L10n.text("filters.compilationsOnly"),
                isOn: $library.filterCriteria.compilationsOnly
            )

            HStack {
                Spacer()
                Text(L10n.format("filters.resultCount", library.filteredTracks.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryInk)
            }
        }
        .padding(AppTheme.spaceLG)
        .frame(width: 390)
        .background(AppTheme.canvas)
    }

    private func filterTextRow(_ key: String, text: Binding<String>) -> some View {
        GridRow {
            filterLabel(key)
            TextField(L10n.text(key), text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func filterLabel(_ key: String) -> some View {
        Text(L10n.text(key))
            .foregroundStyle(AppTheme.secondaryInk)
            .frame(width: 92, alignment: .trailing)
    }

    private func optionalIntegerBinding(
        _ keyPath: WritableKeyPath<LibraryFilterCriteria, Int?>
    ) -> Binding<String> {
        Binding(
            get: { library.filterCriteria[keyPath: keyPath].map(String.init) ?? "" },
            set: { value in
                var criteria = library.filterCriteria
                criteria[keyPath: keyPath] = Int(value.filter(\.isNumber))
                library.filterCriteria = criteria
            }
        )
    }
}

private struct DuplicateLibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    let groups: [DuplicateTrackGroup]

    @State private var keepSelections: [DuplicateTrackGroup.ID: Track.ID] = [:]
    @State private var pendingGroup: DuplicateTrackGroup?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.spaceMD) {
                ForEach(groups) { group in
                    duplicateCard(group)
                }
            }
            .padding(.horizontal, AppTheme.spaceLG)
            .padding(.vertical, AppTheme.spaceMD)
        }
        .confirmationDialog(
            L10n.text("duplicates.confirm.title"),
            isPresented: Binding(
                get: { pendingGroup != nil },
                set: { if !$0 { pendingGroup = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("duplicates.action.unregister")) {
                resolvePendingGroup(moveManagedFilesToTrash: false)
            }
            Button(L10n.text("duplicates.action.trashManaged"), role: .destructive) {
                resolvePendingGroup(moveManagedFilesToTrash: true)
            }
            Button(L10n.text("common.cancel"), role: .cancel) { pendingGroup = nil }
        } message: {
            Text(L10n.text("duplicates.confirm.message"))
        }
        .alert(
            L10n.text("duplicates.error.title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.text("common.ok")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func duplicateCard(_ group: DuplicateTrackGroup) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            HStack(spacing: AppTheme.spaceSM) {
                Label(
                    L10n.text(group.kind.titleKey),
                    systemImage: group.kind == .exact
                        ? "checkmark.seal.fill" : "questionmark.diamond.fill"
                )
                .font(.headline)
                .foregroundStyle(group.kind == .exact ? AppTheme.good : AppTheme.warning)
                Spacer()
                Text(L10n.format("duplicates.songCount", group.tracks.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            Text(L10n.text("duplicates.chooseKeep"))
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryInk)

            ForEach(group.tracks) { track in
                Button {
                    keepSelections[group.id] = track.id
                    library.selectedTrackID = track.id
                } label: {
                    HStack(alignment: .top, spacing: AppTheme.spaceSM) {
                        Image(systemName: keepID(for: group) == track.id
                            ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(keepID(for: group) == track.id
                                ? AppTheme.accent : AppTheme.secondaryInk)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: AppTheme.spaceXS) {
                                Text(track.title).fontWeight(.semibold).lineLimit(1)
                                if group.recommendedTrackID == track.id {
                                    Text(L10n.text("duplicates.recommended"))
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(AppTheme.accent.opacity(0.13), in: Capsule())
                                }
                            }
                            Text("\(track.artist) — \(track.album)")
                                .font(.callout)
                                .foregroundStyle(AppTheme.secondaryInk)
                                .lineLimit(1)
                            HStack(spacing: AppTheme.spaceMD) {
                                Text(DurationFormatter.string(track.duration))
                                Text(ByteCountFormatter.string(
                                    fromByteCount: track.fileSize,
                                    countStyle: .file
                                ))
                                Text(track.fileURL.lastPathComponent)
                                    .lineLimit(1)
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryInk)
                            Text(track.managedPath)
                                .font(.caption2.monospaced())
                                .foregroundStyle(AppTheme.secondaryInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(AppTheme.spaceSM)
                    .contentShape(Rectangle())
                    .background(
                        keepID(for: group) == track.id
                            ? AppTheme.accent.opacity(0.08) : AppTheme.raised,
                        in: RoundedRectangle(cornerRadius: AppTheme.radiusSmall)
                    )
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text(L10n.text("duplicates.filesRemainUnlessTrash"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
                Spacer()
                Button(L10n.text("duplicates.action.resolve")) {
                    pendingGroup = group
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppTheme.spaceMD)
        .ongakuPanel()
    }

    private func keepID(for group: DuplicateTrackGroup) -> Track.ID {
        keepSelections[group.id] ?? group.recommendedTrackID
    }

    private func resolvePendingGroup(moveManagedFilesToTrash: Bool) {
        guard let group = pendingGroup else { return }
        let keepID = keepID(for: group)
        pendingGroup = nil
        Task {
            do {
                _ = try await library.resolveDuplicateGroup(
                    group.id,
                    keeping: keepID,
                    moveManagedFilesToTrash: moveManagedFilesToTrash
                )
                player.reconcilePlaybackQueue(with: library.tracks)
                keepSelections[group.id] = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct TrackSortRequest: Hashable, Sendable {
    let contentRevision: Int
    let section: LibrarySection
    let playlistID: Playlist.ID?
    let searchText: String
    let filterCriteria: LibraryFilterCriteria
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
        Table(
            album.sortedTracks,
            selection: Binding(
                get: { library.selectedTrackID },
                set: { library.selectedTrackID = $0 }
            )
        ) {
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
                        .lineLimit(1)
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
        .contextMenu(forSelectionType: Track.ID.self) { selection in
            if let track = album.sortedTracks.first(where: { selection.contains($0.id) }) {
                Button(L10n.text("track.play")) { player.play(track) }
                PlaybackQueueContextActions(tracks: [track])
                TrackPlaybackAttributeActions(track: track)
                Button(L10n.text("metadataEditor.track.menu")) { onEditTrack(track) }
                Button(L10n.text("metadataEditor.album.menu")) { onEditAlbum(album) }
                Divider()
                Button(L10n.text("track.reveal")) { library.reveal(track) }
            }
        } primaryAction: { selection in
            guard let track = album.sortedTracks.first(where: { selection.contains($0.id) }) else {
                return
            }
            library.selectedTrackID = track.id
            player.play(track)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .padding(.bottom, AppTheme.spaceMD)
    }
}

private struct ArtistBrowser: View {
    let artists: [ArtistGroup]
    @Binding var selectedArtistID: ArtistGroup.ID?
    let onEditArtist: (ArtistGroup) -> Void

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
                                    fallbackLetter: String(artist.name.prefix(1)).uppercased(),
                                    onEditArtist: { onEditArtist(artist) }
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
                        .contextMenu {
                            Button(L10n.text("metadataEditor.artist.menu")) {
                                onEditArtist(artist)
                            }
                        }
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
    let onEditArtist: (ArtistGroup) -> Void

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
                    fallbackLetter: String(artist.name.prefix(1)).uppercased(),
                    onEditArtist: { onEditArtist(artist) }
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

            Table(
                artist.sortedTracks,
                selection: Binding(
                    get: { library.selectedTrackID },
                    set: { library.selectedTrackID = $0 }
                )
            ) {
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
                            .lineLimit(1)
                    }
                }
                .width(min: 220, ideal: 300)

                TableColumn(L10n.text("column.album")) { track in
                    Text(track.album)
                        .lineLimit(1)
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
            .contextMenu(forSelectionType: Track.ID.self) { selection in
                if let track = artist.sortedTracks.first(where: { selection.contains($0.id) }) {
                    Button(L10n.text("track.play")) { player.play(track) }
                    PlaybackQueueContextActions(tracks: [track])
                    TrackPlaybackAttributeActions(track: track)
                    Button(L10n.text("metadataEditor.track.menu")) { onEditTrack(track) }
                    if let album = artist.albums.first(where: {
                        $0.name == track.album && $0.artist == track.artist
                    }) {
                        Button(L10n.text("metadataEditor.album.menu")) { onEditAlbum(album) }
                    }
                    Button(L10n.text("metadataEditor.artist.menu")) {
                        onEditArtist(artist)
                    }
                    Divider()
                    Button(L10n.text("track.reveal")) { library.reveal(track) }
                }
            } primaryAction: { selection in
                guard let track = artist.sortedTracks.first(where: { selection.contains($0.id) }) else {
                    return
                }
                library.selectedTrackID = track.id
                player.play(track)
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
                Button(L10n.text("empty.clearSearchAndFilters")) {
                    library.searchText = ""
                    library.filterCriteria = LibraryFilterCriteria()
                }
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
