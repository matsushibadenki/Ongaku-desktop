import AVFoundation
import SwiftUI

struct AudioCDTrack: Identifiable, Sendable {
    var id: String { sourceURL.standardizedFileURL.path }
    let sourceURL: URL
    let number: Int
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}

struct AudioDisc: Identifiable, Sendable {
    var id: String { volumeURL.standardizedFileURL.path }
    let volumeURL: URL
    let name: String
    let tracks: [AudioCDTrack]
}

enum AudioCDScanner {
    private static let trackExtensions: Set<String> = ["aif", "aiff", "cdda"]

    static func scan() async -> [AudioDisc] {
        let candidates = await Task.detached(priority: .userInitiated) {
            discoverCandidateVolumes()
        }.value

        var discs: [AudioDisc] = []
        for candidate in candidates {
            var tracks: [AudioCDTrack] = []
            for (index, url) in candidate.trackURLs.enumerated() {
                let number = trackNumber(from: url) ?? index + 1
                let metadata = await metadata(for: url)
                let fallbackTitle = L10n.format("cd.track.defaultTitle", number)
                tracks.append(AudioCDTrack(
                    sourceURL: url,
                    number: number,
                    title: cleanedTitle(metadata.title, number: number) ?? fallbackTitle,
                    artist: metadata.artist ?? "",
                    album: metadata.album ?? "",
                    duration: metadata.duration
                ))
            }
            guard !tracks.isEmpty else { continue }
            discs.append(AudioDisc(
                volumeURL: candidate.url,
                name: candidate.name,
                tracks: tracks.sorted { $0.number < $1.number }
            ))
        }
        return discs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct CandidateVolume: Sendable {
        let url: URL
        let name: String
        let trackURLs: [URL]
    }

    private static func discoverCandidateVolumes() -> [CandidateVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: []
        ) ?? []

        return volumes.compactMap { volumeURL in
            guard
                let entries = try? FileManager.default.contentsOfDirectory(
                    at: volumeURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: []
                )
            else { return nil }

            let trackURLs = entries.filter { url in
                guard trackExtensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      )
                else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }.sorted(by: audioTrackOrder)
            guard !trackURLs.isEmpty else { return nil }

            let values = try? volumeURL.resourceValues(forKeys: keys)
            let name = values?.volumeName ?? volumeURL.lastPathComponent
            let lowercasedNames = entries.map { $0.lastPathComponent.lowercased() }
            let hasTOC = lowercasedNames.contains { $0.contains("toc") }
            let hasAudioTrackNames = trackURLs.contains {
                $0.deletingPathExtension().lastPathComponent
                    .range(of: #"^\d+\s+audio\s+track$"#, options: [.regularExpression, .caseInsensitive]) != nil
            }
            let looksOptical = values?.volumeIsEjectable == true
                || name.localizedCaseInsensitiveContains("audio cd")
                || hasTOC
                || hasAudioTrackNames
            guard looksOptical else { return nil }
            return CandidateVolume(url: volumeURL, name: name, trackURLs: trackURLs)
        }
    }

    private static func audioTrackOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        let leftNumber = trackNumber(from: lhs) ?? .max
        let rightNumber = trackNumber(from: rhs) ?? .max
        if leftNumber != rightNumber { return leftNumber < rightNumber }
        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    private static func trackNumber(from url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: #"^\d+"#, options: .regularExpression) else { return nil }
        return Int(name[range])
    }

    private static func metadata(
        for url: URL
    ) async -> (title: String?, artist: String?, album: String?, duration: TimeInterval) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let items = (try? await asset.load(.commonMetadata)) ?? []

        func value(_ identifier: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(
                from: items,
                filteredByIdentifier: identifier
            ).first else { return nil }
            return try? await item.load(.stringValue)
        }

