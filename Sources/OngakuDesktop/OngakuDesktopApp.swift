import AppKit
import SwiftUI
#if !APP_STORE
import Sparkle
#endif

struct AppStoreRelease: Decodable, Equatable, Identifiable {
    let version: String
    let trackViewUrl: URL
    let bundleId: String

    var id: String { version }
}

struct AppStoreLookupResponse: Decodable {
    let results: [AppStoreRelease]
}

enum AppVersionComparison {
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        candidate.compare(installed, options: .numeric) == .orderedDescending
    }
}

/// An explicit, temporary-library launch mode used by the Release UI qualification.
/// It is intentionally unavailable for paths outside the process temporary directory,
/// so an accidental launch argument can never redirect or overwrite a user's library.
struct LibraryQualificationConfiguration: Sendable {
    static let rootArgument = "--ongaku-qualification-root"
    static let prepareArgument = "--ongaku-qualification-prepare"

    let rootURL: URL
    let preparationTrackCount: Int?

    static var current: Self? {
        parse(arguments: ProcessInfo.processInfo.arguments)
    }

    static var isEnabled: Bool { current != nil }

    static func parse(arguments: [String]) -> Self? {
        guard let rootIndex = arguments.firstIndex(of: rootArgument),
              arguments.indices.contains(rootIndex + 1) else { return nil }

        let rootURL = URL(fileURLWithPath: arguments[rootIndex + 1], isDirectory: true)
            .standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        guard rootURL.path.hasPrefix(temporaryRoot.path + "/") else { return nil }

        var trackCount: Int?
        if let prepareIndex = arguments.firstIndex(of: prepareArgument),
           arguments.indices.contains(prepareIndex + 1),
           let requestedCount = Int(arguments[prepareIndex + 1]),
           (1...100_000).contains(requestedCount) {
            trackCount = requestedCount
        }
        return Self(rootURL: rootURL, preparationTrackCount: trackCount)
    }
}

enum LibraryQualificationFixture {
    static func prepare(_ configuration: LibraryQualificationConfiguration) async throws {
        guard let trackCount = configuration.preparationTrackCount else { return }
        let tracksPerAlbum = 10
        let tracksPerArtist = 20
        let artistCount = max(1, (trackCount + tracksPerArtist - 1) / tracksPerArtist)
        let albumCount = max(1, (trackCount + tracksPerAlbum - 1) / tracksPerAlbum)
        let artistIDs = (0..<artistCount).map { stableUUID(namespace: 0x2000_0000, value: $0) }
        let albumIDs = (0..<albumCount).map { stableUUID(namespace: 0x3000_0000, value: $0) }
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let tracks = (0..<trackCount).map { index in
            let artistIndex = index / tracksPerArtist
            let albumIndex = index / tracksPerAlbum
            let titlePrefix = switch index % 3 {
            case 0: "Track"
            case 1: "楽曲"
            default: "曲目"
            }
            return Track(
                id: stableUUID(namespace: 0x1000_0000, value: index),
                title: "\(titlePrefix) \(padded(index, width: 6))",
                artist: "Artist \(padded(artistIndex, width: 4))",
                album: "Album \(padded(albumIndex, width: 5))",
                duration: TimeInterval(120 + index % 300),
                fileSize: Int64(3_000_000 + index % 12_000_000),
                managedPath: configuration.rootURL
                    .appendingPathComponent("Media/Track \(padded(index, width: 6)).m4a").path,
                sha256: String(format: "%064llx", UInt64(index + 1)),
                addedAt: baseDate.addingTimeInterval(TimeInterval(index)),
                lastVerifiedAt: baseDate,
                health: .verified,
                artistID: artistIDs[artistIndex],
                albumID: albumIDs[albumIndex]
            )
        }
        let document = LibraryDocument(
            updatedAt: baseDate,
            tracks: tracks,
            libraryID: stableUUID(namespace: 0x4000_0000, value: 0),
            createdAt: baseDate
        )
        let repository = LibraryRepository(
            rootURL: configuration.rootURL,
            mediaURL: configuration.rootURL.appendingPathComponent("Media", isDirectory: true)
        )
        try await repository.save(document: document)
    }

    private static func stableUUID(namespace: UInt32, value: Int) -> UUID {
        UUID(uuidString: String(
            format: "%08X-0000-4000-8000-%012llX",
            namespace,
            UInt64(value)
        ))!
    }

    private static func padded(_ value: Int, width: Int) -> String {
        String(format: "%0*d", width, value)
    }
}

@MainActor
final class AppStoreUpdateChecker: ObservableObject {
    nonisolated static let appID = "6807717764"
    nonisolated static let bundleID = "com.ongaku.desktop"

