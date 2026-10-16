import Combine
import CryptoKit
import Foundation

/// Files that define an Ongaku library live beside its managed music so the
/// complete library can be moved to another Mac as one folder.
enum LibraryMigrationRecovery {
    /// Only a completed scan with no library artifacts may offer creation.
    nonisolated static func canOfferCreation(after error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "OngakuMigration" && error.code == 7
    }
    nonisolated static func catalogIdentity(at catalog: URL) -> String? {
        guard let data = try? Data(contentsOf: catalog.appendingPathComponent("library-v1.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["libraryID"] as? String
    }

    nonisolated static func relocatedMedia(
        originalMedia: URL, originalRoot: URL, resolvedRoot: URL, libraryID: String
    ) -> URL? {
        let oldRoot = originalRoot.standardizedFileURL.path
        let oldMedia = originalMedia.standardizedFileURL.path
        let oldPrefix = oldRoot == "/" ? "/" : oldRoot + "/"
        guard oldMedia == oldRoot || oldMedia.hasPrefix(oldPrefix) else { return nil }
        let relative = oldMedia == oldRoot ? "" : String(oldMedia.dropFirst(oldPrefix.count))
        let root = resolvedRoot.resolvingSymlinksInPath().standardizedFileURL
        let candidate = relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: true)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path == "/" ? "/" : root.path + "/"),
              catalogIdentity(at: PortableLibraryStorage(mediaURL: resolved).rootURL) == libraryID else { return nil }
        return resolved
    }

    nonisolated static func reconnectedMedia(
        originalMedia: URL, originalRoot: URL, resolvedRoot: URL, libraryID: String
    ) throws -> URL {
        if let media = relocatedMedia(originalMedia: originalMedia, originalRoot: originalRoot,
                                      resolvedRoot: resolvedRoot, libraryID: libraryID) { return media }
        return try findMediaDirectory(in: resolvedRoot, expectedMedia: originalMedia,
                                      expectedCatalog: PortableLibraryStorage(mediaURL: originalMedia).rootURL,
                                      expectedLibraryID: libraryID)
    }

    nonisolated static func findMediaDirectory(
        in selected: URL, expectedMedia: URL, expectedCatalog: URL,
        expectedLibraryID: String? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = selected.resolvingSymlinksInPath().standardizedFileURL
        let expected = expectedMedia.resolvingSymlinksInPath().standardizedFileURL
        func identity(_ catalog: URL) -> String? {
            guard let data = try? Data(contentsOf: catalog.appendingPathComponent("library-v1.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["libraryID"] as? String
        }
        let expectedID = expectedLibraryID ?? identity(expectedCatalog)
        let hasLegacyCatalog = fileManager.fileExists(
            atPath: expectedCatalog.appendingPathComponent("library-v1.json").path
        )
        var queue: [(URL, Int)] = [(root, 0)]
        var visited = 0
        var candidates: [String: URL] = [:]
        var foundRelatedData = false
        while visited < queue.count {
            try Task.checkCancellation()
            guard visited < 4_096 else {
                throw NSError(domain: "OngakuMigration", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: L10n.text("storage.migration.scanLimit"),
                ])
            }
            let (directory, depth) = queue[visited]
            visited += 1
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let media = (directory.lastPathComponent == PortableLibraryStorage.directoryName
                ? directory.deletingLastPathComponent() : directory)
                .resolvingSymlinksInPath().standardizedFileURL
            let catalog = PortableLibraryStorage(mediaURL: media).rootURL
            let hasCatalog = fileManager.fileExists(atPath: catalog.appendingPathComponent("library-v1.json").path)
            if directory.lastPathComponent == PortableLibraryStorage.directoryName || hasCatalog
                || fileManager.fileExists(atPath: directory.appendingPathComponent(".ongaku-library.json").path) {
                foundRelatedData = true
            }
            if hasCatalog || (directory.lastPathComponent == "Ongaku Media"
                && (directory.path == expected.path || hasLegacyCatalog)) {
                let candidateID = identity(catalog)
                if candidateID == expectedID && candidateID != nil
                    || expectedID == nil
                    || (expectedLibraryID == nil && (!hasCatalog || media.path == expected.path)) {
                    candidates[media.path] = media
                }
                // Never scan audio files or derived data inside a found library.
                continue
            }
            guard depth < 5 else { continue }
            let children = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for child in children {
                if child.lastPathComponent.hasPrefix("library-v1.")
                    || child.lastPathComponent.hasPrefix("library-schema-")
                    || child.lastPathComponent == "storage-recovery-v1.json" {
                    foundRelatedData = true
                }
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true {
                    guard queue.count < 4_096 else {
                        throw NSError(domain: "OngakuMigration", code: 4, userInfo: [
                            NSLocalizedDescriptionKey: L10n.text("storage.migration.scanLimit"),
                        ])
                    }
                    queue.append((child, depth + 1))
                }
            }
        }
        if let exact = candidates[expected.path] { return exact }
        guard candidates.count == 1, let match = candidates.values.first else {
            throw NSError(domain: "OngakuMigration", code: candidates.isEmpty && !foundRelatedData ? 7 : 3, userInfo: [
                NSLocalizedDescriptionKey: L10n.text(candidates.isEmpty
                    ? "storage.migration.notFound" : "storage.migration.ambiguous"),
            ])
        }
        return match
    }
}

struct PortableLibraryStorage: Sendable {
    static let directoryName = "Ongaku Library Data"

    let mediaURL: URL

    static func relocateLegacyMedia(from source: URL, to destination: URL, fileManager: FileManager) throws {
        try moveIfDestinationIsMissing(from: source, to: destination, fileManager: fileManager)
    }

