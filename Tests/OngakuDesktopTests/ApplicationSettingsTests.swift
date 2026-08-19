import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OngakuDesktop

@Suite("Application settings")
struct ApplicationSettingsTests {
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
        try await Task.sleep(for: .milliseconds(220))
        #expect(!controller.isMiniPlayer)
        #expect(window.styleMask.contains(.resizable))
        #expect(abs(window.frame.width - originalWindowFrame.width) < 1)
        #expect(abs(window.frame.height - originalWindowFrame.height) < 1)
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
        let originalManagedDirectory = settings.mediaDirectoryURL
        let originalSource = settings.source
        try settings.useAppleMusicLibrary(library)
        #expect(settings.source == originalSource)
        #expect(settings.musicLibraryURL == library.standardizedFileURL)
        #expect(settings.musicLibraryMediaURL == media.standardizedFileURL)
        #expect(settings.mediaDirectoryURL == originalManagedDirectory)
        #expect(!FileManager.default.fileExists(atPath: media.appendingPathComponent("Ongaku Media").path))

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

        let restored = LibraryStorageSettings(defaults: defaults)
        #expect(restored.mediaDirectoryURL == selected.standardizedFileURL)
    }
}
