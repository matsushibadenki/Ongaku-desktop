import Foundation
import Testing
@testable import OngakuDesktop

@Suite("M3 library management milestone")
struct M3LibraryManagementMilestoneTests {
    private static let resourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/OngakuDesktop/Resources", isDirectory: true)

    @Test("Duplicate deletion explains the exact target and recovery policy in every language")
    func deletionImpactIsExplicit() throws {
        for language in ["en", "ja", "zh-Hans"] {
            let strings = try localizationStrings(language)
            let format = try #require(strings["duplicates.confirm.message"])
            let message = String(format: format, locale: Locale(identifier: "en_US_POSIX"), 2)
            #expect(message.contains("2"))
            #expect(message != "duplicates.confirm.message")
        }
    }

    @Test("Managed duplicate files are recoverable while external references remain untouched")
    func deletionPolicyMatchesTheConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-M3-Deletion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("Ongaku Media", isDirectory: true)
        let external = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        let managedURL = media.appendingPathComponent("managed.m4a")
        let externalURL = external.appendingPathComponent("external.m4a")
        try Data("managed".utf8).write(to: managedURL)
        try Data("external".utf8).write(to: externalURL)
        let managed = makeTrack(url: managedURL, hash: "managed")
        let referenced = makeTrack(url: externalURL, hash: "external")
        let repository = LibraryRepository(rootURL: root, mediaURL: media)

        let result = await repository.trashManagedFiles(
            removedTracks: [managed, referenced],
            retainedTracks: []
        )

        #expect(result.trashed == 1)
        #expect(result.retained == 1)
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: managedURL.path))
        #expect(FileManager.default.fileExists(atPath: externalURL.path))
    }

    private func makeTrack(url: URL, hash: String) -> Track {
        Track(
            id: UUID(), title: url.deletingPathExtension().lastPathComponent,
            artist: "Artist", album: "Album", duration: 1, fileSize: 1,
            managedPath: url.path, sha256: hash, addedAt: .now, health: .verified
        )
    }

    private func localizationStrings(_ language: String) throws -> [String: String] {
        let url = Self.resourceRoot
            .appendingPathComponent("\(language).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(propertyList as? [String: String])
    }
}
