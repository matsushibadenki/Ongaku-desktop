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
    @StateObject private var library: LibraryStore
    @StateObject private var language: AppLanguageSettings
    @StateObject private var appearance: AppAppearanceSettings
    @StateObject private var windowPresentation = WindowPresentationController()
    @StateObject private var player = PlaybackController()
    @StateObject private var softwareUpdater = SoftwareUpdateController()

    init() {
        let storage = LibraryStorageSettings()
        _storage = StateObject(wrappedValue: storage)
        _language = StateObject(wrappedValue: AppLanguageSettings())
        _appearance = StateObject(wrappedValue: AppAppearanceSettings())
        _library = StateObject(wrappedValue: LibraryStore(
            repository: LibraryRepository(mediaURL: storage.mediaDirectoryURL)
        ))
    }

    var body: some Scene {
        WindowGroup {
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
                .environmentObject(storage)
                .environmentObject(language)
                .environmentObject(appearance)
                .environment(\.locale, language.selectedLanguage.locale ?? .current)
                .preferredColorScheme(appearance.selectedAppearance.colorScheme)
                .id(language.selectedLanguage.rawValue)
                .task { await library.load() }
        }
        .defaultSize(width: 1_320, height: 780)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.text("command.softwareUpdate")) {
                    softwareUpdater.checkForUpdates()
                }
            }

            CommandGroup(after: .newItem) {
                Button(L10n.text("command.import")) {
                    NotificationCenter.default.post(name: .requestImport, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu(L10n.text("command.library")) {
                Button(L10n.text("command.verify")) {
                    NotificationCenter.default.post(name: .requestVerification, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
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
                .environmentObject(language)
                .environmentObject(appearance)
                .id(language.selectedLanguage.rawValue)
        }
        .defaultSize(width: 761, height: 440)
        .windowResizability(.contentSize)
    }
}

extension Notification.Name {
    static let requestImport = Notification.Name("OngakuDesktop.requestImport")
    static let requestVerification = Notification.Name("OngakuDesktop.requestVerification")
}