    var rootURL: URL {
        mediaURL.standardizedFileURL
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    var downloadedArtworkURL: URL {
        rootURL.appendingPathComponent("Artwork/Downloaded", isDirectory: true)
    }

    var customArtworkURL: URL {
        rootURL.appendingPathComponent("Artwork/Custom", isDirectory: true)
    }

    /// Moves legacy state item-by-item. Each item is first copied to a staging
    /// location on the destination volume, then atomically installed. The old
    /// copy is removed only after the destination has been verified.
    static func migrateLegacyStateIfNeeded(
        from legacyCatalogURL: URL,
        to mediaURL: URL,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil,
        cachesURL: URL? = nil,
        removeLegacyArtwork: Bool = true
    ) throws -> URL {
        let layout = Self(mediaURL: mediaURL)
        try fileManager.createDirectory(at: layout.rootURL, withIntermediateDirectories: true)

        if legacyCatalogURL.standardizedFileURL != layout.rootURL.standardizedFileURL {
            let catalogNames = try legacyCatalogItemNames(
                at: legacyCatalogURL,
                fileManager: fileManager
            )
            // Keep a complete source set before removing any item. In particular,
            // queues and history must not be mixed into a different library ID.
            let sourceManifest = legacyCatalogURL.appendingPathComponent("library-v1.json")
            let destinationManifest = layout.rootURL.appendingPathComponent("library-v1.json")
            let hasConflict = try fileManager.fileExists(atPath: sourceManifest.path)
                && fileManager.fileExists(atPath: destinationManifest.path)
                && !itemsMatch(sourceManifest, destinationManifest, fileManager: fileManager)
            let target = hasConflict
                ? layout.rootURL.appendingPathComponent("Legacy Imports/\(UUID().uuidString)", isDirectory: true)
                : layout.rootURL
            // Conflicting catalogs stay independently recoverable, never overwrite
            // the current library or attach their sidecars to it.
            if hasConflict {
                for name in catalogNames {
                    try moveIfDestinationIsMissing(
                        from: legacyCatalogURL.appendingPathComponent(name),
                        to: target.appendingPathComponent(name),
                        fileManager: fileManager,
                        removeSource: false
                    )
                }
            }
            // Remove the source manifest last so an interrupted conflicting
            // migration cannot mistake leftover sidecars for the active library.
            for name in catalogNames.sorted(by: { lhs, rhs in
                if lhs == "library-v1.json" { return false }
                if rhs == "library-v1.json" { return true }
                return lhs < rhs
            }) {
                try moveIfDestinationIsMissing(
                    from: legacyCatalogURL.appendingPathComponent(name),
                    to: target.appendingPathComponent(name),
                    fileManager: fileManager
                )
            }
        }

        let support = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let support {
            try moveDirectoryContentsIfMissing(
                from: support
                    .appendingPathComponent("Ongaku Desktop", isDirectory: true)
                    .appendingPathComponent("Custom Artwork", isDirectory: true),
                to: layout.customArtworkURL,
                fileManager: fileManager,
                removeSource: removeLegacyArtwork
            )
        }

        let caches = cachesURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let caches {
            try moveDirectoryContentsIfMissing(
                from: caches
                    .appendingPathComponent("Ongaku Desktop", isDirectory: true)
                    .appendingPathComponent("Artwork", isDirectory: true),
                to: layout.downloadedArtworkURL,
                fileManager: fileManager,
                removeSource: removeLegacyArtwork
            )
        }
        return layout.rootURL
    }

    private static func legacyCatalogItemNames(
        at rootURL: URL,
        fileManager: FileManager
    ) throws -> [String] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let names = try fileManager.contentsOfDirectory(atPath: rootURL.path)
        let exactNames: Set<String> = [
            "Incoming", "Playlist Artwork", "library-v1.json", "library-v1.backup.json",
            "import-journal-v1.json", "media-organization-journal-v1.json",
            "audio-features-v1.json", "device-sync-tags-v1.json",
            "storage-recovery-v1.json", "Recovery Backups", "Legacy Imports",
            "playback-queue-v1.json", "playback-queue-v1.backup.json",
            "playback-events-v1.json", "playback-events-v1.backup.json", "Artwork",
            "catalog-prototype-v1.sqlite", "catalog-prototype-v1.migrating.sqlite",
            "catalog-prototype-v1.previous.sqlite", "catalog-json-rollback.json",
        ]
        return names.filter { name in
            exactNames.contains(name)
                || name.hasPrefix("library-schema-")
                || name.hasPrefix("library-unversioned.")
                || name.hasPrefix("catalog-prototype-v1.sqlite-")
        }
    }

    private static func moveDirectoryContentsIfMissing(
        from source: URL,
        to destination: URL,
        fileManager: FileManager,
        removeSource: Bool
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) {
            try moveIfDestinationIsMissing(
                from: source.appendingPathComponent(name),
                to: destination.appendingPathComponent(name),
                fileManager: fileManager,
                removeSource: removeSource
            )
        }
        if removeSource,
           (try? fileManager.contentsOfDirectory(atPath: source.path).isEmpty) == true {
            try? fileManager.removeItem(at: source)
        }
    }

    private static func moveIfDestinationIsMissing(
        from source: URL,
        to destination: URL,
        fileManager: FileManager,
        removeSource: Bool = true
    ) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            if removeSource {
                if try itemsMatch(source, destination, fileManager: fileManager) {
                    try fileManager.removeItem(at: source)
                } else {
                    let preserved = destination.deletingLastPathComponent()
                        .appendingPathComponent("Migration Conflicts/\(UUID().uuidString)", isDirectory: true)
                        .appendingPathComponent(source.lastPathComponent)
                    try moveIfDestinationIsMissing(from: source, to: preserved, fileManager: fileManager)
                }
            }
            return
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).migration-\(UUID().uuidString)"
        )
        do {
            try fileManager.copyItem(at: source, to: staging)
            guard try itemsMatch(source, staging, fileManager: fileManager) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try fileManager.moveItem(at: staging, to: destination)
            if removeSource { try fileManager.removeItem(at: source) }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func itemsMatch(
        _ lhs: URL,
        _ rhs: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let leftValues = try lhs.resourceValues(forKeys: keys)
        let rightValues = try rhs.resourceValues(forKeys: keys)
        guard leftValues.isDirectory == rightValues.isDirectory else { return false }
        if leftValues.isDirectory != true {
            let leftHash = try sha256(of: lhs)
            let rightHash = try sha256(of: rhs)
            return leftValues.fileSize == rightValues.fileSize
                && leftHash == rightHash
        }
        let left = try fileManager.subpathsOfDirectory(atPath: lhs.path).sorted()
        let right = try fileManager.subpathsOfDirectory(atPath: rhs.path).sorted()
        guard left == right else { return false }
        for relativePath in left {
            let leftItem = lhs.appendingPathComponent(relativePath)
            let rightItem = rhs.appendingPathComponent(relativePath)
            let leftItemValues = try leftItem.resourceValues(forKeys: keys)
            let rightItemValues = try rightItem.resourceValues(forKeys: keys)
            guard leftItemValues.isDirectory == rightItemValues.isDirectory else { return false }
            if leftItemValues.isDirectory != true {
                let leftHash = try sha256(of: leftItem)
                let rightHash = try sha256(of: rightItem)
                guard leftItemValues.fileSize == rightItemValues.fileSize,
                      leftHash == rightHash else { return false }
            }
        }
        return true
    }

    private static func sha256(of url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize()
    }
}