        return (
            await value(.commonIdentifierTitle),
            await value(.commonIdentifierArtist),
            await value(.commonIdentifierAlbumName),
            duration.isFinite ? max(0, duration) : 0
        )
    }

    private static func cleanedTitle(_ value: String?, number: Int) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.range(
            of: #"^\d+\s+audio\s+track$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return nil
        }
        return value
    }
}

enum AudioCDImportFormat: String, CaseIterable, Identifiable, Sendable {
    case alac
    case aiff
    case wav
    case aac

    var id: String { rawValue }
    var localizationKey: String { "cd.format.\(rawValue)" }
    var pathExtension: String {
        switch self {
        case .alac, .aac: "m4a"
        case .aiff: "aiff"
        case .wav: "wav"
        }
    }
}

enum AudioCDAACQuality: String, CaseIterable, Identifiable, Sendable {
    case standard
    case high

    var id: String { rawValue }
    var localizationKey: String { "cd.quality.\(rawValue)" }
    var bitRate: Int { self == .high ? 256_000 : 192_000 }
}

enum AudioCDRipError: LocalizedError, Equatable {
    case unstableRead
    case conversionFailed
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .unstableRead: L10n.text("cd.error.unstableRead")
        case .conversionFailed: L10n.text("cd.error.conversionFailed")
        case .invalidOutput: L10n.text("cd.error.invalidOutput")
        }
    }
}

enum AudioCDRipper {
    static let maximumReadAttempts = 3

    nonisolated static func verifiedSourceHash(
        _ sourceURL: URL,
        maximumAttempts: Int = maximumReadAttempts,
        hash: (URL) throws -> String = LibraryRepository.sha256
    ) throws -> String {
        guard maximumAttempts >= 2 else { throw AudioCDRipError.unstableRead }
        var previous: String?
        for _ in 0..<maximumAttempts {
            let current = try hash(sourceURL)
            if current == previous { return current }
            previous = current
        }
        throw AudioCDRipError.unstableRead
    }

    nonisolated static func rip(
        sourceURL: URL,
        destinationURL: URL,
        format: AudioCDImportFormat,
        aacQuality: AudioCDAACQuality
    ) throws {
        let sourceHash = try verifiedSourceHash(sourceURL)
        try? FileManager.default.removeItem(at: destinationURL)
        if format == .aiff {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            guard try LibraryRepository.sha256(of: destinationURL) == sourceHash else {
                throw AudioCDRipError.invalidOutput
            }
            return
        }

        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let processingFormat = sourceFile.processingFormat
        guard processingFormat.sampleRate > 0,
              processingFormat.channelCount > 0,
              sourceFile.length > 0 else {
            throw AudioCDRipError.conversionFailed
        }
        let settings = outputSettings(
            format: format,
            sourceFormat: processingFormat,
            aacQuality: aacQuality
        )
        do {
            let outputFile = try AVAudioFile(forWriting: destinationURL, settings: settings)
            let capacity: AVAudioFrameCount = 32_768
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: capacity
            ) else { throw AudioCDRipError.conversionFailed }
            while sourceFile.framePosition < sourceFile.length {
                buffer.frameLength = 0
                try sourceFile.read(into: buffer, frameCount: capacity)
                guard buffer.frameLength > 0 else { break }
                try outputFile.write(from: buffer)
            }
        }

        let verificationFile = try AVAudioFile(forReading: destinationURL)
        guard verificationFile.length > 0,
              verificationFile.processingFormat.sampleRate > 0,
              !(try LibraryRepository.sha256(of: destinationURL)).isEmpty else {
            throw AudioCDRipError.invalidOutput
        }
    }

    private nonisolated static func outputSettings(
        format: AudioCDImportFormat,
        sourceFormat: AVAudioFormat,
        aacQuality: AudioCDAACQuality
    ) -> [String: Any] {
        let base: [String: Any] = [
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: Int(sourceFormat.channelCount),
        ]
        switch format {
        case .alac:
            return base.merging([
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVEncoderBitDepthHintKey: 16,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]) { _, new in new }
        case .wav:
            return base.merging([
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]) { _, new in new }
        case .aac:
            return base.merging([
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: aacQuality.bitRate,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]) { _, new in new }
        case .aiff:
            return base
        }
    }
}

