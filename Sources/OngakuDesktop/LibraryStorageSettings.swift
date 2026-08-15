import Combine
import Foundation

enum LibraryStorageSource: String {
    case automaticAppleMusic
    case selectedAppleMusicLibrary
    case applicationSupport
    case userSelected

    var localizationKey: String {
        switch self {
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

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager

        let savedSource = defaults.string(forKey: Self.sourceKey)
            .flatMap(LibraryStorageSource.init(rawValue:))
        if savedSource == .selectedAppleMusicLibrary {
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

    private static func managedDirectory(in parent: URL) -> URL {
        parent.appendingPathComponent(managedFolderName, isDirectory: true)
    }

    private static func defaultMediaDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ongaku Desktop/Ongaku Media", isDirectory: true)
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
