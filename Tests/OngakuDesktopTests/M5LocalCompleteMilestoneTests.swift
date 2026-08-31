import Foundation
import Testing
@testable import OngakuDesktop

@Suite("M5 local complete milestone")
struct M5LocalCompleteMilestoneTests {
    @Test("External libraries survive a mount-path change and reject the wrong library")
    @MainActor
    func externalLibraryReconnect() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("Ongaku-M5-\(UUID().uuidString)", isDirectory: true)
        let firstMount = root.appendingPathComponent("First Mount", isDirectory: true)
        let secondMount = root.appendingPathComponent("Second Mount", isDirectory: true)
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let defaultsName = "OngakuDesktopTests.M5.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: firstMount, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondMount, withIntermediateDirectories: true)

        let settings = LibraryProfileSettings(
            defaultMediaURL: support.appendingPathComponent("Default Media"),
            defaults: defaults,
            fileManager: fileManager,
            applicationSupportURL: support
        )
        let localID = settings.activeLibraryID
        let externalID = try settings.createExternalLibrary(named: "Archive", in: firstMount)
        let originalProfile = try #require(settings.profiles.first { $0.id == externalID })
        #expect(originalProfile.isExternal)
        #expect(settings.connectionState(for: originalProfile) == .connected)

        let originalBytes = Data((0..<4_096).map { UInt8($0 % 251) })
        let audioURL = originalProfile.mediaURL.appendingPathComponent("Source.aiff")
        try originalBytes.write(to: audioURL, options: .atomic)
        let originalHash = try LibraryRepository.sha256(of: audioURL)

        let relocatedRoot = secondMount.appendingPathComponent(
            originalProfile.externalRootURL?.lastPathComponent ?? "Ongaku Library",
            isDirectory: true
        )
        let originalRoot = try #require(originalProfile.externalRootURL)
        try fileManager.copyItem(at: originalRoot, to: relocatedRoot)
        try fileManager.removeItem(at: originalRoot)
        settings.refreshExternalConnections()
        let disconnected = try #require(settings.profiles.first { $0.id == externalID })
        #expect(settings.connectionState(for: disconnected) != .connected)
        settings.activate(localID)
        settings.activate(externalID)
        #expect(settings.activeLibraryID == localID)

        let otherID = try settings.createExternalLibrary(named: "Other", in: firstMount)
        let otherRoot = try #require(
            settings.profiles.first { $0.id == otherID }?.externalRootURL
        )
        #expect(throws: ExternalLibraryError.wrongLibrary) {
            try settings.reconnect(externalID, to: otherRoot)
        }

        try settings.reconnect(externalID, to: relocatedRoot)
        settings.activate(externalID)
        let reconnected = try #require(settings.profiles.first { $0.id == externalID })
        #expect(settings.activeLibraryID == externalID)
        #expect(settings.connectionState(for: reconnected) == .connected)
        #expect(try Data(contentsOf: reconnected.mediaURL.appendingPathComponent("Source.aiff")) == originalBytes)
        #expect(try LibraryRepository.sha256(
            of: reconnected.mediaURL.appendingPathComponent("Source.aiff")
        ) == originalHash)
    }

    @Test("Legacy profiles decode without external-volume metadata")
    func legacyProfileCompatibility() throws {
        let id = UUID()
        let data = try #require(
            """
            {"id":"\(id.uuidString)","name":"Legacy","catalogPath":"/catalog","mediaPath":"/media","isArchived":false,"createdAt":0}
            """.data(using: .utf8)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let profile = try decoder.decode(LibraryProfile.self, from: data)
        #expect(!profile.isExternal)
        #expect(profile.externalBookmark == nil)
    }
}