struct LibraryProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var catalogPath: String
    var mediaPath: String
    var isArchived: Bool
    var createdAt: Date
    var externalRootPath: String? = nil
    var externalBookmark: Data? = nil
    var externalVolumeName: String? = nil

    var catalogURL: URL { URL(fileURLWithPath: catalogPath, isDirectory: true) }
    var mediaURL: URL { URL(fileURLWithPath: mediaPath, isDirectory: true) }
    var externalRootURL: URL? {
        externalRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    var isExternal: Bool { externalRootPath != nil }
}

enum LibraryProfileConnectionState: Equatable, Sendable {
    case connected
    case disconnected(volumeName: String?)
}

enum ExternalLibraryError: LocalizedError, Equatable {
    case invalidLocation
    case markerMissing
    case wrongLibrary

    var errorDescription: String? {
        switch self {
        case .invalidLocation: L10n.text("libraryProfile.external.error.invalidLocation")
        case .markerMissing: L10n.text("libraryProfile.external.error.markerMissing")
        case .wrongLibrary: L10n.text("libraryProfile.external.error.wrongLibrary")
        }
    }
}

@MainActor
final class LibraryProfileSettings: ObservableObject {
    nonisolated static let profilesKey = "library.profiles.v1"
    nonisolated static let activeProfileKey = "library.profiles.active.v1"

    @Published private(set) var profiles: [LibraryProfile] {
        didSet { persistProfiles() }
    }
    @Published private(set) var activeLibraryID: LibraryProfile.ID {
        didSet { defaults.set(activeLibraryID.uuidString, forKey: Self.activeProfileKey) }
    }
    @Published private(set) var activeLocationRevision = 0
    @Published private(set) var migrationError: String?

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let librariesRootURL: URL
    private let legacyRootURL: URL
    private var securityScopedProfileURLs: [LibraryProfile.ID: URL] = [:]
    private var unavailableRecoveryProfiles: Set<LibraryProfile.ID> = []

    private struct ExternalLibraryMarker: Codable {
        let libraryID: UUID
        let createdAt: Date
    }

    private static let externalMarkerName = ".ongaku-library.json"

