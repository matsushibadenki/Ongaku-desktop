import AVFoundation
import Foundation
import SwiftUI

enum URLAudioImportError: LocalizedError, Equatable {
    case invalidURL
    case secureConnectionRequired
    case privateHostNotAllowed
    case credentialsNotAllowed
    case nonstandardPortNotAllowed
    case invalidResponse
    case unsupportedMIMEType(String)
    case unsupportedFileType
    case mismatchedFileType
    case fileTooLarge
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .invalidURL: L10n.text("urlImport.error.invalidURL")
        case .secureConnectionRequired: L10n.text("urlImport.error.httpsRequired")
        case .privateHostNotAllowed: L10n.text("urlImport.error.privateHost")
        case .credentialsNotAllowed: L10n.text("urlImport.error.credentials")
        case .nonstandardPortNotAllowed: L10n.text("urlImport.error.port")
        case .invalidResponse: L10n.text("urlImport.error.response")
        case .unsupportedMIMEType(let type):
            L10n.format("urlImport.error.mime", type)
        case .unsupportedFileType: L10n.text("urlImport.error.fileType")
        case .mismatchedFileType: L10n.text("urlImport.error.mismatch")
        case .fileTooLarge: L10n.text("urlImport.error.tooLarge")
        case .invalidAudio: L10n.text("urlImport.error.invalidAudio")
        }
    }
}

struct URLAudioImportDescriptor: Equatable, Sendable {
    let finalURL: URL
    let fileName: String
    let pathExtension: String
    let mimeType: String
    let expectedSize: Int64?
}

enum URLAudioImportPolicy {
    static let maximumFileSize: Int64 = 512 * 1_024 * 1_024
    static let supportedExtensions: Set<String> = [
        "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "mp3", "wav",
    ]

    private static let extensionsByMIME: [String: Set<String>] = [
        "audio/aac": ["aac"],
        "audio/aiff": ["aif", "aiff"],
        "audio/flac": ["flac"],
        "audio/mpeg": ["mp3"],
        "audio/mp3": ["mp3"],
        "audio/mp4": ["aac", "alac", "m4a"],
        "audio/wav": ["wav"],
        "audio/x-aiff": ["aif", "aiff"],
        "audio/x-caf": ["caf"],
        "audio/x-flac": ["flac"],
        "audio/x-m4a": ["alac", "m4a"],
        "audio/x-wav": ["wav"],
    ]

