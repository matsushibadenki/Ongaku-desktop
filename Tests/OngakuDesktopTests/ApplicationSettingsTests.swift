import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OngakuDesktop

@Suite("Application settings")
struct ApplicationSettingsTests {
    @Test("App Store versions use numeric semantic comparison")
    func appStoreVersionComparison() {
        #expect(AppVersionComparison.isNewer("0.1.7", than: "0.1.6"))
        #expect(AppVersionComparison.isNewer("0.10.0", than: "0.9.9"))
        #expect(!AppVersionComparison.isNewer("0.1.7", than: "0.1.7"))
        #expect(!AppVersionComparison.isNewer("0.1.6", than: "0.1.7"))
    }

    @Test("App Store lookup response decodes the release destination")
    func appStoreLookupDecoding() throws {
        let data = Data(#"{"results":[{"version":"0.1.7","trackViewUrl":"https://apps.apple.com/jp/app/id6807717764","bundleId":"com.ongaku.desktop"}]}"#.utf8)
        let release = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data).results.first
        #expect(release?.version == "0.1.7")
        #expect(release?.bundleId == AppStoreUpdateChecker.bundleID)
        #expect(release?.trackViewUrl.host == "apps.apple.com")
    }

    @Test("Legacy catalog and artwork move beside managed music")
    func portableLibraryMigration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-Portable-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        let legacy = support.appendingPathComponent("Ongaku Desktop", isDirectory: true)
        let media = root.appendingPathComponent("Music", isDirectory: true)
        let custom = legacy.appendingPathComponent("Custom Artwork", isDirectory: true)
        let downloaded = caches.appendingPathComponent("Ongaku Desktop/Artwork", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
        try Data("catalog".utf8).write(to: legacy.appendingPathComponent("library-v1.json"))
        try Data("custom".utf8).write(to: custom.appendingPathComponent("artist.artwork"))
        try Data("downloaded".utf8).write(to: downloaded.appendingPathComponent("album.artwork"))

        let portable = try PortableLibraryStorage.migrateLegacyStateIfNeeded(
            from: legacy,
            to: media,
            applicationSupportURL: support,
            cachesURL: caches
        )

        #expect(portable == media.appendingPathComponent("Ongaku Library Data"))
        #expect(FileManager.default.fileExists(atPath: portable.appendingPathComponent("library-v1.json").path))
        #expect(FileManager.default.fileExists(atPath: portable.appendingPathComponent("Artwork/Custom/artist.artwork").path))
        #expect(FileManager.default.fileExists(atPath: portable.appendingPathComponent("Artwork/Downloaded/album.artwork").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("library-v1.json").path))
        #expect(!FileManager.default.fileExists(atPath: custom.appendingPathComponent("artist.artwork").path))
        #expect(!FileManager.default.fileExists(atPath: downloaded.appendingPathComponent("album.artwork").path))
    }

