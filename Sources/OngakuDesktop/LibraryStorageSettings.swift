import Combine
import CryptoKit
import Foundation

/// Files that define an Ongaku library live beside its managed music so the
/// complete library can be moved to another Mac as one folder.
struct PortableLibraryStorage: Sendable {
    static let directoryName = "Ongaku Library Data"

    let mediaURL: URL

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
            for name in catalogNames {
                try moveIfDestinationIsMissing(
                    from: legacyCatalogURL.appendingPathComponent(name),
                    to: layout.rootURL.appendingPathComponent(name),
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
            if removeSource,
               try itemsMatch(source, destination, fileManager: fileManager) {
                try fileManager.removeItem(at: source)
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

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let librariesRootURL: URL
    private var securityScopedProfileURLs: [LibraryProfile.ID: URL] = [:]

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
        librariesRootURL = legacyRoot.appendingPathComponent("Libraries", isDirectory: true)

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

    private func migrateProfilesToPortableStorage() {
        let activeIndex = profiles.firstIndex { $0.id == activeLibraryID }
        let orderedIndices = ([activeIndex].compactMap { $0 }
            + profiles.indices.filter { $0 != activeIndex })
        var migratedIndices: [Int] = []
        for index in orderedIndices {
            let profile = profiles[index]
            guard Self.isReachable(profile, fileManager: fileManager),
                  let portableRoot = try? PortableLibraryStorage.migrateLegacyStateIfNeeded(
                      from: profile.catalogURL,
                      to: profile.mediaURL,
                      fileManager: fileManager,
                      removeLegacyArtwork: false
                  ) else { continue }
            profiles[index].catalogPath = portableRoot.path
            migratedIndices.append(index)
        }
        // The old artwork store was shared by every profile. Copy it to every
        // reachable portable library first, then remove only verified matches.
        if migratedIndices.count == orderedIndices.count,
           let activeIndex,
           let portableRoot = try? PortableLibraryStorage.migrateLegacyStateIfNeeded(
               from: profiles[activeIndex].catalogURL,
               to: profiles[activeIndex].mediaURL,
               fileManager: fileManager,
               removeLegacyArtwork: true
           ) {
            profiles[activeIndex].catalogPath = portableRoot.path
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
    private static let managedFolderName = "Ongaku Media"

    @Published private(set) var mediaDirectoryURL: URL
    @Published private(set) var source: LibraryStorageSource
    @Published private(set) var musicLibraryURL: URL?
    @Published private(set) var musicLibraryMediaURL: URL?

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private var securityScopedURL: URL?

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
        } else if savedSource == .selectedAppleMusicLibrary {
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
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
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
        defaults.set(library.path, forKey: Self.musicLibraryPathKey)
        defaults.set(mediaFolder.path, forKey: Self.musicLibraryMediaPathKey)
        musicLibraryURL = library
        musicLibraryMediaURL = mediaFolder
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
        if locationChanged {
            source = .applicationSupport
        }
    }

    private static func managedDirectory(in parent: URL) -> URL {
        parent.appendingPathComponent(managedFolderName, isDirectory: true)
    }

    private static func defaultMediaDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ongaku Desktop/Ongaku Media", isDirectory: true)
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
