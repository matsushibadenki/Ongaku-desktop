import SwiftUI
import UniformTypeIdentifiers

private enum MainFileImporterMode {
    case music
    case relinkSearch

    var allowedContentTypes: [UTType] {
        switch self {
        case .music: [.audio]
        case .relinkSearch: [.folder]
        }
    }

    var allowsMultipleSelection: Bool {
        self == .music
    }
}

struct ContentView: View {
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var appleMusicPlayback: AppleMusicPlaybackController
    @EnvironmentObject private var meterSettings: PlayerMeterSettings
    @EnvironmentObject private var phoneSync: PhoneSyncController
    @State private var fileImporterMode: MainFileImporterMode = .music
    @State private var isFileImporterPresented = false
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

    var body: some View {
        playerAwareLayout
        .accessibilityIdentifier("main.window")
        .background(AppTheme.canvas)
        .tint(AppTheme.accent)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await library.importDroppedItems(urls) }
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
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: fileImporterMode.allowedContentTypes,
            allowsMultipleSelection: fileImporterMode.allowsMultipleSelection
        ) { result in
            guard case .success(let urls) = result else { return }
            switch fileImporterMode {
            case .music:
                Task { await library.importFiles(urls) }
            case .relinkSearch:
                Task { await library.relinkMissingFiles(searching: urls) }
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .requestImport)) { _ in
            presentFileImporter(.music)
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
        .onAppear {
            library.undoManager = undoManager
            phoneSync.onVerifiedIncomingFile = { url in
                Task { @MainActor in
                    await library.importFiles([url])
                    try? FileManager.default.removeItem(at: url)
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
                    presentFileImporter(.music)
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
                    presentFileImporter(.relinkSearch)
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

    private func presentFileImporter(_ mode: MainFileImporterMode) {
        fileImporterMode = mode
        isFileImporterPresented = true
    }

    private var persistentPlayer: some View {
        PlayerBar()
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    private var playerAwareLayout: some View {
        VStack(spacing: 0) {
            if meterSettings.barPosition == .top {
                persistentPlayer
            }

            navigationContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(0)

            if meterSettings.barPosition == .bottom {
                persistentPlayer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } content: {
            LibraryContent()
                .navigationSplitViewColumnWidth(min: 660, ideal: 760)
        } detail: {
            TrackInspector()
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