struct AudioCDImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var discs: [AudioDisc] = []
    @State private var selectedDiscID: AudioDisc.ID?
    @State private var selectedTrackIDs: Set<AudioCDTrack.ID> = []
    @State private var titles: [AudioCDTrack.ID: String] = [:]
    @State private var trackArtists: [AudioCDTrack.ID: String] = [:]
    @State private var artist = ""
    @State private var album = ""
    @State private var importFormat: AudioCDImportFormat = .alac
    @State private var aacQuality: AudioCDAACQuality = .high
    @State private var musicBrainzReleases: [MusicBrainzDiscReleaseCandidate] = []
    @State private var selectedReleaseID: MusicBrainzDiscReleaseCandidate.ID?
    @State private var appliedReleaseID: MusicBrainzDiscReleaseCandidate.ID?
    @State private var trackReferences: [AudioCDTrack.ID: MusicBrainzReference] = [:]
    @State private var isSearchingMusicBrainz = false
    @State private var isScanning = true
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var selectedDisc: AudioDisc? {
        discs.first { $0.id == selectedDiscID } ?? discs.first
    }

    private var selectedRelease: MusicBrainzDiscReleaseCandidate? {
        musicBrainzReleases.first { $0.id == selectedReleaseID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            actions
        }
        .frame(width: 840, height: 680)
        .background(AppTheme.canvas)
        .task { await rescan() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "opticaldisc")
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("cd.import.title"))
                    .font(.headline)
                Text(L10n.text("cd.import.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if discs.count > 1 {
                Picker(L10n.text("cd.disc"), selection: $selectedDiscID) {
                    ForEach(discs) { disc in
                        Text(disc.name).tag(Optional(disc.id))
                    }
                }
                .frame(width: 220)
                .onChange(of: selectedDiscID) { configureSelectedDisc() }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(L10n.text("cd.scanning"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let disc = selectedDisc {
            VStack(spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text(L10n.text("metadataEditor.field.artist"))
                            .frame(width: 120, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        TextField(L10n.text("metadataEditor.field.artist"), text: $artist)
                    }
                    GridRow {
                        Text(L10n.text("metadataEditor.field.album"))
                            .frame(width: 120, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        TextField(L10n.text("metadataEditor.field.album"), text: $album)
                    }
                    GridRow {
                        Text(L10n.text("cd.import.format"))
                            .frame(width: 120, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Picker("", selection: $importFormat) {
                                ForEach(AudioCDImportFormat.allCases) { format in
                                    Text(L10n.text(format.localizationKey)).tag(format)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                            if importFormat == .aac {
                                Picker(L10n.text("cd.import.quality"), selection: $aacQuality) {
                                    ForEach(AudioCDAACQuality.allCases) { quality in
                                        Text(L10n.text(quality.localizationKey)).tag(quality)
                                    }
                                }
                                .frame(width: 220)
                            } else {
                                Text(L10n.text("cd.quality.losslessCD"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)

                musicBrainzControls(for: disc)

                List(disc.tracks) { track in
                    HStack(spacing: 12) {
                        Toggle("", isOn: selectionBinding(for: track.id))
                            .labelsHidden()
                        Text(String(format: "%02d", track.number))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        TextField(
                            L10n.format("cd.track.defaultTitle", track.number),
                            text: titleBinding(for: track)
                        )
                        .textFieldStyle(.plain)
                        Divider().frame(height: 18)
                        TextField(
                            L10n.text("metadataEditor.field.artist"),
                            text: artistBinding(for: track)
                        )
                        .textFieldStyle(.plain)
                        .frame(width: 190)
                        Spacer(minLength: 12)
                        Text(Self.durationText(track.duration))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                .overlay(alignment: .topTrailing) {
                    Text(L10n.format("cd.track.selectedCount", selectedTrackIDs.count, disc.tracks.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        } else {
            ContentUnavailableView {
                Label(L10n.text("cd.empty.title"), systemImage: "opticaldisc")
            } description: {
                Text(L10n.text("cd.empty.message"))
            } actions: {
                Button(L10n.text("cd.rescan")) { Task { await rescan() } }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button(L10n.text("cd.rescan")) { Task { await rescan() } }
                .disabled(isScanning || isImporting)
            Spacer()
            Button(L10n.text("common.cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.text("cd.import.action")) { Task { await importSelection() } }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedDisc == nil || selectedTrackIDs.isEmpty || isImporting)
            if isImporting { ProgressView().controlSize(.small) }
        }
        .padding(20)
    }

    private func rescan() async {
        isScanning = true
        errorMessage = nil
        let result = await AudioCDScanner.scan()
        discs = result
        selectedDiscID = result.first?.id
        configureSelectedDisc()
        isScanning = false
    }

    private func configureSelectedDisc() {
        guard let disc = selectedDisc else {
            selectedTrackIDs = []
            titles = [:]
            trackArtists = [:]
            artist = ""
            album = ""
            musicBrainzReleases = []
            selectedReleaseID = nil
            appliedReleaseID = nil
            trackReferences = [:]
            return
        }
        selectedTrackIDs = Set(disc.tracks.map(\.id))
        titles = Dictionary(uniqueKeysWithValues: disc.tracks.map { ($0.id, $0.title) })
        trackArtists = Dictionary(uniqueKeysWithValues: disc.tracks.map { ($0.id, $0.artist) })
        artist = disc.tracks.first(where: { !$0.artist.isEmpty })?.artist ?? ""
        album = disc.tracks.first(where: { !$0.album.isEmpty })?.album ?? disc.name
        musicBrainzReleases = []
        selectedReleaseID = nil
        appliedReleaseID = nil
        trackReferences = [:]
    }

    private func selectionBinding(for id: AudioCDTrack.ID) -> Binding<Bool> {
        Binding(
            get: { selectedTrackIDs.contains(id) },
            set: { selected in
                if selected { selectedTrackIDs.insert(id) }
                else { selectedTrackIDs.remove(id) }
            }
        )
    }

    private func titleBinding(for track: AudioCDTrack) -> Binding<String> {
        Binding(
            get: { titles[track.id] ?? track.title },
            set: { titles[track.id] = $0 }
        )
    }

    private func artistBinding(for track: AudioCDTrack) -> Binding<String> {
        Binding(
            get: { trackArtists[track.id] ?? track.artist },
            set: { trackArtists[track.id] = $0 }
        )
    }

    @ViewBuilder
    private func musicBrainzControls(for disc: AudioDisc) -> some View {
        let toc = MusicBrainzDiscTOC(trackDurations: disc.tracks.map(\.duration))
        HStack(spacing: 10) {
            Button {
                Task { await searchMusicBrainz(for: toc) }
            } label: {
                Label(L10n.text("cd.musicbrainz.search"), systemImage: "music.note.list")
            }
            .disabled(isSearchingMusicBrainz)
            if isSearchingMusicBrainz { ProgressView().controlSize(.small) }
            if !musicBrainzReleases.isEmpty {
                Picker("", selection: $selectedReleaseID) {
                    ForEach(musicBrainzReleases) { release in
                        Text(releaseLabel(release)).tag(Optional(release.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 390)
                Button(L10n.text("cd.musicbrainz.apply")) { applySelectedRelease() }
                    .disabled(selectedRelease == nil)
            }
            Spacer(minLength: 8)
            Text(L10n.format("cd.musicbrainz.discID", toc.discID))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(toc.queryValue)
        }
    }

    private func searchMusicBrainz(for toc: MusicBrainzDiscTOC) async {
        isSearchingMusicBrainz = true
        errorMessage = nil
        do {
            musicBrainzReleases = try await MusicBrainzService.shared.releases(for: toc)
            selectedReleaseID = musicBrainzReleases.first?.id
            appliedReleaseID = nil
            trackReferences = [:]
            if musicBrainzReleases.isEmpty {
                errorMessage = L10n.text("cd.musicbrainz.noResults")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isSearchingMusicBrainz = false
    }

    private func applySelectedRelease() {
        guard let disc = selectedDisc, let release = selectedRelease else { return }
        album = release.title
        artist = release.artist
        appliedReleaseID = release.id
        trackReferences = [:]
        for track in disc.tracks {
            guard let metadata = release.tracks.first(where: { $0.position == track.number }) else {
                continue
            }
            titles[track.id] = metadata.title
            trackArtists[track.id] = metadata.artist
            trackReferences[track.id] = MusicBrainzReference(
                recordingID: metadata.recordingID,
                releaseID: release.releaseID,
                releaseGroupID: release.releaseGroupID,
                artistIDs: metadata.artistIDs,
                isrc: metadata.isrc,
                country: release.country,
                mediaFormat: release.mediaFormat,
                coverArtID: nil,
                coverArtTypes: [],
                fetchedAt: .now
            )
        }
    }

    private func importSelection() async {
        guard let disc = selectedDisc else { return }
        isImporting = true
        errorMessage = nil
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ongaku-CD-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporaryRoot,
                withIntermediateDirectories: true
            )
        } catch {
            isImporting = false
            errorMessage = error.localizedDescription
            return
        }
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let fallbackArtist = L10n.text("metadata.unknownArtist")
        let fallbackAlbum = L10n.text("metadata.unknownAlbum")
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenFormat = importFormat
        let chosenAACQuality = aacQuality
        var requests: [AudioCDImportRequest] = []
        for track in disc.tracks where selectedTrackIDs.contains(track.id) {
            let outputURL = temporaryRoot
                .appendingPathComponent(String(format: "%02d-%@", track.number, UUID().uuidString))
                .appendingPathExtension(chosenFormat.pathExtension)
            do {
                try await Task.detached(priority: .userInitiated) {
                    try AudioCDRipper.rip(
                        sourceURL: track.sourceURL,
                        destinationURL: outputURL,
                        format: chosenFormat,
                        aacQuality: chosenAACQuality
                    )
                }.value
            } catch {
                errorMessage = L10n.format(
                    "cd.import.trackError",
                    track.number,
                    error.localizedDescription
                )
                isImporting = false
                return
            }
            let cleanTitle = (titles[track.id] ?? track.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let perTrackArtist = (trackArtists[track.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let release = musicBrainzReleases.first { $0.id == appliedReleaseID }
            requests.append(AudioCDImportRequest(
                sourceURL: outputURL,
                title: cleanTitle.isEmpty ? L10n.format("cd.track.defaultTitle", track.number) : cleanTitle,
                artist: perTrackArtist.isEmpty
                    ? (cleanArtist.isEmpty ? fallbackArtist : cleanArtist)
                    : perTrackArtist,
                album: cleanAlbum.isEmpty ? fallbackAlbum : cleanAlbum,
                albumArtist: release?.artist,
                releaseYear: release?.releaseYear,
                isrc: trackReferences[track.id]?.isrc,
                trackNumber: track.number,
                trackCount: disc.tracks.count,
                discNumber: release?.discNumber,
                discCount: release?.discCount,
                musicBrainzReference: trackReferences[track.id]
            ))
        }
        let importedCount = await library.importAudioCD(requests)
        isImporting = false
        if importedCount > 0 {
            dismiss()
        } else {
            errorMessage = library.lastIssues.first?.message ?? L10n.text("cd.import.failed")
        }
    }

    private func releaseLabel(_ release: MusicBrainzDiscReleaseCandidate) -> String {
        let year = release.releaseYear.map(String.init) ?? "—"
        let country = release.country ?? "—"
        return "\(release.title) — \(release.artist) (\(year), \(country))"
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return "—:—" }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
