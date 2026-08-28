import AppKit
import SwiftUI
import Sparkle

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

@main
struct OngakuDesktopApp: App {
    @StateObject private var storage: LibraryStorageSettings
    @StateObject private var libraryProfiles: LibraryProfileSettings
    @StateObject private var library: LibraryStore
    @StateObject private var language: AppLanguageSettings
    @StateObject private var appearance: AppAppearanceSettings
    @StateObject private var meterSettings: PlayerMeterSettings
    @StateObject private var trackTableSettings: TrackTableSettings
    @StateObject private var windowPresentation = WindowPresentationController()
    @StateObject private var player: PlaybackController
    @StateObject private var appleMusicPlayback: AppleMusicPlaybackController
    @StateObject private var appleMusicStore: AppleMusicStoreController
    @StateObject private var systemNowPlaying: SystemNowPlayingController
    @StateObject private var phoneSync = PhoneSyncController()
    @StateObject private var softwareUpdater = SoftwareUpdateController()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let storage = LibraryStorageSettings()
        _storage = StateObject(wrappedValue: storage)
        let libraryProfiles = LibraryProfileSettings(defaultMediaURL: storage.mediaDirectoryURL)
        storage.activateProfileMediaDirectory(libraryProfiles.activeProfile.mediaURL)
        _libraryProfiles = StateObject(wrappedValue: libraryProfiles)
        _language = StateObject(wrappedValue: AppLanguageSettings())
        _appearance = StateObject(wrappedValue: AppAppearanceSettings())
        _meterSettings = StateObject(wrappedValue: PlayerMeterSettings())
        _trackTableSettings = StateObject(wrappedValue: TrackTableSettings())
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
        _library = StateObject(wrappedValue: LibraryStore(
            repository: LibraryRepository(
                rootURL: libraryProfiles.activeProfile.catalogURL,
                mediaURL: libraryProfiles.activeProfile.mediaURL
            )
        ))
    }

    var body: some Scene {
        Window("Ongaku", id: "main") {
            Group {
                if windowPresentation.isMiniPlayer {
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
                .environmentObject(phoneSync)
                .environment(\.locale, language.selectedLanguage.locale ?? .current)
                .preferredColorScheme(appearance.selectedAppearance.colorScheme)
                .id(language.selectedLanguage.rawValue)
                .task {
                    await library.load()
                    phoneSync.updateLocalTracks(library.tracks)
                    phoneSync.start()
                    player.updateAudioFeatures(library.audioFeatures)
                    player.restorePlaybackQueue(library.playbackQueue, tracks: library.tracks)
                }
                .onChange(of: library.contentRevision) {
                    phoneSync.updateLocalTracks(library.tracks)
                    player.reconcilePlaybackQueue(with: library.tracks)
                }
                .onChange(of: library.audioFeatureRevision) {
                    player.updateAudioFeatures(library.audioFeatures)
                }
                .onChange(of: libraryProfiles.activeLibraryID) {
                    let profile = libraryProfiles.activeProfile
                    storage.activateProfileMediaDirectory(profile.mediaURL)
                    Task {
                        await library.switchLibrary(
                            catalogURL: profile.catalogURL,
                            mediaURL: profile.mediaURL
                        )
                        player.restorePlaybackQueue(library.playbackQueue, tracks: library.tracks)
                    }
                }
                .onChange(of: storage.mediaDirectoryURL) { _, url in
                    libraryProfiles.updateActiveMediaURL(url)
                }
                .onChange(of: player.queueState) {
                    library.schedulePlaybackQueueSave(player.queueState)
                }
                .onReceive(player.playbackEventPublisher) { event in
                    Task { await library.recordPlaybackEvent(event) }
                }
                .onAppear {
                    systemNowPlaying.activate()
                }
        }
        .commandsRemoved()
        .defaultSize(width: 1_320, height: 780)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.text("command.softwareUpdate")) {
                    softwareUpdater.checkForUpdates()
                }
            }

            CommandGroup(replacing: .newItem) {
                Button(L10n.text("command.import")) {
                    NotificationCenter.default.post(name: .requestImport, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button(L10n.text("command.importCD")) {
                    NotificationCenter.default.post(name: .requestCDImport, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

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
            PreferencesView()
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