    @Test("Existing portable data is never overwritten by legacy migration")
    func portableMigrationPreservesDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-Portable-Collision-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("Legacy", isDirectory: true)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        let portableManifest = media
            .appendingPathComponent("Ongaku Library Data", isDirectory: true)
            .appendingPathComponent("library-v1.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: portableManifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("library-v1.json"))
        try Data("old queue".utf8).write(to: legacy.appendingPathComponent("playback-queue-v1.json"))
        try Data("portable".utf8).write(to: portableManifest)

        _ = try PortableLibraryStorage.migrateLegacyStateIfNeeded(from: legacy, to: media)

        #expect(try Data(contentsOf: portableManifest) == Data("portable".utf8))
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("library-v1.json").path))
        let backups = try FileManager.default.contentsOfDirectory(
            at: portableManifest.deletingLastPathComponent().appendingPathComponent("Legacy Imports"),
            includingPropertiesForKeys: nil
        )
        #expect(backups.count == 1)
        #expect(!FileManager.default.fileExists(atPath: portableManifest.deletingLastPathComponent().appendingPathComponent("playback-queue-v1.json").path))
        #expect(try Data(contentsOf: backups[0].appendingPathComponent("playback-queue-v1.json")) == Data("old queue".utf8))
        #expect(try Data(contentsOf: backups[0].appendingPathComponent("library-v1.json")) == Data("legacy".utf8))
        _ = try PortableLibraryStorage.migrateLegacyStateIfNeeded(from: legacy, to: media)
        #expect(try FileManager.default.contentsOfDirectory(atPath: portableManifest.deletingLastPathComponent().appendingPathComponent("Legacy Imports").path).count == 1)
    }

    @Test("Startup migrates legacy catalogs, retries failure, and creates portable libraries")
    @MainActor
    func startupMigrationRetriesSafely() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = root.appendingPathComponent("Support")
        let legacy = support.appendingPathComponent("Ongaku Desktop")
        let media = root.appendingPathComponent("Media")
        let suite = "Migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let bytes = Data("legacy catalog".utf8)
        try bytes.write(to: legacy.appendingPathComponent("library-v1.json"))
        // A file where the media directory should be simulates an unavailable destination.
        try Data("blocked".utf8).write(to: media)
        let failed = LibraryProfileSettings(defaultMediaURL: media, defaults: defaults, applicationSupportURL: support)
        #expect(failed.migrationError != nil)
        #expect(try Data(contentsOf: legacy.appendingPathComponent("library-v1.json")) == bytes)
        try FileManager.default.removeItem(at: media)
        let restored = LibraryProfileSettings(defaultMediaURL: media, defaults: defaults, applicationSupportURL: support)
        #expect(restored.migrationError == nil)
        #expect(restored.activeProfile.catalogURL == PortableLibraryStorage(mediaURL: media).rootURL)
        #expect(try Data(contentsOf: restored.activeProfile.catalogURL.appendingPathComponent("library-v1.json")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("library-v1.json").path))
        try restored.createLibrary(named: "Second")
        #expect(!restored.activeProfile.catalogPath.hasPrefix(support.path))
        #expect(!restored.activeProfile.mediaPath.hasPrefix(support.path))
        // A previous app can leave legacy data even after profiles were migrated.
        try bytes.write(to: legacy.appendingPathComponent("library-v1.json"))
        let again = LibraryProfileSettings(defaultMediaURL: media, defaults: defaults, applicationSupportURL: support)
        #expect(again.migrationError == nil)
        #expect(try Data(contentsOf: again.activeProfile.catalogURL.appendingPathComponent("library-v1.json")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("library-v1.json").path))
    }

    @Test("A completely fresh install stores managed music under the Music directory")
    @MainActor
    func freshInstallMusicDirectoryDefault() {
        let suiteName = "OngakuDesktopTests.FreshStorage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let music = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fresh Music", isDirectory: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = LibraryStorageSettings(
            defaults: defaults,
            freshMusicDirectoryURL: music
        )

        #expect(
            settings.mediaDirectoryURL
                == music.appendingPathComponent(
                    "Ongaku Desktop/Ongaku Media",
                    isDirectory: true
                ).standardizedFileURL
        )
        #expect(settings.source == .musicDirectory)
    }

    @Test("Appearance selection persists and system mode clears the override")
    @MainActor
    func appearancePersistence() {
        let suiteName = "OngakuDesktopTests.Appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppAppearanceSettings(defaults: defaults)
        #expect(settings.selectedAppearance == .system)

        settings.selectedAppearance = .light
        #expect(defaults.string(forKey: AppAppearanceSettings.defaultsKey) == "light")
        #expect(settings.selectedAppearance.colorScheme == ColorScheme.light)

        settings.selectedAppearance = .system
        #expect(defaults.object(forKey: AppAppearanceSettings.defaultsKey) == nil)
        #expect(settings.selectedAppearance.colorScheme == nil)
    }

    @Test("Player presentation settings persist and the player defaults to the bottom")
    @MainActor
    func playerMeterPersistence() {
        let suiteName = "OngakuDesktopTests.PlayerMeter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PlayerMeterSettings(defaults: defaults)
        #expect(settings.style == .spectrum)
        #expect(settings.backlight == .cyan)
        #expect(settings.barPosition == .bottom)

        settings.style = .vu
        settings.backlight = .orange
        settings.barPosition = .top

        let restored = PlayerMeterSettings(defaults: defaults)
        #expect(restored.style == .vu)
        #expect(restored.backlight == .orange)
        #expect(restored.barPosition == .top)
    }

    @Test("Song list columns and sorting persist")
    @MainActor
    func trackTablePersistence() {
        let suiteName = "OngakuDesktopTests.TrackTable.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TrackTableSettings(defaults: defaults)
        #expect(settings.visibleColumns == Set(TrackTableColumn.allCases))
        #expect(settings.sortField == .title)
        #expect(settings.sortAscending)

        settings.visibleColumns.remove(.health)
        settings.visibleColumns.remove(.album)
        settings.sortField = .artist
        settings.sortAscending = false

        let restored = TrackTableSettings(defaults: defaults)
        #expect(restored.visibleColumns == [.artist, .duration])
        #expect(restored.sortField == .artist)
        #expect(!restored.sortAscending)
    }

    @Test("Multiple libraries create, rename, switch, archive, and restore")
    @MainActor
    func libraryProfilePersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-Profiles-\(UUID().uuidString)", isDirectory: true)
        let media = root.appendingPathComponent("Legacy Media", isDirectory: true)
        let suiteName = "OngakuDesktopTests.Profiles.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let settings = LibraryProfileSettings(
            defaultMediaURL: media,
            defaults: defaults,
            applicationSupportURL: root
        )
        #expect(
            settings.activeProfile.catalogURL
                == media.appendingPathComponent("Ongaku Library Data", isDirectory: true)
        )
        let mainID = settings.activeLibraryID
        let secondID = try settings.createLibrary(named: "Classical")
        #expect(settings.activeLibraryID == secondID)
        #expect(FileManager.default.fileExists(atPath: settings.activeProfile.mediaPath))
        settings.rename(secondID, to: "Classical Archive")
        settings.activate(mainID)
        settings.archive(secondID)
        #expect(settings.archivedProfiles.map(\.id) == [secondID])
        settings.unarchive(secondID)
        #expect(settings.availableProfiles.count == 2)

        let restored = LibraryProfileSettings(
            defaultMediaURL: root.appendingPathComponent("New Default Must Be Ignored"),
            defaults: defaults,
            applicationSupportURL: root
        )
        #expect(restored.activeLibraryID == mainID)
        #expect(restored.activeProfile.mediaURL == media.standardizedFileURL)
        #expect(restored.profiles.first { $0.id == secondID }?.name == "Classical Archive")
    }

    @Test("Switching libraries isolates tracks and playback state")
    @MainActor
    func librarySwitchIsolation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-Switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = root.appendingPathComponent("First", isDirectory: true)
        let secondRoot = root.appendingPathComponent("Second", isDirectory: true)
        let firstTrack = Track(
            id: UUID(), title: "First Song", artist: "Artist", album: "Album",
            duration: 10, fileSize: 1, managedPath: "/tmp/first.m4a",
            sha256: "first", addedAt: .now, health: .verified
        )
        let secondTrack = Track(
            id: UUID(), title: "Second Song", artist: "Artist", album: "Album",
            duration: 10, fileSize: 1, managedPath: "/tmp/second.m4a",
            sha256: "second", addedAt: .now, health: .verified
        )
        try await LibraryRepository(rootURL: firstRoot).save(tracks: [firstTrack])
        try await LibraryRepository(rootURL: secondRoot).save(tracks: [secondTrack])
        let store = LibraryStore(repository: LibraryRepository(rootURL: firstRoot))
        await store.load()
        #expect(store.tracks.map(\.id) == [firstTrack.id])

        await store.switchLibrary(
            catalogURL: secondRoot,
            mediaURL: secondRoot.appendingPathComponent("Ongaku Media")
        )
        #expect(store.tracks.map(\.id) == [secondTrack.id])
        #expect(store.selectedPlaylistID == nil)
        #expect(store.searchText.isEmpty)
    }

    @Test("Mini Player restores the original window frame")
    @MainActor
    func miniPlayerWindowRestoration() async throws {
        let originalFrame = NSRect(x: 80, y: 120, width: 1_320, height: 780)
        let window = NSWindow(
            contentRect: originalFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let originalWindowFrame = window.frame
        let controller = WindowPresentationController()
        controller.attach(to: window)

        controller.toggleMiniPlayer(in: window)
        try await Task.sleep(for: .milliseconds(20))
        #expect(controller.isMiniPlayer)
        #expect(abs(window.contentLayoutRect.width - WindowPresentationController.miniContentSize.width) < 1)
        #expect(abs(window.contentLayoutRect.height - WindowPresentationController.miniContentSize.height) < 1)
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.contentMinSize == WindowPresentationController.miniContentSize)
        #expect(window.contentMaxSize == WindowPresentationController.miniContentSize)
        #expect(window.minSize == window.maxSize)
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == false)

        controller.toggleMiniPlayer(in: window)
        #expect(!controller.isMiniPlayer)
        #expect(window.styleMask.contains(.resizable))
        #expect(abs(window.frame.width - originalWindowFrame.width) < 1)
        #expect(abs(window.frame.height - originalWindowFrame.height) < 1)
    }

    @Test("The main window keeps all columns below the title bar")
    @MainActor
    func mainWindowRespectsTitleBarSafeArea() {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 120, width: 1_320, height: 780),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true

        WindowPresentationController().attach(to: window)

        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(!window.titlebarAppearsTransparent)
        #expect(window.contentLayoutRect.maxY < window.frame.height)
    }

    @Test("Title-bar dragging uses screen coordinates across window movement")
    func titleBarDragCoordinates() {
        let drag = TitleBarDrag(
            windowOrigin: NSPoint(x: -400, y: 80),
            mouseOrigin: NSPoint(x: -100, y: 600)
        )
        #expect(drag.windowOrigin(for: NSPoint(x: 40, y: 560)) == NSPoint(x: -260, y: 40))
        #expect(drag.windowOrigin(for: NSPoint(x: -100, y: 600)) == NSPoint(x: -400, y: 80))
    }

    @Test("Title-bar dragging excludes content and window controls")
    @MainActor
    func titleBarDragHitRegions() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 120, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = WindowPresentationController()
        controller.attach(to: window)
        let titlePoint = NSPoint(x: 450, y: window.frame.height - 10)
        #expect(TitleBarDrag.canStart(in: window, at: titlePoint))
        #expect(!TitleBarDrag.canStart(in: window, at: NSPoint(x: 450, y: 100)))
        let close = try #require(window.standardWindowButton(.closeButton))
        let closePoint = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        #expect(!TitleBarDrag.canStart(in: window, at: closePoint))
        window.isMovable = false
        #expect(!TitleBarDrag.canStart(in: window, at: titlePoint))
    }

    @Test("A selected Apple Music library resolves and persists its Media folder")
    @MainActor
    func appleMusicLibraryPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = root.appendingPathComponent("Music Library.musiclibrary", isDirectory: true)
        let media = root.appendingPathComponent("Media.localized", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        let suiteName = "OngakuDesktopTests.Storage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let settings = LibraryStorageSettings(defaults: defaults)
        try settings.useAppleMusicLibrary(library)
        #expect(settings.source == .selectedAppleMusicLibrary)
        #expect(settings.musicLibraryURL == library.standardizedFileURL)
        #expect(settings.musicLibraryMediaURL == media.standardizedFileURL)
        #expect(settings.mediaDirectoryURL == media.appendingPathComponent("Ongaku Media", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: settings.mediaDirectoryURL.path))

        let restored = LibraryStorageSettings(defaults: defaults)
        #expect(restored.musicLibraryURL == library.standardizedFileURL)
        #expect(restored.musicLibraryMediaURL == media.standardizedFileURL)
        #expect(restored.mediaDirectoryURL == settings.mediaDirectoryURL)
    }

    @Test("A user-selected storage directory is used directly")
    @MainActor
    func selectedDirectoryIsUsedDirectly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selected = root.appendingPathComponent("My Managed Music", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let suiteName = "OngakuDesktopTests.DirectStorage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let settings = LibraryStorageSettings(defaults: defaults)
        try settings.useSelectedDirectory(selected)
        #expect(settings.mediaDirectoryURL == selected.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: selected.appendingPathComponent("Ongaku Media").path))

        let unrelatedNewDefault = root.appendingPathComponent("Different Music", isDirectory: true)
        let restored = LibraryStorageSettings(
            defaults: defaults,
            freshMusicDirectoryURL: unrelatedNewDefault
        )
        #expect(restored.mediaDirectoryURL == selected.standardizedFileURL)
    }
    @Test("Storage activation creates a catalog, reopens it, and preserves the old library on failure")
    @MainActor
    func storageActivationRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Ongaku.StorageActivation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        let firstCatalog = PortableLibraryStorage(mediaURL: first).rootURL
        let repository = LibraryRepository(rootURL: firstCatalog, mediaURL: first)
        let track = Track(
            id: UUID(), title: "Original", artist: "Artist", album: "Album", duration: 10,
            fileSize: 1, managedPath: first.appendingPathComponent("original.mp3").path,
            sha256: "original", addedAt: .now, health: .verified
        )
        try await repository.save(tracks: [track])
        let playlist = Playlist(name: "Original playlist", entries: [PlaylistEntry(trackID: track.id)])
        let queue = PlaybackQueueState(trackIDs: [track.id], currentTrackID: track.id, position: 4)
        try await repository.save(playlists: [playlist])
        try await repository.save(playbackQueue: queue)
        let firstID = try await repository.load().document.libraryID
        let store = LibraryStore(repository: repository)
        await store.load()
        // Player notifications can arrive while the destination's asynchronous load is in progress.
        let queueNotification = store.$audioFeatureRevision.sink { _ in
            if store.isSwitchingLibrary {
                store.schedulePlaybackQueueSave(PlaybackQueueState())
            }
        }
        defer { queueNotification.cancel() }
        let settings = LibraryStorageSettings(defaults: defaults, freshMusicDirectoryURL: root)
        let profiles = LibraryProfileSettings(
            defaultMediaURL: first, defaults: defaults, applicationSupportURL: root.appendingPathComponent("Support")
        )
        try await settings.activateDirectory(second) { try await store.openStorageDirectory($0) }
        profiles.adoptActiveStorageLocation(second)
        let secondCatalog = PortableLibraryStorage(mediaURL: second).rootURL
        #expect(store.tracks.isEmpty)
        #expect(profiles.activeProfile.catalogURL == secondCatalog)
        for name in ["library-v1.json", "playback-queue-v1.json", "playback-events-v1.json", "Artwork/Custom", "Artwork/Downloaded"] {
            #expect(FileManager.default.fileExists(atPath: secondCatalog.appendingPathComponent(name).path))
        }
        #expect(FileManager.default.fileExists(atPath: firstCatalog.appendingPathComponent("library-v1.json").path))
        let secondRepository = LibraryRepository(rootURL: secondCatalog, mediaURL: second)
        let secondID = try await secondRepository.load().document.libraryID
        #expect(secondID != firstID)
        try await settings.activateDirectory(first) { try await store.openStorageDirectory($0) }
        profiles.adoptActiveStorageLocation(first)
        #expect(store.tracks.map(\.id) == [track.id])
        #expect(store.playlists.map(\.id) == [playlist.id])
        #expect(store.playbackQueue == queue)
        #expect(try await LibraryRepository(rootURL: firstCatalog, mediaURL: first).load().document.libraryID == firstID)
        #expect(try await LibraryRepository(rootURL: secondCatalog, mediaURL: second).load().document.libraryID == secondID)
        let restored = LibraryStorageSettings(defaults: defaults)
        #expect(restored.mediaDirectoryURL == first)

        let broken = root.appendingPathComponent("Broken", isDirectory: true)
        let brokenCatalog = PortableLibraryStorage(mediaURL: broken).rootURL
        try FileManager.default.createDirectory(at: brokenCatalog, withIntermediateDirectories: true)
        let corruptData = Data("broken catalog".utf8)
        try corruptData.write(to: brokenCatalog.appendingPathComponent("library-v1.json"))
        do {
            try await settings.activateDirectory(broken) { try await store.openStorageDirectory($0) }
            Issue.record("Corrupt storage was activated")
        } catch {
            #expect(settings.mediaDirectoryURL == first)
            #expect(store.tracks.map(\.id) == [track.id])
            #expect(profiles.activeProfile.mediaURL == first)
            #expect(try Data(contentsOf: brokenCatalog.appendingPathComponent("library-v1.json")) == corruptData)
        }
    }

    @Test("Selecting another Music library opens its own Ongaku storage and persists it")
    @MainActor
    func musicStorageActivation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Ongaku.MusicActivation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let settings = LibraryStorageSettings(defaults: defaults, freshMusicDirectoryURL: root)
        let store = LibraryStore(repository: LibraryRepository(mediaURL: settings.mediaDirectoryURL))
        await store.load()
        var ids: [UUID] = []
        for name in ["First", "Second", "First"] {
            let parent = root.appendingPathComponent(name, isDirectory: true)
            let music = parent.appendingPathComponent("Music Library.musiclibrary", isDirectory: true)
            let media = parent.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let sentinel = music.appendingPathComponent("Library.musicdb")
            let original = Data("Apple Music database".utf8)
            try original.write(to: sentinel)
            try await settings.activateAppleMusicLibrary(music) { try await store.openStorageDirectory($0) }
            #expect(settings.mediaDirectoryURL == media.appendingPathComponent("Ongaku Media", isDirectory: true))
            #expect(settings.source == .selectedAppleMusicLibrary)
            #expect(settings.musicLibraryMediaURL == media)
            #expect(try Data(contentsOf: sentinel) == original)
            let catalog = PortableLibraryStorage(mediaURL: settings.mediaDirectoryURL).rootURL
            ids.append(try await LibraryRepository(rootURL: catalog, mediaURL: settings.mediaDirectoryURL).load().document.libraryID)
            let restored = LibraryStorageSettings(defaults: defaults)
            #expect(restored.mediaDirectoryURL == settings.mediaDirectoryURL)
            #expect(restored.source == .selectedAppleMusicLibrary)
        }
        #expect(ids[0] != ids[1])
        #expect(ids[0] == ids[2])

        // A Media folder can live somewhere other than beside the package.
        let customMedia = root.appendingPathComponent("External Media", isDirectory: true)
        try FileManager.default.createDirectory(at: customMedia, withIntermediateDirectories: true)
        let music = root.appendingPathComponent("First/Music Library.musiclibrary", isDirectory: true)
        try await settings.activateAppleMusicLibrary(music, authorizedMediaURL: customMedia) {
            try await store.openStorageDirectory($0)
        }
        let managed = customMedia.appendingPathComponent("Ongaku Media", isDirectory: true)
        #expect(settings.mediaDirectoryURL == managed)
        let bookmarks = try #require(defaults.dictionary(forKey: "library.storage.mediaAccessBookmarks.v1"))
        #expect(bookmarks[managed.path] is Data)
    }

}