    nonisolated static func validatedURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw URLAudioImportError.invalidURL
        }
        guard scheme == "https" else { throw URLAudioImportError.secureConnectionRequired }
        guard url.user == nil, url.password == nil else {
            throw URLAudioImportError.credentialsNotAllowed
        }
        guard url.port == nil || url.port == 443 else {
            throw URLAudioImportError.nonstandardPortNotAllowed
        }
        guard isPublicHost(host) else { throw URLAudioImportError.privateHostNotAllowed }
        return url
    }

    nonisolated static func descriptor(
        response: HTTPURLResponse,
        fallbackURL: URL
    ) throws -> URLAudioImportDescriptor {
        guard (200..<300).contains(response.statusCode) else {
            throw URLAudioImportError.invalidResponse
        }
        let finalURL = try validatedURL(from: (response.url ?? fallbackURL).absoluteString)
        let mime = normalizedMIME(response.mimeType)
        guard let compatibleExtensions = extensionsByMIME[mime] else {
            throw URLAudioImportError.unsupportedMIMEType(mime.isEmpty ? "—" : mime)
        }
        let expectedSize = response.expectedContentLength >= 0
            ? response.expectedContentLength : nil
        if let expectedSize, expectedSize > maximumFileSize {
            throw URLAudioImportError.fileTooLarge
        }

        // URLResponse may synthesize a filename extension from the MIME type.
        // Validate the server URL's real extension instead so a conflicting
        // Content-Type cannot silently rewrite `song.flac` to `song.flac.mp3`.
        var fileName = safeFileName(finalURL.lastPathComponent)
        var pathExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        if pathExtension.isEmpty {
            pathExtension = preferredExtension(for: mime)
            fileName = (fileName.isEmpty ? "download" : fileName)
                + "." + pathExtension
        }
        guard supportedExtensions.contains(pathExtension) else {
            throw URLAudioImportError.unsupportedFileType
        }
        guard compatibleExtensions.contains(pathExtension) else {
            throw URLAudioImportError.mismatchedFileType
        }
        return URLAudioImportDescriptor(
            finalURL: finalURL,
            fileName: fileName,
            pathExtension: pathExtension,
            mimeType: mime,
            expectedSize: expectedSize
        )
    }

    nonisolated static func validateDownloadedFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw URLAudioImportError.invalidAudio }
        guard Int64(values.fileSize ?? 0) <= maximumFileSize else {
            throw URLAudioImportError.fileTooLarge
        }
        let file = try? AVAudioFile(forReading: url)
        guard let file, file.length > 0, file.processingFormat.sampleRate > 0 else {
            throw URLAudioImportError.invalidAudio
        }
    }

    private nonisolated static func normalizedMIME(_ value: String?) -> String {
        (value ?? "").split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private nonisolated static func preferredExtension(for mime: String) -> String {
        switch mime {
        case "audio/aiff", "audio/x-aiff": "aiff"
        case "audio/mp4", "audio/x-m4a": "m4a"
        case "audio/wav", "audio/x-wav": "wav"
        case "audio/x-caf": "caf"
        case "audio/aac": "aac"
        case "audio/flac", "audio/x-flac": "flac"
        default: "mp3"
        }
    }

    private nonisolated static func safeFileName(_ value: String) -> String {
        let lastComponent = URL(fileURLWithPath: value).lastPathComponent
        let cleaned = lastComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "download" : cleaned).prefix(220))
    }

    private nonisolated static func isPublicHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return false
        }
        let unbracketed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if unbracketed == "::1" || unbracketed.hasPrefix("fe80:")
            || unbracketed.hasPrefix("fc") || unbracketed.hasPrefix("fd") {
            return false
        }
        let octets = unbracketed.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (0, _): return false
            case (169, 254): return false
            case (172, 16...31): return false
            case (192, 168): return false
            default: break
            }
        }
        return true
    }
}

