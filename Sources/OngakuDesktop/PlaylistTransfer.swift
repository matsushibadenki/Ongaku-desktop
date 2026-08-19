import Foundation

enum PlaylistTransferFormat: String, CaseIterable, Identifiable, Sendable {
    case m3u
    case m3u8
    case json

    var id: String { rawValue }
    var fileExtension: String { rawValue }
}

enum PlaylistImportRowStatus: String, Sendable {
    case matched
    case duplicate
    case missing
}

struct PlaylistImportRow: Identifiable, Sendable {
    let id = UUID()
    var displayName: String
    var sourcePath: String?
    var trackID: Track.ID?
    var status: PlaylistImportRowStatus
}

struct PlaylistImportPreview: Identifiable, Sendable {
    let id = UUID()
    var name: String
    var description: String
    var rows: [PlaylistImportRow]

    var matchedTrackIDs: [Track.ID] {
        rows.compactMap { $0.status == .matched ? $0.trackID : nil }
    }

    var matchedCount: Int { rows.count { $0.status == .matched } }
    var duplicateCount: Int { rows.count { $0.status == .duplicate } }
    var missingCount: Int { rows.count { $0.status == .missing } }
}

enum PlaylistTransferError: LocalizedError {
    case unsupportedFormat
    case unreadableText
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: L10n.text("playlist.transfer.error.unsupported")
        case .unreadableText: L10n.text("playlist.transfer.error.unreadable")
        case .invalidJSON: L10n.text("playlist.transfer.error.invalidJSON")
        }
    }
}

enum PlaylistTransferService {
    private struct PortablePlaylist: Codable {
        var formatVersion: Int
        var name: String
        var description: String
        var entries: [PortableEntry]
    }

    private struct PortableEntry: Codable {
        var trackID: UUID?
        var path: String?
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
    }

    private struct Candidate {
        var path: String?
        var title: String?
        var artist: String?
        var album: String?
        var duration: TimeInterval?
        var trackID: UUID?
    }

    static func preview(from url: URL, tracks: [Track]) throws -> PlaylistImportPreview {
        let format = PlaylistTransferFormat(rawValue: url.pathExtension.lowercased())
        guard let format else { throw PlaylistTransferError.unsupportedFormat }
        let data = try Data(contentsOf: url)
        let parsed: (String, String, [Candidate])
        switch format {
        case .m3u, .m3u8:
            parsed = try parseM3U(data: data, sourceURL: url)
        case .json:
            parsed = try parseJSON(data: data)
        }
        return makePreview(
            name: parsed.0.isEmpty ? url.deletingPathExtension().lastPathComponent : parsed.0,
            description: parsed.1,
            candidates: parsed.2,
            sourceURL: url,
            tracks: tracks
        )
    }