    init(
        defaultMediaURL: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        let support = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyRoot = support.appendingPathComponent("Ongaku Desktop", isDirectory: true)
        legacyRootURL = legacyRoot
        let musicRoot = fileManager.urls(for: .musicDirectory, in: .userDomainMask)[0]
        let safeDefaultMedia = defaultMediaURL.path.hasPrefix(legacyRoot.path + "/")
            ? musicRoot.appendingPathComponent("Ongaku Desktop/Ongaku Media", isDirectory: true)
            : defaultMediaURL
        librariesRootURL = PortableLibraryStorage(mediaURL: safeDefaultMedia).rootURL
            .appendingPathComponent("Libraries", isDirectory: true)

        let initialProfiles: [LibraryProfile]
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([LibraryProfile].self, from: data),
           !decoded.isEmpty {
            initialProfiles = decoded
        } else {
            initialProfiles = [LibraryProfile(
                id: UUID(),
                name: L10n.text("libraryProfile.defaultName"),
                catalogPath: legacyRoot.path,
                mediaPath: defaultMediaURL.standardizedFileURL.path,
                isArchived: false,
                createdAt: .now
            )]
        }
        let savedID = defaults.string(forKey: Self.activeProfileKey).flatMap(UUID.init(uuidString:))
        profiles = initialProfiles
        activeLibraryID = initialProfiles.first(where: {
            $0.id == savedID && !$0.isArchived && Self.isReachable($0, fileManager: fileManager)
        })?.id
            ?? initialProfiles.first(where: {
                !$0.isArchived && Self.isReachable($0, fileManager: fileManager)
            })?.id
            ?? initialProfiles.first(where: { !$0.isArchived })?.id
            ?? initialProfiles[0].id
        resolveExternalBookmarks()
        // Restore recovery grants before startup tries to migrate any profile.
        // Storage settings may initially point at a different active profile.
        let recoveryBookmarks = defaults.dictionary(forKey: LibraryStorageSettings.migrationAccessKey) ?? [:]
        var locations = defaults.dictionary(forKey: LibraryStorageSettings.migrationLocationsKey) ?? [:]
        for index in profiles.indices where securityScopedProfileURLs[profiles[index].id] == nil {
            let profile = profiles[index]
            let oldPath = profile.mediaURL.standardizedFileURL.path
            guard let data = recoveryBookmarks[oldPath] as? Data else {
                if locations[oldPath] != nil {
                    unavailableRecoveryProfiles.insert(profile.id)
                    if profile.id == activeLibraryID { migrationError = L10n.text("storage.migration.notFound") }
                }
                continue
            }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                securityScopedProfileURLs[profile.id] = url
                if let record = locations[oldPath] as? [String: String],
                   let rootPath = record["rootPath"], let libraryID = record["libraryID"] {
                    do {
                    let media = try LibraryMigrationRecovery.reconnectedMedia(
                        originalMedia: profile.mediaURL, originalRoot: URL(fileURLWithPath: rootPath),
                        resolvedRoot: url, libraryID: libraryID
                    )
                    if media.path != oldPath {
                    profiles[index].mediaPath = media.path
                    profiles[index].catalogPath = PortableLibraryStorage(mediaURL: media).rootURL.path
                    var bookmarks = defaults.dictionary(forKey: LibraryStorageSettings.migrationAccessKey) ?? [:]
                    bookmarks[media.path] = (try? url.bookmarkData(
                        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
                    )) ?? data
                    locations[media.path] = ["rootPath": url.standardizedFileURL.path, "libraryID": libraryID]
                    defaults.set(bookmarks, forKey: LibraryStorageSettings.migrationAccessKey)
                    defaults.set(locations, forKey: LibraryStorageSettings.migrationLocationsKey)
                    }
                    } catch {
                        unavailableRecoveryProfiles.insert(profile.id)
                        if profile.id == activeLibraryID { migrationError = error.localizedDescription }
                    }
                }
            } else if locations[oldPath] != nil {
                unavailableRecoveryProfiles.insert(profile.id)
                if profile.id == activeLibraryID { migrationError = L10n.text("storage.migration.notFound") }
            }
        }
        for index in profiles.indices where !unavailableRecoveryProfiles.contains(profiles[index].id)
            && profiles[index].mediaURL.path.hasPrefix(legacyRoot.path + "/") {
            let oldMedia = profiles[index].mediaURL
            let newMedia = librariesRootURL.appendingPathComponent("Recovered/\(profiles[index].id)/Media", isDirectory: true)
            do {
                try PortableLibraryStorage.relocateLegacyMedia(from: oldMedia, to: newMedia, fileManager: fileManager)
                if profiles[index].catalogPath.hasPrefix(oldMedia.path + "/") {
                    profiles[index].catalogPath = newMedia.path + profiles[index].catalogPath.dropFirst(oldMedia.path.count)
                }
                profiles[index].mediaPath = newMedia.path
            } catch {
                migrationError = error.localizedDescription
            }
        }
        migrateProfilesToPortableStorage()
        persistProfiles()
    }

    deinit {
        for url in securityScopedProfileURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
    }

    var activeProfile: LibraryProfile {
        profiles.first(where: { $0.id == activeLibraryID }) ?? profiles[0]
    }

    var availableProfiles: [LibraryProfile] {
        profiles.filter { !$0.isArchived }.sorted { $0.createdAt < $1.createdAt }
    }

    var archivedProfiles: [LibraryProfile] {
        profiles.filter(\.isArchived).sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func createLibrary(named proposedName: String) throws -> LibraryProfile.ID {
        let name = normalizedName(proposedName)
        let id = UUID()
        let root = librariesRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let media = root.appendingPathComponent("Ongaku Media", isDirectory: true)
        try fileManager.createDirectory(at: media, withIntermediateDirectories: true)
        let catalog = try PortableLibraryStorage.migrateLegacyStateIfNeeded(
            from: root,
            to: media,
            fileManager: fileManager
        )
        profiles.append(LibraryProfile(
            id: id,
            name: name,
            catalogPath: catalog.path,
            mediaPath: media.path,
            isArchived: false,
            createdAt: .now
        ))
        activeLibraryID = id
        return id
    }

    @discardableResult
    func createExternalLibrary(
        named proposedName: String,
        in destinationDirectory: URL
    ) throws -> LibraryProfile.ID {
        let name = normalizedName(proposedName)
        let id = UUID()
        let parent = destinationDirectory.standardizedFileURL
        let parentAccess = parent.startAccessingSecurityScopedResource()
        defer { if parentAccess { parent.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ExternalLibraryError.invalidLocation
        }

        let root = uniqueExternalRoot(in: parent, name: name)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try fileManager.createDirectory(at: media, withIntermediateDirectories: true)
        let catalog = try PortableLibraryStorage.migrateLegacyStateIfNeeded(
            from: root.appendingPathComponent("Catalog", isDirectory: true),
            to: media,
            fileManager: fileManager
        )
        let marker = ExternalLibraryMarker(libraryID: id, createdAt: .now)
        // Initialize the manifest before publishing the new profile. The root
        // is unique, so no existing library or audio file is overwritten.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LibraryDocument(libraryID: id)).write(
            to: catalog.appendingPathComponent("library-v1.json"), options: .atomic
        )
        try JSONEncoder().encode(marker).write(
            to: root.appendingPathComponent(Self.externalMarkerName),
            options: .atomic
        )
        let bookmark = try root.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.volumeNameKey, .volumeUUIDStringKey],
            relativeTo: nil
        )
        let volumeName = try? root.resourceValues(forKeys: [.volumeNameKey]).volumeName
        let didAccess = root.startAccessingSecurityScopedResource()
        if didAccess { securityScopedProfileURLs[id] = root }
        profiles.append(LibraryProfile(
            id: id,
            name: name,
            catalogPath: catalog.path,
            mediaPath: media.path,
            isArchived: false,
            createdAt: .now,
            externalRootPath: root.path,
            externalBookmark: bookmark,
            externalVolumeName: volumeName
        ))
        activeLibraryID = id
        return id
    }

    func activate(_ id: LibraryProfile.ID) {
        guard let profile = profiles.first(where: { $0.id == id && !$0.isArchived }),
              connectionState(for: profile) == .connected else { return }
        activeLibraryID = id
    }

    /// Called only after the recovery UI explicitly confirms a separate library.
    /// Keep the previous profile so reconnecting its drive can recover it later.
    func createLibraryAfterRecoveryConfirmation(in directory: URL) throws {
        try createExternalLibrary(named: L10n.text("libraryProfile.defaultName"), in: directory)
        migrationError = nil
    }

    func connectionState(for profile: LibraryProfile) -> LibraryProfileConnectionState {
        Self.isReachable(profile, fileManager: fileManager)
            ? .connected
            : .disconnected(volumeName: profile.externalVolumeName)
    }

    func reconnect(_ id: LibraryProfile.ID, to selectedRoot: URL) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              profiles[index].isExternal else { throw ExternalLibraryError.wrongLibrary }
        let root = selectedRoot.standardizedFileURL
        let didAccess = root.startAccessingSecurityScopedResource()
        do {
            let markerURL = root.appendingPathComponent(Self.externalMarkerName)
            guard fileManager.fileExists(atPath: markerURL.path) else {
                throw ExternalLibraryError.markerMissing
            }
            let marker = try JSONDecoder().decode(
                ExternalLibraryMarker.self,
                from: Data(contentsOf: markerURL)
            )
            guard marker.libraryID == id else { throw ExternalLibraryError.wrongLibrary }
            let media = root.appendingPathComponent("Media", isDirectory: true)
            let legacyCatalog = root.appendingPathComponent("Catalog", isDirectory: true)
            let catalog = try PortableLibraryStorage.migrateLegacyStateIfNeeded(
                from: legacyCatalog,
                to: media,
                fileManager: fileManager
            )
            guard Self.requiredDirectoriesExist(catalog: catalog, media: media, fileManager: fileManager)
            else { throw ExternalLibraryError.invalidLocation }
            let bookmark = try root.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: [.volumeNameKey, .volumeUUIDStringKey],
                relativeTo: nil
            )
            securityScopedProfileURLs[id]?.stopAccessingSecurityScopedResource()
            if didAccess { securityScopedProfileURLs[id] = root }
            profiles[index].catalogPath = catalog.path
            profiles[index].mediaPath = media.path
            profiles[index].externalRootPath = root.path
            profiles[index].externalBookmark = bookmark
            profiles[index].externalVolumeName = try? root.resourceValues(forKeys: [.volumeNameKey]).volumeName
            if id == activeLibraryID { activeLocationRevision &+= 1 }
        } catch {
            if didAccess { root.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func refreshExternalConnections() {
        resolveExternalBookmarks()
        objectWillChange.send()
    }

    func rename(_ id: LibraryProfile.ID, to proposedName: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = normalizedName(proposedName)
    }

    func archive(_ id: LibraryProfile.ID) {
        guard id != activeLibraryID,
              availableProfiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].isArchived = true
    }

    func unarchive(_ id: LibraryProfile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].isArchived = false
    }

    func updateActiveMediaURL(_ url: URL) {
        guard let index = profiles.firstIndex(where: { $0.id == activeLibraryID }) else { return }
        let media = url.standardizedFileURL
        guard let catalog = try? PortableLibraryStorage.migrateLegacyStateIfNeeded(
            from: profiles[index].catalogURL,
            to: media,
            fileManager: fileManager
        ) else { return }
        profiles[index].mediaPath = media.path
        profiles[index].catalogPath = catalog.path
        activeLocationRevision &+= 1
    }

    /// A storage selection opens an independent catalog; it is not a migration.
    func adoptActiveStorageLocation(_ url: URL) {
        guard let index = profiles.firstIndex(where: { $0.id == activeLibraryID }) else { return }
        let locationChanged = profiles[index].mediaURL.standardizedFileURL != url.standardizedFileURL
        profiles[index].mediaPath = url.standardizedFileURL.path
        profiles[index].catalogPath = PortableLibraryStorage(mediaURL: url).rootURL.path
        if locationChanged, profiles[index].externalRootURL != nil {
            securityScopedProfileURLs.removeValue(forKey: activeLibraryID)?.stopAccessingSecurityScopedResource()
            profiles[index].externalRootPath = nil
            profiles[index].externalBookmark = nil
            profiles[index].externalVolumeName = nil
        }
        activeLocationRevision &+= 1
    }

    private func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.text("libraryProfile.untitled") : String(trimmed.prefix(80))
    }

    private func uniqueExternalRoot(in parent: URL, name: String) -> URL {
        let invalid = CharacterSet(charactersIn: "/:")
        let safeName = name.components(separatedBy: invalid).joined(separator: "-")
        let base = parent.appendingPathComponent("Ongaku Library – \(safeName)", isDirectory: true)
        guard fileManager.fileExists(atPath: base.path) else { return base }
        for suffix in 2...999 {
            let candidate = parent.appendingPathComponent(
                "Ongaku Library – \(safeName) \(suffix)",
                isDirectory: true
            )
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return parent.appendingPathComponent("Ongaku Library – \(UUID().uuidString)", isDirectory: true)
    }

    private func resolveExternalBookmarks() {
        for index in profiles.indices where profiles[index].isExternal {
            guard let bookmark = profiles[index].externalBookmark else { continue }
            var stale = false
            guard let root = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            let standardizedRoot = root.standardizedFileURL
            let media = standardizedRoot.appendingPathComponent("Media", isDirectory: true)
            let portableCatalog = PortableLibraryStorage(mediaURL: media).rootURL
            let legacyCatalog = standardizedRoot.appendingPathComponent("Catalog", isDirectory: true)
            let catalog = fileManager.fileExists(atPath: portableCatalog.path)
                ? portableCatalog
                : legacyCatalog
            guard Self.requiredDirectoriesExist(
                catalog: catalog,
                media: media,
                fileManager: fileManager
            ) else { continue }
            if securityScopedProfileURLs[profiles[index].id] == nil,
               standardizedRoot.startAccessingSecurityScopedResource() {
                securityScopedProfileURLs[profiles[index].id] = standardizedRoot
            }
            profiles[index].catalogPath = catalog.path
            profiles[index].mediaPath = media.path
            profiles[index].externalRootPath = standardizedRoot.path
            if stale {
                profiles[index].externalBookmark = try? standardizedRoot.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: [.volumeNameKey, .volumeUUIDStringKey],
                    relativeTo: nil
                )
            }
        }
    }

    private static func isReachable(_ profile: LibraryProfile, fileManager: FileManager) -> Bool {
        guard profile.isExternal else { return true }
        return requiredDirectoriesExist(
            catalog: profile.catalogURL,
            media: profile.mediaURL,
            fileManager: fileManager
        )
    }

    private static func requiredDirectoriesExist(
        catalog: URL,
        media: URL,
        fileManager: FileManager
    ) -> Bool {
        var catalogIsDirectory: ObjCBool = false
        var mediaIsDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: catalog.path, isDirectory: &catalogIsDirectory)
            && catalogIsDirectory.boolValue
            && fileManager.fileExists(atPath: media.path, isDirectory: &mediaIsDirectory)
            && mediaIsDirectory.boolValue
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
    }

    var recoveryLibraryID: String? {
        let locations = defaults.dictionary(forKey: LibraryStorageSettings.migrationLocationsKey) ?? [:]
        let record = locations[activeProfile.mediaURL.standardizedFileURL.path] as? [String: String]
        return record?["libraryID"]
    }

    func canAuthorizeMigration(using selected: URL) -> Bool {
        let destination = activeProfile.mediaURL.resolvingSymlinksInPath().standardizedFileURL.path
        let permissionRoot = selected.resolvingSymlinksInPath().standardizedFileURL.path
        return destination == permissionRoot
            || destination.hasPrefix(permissionRoot == "/" ? "/" : permissionRoot + "/")
    }

    /// Retry the existing destination only; never reinterpret recovery as a
    /// storage change or create an empty library in a different folder.
    func retryMigration(at mediaURL: URL) throws {
        guard mediaURL.standardizedFileURL.path == activeProfile.mediaURL.standardizedFileURL.path else {
            throw NSError(domain: "OngakuMigration", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L10n.text("storage.migration.sameFolder"),
            ])
        }
        migrationError = nil
        unavailableRecoveryProfiles.remove(activeLibraryID)
        migrateProfilesToPortableStorage(onlyActive: true)
        if let migrationError {
            throw NSError(domain: "OngakuMigration", code: 2, userInfo: [
                NSLocalizedDescriptionKey: migrationError,
            ])
        }
        persistProfiles()
    }

    func repairMigration(at mediaURL: URL) throws {
        guard let index = profiles.firstIndex(where: { $0.id == activeLibraryID }) else { return }
        let previous = profiles[index]
        let catalog = PortableLibraryStorage(mediaURL: mediaURL).rootURL
        profiles[index].mediaPath = mediaURL.standardizedFileURL.path
        if fileManager.fileExists(atPath: catalog.appendingPathComponent("library-v1.json").path) {
            profiles[index].catalogPath = catalog.path
        }
        do {
            try retryMigration(at: mediaURL)
        } catch {
            profiles[index] = previous
            throw error
        }
    }

    private func migrateProfilesToPortableStorage(onlyActive: Bool = false) {
        guard migrationError == nil else { return }
        let activeIndex = profiles.firstIndex { $0.id == activeLibraryID }
        let orderedIndices = ([activeIndex].compactMap { $0 }
            + (onlyActive ? [] : profiles.indices.filter { $0 != activeIndex }))
        var migratedIndices: [Int] = []
        for index in orderedIndices {
            let profile = profiles[index]
            guard !unavailableRecoveryProfiles.contains(profile.id),
                  Self.isReachable(profile, fileManager: fileManager) else { continue }
            do {
                let portableRoot = try PortableLibraryStorage.migrateLegacyStateIfNeeded(
                      from: profile.catalogURL,
                      to: profile.mediaURL,
                      fileManager: fileManager,
                      applicationSupportURL: legacyRootURL.deletingLastPathComponent(),
                      removeLegacyArtwork: false
                  )
                profiles[index].catalogPath = portableRoot.path
                migratedIndices.append(index)
            } catch {
                // An inaccessible inactive library stays intact for its own
                // recovery; it must not block opening the active library.
                if index == activeIndex { migrationError = error.localizedDescription }
            }
        }
        if migrationError == nil, let activeIndex,
           profiles[activeIndex].catalogURL.standardizedFileURL != legacyRootURL.standardizedFileURL {
            do {
                _ = try PortableLibraryStorage.migrateLegacyStateIfNeeded(
                    from: legacyRootURL,
                    to: profiles[activeIndex].mediaURL,
                    fileManager: fileManager,
                    applicationSupportURL: legacyRootURL.deletingLastPathComponent(),
                    removeLegacyArtwork: false
                )
            } catch {
                migrationError = error.localizedDescription
            }
        }
        // The old artwork store was shared by every profile. Copy it to every
        // reachable portable library first, then remove only verified matches.
        if !onlyActive, migrationError == nil, migratedIndices.count == orderedIndices.count, let activeIndex {
            do {
                let portableRoot = try PortableLibraryStorage.migrateLegacyStateIfNeeded(
                    from: profiles[activeIndex].catalogURL,
                    to: profiles[activeIndex].mediaURL,
                    fileManager: fileManager,
                    applicationSupportURL: legacyRootURL.deletingLastPathComponent(),
                    removeLegacyArtwork: true
                )
                profiles[activeIndex].catalogPath = portableRoot.path
            } catch {
                migrationError = error.localizedDescription
            }
        }
    }
}