private final class URLAudioDownloadDelegate: NSObject, URLSessionTaskDelegate,
    URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumSize: Int64
    private let stateLock = NSLock()
    private var didExceedMaximumSize = false

    init(maximumSize: Int64) { self.maximumSize = maximumSize }

    var exceededMaximumSize: Bool {
        stateLock.withLock { didExceedMaximumSize }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed = request.url.flatMap {
            try? URLAudioImportPolicy.validatedURL(from: $0.absoluteString)
        } != nil
        completionHandler(allowed ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumSize
            || totalBytesExpectedToWrite > maximumSize {
            stateLock.withLock { didExceedMaximumSize = true }
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

struct DownloadedAudioImport: Sendable {
    let fileURL: URL
    let sourceURL: URL
    let mimeType: String
    let byteCount: Int64
}

actor URLAudioImportService {
    static let shared = URLAudioImportService()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func download(from value: String) async throws -> DownloadedAudioImport {
        let requestedURL = try URLAudioImportPolicy.validatedURL(from: value)
        var request = URLRequest(url: requestedURL)
        request.httpMethod = "GET"
        request.setValue("audio/*", forHTTPHeaderField: "Accept")
        let delegate = URLAudioDownloadDelegate(
            maximumSize: URLAudioImportPolicy.maximumFileSize
        )
        let temporaryDownload: URL
        let response: URLResponse
        do {
            (temporaryDownload, response) = try await session.download(
                for: request,
                delegate: delegate
            )
        } catch {
            if delegate.exceededMaximumSize {
                throw URLAudioImportError.fileTooLarge
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw URLAudioImportError.invalidResponse
        }
        let descriptor = try URLAudioImportPolicy.descriptor(
            response: http,
            fallbackURL: requestedURL
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-URL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(descriptor.fileName)
        do {
            try FileManager.default.moveItem(at: temporaryDownload, to: destination)
            try URLAudioImportPolicy.validateDownloadedFile(destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            return DownloadedAudioImport(
                fileURL: destination,
                sourceURL: descriptor.finalURL,
                mimeType: descriptor.mimeType,
                byteCount: Int64(values.fileSize ?? 0)
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

struct URLAudioImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var urlText = ""
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var pendingDownload: DownloadedAudioImport?
    @State private var requiredMetadata: RequiredImportMetadataDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "link.badge.plus")
                    .font(.title2)
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("urlImport.title")).font(.headline)
                    Text(L10n.text("urlImport.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("https://example.com/song.flac", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.text("urlImport.url"))
                .disabled(isImporting || pendingDownload != nil)
                .onSubmit { Task { await importAudio() } }

            if let draft = requiredMetadata {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("import.requiredMetadata.urlMessage"))
                        .font(.callout.weight(.semibold))
                    if draft.requiresArtist {
                        TextField(
                            L10n.text("import.requiredMetadata.artistPlaceholder"),
                            text: requiredMetadataBinding(\.artist)
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                    if draft.requiresAlbum {
                        TextField(
                            L10n.text("import.requiredMetadata.albumPlaceholder"),
                            text: requiredMetadataBinding(\.album)
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(14)
                .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 12))
            }

            Label(L10n.text("urlImport.security"), systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isImporting {
                    ProgressView()
                    Text(L10n.text("urlImport.downloading"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("common.cancel"), role: .cancel) {
                    cleanupPendingDownload()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Button(L10n.text("urlImport.action")) { Task { await importAudio() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isImporting || requiredMetadata?.isComplete == false)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(AppTheme.canvas)
        .interactiveDismissDisabled(isImporting)
        .onDisappear { cleanupPendingDownload() }
    }

    private func importAudio() async {
        if let pendingDownload, let requiredMetadata {
            await importDownloadedAudio(pendingDownload, metadata: requiredMetadata)
            return
        }
        isImporting = true
        errorMessage = nil
        do {
            let download = try await URLAudioImportService.shared.download(from: urlText)
            let drafts = await library.requiredImportMetadata(for: [download.fileURL])
            if let draft = drafts.first {
                pendingDownload = download
                requiredMetadata = draft
                isImporting = false
                return
            }
            let previousCount = library.tracks.count
            await library.importFiles([download.fileURL])
            try? FileManager.default.removeItem(
                at: download.fileURL.deletingLastPathComponent()
            )
            if library.tracks.count > previousCount {
                dismiss()
            } else {
                errorMessage = library.lastIssues.first?.message
                    ?? L10n.text("urlImport.error.importFailed")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isImporting = false
    }

    private func importDownloadedAudio(
        _ download: DownloadedAudioImport,
        metadata: RequiredImportMetadataDraft
    ) async {
        guard metadata.isComplete else { return }
        isImporting = true
        errorMessage = nil
        let previousCount = library.tracks.count
        await library.importFiles(
            [download.fileURL],
            requiredMetadataOverrides: [metadata.id: metadata]
        )
        cleanupPendingDownload()
        if library.tracks.count > previousCount {
            dismiss()
        } else {
            errorMessage = library.lastIssues.first?.message
                ?? L10n.text("urlImport.error.importFailed")
        }
        isImporting = false
    }

    private func requiredMetadataBinding(
        _ keyPath: WritableKeyPath<RequiredImportMetadataDraft, String>
    ) -> Binding<String> {
        Binding(
            get: { requiredMetadata?[keyPath: keyPath] ?? "" },
            set: { value in requiredMetadata?[keyPath: keyPath] = value }
        )
    }

    private func cleanupPendingDownload() {
        if let pendingDownload {
            try? FileManager.default.removeItem(
                at: pendingDownload.fileURL.deletingLastPathComponent()
            )
        }
        pendingDownload = nil
        requiredMetadata = nil
    }
}
