import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum LegacyLibraryTrackStatus: String, Sendable {
    case ready
    case alreadyRegistered
    case missing
    case unsupported

    var titleKey: String { "libraryMigration.status.\(rawValue)" }
}

struct LegacyLibraryTrack: Identifiable, Sendable {
    let id: Int
    var persistentID: String?
    var location: URL?
    var title: String
    var artist: String
    var artistSortName: String
    var album: String
    var albumSortName: String
    var albumArtist: String
    var albumArtistSortName: String
    var composer: String
    var composerSortName: String
    var grouping: String
    var genre: String
    var beatsPerMinute: Int?
    var copyright: String
    var releaseYear: Int?
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?
    var isCompilation: Bool
    var rating: Int
    var playCount: Int
    var comments: String
    var isFavorite: Bool
    var isExcludedFromPlayback: Bool
    var addedAt: Date?
    var status: LegacyLibraryTrackStatus
}

struct LegacyLibraryPlaylist: Identifiable, Sendable {
    let id: String
    var name: String
    var description: String
    var trackIDs: [Int]
}

struct LegacyLibraryMigrationPreview: Sendable {
    var sourceURL: URL
    var sourceName: String
    var tracks: [LegacyLibraryTrack]
    var playlists: [LegacyLibraryPlaylist]

    var readyCount: Int { tracks.count { $0.status == .ready } }
    var registeredCount: Int { tracks.count { $0.status == .alreadyRegistered } }
    var missingCount: Int { tracks.count { $0.status == .missing } }
    var unsupportedCount: Int { tracks.count { $0.status == .unsupported } }
}

struct LegacyLibraryMigrationSummary: Sendable {
    var imported: Int
    var linkedExisting: Int
    var playlists: Int
    var issues: Int
}

enum LegacyLibraryMigrationError: LocalizedError, Equatable {
    case invalidFile
    case fileTooLarge
    case noTracks

    var errorDescription: String? {
        switch self {
        case .invalidFile: L10n.text("libraryMigration.error.invalidFile")
        case .fileTooLarge: L10n.text("libraryMigration.error.fileTooLarge")
        case .noTracks: L10n.text("libraryMigration.error.noTracks")
        }
    }
}

enum LegacyLibraryMigrationService {
    static let maximumXMLSize = 256 * 1_024 * 1_024
    private static let supportedExtensions: Set<String> = [
        "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "mp3", "wav",
    ]

    nonisolated static func preview(
        from sourceURL: URL,
        existingTracks: [Track]
    ) throws -> LegacyLibraryMigrationPreview {
        let source = sourceURL.standardizedFileURL
        let values = try source.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LegacyLibraryMigrationError.invalidFile
        }
        guard values.fileSize ?? 0 <= maximumXMLSize else {
            throw LegacyLibraryMigrationError.fileTooLarge
        }
        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let root = propertyList as? [String: Any],
              let rawTracks = root["Tracks"] as? [String: Any] else {
            throw LegacyLibraryMigrationError.invalidFile
        }

        let existingPaths = Set(existingTracks.map { $0.fileURL.standardizedFileURL.path })
        let tracks = rawTracks.values.compactMap { rawValue -> LegacyLibraryTrack? in
            guard let values = rawValue as? [String: Any],
                  let id = integer(values["Track ID"]) else { return nil }
            let location = fileURL(values["Location"] as? String)
            let status: LegacyLibraryTrackStatus
            if let location, existingPaths.contains(location.path) {
                status = .alreadyRegistered
            } else if let location, !supportedExtensions.contains(location.pathExtension.lowercased()) {
                status = .unsupported
            } else if let location, isReadableRegularFile(location) {
                status = .ready
            } else {
                status = .missing
            }
            let sourceRating = integer(values["Rating"]) ?? 0
            return LegacyLibraryTrack(
                id: id,
                persistentID: values["Persistent ID"] as? String,
                location: location,
                title: string(values["Name"], fallback: location?.deletingPathExtension().lastPathComponent),
                artist: string(values["Artist"], fallback: L10n.text("unknown.artist")),
                artistSortName: string(values["Sort Artist"]),
                album: string(values["Album"], fallback: L10n.text("unknown.album")),
                albumSortName: string(values["Sort Album"]),
                albumArtist: string(values["Album Artist"]),
                albumArtistSortName: string(values["Sort Album Artist"]),
                composer: string(values["Composer"]),
                composerSortName: string(values["Sort Composer"]),
                grouping: string(values["Grouping"]),
                genre: string(values["Genre"]),
                beatsPerMinute: integer(values["BPM"]),
                copyright: string(values["Copyright"]),
                releaseYear: integer(values["Year"]),
                trackNumber: integer(values["Track Number"]),
                trackCount: integer(values["Track Count"]),
                discNumber: integer(values["Disc Number"]),
                discCount: integer(values["Disc Count"]),
                isCompilation: boolean(values["Compilation"]),
                rating: min(5, max(0, Int((Double(sourceRating) / 20).rounded()))),
                playCount: max(0, integer(values["Play Count"]) ?? 0),
                comments: string(values["Comments"]),
                isFavorite: boolean(values["Loved"]),
                isExcludedFromPlayback: boolean(values["Disabled"]),
                addedAt: values["Date Added"] as? Date,
                status: status
            )
        }
        .sorted { $0.id < $1.id }
        guard !tracks.isEmpty else { throw LegacyLibraryMigrationError.noTracks }

