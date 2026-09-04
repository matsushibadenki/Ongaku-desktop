import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct PendingRequiredMetadataImport: Identifiable {
    let id = UUID()
    let sourceURLs: [URL]
    let drafts: [RequiredImportMetadataDraft]
    let cleanupURLs: [URL]
}

struct ContentView: View {
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var appleMusicPlayback: AppleMusicPlaybackController
    @EnvironmentObject private var meterSettings: PlayerMeterSettings
    @EnvironmentObject private var phoneSync: PhoneSyncController
    @State private var isImportingCD = false
    @State private var isImportingURL = false
    @State private var isMigratingLibrary = false
    @State private var isMigratingOngakuLibrary = false
    @State private var isMigratingSharedFolder = false
    @State private var isOrganizingMedia = false
    @State private var isShowingAppleMusicStore = false
    @State private var isShowingDeviceSync = false
    @State private var isDropTargeted = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pendingRequiredMetadataImport: PendingRequiredMetadataImport?
    @State private var deferredImportCleanupURLs: [URL] = []

    var body: some View {
        playerAwareLayout
        .accessibilityIdentifier("main.window")
        .background(AppTheme.canvas)
        .tint(AppTheme.accent)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task {
                let sourceURLs = await library.audioFiles(inDroppedItems: urls)
                await prepareFilesForImport(sourceURLs)
            }
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay {
            if isDropTargeted {
                dropImportOverlay
                    .allowsHitTesting(false)
                    .padding(32)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
#if !APP_STORE
        .sheet(isPresented: $isImportingCD) {
            AudioCDImportView()
                .environmentObject(library)
        }
#endif
        .sheet(isPresented: $isImportingURL) {
            URLAudioImportView()
                .environmentObject(library)
        }
        .sheet(isPresented: $isMigratingLibrary) {
            LegacyLibraryMigrationView()
                .environmentObject(library)
        }
        .sheet(isPresented: $isMigratingOngakuLibrary) {
            OngakuLibraryMigrationView()
                .environmentObject(library)
        }
        .sheet(isPresented: $isMigratingSharedFolder) {
            SharedFolderMigrationView()
                .environmentObject(library)
        }
        .sheet(isPresented: $isOrganizingMedia) {
            MediaOrganizationView()
                .environmentObject(library)
        }
        .sheet(isPresented: $isShowingAppleMusicStore) {
            AppleMusicStoreView()
                .environmentObject(player)
                .environmentObject(appleMusicPlayback)
        }
        .sheet(isPresented: $isShowingDeviceSync) {
            DeviceSyncView()
                .environmentObject(library)
                .environmentObject(phoneSync)
        }
        .sheet(item: $pendingRequiredMetadataImport, onDismiss: {
            cleanupImportedSources(deferredImportCleanupURLs)
            deferredImportCleanupURLs = []
        }) { request in
            RequiredImportMetadataView(drafts: request.drafts) { drafts in
                deferredImportCleanupURLs = []
                pendingRequiredMetadataImport = nil
                importReviewedFiles(
                    request.sourceURLs,
                    drafts: drafts,
                    cleanupURLs: request.cleanupURLs
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestImport)) { _ in
            presentMusicImportPanel()
        }
#if !APP_STORE
        .onReceive(NotificationCenter.default.publisher(for: .requestCDImport)) { _ in
            isImportingCD = true
        }
#endif
        .onReceive(NotificationCenter.default.publisher(for: .requestURLImport)) { _ in
            isImportingURL = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestLibraryMigration)) { _ in
            isMigratingLibrary = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOngakuLibraryMigration)) { _ in
            isMigratingOngakuLibrary = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSharedFolderMigration)) { _ in
            isMigratingSharedFolder = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestMediaOrganization)) { _ in
            isOrganizingMedia = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAppleMusicStore)) { _ in
            isShowingAppleMusicStore = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestVerification)) { _ in
            Task { await library.verifyLibrary() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await library.refreshFileAvailability() }
        }
        .onAppear {
            library.undoManager = undoManager
            phoneSync.onVerifiedIncomingFile = { url in
                Task { @MainActor in
                    await prepareFilesForImport([url], cleanupURLs: [url])
                }
            }
            phoneSync.updateLocalTracks(
                library.tracks,
                playbackEvents: library.playbackEvents,
                playlists: library.playlists,
                displayTags: library.syncedDisplayTags
            )
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    presentMusicImportPanel()
                } label: {
                    Label(L10n.text("command.import"), systemImage: "plus")
                }
                .accessibilityIdentifier("main.import-music")
                .help(L10n.text("toolbar.importHelp"))

#if !APP_STORE
                Button {
                    isImportingCD = true
                } label: {
                    Label(L10n.text("command.importCD"), systemImage: "opticaldisc")
                }
                .help(L10n.text("toolbar.importCDHelp"))