enum LibraryStorageSource: String {
    case musicDirectory
    case automaticAppleMusic
    case selectedAppleMusicLibrary
    case applicationSupport
    case userSelected

    var localizationKey: String {
        switch self {
        case .musicDirectory: "settings.storage.source.musicDirectory"
        case .automaticAppleMusic: "settings.storage.source.appleMusic"
        case .selectedAppleMusicLibrary: "settings.storage.source.selectedAppleMusicLibrary"
        case .applicationSupport: "settings.storage.source.default"
        case .userSelected: "settings.storage.source.custom"
        }
    }
}

struct AppleMusicSettingsReader {
    private static let mediaFolderKeys = [
        "media-folder-url",
        "iTunes Media Folder Location",
        "iTunes Media Folder URL"
    ]

    static func mediaFolderURL(from preferences: [String: Any]) -> URL? {
        for key in mediaFolderKeys {
            guard let value = preferences[key] else { continue }
            if let url = value as? URL, url.isFileURL { return url.standardizedFileURL }
            if let string = value as? String {
                if let fileURL = URL(string: string), fileURL.isFileURL {
                    return fileURL.standardizedFileURL
                }
                if string.hasPrefix("/") {
                    return URL(fileURLWithPath: string, isDirectory: true).standardizedFileURL
                }
            }
        }

        if let bookmark = preferences["media-folder-bookmark"] as? Data {
            var isStale = false
            if let url = try? URL(
               resolvingBookmarkData: bookmark,
               options: [.withoutUI],
               relativeTo: nil,
               bookmarkDataIsStale: &isStale
           ) {
                return url.standardizedFileURL
            }
        }
        return nil
    }

