@preconcurrency import AVFoundation
import Foundation

enum AudioArtworkChange: Sendable {
    case unchanged
    case set(Data)
}

struct AudioMetadataUpdate: Sendable {
    let title: String
    let artist: String
    let album: String
    var artwork: AudioArtworkChange = .unchanged
}

struct EmbeddedFileFingerprint: Sendable {
    let fileSize: Int64
    let sha256: String
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

// AVFoundation invokes this completion handler on its own serialization queue.
// Keeping its creation outside AudioFileMetadataWriter prevents Swift 6 from
// attaching the writer actor's executor precondition to the callback.
private func exportAudioAsset(_ box: ExportSessionBox) async throws {
    try await withCheckedThrowingContinuation { continuation in
        box.session.exportAsynchronously {
            switch box.session.status {
            case .completed:
                continuation.resume()
            case .cancelled:
                continuation.resume(throwing: CancellationError())
            default:
                continuation.resume(
                    throwing: box.session.error ?? CocoaError(.fileWriteUnknown)
                )
            }
        }
    }
}

/// Safely rewrites metadata only for containers that AVFoundation can export
/// without transcoding. Unsupported files remain untouched and keep using the
/// catalog metadata maintained by `LibraryStore`.
actor AudioFileMetadataWriter {
    static let shared = AudioFileMetadataWriter()

    private let fileManager = FileManager.default

    func embed(_ update: AudioMetadataUpdate, in url: URL) async -> EmbeddedFileFingerprint? {
        guard let outputType = outputType(for: url), fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".ongaku-metadata-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        do {
            let asset = AVURLAsset(url: url)
            guard let session = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetPassthrough
            ) else { return nil }

            session.outputURL = temporaryURL
            session.outputFileType = outputType
            session.metadata = try await mergedMetadata(for: asset, update: update)
            session.shouldOptimizeForNetworkUse = false
            try await exportAudioAsset(ExportSessionBox(session))

            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return EmbeddedFileFingerprint(
                fileSize: Int64(values.fileSize ?? 0),
                sha256: try LibraryRepository.sha256(of: url)
            )
        } catch {
            // Embedding is opportunistic. Catalog persistence is the fallback,
            // so an unsupported or malformed media file must not block editing.
            return nil
        }
    }

    nonisolated static func supportsEmbedding(at url: URL) -> Bool {
        ["m4a", "m4b", "mp4"].contains(url.pathExtension.lowercased())
    }

    private func outputType(for url: URL) -> AVFileType? {
        switch url.pathExtension.lowercased() {
        case "m4a", "m4b": .m4a
        case "mp4": .mp4
        default: nil
        }
    }

    private func mergedMetadata(
        for asset: AVURLAsset,
        update: AudioMetadataUpdate
    ) async throws -> [AVMetadataItem] {
        var replacedIdentifiers: Set<AVMetadataIdentifier> = [
            .commonIdentifierTitle,
            .commonIdentifierArtist,
            .commonIdentifierAlbumName,
            .iTunesMetadataSongName,
            .iTunesMetadataArtist,
            .iTunesMetadataAlbum
        ]
        if case .set = update.artwork {
            replacedIdentifiers.formUnion([
                .commonIdentifierArtwork,
                .iTunesMetadataCoverArt
            ])
        }
        let existing = try await asset.load(.metadata)
        var result: [AVMetadataItem] = []
        for item in existing {
            if let identifier = item.identifier,
               replacedIdentifiers.contains(identifier) { continue }
            result.append(item)
        }

        result.append(stringItem(identifier: .iTunesMetadataSongName, value: update.title))
        result.append(stringItem(identifier: .iTunesMetadataArtist, value: update.artist))
        result.append(stringItem(identifier: .iTunesMetadataAlbum, value: update.album))
        if case .set(let data) = update.artwork {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataCoverArt
            item.value = data as NSData
            result.append(item)
        }
        return result
    }

    private func stringItem(
        identifier: AVMetadataIdentifier,
        value: String
    ) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

}