    static func exportData(
        playlist: Playlist,
        tracks: [Track],
        format: PlaylistTransferFormat
    ) throws -> Data {
        switch format {
        case .m3u, .m3u8:
            var lines = ["#EXTM3U", "#PLAYLIST:\(playlist.name)"]
            for track in tracks {
                let seconds = max(0, Int(track.duration.rounded()))
                lines.append("#EXTINF:\(seconds),\(track.artist) - \(track.title)")
                lines.append(track.fileURL.path)
            }
            let text = lines.joined(separator: "\n") + "\n"
            guard let data = text.data(using: .utf8) else {
                throw PlaylistTransferError.unreadableText
            }
            return data
        case .json:
            let document = PortablePlaylist(
                formatVersion: 1,
                name: playlist.name,
                description: playlist.description,
                entries: tracks.map {
                    PortableEntry(
                        trackID: $0.id,
                        path: $0.managedPath,
                        title: $0.title,
                        artist: $0.artist,
                        album: $0.album,
                        duration: $0.duration
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(document)
        }
    }

    private static func parseJSON(data: Data) throws -> (String, String, [Candidate]) {
        do {
            let document = try JSONDecoder().decode(PortablePlaylist.self, from: data)
            guard document.formatVersion == 1 else {
                throw PlaylistTransferError.invalidJSON
            }
            return (
                document.name,
                document.description,
                document.entries.map {
                    Candidate(
                        path: $0.path,
                        title: $0.title,
                        artist: $0.artist,
                        album: $0.album,
                        duration: $0.duration,
                        trackID: $0.trackID
                    )
                }
            )
        } catch let error as PlaylistTransferError {
            throw error
        } catch {
            throw PlaylistTransferError.invalidJSON
        }
    }

    private static func parseM3U(
        data: Data,
        sourceURL: URL
    ) throws -> (String, String, [Candidate]) {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let text else { throw PlaylistTransferError.unreadableText }
        var name = ""
        var pendingTitle: String?
        var pendingArtist: String?
        var pendingDuration: TimeInterval?
        var candidates: [Candidate] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#PLAYLIST:") {
                name = String(line.dropFirst("#PLAYLIST:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#EXTINF:") {
                let detail = String(line.dropFirst("#EXTINF:".count))
                let pieces = detail.split(separator: ",", maxSplits: 1).map(String.init)
                pendingDuration = pieces.first.flatMap(TimeInterval.init)
                if pieces.count == 2 {
                    let label = pieces[1]
                    let names = label.components(separatedBy: " - ")
                    if names.count > 1 {
                        pendingArtist = names[0]
                        pendingTitle = names.dropFirst().joined(separator: " - ")
                    } else {
                        pendingTitle = label
                    }
                }
            } else if !line.hasPrefix("#") {
                candidates.append(Candidate(
                    path: line,
                    title: pendingTitle,
                    artist: pendingArtist,
                    album: nil,
                    duration: pendingDuration,
                    trackID: nil
                ))
                pendingTitle = nil
                pendingArtist = nil
                pendingDuration = nil
            }
        }
        return (name, "", candidates)
    }

    private static func makePreview(
        name: String,
        description: String,
        candidates: [Candidate],
        sourceURL: URL,
        tracks: [Track]
    ) -> PlaylistImportPreview {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let tracksByPath = Dictionary(grouping: tracks) { standardizedPath($0.managedPath) }
        let tracksByFilename = Dictionary(grouping: tracks) {
            $0.fileURL.lastPathComponent.lowercased()
        }
        var seen: Set<Track.ID> = []
        let rows = candidates.map { candidate -> PlaylistImportRow in
            let matched = candidate.trackID.flatMap { tracksByID[$0] }
                ?? matchPath(
                    candidate.path,
                    sourceURL: sourceURL,
                    tracksByPath: tracksByPath,
                    tracksByFilename: tracksByFilename
                )
                ?? matchMetadata(candidate, tracks: tracks)
            let status: PlaylistImportRowStatus
            if let matched {
                status = seen.insert(matched.id).inserted ? .matched : .duplicate
            } else {
                status = .missing
            }
            let fallback = candidate.path.map { URL(fileURLWithPath: $0).lastPathComponent }
            let displayName = matched.map { "\($0.artist) — \($0.title)" }
                ?? candidate.title
                ?? fallback
                ?? L10n.text("playlist.transfer.unknownEntry")
            return PlaylistImportRow(
                displayName: displayName,
                sourcePath: candidate.path,
                trackID: matched?.id,
                status: status
            )
        }
        return PlaylistImportPreview(name: name, description: description, rows: rows)
    }

    private static func matchPath(
        _ path: String?,
        sourceURL: URL,
        tracksByPath: [String: [Track]],
        tracksByFilename: [String: [Track]]
    ) -> Track? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        let resolvedURL = URL(fileURLWithPath: expanded, relativeTo: sourceURL.deletingLastPathComponent())
            .standardizedFileURL
        if let exact = tracksByPath[standardizedPath(resolvedURL.path)], exact.count == 1 {
            return exact[0]
        }
        let filename = resolvedURL.lastPathComponent.lowercased()
        if let matches = tracksByFilename[filename], matches.count == 1 {
            return matches[0]
        }
        return nil
    }

    private static func matchMetadata(_ candidate: Candidate, tracks: [Track]) -> Track? {
        guard let title = candidate.title else { return nil }
        let normalizedTitle = CatalogSearch.normalize(title)
        let matches = tracks.filter { track in
            guard CatalogSearch.normalize(track.title) == normalizedTitle else { return false }
            if let artist = candidate.artist,
               CatalogSearch.normalize(track.artist) != CatalogSearch.normalize(artist) {
                return false
            }
            if let album = candidate.album,
               CatalogSearch.normalize(track.album) != CatalogSearch.normalize(album) {
                return false
            }
            if let duration = candidate.duration,
               abs(track.duration - duration) > 2 {
                return false
            }
            return true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