    static func detectedMediaFolder(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        var candidates: [[String: Any]] = []
        if let domain = userDefaults.persistentDomain(forName: "com.apple.Music") {
            candidates.append(domain)
        }

        let plistURL = homeDirectory
            .appendingPathComponent("Library/Preferences/com.apple.Music.plist")
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = plist as? [String: Any] {
            candidates.append(dictionary)
        }

        return candidates
            .compactMap(mediaFolderURL(from:))
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    static func mediaFolder(
        forMusicLibrary libraryURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let library = libraryURL.standardizedFileURL
        guard library.pathExtension.lowercased() == "musiclibrary" else {
            throw AppleMusicLibraryError.invalidPackage
        }
        let values = try library.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw AppleMusicLibraryError.invalidPackage
        }

        let preferencesURL = library.appendingPathComponent("Preferences.plist")
        if let data = try? Data(contentsOf: preferencesURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let preferences = plist as? [String: Any],
           let configured = mediaFolderURL(from: preferences),
           fileManager.fileExists(atPath: configured.path) {
            return configured
        }

        let parent = library.deletingLastPathComponent()
        let siblingNames = ["Media.localized", "Media", "iTunes Media.localized", "iTunes Media"]
        for name in siblingNames {
            let candidate = parent.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate.standardizedFileURL
            }
        }
        throw AppleMusicLibraryError.mediaFolderNotFound
    }

    enum AppleMusicLibraryError: LocalizedError {
        case invalidPackage
        case mediaFolderNotFound

        var errorDescription: String? {
            switch self {
            case .invalidPackage: L10n.text("settings.storage.error.invalidMusicLibrary")
            case .mediaFolderNotFound: L10n.text("settings.storage.error.mediaFolderNotFound")
            }
        }
    }
}

@MainActor
final class LibraryStorageSettings: ObservableObject {
    private static let bookmarkKey = "library.storage.parentBookmark.v1"
    private static let pathKey = "library.storage.parentPath.v1"
    private static let sourceKey = "library.storage.source.v1"
    private static let musicLibraryPathKey = "library.storage.musicLibraryPath.v1"
    private static let musicLibraryMediaPathKey = "library.storage.musicLibraryMediaPath.v1"
    private static let musicLibraryStorageVersionKey = "library.storage.musicLibraryManagedStorage.v2"
    private static let mediaAccessBookmarksKey = "library.storage.mediaAccessBookmarks.v1"
    private static let managedFolderName = "Ongaku Media"

