import Combine
import Foundation

#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class LibraryStore: ObservableObject {
    enum Activity: Equatable {
        case idle
        case importing
        case verifying
        case notice(String)
        case failed(String)
    }

    @Published private(set) var tracks: [Track] = []
    @Published var selectedSection: LibrarySection = .songs
    @Published var selectedTrackID: Track.ID?
    @Published var searchText = ""
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var lastIssues: [ImportIssue] = []

    private let repository: LibraryRepository

    init(repository: LibraryRepository = LibraryRepository()) {
        self.repository = repository
    }

    var selectedTrack: Track? {
        tracks.first { $0.id == selectedTrackID }
    }

    var filteredTracks: [Track] {
        var result: [Track]
        switch selectedSection {
        case .songs, .albums, .artists, .effects:
            result = tracks
        case .recentlyAdded:
            result = tracks.sorted { $0.addedAt > $1.addedAt }
        case .needsAttention:
            result = tracks.filter { $0.health != .verified }
        }

        guard !searchText.isEmpty else { return result }
        return result.filter {
            $0.title.localizedStandardContains(searchText)
                || $0.artist.localizedStandardContains(searchText)
                || $0.album.localizedStandardContains(searchText)
        }
    }

    var totalBytes: Int64 { tracks.reduce(0) { $0 + $1.fileSize } }
    var attentionCount: Int { tracks.filter { $0.health != .verified }.count }

    func load() async {
        do {
            let result = try await repository.load()
            tracks = result.document.tracks
            selectedTrackID = selectedTrackID ?? tracks.first?.id
            if result.unresolvedImportCount > 0 {
                activity = .failed(L10n.format("status.importRecoveryIssues", result.unresolvedImportCount))
            } else if result.recoveredImportCount > 0 {
                activity = .notice(L10n.format("status.recoveredImports", result.recoveredImportCount))
            } else if result.recoveredFromBackup {
                activity = .notice(L10n.text("status.recoveredManifest"))
            } else {
                activity = .idle
            }
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        activity = .importing
        lastIssues = []
        let result = await repository.importFiles(urls, existing: tracks)
        tracks.append(contentsOf: result.imported)
        tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        lastIssues = result.issues

        do {
            try await repository.save(tracks: tracks)
            selectedTrackID = result.imported.first?.id ?? selectedTrackID
            activity = result.issues.isEmpty ? .idle : .failed(L10n.format("import.issueCount", result.issues.count))
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func importAppleMusicMediaFolder(
        _ mediaFolderURL: URL,
        excluding managedDirectoryURL: URL
    ) async -> AppleMusicImportSummary {
        activity = .importing
        lastIssues = []
        let sourceURLs = await Task.detached(priority: .userInitiated) {
            Self.discoverAudioFiles(
                in: mediaFolderURL,
                excluding: managedDirectoryURL
            )
        }.value
        guard !sourceURLs.isEmpty else {
            activity = .notice(L10n.text("status.appleMusicNoFiles"))
            return AppleMusicImportSummary(discovered: 0, imported: 0, relinked: 0, issues: 0)
        }

        let result = await repository.referenceFilesInPlace(
            sourceURLs,
            existing: tracks
        )
        var importedCount = 0
        var relinkedCount = 0
        for referencedTrack in result.imported {
            if let index = tracks.firstIndex(where: { $0.sha256 == referencedTrack.sha256 }) {
                if tracks[index].fileURL.standardizedFileURL != referencedTrack.fileURL.standardizedFileURL {
                    relinkedCount += 1
                }
                tracks[index] = referencedTrack
            } else {
                tracks.append(referencedTrack)
                importedCount += 1
            }
        }
        tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        lastIssues = result.issues

        do {
            try await repository.save(tracks: tracks)
            selectedTrackID = result.imported.first?.id ?? selectedTrackID
            activity = result.issues.isEmpty
                ? .notice(L10n.format("status.appleMusicImported", importedCount, relinkedCount))
                : .failed(L10n.format("import.issueCount", result.issues.count))
        } catch {
            activity = .failed(error.localizedDescription)
        }
        return AppleMusicImportSummary(
            discovered: sourceURLs.count,
            imported: importedCount,
            relinked: relinkedCount,
            issues: result.issues.count
        )
    }

    func verifyLibrary() async {
        guard !tracks.isEmpty else { return }
        activity = .verifying
        tracks = await repository.verify(tracks)
        do {
            try await repository.save(tracks: tracks)
            activity = .idle
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func setMediaDirectory(_ url: URL) async throws {
        try await repository.setMediaDirectory(url)
        activity = .notice(L10n.text("status.storageChanged"))
    }

    func reveal(_ track: Track) {
#if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([track.fileURL])
#endif
    }


    private nonisolated static func discoverAudioFiles(
        in mediaFolderURL: URL,
        excluding managedDirectoryURL: URL
    ) -> [URL] {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: mediaFolderURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let managedPath = managedDirectoryURL.standardizedFileURL.path
        let legacyAppleMediaManagedPath = mediaFolderURL
            .appendingPathComponent("Ongaku Media", isDirectory: true)
            .standardizedFileURL.path
        let supportedExtensions: Set<String> = [
            "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "mp3", "wav"
        ]
        var audioFiles: [URL] = []
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            if path == managedPath || path.hasPrefix(managedPath + "/")
                || path == legacyAppleMediaManagedPath
                || path.hasPrefix(legacyAppleMediaManagedPath + "/") {
                if (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard supportedExtensions.contains(standardized.pathExtension.lowercased()),
                  let values = try? standardized.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            audioFiles.append(standardized)
        }
        return audioFiles.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}