    @Published var availableRelease: AppStoreRelease?
    private var hasChecked = false

    func checkIfNeeded(
        installedVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
    ) async {
        guard !hasChecked else { return }
        hasChecked = true

        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: Self.appID),
            URLQueryItem(name: "country", value: "jp")
        ]
        guard let url = components.url else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let release = try JSONDecoder().decode(
                    AppStoreLookupResponse.self,
                    from: data
                  ).results.first(where: { $0.bundleId == Self.bundleID }),
                  AppVersionComparison.isNewer(release.version, than: installedVersion) else {
                return
            }
            availableRelease = release
        } catch {
            // An update check must never delay launch or surface a network error.
        }
    }

    func dismiss() {
        availableRelease = nil
    }
}

#if !APP_STORE
@MainActor
final class SoftwareUpdateController: ObservableObject {
    let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
#endif

@main
struct OngakuDesktopApp: App {
    private let qualificationConfiguration: LibraryQualificationConfiguration?
    @StateObject private var storage: LibraryStorageSettings
    @StateObject private var libraryProfiles: LibraryProfileSettings
    @StateObject private var library: LibraryStore
    @StateObject private var language: AppLanguageSettings
    @StateObject private var appearance: AppAppearanceSettings
    @StateObject private var meterSettings: PlayerMeterSettings
    @StateObject private var trackTableSettings: TrackTableSettings
    @StateObject private var socialPrivacy: SocialPrivacySettings
    @StateObject private var artworkPrivacy: ArtworkPrivacySettings
    @StateObject private var windowPresentation = WindowPresentationController()
    @StateObject private var player: PlaybackController
    @StateObject private var appleMusicPlayback: AppleMusicPlaybackController
    @StateObject private var appleMusicStore: AppleMusicStoreController
    @StateObject private var systemNowPlaying: SystemNowPlayingController
    @StateObject private var phoneSync = PhoneSyncController()
    @StateObject private var appStoreUpdateChecker = AppStoreUpdateChecker()
#if !APP_STORE
    @StateObject private var softwareUpdater = SoftwareUpdateController()
#endif

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let qualificationConfiguration = LibraryQualificationConfiguration.current
        self.qualificationConfiguration = qualificationConfiguration
        let storage = LibraryStorageSettings()
        _storage = StateObject(wrappedValue: storage)
        let libraryProfiles = LibraryProfileSettings(defaultMediaURL: storage.mediaDirectoryURL)
        if qualificationConfiguration == nil {
            storage.activateProfileMediaDirectory(libraryProfiles.activeProfile.mediaURL)
        }
        _libraryProfiles = StateObject(wrappedValue: libraryProfiles)
        _language = StateObject(wrappedValue: AppLanguageSettings())
        _appearance = StateObject(wrappedValue: AppAppearanceSettings())
        _meterSettings = StateObject(wrappedValue: PlayerMeterSettings())
        _trackTableSettings = StateObject(wrappedValue: TrackTableSettings())
        _socialPrivacy = StateObject(wrappedValue: SocialPrivacySettings())
        _artworkPrivacy = StateObject(wrappedValue: ArtworkPrivacySettings())
        let player = PlaybackController()
        let appleMusicPlayback = AppleMusicPlaybackController()
        player.setExternalPlaybackStopHandler { [weak appleMusicPlayback] in
            appleMusicPlayback?.stopForLocalPlayback()
        }
        _player = StateObject(wrappedValue: player)
        _appleMusicPlayback = StateObject(wrappedValue: appleMusicPlayback)
        _appleMusicStore = StateObject(wrappedValue: AppleMusicStoreController())
        _systemNowPlaying = StateObject(
            wrappedValue: SystemNowPlayingController(
                player: player,
                appleMusicPlayback: appleMusicPlayback
            )
        )
        let repository: LibraryRepository
        if let qualificationConfiguration {
            repository = LibraryRepository(
                rootURL: qualificationConfiguration.rootURL,
                mediaURL: qualificationConfiguration.rootURL
                    .appendingPathComponent("Media", isDirectory: true)
            )
        } else {
            repository = LibraryRepository(
                rootURL: PortableLibraryStorage(mediaURL: libraryProfiles.activeProfile.mediaURL).rootURL,
                mediaURL: libraryProfiles.activeProfile.mediaURL
            )
        }
        _library = StateObject(wrappedValue: LibraryStore(repository: repository))
    }