    @Published private(set) var mediaDirectoryURL: URL
    @Published private(set) var source: LibraryStorageSource
    @Published private(set) var musicLibraryURL: URL?
    @Published private(set) var musicLibraryMediaURL: URL?

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private var securityScopedURL: URL?
    private var musicMediaScopedURL: URL?
    private var migrationScopedURL: URL?
    static let migrationAccessKey = "library.storage.migrationAccessBookmarks.v1"
    static let migrationLocationsKey = "library.storage.migrationLocations.v1"

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        freshMusicDirectoryURL: URL? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager

        let savedSource = defaults.string(forKey: Self.sourceKey)
            .flatMap(LibraryStorageSource.init(rawValue:))
        if !Self.hasPersistedConfiguration(defaults: defaults) {
            let freshDirectory = Self.freshDefaultMediaDirectory(
                fileManager: fileManager,
                musicDirectoryURL: freshMusicDirectoryURL
            )
            mediaDirectoryURL = freshDirectory
            source = .musicDirectory
            defaults.set(freshDirectory.path, forKey: Self.pathKey)
            defaults.set(LibraryStorageSource.musicDirectory.rawValue, forKey: Self.sourceKey)
        } else if savedSource == .selectedAppleMusicLibrary,
                  !defaults.bool(forKey: Self.musicLibraryStorageVersionKey) {
            // Migrate the earlier behavior that incorrectly used Apple Music's
            // Media folder as Ongaku's managed-copy destination.
            mediaDirectoryURL = Self.defaultMediaDirectory(fileManager: fileManager)
            source = .applicationSupport
        } else if let savedParent = Self.savedParentURL(defaults: defaults) {
            mediaDirectoryURL = savedParent
            source = savedSource ?? .userSelected
            securityScopedURL = savedParent.startAccessingSecurityScopedResource() ? savedParent : nil
        } else if let appleMedia = AppleMusicSettingsReader.detectedMediaFolder(
            fileManager: fileManager,
            userDefaults: defaults
        ) {
            mediaDirectoryURL = Self.managedDirectory(in: appleMedia)
            source = .automaticAppleMusic
        } else {
            mediaDirectoryURL = Self.defaultMediaDirectory(fileManager: fileManager)
            source = .applicationSupport
        }
        musicLibraryURL = defaults.string(forKey: Self.musicLibraryPathKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        musicLibraryMediaURL = defaults.string(forKey: Self.musicLibraryMediaPathKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        if musicLibraryMediaURL == nil, let musicLibraryURL {
            musicLibraryMediaURL = try? AppleMusicSettingsReader.mediaFolder(
                forMusicLibrary: musicLibraryURL,
                fileManager: fileManager
            )
        }
        musicMediaScopedURL = restoreMediaAccess(for: mediaDirectoryURL)
        restoreMigrationAccess(for: mediaDirectoryURL)
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        musicMediaScopedURL?.stopAccessingSecurityScopedResource()
        migrationScopedURL?.stopAccessingSecurityScopedResource()
    }

    private func restoreMigrationAccess(for mediaURL: URL) {
        migrationScopedURL?.stopAccessingSecurityScopedResource()
        migrationScopedURL = nil
        guard let data = defaults.dictionary(forKey: Self.migrationAccessKey)?[mediaURL.standardizedFileURL.path] as? Data else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale),
           url.startAccessingSecurityScopedResource() {
            migrationScopedURL = url
        }
    }

