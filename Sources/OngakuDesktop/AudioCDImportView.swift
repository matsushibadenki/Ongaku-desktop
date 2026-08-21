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

struct AudioCDImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var discs: [AudioDisc] = []
    @State private var selectedDiscID: AudioDisc.ID?
    @State private var selectedTrackIDs: Set<AudioCDTrack.ID> = []
    @State private var titles: [AudioCDTrack.ID: String] = [:]
    @State private var artist = ""
    @State private var album = ""
    @State private var isScanning = true
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var selectedDisc: AudioDisc? {
        discs.first { $0.id == selectedDiscID } ?? discs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            actions
        }
        .frame(width: 760, height: 570)
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
                }
                .textFieldStyle(.roundedBorder)

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
            artist = ""
            album = ""
            return
        }
        selectedTrackIDs = Set(disc.tracks.map(\.id))
        titles = Dictionary(uniqueKeysWithValues: disc.tracks.map { ($0.id, $0.title) })
        artist = disc.tracks.first(where: { !$0.artist.isEmpty })?.artist ?? ""
        album = disc.tracks.first(where: { !$0.album.isEmpty })?.album ?? disc.name
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

    private func importSelection() async {
        guard let disc = selectedDisc else { return }
        isImporting = true
        errorMessage = nil
        let fallbackArtist = L10n.text("metadata.unknownArtist")
        let fallbackAlbum = L10n.text("metadata.unknownAlbum")
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let requests = disc.tracks.compactMap { track -> AudioCDImportRequest? in
            guard selectedTrackIDs.contains(track.id) else { return nil }
            let cleanTitle = (titles[track.id] ?? track.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AudioCDImportRequest(
                sourceURL: track.sourceURL,
                title: cleanTitle.isEmpty ? L10n.format("cd.track.defaultTitle", track.number) : cleanTitle,
                artist: cleanArtist.isEmpty ? fallbackArtist : cleanArtist,
                album: cleanAlbum.isEmpty ? fallbackAlbum : cleanAlbum,
                trackNumber: track.number,
                trackCount: disc.tracks.count
            )
        }
        let importedCount = await library.importAudioCD(requests)
        isImporting = false
        if importedCount > 0 {
            dismiss()
        } else {
            errorMessage = library.lastIssues.first?.message ?? L10n.text("cd.import.failed")
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return "—:—" }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
