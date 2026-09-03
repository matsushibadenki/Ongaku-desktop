import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SidebarDestination: Hashable {
    case section(LibrarySection)
    case playlist(Playlist.ID)
}

private enum PlaylistEditorTarget: Identifiable {
    case create
    case edit(Playlist)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let playlist): playlist.id.uuidString
        }
    }
}

private enum PlaylistFolderEditorTarget: Identifiable {
    case create
    case rename(PlaylistFolder)

    var id: String {
        switch self {
        case .create: "create-folder"
        case .rename(let folder): folder.id.uuidString
        }
    }
}

private enum SmartPlaylistEditorTarget: Identifiable {
    case create
    case edit(Playlist)

    var id: String {
        switch self {
        case .create: "create-smart-playlist"
        case .edit(let playlist): "smart-\(playlist.id.uuidString)"
        }
    }
}

struct LibrarySidebar: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var libraryProfiles: LibraryProfileSettings
    @EnvironmentObject private var meterSettings: PlayerMeterSettings
    @State private var playlistEditorTarget: PlaylistEditorTarget?
    @State private var playlistPendingDeletion: Playlist?
    @State private var folderEditorTarget: PlaylistFolderEditorTarget?
    @State private var folderPendingDeletion: PlaylistFolder?
    @State private var smartPlaylistEditorTarget: SmartPlaylistEditorTarget?
    @State private var importPreview: PlaylistImportPreview?
    @State private var expandedFolderIDs: Set<PlaylistFolder.ID> = []
    @State private var errorMessage: String?
    @State private var isCreatingLibrary = false
    @State private var isCreatingExternalLibrary = false
    @State private var isRenamingLibrary = false
    @State private var isShowingLibraryProfilePopover = false
    @State private var libraryNameDraft = ""

    var body: some View {
        List(selection: sidebarSelection) {
            Section(L10n.text("libraryProfile.section")) {
                Button {
                    isShowingLibraryProfilePopover.toggle()
                } label: {
                    libraryProfileMenuLabel
                        .frame(width: 170, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isShowingLibraryProfilePopover, arrowEdge: .trailing) {
                    libraryProfilePopover
                }
                .accessibilityLabel(libraryProfiles.activeProfile.name)
            }

            Section(L10n.text("sidebar.library")) {
                ForEach([
                    LibrarySection.songs,
                    .albums,
                    .artists,
                    .pinned,
                    .recentlyAdded,
                    .frequentlyPlayed,
                    .recentlyPlayed,
                    .favorites,
                    .ongakuMix,
                ]) { section in
                    Label(L10n.text(section.titleKey), systemImage: section.systemImage)
                        .fixedSize(horizontal: true, vertical: false)
                        .tag(SidebarDestination.section(section))
                }
            }

            Section {
                ForEach(library.sortedPlaylistFolders) { folder in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedFolderIDs.contains(folder.id) },
                            set: { expanded in
                                if expanded { expandedFolderIDs.insert(folder.id) }
                                else { expandedFolderIDs.remove(folder.id) }
                            }
                        )
                    ) {
                        ForEach(library.playlists(in: folder.id)) { playlist in
                            playlistRow(playlist)
                        }
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .lineLimit(1)
                    }
                    .draggable("folder:\(folder.id.uuidString)")
                    .dropDestination(for: String.self) { payloads, location in
                        handleFolderDrop(payloads, onto: folder, insertAfter: location.y > 14)
                    } isTargeted: { _ in }
                    .contextMenu {
                        Button(L10n.text("playlistFolder.rename")) {
                            folderEditorTarget = .rename(folder)
                        }
                        Button(role: .destructive) {
                            folderPendingDeletion = folder
                        } label: {
                            Label(L10n.text("playlistFolder.delete"), systemImage: "trash")
                        }
                    }
                }

                ForEach(library.playlists(in: nil)) { playlist in
                    playlistRow(playlist)
                }
            } header: {
                HStack {
                    Text(L10n.text("sidebar.playlists"))
                        .dropDestination(for: String.self) { payloads, _ in
                            guard let playlistID = payloads.compactMap(parsePlaylistID).first else {
                                return false
                            }
                            Task { try? await library.movePlaylist(playlistID, to: nil) }
                            return true
                        } isTargeted: { _ in }
                    Spacer()
                    Menu {
                        Button {
                            playlistEditorTarget = .create
                        } label: {
                            Label(L10n.text("playlist.create"), systemImage: "music.note.list")
                        }
                        Button {
                            smartPlaylistEditorTarget = .create
                        } label: {
                            Label(
                                L10n.text("smartPlaylist.create"),
                                systemImage: "gearshape.2"
                            )
                        }
                        Button {
                            folderEditorTarget = .create
                        } label: {
                            Label(L10n.text("playlistFolder.create"), systemImage: "folder.badge.plus")
                        }
                        Divider()
                        Button(action: startPlaylistImport) {
                            Label(
                                L10n.text("playlist.transfer.import"),
                                systemImage: "square.and.arrow.down"
                            )
                        }
                    } label: {
                        Image(systemName: "plus").contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L10n.text("playlist.add"))
                    .accessibilityLabel(L10n.text("playlist.add"))
                }
            }

            Section(L10n.text("sidebar.processing")) {
                Label(
                    L10n.text(LibrarySection.effects.titleKey),
                    systemImage: LibrarySection.effects.systemImage
                )
                .fixedSize(horizontal: true, vertical: false)
                .tag(SidebarDestination.section(.effects))
            }

            Section(L10n.text("sidebar.integrity")) {
                Label {
                    HStack {
                        Text(L10n.text(LibrarySection.duplicates.titleKey))
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        if !library.duplicateGroups.isEmpty {
                            Text("\(library.duplicateGroups.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.warning)
                        }
                    }
                } icon: {
                    Image(systemName: LibrarySection.duplicates.systemImage)
                }
                .tag(SidebarDestination.section(.duplicates))

                Label {
                    HStack {
                        Text(L10n.text(LibrarySection.needsAttention.titleKey))
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        if library.attentionCount > 0 {
                            Text("\(library.attentionCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.warning)
                        }
                    }
                } icon: {
                    Image(systemName: LibrarySection.needsAttention.systemImage)
                }
                .tag(SidebarDestination.section(.needsAttention))
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                librarySummary
                if meterSettings.barPosition == .bottom {
                    Color.clear.frame(height: AppTheme.bottomPlayerClearance)
                }
            }
        }
        .navigationTitle("Ongaku")
        .sheet(item: $playlistEditorTarget) { target in
            PlaylistEditorView(target: target)
                .environmentObject(library)
        }
        .sheet(item: $folderEditorTarget) { target in
            PlaylistFolderEditorView(target: target)
                .environmentObject(library)
        }
        .sheet(item: $smartPlaylistEditorTarget) { target in
            SmartPlaylistEditorView(target: target)
                .environmentObject(library)
        }
        .sheet(item: $importPreview) { preview in
            PlaylistImportPreviewView(preview: preview)
                .environmentObject(library)
        }
        .alert(L10n.text("libraryProfile.create"), isPresented: $isCreatingLibrary) {
            TextField(L10n.text("libraryProfile.name"), text: $libraryNameDraft)
            Button(L10n.text("common.cancel"), role: .cancel) {}
            Button(L10n.text("libraryProfile.create")) {
                do { try libraryProfiles.createLibrary(named: libraryNameDraft) }
                catch { errorMessage = error.localizedDescription }
            }
        } message: {
            Text(L10n.text("libraryProfile.createDescription"))
        }
        .alert(
            L10n.text("libraryProfile.external.create"),
            isPresented: $isCreatingExternalLibrary
        ) {
            TextField(L10n.text("libraryProfile.name"), text: $libraryNameDraft)
            Button(L10n.text("common.cancel"), role: .cancel) {}
            Button(L10n.text("common.create")) { createExternalLibrary() }
        } message: {
            Text(L10n.text("libraryProfile.external.createDescription"))
        }
        .alert(L10n.text("libraryProfile.rename"), isPresented: $isRenamingLibrary) {
            TextField(L10n.text("libraryProfile.name"), text: $libraryNameDraft)
            Button(L10n.text("common.cancel"), role: .cancel) {}
            Button(L10n.text("libraryProfile.rename")) {
                libraryProfiles.rename(
                    libraryProfiles.activeLibraryID,
                    to: libraryNameDraft
                )
            }
        }
        .confirmationDialog(
            L10n.text("playlist.delete.title"),
            isPresented: Binding(
                get: { playlistPendingDeletion != nil },
                set: { if !$0 { playlistPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let playlistPendingDeletion {
                Button(L10n.text("playlist.delete"), role: .destructive) {
                    Task { await delete(playlistPendingDeletion) }
                }
            }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("playlist.delete.message"))
        }
        .confirmationDialog(
            L10n.text("playlistFolder.delete.title"),
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { if !$0 { folderPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let folderPendingDeletion {
                Button(L10n.text("playlistFolder.delete"), role: .destructive) {
                    Task { await delete(folderPendingDeletion) }
                }
            }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("playlistFolder.delete.message"))
        }
        .alert(
            L10n.text("playlist.error.title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didMountNotification
            )
        ) { _ in
            libraryProfiles.refreshExternalConnections()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didUnmountNotification
            )
        ) { _ in
            libraryProfiles.refreshExternalConnections()
        }
    }

    private var libraryProfileMenuLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: activeProfileIcon)
                .frame(width: 16)
            Text(libraryProfiles.activeProfile.name)
                .lineLimit(1)
                .layoutPriority(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(AppTheme.ink)
        .contentShape(Rectangle())
    }

    private var activeProfileIcon: String {
        let profile = libraryProfiles.activeProfile
        if libraryProfiles.connectionState(for: profile) != .connected {
            return "externaldrive.badge.exclamationmark"
        }
        return profile.isExternal ? "externaldrive" : "books.vertical"
    }

    private var libraryProfilePopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(libraryProfiles.availableProfiles) { profile in
                    Button {
                        libraryProfiles.activate(profile.id)
                        isShowingLibraryProfilePopover = false
                    } label: {
                        profileMenuLabel(profile)
                            .frame(width: 220, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(libraryProfiles.connectionState(for: profile) != .connected)
                }

                Divider().padding(.vertical, 3)

                libraryProfileAction(
                    L10n.text("libraryProfile.create"),
                    systemImage: "plus"
                ) {
                    isShowingLibraryProfilePopover = false
                    libraryNameDraft = ""
                    isCreatingLibrary = true
                }
                libraryProfileAction(
                    L10n.text("libraryProfile.external.create"),
                    systemImage: "externaldrive.badge.plus"
                ) {
                    isShowingLibraryProfilePopover = false
                    libraryNameDraft = ""
                    isCreatingExternalLibrary = true
                }
                libraryProfileAction(
                    L10n.text("libraryProfile.rename"),
                    systemImage: "pencil"
                ) {
                    isShowingLibraryProfilePopover = false
                    libraryNameDraft = libraryProfiles.activeProfile.name
                    isRenamingLibrary = true
                }

                let disconnected = libraryProfiles.availableProfiles.filter {
                    $0.isExternal && libraryProfiles.connectionState(for: $0) != .connected
                }
                if !disconnected.isEmpty {
                    libraryProfileGroupTitle(L10n.text("libraryProfile.external.reconnect"))
                    ForEach(disconnected) { profile in
                        libraryProfileAction(profile.name, systemImage: "externaldrive.badge.plus") {
                            isShowingLibraryProfilePopover = false
                            reconnect(profile)
                        }
                    }
                }

                let archivable = libraryProfiles.availableProfiles.filter {
                    $0.id != libraryProfiles.activeLibraryID
                }
                if !archivable.isEmpty {
                    libraryProfileGroupTitle(L10n.text("libraryProfile.archive"))
                    ForEach(archivable) { profile in
                        libraryProfileAction(profile.name, systemImage: "archivebox") {
                            libraryProfiles.archive(profile.id)
                        }
                    }
                }

                if !libraryProfiles.archivedProfiles.isEmpty {
                    libraryProfileGroupTitle(L10n.text("libraryProfile.archived"))
                    ForEach(libraryProfiles.archivedProfiles) { profile in
                        libraryProfileAction(
                            L10n.format("libraryProfile.unarchive", profile.name),
                            systemImage: "arrow.uturn.backward"
                        ) {
                            libraryProfiles.unarchive(profile.id)
                        }
                    }
                }
            }
            .padding(AppTheme.spaceXS)
        }
        .frame(width: 252)
        .frame(maxHeight: 480)
    }

    private func libraryProfileAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.ink)
    }

    private func libraryProfileGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.secondaryInk)
            .padding(.horizontal, 6)
            .padding(.top, AppTheme.spaceXS)
    }

    @ViewBuilder
    private func profileMenuLabel(_ profile: LibraryProfile) -> some View {
        if libraryProfiles.connectionState(for: profile) == .connected {
            Label(
                profile.name,
                systemImage: profile.id == libraryProfiles.activeLibraryID
                    ? "checkmark"
                    : (profile.isExternal ? "externaldrive" : "books.vertical")
            )
        } else {
            Label(
                L10n.format("libraryProfile.external.disconnected", profile.name),
                systemImage: "externaldrive.badge.exclamationmark"
            )
        }
    }

    private func createExternalLibrary() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("libraryProfile.external.chooseDestination")
        panel.prompt = L10n.text("common.choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try libraryProfiles.createExternalLibrary(
                named: libraryNameDraft,
                in: destination
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reconnect(_ profile: LibraryProfile) {
        let panel = NSOpenPanel()
        panel.title = L10n.format("libraryProfile.external.reconnectTitle", profile.name)
        panel.message = L10n.text("libraryProfile.external.reconnectDescription")
        panel.prompt = L10n.text("libraryProfile.external.reconnectAction")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let root = panel.url else { return }
        do {
            try libraryProfiles.reconnect(profile.id, to: root)
            libraryProfiles.activate(profile.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        Label {
            Text(playlist.name).lineLimit(1)
        } icon: {
            if playlist.smartDefinition != nil {
                Image(systemName: "gearshape.2")
            } else {
                PlaylistSidebarArtwork(playlist: playlist)
            }
        }
        .tag(SidebarDestination.playlist(playlist.id))
        .draggable("playlist:\(playlist.id.uuidString)")
        .dropDestination(for: String.self) { payloads, location in
            if let sourceID = payloads.compactMap(parsePlaylistID).first {
                let targetID = location.y > 14
                    ? playlistID(after: playlist.id, in: playlist.folderID)
                    : playlist.id
                Task {
                    try? await library.movePlaylist(
                        sourceID,
                        to: playlist.folderID,
                        before: targetID
                    )
                }
                return sourceID != playlist.id
            }
            let trackIDs = orderedUniqueTrackIDs(payloads.flatMap(parseTrackIDs))
            guard !trackIDs.isEmpty, playlist.smartDefinition == nil else { return false }
            Task { try? await library.addTracks(trackIDs, to: playlist.id) }
            return true
        } isTargeted: { _ in }
        .contextMenu {
            Button {
                if playlist.smartDefinition != nil {
                    smartPlaylistEditorTarget = .edit(playlist)
                } else {
                    playlistEditorTarget = .edit(playlist)
                }
            } label: {
                Label(L10n.text("playlist.edit"), systemImage: "pencil")
            }
            Button {
                Task { await duplicate(playlist) }
            } label: {
                Label(
                    L10n.text("playlist.duplicate"),
                    systemImage: "plus.square.on.square"
                )
            }
            Menu(L10n.text("playlist.transfer.export")) {
                ForEach(PlaylistTransferFormat.allCases) { format in
                    Button(format.rawValue.uppercased()) {
                        export(playlist, as: format)
                    }
                }
            }
            Menu(L10n.text("playlist.moveToFolder")) {
                Button(L10n.text("playlistFolder.none")) {
                    Task { try? await library.movePlaylist(playlist.id, to: nil) }
                }
                Divider()
                ForEach(library.sortedPlaylistFolders) { folder in
                    Button(folder.name) {
                        expandedFolderIDs.insert(folder.id)
                        Task { try? await library.movePlaylist(playlist.id, to: folder.id) }
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                playlistPendingDeletion = playlist
            } label: {
                Label(L10n.text("playlist.delete"), systemImage: "trash")
            }
        }
    }

    private func handleFolderDrop(
        _ payloads: [String],
        onto folder: PlaylistFolder,
        insertAfter: Bool
    ) -> Bool {
        if let sourceFolderID = payloads.compactMap(parseFolderID).first {
            guard sourceFolderID != folder.id else { return false }
            let targetID = insertAfter ? folderID(after: folder.id) : folder.id
            Task { try? await library.movePlaylistFolder(sourceFolderID, before: targetID) }
            return true
        }
        if let playlistID = payloads.compactMap(parsePlaylistID).first {
            expandedFolderIDs.insert(folder.id)
            Task { try? await library.movePlaylist(playlistID, to: folder.id) }
            return true
        }
        return false
    }

    private func playlistID(
        after playlistID: Playlist.ID,
        in folderID: PlaylistFolder.ID?
    ) -> Playlist.ID? {
        let playlists = library.playlists(in: folderID)
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return nil }
        let nextIndex = playlists.index(after: index)
        return nextIndex < playlists.endIndex ? playlists[nextIndex].id : nil
    }

    private func folderID(after folderID: PlaylistFolder.ID) -> PlaylistFolder.ID? {
        let folders = library.sortedPlaylistFolders
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return nil }
        let nextIndex = folders.index(after: index)
        return nextIndex < folders.endIndex ? folders[nextIndex].id : nil
    }

    private func parsePlaylistID(_ payload: String) -> Playlist.ID? {
        guard payload.hasPrefix("playlist:") else { return nil }
        return UUID(uuidString: String(payload.dropFirst("playlist:".count)))
    }

    private func parseFolderID(_ payload: String) -> PlaylistFolder.ID? {
        guard payload.hasPrefix("folder:") else { return nil }
        return UUID(uuidString: String(payload.dropFirst("folder:".count)))
    }

    private func parseTrackIDs(_ payload: String) -> [Track.ID] {
        payload.split(whereSeparator: \.isNewline).compactMap { UUID(uuidString: String($0)) }
    }

    private func orderedUniqueTrackIDs(_ trackIDs: [Track.ID]) -> [Track.ID] {
        var seen: Set<Track.ID> = []
        return trackIDs.filter { seen.insert($0).inserted }
    }

    private func startPlaylistImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = PlaylistTransferFormat.allCases.compactMap {
            UTType(filenameExtension: $0.fileExtension)
        }
        panel.prompt = L10n.text("playlist.transfer.import.action")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importPreview = try PlaylistTransferService.preview(from: url, tracks: library.tracks)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export(_ playlist: Playlist, as format: PlaylistTransferFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeFilename(playlist.name)).\(format.fileExtension)"
        panel.allowedContentTypes = [
            UTType(filenameExtension: format.fileExtension) ?? .data
        ]
        panel.canCreateDirectories = true
        panel.prompt = L10n.text("playlist.transfer.export.action")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PlaylistTransferService.exportData(
                playlist: playlist,
                tracks: library.tracks(in: playlist),
                format: format
            )
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        return value.components(separatedBy: invalid).joined(separator: "-")
    }

    private var sidebarSelection: Binding<SidebarDestination?> {
        Binding(
            get: {
                if let selectedPlaylistID = library.selectedPlaylistID {
                    return .playlist(selectedPlaylistID)
                }
                return .section(library.selectedSection)
            },
            set: { destination in
                guard let destination else { return }
                // AppKit's List selection setter can run while SwiftUI is still updating
                // the sidebar. Publish the destination on the next main-loop turn so the
                // shared library state never changes inside that view update transaction.
                DispatchQueue.main.async {
                    switch destination {
                    case .section(let section):
                        library.selectedPlaylistID = nil
                        library.selectedSection = section
                    case .playlist(let id):
                        library.selectedPlaylistID = id
                        library.selectedTrackID = library.filteredTracks.first?.id
                    }
                }
            }
        )
    }

    private var librarySummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.format("sidebar.trackCount", library.tracks.count))
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryInk)
            Text(ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.spaceMD)
        .padding(.vertical, AppTheme.spaceSM)
    }

    @MainActor
    private func duplicate(_ playlist: Playlist) async {
        do {
            _ = try await library.duplicatePlaylist(playlist.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ playlist: Playlist) async {
        playlistPendingDeletion = nil
        do {
            try await library.deletePlaylist(playlist.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ folder: PlaylistFolder) async {
        folderPendingDeletion = nil
        do {
            try await library.deletePlaylistFolder(folder.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PlaylistImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let preview: PlaylistImportPreview
    @State private var name: String
    @State private var isImporting = false
    @State private var errorMessage: String?

    init(preview: PlaylistImportPreview) {
        self.preview = preview
        _name = State(initialValue: preview.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                Text(L10n.text("playlist.transfer.preview.title"))
                    .font(.title2.bold())
                Text(L10n.text("playlist.transfer.preview.description"))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            TextField(L10n.text("playlist.field.name"), text: $name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: AppTheme.spaceLG) {
                summary(L10n.text("playlist.transfer.matched"), preview.matchedCount, AppTheme.good)
                summary(L10n.text("playlist.transfer.duplicate"), preview.duplicateCount, AppTheme.warning)
                summary(L10n.text("playlist.transfer.missing"), preview.missingCount, AppTheme.danger)
                Spacer()
            }

            Table(preview.rows) {
                TableColumn(L10n.text("playlist.transfer.column.status")) { row in
                    Label(
                        L10n.text("playlist.transfer.status.\(row.status.rawValue)"),
                        systemImage: statusSymbol(row.status)
                    )
                    .foregroundStyle(statusColor(row.status))
                }
                .width(min: 110, ideal: 130)
                TableColumn(L10n.text("playlist.transfer.column.song"), value: \.displayName)
                TableColumn(L10n.text("playlist.transfer.column.source")) { row in
                    Text(row.sourcePath ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(AppTheme.secondaryInk)
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(AppTheme.danger)
            }

            HStack {
                Text(L10n.format("playlist.transfer.preview.importCount", preview.matchedCount))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }
                Button(L10n.text("playlist.transfer.import.action"), action: performImport)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || preview.matchedCount == 0 || isImporting)
            }
        }
        .padding(AppTheme.spaceLG)
        .frame(minWidth: 760, minHeight: 560)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func summary(_ label: String, _ count: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(.title3.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(AppTheme.secondaryInk)
        }
    }

    private func statusSymbol(_ status: PlaylistImportRowStatus) -> String {
        switch status {
        case .matched: "checkmark.circle.fill"
        case .duplicate: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .missing: "questionmark.circle.fill"
        }
    }

    private func statusColor(_ status: PlaylistImportRowStatus) -> Color {
        switch status {
        case .matched: AppTheme.good
        case .duplicate: AppTheme.warning
        case .missing: AppTheme.danger
        }
    }

    private func performImport() {
        guard !trimmedName.isEmpty, !isImporting else { return }
        isImporting = true
        Task { @MainActor in
            do {
                _ = try await library.importPlaylist(
                    name: trimmedName,
                    description: preview.description,
                    trackIDs: preview.matchedTrackIDs
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isImporting = false
            }
        }
    }
}

private struct PlaylistSidebarArtwork: View {
    let playlist: Playlist

    var body: some View {
        Group {
            if let path = playlist.artworkPath,
               let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note.list")
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct PlaylistFolderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let target: PlaylistFolderEditorTarget
    @State private var name: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(target: PlaylistFolderEditorTarget) {
        self.target = target
        switch target {
        case .create:
            _name = State(initialValue: "")
        case .rename(let folder):
            _name = State(initialValue: folder.name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            Text(L10n.text(isRenaming
                ? "playlistFolder.editor.renameTitle"
                : "playlistFolder.editor.createTitle"))
                .font(.title2.bold())

            TextField(L10n.text("playlistFolder.field.name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.danger)
            }

            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }
                Button(L10n.text("playlist.editor.save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || isSaving)
            }
        }
        .padding(AppTheme.spaceLG)
        .frame(width: 380)
    }

    private var isRenaming: Bool {
        if case .rename = target { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty, !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            do {
                switch target {
                case .create:
                    _ = try await library.createPlaylistFolder(name: trimmedName)
                case .rename(let folder):
                    try await library.renamePlaylistFolder(folder.id, name: trimmedName)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct SmartPlaylistEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let target: SmartPlaylistEditorTarget
    @State private var name: String
    @State private var definition: SmartPlaylistDefinition
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(target: SmartPlaylistEditorTarget) {
        self.target = target
        switch target {
        case .create:
            _name = State(initialValue: "")
            _definition = State(initialValue: SmartPlaylistDefinition())
        case .edit(let playlist):
            _name = State(initialValue: playlist.name)
            _definition = State(initialValue: playlist.smartDefinition ?? SmartPlaylistDefinition())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                Text(L10n.text(isEditing
                    ? "smartPlaylist.editor.editTitle"
                    : "smartPlaylist.editor.createTitle"))
                    .font(.title2.bold())
                Text(L10n.text("smartPlaylist.editor.description"))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            TextField(L10n.text("playlist.field.name"), text: $name)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                SmartRuleGroupEditor(group: $definition.root, depth: 0)
                    .padding(.trailing, AppTheme.spaceSM)
            }
            .frame(maxHeight: 350)

            HStack {
                Toggle(
                    L10n.text("smartPlaylist.limit.enabled"),
                    isOn: Binding(
                        get: { definition.limit != nil },
                        set: { definition.limit = $0 ? 100 : nil }
                    )
                )
                if definition.limit != nil {
                    Stepper(
                        L10n.format("smartPlaylist.limit.count", definition.limit ?? 100),
                        value: Binding(
                            get: { definition.limit ?? 100 },
                            set: { definition.limit = $0 }
                        ),
                        in: 1...100_000
                    )
                    .monospacedDigit()
                }
                Spacer()
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(AppTheme.danger)
            }

            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }
                Button(L10n.text("playlist.editor.save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || isSaving)
            }
        }
        .padding(AppTheme.spaceLG)
        .frame(width: 760, height: 600)
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty, !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            do {
                switch target {
                case .create:
                    _ = try await library.createSmartPlaylist(
                        name: trimmedName,
                        definition: definition
                    )
                case .edit(let playlist):
                    try await library.updateSmartPlaylist(
                        id: playlist.id,
                        name: trimmedName,
                        definition: definition
                    )
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct SmartRuleGroupEditor: View {
    @Binding var group: SmartPlaylistRuleGroup
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            HStack {
                Text(L10n.text("smartPlaylist.group.match"))
                    .font(.callout.weight(.medium))
                Picker("", selection: $group.mode) {
                    ForEach(SmartPlaylistMatchMode.allCases) { mode in
                        Text(L10n.text("smartPlaylist.match.\(mode.rawValue)"))
                            .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
                Spacer()
            }

            ForEach($group.rules) { $rule in
                HStack(spacing: AppTheme.spaceSM) {
                    Picker("", selection: $rule.field) {
                        ForEach(SmartPlaylistField.allCases) { field in
                            Text(L10n.text("smartPlaylist.field.\(field.rawValue)"))
                                .tag(field)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: rule.field) { _, field in
                        rule.comparison = comparisons(for: field).first ?? .equals
                        if field.isBoolean { rule.value = "" }
                    }

                    Picker("", selection: $rule.comparison) {
                        ForEach(comparisons(for: rule.field)) { comparison in
                            Text(L10n.text("smartPlaylist.comparison.\(comparison.rawValue)"))
                                .tag(comparison)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)

                    if !rule.field.isBoolean {
                        TextField(valuePrompt(for: rule.field), text: $rule.value)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Spacer()
                    }

                    Button(role: .destructive) {
                        group.rules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("smartPlaylist.rule.remove"))
                }
            }

            ForEach($group.groups) { $subgroup in
                ZStack(alignment: .topTrailing) {
                    SmartRuleGroupEditor(group: $subgroup, depth: depth + 1)
                        .padding(.leading, AppTheme.spaceMD)
                    Button(role: .destructive) {
                        group.groups.removeAll { $0.id == subgroup.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("smartPlaylist.group.remove"))
                    .padding(AppTheme.spaceXS)
                }
            }

            HStack {
                Button {
                    group.rules.append(SmartPlaylistRule())
                } label: {
                    Label(L10n.text("smartPlaylist.rule.add"), systemImage: "plus")
                }
                Button {
                    group.groups.append(SmartPlaylistRuleGroup())
                } label: {
                    Label(L10n.text("smartPlaylist.group.add"), systemImage: "plus.square")
                }
                if depth > 0 {
                    Spacer()
                    Text(L10n.text("smartPlaylist.group.nested"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryInk)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(AppTheme.spaceMD)
        .background(depth == 0 ? AppTheme.raised : AppTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.radiusMedium, style: .continuous)
                .strokeBorder(AppTheme.ink.opacity(0.08))
        }
    }

    private func comparisons(for field: SmartPlaylistField) -> [SmartPlaylistComparison] {
        if field.isBoolean { return [.isTrue, .isFalse] }
        if field.isNumeric { return [.equals, .notEquals, .atLeast, .atMost] }
        return [.contains, .equals, .notEquals]
    }

    private func valuePrompt(for field: SmartPlaylistField) -> String {
        field.isNumeric
            ? L10n.text("smartPlaylist.value.number")
            : L10n.text("smartPlaylist.value.text")
    }
}

private struct PlaylistEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    let target: PlaylistEditorTarget

    @State private var name: String
    @State private var playlistDescription: String
    @State private var selectedArtworkData: Data?
    @State private var artworkImage: NSImage?
    @State private var removesArtwork = false
    @State private var isSelectingArtwork = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(target: PlaylistEditorTarget) {
        self.target = target
        switch target {
        case .create:
            _name = State(initialValue: "")
            _playlistDescription = State(initialValue: "")
        case .edit(let playlist):
            _name = State(initialValue: playlist.name)
            _playlistDescription = State(initialValue: playlist.description)
            if let path = playlist.artworkPath {
                _artworkImage = State(initialValue: NSImage(contentsOfFile: path))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                Text(L10n.text(isEditing ? "playlist.editor.editTitle" : "playlist.editor.createTitle"))
                    .font(.title2.bold())
                Text(L10n.text("playlist.editor.description"))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            HStack(alignment: .top, spacing: AppTheme.spaceLG) {
                artworkEditor

                VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
                    LabeledContent(L10n.text("playlist.field.name")) {
                        TextField(L10n.text("playlist.field.name"), text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                    }
                    VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                        Text(L10n.text("playlist.field.description"))
                            .font(.callout)
                        TextEditor(text: $playlistDescription)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(AppTheme.spaceXS)
                            .frame(width: 320, height: 110)
                            .background(AppTheme.raised)
                            .clipShape(RoundedRectangle(
                                cornerRadius: AppTheme.radiusSmall,
                                style: .continuous
                            ))
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: AppTheme.radiusSmall,
                                    style: .continuous
                                )
                                .strokeBorder(AppTheme.rule, lineWidth: 1)
                            }
                    }
                }
            }
            .padding(AppTheme.spaceMD)
            .ongakuPanel()

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppTheme.warning)
            }

            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("playlist.editor.save")) {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || isSaving)
            }
        }
        .padding(AppTheme.spaceLG)
        .frame(width: 650)
        .background(AppTheme.canvas)
        .interactiveDismissDisabled(isSaving)
        .fileImporter(
            isPresented: $isSelectingArtwork,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: importArtwork
        )
    }

    private var artworkEditor: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            Text(L10n.text("playlist.field.artwork")).font(.headline)
            Group {
                if let artworkImage {
                    Image(nsImage: artworkImage).resizable().scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppTheme.radiusMedium)
                            .fill(AppTheme.raised)
                        Image(systemName: "music.note.list")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            }
            .frame(width: 144, height: 144)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusMedium))

            Button(L10n.text("metadataEditor.artwork.choose")) {
                isSelectingArtwork = true
            }
            .frame(width: 144)

            Button(L10n.text("metadataEditor.artwork.remove")) {
                selectedArtworkData = nil
                artworkImage = nil
                removesArtwork = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.secondaryInk)
            .disabled(artworkImage == nil)
            .frame(width: 144)
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func importArtwork(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= 12 * 1_024 * 1_024,
                  let image = NSImage(data: data) else {
                errorMessage = L10n.text("metadataEditor.artwork.invalid")
                return
            }
            selectedArtworkData = data
            artworkImage = image
            removesArtwork = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        do {
            let description = playlistDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            switch target {
            case .create:
                _ = try await library.createPlaylist(
                    name: trimmedName,
                    description: description,
                    artworkData: selectedArtworkData
                )
            case .edit(let playlist):
                try await library.updatePlaylist(
                    id: playlist.id,
                    name: trimmedName,
                    description: description,
                    artworkData: selectedArtworkData,
                    removesArtwork: removesArtwork
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