    /// Keep the actual media destination unchanged when an ancestor grants access.
    func authorizeMigrationAccess(
        selecting selected: URL, mediaURL: URL, prepare: () throws -> Void
    ) throws {
        let didAccess = selected.startAccessingSecurityScopedResource()
        do {
            let destination = mediaURL.resolvingSymlinksInPath().standardizedFileURL.path
            let permissionRoot = selected.resolvingSymlinksInPath().standardizedFileURL.path
            guard destination == permissionRoot
                || destination.hasPrefix(permissionRoot == "/" ? "/" : permissionRoot + "/") else {
                throw NSError(domain: "OngakuMigration", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L10n.text("storage.migration.sameFolder"),
                ])
            }
            let bookmark = try selected.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            )
            try prepare()
            var saved = defaults.dictionary(forKey: Self.migrationAccessKey) ?? [:]
            saved[mediaURL.standardizedFileURL.path] = bookmark
            defaults.set(saved, forKey: Self.migrationAccessKey)
            if let libraryID = LibraryMigrationRecovery.catalogIdentity(at: PortableLibraryStorage(mediaURL: mediaURL).rootURL) {
                var locations = defaults.dictionary(forKey: Self.migrationLocationsKey) ?? [:]
                locations[mediaURL.standardizedFileURL.path] = [
                    "rootPath": selected.standardizedFileURL.path, "libraryID": libraryID,
                ]
                defaults.set(locations, forKey: Self.migrationLocationsKey)
            }
            migrationScopedURL?.stopAccessingSecurityScopedResource()
            migrationScopedURL = didAccess ? selected : nil
        } catch {
            if didAccess { selected.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func useSelectedDirectory(_ directoryURL: URL) throws {
        try useDirectory(directoryURL, source: .userSelected)
        defaults.removeObject(forKey: Self.musicLibraryPathKey)
        defaults.removeObject(forKey: Self.musicLibraryMediaPathKey)
        musicLibraryURL = nil
        musicLibraryMediaURL = nil
    }

    func useAppleMusicLibrary(_ libraryURL: URL) throws {
        let didAccess = libraryURL.startAccessingSecurityScopedResource()
        defer { if didAccess { libraryURL.stopAccessingSecurityScopedResource() } }
        let mediaFolder = try AppleMusicSettingsReader.mediaFolder(
            forMusicLibrary: libraryURL,
            fileManager: fileManager
        )
        let library = libraryURL.standardizedFileURL
        try useDirectory(Self.managedDirectory(in: mediaFolder), source: .selectedAppleMusicLibrary)
        defaults.set(true, forKey: Self.musicLibraryStorageVersionKey)
        defaults.set(library.path, forKey: Self.musicLibraryPathKey)
        defaults.set(mediaFolder.path, forKey: Self.musicLibraryMediaPathKey)
        musicLibraryURL = library
        musicLibraryMediaURL = mediaFolder
    }

    /// Keep bookmarks and the previous storage selection intact if preparation fails.
    func activateDirectory(
        _ directoryURL: URL,
        source newSource: LibraryStorageSource = .userSelected,
        musicLibrary: URL? = nil,
        musicMedia: URL? = nil,
        prepare: (URL) async throws -> Void
    ) async throws {
        let directory = directoryURL.standardizedFileURL
        let sourceScope = musicMedia.flatMap { $0.startAccessingSecurityScopedResource() ? $0 : nil }
            ?? restoreMediaAccess(for: directory)
        let didAccess = directory.startAccessingSecurityScopedResource()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let bookmark = try directory.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            )
            let sourceBookmark = try musicMedia?.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            )
            try await prepare(directory)
            securityScopedURL?.stopAccessingSecurityScopedResource()
            musicMediaScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = didAccess ? directory : nil
            musicMediaScopedURL = sourceScope
            if let sourceBookmark {
                var bookmarks = defaults.dictionary(forKey: Self.mediaAccessBookmarksKey) ?? [:]
                bookmarks[directory.path] = sourceBookmark
                defaults.set(bookmarks, forKey: Self.mediaAccessBookmarksKey)
            }
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            defaults.set(directory.path, forKey: Self.pathKey)
            defaults.set(newSource.rawValue, forKey: Self.sourceKey)
            defaults.set(musicLibrary?.path, forKey: Self.musicLibraryPathKey)
            defaults.set(musicMedia?.path, forKey: Self.musicLibraryMediaPathKey)
            defaults.set(musicLibrary != nil, forKey: Self.musicLibraryStorageVersionKey)
            mediaDirectoryURL = directory
            source = newSource
            musicLibraryURL = musicLibrary
            musicLibraryMediaURL = musicMedia
        } catch {
            if didAccess { directory.stopAccessingSecurityScopedResource() }
            sourceScope?.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    func activateAppleMusicLibrary(
        _ libraryURL: URL, authorizedMediaURL: URL? = nil, prepare: (URL) async throws -> Void
    ) async throws {
        let didAccess = libraryURL.startAccessingSecurityScopedResource()
        defer { if didAccess { libraryURL.stopAccessingSecurityScopedResource() } }
        guard libraryURL.pathExtension.lowercased() == "musiclibrary",
              try libraryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AppleMusicSettingsReader.AppleMusicLibraryError.invalidPackage
        }
        let media = try authorizedMediaURL?.standardizedFileURL
            ?? AppleMusicSettingsReader.mediaFolder(forMusicLibrary: libraryURL, fileManager: fileManager)
        try await activateDirectory(
            Self.managedDirectory(in: media), source: .selectedAppleMusicLibrary,
            musicLibrary: libraryURL.standardizedFileURL, musicMedia: media, prepare: prepare
        )
    }

    private func restoreMediaAccess(for directory: URL) -> URL? {
        guard let bookmarks = defaults.dictionary(forKey: Self.mediaAccessBookmarksKey),
              let data = bookmarks[directory.standardizedFileURL.path] as? Data else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    func activateAutomaticLocation(prepare: (URL) async throws -> Void) async throws {
        let detected = AppleMusicSettingsReader.detectedMediaFolder(fileManager: fileManager, userDefaults: defaults)
        try await activateDirectory(
            detected.map(Self.managedDirectory(in:)) ?? Self.defaultMediaDirectory(fileManager: fileManager),
            source: detected == nil ? .musicDirectory : .automaticAppleMusic,
            prepare: prepare
        )
    }

    private func useDirectory(_ directoryURL: URL, source newSource: LibraryStorageSource) throws {
        let directory = directoryURL.standardizedFileURL
        let didAccess = directory.startAccessingSecurityScopedResource()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let bookmark = try directory.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            securityScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = didAccess ? directory : nil
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            defaults.set(directory.path, forKey: Self.pathKey)
            defaults.set(newSource.rawValue, forKey: Self.sourceKey)
            mediaDirectoryURL = directory
            source = newSource
        } catch {
            if didAccess { directory.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func restoreAutomaticLocation() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.pathKey)
        defaults.removeObject(forKey: Self.sourceKey)

        if let appleMedia = AppleMusicSettingsReader.detectedMediaFolder(
            fileManager: fileManager,
            userDefaults: defaults
        ) {
            mediaDirectoryURL = Self.managedDirectory(in: appleMedia)
            source = .automaticAppleMusic
        } else {
            mediaDirectoryURL = Self.defaultMediaDirectory(fileManager: fileManager)
            source = .applicationSupport
        }
    }

    func activateProfileMediaDirectory(_ url: URL) {
        let profileURL = url.standardizedFileURL
        let locationChanged = mediaDirectoryURL.standardizedFileURL != profileURL
        mediaDirectoryURL = profileURL
        restoreMigrationAccess(for: profileURL)
        if locationChanged {
            let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let support = supportURL?.standardizedFileURL.path
            let path = profileURL.path
            source = support.map { path == $0 || path.hasPrefix($0 + "/") } == true
                ? .applicationSupport : .userSelected
        }
    }

    private static func managedDirectory(in parent: URL) -> URL {
        parent.appendingPathComponent(managedFolderName, isDirectory: true)
    }

    private static func defaultMediaDirectory(fileManager: FileManager) -> URL {
        freshDefaultMediaDirectory(fileManager: fileManager, musicDirectoryURL: nil)
    }

    private static func freshDefaultMediaDirectory(
        fileManager: FileManager,
        musicDirectoryURL: URL?
    ) -> URL {
        let musicDirectory = musicDirectoryURL
            ?? fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Music", isDirectory: true)
        return musicDirectory
            .appendingPathComponent("Ongaku Desktop/Ongaku Media", isDirectory: true)
            .standardizedFileURL
    }

    private static func hasPersistedConfiguration(defaults: UserDefaults) -> Bool {
        [
            bookmarkKey,
            pathKey,
            sourceKey,
            musicLibraryPathKey,
            musicLibraryMediaPathKey,
            LibraryProfileSettings.profilesKey,
            LibraryProfileSettings.activeProfileKey,
        ].contains { defaults.object(forKey: $0) != nil }
    }

    private static func savedParentURL(defaults: UserDefaults) -> URL? {
        if let bookmark = defaults.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), !isStale {
                return url.standardizedFileURL
            }
        }
        guard let path = defaults.string(forKey: pathKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