        let knownTrackIDs = Set(tracks.map(\.id))
        let rawPlaylists = root["Playlists"] as? [[String: Any]] ?? []
        let playlists = rawPlaylists.compactMap { values -> LegacyLibraryPlaylist? in
            guard !boolean(values["Master"]),
                  !boolean(values["Music"]),
                  !boolean(values["Folder"]),
                  values["Distinguished Kind"] == nil,
                  values["Smart Info"] == nil,
                  values["Smart Criteria"] == nil else { return nil }
            let name = string(values["Name"])
            guard !name.isEmpty else { return nil }
            let items = values["Playlist Items"] as? [[String: Any]] ?? []
            let trackIDs = items.compactMap { integer($0["Track ID"]) }
                .filter { knownTrackIDs.contains($0) }
            return LegacyLibraryPlaylist(
                id: string(values["Playlist Persistent ID"], fallback: UUID().uuidString),
                name: name,
                description: string(values["Description"]),
                trackIDs: trackIDs
            )
        }

        return LegacyLibraryMigrationPreview(
            sourceURL: source,
            sourceName: string(root["Library Persistent ID"], fallback: source.deletingPathExtension().lastPathComponent),
            tracks: tracks,
            playlists: playlists
        )
    }

    private nonisolated static func fileURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL
        }
        let expanded = NSString(string: value).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private nonisolated static func isReadableRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isReadableKey]
        ) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && values.isReadable == true
    }

    private nonisolated static func string(_ value: Any?, fallback: String? = nil) -> String {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? (fallback ?? "") : text
    }

    private nonisolated static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private nonisolated static func boolean(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let value = value as? String { return ["1", "true", "yes"].contains(value.lowercased()) }
        return false
    }
}

struct LegacyLibraryMigrationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var preview: LegacyLibraryMigrationPreview?
    @State private var isChoosingFile = false
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                    .font(.title2)
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("libraryMigration.title")).font(.headline)
                    Text(L10n.text("libraryMigration.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("libraryMigration.choose")) { isChoosingFile = true }
                    .disabled(isLoading || isImporting)
            }

            if isLoading {
                HStack { ProgressView(); Text(L10n.text("libraryMigration.reading")) }
                    .foregroundStyle(.secondary)
            } else if let preview {
                summary(preview)
                Divider()
                List(preview.tracks) { track in
                    HStack(spacing: 12) {
                        Image(systemName: statusSymbol(track.status))
                            .foregroundStyle(statusColor(track.status))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1)
                            Text("\(track.artist) — \(track.album)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(L10n.text(track.status.titleKey))
                            .font(.caption)
                            .foregroundStyle(statusColor(track.status))
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    L10n.text("libraryMigration.empty.title"),
                    systemImage: "music.note.house",
                    description: Text(L10n.text("libraryMigration.empty.description"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isImporting { ProgressView(); Text(L10n.text("libraryMigration.importing")) }
                Spacer()
                Button(L10n.text("common.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Button(L10n.text("libraryMigration.import")) {
                    Task { await performImport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasImportableTracks || isLoading || isImporting)
            }
        }
        .padding(24)
        .frame(width: 760, height: 600)
        .background(AppTheme.canvas)
        .interactiveDismissDisabled(isImporting)
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.xml, .propertyList],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            loadPreview(url)
        }
    }

    private func summary(_ preview: LegacyLibraryMigrationPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.sourceURL.lastPathComponent).font(.subheadline.weight(.semibold))
            HStack(spacing: 18) {
                Label(L10n.format("libraryMigration.count.ready", preview.readyCount), systemImage: "square.and.arrow.down")
                Label(L10n.format("libraryMigration.count.registered", preview.registeredCount), systemImage: "checkmark.circle")
                Label(L10n.format("libraryMigration.count.playlists", preview.playlists.count), systemImage: "music.note.list")
                if preview.missingCount + preview.unsupportedCount > 0 {
                    Label(
                        L10n.format("libraryMigration.count.unavailable", preview.missingCount + preview.unsupportedCount),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
    }

    private func loadPreview(_ url: URL) {
        isLoading = true
        errorMessage = nil
        let existing = library.tracks
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                preview = try await Task.detached(priority: .userInitiated) {
                    try LegacyLibraryMigrationService.preview(from: url, existingTracks: existing)
                }.value
            } catch {
                preview = nil
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func performImport() async {
        guard let preview else { return }
        isImporting = true
        errorMessage = nil
        do {
            _ = try await library.importLegacyLibrary(preview)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isImporting = false
    }

    private var hasImportableTracks: Bool {
        guard let preview else { return false }
        return preview.readyCount + preview.registeredCount > 0
    }

    private func statusSymbol(_ status: LegacyLibraryTrackStatus) -> String {
        switch status {
        case .ready: "square.and.arrow.down"
        case .alreadyRegistered: "checkmark.circle.fill"
        case .missing: "questionmark.folder"
        case .unsupported: "nosign"
        }
    }

    private func statusColor(_ status: LegacyLibraryTrackStatus) -> Color {
        switch status {
        case .ready: AppTheme.accent
        case .alreadyRegistered: .green
        case .missing, .unsupported: .orange
        }
    }
}