    var body: some Scene {
        Window("Ongaku", id: "main") {
            Group {
                if qualificationConfiguration == nil, let error = libraryProfiles.migrationError {
                    VStack(spacing: 16) {
                        Text(L10n.text("storage.migration.failed")).font(.headline)
                        Text(error).textSelection(.enabled)
                    }
                    .padding(24)
                } else if windowPresentation.isMiniPlayer {
                    MiniPlayerView()
                } else {
                    ContentView()
                        .frame(minWidth: 1_160, minHeight: 620)
                }
            }
                .background(WindowMiniaturizeBridge(controller: windowPresentation))
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(appleMusicPlayback)
                .environmentObject(appleMusicStore)
                .environmentObject(storage)
                .environmentObject(libraryProfiles)
                .environmentObject(language)
                .environmentObject(appearance)
                .environmentObject(meterSettings)
                .environmentObject(trackTableSettings)
                .environmentObject(socialPrivacy)
                .environmentObject(artworkPrivacy)
                .environmentObject(phoneSync)
                .environment(\.locale, language.selectedLanguage.locale ?? .current)
                .preferredColorScheme(appearance.selectedAppearance.colorScheme)
                .id(language.selectedLanguage.rawValue)
                .task {
                    if let qualificationConfiguration {
                        try? await LibraryQualificationFixture.prepare(qualificationConfiguration)
                        await library.load()
                        player.updateAudioFeatures(library.audioFeatures)
                        return
                    }
#if APP_STORE
                    await appStoreUpdateChecker.checkIfNeeded()
#endif
                    guard libraryProfiles.migrationError == nil else { return }
                    try? await ArtworkResolver.shared.configure(
                        libraryRootURL: libraryProfiles.activeProfile.catalogURL
                    )
                    await library.load()
                    await library.refreshFileAvailability(force: true)
                    phoneSync.updateLocalTracks(
                        library.tracks,
                        playbackEvents: library.playbackEvents,
                        playlists: library.playlists,
                        displayTags: library.syncedDisplayTags
                    )
                    phoneSync.start()
                    player.updateAudioFeatures(library.audioFeatures)
                    player.restorePlaybackQueue(library.playbackQueue, tracks: library.tracks)
                }
                .onChange(of: library.contentRevision) {
                    guard qualificationConfiguration == nil else { return }
                    phoneSync.updateLocalTracks(
                        library.tracks,
                        playbackEvents: library.playbackEvents,
                        playlists: library.playlists,
                        displayTags: library.syncedDisplayTags
                    )
                    player.reconcilePlaybackQueue(with: library.tracks)
                }
                .onChange(of: library.audioFeatureRevision) {
                    player.updateAudioFeatures(library.audioFeatures)
                }
                .onChange(of: libraryProfiles.activeLibraryID) {
                    guard qualificationConfiguration == nil else { return }
                    let profile = libraryProfiles.activeProfile
                    storage.activateProfileMediaDirectory(profile.mediaURL)
                    Task {
                        try? await ArtworkResolver.shared.configure(
                            libraryRootURL: profile.catalogURL
                        )
                        await library.switchLibrary(
                            catalogURL: profile.catalogURL,
                            mediaURL: profile.mediaURL
                        )
                        await library.refreshFileAvailability(force: true)
                        player.restorePlaybackQueue(library.playbackQueue, tracks: library.tracks)
                    }
                }
                .onChange(of: libraryProfiles.activeLocationRevision) {
                    guard qualificationConfiguration == nil else { return }
                    let profile = libraryProfiles.activeProfile
                    storage.activateProfileMediaDirectory(profile.mediaURL)
                    Task {
                        try? await ArtworkResolver.shared.configure(
                            libraryRootURL: profile.catalogURL
                        )
                        await library.switchLibrary(
                            catalogURL: profile.catalogURL,
                            mediaURL: profile.mediaURL
                        )
                        await library.refreshFileAvailability(force: true)
                        player.restorePlaybackQueue(library.playbackQueue, tracks: library.tracks)
                    }
                }
                .onChange(of: storage.mediaDirectoryURL) { _, url in
                    guard qualificationConfiguration == nil else { return }
                    libraryProfiles.updateActiveMediaURL(url)
                }
                .onChange(of: player.queueState) {
                    library.schedulePlaybackQueueSave(player.queueState)
                }
                .onReceive(player.playbackEventPublisher) { event in
                    Task { await library.recordPlaybackEvent(event) }
                }
                .onReceive(player.missingTrackPublisher) { trackID in
                    Task { await library.handleMissingPlaybackFile(id: trackID) }
                }
                .onAppear {
                    systemNowPlaying.activate()
                }
#if APP_STORE
                .alert(
                    L10n.text("appStoreUpdate.title"),
                    isPresented: Binding(
                        get: { appStoreUpdateChecker.availableRelease != nil },
                        set: { if !$0 { appStoreUpdateChecker.dismiss() } }
                    ),
                    presenting: appStoreUpdateChecker.availableRelease
                ) { release in
                    Button(L10n.text("appStoreUpdate.update")) {
                        NSWorkspace.shared.open(release.trackViewUrl)
                        appStoreUpdateChecker.dismiss()
                    }
                    Button(L10n.text("appStoreUpdate.later"), role: .cancel) {
                        appStoreUpdateChecker.dismiss()
                    }
                } message: { release in
                    Text(L10n.format("appStoreUpdate.message", release.version))
                }
#endif
        }
        .commandsRemoved()
        .defaultSize(width: 1_320, height: 780)
        .windowResizability(.contentSize)
        .commands {
#if !APP_STORE
            CommandGroup(after: .appInfo) {
                Button(L10n.text("command.softwareUpdate")) {
                    softwareUpdater.checkForUpdates()
                }
            }
#endif

            CommandGroup(replacing: .newItem) {
                Button(L10n.text("command.import")) {
                    NotificationCenter.default.post(name: .requestImport, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

#if !APP_STORE
                Button(L10n.text("command.importCD")) {
                    NotificationCenter.default.post(name: .requestCDImport, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
#endif

                Button(L10n.text("command.importURL")) {
                    NotificationCenter.default.post(name: .requestURLImport, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

                Divider()

                Button(L10n.text("command.migrateLibrary")) {
                    NotificationCenter.default.post(name: .requestLibraryMigration, object: nil)
                }

                Button(L10n.text("command.migrateOngakuLibrary")) {
                    NotificationCenter.default.post(
                        name: .requestOngakuLibraryMigration,
                        object: nil
                    )
                }

                Button(L10n.text("command.migrateSharedFolder")) {
                    NotificationCenter.default.post(
                        name: .requestSharedFolderMigration,
                        object: nil
                    )
                }

                Divider()

                Button(L10n.text("command.organizeMedia")) {
                    NotificationCenter.default.post(
                        name: .requestMediaOrganization,
                        object: nil
                    )
                }
            }

            CommandGroup(replacing: .help) {
                Link(
                    L10n.text("command.onlineHelp"),
                    destination: URL(string: "https://github.com/matsushibadenki/Ongaku-desktop")!
                )
            }

            CommandMenu(L10n.text("command.library")) {
                Button(L10n.text("command.verify")) {
                    NotificationCenter.default.post(name: .requestVerification, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }

            CommandMenu(L10n.text("command.store")) {
                Button(L10n.text("command.appleMusicStore")) {
                    NotificationCenter.default.post(name: .requestAppleMusicStore, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            CommandMenu(L10n.text("command.playback")) {
                Picker(L10n.text("player.mode.title"), selection: $player.playbackMode) {
                    ForEach(PlaybackMode.allCases) { mode in
                        Label(L10n.text(mode.localizationKey), systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }

                Divider()

                Toggle(L10n.text("command.automaticUpsampling"), isOn: $player.automaticUpsampling)
            }
        }

        Settings {
            PreferencesView(socialPrivacy: socialPrivacy)
                .environmentObject(artworkPrivacy)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(storage)
                .environmentObject(libraryProfiles)
                .environmentObject(language)
                .environmentObject(appearance)
                .environmentObject(meterSettings)
                .environmentObject(trackTableSettings)
                .environmentObject(phoneSync)
                .id(language.selectedLanguage.rawValue)
        }
        .defaultSize(width: 761, height: 440)
        .windowResizability(.contentSize)
    }
}

extension Notification.Name {
    static let requestImport = Notification.Name("OngakuDesktop.requestImport")
    static let requestCDImport = Notification.Name("OngakuDesktop.requestCDImport")
    static let requestURLImport = Notification.Name("OngakuDesktop.requestURLImport")
    static let requestLibraryMigration = Notification.Name("OngakuDesktop.requestLibraryMigration")
    static let requestOngakuLibraryMigration = Notification.Name(
        "OngakuDesktop.requestOngakuLibraryMigration"
    )
    static let requestSharedFolderMigration = Notification.Name(
        "OngakuDesktop.requestSharedFolderMigration"
    )
    static let requestMediaOrganization = Notification.Name(
        "OngakuDesktop.requestMediaOrganization"
    )
    static let requestAppleMusicStore = Notification.Name("OngakuDesktop.requestAppleMusicStore")
    static let requestVerification = Notification.Name("OngakuDesktop.requestVerification")
}