#endif

                Button {
                    isImportingURL = true
                } label: {
                    Label(L10n.text("command.importURL"), systemImage: "link.badge.plus")
                }
                .help(L10n.text("toolbar.importURLHelp"))

                Button {
                    isShowingAppleMusicStore = true
                } label: {
                    Label(L10n.text("command.appleMusicStore"), systemImage: "apple.logo")
                }
                .accessibilityIdentifier("main.open-apple-music")
                .help(L10n.text("toolbar.appleMusicStoreHelp"))

                Button {
                    isShowingDeviceSync = true
                } label: {
                    Label(L10n.text("deviceSync.title"), systemImage: "iphone.and.arrow.forward")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .accessibilityIdentifier("main.open-device-sync")
                .help(L10n.text("deviceSync.toolbar.help"))

                Button {
                    Task { await library.verifyLibrary() }
                } label: {
                    Label(L10n.text("command.verify"), systemImage: "checkmark.shield")
                }
                .help(L10n.text("toolbar.verifyHelp"))
                .disabled(
                    library.tracks.isEmpty
                        || library.activity == .verifying
                        || library.activity == .relinking
                )

                Button {
                    presentRelinkSearchPanel()
                } label: {
                    Label(L10n.text("relink.searchFolder"), systemImage: "folder.badge.questionmark")
                }
                .help(L10n.text("relink.searchFolderHelp"))
                .disabled(
                    !library.tracks.contains(where: { $0.health == .missing })
                        || library.activity == .relinking
                        || library.activity == .verifying
                )
            }
        }
        .toolbarBackground(AppTheme.windowBar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }

    private func presentMusicImportPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("command.import")
        panel.prompt = L10n.text("common.choose")
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        Task { await prepareFilesForImport(urls) }
    }

    private func prepareFilesForImport(
        _ urls: [URL],
        cleanupURLs: [URL] = []
    ) async {
        guard !urls.isEmpty else { return }
        let drafts = await library.requiredImportMetadata(for: urls)
        guard !drafts.isEmpty else {
            await library.importFiles(urls)
            cleanupImportedSources(cleanupURLs)
            return
        }
        pendingRequiredMetadataImport = PendingRequiredMetadataImport(
            sourceURLs: urls,
            drafts: drafts,
            cleanupURLs: cleanupURLs
        )
        deferredImportCleanupURLs = cleanupURLs
    }

    private func importReviewedFiles(
        _ urls: [URL],
        drafts: [RequiredImportMetadataDraft],
        cleanupURLs: [URL]
    ) {
        let overrides = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
        Task {
            await library.importFiles(urls, requiredMetadataOverrides: overrides)
            cleanupImportedSources(cleanupURLs)
        }
    }

    private func cleanupImportedSources(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private func presentRelinkSearchPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("relink.searchFolder")
        panel.prompt = L10n.text("common.choose")
        panel.allowedContentTypes = [.folder]
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { await library.relinkMissingFiles(searching: [directory]) }
    }

    private var persistentPlayer: some View {
        PlayerBar()
            .frame(height: PlayerBar.layoutHeight)
            .layoutPriority(2)
    }

    private var playerAwareLayout: some View {
        GeometryReader { proxy in
            let navigationHeight = PlayerBar.navigationHeight(in: proxy.size.height)
            VStack(spacing: 0) {
                if meterSettings.barPosition == .top {
                    persistentPlayer
                }

                navigationContent
                    .frame(
                        maxWidth: .infinity,
                        minHeight: navigationHeight,
                        maxHeight: navigationHeight
                    )
                    .clipped()

                if meterSettings.barPosition == .bottom {
                    persistentPlayer
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar()
                .frame(maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } content: {
            LibraryContent()
                .frame(maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 660, ideal: 760)
        } detail: {
            TrackInspector()
                .frame(maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        }
    }

    private var dropImportOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(AppTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))

            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                Text(L10n.text("dropImport.title"))
                    .font(.title3.weight(.semibold))
                Text(L10n.text("dropImport.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
        .frame(maxWidth: 520, maxHeight: 230)
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("dropImport.title"))
        .accessibilityHint(L10n.text("dropImport.subtitle"))
    }
}

private struct RequiredImportMetadataView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [RequiredImportMetadataDraft]
    let onImport: ([RequiredImportMetadataDraft]) -> Void

    init(
        drafts: [RequiredImportMetadataDraft],
        onImport: @escaping ([RequiredImportMetadataDraft]) -> Void
    ) {
        _drafts = State(initialValue: drafts)
        self.onImport = onImport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("import.requiredMetadata.title"))
                    .font(.title2.bold())
                Text(L10n.text("import.requiredMetadata.message"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(draft.sourceURL.lastPathComponent, systemImage: "music.note")
                                .font(.headline)
                                .lineLimit(1)
                                .help(draft.sourceURL.path)

                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                if draft.requiresArtist {
                                    GridRow {
                                        Text(L10n.text("metadataEditor.field.artist"))
                                            .foregroundStyle(.secondary)
                                        TextField(
                                            L10n.text("import.requiredMetadata.artistPlaceholder"),
                                            text: $draft.artist
                                        )
                                        .textFieldStyle(.roundedBorder)
                                    }
                                }
                                if draft.requiresAlbum {
                                    GridRow {
                                        Text(L10n.text("metadataEditor.field.album"))
                                            .foregroundStyle(.secondary)
                                        TextField(
                                            L10n.text("import.requiredMetadata.albumPlaceholder"),
                                            text: $draft.album
                                        )
                                        .textFieldStyle(.roundedBorder)
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.text("common.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("import.requiredMetadata.import")) {
                    onImport(drafts)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!drafts.allSatisfy(\.isComplete))
            }
            .padding(20)
        }
        .frame(width: 580)
        .frame(minHeight: 360, maxHeight: 680)
        .background(AppTheme.canvas)
    }
}

#Preview("Desktop") {
    let storage = LibraryStorageSettings()
    ContentView()
        .environmentObject(LibraryStore())
        .environmentObject(PlaybackController())
        .environmentObject(AppleMusicPlaybackController())
        .environmentObject(AppleMusicStoreController())
        .environmentObject(PlayerMeterSettings())
        .environmentObject(TrackTableSettings())
        .environmentObject(PhoneSyncController())
        .environmentObject(LibraryProfileSettings(defaultMediaURL: storage.mediaDirectoryURL))
        .frame(width: 1240, height: 780)
}
